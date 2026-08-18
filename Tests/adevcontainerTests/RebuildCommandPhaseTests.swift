import Foundation
@testable import ADevContainerLib

// MARK: - Scenario builder (sections 3–5)

/// Editor runner that rewrites the temp path and reports launch timing for TTY named-retry tests.
private final class RebuildTTYEditorRunner: ProcessRunning, @unchecked Sendable {
    let bytes: Data
    var launches = 0
    let onLaunch: (Int) -> Void

    init(bytes: Data, onLaunch: @escaping (Int) -> Void = { _ in }) {
        self.bytes = bytes
        self.onLaunch = onLaunch
    }

    func run(
        executable: String,
        arguments: [String],
        environment: [String: String]?,
        currentDirectory: String?,
        stdinData: Data?
    ) throws -> ProcessResult {
        launches += 1
        onLaunch(launches)
        if let path = arguments.last {
            try bytes.write(to: URL(fileURLWithPath: path))
        }
        return ProcessResult(exitCode: 0, stdout: Data(), stderr: Data())
    }
}

/// Mock runtime scenario for rebuild Phase A/B tests.
final class RebuildScenario {
    let mock = MockProcessRunner()
    var containers: [ContainerInfo] = []
    var volumeConfigText = #"{"image":"alpine:3.20"}"#
    var existingImages: [String] = []
    var volumes: [String] = []
    var startFails = false
    var deleteFails = false
    var createFails = false
    var volumeCreateFails = false
    var buildFails = false
    var newContainerId = "new-id-created"
    /// exec script substrings that should exit non-zero.
    var failingExecSubstrings: [String] = []
    /// Volume-mode guest `.devcontainer/` presence for initialize staging.
    var guestDevcontainerExists = true
    /// `tar cf - -C <workspace> .devcontainer` stdout returned by the mock exec.
    var guestDevcontainerTar: Data?

    var runtime: AppleContainerRuntime {
        AppleContainerRuntime(executablePath: "container", runner: mock)
    }

    func install() {
        for container in containers where RecoveryHelper.isEligible(container) {
            if !existingImages.contains(RecoveryHelper.helperImageReference) {
                existingImages.append(RecoveryHelper.helperImageReference)
            }
            if let volume = container.labels[ContainerIdentity.labelWorkspaceVolume], !volumes.contains(volume) {
                volumes.append(volume)
            }
        }
        mock.handlers.append { [weak self] args in self?.handle(args) }
    }

    static func container(
        id: String,
        state: String = "running",
        labels: [String: String]
    ) -> ContainerInfo {
        ContainerInfo(id: id, name: id, state: state, labels: labels, image: "alpine:3.20")
    }

    func bindLabels(
        localFolder: String,
        configFile: String,
        hash: String = "oldhash",
        workspaceFolder: String = "/workspaces/old",
        remoteUser: String = "vscode"
    ) -> [String: String] {
        [
            ContainerIdentity.labelManaged: ContainerIdentity.managedValue,
            ContainerIdentity.labelWorkspaceMode: ContainerIdentity.workspaceModeBind,
            ContainerIdentity.labelLocalFolder: localFolder,
            ContainerIdentity.labelConfigFile: configFile,
            ContainerIdentity.labelConfigHash: hash,
            ContainerIdentity.labelWorkspaceFolder: workspaceFolder,
            ContainerIdentity.labelRemoteUser: remoteUser
        ]
    }

    func volumeLabels(
        configFile: String = ".devcontainer/devcontainer.json",
        workspaceFolder: String = "/workspaces/edge",
        gitURL: String = "https://github.com/example/repo.git",
        workspaceVolume: String = "adev-repo-ws",
        hash: String = "oldhash",
        remoteUser: String = "vscode"
    ) -> [String: String] {
        [
            ContainerIdentity.labelManaged: ContainerIdentity.managedValue,
            ContainerIdentity.labelWorkspaceMode: ContainerIdentity.workspaceModeVolume,
            ContainerIdentity.labelConfigFile: configFile,
            ContainerIdentity.labelWorkspaceFolder: workspaceFolder,
            ContainerIdentity.labelGitURL: gitURL,
            ContainerIdentity.labelWorkspaceVolume: workspaceVolume,
            ContainerIdentity.labelConfigHash: hash,
            ContainerIdentity.labelRemoteUser: remoteUser
        ]
    }

    // MARK: runtime mock

    private func handle(_ args: [String]) -> ProcessResult? {
        if args.starts(with: ["list"]) {
            return ok(listJSON())
        }
        if args.starts(with: ["volume", "list"]) {
            return ok(try! JSONSerialization.data(withJSONObject: volumes.map { ["name": $0] }))
        }
        if args.starts(with: ["volume", "create"]) {
            return volumeCreateFails ? fail("volume create failed") : ok(Data())
        }
        if args.starts(with: ["image", "inspect"]) {
            let ref = args.last ?? ""
            // Derived tags exist only when explicitly listed (Features reuse).
            if ref.hasPrefix("adev-") || ref.hasPrefix("adevcontainer:") {
                guard existingImages.contains(ref) else { return fail("missing") }
            }
            if ref == RecoveryHelper.helperImageReference {
                guard existingImages.contains(ref) else { return fail("missing") }
                let object: [String: Any] = [
                    "configuration": [
                        "name": ref,
                        "variants": [[
                            "digest": RecoveryHelper.helperImageDigest,
                            "platform": ["os": "linux", "architecture": "arm64", "variant": "v8"]
                        ]]
                    ]
                ]
                return ok(try! JSONSerialization.data(withJSONObject: [object]))
            }
            // Base / config / derived (when present): Apple-shaped JSON with USER for resolution.
            let payload = MockProcessRunner.imageInspectJSON(reference: ref, user: "vscode")
            return ok(try! JSONSerialization.data(withJSONObject: payload))
        }
        if args.first == "start" {
            return startFails ? fail("start failed") : ok(Data())
        }
        if args.first == "delete" {
            return deleteFails ? fail("delete failed") : ok(Data())
        }
        if args.first == "build" {
            return buildFails ? fail("build failed") : ok(Data())
        }
        if args.starts(with: ["image", "pull"]) {
            return ok(Data())
        }
        if args.first == "create" {
            return createFails ? fail("create failed") : ok(Data("\(newContainerId)\n".utf8))
        }
        if args.first == "exec" {
            return execResult(args)
        }
        return nil
    }

    private func execResult(_ args: [String]) -> ProcessResult {
        if args.contains("cat") {
            return ProcessResult(exitCode: 0, stdout: Data(volumeConfigText.utf8), stderr: Data())
        }
        if args.contains("test"), args.contains("-d") {
            let path = args.last ?? ""
            if path.hasSuffix(".devcontainer") {
                return guestDevcontainerExists ? ok(Data()) : fail("missing")
            }
        }
        if args.contains("tar"), args.contains("cf") {
            return ProcessResult(exitCode: 0, stdout: guestDevcontainerTar ?? Data(), stderr: Data())
        }
        if let script = args.last,
           failingExecSubstrings.contains(where: { script.contains($0) }) {
            return ProcessResult(exitCode: 1, stdout: Data(), stderr: Data("script failed".utf8))
        }
        return ok(Data())
    }

    private func listJSON() -> Data {
        let arr = containers.map { c -> [String: Any] in
            [
                "id": c.id,
                "configuration": [
                    "id": c.id,
                    "image": c.image ?? "",
                    "labels": c.labels
                ],
                "status": ["state": c.state]
            ]
        }
        return try! JSONSerialization.data(withJSONObject: arr)
    }

    private func ok(_ data: Data) -> ProcessResult {
        ProcessResult(exitCode: 0, stdout: data, stderr: Data())
    }

    private func fail(_ stderr: String) -> ProcessResult {
        ProcessResult(exitCode: 1, stdout: Data(), stderr: Data(stderr.utf8))
    }
}

final class RebuildIdentityReaderFixture: RebuildLocalIdentityReader, @unchecked Sendable {
    var hostIdentity = GitAuthorIdentity()
    var guestIdentity = GitAuthorIdentity()
    var hostPaths: [String] = []
    var guestCalls: [(containerId: String, workspaceFolder: String, user: String?)] = []
    var onHostRead: (() -> Void)?
    var onGuestRead: (() -> Void)?

    func readHostWorkspace(path: String) -> GitAuthorIdentity {
        hostPaths.append(path)
        onHostRead?()
        return hostIdentity
    }

    func readOldContainerWorkspace(
        containerId: String,
        workspaceFolder: String,
        user: String?,
        runtime: AppleContainerRuntime
    ) -> GitAuthorIdentity {
        guestCalls.append((containerId, workspaceFolder, user))
        onGuestRead?()
        return guestIdentity
    }
}

func withRebuildIdentityReader(
    _ reader: any RebuildLocalIdentityReader,
    _ body: () throws -> Void
) throws {
    let previous = RebuildCommand.localIdentityReaderOverride
    RebuildCommand.localIdentityReaderOverride = reader
    defer { RebuildCommand.localIdentityReaderOverride = previous }
    try body()
}

// MARK: - Test doubles

/// Non-interactive picker (`selectionRequired` on multiple containers).
func rebuildNonInteractivePicker() -> InteractivePicker {
    InteractivePicker(isInteractive: false, readLine: { nil })
}

/// Interactive picker that selects the container at `index` (1-based, as printed).
func rebuildPickIndexPicker(_ index: Int) -> InteractivePicker {
    InteractivePicker(isInteractive: true, readLine: { "\(index)" })
}

/// Build the OrderedFeature the FeaturesRunner would construct for `ref` from the fixture,
/// so the derived tag computed in tests matches the implementation's.
func rebuildOrderedFeature(
    ref: String,
    fixture: String,
    options: [String: FeatureOptionValue] = [:]
) throws -> FeatureOrder.OrderedFeature {
    let metaURL = URL(filePath: fixture).appendingPathComponent("devcontainer-feature.json")
    let metadata = try FeatureMetadata.parse(
        data: try Data(contentsOf: metaURL),
        featureRef: ref
    )
    return FeatureOrder.OrderedFeature(
        admitted: AdmittedFeature(reference: ref, options: options),
        metadata: metadata
    )
}

final class RecordingGuestOps: VSCodeGuestOperating, @unchecked Sendable {
    var home = "/home/user"
    var existingText: String?
    var lastWrite: String?
    var writes: [String] = []
    var dirsEnsured: [String] = []
    var onWrite: ((String) -> Void)?

    func resolveHome(containerId: String, user: String?) throws -> String { home }
    func readTextFile(containerId: String, path: String, user: String?) throws -> String? { existingText }
    func writeTextFile(containerId: String, path: String, contents: String, user: String?) throws {
        lastWrite = "\(path):\(contents)"
        writes.append("\(path):\(contents)")
        onWrite?(path)
    }
    func ensureDirectory(containerId: String, path: String, user: String?) throws {
        dirsEnsured.append(path)
    }
    func listDirectoryNames(containerId: String, path: String, user: String?) throws -> [String] { [] }
    func removeFile(containerId: String, path: String, user: String?) throws {}
    func unpackZip(containerId: String, zipData: Data, destDir: String, user: String?) throws {}
    func resolveMarketplaceTargetPlatform(containerId: String, user: String?) throws -> String {
        "linux-arm64"
    }
}

struct StubVSIXDownloader: VSCodeVSIXDownloading {
    func fetchVSIX(extensionId: String, targetPlatform: String) throws -> VSCodeVSIXArtifact {
        VSCodeVSIXArtifact(data: Data(), installFolderName: "\(extensionId)-1.0.0")
    }
}

/// Save/restore the RebuildCommand feature overrides around a test body.
func withRebuildFeatureOverrides(
    fetcher: any FeatureFetching,
    cache: String,
    _ body: () throws -> Void
) throws {
    let prevFetcher = RebuildCommand.featuresFetcherOverride
    let prevCache = RebuildCommand.featuresCacheRootOverride
    let prevEnsure = RebuildCommand.ensureNativeArmBuildOverride
    RebuildCommand.featuresFetcherOverride = fetcher
    RebuildCommand.featuresCacheRootOverride = cache
    RebuildCommand.ensureNativeArmBuildOverride = { /* no-op: already native in tests */ }
    defer {
        RebuildCommand.featuresFetcherOverride = prevFetcher
        RebuildCommand.featuresCacheRootOverride = prevCache
        RebuildCommand.ensureNativeArmBuildOverride = prevEnsure
    }
    try body()
}

/// Host-side `tar cf -` of a `.devcontainer/` tree for volume-mode initialize tests.
func makeGuestDevcontainerArchive(files: [String: String]) throws -> Data {
    let root = FileManager.default.temporaryDirectory
        .appendingPathComponent("adev-init-tar-\(UUID().uuidString)", isDirectory: true)
    defer { try? FileManager.default.removeItem(at: root) }
    let dc = root.appendingPathComponent(".devcontainer", isDirectory: true)
    try FileManager.default.createDirectory(at: dc, withIntermediateDirectories: true)
    for (relative, contents) in files {
        let url = dc.appendingPathComponent(relative)
        try FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try contents.write(to: url, atomically: true, encoding: .utf8)
    }
    let result = try FoundationProcessRunner().run(
        executable: "/usr/bin/tar",
        arguments: ["cf", "-", "-C", root.path, ".devcontainer"],
        environment: nil,
        currentDirectory: nil
    )
    guard result.succeeded, !result.stdout.isEmpty else {
        throw MiniTest.Failure(message: "failed to build guest .devcontainer archive")
    }
    return result.stdout
}

/// Feature overrides for volume-mode scenarios: volume mode injects the git feature,
/// so map the git ref to the sample fixture and no-op the native-arm rosetta probe.
func withRebuildVolumeOverrides(_ body: () throws -> Void) throws {
    let cache = FileManager.default.temporaryDirectory
        .appendingPathComponent("feat-rebuild-vol-\(UUID().uuidString)", isDirectory: true).path
    defer { try? FileManager.default.removeItem(atPath: cache) }
    try withRebuildFeatureOverrides(
        fetcher: MockFeatureFetcher(packagesByRef: [
            FeatureGitEnsure.gitFeatureRef: TestRepo.root()
                .appendingPathComponent("Tests/Fixtures/features-sample/sample-a").path
        ]),
        cache: cache
    ) {
        try body()
    }
}

/// Save/restore VSCodeCustomizationsApply guest/downloader overrides.
func withRebuildCustomizationsOverrides(
    guest: VSCodeGuestOperating,
    downloader: VSCodeVSIXDownloading = StubVSIXDownloader(),
    _ body: () throws -> Void
) throws {
    let prevGuest = VSCodeCustomizationsApply.guestOverride
    let prevDownloader = VSCodeCustomizationsApply.downloaderOverride
    VSCodeCustomizationsApply.guestOverride = guest
    VSCodeCustomizationsApply.downloaderOverride = downloader
    defer {
        VSCodeCustomizationsApply.guestOverride = prevGuest
        VSCodeCustomizationsApply.downloaderOverride = prevDownloader
    }
    try body()
}

/// Records fetch refs in order, delegating to a MockFeatureFetcher.
final class RecordingFeatureFetcher: FeatureFetching, @unchecked Sendable {
    let inner: MockFeatureFetcher
    var recorded: [String] = []

    init(inner: MockFeatureFetcher) {
        self.inner = inner
    }

    func fetch(reference: String, destinationDirectory: String) throws -> FetchedFeaturePackage {
        recorded.append(reference)
        return try inner.fetch(reference: reference, destinationDirectory: destinationDirectory)
    }
}

/// Save/restore the VSCodeOpen overrides (same contract as VSCodeOpenTests' private support).
enum RebuildOpenSupport {
    static func install(
        launcher: MockVSCodeLauncher,
        resolverPath: String? = "/usr/local/bin/code"
    ) -> () -> Void {
        let prevLauncher = VSCodeOpen.launcherOverride
        let prevResolver = VSCodeOpen.resolverOverride
        let prevRoot = VSCodeOpen.nameConfigRootOverride
        let prevWrite = VSCodeOpen.writeNameConfigEnabled
        VSCodeOpen.launcherOverride = launcher
        VSCodeOpen.resolverOverride = MockVSCodeResolver(path: resolverPath)
        VSCodeOpen.nameConfigRootOverride = nil
        VSCodeOpen.writeNameConfigEnabled = false
        return {
            VSCodeOpen.launcherOverride = prevLauncher
            VSCodeOpen.resolverOverride = prevResolver
            VSCodeOpen.nameConfigRootOverride = prevRoot
            VSCodeOpen.writeNameConfigEnabled = prevWrite
        }
    }
}

// MARK: - Sections 3–5 tests

nonisolated(unsafe) let rebuildPhaseTests: [(String, () throws -> Void)] = [
    // ═══════════════════════ Section 3: Phase A (non-destructive gate) ═══════════════════════

    ("rebuildSelectsSingleManagedContainerAndRebuilds", {
        let ws = try TestRepo.makeTempWorkspace(configJSON: #"{"image":"alpine:3.20","remoteUser":"vscode"}"#)
        defer { try? FileManager.default.removeItem(at: ws) }
        let s = RebuildScenario()
        let info = RebuildScenario.container(
            id: "adev-mybase-abc123def456",
            labels: s.bindLabels(
                localFolder: ws.path,
                configFile: ws.appendingPathComponent(".devcontainer/devcontainer.json").path
            )
        )
        s.containers = [info]
        s.install()
        let result = try RebuildCommand.run(options: RebuildOptions(), runtime: s.runtime)
        try MiniTest.expectEqual(result.outcome, "success")
        try MiniTest.expectEqual(result.containerId, s.newContainerId)
        let expectedName = ContainerIdentity.containerName(
            workspacePath: ws.path,
            configPath: ws.appendingPathComponent(".devcontainer/devcontainer.json").path,
            configName: nil
        )
        try MiniTest.expectEqual(result.containerName, expectedName)
        let deletes = s.mock.calls.filter { $0.arguments.first == "delete" }
        try MiniTest.expectEqual(deletes.count, 1, "old container deleted exactly once")
        try MiniTest.expectEqual(deletes.first?.arguments.last, info.id)
        let creates = s.mock.calls.filter { $0.arguments.first == "create" }
        try MiniTest.expectEqual(creates.count, 1, "new container created once")
        let createArgs = creates[0].arguments
        try MiniTest.expect(createArgs.contains(expectedName), "create uses live computed name")
    }),

    ("rebuildFailsContainerNotFoundNoDelete", {
        let ws = try TestRepo.makeTempWorkspace(configJSON: #"{"image":"alpine:3.20"}"#)
        defer { try? FileManager.default.removeItem(at: ws) }
        let s = RebuildScenario()
        let info = RebuildScenario.container(
            id: "other-id",
            labels: s.bindLabels(
                localFolder: ws.path,
                configFile: ws.appendingPathComponent(".devcontainer/devcontainer.json").path
            )
        )
        s.containers = [info]
        s.install()
        try MiniTest.expectThrows({
            _ = try RebuildCommand.run(options: RebuildOptions(name: "missing"), runtime: s.runtime)
        }, validate: { err in
            try MiniTest.expectEqual(rebuildErrorCode(err), CLIErrorCode.containerNotFound)
        })
        try MiniTest.expect(!s.mock.calls.contains { $0.arguments.first == "delete" }, "no delete on missing name")
        try MiniTest.expect(!s.mock.calls.contains { $0.arguments.first == "create" }, "no create on missing name")
    }),

    ("rebuildMultipleNonInteractiveRequiresName", {
        let ws = try TestRepo.makeTempWorkspace(configJSON: #"{"image":"alpine:3.20"}"#)
        defer { try? FileManager.default.removeItem(at: ws) }
        let s = RebuildScenario()
        let labels = s.bindLabels(
            localFolder: ws.path,
            configFile: ws.appendingPathComponent(".devcontainer/devcontainer.json").path
        )
        s.containers = [
            RebuildScenario.container(id: "a", labels: labels),
            RebuildScenario.container(id: "b", labels: labels)
        ]
        s.install()
        try MiniTest.expectThrows({
            _ = try RebuildCommand.run(options: RebuildOptions(), runtime: s.runtime, picker: rebuildNonInteractivePicker())
        }, validate: { err in
            try MiniTest.expectEqual(rebuildErrorCode(err), CLIErrorCode.selectionRequired)
        })
        try MiniTest.expect(!s.mock.calls.contains { $0.arguments.first == "delete" }, "no delete without selection")
    }),

    ("rebuildPickerSelectsForMultiple", {
        let ws = try TestRepo.makeTempWorkspace(configJSON: #"{"image":"alpine:3.20"}"#)
        defer { try? FileManager.default.removeItem(at: ws) }
        let s = RebuildScenario()
        let labels = s.bindLabels(
            localFolder: ws.path,
            configFile: ws.appendingPathComponent(".devcontainer/devcontainer.json").path
        )
        s.containers = [
            RebuildScenario.container(id: "a", labels: labels),
            RebuildScenario.container(id: "b", labels: labels)
        ]
        s.install()
        _ = try RebuildCommand.run(options: RebuildOptions(), runtime: s.runtime, picker: rebuildPickIndexPicker(2))
        let deletes = s.mock.calls.filter { $0.arguments.first == "delete" }
        try MiniTest.expectEqual(deletes.count, 1)
        try MiniTest.expectEqual(deletes.first?.arguments.last, "b", "delete picked container")
    }),

    ("rebuildVolumeStoppedBareStartBeforeRead", {
        let s = RebuildScenario()
        let info = RebuildScenario.container(id: "vol-old", state: "stopped", labels: s.volumeLabels())
        s.containers = [info]
        s.install()
        try withRebuildVolumeOverrides {
            _ = try RebuildCommand.run(options: RebuildOptions(skipPull: true), runtime: s.runtime)
        }
        let calls = s.mock.calls.map(\.arguments)
        let startIdx = calls.firstIndex { $0.first == "start" }
        let catIdx = calls.firstIndex { $0.contains("cat") }
        let deleteIdx = calls.firstIndex { $0.first == "delete" }
        try MiniTest.expect(startIdx != nil, "bare start of old volume container")
        try MiniTest.expect(catIdx != nil, "config cat read")
        try MiniTest.expect(deleteIdx != nil, "old container deleted")
        try MiniTest.expect(startIdx! < catIdx!, "start before config cat")
        try MiniTest.expect(catIdx! < deleteIdx!, "config read before delete")
        let preDelete = calls.prefix(deleteIdx!)
        try MiniTest.expect(
            !preDelete.contains { $0.first == "exec" && $0.contains("sh") },
            "no lifecycle hooks on old container before delete"
        )
    }),

    ("rebuildVolumeStartFailureNoDelete", {
        let s = RebuildScenario()
        let info = RebuildScenario.container(id: "vol-old", state: "stopped", labels: s.volumeLabels())
        s.containers = [info]
        s.startFails = true
        s.install()
        try MiniTest.expectThrows({
            _ = try RebuildCommand.run(options: RebuildOptions(skipPull: true), runtime: s.runtime)
        }, validate: { err in
            try MiniTest.expect(rebuildErrorCode(err) != nil, "runtime error surfaced")
        })
        try MiniTest.expect(!s.mock.calls.contains { $0.arguments.first == "delete" }, "no delete after old start failure")
    }),

    ("rebuildStrictBindMissingFileFailsBeforeDelete", {
        let ws = try TestRepo.makeTempWorkspace(configJSON: #"{"image":"alpine:3.20"}"#)
        defer { try? FileManager.default.removeItem(at: ws) }
        let s = RebuildScenario()
        let missing = ws.appendingPathComponent(".devcontainer/gone.json").path
        let info = RebuildScenario.container(id: "old-id", labels: s.bindLabels(localFolder: ws.path, configFile: missing))
        s.containers = [info]
        s.install()
        try MiniTest.expectThrows({
            _ = try RebuildCommand.run(options: RebuildOptions(), runtime: s.runtime)
        }, validate: { err in
            try MiniTest.expectEqual(rebuildErrorCode(err), CLIErrorCode.configNotFound)
        })
        try MiniTest.expect(!s.mock.calls.contains { $0.arguments.first == "delete" }, "no delete on strict read miss")
        try MiniTest.expect(!s.mock.calls.contains { $0.arguments.first == "create" }, "no create on strict read miss")
    }),

    ("rebuildStrictVolumeUnparseableFailsBeforeDelete", {
        let s = RebuildScenario()
        let info = RebuildScenario.container(id: "vol-old", labels: s.volumeLabels())
        s.containers = [info]
        s.volumeConfigText = "{ not json"
        s.install()
        try MiniTest.expectThrows({
            _ = try RebuildCommand.run(options: RebuildOptions(skipPull: true), runtime: s.runtime)
        }, validate: { err in
            try MiniTest.expectEqual(rebuildErrorCode(err), CLIErrorCode.configParse)
        })
        try MiniTest.expect(!s.mock.calls.contains { $0.arguments.first == "delete" }, "no delete on parse failure")
        try MiniTest.expect(!s.mock.calls.contains { $0.arguments.first == "create" }, "no create on parse failure")
    }),

    ("rebuildHostRequirementsShortfallFailsBeforeDelete", {
        let ws = try TestRepo.makeTempWorkspace(configJSON: #"{"image":"alpine:3.20","hostRequirements":{"memory":"8gb"}}"#)
        defer { try? FileManager.default.removeItem(at: ws) }
        let s = RebuildScenario()
        let info = RebuildScenario.container(
            id: "old-id",
            labels: s.bindLabels(
                localFolder: ws.path,
                configFile: ws.appendingPathComponent(".devcontainer/devcontainer.json").path
            )
        )
        s.containers = [info]
        s.install()
        let tiny = MockHostResourceInfo(physicalMemoryBytes: 1_073_741_824, cpuCount: 1)
        try MiniTest.expectThrows({
            _ = try RebuildCommand.run(options: RebuildOptions(), runtime: s.runtime, hostResources: tiny)
        }, validate: { err in
            try MiniTest.expectEqual(rebuildErrorCode(err), CLIErrorCode.hostRequirements)
        })
        try MiniTest.expect(!s.mock.calls.contains { $0.arguments.first == "delete" }, "no delete on host shortfall")
    }),

    ("rebuildFeaturesBuildFailureFailsBeforeDelete", {
        let ref = "ghcr.io/adevcontainer/features/sample-a:1"
        let fixture = TestRepo.root()
            .appendingPathComponent("Tests/Fixtures/features-sample/sample-a").path
        let cache = FileManager.default.temporaryDirectory
            .appendingPathComponent("feat-rebuild-\(UUID().uuidString)", isDirectory: true).path
        defer { try? FileManager.default.removeItem(atPath: cache) }
        let ws = try TestRepo.makeTempWorkspace(configJSON: """
        {
          "image": "alpine:3.20",
          "features": { "\(ref)": { "greeting": "hi" } }
        }
        """)
        defer { try? FileManager.default.removeItem(at: ws) }
        let s = RebuildScenario()
        let info = RebuildScenario.container(
            id: "adev-mybase-abc123def456",
            labels: s.bindLabels(
                localFolder: ws.path,
                configFile: ws.appendingPathComponent(".devcontainer/devcontainer.json").path
            )
        )
        s.containers = [info]
        s.buildFails = true
        s.install()
        try withRebuildFeatureOverrides(
            fetcher: MockFeatureFetcher(packagesByRef: [ref: fixture]),
            cache: cache
        ) {
            try MiniTest.expectThrows({
                _ = try RebuildCommand.run(options: RebuildOptions(), runtime: s.runtime)
            }, validate: { err in
                try MiniTest.expectEqual(rebuildErrorCode(err), CLIErrorCode.featureBuild)
            })
        }
        let builds = s.mock.calls.filter { $0.arguments.first == "build" }
        try MiniTest.expectEqual(builds.count, 1, "feature build attempted once")
        try MiniTest.expect(!s.mock.calls.contains { $0.arguments.first == "delete" }, "no delete on build failure")
    }),

    ("rebuildRosettaConsentInvoked", {
        let ref = "ghcr.io/adevcontainer/features/sample-a:1"
        let fixture = TestRepo.root()
            .appendingPathComponent("Tests/Fixtures/features-sample/sample-a").path
        let cache = FileManager.default.temporaryDirectory
            .appendingPathComponent("feat-rebuild-\(UUID().uuidString)", isDirectory: true).path
        defer { try? FileManager.default.removeItem(atPath: cache) }
        let ws = try TestRepo.makeTempWorkspace(configJSON: """
        {
          "image": "alpine:3.20",
          "features": { "\(ref)": {} }
        }
        """)
        defer { try? FileManager.default.removeItem(at: ws) }
        let s = RebuildScenario()
        let info = RebuildScenario.container(
            id: "adev-mybase-abc123def456",
            labels: s.bindLabels(
                localFolder: ws.path,
                configFile: ws.appendingPathComponent(".devcontainer/devcontainer.json").path
            )
        )
        s.containers = [info]
        s.install()
        let counter = RebuildCounter()
        try withRebuildFeatureOverrides(
            fetcher: MockFeatureFetcher(packagesByRef: [ref: fixture]),
            cache: cache
        ) {
            let prevEnsure = RebuildCommand.ensureNativeArmBuildOverride
            RebuildCommand.ensureNativeArmBuildOverride = { counter.count += 1 }
            defer { RebuildCommand.ensureNativeArmBuildOverride = prevEnsure }
            _ = try RebuildCommand.run(options: RebuildOptions(), runtime: s.runtime)
        }
        try MiniTest.expectEqual(counter.count, 1, "rosetta consent invoked once")
    }),

    ("rebuildFeaturesReusesDerivedTagWhenUnchanged", {
        let ref = "ghcr.io/adevcontainer/features/sample-a:1"
        let fixture = TestRepo.root()
            .appendingPathComponent("Tests/Fixtures/features-sample/sample-a").path
        let cache = FileManager.default.temporaryDirectory
            .appendingPathComponent("feat-rebuild-\(UUID().uuidString)", isDirectory: true).path
        defer { try? FileManager.default.removeItem(atPath: cache) }
        let ws = try TestRepo.makeTempWorkspace(configJSON: """
        {
          "image": "alpine:3.20",
          "features": { "\(ref)": { "greeting": "hi" } }
        }
        """)
        defer { try? FileManager.default.removeItem(at: ws) }
        let fetcher = MockFeatureFetcher(packagesByRef: [ref: fixture])
        let nameBase = ContainerIdentity.humanBase(workspacePath: ws.path)
        let derivedTag = DerivedImageTag.compute(
            baseImage: "alpine:3.20",
            ordered: [try rebuildOrderedFeature(ref: ref, fixture: fixture, options: ["greeting": .string("hi")])],
            nameBase: nameBase
        )
        let s = RebuildScenario()
        let info = RebuildScenario.container(
            id: "adev-mybase-abc123def456",
            labels: s.bindLabels(
                localFolder: ws.path,
                configFile: ws.appendingPathComponent(".devcontainer/devcontainer.json").path
            )
        )
        s.containers = [info]
        s.existingImages = [derivedTag]
        s.install()
        try withRebuildFeatureOverrides(fetcher: fetcher, cache: cache) {
            _ = try RebuildCommand.run(options: RebuildOptions(), runtime: s.runtime)
        }
        try MiniTest.expect(!s.mock.calls.contains { $0.arguments.first == "build" }, "no rebuild of unchanged feature tag (expected \(derivedTag) reused; image inspect was called for: \(s.mock.calls.filter { $0.arguments.starts(with: ["image", "inspect"]) }.map(\.arguments))")
        try MiniTest.expectEqual(fetcher.fetchCalls.count, 1, "feature fetched once for contributions")
        let creates = s.mock.calls.filter { $0.arguments.first == "create" }
        try MiniTest.expect(creates[0].arguments.contains(derivedTag), "create uses derived image tag")
    }),

    ("rebuildFeaturesBuildsWhenTagAbsent", {
        let ref = "ghcr.io/adevcontainer/features/sample-a:1"
        let fixture = TestRepo.root()
            .appendingPathComponent("Tests/Fixtures/features-sample/sample-a").path
        let cache = FileManager.default.temporaryDirectory
            .appendingPathComponent("feat-rebuild-\(UUID().uuidString)", isDirectory: true).path
        defer { try? FileManager.default.removeItem(atPath: cache) }
        let ws = try TestRepo.makeTempWorkspace(configJSON: """
        {
          "image": "alpine:3.20",
          "features": { "\(ref)": { "greeting": "hi" } }
        }
        """)
        defer { try? FileManager.default.removeItem(at: ws) }
        let fetcher = MockFeatureFetcher(packagesByRef: [ref: fixture])
        let nameBase = ContainerIdentity.humanBase(workspacePath: ws.path)
        let derivedTag = DerivedImageTag.compute(
            baseImage: "alpine:3.20",
            ordered: [try rebuildOrderedFeature(ref: ref, fixture: fixture, options: ["greeting": .string("hi")])],
            nameBase: nameBase
        )
        let s = RebuildScenario()
        let info = RebuildScenario.container(
            id: "adev-mybase-abc123def456",
            labels: s.bindLabels(
                localFolder: ws.path,
                configFile: ws.appendingPathComponent(".devcontainer/devcontainer.json").path
            )
        )
        s.containers = [info]
        s.install()
        try withRebuildFeatureOverrides(fetcher: fetcher, cache: cache) {
            _ = try RebuildCommand.run(options: RebuildOptions(), runtime: s.runtime)
        }
        let builds = s.mock.calls.filter { $0.arguments.first == "build" }
        let orderedFeature = try rebuildOrderedFeature(ref: ref, fixture: fixture, options: ["greeting": .string("hi")])
        let buildTag = builds.first?.arguments.drop(while: { $0 != "-t" }).dropFirst().first ?? "<none>"
        try MiniTest.expectEqual(buildTag, derivedTag, "build tag == test-computed tag (id=\(orderedFeature.metadata.id), myTag=\(derivedTag))")
        let creates = s.mock.calls.filter { $0.arguments.first == "create" }
        try MiniTest.expect(creates[0].arguments.contains(derivedTag), "create uses derived image tag")
    }),

    ("rebuildSkipPullSuppressesPull", {
        let ws = try TestRepo.makeTempWorkspace(configJSON: #"{"image":"alpine:3.20"}"#)
        defer { try? FileManager.default.removeItem(at: ws) }
        let s = RebuildScenario()
        let info = RebuildScenario.container(
            id: "old-id",
            labels: s.bindLabels(
                localFolder: ws.path,
                configFile: ws.appendingPathComponent(".devcontainer/devcontainer.json").path
            )
        )
        s.containers = [info]
        s.install()
        _ = try RebuildCommand.run(options: RebuildOptions(skipPull: true), runtime: s.runtime)
        try MiniTest.expect(!s.mock.calls.contains { $0.arguments.starts(with: ["image", "pull"]) }, "skip-pull suppresses pull")
    }),

    ("rebuildPullsByDefault", {
        let ws = try TestRepo.makeTempWorkspace(configJSON: #"{"image":"alpine:3.20"}"#)
        defer { try? FileManager.default.removeItem(at: ws) }
        let s = RebuildScenario()
        let info = RebuildScenario.container(
            id: "old-id",
            labels: s.bindLabels(
                localFolder: ws.path,
                configFile: ws.appendingPathComponent(".devcontainer/devcontainer.json").path
            )
        )
        s.containers = [info]
        s.install()
        _ = try RebuildCommand.run(options: RebuildOptions(), runtime: s.runtime)
        try MiniTest.expect(s.mock.calls.contains { $0.arguments.starts(with: ["image", "pull"]) }, "pull by default")
    }),

    // ═══════════════════════ Section 4: Phase B (destructive create path) ═══════════════════════

    ("rebuildBindKeepsNameAndPreservesLabelsWithDriftUpdates", {
        let ws = try TestRepo.makeTempWorkspace(configJSON: """
        {
          "image": "alpine:3.20",
          "remoteUser": "vscode",
          "workspaceFolder": "/workspaces/new"
        }
        """)
        defer { try? FileManager.default.removeItem(at: ws) }
        let s = RebuildScenario()
        var labels = s.bindLabels(
            localFolder: ws.path,
            configFile: ws.appendingPathComponent(".devcontainer/devcontainer.json").path
        )
        labels["x.keep"] = "yes"
        let info = RebuildScenario.container(id: "adev-mybase-abc123def456", labels: labels)
        s.containers = [info]
        s.install()
        _ = try RebuildCommand.run(options: RebuildOptions(), runtime: s.runtime)
        let cfgFile = ws.appendingPathComponent(".devcontainer/devcontainer.json").path
        let expectedName = ContainerIdentity.containerName(
            workspacePath: ws.path,
            configPath: cfgFile,
            configName: nil
        )
        let createArgs = s.mock.calls.first { $0.arguments.first == "create" }!.arguments
        try MiniTest.expect(createArgs.contains(expectedName), "create uses live computed name")
        try MiniTest.expect(createArgs.contains("devcontainer.managed=adevcontainer"), "managed label preserved")
        try MiniTest.expect(createArgs.contains("devcontainer.workspace_mode=bind"), "workspace_mode label preserved")
        try MiniTest.expect(createArgs.contains("devcontainer.local_folder=\(ws.path)"), "local_folder preserved")
        try MiniTest.expect(createArgs.contains("devcontainer.config_file=\(cfgFile)"), "config_file preserved")
        try MiniTest.expect(createArgs.contains("devcontainer.workspace_folder=/workspaces/new"), "workspace_folder drift-updated")
        try MiniTest.expect(createArgs.contains("devcontainer.remote_user=vscode"), "remote_user drift-updated")
        try MiniTest.expect(createArgs.contains("x.keep=yes"), "unknown labels preserved verbatim")
        let hash = createArgs.first { $0.hasPrefix("devcontainer.config_hash=") }!
        try MiniTest.expect(hash != "devcontainer.config_hash=oldhash", "config_hash drift-updated")
    }),

    ("rebuildEqualHashStillRuns", {
        let ws = try TestRepo.makeTempWorkspace(configJSON: #"{"image":"alpine:3.20"}"#)
        defer { try? FileManager.default.removeItem(at: ws) }
        let s = RebuildScenario()
        let info = RebuildScenario.container(
            id: "old-id",
            labels: s.bindLabels(
                localFolder: ws.path,
                configFile: ws.appendingPathComponent(".devcontainer/devcontainer.json").path
            )
        )
        s.containers = [info]
        s.install()
        _ = try RebuildCommand.run(options: RebuildOptions(), runtime: s.runtime)
        try MiniTest.expect(s.mock.calls.contains { $0.arguments.first == "delete" }, "rebuild deletes with equal hash")
        try MiniTest.expect(s.mock.calls.contains { $0.arguments.first == "create" }, "rebuild creates with equal hash")
    }),

    ("rebuildVolumePreservesWorkspaceVolumeAndGitUrl", {
        let s = RebuildScenario()
        let info = RebuildScenario.container(id: "adev-repo-123456789abc", labels: s.volumeLabels())
        s.containers = [info]
        s.volumes = ["adev-repo-ws"]
        s.install()
        var rebuildResult: RebuildResult?
        try withRebuildVolumeOverrides {
            rebuildResult = try RebuildCommand.run(options: RebuildOptions(skipPull: true), runtime: s.runtime)
        }
        let result = rebuildResult!
        try MiniTest.expectEqual(result.workspaceVolume, "adev-repo-ws")
        try MiniTest.expectEqual(result.gitUrl, "https://github.com/example/repo.git")
        try MiniTest.expect(!s.mock.calls.contains { $0.arguments.starts(with: ["volume", "create"]) }, "workspace volume was not created")
        try MiniTest.expect(!s.mock.calls.contains { $0.arguments.starts(with: ["volume", "delete"]) }, "workspace volume never deleted")
        let createArgs = s.mock.calls.first { $0.arguments.first == "create" }!.arguments
        try MiniTest.expect(createArgs.contains { $0.contains("adev-repo-ws") }, "create mounts existing workspace volume")
    }),

    ("rebuildNamedRecoveryRetryStripsHelperMarkers", {
        let rawBytes = Data(#"{"image":"alpine:3.20","remoteUser":"vscode"}"#.utf8)
        let sessionID = "retry-marker-\(String(UUID().uuidString.prefix(8)).lowercased())"
        let helperLabels: [String: String] = [
            ContainerIdentity.labelManaged: ContainerIdentity.managedValue,
            ContainerIdentity.labelWorkspaceMode: ContainerIdentity.workspaceModeVolume,
            ContainerIdentity.labelGitURL: "https://github.com/example/repo.git",
            ContainerIdentity.labelWorkspaceVolume: "adev-repo-ws",
            ContainerIdentity.labelConfigFile: ".devcontainer/devcontainer.json",
            ContainerIdentity.labelWorkspaceFolder: "/workspaces/repo",
            ContainerIdentity.labelConfigHash: "old-hash",
            ContainerIdentity.labelRemoteUser: "vscode",
            RecoveryHelper.recoveryMarkerLabel: RecoveryHelper.recoveryMarkerValue,
            RecoveryHelper.recoverySessionLabel: sessionID,
            RecoveryHelper.recoveryForLabel: "adev-repo-123456789abc",
            "devcontainer.recovery_future": "must-not-leak"
        ]
        let helper = ContainerInfo(
            id: "adev-repo-123456789abc",
            name: "adev-repo-123456789abc",
            state: "running",
            labels: helperLabels,
            image: RecoveryHelper.helperImageReference
        )
        let raw = RawVolumeConfig(
            bytes: rawBytes,
            pathInContainer: "/workspaces/repo/.devcontainer/devcontainer.json",
            workspaceFolder: "/workspaces/repo",
            workspaceFolderBasename: "repo"
        )
        let session = try RecoveryConfigSession(
            rawVolumeConfig: raw,
            targetContainerID: "old-id",
            targetContainerName: helper.name,
            workspaceVolume: "adev-repo-ws",
            configFile: ".devcontainer/devcontainer.json",
            sessionID: sessionID
        )
        defer { try? session.cleanup() }
        let conflictBytes = Data(#"{"image":"alpine:3.20","name":"conflict-baseline"}"#.utf8)
        let conflictRunner = MockProcessRunner()
        conflictRunner.handlers = [{ args in
            guard args.first == "exec", args.contains("cat") else { return nil }
            return ProcessResult(exitCode: 0, stdout: conflictBytes, stderr: Data())
        }]
        let conflictRuntime = AppleContainerRuntime(executablePath: "container", runner: conflictRunner)
        do {
            _ = try session.applyEdit(helperContainerID: helper.id, runtime: conflictRuntime)
        } catch {
            // Seed the retained session with the conflict that the JSON retry must acknowledge.
        }
        try MiniTest.expectEqual(session.conflictHash, RecoveryConfigSession.sha256Hex(conflictBytes))
        try MiniTest.expect(session.conflictFileURL != nil)

        let imageJSON: Data = {
            let object: [String: Any] = [
                "configuration": [
                    "name": RecoveryHelper.helperImageReference,
                    "variants": [[
                        "digest": RecoveryHelper.helperImageDigest,
                        "platform": ["os": "linux", "architecture": "arm64", "variant": "v8"]
                    ]]
                ]
            ]
            return try! JSONSerialization.data(withJSONObject: [object])
        }()
        let mountJSON: Data = {
            let object: [String: Any] = [
                "configuration": [
                    "id": helper.id,
                    "mounts": [[
                        "source": "/var/lib/container/volumes/adev-repo-ws.img",
                        "destination": "/workspaces/repo",
                        "options": [],
                        "type": ["volume": ["name": "adev-repo-ws"]]
                    ]]
                ]
            ]
            return try! JSONSerialization.data(withJSONObject: [object])
        }()
        var catReads = 0
        let mock = MockProcessRunner()
        mock.handlers = [{ args in
            if args.starts(with: ["list", "--all"]) {
                return ProcessResult(
                    exitCode: 0,
                    stdout: try! JSONSerialization.data(withJSONObject: [
                        MockProcessRunner.containerListJSON(
                            id: helper.id,
                            state: "running",
                            labels: helperLabels,
                            image: RecoveryHelper.helperImageReference
                        )
                    ]),
                    stderr: Data()
                )
            }
            if args.starts(with: ["volume", "list"]) {
                return ProcessResult(
                    exitCode: 0,
                    stdout: try! JSONSerialization.data(withJSONObject: [["configuration": ["name": "adev-repo-ws"]]]),
                    stderr: Data()
                )
            }
            if args.starts(with: ["image", "inspect"]) {
                return ProcessResult(exitCode: 0, stdout: args.last == RecoveryHelper.helperImageReference ? imageJSON : Data(#"{"configuration":{"labels":{}}}"#.utf8), stderr: Data())
            }
            if args == ["inspect", helper.id] {
                return ProcessResult(exitCode: 0, stdout: mountJSON, stderr: Data())
            }
            if args.first == "exec", args.contains("cat") {
                catReads += 1
                return ProcessResult(
                    exitCode: 0,
                    stdout: catReads <= 2 ? conflictBytes : rawBytes,
                    stderr: Data()
                )
            }
            if args.first == "exec", args.contains("adevcontainer-recovery-write") {
                let hash = RecoveryConfigSession.sha256Hex(rawBytes)
                return ProcessResult(exitCode: 0, stdout: Data("RECOVERY_APPLIED:\(hash)\n".utf8), stderr: Data())
            }
            if args.first == "create" {
                return ProcessResult(exitCode: 0, stdout: Data("final-id\n".utf8), stderr: Data())
            }
            if args.first == "start" || args.first == "delete" {
                return ProcessResult(exitCode: 0, stdout: Data(), stderr: Data())
            }
            return nil
        }]
        let runtime = AppleContainerRuntime(executablePath: "container", runner: mock)
        try withRebuildVolumeOverrides {
            _ = try RebuildCommand.run(
                options: RebuildOptions(name: helper.name, skipPull: true, jsonOutput: true),
                runtime: runtime
            )
        }
        guard let createArgs = mock.calls.first(where: { $0.arguments.first == "create" })?.arguments else {
            throw MiniTest.Failure(message: "final replacement create call was not recorded")
        }
        try MiniTest.expect(createArgs.contains("devcontainer.managed=adevcontainer"))
        try MiniTest.expect(!createArgs.contains { $0.hasPrefix("devcontainer.recovery") }, "recovery markers are not copied to final container")
        try MiniTest.expect(!createArgs.contains("devcontainer.recovery_for=adev-repo-123456789abc"))
        try MiniTest.expect(!FileManager.default.fileExists(atPath: session.directoryURL.path), "successful retry cleans the consumed session")
    }),

    ("rebuildNamedRecoveryRetryTTYOpensEditorBeforeWrite", {
        // First interactive named retry after non-TTY retention must open the editor before
        // applyValidatedEdit / helper delete — not silently replay the retained broken temp.
        let broken = Data(#"{"image":"alpine:3.20","postCreateCommand":"exit 42","remoteUser":"vscode"}"#.utf8)
        let fixed = Data(#"{"image":"alpine:3.20","postCreateCommand":"true","remoteUser":"vscode"}"#.utf8)
        let sessionID = "tty-named-\(String(UUID().uuidString.prefix(8)).lowercased())"
        let helperLabels: [String: String] = [
            ContainerIdentity.labelManaged: ContainerIdentity.managedValue,
            ContainerIdentity.labelWorkspaceMode: ContainerIdentity.workspaceModeVolume,
            ContainerIdentity.labelGitURL: "https://github.com/example/repo.git",
            ContainerIdentity.labelWorkspaceVolume: "adev-repo-ws",
            ContainerIdentity.labelConfigFile: ".devcontainer/devcontainer.json",
            ContainerIdentity.labelWorkspaceFolder: "/workspaces/repo",
            ContainerIdentity.labelConfigHash: "old-hash",
            ContainerIdentity.labelRemoteUser: "vscode",
            RecoveryHelper.recoveryMarkerLabel: RecoveryHelper.recoveryMarkerValue,
            RecoveryHelper.recoverySessionLabel: sessionID
        ]
        let helper = ContainerInfo(
            id: "adev-repo-123456789abc",
            name: "adev-repo-123456789abc",
            state: "running",
            labels: helperLabels,
            image: RecoveryHelper.helperImageReference
        )
        let raw = RawVolumeConfig(
            bytes: broken,
            pathInContainer: "/workspaces/repo/.devcontainer/devcontainer.json",
            workspaceFolder: "/workspaces/repo",
            workspaceFolderBasename: "repo"
        )
        let session = try RecoveryConfigSession(
            rawVolumeConfig: raw,
            targetContainerID: "old-id",
            targetContainerName: helper.name,
            workspaceVolume: "adev-repo-ws",
            configFile: ".devcontainer/devcontainer.json",
            sessionID: sessionID
        )
        defer { try? session.cleanup() }

        let imageJSON: Data = {
            let object: [String: Any] = [
                "configuration": [
                    "name": RecoveryHelper.helperImageReference,
                    "variants": [[
                        "digest": RecoveryHelper.helperImageDigest,
                        "platform": ["os": "linux", "architecture": "arm64", "variant": "v8"]
                    ]]
                ]
            ]
            return try! JSONSerialization.data(withJSONObject: [object])
        }()
        let mountJSON: Data = {
            let object: [String: Any] = [
                "configuration": [
                    "id": helper.id,
                    "mounts": [[
                        "source": "/var/lib/container/volumes/adev-repo-ws.img",
                        "destination": "/workspaces/repo",
                        "options": [],
                        "type": ["volume": ["name": "adev-repo-ws"]]
                    ]]
                ]
            ]
            return try! JSONSerialization.data(withJSONObject: [object])
        }()
        var sawWrite = false
        var editorLaunchesBeforeWrite = 0
        let editorRunner = RebuildTTYEditorRunner(bytes: fixed) { launches in
            if !sawWrite { editorLaunchesBeforeWrite = launches }
        }
        let mock = MockProcessRunner()
        mock.handlers = [{ args in
            if args.starts(with: ["list", "--all"]) {
                return ProcessResult(
                    exitCode: 0,
                    stdout: try! JSONSerialization.data(withJSONObject: [
                        MockProcessRunner.containerListJSON(
                            id: helper.id,
                            state: "running",
                            labels: helperLabels,
                            image: RecoveryHelper.helperImageReference
                        )
                    ]),
                    stderr: Data()
                )
            }
            if args.starts(with: ["volume", "list"]) {
                return ProcessResult(
                    exitCode: 0,
                    stdout: try! JSONSerialization.data(withJSONObject: [["configuration": ["name": "adev-repo-ws"]]]),
                    stderr: Data()
                )
            }
            if args.starts(with: ["image", "inspect"]) {
                return ProcessResult(
                    exitCode: 0,
                    stdout: args.last == RecoveryHelper.helperImageReference
                        ? imageJSON
                        : Data(#"{"configuration":{"labels":{}}}"#.utf8),
                    stderr: Data()
                )
            }
            if args == ["inspect", helper.id] {
                return ProcessResult(exitCode: 0, stdout: mountJSON, stderr: Data())
            }
            if args.first == "exec", args.contains("cat") {
                // Before editor apply, volume still has broken bytes; after write, fixed.
                return ProcessResult(exitCode: 0, stdout: sawWrite ? fixed : broken, stderr: Data())
            }
            if args.first == "exec", args.contains("adevcontainer-recovery-write") {
                sawWrite = true
                let hash = RecoveryConfigSession.sha256Hex(fixed)
                return ProcessResult(exitCode: 0, stdout: Data("RECOVERY_APPLIED:\(hash)\n".utf8), stderr: Data())
            }
            if args.first == "create" {
                return ProcessResult(exitCode: 0, stdout: Data("final-id\n".utf8), stderr: Data())
            }
            if args.first == "start" || args.first == "delete" {
                return ProcessResult(exitCode: 0, stdout: Data(), stderr: Data())
            }
            return nil
        }]
        let runtime = AppleContainerRuntime(executablePath: "container", runner: mock)
        let editor = RecoveryEditor(
            environment: ["VISUAL": "/test-editor"],
            runner: editorRunner,
            fallbackEditors: [],
            executableChecker: { _ in true }
        )
        try withRebuildVolumeOverrides {
            _ = try RebuildCommand.run(
                options: RebuildOptions(name: helper.name, skipPull: true),
                runtime: runtime,
                isTTY: true,
                recoveryEditor: editor
            )
        }
        try MiniTest.expectEqual(editorRunner.launches, 1, "TTY named retry launches the editor once")
        try MiniTest.expectEqual(editorLaunchesBeforeWrite, 1, "editor runs before the recovery write")
        try MiniTest.expect(sawWrite, "validated edit is written through the helper")
        try MiniTest.expect(mock.calls.contains { $0.arguments.first == "create" }, "rebuild proceeds after edit")
    }),

    ("rebuildNamedRecoveryRetryMissingWorkspaceVolumeFailsClosed", {
        let rawBytes = Data(#"{"image":"alpine:3.20","remoteUser":"vscode"}"#.utf8)
        // Unique id avoids stranded sessions from a prior failed run colliding on create.
        let sessionID = "missing-retry-volume-\(String(UUID().uuidString.prefix(8)).lowercased())"
        let helperLabels: [String: String] = [
            ContainerIdentity.labelManaged: ContainerIdentity.managedValue,
            ContainerIdentity.labelWorkspaceMode: ContainerIdentity.workspaceModeVolume,
            ContainerIdentity.labelGitURL: "https://github.com/example/repo.git",
            ContainerIdentity.labelWorkspaceVolume: "adev-repo-ws",
            ContainerIdentity.labelConfigFile: ".devcontainer/devcontainer.json",
            ContainerIdentity.labelWorkspaceFolder: "/workspaces/repo",
            ContainerIdentity.labelConfigHash: "old-hash",
            ContainerIdentity.labelRemoteUser: "vscode",
            RecoveryHelper.recoveryMarkerLabel: RecoveryHelper.recoveryMarkerValue,
            RecoveryHelper.recoverySessionLabel: sessionID
        ]
        let helper = ContainerInfo(
            id: "adev-repo-123456789abc",
            name: "adev-repo-123456789abc",
            state: "running",
            labels: helperLabels,
            image: RecoveryHelper.helperImageReference
        )
        let raw = RawVolumeConfig(
            bytes: rawBytes,
            pathInContainer: "/workspaces/repo/.devcontainer/devcontainer.json",
            workspaceFolder: "/workspaces/repo",
            workspaceFolderBasename: "repo"
        )
        let session = try RecoveryConfigSession(
            rawVolumeConfig: raw,
            targetContainerID: "old-id",
            targetContainerName: helper.name,
            workspaceVolume: "adev-repo-ws",
            configFile: ".devcontainer/devcontainer.json",
            sessionID: sessionID
        )
        defer { try? session.cleanup() }
        let imageJSON: Data = {
            let object: [String: Any] = [
                "configuration": [
                    "name": RecoveryHelper.helperImageReference,
                    "variants": [[
                        "digest": RecoveryHelper.helperImageDigest,
                        "platform": ["os": "linux", "architecture": "arm64", "variant": "v8"]
                    ]]
                ]
            ]
            return try! JSONSerialization.data(withJSONObject: [object])
        }()
        let mountJSON: Data = {
            let object: [String: Any] = [
                "configuration": [
                    "id": helper.id,
                    "mounts": [[
                        "source": "/var/lib/container/volumes/adev-repo-ws.img",
                        "destination": "/workspaces/repo",
                        "options": [],
                        "type": ["volume": ["name": "adev-repo-ws"]]
                    ]]
                ]
            ]
            return try! JSONSerialization.data(withJSONObject: [object])
        }()
        var volumeListCalls = 0
        let mock = MockProcessRunner()
        mock.handlers = [{ args in
            if args.starts(with: ["list", "--all"]) {
                return ProcessResult(
                    exitCode: 0,
                    stdout: try! JSONSerialization.data(withJSONObject: [
                        MockProcessRunner.containerListJSON(
                            id: helper.id,
                            state: "running",
                            labels: helperLabels,
                            image: RecoveryHelper.helperImageReference
                        )
                    ]),
                    stderr: Data()
                )
            }
            if args.starts(with: ["volume", "list"]) {
                volumeListCalls += 1
                let names = volumeListCalls <= 2 ? ["adev-repo-ws"] : []
                return ProcessResult(
                    exitCode: 0,
                    stdout: try! JSONSerialization.data(withJSONObject: names.map { ["configuration": ["name": $0]] }),
                    stderr: Data()
                )
            }
            if args.starts(with: ["image", "inspect"]) {
                return ProcessResult(exitCode: 0, stdout: imageJSON, stderr: Data())
            }
            if args == ["inspect", helper.id] {
                return ProcessResult(exitCode: 0, stdout: mountJSON, stderr: Data())
            }
            if args.first == "exec", args.contains("cat") {
                return ProcessResult(exitCode: 0, stdout: rawBytes, stderr: Data())
            }
            if args.first == "exec", args.contains("adevcontainer-recovery-write") {
                let hash = RecoveryConfigSession.sha256Hex(rawBytes)
                return ProcessResult(exitCode: 0, stdout: Data("RECOVERY_APPLIED:\(hash)\n".utf8), stderr: Data())
            }
            if args.first == "delete" || args.first == "create" {
                return ProcessResult(exitCode: 0, stdout: Data(), stderr: Data())
            }
            return nil
        }]
        let runtime = AppleContainerRuntime(executablePath: "container", runner: mock)
        try withRebuildVolumeOverrides {
            try MiniTest.expectThrows({
                _ = try RebuildCommand.run(
                    options: RebuildOptions(name: helper.name, skipPull: true, jsonOutput: true),
                    runtime: runtime
                )
            }) { error in
                let cli = error as? CLIError
                try MiniTest.expectEqual(cli?.code, CLIErrorCode.recoveryUnavailable)
                try MiniTest.expectEqual(cli?.recovery?.helperAvailable, false)
                try MiniTest.expect(cli?.recovery?.retryCommand.contains("rebuild") == true)
            }
        }
        try MiniTest.expect(volumeListCalls >= 2, "retry rechecks the workspace volume")
        try MiniTest.expect(!mock.calls.contains { $0.arguments.first == "volume" && $0.arguments.dropFirst().first == "create" })
        try MiniTest.expect(mock.calls.contains { $0.arguments.first == "delete" }, "replacement delete is recorded before the raced disappearance")
    }),

    ("rebuildConfigNamedVolumesReused", {
        let ws = try TestRepo.makeTempWorkspace(configJSON: """
        {
          "image": "alpine:3.20",
          "mounts": [{ "type": "volume", "source": "cfgvol", "target": "/data" }]
        }
        """)
        defer { try? FileManager.default.removeItem(at: ws) }
        let s = RebuildScenario()
        var labels = s.bindLabels(
            localFolder: ws.path,
            configFile: ws.appendingPathComponent(".devcontainer/devcontainer.json").path
        )
        labels[ContainerIdentity.labelConfigVolumes] = "cfgvol"
        let info = RebuildScenario.container(id: "old-id", labels: labels)
        s.containers = [info]
        s.volumes = ["cfgvol"]
        s.install()
        _ = try RebuildCommand.run(options: RebuildOptions(), runtime: s.runtime)
        try MiniTest.expect(!s.mock.calls.contains { $0.arguments.starts(with: ["volume", "create"]) }, "existing config volume reused")
    }),

    ("rebuildVolumeEnsureFailureDoesNotOfferRecovery", {
        let s = RebuildScenario()
        let info = RebuildScenario.container(id: "vol-old", labels: s.volumeLabels())
        s.containers = [info]
        s.volumeConfigText = #"{"image":"alpine:3.20","mounts":[{"type":"volume","source":"missing-config","target":"/data"}]}"#
        s.volumeCreateFails = true
        s.install()
        try withRebuildVolumeOverrides {
            try MiniTest.expectThrows({
                _ = try RebuildCommand.run(options: RebuildOptions(skipPull: true), runtime: s.runtime)
            }) { error in
                try MiniTest.expectEqual((error as? CLIError)?.property, "volumes")
            }
        }
        try MiniTest.expect(!s.mock.calls.contains { $0.arguments.first == "create" }, "no replacement or recovery helper after ensure failure")
        try MiniTest.expect(!s.mock.calls.contains { $0.arguments.first == "exec" && $0.arguments.contains("adevcontainer-recovery-write") }, "no recovery write after ensure failure")
    }),

    ("rebuildCreatesNewlyDeclaredConfigVolume", {
        let ws = try TestRepo.makeTempWorkspace(configJSON: """
        {
          "image": "alpine:3.20",
          "mounts": [{ "type": "volume", "source": "freshvol", "target": "/data" }]
        }
        """)
        defer { try? FileManager.default.removeItem(at: ws) }
        let s = RebuildScenario()
        let info = RebuildScenario.container(
            id: "old-id",
            labels: s.bindLabels(
                localFolder: ws.path,
                configFile: ws.appendingPathComponent(".devcontainer/devcontainer.json").path
            )
        )
        s.containers = [info]
        s.install()
        _ = try RebuildCommand.run(options: RebuildOptions(), runtime: s.runtime)
        try MiniTest.expect(
            s.mock.calls.contains { $0.arguments.starts(with: ["volume", "create"]) && $0.arguments.last == "freshvol" },
            "newly declared config volume created"
        )
        let createArgs = s.mock.calls.first { $0.arguments.first == "create" }!.arguments
        try MiniTest.expect(createArgs.contains("devcontainer.config_volumes=freshvol"), "config_volumes label updated")
    }),

    ("rebuildVolumeNoCloneNoPull", {
        let s = RebuildScenario()
        let info = RebuildScenario.container(id: "vol-old", labels: s.volumeLabels())
        s.containers = [info]
        s.install()
        try withRebuildVolumeOverrides {
            _ = try RebuildCommand.run(options: RebuildOptions(skipPull: true), runtime: s.runtime)
        }
        let execs = s.mock.calls.compactMap { call -> String? in
            guard call.arguments.first == "exec" else { return nil }
            return call.arguments.last
        }
        try MiniTest.expect(!execs.contains { $0.contains("git clone") }, "no in-container clone on rebuild")
        try MiniTest.expect(!execs.contains { $0.contains("git pull") }, "no in-container pull on rebuild")
        try MiniTest.expect(!s.mock.calls.contains { $0.arguments.starts(with: ["image", "pull"]) }, "no image pull with skip-pull")
    }),

    ("rebuildVolumeSshForwardOnlyWithAgentEnv", {
        let withAgent = RebuildScenario()
        let info = RebuildScenario.container(id: "vol-old", labels: withAgent.volumeLabels())
        withAgent.containers = [info]
        withAgent.install()
        try withRebuildVolumeOverrides {
            _ = try RebuildCommand.run(
                options: RebuildOptions(skipPull: true),
                runtime: withAgent.runtime,
                localEnv: ["SSH_AUTH_SOCK": "/tmp/agent.sock"]
            )
        }
        let createWith = withAgent.mock.calls.first { $0.arguments.first == "create" }!.arguments
        try MiniTest.expect(createWith.contains("--ssh"), "--ssh forwarded with SSH_AUTH_SOCK")

        let noAgent = RebuildScenario()
        let info2 = RebuildScenario.container(id: "vol-old", labels: noAgent.volumeLabels())
        noAgent.containers = [info2]
        noAgent.install()
        try withRebuildVolumeOverrides {
            _ = try RebuildCommand.run(
                options: RebuildOptions(skipPull: true),
                runtime: noAgent.runtime,
                localEnv: [:]
            )
        }
        let createNo = noAgent.mock.calls.first { $0.arguments.first == "create" }!.arguments
        try MiniTest.expect(!createNo.contains("--ssh"), "no --ssh without SSH_AUTH_SOCK")
    }),

    ("rebuildVolumeGitEnsureInjectsGitRef", {
        let gitRef = FeatureGitEnsure.gitFeatureRef
        let sampleRef = "ghcr.io/adevcontainer/features/sample-a:1"
        let fixture = TestRepo.root()
            .appendingPathComponent("Tests/Fixtures/features-sample/sample-a").path
        let cache = FileManager.default.temporaryDirectory
            .appendingPathComponent("feat-rebuild-\(UUID().uuidString)", isDirectory: true).path
        defer { try? FileManager.default.removeItem(atPath: cache) }

        // (a) config with a non-git feature → git injected AFTER the declared feature.
        let s = RebuildScenario()
        let info = RebuildScenario.container(id: "vol-old", labels: s.volumeLabels())
        s.containers = [info]
        s.volumeConfigText = """
        { "image": "alpine:3.20", "features": { "\(sampleRef)": {} } }
        """
        s.install()
        let fetcher = RecordingFeatureFetcher(inner: MockFeatureFetcher(packagesByRef: [
            sampleRef: fixture,
            gitRef: fixture
        ]))
        try withRebuildFeatureOverrides(fetcher: fetcher, cache: cache) {
            _ = try RebuildCommand.run(options: RebuildOptions(skipPull: true), runtime: s.runtime)
        }
        try MiniTest.expectEqual(fetcher.recorded, [sampleRef, gitRef], "git injected after declared feature")

        // (b) config with a git-covering feature → no injection.
        let s2 = RebuildScenario()
        let info2 = RebuildScenario.container(id: "vol-old", labels: s2.volumeLabels())
        s2.containers = [info2]
        s2.volumeConfigText = """
        { "image": "alpine:3.20", "features": { "\(gitRef)": {} } }
        """
        s2.install()
        let fetcher2 = RecordingFeatureFetcher(inner: MockFeatureFetcher(packagesByRef: [gitRef: fixture]))
        try withRebuildFeatureOverrides(fetcher: fetcher2, cache: cache) {
            _ = try RebuildCommand.run(options: RebuildOptions(skipPull: true), runtime: s2.runtime)
        }
        try MiniTest.expectEqual(fetcher2.recorded, [gitRef], "git covering feature not duplicated")
    }),

    ("rebuildVolumeWritableStepGatedByUserChange", {
        // (a) stamped user == effective → no recursive workspace chown; the parents-only
        // fix-up still runs against the fresh container rootfs.
        let same = RebuildScenario()
        let infoSame = RebuildScenario.container(id: "vol-a", labels: same.volumeLabels(remoteUser: "vscode"))
        same.containers = [infoSame]
        same.volumeConfigText = #"{"image":"alpine:3.20","remoteUser":"vscode"}"#
        same.install()
        try withRebuildVolumeOverrides {
            _ = try RebuildCommand.run(options: RebuildOptions(skipPull: true), runtime: same.runtime)
        }
        let execsSame = same.mock.calls.compactMap { $0.arguments.last }
        try MiniTest.expect(!execsSame.contains { $0.contains("chown -R") }, "no recursive workspace chown when user unchanged")
        try MiniTest.expect(execsSame.contains { $0.contains("chown") && !$0.contains("chown -R") }, "parents-only fix-up runs when user unchanged")

        // (b) stamped user empty → chown runs.
        let changed = RebuildScenario()
        let infoChanged = RebuildScenario.container(id: "vol-b", labels: changed.volumeLabels(remoteUser: ""))
        changed.containers = [infoChanged]
        changed.volumeConfigText = #"{"image":"alpine:3.20","remoteUser":"vscode"}"#
        changed.install()
        try withRebuildVolumeOverrides {
            _ = try RebuildCommand.run(options: RebuildOptions(skipPull: true), runtime: changed.runtime)
        }
        let execsChanged = changed.mock.calls.compactMap { $0.arguments.last }
        try MiniTest.expect(execsChanged.contains { $0.contains("chown -R") }, "chown runs when user changed")

        // (c) stamped old user → chown runs.
        let oldUser = RebuildScenario()
        let infoOld = RebuildScenario.container(id: "vol-c", labels: oldUser.volumeLabels(remoteUser: "oldu"))
        oldUser.containers = [infoOld]
        oldUser.volumeConfigText = #"{"image":"alpine:3.20","remoteUser":"vscode"}"#
        oldUser.install()
        try withRebuildVolumeOverrides {
            _ = try RebuildCommand.run(options: RebuildOptions(skipPull: true), runtime: oldUser.runtime)
        }
        let execsOld = oldUser.mock.calls.compactMap { $0.arguments.last }
        try MiniTest.expect(execsOld.contains { $0.contains("chown -R") }, "chown runs when user differs")

        // (d) effective root → no chown even when stamped differs.
        let root = RebuildScenario()
        let infoRoot = RebuildScenario.container(id: "vol-d", labels: root.volumeLabels(remoteUser: "oldu"))
        root.containers = [infoRoot]
        root.volumeConfigText = #"{"image":"alpine:3.20","remoteUser":"root"}"#
        root.install()
        try withRebuildVolumeOverrides {
            _ = try RebuildCommand.run(options: RebuildOptions(skipPull: true), runtime: root.runtime)
        }
        let execsRoot = root.mock.calls.compactMap { $0.arguments.last }
        try MiniTest.expect(!execsRoot.contains { $0.contains("chown") }, "no chown for root remote user")
    }),

    ("rebuildBindChownsConfigNamedVolumeMounts", {
        // Bind rebuild with non-root + config volume: chown mount target even when remoteUser unchanged.
        let ws = try TestRepo.makeTempWorkspace(configJSON: """
        {
          "image": "alpine:3.20",
          "remoteUser": "vscode",
          "mounts": [
            "source=opencode-config,target=/home/vscode/.config/opencode,type=volume"
          ]
        }
        """)
        defer { try? FileManager.default.removeItem(at: ws) }
        let s = RebuildScenario()
        let info = RebuildScenario.container(
            id: "bind-vol",
            labels: s.bindLabels(
                localFolder: ws.path,
                configFile: ws.appendingPathComponent(".devcontainer/devcontainer.json").path,
                remoteUser: "vscode"
            )
        )
        s.containers = [info]
        s.install()
        _ = try RebuildCommand.run(options: RebuildOptions(skipPull: true), runtime: s.runtime)
        let chownScripts = s.mock.calls.compactMap { $0.arguments.last }.filter { $0.contains("chown -R") }
        try MiniTest.expect(!chownScripts.isEmpty, "bind rebuild chowns config named volumes")
        try MiniTest.expect(chownScripts.contains { $0.contains("/home/vscode/.config/opencode") })
        try MiniTest.expect(!chownScripts.contains { $0.contains(ws.path) }, "must not chown host bind path")
    }),

    ("rebuildBindRunsParentsOnlyFixupBeforeHooks", {
        let ws = try TestRepo.makeTempWorkspace(configJSON: """
        {
          "image": "alpine:3.20",
          "remoteUser": "vscode",
          "postCreateCommand": "echo postCreateCustom"
        }
        """)
        defer { try? FileManager.default.removeItem(at: ws) }
        let s = RebuildScenario()
        let info = RebuildScenario.container(
            id: "bind-old",
            labels: s.bindLabels(
                localFolder: ws.path,
                configFile: ws.appendingPathComponent(".devcontainer/devcontainer.json").path
            )
        )
        s.containers = [info]
        s.install()
        _ = try RebuildCommand.run(options: RebuildOptions(skipPull: true), runtime: s.runtime)
        let parentsExecs = s.mock.calls.filter { call in
            call.arguments.first == "exec"
                && (call.arguments.last?.contains("chown") == true)
                && (call.arguments.last?.contains("chown -R") == false)
        }
        try MiniTest.expectEqual(parentsExecs.count, 1, "exactly one parents-only exec on bind rebuild")
        let script = parentsExecs[0].arguments.last ?? ""
        try MiniTest.expect(script.contains("T='/workspaces/\(ws.lastPathComponent)'"), "workspace folder path")
        try MiniTest.expect(!script.contains("chown -R"), "bind target never chowned recursively")
        try MiniTest.expect(!script.contains("chown \"$OWN\" \"$T\""), "workspace folder (bind target) never chowned")
        try MiniTest.expect(script.contains("chown \"$OWN\" \"$P\""), "non-recursive ancestor chown")
        try MiniTest.expect(!s.mock.calls.contains { $0.arguments.last?.contains(ws.path) == true }, "no script references the host bind path")
        let parentsIdx = s.mock.calls.firstIndex { call in
            call.arguments.first == "exec" && call.arguments.last?.contains("chown") == true
        }!
        let hookIdx = s.mock.calls.firstIndex { call in
            call.arguments.first == "exec" && call.arguments.last?.contains("postCreateCustom") == true
        }!
        try MiniTest.expect(parentsIdx < hookIdx, "parent fix-up runs before create-path hooks")
    }),

    ("rebuildParentsFixupFailureWarnsAndContinues", {
        let ws = try TestRepo.makeTempWorkspace(configJSON: """
        {
          "image": "alpine:3.20",
          "remoteUser": "vscode",
          "postCreateCommand": "echo postCreateCustom"
        }
        """)
        defer { try? FileManager.default.removeItem(at: ws) }
        let s = RebuildScenario()
        let info = RebuildScenario.container(
            id: "bind-old",
            labels: s.bindLabels(
                localFolder: ws.path,
                configFile: ws.appendingPathComponent(".devcontainer/devcontainer.json").path
            )
        )
        s.containers = [info]
        s.failingExecSubstrings = ["chown \"$OWN\" \"$P\""]
        s.install()
        let previous = StatusPrinter.onWarning
        defer { StatusPrinter.onWarning = previous }
        var warnings: [String] = []
        StatusPrinter.onWarning = { warnings.append($0) }
        _ = try RebuildCommand.run(options: RebuildOptions(skipPull: true), runtime: s.runtime)
        try MiniTest.expect(warnings.contains { $0.contains("workspace parents") }, "parent fix-up failure warns on stderr")
        try MiniTest.expect(
            s.mock.calls.contains { $0.arguments.first == "exec" && $0.arguments.last?.contains("postCreateCustom") == true },
            "create-path hooks still run after parent fix-up failure"
        )
        try MiniTest.expect(
            !s.mock.calls.contains { $0.arguments.first == "delete" && $0.arguments.contains(s.newContainerId) },
            "new container not deleted on parent fix-up failure"
        )
    }),

    ("rebuildHookOrderOnNewContainer", {
        let ws = try TestRepo.makeTempWorkspace(configJSON: """
        {
          "image": "alpine:3.20",
          "onCreateCommand": "echo onCreateCustom",
          "updateContentCommand": "echo updateContentCustom",
          "postCreateCommand": "echo postCreateCustom",
          "postStartCommand": "echo postStartCustom"
        }
        """)
        defer { try? FileManager.default.removeItem(at: ws) }
        let s = RebuildScenario()
        let info = RebuildScenario.container(
            id: "old-id",
            labels: s.bindLabels(
                localFolder: ws.path,
                configFile: ws.appendingPathComponent(".devcontainer/devcontainer.json").path
            )
        )
        s.containers = [info]
        s.install()
        _ = try RebuildCommand.run(options: RebuildOptions(), runtime: s.runtime)
        let hookCalls = s.mock.calls.map(\.arguments).enumerated().compactMap { (idx, args) -> (Int, String)? in
            guard args.first == "exec", let script = args.last else { return nil }
            for marker in ["onCreateCustom", "updateContentCustom", "postCreateCustom", "postStartCustom"] {
                if script.contains(marker) { return (idx, marker) }
            }
            return nil
        }
        let markers = hookCalls.map(\.1)
        try MiniTest.expectEqual(markers, ["onCreateCustom", "updateContentCustom", "postCreateCustom", "postStartCustom"], "hooks run in create-path order")
        let firstExec = hookCalls.first!.0
        let createIdx = s.mock.calls.firstIndex { $0.arguments.first == "create" }!
        try MiniTest.expect(firstExec > createIdx, "hooks run on the NEW container")
    }),

    ("rebuildRunsHostInitializeBeforeCreate", {
        let ws = try TestRepo.makeTempWorkspace(configJSON: """
        {
          "image": "alpine:3.20",
          "initializeCommand": "echo init-rebuild",
          "onCreateCommand": "echo onCreateBoom",
          "updateContentCommand": "echo updateContentCustom",
          "postCreateCommand": "echo postCreateCustom",
          "postStartCommand": "echo postStartCustom"
        }
        """)
        defer { try? FileManager.default.removeItem(at: ws) }
        var events: [String] = []
        let host = RecordingHostProcessRunner()
        host.handler = { call in
            // Non-repo temp workspace: the credential-seeding remote probe reports no remotes.
            if call.arguments.contains("remote") {
                return ProcessResult(exitCode: 128, stdout: Data(), stderr: Data("fatal: not a git repository".utf8))
            }
            events.append("initialize")
            return ProcessResult(exitCode: 0, stdout: Data(), stderr: Data())
        }
        let restoreHost = RecordingHostProcessRunner.install(host)
        defer { restoreHost() }
        let s = RebuildScenario()
        let info = RebuildScenario.container(
            id: "old-id",
            labels: s.bindLabels(
                localFolder: ws.path,
                configFile: ws.appendingPathComponent(".devcontainer/devcontainer.json").path
            )
        )
        s.containers = [info]
        s.failingExecSubstrings = ["onCreateBoom"]
        s.install()
        defer { try? BindRecoveryResume.cleanup(name: info.name) }
        try MiniTest.expectThrows({
            _ = try RebuildCommand.run(
                options: RebuildOptions(skipPull: true, jsonOutput: true),
                runtime: s.runtime,
                isTTY: false
            )
        }) { err in
            let cli = err as? CLIError
            try MiniTest.expect(
                cli?.property?.contains("onCreateCommand") == true
                    || cli?.code == CLIErrorCode.recoveryUnavailable,
                "create-path hook failure (or bind recovery of that failure)"
            )
        }
        let createIdx = s.mock.calls.firstIndex { $0.arguments.first == "create" }
        try MiniTest.expect(createIdx != nil, "new container is created after host initialize")
        try MiniTest.expectEqual(events.first, "initialize")
        try MiniTest.expectEqual(host.calls.filter { $0.arguments.contains("echo init-rebuild") }.count, 1)
        try MiniTest.expect(host.calls[0].arguments.contains("echo init-rebuild"))
        try MiniTest.expectEqual(
            (host.calls[0].currentDirectory as NSString?)?.standardizingPath,
            (ws.path as NSString).standardizingPath
        )
        try MiniTest.expect(
            s.mock.calls.contains { $0.arguments.first == "delete" && $0.arguments.last == s.newContainerId },
            "first create-path hook failure deletes only the new container"
        )
    }),

    ("volumeModeRebuildWithoutHostWorkspaceStillRunsInitializeCommand", {
        let s = RebuildScenario()
        let host = RecordingHostProcessRunner()
        var initCwd: String?
        var sawDeleteOrCreateDuringInit = false
        var stagedHasDevcontainer = false
        var stagedHasSetup = false
        var stagedHasScripts = false
        host.handler = { call in
            initCwd = call.currentDirectory
            if s.mock.calls.contains(where: {
                $0.arguments.first == "delete" || $0.arguments.first == "create"
            }) {
                sawDeleteOrCreateDuringInit = true
            }
            let cwd = call.currentDirectory ?? ""
            let dc = (cwd as NSString).appendingPathComponent(".devcontainer")
            var isDir: ObjCBool = false
            stagedHasDevcontainer = FileManager.default.fileExists(atPath: dc, isDirectory: &isDir) && isDir.boolValue
            stagedHasSetup = FileManager.default.fileExists(
                atPath: (dc as NSString).appendingPathComponent("setup.sh")
            )
            stagedHasScripts = FileManager.default.fileExists(
                atPath: (cwd as NSString).appendingPathComponent("scripts")
            )
            return ProcessResult(exitCode: 0, stdout: Data(), stderr: Data())
        }
        let restoreHost = RecordingHostProcessRunner.install(host)
        defer { restoreHost() }
        var labels = s.volumeLabels()
        labels[ContainerIdentity.labelLocalFolder] = "volume://adev-repo-ws"
        let info = RebuildScenario.container(id: "vol-old", labels: labels)
        s.containers = [info]
        s.volumes = ["adev-repo-ws"]
        s.volumeConfigText = """
        {
          "image": "alpine:3.20",
          "initializeCommand": "bash .devcontainer/setup.sh"
        }
        """
        s.guestDevcontainerTar = try makeGuestDevcontainerArchive(files: [
            "devcontainer.json": s.volumeConfigText,
            "setup.sh": "#!/bin/sh\necho staged\n"
        ])
        s.install()
        try withRebuildVolumeOverrides {
            _ = try RebuildCommand.run(
                options: RebuildOptions(skipPull: true),
                runtime: s.runtime
            )
        }
        try MiniTest.expectEqual(host.calls.count, 1, "initializeCommand must run on the host")
        try MiniTest.expect(host.calls[0].arguments.contains("bash .devcontainer/setup.sh"))
        try MiniTest.expect(stagedHasDevcontainer, "temp cwd must contain guest .devcontainer/")
        try MiniTest.expect(stagedHasSetup, "bash .devcontainer/setup.sh must resolve from the temp cwd")
        try MiniTest.expect(!stagedHasScripts, "temp root is not a full guest workspace checkout")
        try MiniTest.expect(!sawDeleteOrCreateDuringInit, "initialize runs before old delete / new create")
        try MiniTest.expect(
            s.mock.calls.contains { $0.arguments.first == "create" },
            "new container is created only after initialize succeeds"
        )
        try MiniTest.expect(
            s.mock.calls.contains { $0.arguments.first == "delete" && $0.arguments.last == "vol-old" },
            "old container is deleted after initialize"
        )
        guard let cwd = initCwd else {
            throw MiniTest.Failure(message: "initialize cwd was not observed")
        }
        try MiniTest.expect(
            !FileManager.default.fileExists(atPath: cwd),
            "temporary workspace root is removed after the hook"
        )
        try MiniTest.expect(
            (cwd as NSString).standardizingPath != (s.volumes[0] as NSString).standardizingPath
        )
    }),

    ("volumeModeRebuildInitializeTempIsRemovedAfterFailure", {
        let host = RecordingHostProcessRunner()
        var initCwd: String?
        host.handler = { call in
            initCwd = call.currentDirectory
            return ProcessResult(exitCode: 9, stdout: Data(), stderr: Data("init failed".utf8))
        }
        let restoreHost = RecordingHostProcessRunner.install(host)
        defer { restoreHost() }
        let s = RebuildScenario()
        var labels = s.volumeLabels()
        labels[ContainerIdentity.labelLocalFolder] = "volume://adev-repo-ws"
        let info = RebuildScenario.container(id: "vol-old", labels: labels)
        s.containers = [info]
        s.volumes = ["adev-repo-ws"]
        s.volumeConfigText = """
        {
          "image": "alpine:3.20",
          "initializeCommand": "exit 9"
        }
        """
        s.guestDevcontainerTar = try makeGuestDevcontainerArchive(files: [
            "devcontainer.json": s.volumeConfigText
        ])
        s.install()
        try MiniTest.expectThrows({
            try withRebuildVolumeOverrides {
                _ = try RebuildCommand.run(
                    options: RebuildOptions(skipPull: true),
                    runtime: s.runtime
                )
            }
        }) { err in
            let cli = err as? CLIError
            try MiniTest.expectEqual(cli?.property, "initializeCommand")
            try MiniTest.expectEqual(cli?.code, CLIErrorCode.lifecycleFailed)
        }
        try MiniTest.expectEqual(host.calls.count, 1)
        try MiniTest.expect(!s.mock.calls.contains { $0.arguments.first == "create" }, "must not create the new container")
        try MiniTest.expect(
            !s.mock.calls.contains { $0.arguments.first == "delete" },
            "old container remains"
        )
        guard let cwd = initCwd else {
            throw MiniTest.Failure(message: "initialize cwd was not observed")
        }
        try MiniTest.expect(
            !FileManager.default.fileExists(atPath: cwd),
            "temporary workspace root is removed after initialize failure"
        )
    }),

    ("missingDevcontainerDirectoryDoesNotSkipInitializeCommandOnVolumeRebuild", {
        let host = RecordingHostProcessRunner()
        var initCwd: String?
        let previous = StatusPrinter.onWarning
        var warnings: [String] = []
        StatusPrinter.onWarning = { warnings.append($0) }
        defer { StatusPrinter.onWarning = previous }
        var stagedHasRootJson = false
        var stagedHasDevcontainerDir = false
        host.handler = { call in
            initCwd = call.currentDirectory
            let cwd = call.currentDirectory ?? ""
            stagedHasRootJson = FileManager.default.fileExists(
                atPath: (cwd as NSString).appendingPathComponent(".devcontainer.json")
            )
            stagedHasDevcontainerDir = FileManager.default.fileExists(
                atPath: (cwd as NSString).appendingPathComponent(".devcontainer")
            )
            return ProcessResult(exitCode: 0, stdout: Data(), stderr: Data())
        }
        let restoreHost = RecordingHostProcessRunner.install(host)
        defer { restoreHost() }
        let s = RebuildScenario()
        var labels = s.volumeLabels(configFile: ".devcontainer.json")
        labels[ContainerIdentity.labelLocalFolder] = "volume://adev-repo-ws"
        let info = RebuildScenario.container(id: "vol-old", labels: labels)
        s.containers = [info]
        s.volumes = ["adev-repo-ws"]
        s.guestDevcontainerExists = false
        s.volumeConfigText = """
        {
          "image": "alpine:3.20",
          "initializeCommand": "echo init-global"
        }
        """
        s.install()
        try withRebuildVolumeOverrides {
            _ = try RebuildCommand.run(
                options: RebuildOptions(skipPull: true),
                runtime: s.runtime
            )
        }
        try MiniTest.expectEqual(host.calls.count, 1, "missing .devcontainer/ must not skip initializeCommand")
        try MiniTest.expect(host.calls[0].arguments.contains("echo init-global"))
        try MiniTest.expect(stagedHasRootJson, "temp cwd must contain the root .devcontainer.json")
        try MiniTest.expect(!stagedHasDevcontainerDir, "missing guest .devcontainer/ must not be invented")
        try MiniTest.expect(
            !warnings.contains { $0.lowercased().contains("initializecommand") && $0.lowercased().contains("host") },
            "must not skip+warn solely because .devcontainer/ is absent"
        )
        guard let cwd = initCwd else {
            throw MiniTest.Failure(message: "initialize cwd was not observed")
        }
        try MiniTest.expect(
            !FileManager.default.fileExists(atPath: cwd),
            "temporary workspace root is removed after the hook"
        )
    }),

    ("volumeModeRebuildInitializeIsNotAFullWorkspaceCheckout", {
        let host = RecordingHostProcessRunner()
        var stagedHasNestedConfig = false
        var stagedHasScripts = false
        host.handler = { call in
            let cwd = call.currentDirectory ?? ""
            stagedHasNestedConfig = FileManager.default.fileExists(
                atPath: (cwd as NSString).appendingPathComponent(".devcontainer/devcontainer.json")
            )
            stagedHasScripts = FileManager.default.fileExists(
                atPath: (cwd as NSString).appendingPathComponent("scripts/bootstrap.sh")
            )
            return ProcessResult(exitCode: 0, stdout: Data(), stderr: Data())
        }
        let restoreHost = RecordingHostProcessRunner.install(host)
        defer { restoreHost() }
        let s = RebuildScenario()
        var labels = s.volumeLabels()
        labels[ContainerIdentity.labelLocalFolder] = "volume://adev-repo-ws"
        let info = RebuildScenario.container(id: "vol-old", labels: labels)
        s.containers = [info]
        s.volumes = ["adev-repo-ws"]
        s.volumeConfigText = """
        {
          "image": "alpine:3.20",
          "initializeCommand": "echo only-devcontainer"
        }
        """
        s.guestDevcontainerTar = try makeGuestDevcontainerArchive(files: [
            "devcontainer.json": s.volumeConfigText
        ])
        s.install()
        try withRebuildVolumeOverrides {
            _ = try RebuildCommand.run(
                options: RebuildOptions(skipPull: true),
                runtime: s.runtime
            )
        }
        try MiniTest.expectEqual(host.calls.count, 1)
        try MiniTest.expect(stagedHasNestedConfig, "temp root contains guest .devcontainer/")
        try MiniTest.expect(
            !stagedHasScripts,
            "success must not depend on other guest paths such as ./scripts/"
        )
    }),

    ("volumeModeRebuildWithRetainedHostCheckoutUsesThatPath", {
        let checkout = try TestRepo.makeTempWorkspace(configJSON: """
        {
          "image": "alpine:3.20",
          "initializeCommand": "echo init-retained"
        }
        """)
        defer { try? FileManager.default.removeItem(at: checkout) }
        let host = RecordingHostProcessRunner()
        host.handler = { _ in
            ProcessResult(exitCode: 0, stdout: Data(), stderr: Data())
        }
        let restoreHost = RecordingHostProcessRunner.install(host)
        defer { restoreHost() }
        let s = RebuildScenario()
        var labels = s.volumeLabels()
        labels[ContainerIdentity.labelLocalFolder] = checkout.path
        let info = RebuildScenario.container(id: "vol-old", labels: labels)
        s.containers = [info]
        s.volumes = ["adev-repo-ws"]
        s.volumeConfigText = """
        {
          "image": "alpine:3.20",
          "initializeCommand": "echo init-retained"
        }
        """
        s.install()
        try withRebuildVolumeOverrides {
            _ = try RebuildCommand.run(
                options: RebuildOptions(skipPull: true),
                runtime: s.runtime
            )
        }
        try MiniTest.expectEqual(host.calls.count, 1)
        try MiniTest.expectEqual(
            (host.calls[0].currentDirectory as NSString?)?.standardizingPath,
            (checkout.path as NSString).standardizingPath
        )
        try MiniTest.expect(
            !s.mock.calls.contains { $0.arguments.contains("tar") && $0.arguments.contains("cf") },
            "must not substitute a temporary workspace root when a retained checkout exists"
        )
        try MiniTest.expect(
            FileManager.default.fileExists(atPath: checkout.path),
            "retained host checkout is durable and must not be removed"
        )
    }),

    ("rebuildHookFailureDeletesNewContainer", {
        let ws = try TestRepo.makeTempWorkspace(configJSON: """
        {
          "image": "alpine:3.20",
          "postStartCommand": "echo postStartCustom"
        }
        """)
        defer { try? FileManager.default.removeItem(at: ws) }
        let s = RebuildScenario()
        let info = RebuildScenario.container(
            id: "old-id",
            labels: s.bindLabels(
                localFolder: ws.path,
                configFile: ws.appendingPathComponent(".devcontainer/devcontainer.json").path
            )
        )
        s.containers = [info]
        s.failingExecSubstrings = ["postStartCustom"]
        s.install()
        defer { try? BindRecoveryResume.cleanup(name: info.name) }
        let prevEnabled = StatusPrinter.enabled
        defer { StatusPrinter.enabled = prevEnabled }
        StatusPrinter.enabled = true
        var stderr = ""
        try MiniTest.expectThrows({
            try withCapturedStderr(
                {
                    _ = try RebuildCommand.run(
                        options: RebuildOptions(jsonOutput: true),
                        runtime: s.runtime,
                        isTTY: false
                    )
                },
                capture: &stderr
            )
        }, validate: { err in
            // Bind-mode hard post-delete hook failure offers host-path recovery (non-TTY).
            let cli = err as? CLIError
            try MiniTest.expectEqual(cli?.code, CLIErrorCode.recoveryUnavailable)
            try MiniTest.expectEqual(cli?.recovery?.mode, "bind")
            try MiniTest.expectEqual(cli?.recovery?.helperAvailable, false)
            try MiniTest.expect(cli?.recovery?.configPath.contains("devcontainer.json") == true)
            try MiniTest.expect(cli?.recovery?.retryCommand.contains("rebuild") == true)
            try MiniTest.expectEqual(cli?.recovery?.cleanupCommand, "")
        })
        // LifecycleRunner deletes the NEW container on hook fail; bind recovery may
        // re-check/delete by id when still listed. No helper create.
        try MiniTest.expect(
            s.mock.calls.contains { $0.arguments.first == "delete" && $0.arguments.last == s.newContainerId },
            "new container deleted on hook failure"
        )
        try MiniTest.expect(!s.mock.calls.contains { $0.arguments.first == "create" && $0.arguments.contains(RecoveryHelper.helperImageReference) })
        try MiniTest.expect(stderr.contains("was already removed") || stderr.contains("entering recovery"), "operator is told recovery/old-removed context")
        try MiniTest.expect(!stderr.contains("internalError"), "no internal error noise on the delete-on-fail path")
    }),

    ("rebuildExecFailureDeletesDiscoverableNewContainer", {
        let ws = try TestRepo.makeTempWorkspace(configJSON: """
        {
          "image": "alpine:3.20",
          "postCreateCommand": "echo postCreateCustom"
        }
        """)
        defer { try? FileManager.default.removeItem(at: ws) }
        let s = RebuildScenario()
        let info = RebuildScenario.container(
            id: "old-id",
            labels: s.bindLabels(
                localFolder: ws.path,
                configFile: ws.appendingPathComponent(".devcontainer/devcontainer.json").path
            )
        )
        s.containers = [info]
        let expectedError = CLIError(
            code: CLIErrorCode.runtimeFailed,
            property: "postCreateCommand",
            message: "exec transport failed",
            hint: "retry"
        )
        s.mock.throwingHandler = { args in
            guard args.first == "exec" else { return nil }
            if args.contains(LifecycleRunner.userEnvProbeScript) { return nil }
            throw expectedError
        }
        var foundNewContainer = false
        s.mock.handlers.append { [weak s] args in
            guard let s else { return nil }
            if args.first == "create" {
                s.containers.append(RebuildScenario.container(id: s.newContainerId, labels: info.labels))
            } else if args.starts(with: ["list"]) {
                foundNewContainer = s.containers.contains { $0.id == s.newContainerId } || foundNewContainer
            } else if args.first == "delete", args.last == s.newContainerId {
                if s.containers.contains(where: { $0.id == s.newContainerId }) {
                    s.containers.removeAll { $0.id == s.newContainerId }
                } else {
                    let noise = "internalError: failed to delete container (notFound)\n"
                    FileHandle.standardError.write(Data(noise.utf8))
                    return ProcessResult(exitCode: 1, stdout: Data(), stderr: Data(noise.utf8))
                }
            }
            return nil
        }
        s.install()
        defer { try? BindRecoveryResume.cleanup(name: info.name) }

        let previousStatusEnabled = StatusPrinter.enabled
        defer { StatusPrinter.enabled = previousStatusEnabled }
        StatusPrinter.enabled = true
        var stderr = ""
        try MiniTest.expectThrows({
            try withCapturedStderr(
                {
                    _ = try RebuildCommand.run(
                        options: RebuildOptions(jsonOutput: true),
                        runtime: s.runtime,
                        isTTY: false
                    )
                },
                capture: &stderr
            )
        }, validate: { error in
            // Bind recovery wraps the hard failure; original failure kind is preserved.
            let cli = error as? CLIError
            try MiniTest.expectEqual(cli?.code, CLIErrorCode.recoveryUnavailable)
            try MiniTest.expectEqual(cli?.recovery?.mode, "bind")
            try MiniTest.expectEqual(cli?.recovery?.failureKind, CLIErrorCode.runtimeFailed)
        })

        try MiniTest.expect(foundNewContainer, "new container was discoverable for catch cleanup")
        try MiniTest.expect(
            s.mock.calls.contains { $0.arguments.first == "delete" && $0.arguments.last == s.newContainerId },
            "new container deleted after exec failure"
        )
        try MiniTest.expect(stderr.contains("was already removed") || stderr.contains("entering recovery"))
        try MiniTest.expect(!stderr.contains("notFound"), "no duplicate not-found noise")
        try MiniTest.expect(!stderr.contains("internalError"), "no duplicate internal error noise")
    }),

    ("lifecycleRunnerCreatePathDeletesOnceOnHookFailure", {
        // LifecycleRunner-level path: deleteContainerThenFail policy deletes the
        // container exactly once when a create-path hook exits non-zero.
        let mock = MockProcessRunner()
        mock.handlers = [
            { args in
                if args.first == "exec" {
                    if args.contains(LifecycleRunner.userEnvProbeScript) {
                        return ProcessResult(exitCode: 0, stdout: Data(), stderr: Data())
                    }
                    return ProcessResult(exitCode: 1, stdout: Data(), stderr: Data("boom".utf8))
                }
                return nil
            }
        ]
        let runtime = AppleContainerRuntime(executablePath: "container", runner: mock)
        var config = ResolvedDevContainerConfig(image: "alpine:3.20", workspaceFolder: "/workspaces/x")
        config.postCreateCommand = .shell("echo boom")
        try MiniTest.expectThrows({
            try LifecycleRunner.runCreatePath(containerId: "new-ctr", config: config, runtime: runtime)
        }, validate: { err in
            try MiniTest.expectEqual((err as? CLIError)?.code, CLIErrorCode.postCreateFailed)
        })
        let deletes = mock.calls.filter { $0.arguments.first == "delete" }
        try MiniTest.expectEqual(deletes.count, 1, "deleteContainerThenFail deletes exactly once")
        try MiniTest.expectEqual(deletes.first?.arguments.last, "new-ctr", "delete targets the failed new container")
    }),

    ("rebuildStartFailureDeletesNewContainer", {
        let ws = try TestRepo.makeTempWorkspace(configJSON: #"{"image":"alpine:3.20"}"#)
        defer { try? FileManager.default.removeItem(at: ws) }
        let s = RebuildScenario()
        let info = RebuildScenario.container(
            id: "old-id",
            labels: s.bindLabels(
                localFolder: ws.path,
                configFile: ws.appendingPathComponent(".devcontainer/devcontainer.json").path
            )
        )
        s.containers = [info]
        s.startFails = true
        s.install()
        defer { try? BindRecoveryResume.cleanup(name: info.name) }
        try MiniTest.expectThrows({
            _ = try RebuildCommand.run(
                options: RebuildOptions(jsonOutput: true),
                runtime: s.runtime,
                isTTY: false
            )
        }, validate: { err in
            let cli = err as? CLIError
            try MiniTest.expectEqual(cli?.code, CLIErrorCode.recoveryUnavailable)
            try MiniTest.expectEqual(cli?.recovery?.mode, "bind")
            try MiniTest.expectEqual(cli?.recovery?.helperAvailable, false)
        })
        try MiniTest.expect(
            s.mock.calls.contains { $0.arguments.first == "delete" && $0.arguments.last == s.newContainerId },
            "new container deleted after start failure"
        )
        try MiniTest.expect(!s.mock.calls.contains {
            $0.arguments.contains(RecoveryHelper.helperImageReference)
        }, "no Alpine helper for bind start recovery")
    }),

    ("rebuildBindPreDeleteParseNeverOffersRecovery", {
        let ws = try TestRepo.makeTempWorkspace(configJSON: "{ not valid json")
        defer { try? FileManager.default.removeItem(at: ws) }
        let s = RebuildScenario()
        let info = RebuildScenario.container(
            id: "old-id",
            labels: s.bindLabels(
                localFolder: ws.path,
                configFile: ws.appendingPathComponent(".devcontainer/devcontainer.json").path
            )
        )
        s.containers = [info]
        s.install()
        try MiniTest.expectThrows({
            _ = try RebuildCommand.run(
                options: RebuildOptions(jsonOutput: true),
                runtime: s.runtime,
                isTTY: false
            )
        }, validate: { err in
            try MiniTest.expectEqual(rebuildErrorCode(err), CLIErrorCode.configParse)
            try MiniTest.expect((err as? CLIError)?.recovery == nil)
        })
        try MiniTest.expect(!s.mock.calls.contains { $0.arguments.first == "delete" }, "old left untouched")
        try MiniTest.expect(!s.mock.calls.contains { $0.arguments.first == "create" })
        try MiniTest.expect(try BindRecoveryResume.load(name: info.name) == nil)
    }),

    ("rebuildBindPostCreateNonTTYOffersHostPathRecovery", {
        let ws = try TestRepo.makeTempWorkspace(configJSON: """
        {
          "image": "alpine:3.20",
          "postCreateCommand": "echo postCreateBoom"
        }
        """)
        defer { try? FileManager.default.removeItem(at: ws) }
        let configPath = ws.appendingPathComponent(".devcontainer/devcontainer.json").path
        let s = RebuildScenario()
        let info = RebuildScenario.container(
            id: "old-id",
            labels: s.bindLabels(localFolder: ws.path, configFile: configPath)
        )
        s.containers = [info]
        s.failingExecSubstrings = ["postCreateBoom"]
        s.install()
        defer { try? BindRecoveryResume.cleanup(name: info.name) }

        try MiniTest.expectThrows({
            _ = try RebuildCommand.run(
                options: RebuildOptions(name: info.name, jsonOutput: true),
                runtime: s.runtime,
                isTTY: false
            )
        }, validate: { err in
            let cli = err as? CLIError
            try MiniTest.expectEqual(cli?.code, CLIErrorCode.recoveryUnavailable)
            try MiniTest.expectEqual(cli?.recovery?.mode, "bind")
            try MiniTest.expectEqual(
                cli?.recovery?.configPath,
                (configPath as NSString).standardizingPath
            )
            try MiniTest.expect(cli?.recovery?.editCommand.contains("devcontainer.json") == true)
            try MiniTest.expect(cli?.recovery?.retryCommand.contains(info.name) == true)
            try MiniTest.expectEqual(cli?.recovery?.cleanupCommand, "")
            try MiniTest.expectEqual(cli?.recovery?.helperAvailable, false)
            try MiniTest.expectEqual(cli?.recovery?.sessionID, "")
        })
        try MiniTest.expect(!s.mock.calls.contains {
            $0.arguments.first == "create" && $0.arguments.contains(where: { $0.contains("alpine@sha256") })
        }, "no recovery helper create")
        try MiniTest.expect(try BindRecoveryResume.load(name: info.name) != nil, "resume retained for named retry")
    }),

    ("rebuildBindTTYRecoveryEditsHostAndRetries", {
        let ws = try TestRepo.makeTempWorkspace(configJSON: """
        {
          "image": "alpine:3.20",
          "postCreateCommand": "echo postCreateBoom"
        }
        """)
        defer { try? FileManager.default.removeItem(at: ws) }
        let configURL = ws.appendingPathComponent(".devcontainer/devcontainer.json")
        let fixed = Data(#"{"image":"alpine:3.20"}"#.utf8)
        let s = RebuildScenario()
        let info = RebuildScenario.container(
            id: "old-id",
            labels: s.bindLabels(localFolder: ws.path, configFile: configURL.path)
        )
        s.containers = [info]
        // Fail postCreate only on the first rebuild attempt.
        var postCreateFails = true
        s.mock.handlers.append { args in
            guard args.first == "exec", let script = args.last, script.contains("postCreateBoom") else {
                return nil
            }
            if postCreateFails {
                return ProcessResult(exitCode: 1, stdout: Data(), stderr: Data("boom".utf8))
            }
            return ProcessResult(exitCode: 0, stdout: Data(), stderr: Data())
        }
        s.install()
        defer { try? BindRecoveryResume.cleanup(name: info.name) }

        let editorRunner = RebuildTTYEditorRunner(bytes: fixed) { _ in
            // After the editor writes a good config, subsequent hooks succeed.
            postCreateFails = false
        }
        let editor = RecoveryEditor(
            environment: ["VISUAL": "/test-editor"],
            runner: editorRunner,
            fallbackEditors: [],
            executableChecker: { _ in true }
        )
        final class PromptAnswers: @unchecked Sendable {
            var remaining: [String?] = [""]
        }
        let promptAnswers = PromptAnswers()
        let openPrompt = RecoveryOpenEditorPrompt(
            readLine: {
                if promptAnswers.remaining.isEmpty { return nil }
                return promptAnswers.remaining.removeFirst()
            },
            writeError: { _ in }
        )
        let result = try RebuildCommand.run(
            options: RebuildOptions(name: info.name),
            runtime: s.runtime,
            isTTY: true,
            recoveryEditor: editor,
            openEditorPrompt: openPrompt
        )
        try MiniTest.expectEqual(result.outcome, "success")
        try MiniTest.expectEqual(editorRunner.launches, 1)
        let onDisk = try Data(contentsOf: configURL)
        try MiniTest.expectEqual(onDisk, fixed)
        try MiniTest.expect(!s.mock.calls.contains {
            $0.arguments.contains("adevcontainer-recovery-write")
        })
        try MiniTest.expect(try BindRecoveryResume.load(name: info.name) == nil, "resume cleaned after success")
    }),

    // ═══════════════════════ Section 4: open / extensions / postAttach ═══════════════════════

    ("rebuildSettingsApplyNotGatedOnOpen", {
        let ws = try TestRepo.makeTempWorkspace(configJSON: """
        {
          "image": "alpine:3.20",
          "customizations": { "vscode": { "settings": { "editor.fontSize": 14 } } }
        }
        """)
        defer { try? FileManager.default.removeItem(at: ws) }
        let s = RebuildScenario()
        let info = RebuildScenario.container(
            id: "old-id",
            labels: s.bindLabels(
                localFolder: ws.path,
                configFile: ws.appendingPathComponent(".devcontainer/devcontainer.json").path
            )
        )
        s.containers = [info]
        s.install()
        let guest = RecordingGuestOps()
        try withRebuildCustomizationsOverrides(guest: guest) {
            _ = try RebuildCommand.run(options: RebuildOptions(), runtime: s.runtime)
        }
        try MiniTest.expect(guest.writes.contains { $0.contains("settings.json") }, "settings applied without --vscode")
    }),

    ("rebuildExtensionsApplyWithoutVSCode", {
        let ws = try TestRepo.makeTempWorkspace(configJSON: """
        {
          "image": "alpine:3.20",
          "postAttachCommand": "echo postAttachCustom",
          "customizations": {
            "vscode": {
              "settings": { "editor.fontSize": 14 },
              "extensions": ["sample.one"]
            }
          }
        }
        """)
        defer { try? FileManager.default.removeItem(at: ws) }
        let s = RebuildScenario()
        let info = RebuildScenario.container(
            id: "old-id",
            labels: s.bindLabels(
                localFolder: ws.path,
                configFile: ws.appendingPathComponent(".devcontainer/devcontainer.json").path
            )
        )
        s.containers = [info]
        s.install()
        let launcher = MockVSCodeLauncher()
        let restore = RebuildOpenSupport.install(launcher: launcher, resolverPath: "/usr/local/bin/code")
        defer { restore() }
        let guest = RecordingGuestOps()
        try withRebuildCustomizationsOverrides(guest: guest) {
            _ = try RebuildCommand.run(options: RebuildOptions(openVSCode: false), runtime: s.runtime)
        }
        try MiniTest.expectEqual(launcher.calls.count, 0, "must not open without --vscode")
        try MiniTest.expect(
            guest.writes.contains { $0.contains("extensions.json") },
            "extensions applied on rebuild without --vscode"
        )
        try MiniTest.expect(
            guest.writes.contains { $0.contains("settings.json") },
            "settings still applied without --vscode"
        )
        let postAttachIdx = s.mock.calls.firstIndex { $0.arguments.last?.contains("postAttachCustom") == true }
        try MiniTest.expect(postAttachIdx != nil, "CLI-attach rebuild runs postAttach without --vscode")
    }),

    ("rebuildVscodeExtensionsThenOpenThenPostAttach", {
        let ws = try TestRepo.makeTempWorkspace(configJSON: """
        {
          "image": "alpine:3.20",
          "postAttachCommand": "echo postAttachCustom",
          "customizations": {
            "vscode": {
              "settings": { "editor.fontSize": 14 },
              "extensions": ["sample.one"]
            }
          }
        }
        """)
        defer { try? FileManager.default.removeItem(at: ws) }
        let s = RebuildScenario()
        let info = RebuildScenario.container(
            id: "old-id",
            labels: s.bindLabels(
                localFolder: ws.path,
                configFile: ws.appendingPathComponent(".devcontainer/devcontainer.json").path
            )
        )
        s.containers = [info]
        s.install()
        var sequence: [String] = []
        let launcher = MockVSCodeLauncher()
        launcher.onLaunch = { sequence.append("open") }
        let guest = RecordingGuestOps()
        guest.onWrite = { path in
            if path.contains("extensions.json") { sequence.append("extensions") }
        }
        let restore = RebuildOpenSupport.install(launcher: launcher, resolverPath: "/usr/local/bin/code")
        defer { restore() }
        let stderr = try withEnabledStatusStderr {
            try withRebuildCustomizationsOverrides(guest: guest) {
                _ = try RebuildCommand.run(options: RebuildOptions(openVSCode: true), runtime: s.runtime)
            }
        }
        try MiniTest.expectEqual(launcher.calls.count, 1, "VS Code opened once")
        try expectNoPostSuccessConnectionHints(stderr)
        try MiniTest.expect(guest.writes.contains { $0.contains("extensions.json") }, "extensions applied before open")
        let postAttachIdx = s.mock.calls.firstIndex { $0.arguments.last?.contains("postAttachCustom") == true }
        try MiniTest.expect(postAttachIdx != nil, "postAttach ran after open")
        try MiniTest.expect(guest.writes.contains { $0.contains("settings.json") }, "settings applied too")
        // extensions registry write precedes open; postAttach is after open in lifecycle.
        try MiniTest.expect(sequence.firstIndex(of: "extensions")! < sequence.firstIndex(of: "open")!)
    }),

    ("rebuildVscodeOpenSoftFailStillRunsPostAttach", {
        let ws = try TestRepo.makeTempWorkspace(configJSON: """
        {
          "image": "alpine:3.20",
          "postAttachCommand": "echo postAttachCustom"
        }
        """)
        defer { try? FileManager.default.removeItem(at: ws) }
        let s = RebuildScenario()
        let info = RebuildScenario.container(
            id: "old-id",
            labels: s.bindLabels(
                localFolder: ws.path,
                configFile: ws.appendingPathComponent(".devcontainer/devcontainer.json").path
            )
        )
        s.containers = [info]
        s.install()
        let launcher = MockVSCodeLauncher()
        let restore = RebuildOpenSupport.install(launcher: launcher, resolverPath: nil)
        defer { restore() }
        _ = try RebuildCommand.run(options: RebuildOptions(openVSCode: true), runtime: s.runtime)
        try MiniTest.expectEqual(launcher.calls.count, 0, "no launch without code CLI")
        let postAttachIdx = s.mock.calls.firstIndex { $0.arguments.last?.contains("postAttachCustom") == true }
        try MiniTest.expect(postAttachIdx != nil, "open soft-fail must not skip CLI-attach postAttach")
    }),

    ("rebuildPostAttachFailureKeepsContainer", {
        let ws = try TestRepo.makeTempWorkspace(configJSON: """
        {
          "image": "alpine:3.20",
          "postAttachCommand": "echo postAttachCustom"
        }
        """)
        defer { try? FileManager.default.removeItem(at: ws) }
        let s = RebuildScenario()
        let info = RebuildScenario.container(
            id: "old-id",
            labels: s.bindLabels(
                localFolder: ws.path,
                configFile: ws.appendingPathComponent(".devcontainer/devcontainer.json").path
            )
        )
        s.containers = [info]
        s.failingExecSubstrings = ["postAttachCustom"]
        s.install()
        let launcher = MockVSCodeLauncher()
        let restore = RebuildOpenSupport.install(launcher: launcher, resolverPath: "/usr/local/bin/code")
        defer { restore() }
        try MiniTest.expectThrows({
            _ = try RebuildCommand.run(options: RebuildOptions(openVSCode: true), runtime: s.runtime)
        }, validate: { err in
            try MiniTest.expectEqual(rebuildErrorCode(err), CLIErrorCode.lifecycleFailed)
        })
        try MiniTest.expect(
            !s.mock.calls.contains { $0.arguments.first == "delete" && $0.arguments.last == s.newContainerId },
            "postAttach failure keeps the rebuilt container"
        )
    }),

    // ═══════════════════════ Section 5: output shape ═══════════════════════

    ("rebuildJsonSuccessBind", {
        let ws = try TestRepo.makeTempWorkspace(configJSON: #"{"image":"alpine:3.20","remoteUser":"vscode"}"#)
        defer { try? FileManager.default.removeItem(at: ws) }
        let s = RebuildScenario()
        let info = RebuildScenario.container(
            id: "adev-mybase-abc123def456",
            labels: s.bindLabels(
                localFolder: ws.path,
                configFile: ws.appendingPathComponent(".devcontainer/devcontainer.json").path
            )
        )
        s.containers = [info]
        s.install()
        var capturedResult: RebuildResult?
        let stderr = try withEnabledStatusStderr {
            capturedResult = try RebuildCommand.run(options: RebuildOptions(), runtime: s.runtime)
            emitPostSuccessConnectionHintsForTest(
                openVSCode: false,
                nameOrId: capturedResult!.containerName ?? capturedResult!.containerId
            )
        }
        let result = capturedResult!
        let obj = result.jsonObject()
        let parsed = try JSONSerialization.jsonObject(with: result.jsonString().data(using: .utf8)!) as? [String: Any]
        try MiniTest.expect(parsed?["outcome"] as? String == "success", "json round-trip")
        let expectedName = ContainerIdentity.containerName(
            workspacePath: ws.path,
            configPath: ws.appendingPathComponent(".devcontainer/devcontainer.json").path,
            configName: nil
        )
        try MiniTest.expect(parsed?["containerId"] as? String == s.newContainerId, "json containerId")
        try MiniTest.expect(obj["containerName"] == nil, "json omits containerName")
        try MiniTest.expect(obj["gitUrl"] == nil && obj["workspaceVolume"] == nil, "bind json omits volume fields")
        try expectPostSuccessConnectionHints(stderr, nameOrId: expectedName)
    }),

    ("rebuildVolumeResultExposesGitUrlWorkspaceVolume", {
        let s = RebuildScenario()
        let info = RebuildScenario.container(id: "vol-old", labels: s.volumeLabels())
        s.containers = [info]
        s.volumes = ["adev-repo-ws"]
        s.install()
        var rebuildResult: RebuildResult?
        try withRebuildVolumeOverrides {
            rebuildResult = try RebuildCommand.run(options: RebuildOptions(skipPull: true), runtime: s.runtime)
        }
        let result = rebuildResult!
        try MiniTest.expectEqual(result.outcome, "success")
        try MiniTest.expectEqual(result.gitUrl, "https://github.com/example/repo.git")
        try MiniTest.expectEqual(result.workspaceVolume, "adev-repo-ws")
        try MiniTest.expect(result.jsonObject()["gitUrl"] as? String == "https://github.com/example/repo.git", "volume json exposes gitUrl")
    }),

    ("rebuildQuietAndProgressStatus", {
        let ws = try TestRepo.makeTempWorkspace(configJSON: #"{"image":"alpine:3.20"}"#)
        defer { try? FileManager.default.removeItem(at: ws) }
        let s = RebuildScenario()
        let info = RebuildScenario.container(
            id: "old-id",
            labels: s.bindLabels(
                localFolder: ws.path,
                configFile: ws.appendingPathComponent(".devcontainer/devcontainer.json").path
            )
        )
        s.containers = [info]
        s.install()

        let prevEnabled = StatusPrinter.enabled
        defer { StatusPrinter.enabled = prevEnabled }
        StatusPrinter.enabled = true
        var stderr = ""
        try withCapturedStderr({ _ = try RebuildCommand.run(options: RebuildOptions(), runtime: s.runtime) }, capture: &stderr)
        try MiniTest.expect(stderr.contains("==> Creating container"), "progress status emitted")
        try MiniTest.expect(stderr.contains("==> Deleting container"), "delete status emitted")

        StatusPrinter.enabled = false
        var quiet = ""
        try withCapturedStderr({ _ = try RebuildCommand.run(options: RebuildOptions(), runtime: s.runtime) }, capture: &quiet)
        try MiniTest.expect(quiet.isEmpty, "quiet mode suppresses progress")
    }),

    ("rebuildFailureExitCodeIsOne", {
        let s = RebuildScenario()
        let info = RebuildScenario.container(id: "vol-old", labels: s.volumeLabels())
        s.containers = [info]
        s.volumeConfigText = "{ not json"
        s.install()
        try MiniTest.expectThrows({
            _ = try RebuildCommand.run(options: RebuildOptions(skipPull: true), runtime: s.runtime)
        }, validate: { err in
            let cli = err as? CLIError
            try MiniTest.expect(cli != nil, "CLIError surfaced")
            try MiniTest.expectEqual(cli?.exitCode, 1)
        })
    }),

    // ═══════════════════════ Section 6: git credential seeding ═══════════════════════

    ("rebuildBindSeedsFromHostRemotesBeforeHooks", {
        let ws = try TestRepo.makeTempWorkspace(configJSON: """
        {
          "image": "alpine:3.20",
          "remoteUser": "vscode",
          "postCreateCommand": "echo postCreateCustom"
        }
        """)
        defer { try? FileManager.default.removeItem(at: ws) }
        let s = RebuildScenario()
        let info = RebuildScenario.container(
            id: "old-bind-id",
            labels: s.bindLabels(
                localFolder: ws.path,
                configFile: ws.appendingPathComponent(".devcontainer/devcontainer.json").path
            )
        )
        s.containers = [info]
        s.install()
        let hostRunner = RecordingHostProcessRunner()
        hostRunner.handler = { call in
            if call.arguments == ["-C", ws.path, "remote", "-v"] {
                return ProcessResult(
                    exitCode: 0,
                    stdout: Data("origin\thttps://github.com/wcgomes/repo.git (fetch)\n".utf8),
                    stderr: Data()
                )
            }
            return ProcessResult(exitCode: 0, stdout: Data(), stderr: Data())
        }
        let restore = RecordingHostProcessRunner.install(hostRunner)
        defer { restore() }
        let creds = SeedMockCredential()
        creds.results["https://github.com/wcgomes/repo.git"] = .success(
            GitHTTPSCredentials(username: "x-access-token", password: "ghp_secret")
        )
        let result = try RebuildCommand.run(options: RebuildOptions(), runtime: s.runtime, credentials: creds)
        try MiniTest.expectEqual(result.outcome, "success")
        let calls = s.mock.calls.map(\.arguments)
        let deleteIdx = calls.firstIndex { $0.first == "delete" }!
        let createIdx = calls.firstIndex { $0.first == "create" }!
        let startIdx = calls.firstIndex { $0.first == "start" }!
        let seedIdx = calls.firstIndex { $0.first == "exec" && $0.last?.contains("credential.helper") == true }!
        let hookIdx = calls.firstIndex { $0.first == "exec" && $0.last?.contains("postCreateCustom") == true }!
        try MiniTest.expect(deleteIdx < createIdx, "old deleted before new created")
        try MiniTest.expect(createIdx < startIdx, "new created before start")
        try MiniTest.expect(startIdx < seedIdx, "seeding after start")
        try MiniTest.expect(seedIdx < hookIdx, "seeding before first hook exec")
        let seedCall = s.mock.calls[seedIdx]
        let seedArgs = seedCall.arguments
        try MiniTest.expect(seedArgs.contains("-u") && seedArgs.contains("vscode"), "seeds as connection user")
        try MiniTest.expectEqual(
            String(data: seedCall.stdinData ?? Data(), encoding: .utf8) ?? "",
            "protocol=https\nhost=github.com\nusername=x-access-token\npassword=ghp_secret\n\n"
        )
        try MiniTest.expect(!seedArgs.contains(where: { $0.contains("ghp_secret") }))
        try MiniTest.expect(seedCall.environment?.values.contains("ghp_secret") != true)
        let script = seedArgs.last ?? ""
        try MiniTest.expect(script.contains("git config --global --add credential.helper"))
        try MiniTest.expect(!script.contains("ghp_secret"), "secrets never in the exec command")
        try MiniTest.expect(!script.contains("github.com"), "no host/path in the script")
    }),
    ("rebuildVolumeSeedsFromStampedGitURLWithoutEnumeration", {
        let s = RebuildScenario()
        let info = RebuildScenario.container(id: "vol-old", labels: s.volumeLabels())
        s.containers = [info]
        s.install()
        let hostRunner = RecordingHostProcessRunner()
        hostRunner.handler = { _ in
            ProcessResult(exitCode: 0, stdout: Data(), stderr: Data())
        }
        let restore = RecordingHostProcessRunner.install(hostRunner)
        defer { restore() }
        let creds = SeedMockCredential()
        creds.results["https://github.com/example/repo.git"] = .success(
            GitHTTPSCredentials(username: "x-access-token", password: "ghp_secret")
        )
        var result: RebuildResult?
        try withRebuildVolumeOverrides {
            result = try RebuildCommand.run(options: RebuildOptions(skipPull: true), runtime: s.runtime, credentials: creds)
        }
        try MiniTest.expectEqual(result?.outcome, "success")
        let calls = s.mock.calls.map(\.arguments)
        let seedIdx = calls.firstIndex { $0.first == "exec" && $0.last?.contains("credential.helper") == true }!
        let seedCall = s.mock.calls[seedIdx]
        let seedArgs = seedCall.arguments
        try MiniTest.expectEqual(
            String(data: seedCall.stdinData ?? Data(), encoding: .utf8) ?? "",
            "protocol=https\nhost=github.com\nusername=x-access-token\npassword=ghp_secret\n\n",
            "volume seeds from the stamped git_url"
        )
        try MiniTest.expect(!seedArgs.contains(where: { $0.contains("ghp_secret") }))
        try MiniTest.expect(seedCall.environment?.values.contains("ghp_secret") != true)
        try MiniTest.expect(seedArgs.contains("-u") && seedArgs.contains("vscode"))
        try MiniTest.expect(hostRunner.calls.isEmpty, "volume mode must not enumerate host remotes")
    }),
    ("rebuildVolumeMissingGitURLSkipsSilently", {
        let s = RebuildScenario()
        let info = RebuildScenario.container(id: "vol-old", labels: s.volumeLabels(gitURL: ""))
        s.containers = [info]
        s.install()
        let creds = SeedMockCredential()
        creds.defaultResult = .success(GitHTTPSCredentials(username: "u", password: "p"))
        var warnings: [String] = []
        let prevWarning = StatusPrinter.onWarning
        StatusPrinter.onWarning = { warnings.append($0) }
        defer { StatusPrinter.onWarning = prevWarning }
        var result: RebuildResult?
        try withRebuildVolumeOverrides {
            result = try RebuildCommand.run(options: RebuildOptions(skipPull: true), runtime: s.runtime, credentials: creds)
        }
        try MiniTest.expectEqual(result?.outcome, "success")
        try MiniTest.expect(creds.fillCalls.isEmpty, "missing git_url never fills")
        try MiniTest.expect(
            !s.mock.calls.contains { $0.arguments.first == "exec" && $0.arguments.last?.contains("git config --global --add credential.helper") == true },
            "no seeding exec without git_url"
        )
        try MiniTest.expect(warnings.isEmpty, "silent skip emits no warning")
    }),
    ("rebuildSeedingFailureWarnsAndContinues", {
        let ws = try TestRepo.makeTempWorkspace(configJSON: """
        {
          "image": "alpine:3.20",
          "remoteUser": "vscode",
          "postCreateCommand": "echo postCreateCustom"
        }
        """)
        defer { try? FileManager.default.removeItem(at: ws) }
        let s = RebuildScenario()
        let info = RebuildScenario.container(
            id: "old-bind-id",
            labels: s.bindLabels(
                localFolder: ws.path,
                configFile: ws.appendingPathComponent(".devcontainer/devcontainer.json").path
            )
        )
        s.containers = [info]
        s.failingExecSubstrings = ["git-credential-adev"]
        s.install()
        let hostRunner = RecordingHostProcessRunner()
        hostRunner.handler = { call in
            if call.arguments == ["-C", ws.path, "remote", "-v"] {
                return ProcessResult(
                    exitCode: 0,
                    stdout: Data("origin\thttps://github.com/wcgomes/repo.git (fetch)\n".utf8),
                    stderr: Data()
                )
            }
            return ProcessResult(exitCode: 0, stdout: Data(), stderr: Data())
        }
        let restore = RecordingHostProcessRunner.install(hostRunner)
        defer { restore() }
        let creds = SeedMockCredential()
        creds.results["https://github.com/wcgomes/repo.git"] = .success(
            GitHTTPSCredentials(username: "x-access-token", password: "ghp_secret")
        )
        var warnings: [String] = []
        let prevWarning = StatusPrinter.onWarning
        StatusPrinter.onWarning = { warnings.append($0) }
        defer { StatusPrinter.onWarning = prevWarning }
        let result = try RebuildCommand.run(options: RebuildOptions(), runtime: s.runtime, credentials: creds)
        try MiniTest.expectEqual(result.outcome, "success", "seeding failure is soft-fail")
        try MiniTest.expectEqual(warnings.count, 1, "exactly one seeding warning")
        try MiniTest.expect(!warnings[0].contains("ghp_secret"), "warning redacts credential material")
        try MiniTest.expect(!warnings[0].contains("x-access-token"), "warning redacts username")
        let deletes = s.mock.calls.filter { $0.arguments.first == "delete" }
        try MiniTest.expectEqual(deletes.count, 1, "only the old container is deleted")
        try MiniTest.expect(s.mock.calls.contains { $0.arguments.first == "exec" && $0.arguments.last?.contains("postCreateCustom") == true },
            "hooks still run after seeding failure")
    }),
    ("rebuildNeverSeedsOldContainerBeforeDelete", {
        let ws = try TestRepo.makeTempWorkspace(configJSON: #"{"image":"alpine:3.20","remoteUser":"vscode"}"#)
        defer { try? FileManager.default.removeItem(at: ws) }
        let s = RebuildScenario()
        let info = RebuildScenario.container(
            id: "old-bind-id",
            labels: s.bindLabels(
                localFolder: ws.path,
                configFile: ws.appendingPathComponent(".devcontainer/devcontainer.json").path
            )
        )
        s.containers = [info]
        s.install()
        let hostRunner = RecordingHostProcessRunner()
        hostRunner.handler = { call in
            if call.arguments == ["-C", ws.path, "remote", "-v"] {
                return ProcessResult(
                    exitCode: 0,
                    stdout: Data("origin\thttps://github.com/wcgomes/repo.git (fetch)\n".utf8),
                    stderr: Data()
                )
            }
            return ProcessResult(exitCode: 0, stdout: Data(), stderr: Data())
        }
        let restore = RecordingHostProcessRunner.install(hostRunner)
        defer { restore() }
        let creds = SeedMockCredential()
        creds.results["https://github.com/wcgomes/repo.git"] = .success(
            GitHTTPSCredentials(username: "x-access-token", password: "ghp_secret")
        )
        let result = try RebuildCommand.run(options: RebuildOptions(), runtime: s.runtime, credentials: creds)
        try MiniTest.expectEqual(result.outcome, "success")
        let calls = s.mock.calls.map(\.arguments)
        let deleteIdx = calls.firstIndex { $0.first == "delete" }!
        try MiniTest.expect(
            !calls.prefix(deleteIdx + 1).contains { $0.first == "exec" && $0.last?.contains("git config --global --add credential.helper") == true },
            "no seeding exec on the old container before delete"
        )
        let seeds = calls.filter { $0.first == "exec" && $0.last?.contains("git config --global --add credential.helper") == true }
        try MiniTest.expectEqual(seeds.count, 1, "exactly one seeding exec, on the new container")
    }),
    ("rebuildBindIdentityOrderAndConnectionUser", {
        let ws = try TestRepo.makeTempWorkspace(configJSON: """
        {
          "image": "alpine:3.20",
          "remoteUser": "alice",
          "postCreateCommand": "echo identity-hook"
        }
        """)
        defer { try? FileManager.default.removeItem(at: ws) }
        var events: [String] = []
        let reader = RebuildIdentityReaderFixture()
        reader.hostIdentity = GitAuthorIdentity(name: "Ada Lovelace", email: "ada@example.com")
        reader.onHostRead = { events.append("host-read") }
        let s = RebuildScenario()
        let info = RebuildScenario.container(
            id: "old-bind-id",
            labels: s.bindLabels(
                localFolder: ws.path,
                configFile: ws.appendingPathComponent(".devcontainer/devcontainer.json").path,
                remoteUser: "alice"
            )
        )
        s.containers = [info]
        s.install()
        s.mock.handlers.insert({ args in
            if args.first == "delete" { events.append("old-delete") }
            if args.first == "create" { events.append("replacement-create") }
            if args.first == "start" { events.append("replacement-start") }
            if args.first == "exec", let script = args.last {
                if script.contains("git config --global --add credential.helper") {
                    events.append("credential")
                } else if script.contains("git config --global --replace-all user.name") {
                    events.append("global")
                } else if script.contains("chown") {
                    events.append("ownership")
                } else if script.contains("identity-hook") {
                    events.append("hook")
                }
            }
            return nil
        }, at: 0)
        let hostRunner = RecordingHostProcessRunner()
        hostRunner.handler = { call in
            if call.arguments == ["-C", ws.path, "remote", "-v"] {
                return ProcessResult(
                    exitCode: 0,
                    stdout: Data("origin\thttps://github.com/example/repo.git (fetch)\n".utf8),
                    stderr: Data()
                )
            }
            return ProcessResult(exitCode: 0, stdout: Data(), stderr: Data())
        }
        let restoreHost = RecordingHostProcessRunner.install(hostRunner)
        defer { restoreHost() }
        let credentials = SeedMockCredential()
        credentials.results["https://github.com/example/repo.git"] = .success(
            GitHTTPSCredentials(username: "alice", password: "token")
        )
        try withRebuildIdentityReader(reader) {
            _ = try RebuildCommand.run(
                options: RebuildOptions(skipPull: true),
                runtime: s.runtime,
                credentials: credentials
            )
        }
        try MiniTest.expectEqual(reader.hostPaths, [ws.path])
        try MiniTest.expect(reader.guestCalls.isEmpty, "bind mode uses the host local reader")
        try MiniTest.expectEqual(
            events,
            ["host-read", "old-delete", "replacement-create", "replacement-start", "ownership", "credential", "global", "hook"]
        )
        let global = s.mock.calls.first { $0.arguments.last?.contains("git config --global --replace-all user.name") == true }
        try MiniTest.expect(global?.arguments.contains("-u") == true)
        try MiniTest.expect(global?.arguments.contains("alice") == true)
        try MiniTest.expectEqual(
            String(data: global?.stdinData ?? Data(), encoding: .utf8),
            "Ada Lovelace\nada@example.com\n"
        )
    }),
    ("rebuildVolumeIdentityReadsGuestBeforeDelete", {
        var events: [String] = []
        let reader = RebuildIdentityReaderFixture()
        reader.hostIdentity = GitAuthorIdentity(name: "Host", email: "host@example.com")
        reader.guestIdentity = GitAuthorIdentity(name: "Ada Lovelace", email: "ada@example.com")
        reader.onHostRead = { events.append("host-read") }
        reader.onGuestRead = { events.append("guest-read") }
        let s = RebuildScenario()
        let info = RebuildScenario.container(
            id: "old-volume-id",
            labels: s.volumeLabels(remoteUser: "alice")
        )
        s.containers = [info]
        s.volumes = ["adev-repo-ws"]
        s.volumeConfigText = #"{"image":"alpine:3.20","remoteUser":"alice","postCreateCommand":"echo identity-hook"}"#
        s.install()
        s.mock.handlers.insert({ args in
            if args.first == "delete" { events.append("old-delete") }
            if args.first == "create" { events.append("replacement-create") }
            if args.first == "start" { events.append("replacement-start") }
            if args.first == "exec", let script = args.last {
                if script.contains("git config --global --add credential.helper") {
                    events.append("credential")
                } else if script.contains("git config --global --replace-all user.name") {
                    events.append("global")
                } else if script.contains("chown") {
                    events.append("ownership")
                } else if script.contains("identity-hook") {
                    events.append("hook")
                }
            }
            return nil
        }, at: 0)
        let credentials = SeedMockCredential()
        credentials.results["https://github.com/example/repo.git"] = .success(
            GitHTTPSCredentials(username: "alice", password: "token")
        )
        try withRebuildVolumeOverrides {
            try withRebuildIdentityReader(reader) {
                _ = try RebuildCommand.run(
                    options: RebuildOptions(skipPull: true),
                    runtime: s.runtime,
                    credentials: credentials
                )
            }
        }
        try MiniTest.expectEqual(reader.hostPaths, [], "volume mode never uses a host local reader")
        try MiniTest.expectEqual(reader.guestCalls.count, 1)
        try MiniTest.expectEqual(reader.guestCalls[0].containerId, info.id)
        try MiniTest.expectEqual(
            events,
            ["guest-read", "old-delete", "replacement-create", "replacement-start", "ownership", "credential", "global", "hook"]
        )
    }),
    ("rebuildIncompleteIdentitySkipsGlobalWithoutPrompt", {
        let reader = RebuildIdentityReaderFixture()
        reader.guestIdentity = GitAuthorIdentity(name: "Only Name")
        let s = RebuildScenario()
        let info = RebuildScenario.container(id: "old-volume-id", labels: s.volumeLabels())
        s.containers = [info]
        s.volumes = ["adev-repo-ws"]
        s.install()
        try withRebuildVolumeOverrides {
            try withRebuildIdentityReader(reader) {
                _ = try RebuildCommand.run(options: RebuildOptions(skipPull: true), runtime: s.runtime)
            }
        }
        try MiniTest.expect(
            !s.mock.calls.contains { $0.arguments.last?.contains("git config --global --replace-all user.name") == true },
            "incomplete local identity does not invent a global pair"
        )
    }),
    ("rebuildGlobalIdentityFailureWarnsAndContinues", {
        let ws = try TestRepo.makeTempWorkspace(configJSON: #"{"image":"alpine:3.20","postCreateCommand":"echo identity-hook"}"#)
        defer { try? FileManager.default.removeItem(at: ws) }
        let reader = RebuildIdentityReaderFixture()
        reader.hostIdentity = GitAuthorIdentity(name: "Ada", email: "ada@example.com")
        let s = RebuildScenario()
        let info = RebuildScenario.container(
            id: "old-bind-id",
            labels: s.bindLabels(
                localFolder: ws.path,
                configFile: ws.appendingPathComponent(".devcontainer/devcontainer.json").path
            )
        )
        s.containers = [info]
        s.failingExecSubstrings = ["git config --global --replace-all user.name"]
        s.install()
        var warnings: [String] = []
        let previousWarning = StatusPrinter.onWarning
        StatusPrinter.onWarning = { warnings.append($0) }
        defer { StatusPrinter.onWarning = previousWarning }
        try withRebuildIdentityReader(reader) {
            let result = try RebuildCommand.run(options: RebuildOptions(skipPull: true), runtime: s.runtime)
            try MiniTest.expectEqual(result.outcome, "success")
        }
        try MiniTest.expectEqual(warnings.count, 1)
        try MiniTest.expect(warnings[0].contains("Global git author identity synchronization failed"))
        try MiniTest.expectEqual(s.mock.calls.filter { $0.arguments.first == "delete" }.count, 1)
        try MiniTest.expect(!s.mock.calls.contains { $0.arguments.first == "create" && $0.arguments.contains(RecoveryHelper.helperImageReference) })
        try MiniTest.expect(s.mock.calls.contains { $0.arguments.last?.contains("identity-hook") == true })
    }),
    ("rebuildManualLocalIdentityIsCapturedOnNextRebuild", {
        let ws = try TestRepo.makeTempWorkspace(configJSON: #"{"image":"alpine:3.20"}"#)
        defer { try? FileManager.default.removeItem(at: ws) }
        let reader = RebuildIdentityReaderFixture()
        reader.hostIdentity = GitAuthorIdentity(name: "First", email: "first@example.com")
        let s = RebuildScenario()
        let info = RebuildScenario.container(
            id: "old-bind-id",
            labels: s.bindLabels(
                localFolder: ws.path,
                configFile: ws.appendingPathComponent(".devcontainer/devcontainer.json").path
            )
        )
        s.containers = [info]
        s.install()
        try withRebuildIdentityReader(reader) {
            _ = try RebuildCommand.run(options: RebuildOptions(skipPull: true), runtime: s.runtime)
            reader.hostIdentity = GitAuthorIdentity(name: "Second", email: "second@example.com")
            _ = try RebuildCommand.run(options: RebuildOptions(skipPull: true), runtime: s.runtime)
        }
        let writes = s.mock.calls.filter { $0.arguments.last?.contains("git config --global --replace-all user.name") == true }
        try MiniTest.expectEqual(writes.count, 2)
        try MiniTest.expectEqual(
            writes.map { String(data: $0.stdinData ?? Data(), encoding: .utf8) ?? "" },
            ["First\nfirst@example.com\n", "Second\nsecond@example.com\n"]
        )
    }),
    ("rebuildVolumeGlobalFailurePreservesWorkspaceAndHook", {
        let reader = RebuildIdentityReaderFixture()
        reader.guestIdentity = GitAuthorIdentity(name: "Ada", email: "ada@example.com")
        let s = RebuildScenario()
        let info = RebuildScenario.container(
            id: "old-volume-id",
            labels: s.volumeLabels(remoteUser: "alice")
        )
        s.containers = [info]
        s.volumes = ["adev-repo-ws"]
        s.volumeConfigText = #"{"image":"alpine:3.20","remoteUser":"alice","postCreateCommand":"echo identity-hook"}"#
        s.failingExecSubstrings = ["git config --global --replace-all user.name"]
        s.install()
        var warnings: [String] = []
        let previousWarning = StatusPrinter.onWarning
        StatusPrinter.onWarning = { warnings.append($0) }
        defer { StatusPrinter.onWarning = previousWarning }
        try withRebuildVolumeOverrides {
            try withRebuildIdentityReader(reader) {
                let result = try RebuildCommand.run(options: RebuildOptions(skipPull: true), runtime: s.runtime)
                try MiniTest.expectEqual(result.outcome, "success")
            }
        }
        try MiniTest.expectEqual(warnings.count, 1)
        try MiniTest.expectEqual(s.mock.calls.filter { $0.arguments.first == "delete" }.count, 1)
        try MiniTest.expect(!s.mock.calls.contains { $0.arguments.starts(with: ["volume", "delete"]) })
        try MiniTest.expect(s.mock.calls.contains { $0.arguments.last?.contains("identity-hook") == true })
    }),
    ("rebuildIdentityThenHookFailureKeepsReplacementCleanup", {
        let ws = try TestRepo.makeTempWorkspace(configJSON: #"{"image":"alpine:3.20","postCreateCommand":"echo identity-hook"}"#)
        defer { try? FileManager.default.removeItem(at: ws) }
        let reader = RebuildIdentityReaderFixture()
        reader.hostIdentity = GitAuthorIdentity(name: "Ada", email: "ada@example.com")
        let s = RebuildScenario()
        let info = RebuildScenario.container(
            id: "old-bind-id",
            labels: s.bindLabels(
                localFolder: ws.path,
                configFile: ws.appendingPathComponent(".devcontainer/devcontainer.json").path
            )
        )
        s.containers = [info]
        s.failingExecSubstrings = ["identity-hook"]
        s.install()
        try withRebuildIdentityReader(reader) {
            try MiniTest.expectThrows({
                _ = try RebuildCommand.run(
                    options: RebuildOptions(skipPull: true, jsonOutput: true),
                    runtime: s.runtime,
                    isTTY: false
                )
            }) { _ in }
        }
        try MiniTest.expect(
            s.mock.calls.contains { $0.arguments.first == "delete" && $0.arguments.last == s.newContainerId },
            "hook failure still deletes the replacement"
        )
    })
]

// MARK: - FD capture helpers

func withCapturedStderr(_ body: () throws -> Void, capture: inout String) throws {
    try withCapturedFD(fd: 2, body: body, capture: &capture)
}

func withEnabledStatusStderr(_ body: () throws -> Void) throws -> String {
    let previousStatusEnabled = StatusPrinter.enabled
    defer { StatusPrinter.enabled = previousStatusEnabled }
    StatusPrinter.enabled = true
    var stderr = ""
    try withCapturedStderr(body, capture: &stderr)
    return stderr
}

func withCapturedStdout(_ body: () throws -> Void, capture: inout String) throws {
    try withCapturedFD(fd: 1, body: body, capture: &capture)
}

private func withCapturedFD(fd: Int32, body: () throws -> Void, capture: inout String) throws {
    let saved = dup(fd)
    let pipe = Pipe()
    dup2(pipe.fileHandleForWriting.fileDescriptor, fd)
    pipe.fileHandleForWriting.closeFile()
    do {
        try body()
        dup2(saved, fd)
        close(saved)
        capture = String(data: pipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
    } catch {
        dup2(saved, fd)
        close(saved)
        capture = String(data: pipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
        throw error
    }
}

final class RebuildCounter: @unchecked Sendable {
    var count = 0
}
