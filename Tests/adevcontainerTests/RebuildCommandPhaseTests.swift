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
        try MiniTest.expectEqual(result.containerName, info.id)
        let deletes = s.mock.calls.filter { $0.arguments.first == "delete" }
        try MiniTest.expectEqual(deletes.count, 1, "old container deleted exactly once")
        try MiniTest.expectEqual(deletes.first?.arguments.last, info.id)
        let creates = s.mock.calls.filter { $0.arguments.first == "create" }
        try MiniTest.expectEqual(creates.count, 1, "new container created once")
        let createArgs = creates[0].arguments
        try MiniTest.expect(createArgs.contains("adev-mybase-abc123def456"), "create reuses old container name")
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
        let derivedTag = DerivedImageTag.compute(
            baseImage: "alpine:3.20",
            ordered: [try rebuildOrderedFeature(ref: ref, fixture: fixture, options: ["greeting": .string("hi")])],
            nameBase: "mybase"
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
        let derivedTag = DerivedImageTag.compute(
            baseImage: "alpine:3.20",
            ordered: [try rebuildOrderedFeature(ref: ref, fixture: fixture, options: ["greeting": .string("hi")])],
            nameBase: "mybase"
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
        let createArgs = s.mock.calls.first { $0.arguments.first == "create" }!.arguments
        try MiniTest.expect(createArgs.contains("adev-mybase-abc123def456"), "keeps old container name")
        try MiniTest.expect(createArgs.contains("devcontainer.managed=adevcontainer"), "managed label preserved")
        try MiniTest.expect(createArgs.contains("devcontainer.workspace_mode=bind"), "workspace_mode label preserved")
        try MiniTest.expect(createArgs.contains("devcontainer.local_folder=\(ws.path)"), "local_folder preserved")
        let cfgFile = ws.appendingPathComponent(".devcontainer/devcontainer.json").path
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
        // (a) stamped user == effective → no chown.
        let same = RebuildScenario()
        let infoSame = RebuildScenario.container(id: "vol-a", labels: same.volumeLabels(remoteUser: "vscode"))
        same.containers = [infoSame]
        same.volumeConfigText = #"{"image":"alpine:3.20","remoteUser":"vscode"}"#
        same.install()
        try withRebuildVolumeOverrides {
            _ = try RebuildCommand.run(options: RebuildOptions(skipPull: true), runtime: same.runtime)
        }
        let execsSame = same.mock.calls.compactMap { $0.arguments.last }
        try MiniTest.expect(!execsSame.contains { $0.contains("chown") }, "no chown when user unchanged")

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
        let postAttachIdx = s.mock.calls.firstIndex { $0.arguments.last?.contains("postAttach") == true }
        try MiniTest.expect(postAttachIdx == nil, "postAttach skipped without --vscode")
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

    ("rebuildVscodeOpenSoftFailSucceedsNoPostAttach", {
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
        try MiniTest.expect(postAttachIdx == nil, "postAttach skipped when open did not succeed")
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
        try MiniTest.expect(parsed?["containerId"] as? String == s.newContainerId, "json containerId")
        try MiniTest.expect(obj["containerName"] as? String == "adev-mybase-abc123def456", "json containerName")
        try MiniTest.expect(obj["gitUrl"] == nil && obj["workspaceVolume"] == nil, "bind json omits volume fields")
        try expectPostSuccessConnectionHints(stderr, nameOrId: "adev-mybase-abc123def456")
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
