import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif
@testable import ADevContainerLib

enum IntegrationSupport {
    /// When set, replaces `image` in the temp copy only (fixture files stay canonical).
    static var testImageOverride: String? {
        ProcessInfo.processInfo.environment["ADEVCONTAINER_TEST_IMAGE"]
    }

    static func containerRuntimeIfAvailable() -> AppleContainerRuntime? {
        let runtime = AppleContainerRuntime()
        guard runtime.binaryExists() else { return nil }
        do {
            let status = try runtime.systemStatus()
            let s = (status["status"] as? String ?? "").lowercased()
            guard s == "running" else { return nil }
            return runtime
        } catch {
            return nil
        }
    }

    static func fixtureURL(_ fileName: String) -> URL {
        TestRepo.root().appendingPathComponent("Tests/Fixtures/\(fileName)")
    }

    /// Loads a real fixture into a temp workspace. Optionally overrides image and remaps
    /// forwardPorts in the temp copy only so fixture files stay canonical for unit tests.
    /// E2E remaps ports to high free ports to avoid host conflicts.
    static func makeWorkspaceFromFixture(_ fileName: String) throws -> (workspace: URL, config: [String: Any]) {
        let data = try Data(contentsOf: fixtureURL(fileName))
        guard var obj = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw MiniTest.Failure(message: "fixture \(fileName) is not a JSON object")
        }

        if let override = testImageOverride {
            obj["image"] = override
        }

        if let ports = obj["forwardPorts"] as? [Int], !ports.isEmpty {
            let base = 28000 + (abs(UUID().uuidString.hashValue) % 2000)
            var map: [String: String] = [:]
            var newPorts: [Int] = []
            for (i, p) in ports.enumerated() {
                let np = base + i
                map[String(p)] = String(np)
                newPorts.append(np)
            }
            obj["forwardPorts"] = newPorts
            if let attrs = obj["portsAttributes"] as? [String: Any] {
                var newAttrs: [String: Any] = [:]
                for (k, v) in attrs {
                    newAttrs[map[k] ?? k] = v
                }
                obj["portsAttributes"] = newAttrs
            }
        }

        let out = try JSONSerialization.data(withJSONObject: obj, options: [.prettyPrinted, .sortedKeys])
        let json = String(data: out, encoding: .utf8) ?? "{}"
        let ws = try TestRepo.makeTempWorkspace(configJSON: json, prefix: "adev-int")
        return (ws, obj)
    }

    static func cleanup(workspace: URL, runtime: AppleContainerRuntime) {
        if let resolved = try? ConfigResolver.resolve(
            workspacePath: workspace.path,
            localEnv: ProcessInfo.processInfo.environment
        ) {
            do {
                if try runtime.findByName(resolved.containerName) != nil {
                    try runtime.delete(nameOrId: resolved.containerName, force: true)
                }
            } catch {
                if !isAbsentContainerError(error) {
                    reportCleanupFailure(containerName: resolved.containerName, error: error)
                }
            }
        }
        try? FileManager.default.removeItem(at: workspace)
    }

    private static func isAbsentContainerError(_ error: Error) -> Bool {
        if let cliError = error as? CLIError, cliError.code == CLIErrorCode.containerNotFound {
            return true
        }
        let detail = ((error as? CLIError)?.message ?? error.localizedDescription).lowercased()
        return detail.contains("notfound") || detail.contains("not found")
    }

    private static func reportCleanupFailure(containerName: String, error: Error) {
        let detail: String
        if let cliError = error as? CLIError {
            detail = "error[\(cliError.code)]: \(cliError.message)"
        } else {
            detail = error.localizedDescription
        }
        FileHandle.standardError.write(
            Data("warning: Integration cleanup failed for '\(containerName)': \(detail)\n".utf8)
        )
    }

    /// Copy `Tests/Fixtures/features-sample/{sample-a,sample-b}` into workspace `.devcontainer/features/`.
    static func copySampleFeatures(into workspace: URL, names: [String] = ["sample-a", "sample-b"]) throws {
        let fm = FileManager.default
        let destRoot = workspace.appendingPathComponent(".devcontainer/features", isDirectory: true)
        try fm.createDirectory(at: destRoot, withIntermediateDirectories: true)
        for name in names {
            let src = TestRepo.root()
                .appendingPathComponent("Tests/Fixtures/features-sample/\(name)")
            let dest = destRoot.appendingPathComponent(name)
            if fm.fileExists(atPath: dest.path) {
                try fm.removeItem(at: dest)
            }
            try fm.copyItem(at: src, to: dest)
        }
    }

    static func runFixtureE2E(
        fixtureFile: String,
        ensureKube: Bool = false,
        smokeCommand: [String] = ["true"],
        prepareWorkspace: ((URL) throws -> Void)? = nil,
        extra: ((URL, AppleContainerRuntime, [String: Any]) throws -> Void)? = nil
    ) throws {
        guard let runtime = containerRuntimeIfAvailable() else {
            try MiniTest.skip("Apple container unavailable")
        }

        if ensureKube {
            let kube = URL(fileURLWithPath: NSHomeDirectory()).appendingPathComponent(".kube", isDirectory: true)
            try FileManager.default.createDirectory(at: kube, withIntermediateDirectories: true)
        }

        let (ws, config) = try makeWorkspaceFromFixture(fixtureFile)
        defer { cleanup(workspace: ws, runtime: runtime) }

        if let prepareWorkspace {
            try prepareWorkspace(ws)
        }

        let up = try UpCommand.run(
            options: UpOptions(workspacePath: ws.path, jsonOutput: true, skipPull: true),
            runtime: runtime
        )
        try MiniTest.expectEqual(up.outcome, "success")
        try MiniTest.expect(!up.containerId.isEmpty)
        let managedName = up.containerName ?? up.containerId

        let code = try ExecCommand.run(
            options: ExecOptions(command: smokeCommand, name: managedName),
            runtime: runtime
        )
        try MiniTest.expectEqual(code, 0)

        let inspect = try InspectCommand.run(name: managedName, runtime: runtime)
        try MiniTest.expectEqual(inspect.state.lowercased(), "running")
        try MiniTest.expectEqual(
            inspect.labels[ContainerIdentity.labelManaged],
            ContainerIdentity.managedValue
        )
        try MiniTest.expectEqual(
            inspect.labels[ContainerIdentity.labelWorkspaceMode],
            ContainerIdentity.workspaceModeBind
        )

        if let extra {
            try extra(ws, runtime, config)
        }

        try DeleteCommand.run(name: managedName, runtime: runtime)
        try MiniTest.expect(try runtime.findByName(up.containerId) == nil)
    }
}

nonisolated(unsafe) let integrationTests: [(String, () throws -> Void)] = [
    ("fixtureE2E_smoke", {
        try IntegrationSupport.runFixtureE2E(fixtureFile: "smoke.json")
    }),
    ("fixtureE2E_envUser", {
        try IntegrationSupport.runFixtureE2E(fixtureFile: "env-user.json", extra: { ws, runtime, _ in
            let listed = try ManagedContainers.list(runtime: runtime)
            let wsPath = (ws.path as NSString).standardizingPath
            let match = listed.first {
                ($0.labels[ContainerIdentity.labelLocalFolder] as NSString?)?.standardizingPath == wsPath
            }
            try MiniTest.expect(match != nil, "expected managed container for test workspace")
            let name = match!.name
            let inspected = try InspectCommand.run(name: name, runtime: runtime)
            try MiniTest.expectEqual(inspected.remoteUser, "vscode")
            try MiniTest.expectEqual(
                inspected.remoteWorkspaceFolder,
                "/workspaces/\(ws.lastPathComponent)"
            )
            let code = try ExecCommand.run(
                options: ExecOptions(
                    command: [
                        "sh", "-lc",
                        "test \"$ENVIRONMENT\" = Development && test \"$WORKSPACE_BASENAME\" = '\(ws.lastPathComponent)'"
                    ],
                    name: name
                ),
                runtime: runtime
            )
            try MiniTest.expectEqual(code, 0)
        })
    }),
    ("fixtureE2E_mountsPorts", {
        try IntegrationSupport.runFixtureE2E(fixtureFile: "mounts-ports.json", ensureKube: true, extra: { ws, runtime, config in
            let listed = try ManagedContainers.list(runtime: runtime)
            let wsPath = (ws.path as NSString).standardizingPath
            let match = listed.first {
                ($0.labels[ContainerIdentity.labelLocalFolder] as NSString?)?.standardizingPath == wsPath
            }
            try MiniTest.expect(match != nil, "expected managed container for test workspace")
            let name = match!.name
            let code = try ExecCommand.run(
                options: ExecOptions(
                    command: ["sh", "-lc", "test -d /home/vscode/.config/opencode && test -d /home/vscode/.kube"],
                    name: name
                ),
                runtime: runtime
            )
            try MiniTest.expectEqual(code, 0)

            let inspect = try InspectCommand.run(name: name, runtime: runtime)
            // portsAttributes not stored on labels in v1
            try MiniTest.expect(inspect.portsAttributes.isEmpty)
            _ = config
            _ = ws
        })
    }),
    ("fixtureE2E_lifecycle", {
        // postCreate is "echo postCreate-ok && pwd" — success of up + exec is enough
        try IntegrationSupport.runFixtureE2E(fixtureFile: "lifecycle.json")
    }),
    ("fixtureE2E_lifecycleHooks", {
        // Lifecycle hooks are echo-only; up success implies create-path order completed.
        try IntegrationSupport.runFixtureE2E(fixtureFile: "lifecycle-hooks.json")
    }),
    ("fixtureE2E_runargsHost", {
        // Allowlisted runArgs + hostRequirements enforce+apply (8gb/4 cpus OK on typical Macs).
        try IntegrationSupport.runFixtureE2E(fixtureFile: "runargs-host.json")
    }),
    ("fixtureE2E_featuresNode_skipsWithoutNetworkOrRuntime", {
        // Live OCI fetch + container build requires network and Apple container.
        // Default suite must skip cleanly when either is unavailable.
        guard IntegrationSupport.containerRuntimeIfAvailable() != nil else {
            try MiniTest.skip("Apple container unavailable")
        }
        // Probe network to ghcr.io without pulling full feature (quick HEAD/GET).
        var reachable = false
        if let url = URL(string: "https://ghcr.io/v2/") {
            final class StatusBox: @unchecked Sendable { var value = 0 }
            let box = StatusBox()
            let sem = DispatchSemaphore(value: 0)
            let task = URLSession.shared.dataTask(with: url) { _, response, _ in
                box.value = (response as? HTTPURLResponse)?.statusCode ?? -1
                sem.signal()
            }
            task.resume()
            if sem.wait(timeout: .now() + 3) == .timedOut {
                task.cancel()
            } else {
                // ghcr often returns 401 for unauthenticated /v2/ — that still means reachable.
                reachable = box.value > 0
            }
        }
        guard reachable else {
            try MiniTest.skip("network unavailable for ghcr.io feature pull")
        }
        // Full live features-node E2E is optional and expensive; skip unless explicitly enabled.
        guard ProcessInfo.processInfo.environment["ADEVCONTAINER_FEATURES_E2E"] == "1" else {
            try MiniTest.skip("set ADEVCONTAINER_FEATURES_E2E=1 to run live features-node up")
        }
        // create argv expands feature PATH `${PATH}` so bare `node` is on PATH.
        try IntegrationSupport.runFixtureE2E(
            fixtureFile: "features-node.json",
            smokeCommand: ["node", "--version"]
        )
    }),
    ("fixtureE2E_featuresTriple_skipsWithoutNetworkOrRuntime", {
        guard IntegrationSupport.containerRuntimeIfAvailable() != nil else {
            try MiniTest.skip("Apple container unavailable")
        }
        var reachable = false
        if let url = URL(string: "https://ghcr.io/v2/") {
            final class StatusBox: @unchecked Sendable { var value = 0 }
            let box = StatusBox()
            let sem = DispatchSemaphore(value: 0)
            let task = URLSession.shared.dataTask(with: url) { _, response, _ in
                box.value = (response as? HTTPURLResponse)?.statusCode ?? -1
                sem.signal()
            }
            task.resume()
            if sem.wait(timeout: .now() + 3) == .timedOut {
                task.cancel()
            } else {
                reachable = box.value > 0
            }
        }
        guard reachable else {
            try MiniTest.skip("network unavailable for ghcr.io feature pull")
        }
        guard ProcessInfo.processInfo.environment["ADEVCONTAINER_FEATURES_E2E"] == "1" else {
            try MiniTest.skip("set ADEVCONTAINER_FEATURES_E2E=1 to run live features-triple up")
        }
        try IntegrationSupport.runFixtureE2E(
            fixtureFile: "features-triple.json",
            smokeCommand: [
                "/bin/bash", "-lc",
                "node --version && git --version && gh --version"
            ]
        )
    }),
    ("fixtureE2E_featuresLocal", {
        // Local path features only — no ghcr / ADEVCONTAINER_FEATURES_E2E gate.
        // Requires Apple container; uses DefaultFeatureFetcher + sample packages on disk.
        guard IntegrationSupport.containerRuntimeIfAvailable() != nil else {
            try MiniTest.skip("Apple container unavailable")
        }
        try IntegrationSupport.runFixtureE2E(
            fixtureFile: "features-local.json",
            smokeCommand: [
                "/bin/bash", "-lc",
                "test -f /usr/local/etc/adev-features/installed.txt"
                    + " && grep sample-a /usr/local/etc/adev-features/installed.txt"
                    + " && grep sample-b /usr/local/etc/adev-features/installed.txt"
            ],
            prepareWorkspace: { ws in
                try IntegrationSupport.copySampleFeatures(into: ws)
            }
        )
    }),

    // MARK: - Recovery E2E (gated by ADEVCONTAINER_RECOVERY_E2E=1)

    ("recoveryE2E_cloneOriginAndNonTTYRecoveryFlow", {
        // Spec §13.1–13.4: clone-origin volume workspace → post-delete hard failure →
        // non-TTY/JSON recovery → edit temp → named retry → final verify + prune/cleanup.
        try RecoveryE2ESupport.runNonTTYJsonRecoveryFlow()
    }),
    ("recoveryE2E_ttyInteractivePath_skippedByDefault", {
        // Fully automated TTY editor path is not part of the default gated suite.
        // Set ADEVCONTAINER_RECOVERY_E2E_TTY=1 only after non-TTY flow is green; even then
        // this case documents the manual operator steps rather than driving a real $VISUAL.
        guard ProcessInfo.processInfo.environment["ADEVCONTAINER_RECOVERY_E2E"] == "1" else {
            try MiniTest.skip("set ADEVCONTAINER_RECOVERY_E2E=1 to surface recovery TTY manual steps")
        }
        guard ProcessInfo.processInfo.environment["ADEVCONTAINER_RECOVERY_E2E_TTY"] == "1" else {
            try MiniTest.skip(
                "TTY recovery is manual: "
                    + "1) run non-TTY flow without retry cleanup; "
                    + "2) VISUAL=\"$EDITOR\" adevcontainer rebuild --name <helper>; "
                    + "3) edit secure temp, save, exit 0; "
                    + "4) confirm final container + helper/temp cleanup. "
                    + "Set ADEVCONTAINER_RECOVERY_E2E_TTY=1 to acknowledge (still skip-automated)."
            )
        }
        try MiniTest.skip(
            "Automated TTY editor E2E is intentionally not implemented; "
                + "use the manual steps in the skip message above"
        )
    })
]

// MARK: - Recovery E2E support

/// Records every Apple `container` argv while delegating to the real Foundation runner.
final class RecordingProcessRunner: ProcessRunning, @unchecked Sendable {
    private let inner = FoundationProcessRunner()
    private let lock = NSLock()
    private var _calls: [[String]] = []

    var calls: [[String]] {
        lock.lock(); defer { lock.unlock() }
        return _calls
    }

    func run(
        executable: String,
        arguments: [String],
        environment: [String: String]?,
        currentDirectory: String?,
        stdinData: Data?
    ) throws -> ProcessResult {
        lock.lock()
        _calls.append(arguments)
        lock.unlock()
        return try inner.run(
            executable: executable,
            arguments: arguments,
            environment: environment,
            currentDirectory: currentDirectory,
            stdinData: stdinData
        )
    }

    func reset() {
        lock.lock()
        _calls.removeAll()
        lock.unlock()
    }

    /// Volume create/delete invocations (workspace/config safety assertions).
    func volumeMutations() -> [[String]] {
        calls.filter { args in
            args.first == "volume"
                && (args.dropFirst().first == "create" || args.dropFirst().first == "delete")
        }
    }

    /// True when any recorded argv looks like `container cp` (recovery must not use it).
    func usedContainerCp() -> Bool {
        calls.contains { args in
            guard let first = args.first else { return false }
            return first == "cp" || first == "copy"
        }
    }
}

enum RecoveryE2ESupport {
    static let gateEnv = "ADEVCONTAINER_RECOVERY_E2E"
    static let workspaceSentinelName = "ADEV_RECOVERY_SENTINEL"
    static let workspaceSentinelValue = "workspace-sentinel-v1"
    static let configVolSentinelPath = "/recovery-cfg-vol/sentinel.txt"
    static let configVolSentinelValue = "config-vol-sentinel-v1"
    static let recoveredMarker = "adev-recovery-edited-ok"

    /// Skip only when the explicit gate is off or a hard runtime prerequisite is absent.
    /// When the gate is on and runtime is present, callers must not skip for brokenness.
    static func requireRuntime() throws -> AppleContainerRuntime {
        guard ProcessInfo.processInfo.environment[gateEnv] == "1" else {
            try MiniTest.skip("set \(gateEnv)=1 to run live recovery E2E")
        }
        guard let runtime = IntegrationSupport.containerRuntimeIfAvailable() else {
            try MiniTest.skip("Apple container unavailable (prerequisite)")
        }
        // Helper image must be inspectable or pullable; preflight here so a missing image
        // is reported as a prerequisite skip rather than a mid-flow false green.
        do {
            _ = try RecoveryHelper.preflightImage(runtime: runtime, pullIfMissing: true)
        } catch {
            try MiniTest.skip(
                "pinned recovery helper image unavailable: \(error)"
            )
        }
        return runtime
    }

    static func authorEnv() -> [String: String] {
        var env = ProcessInfo.processInfo.environment
        env["ADEVCONTAINER_GIT_AUTHOR_NAME"] = "Recovery E2E"
        env["ADEVCONTAINER_GIT_AUTHOR_EMAIL"] = "recovery-e2e@example.com"
        return env
    }

    static func installFeatureOverrides() -> () -> Void {
        let gitFixture = TestRepo.root()
            .appendingPathComponent("Tests/Fixtures/features-sample/git").path
        // Apple `container build` cannot reliably transfer build context from
        // /var/folders TemporaryDirectory (context transfers as ~31B). Use the
        // product cache root under ~/Library/Caches so COPY feature-N works.
        let cache = FeatureCache.defaultRoot()
            + "/rec-e2e-\(UUID().uuidString.lowercased())"
        let prevRebuildFetcher = RebuildCommand.featuresFetcherOverride
        let prevRebuildCache = RebuildCommand.featuresCacheRootOverride
        let fetcher = MockFeatureFetcher(packagesByRef: [
            FeatureGitEnsure.gitFeatureRef: gitFixture
        ])
        RebuildCommand.featuresFetcherOverride = fetcher
        RebuildCommand.featuresCacheRootOverride = cache
        return {
            RebuildCommand.featuresFetcherOverride = prevRebuildFetcher
            RebuildCommand.featuresCacheRootOverride = prevRebuildCache
            try? FileManager.default.removeItem(atPath: cache)
        }
    }

    struct OriginWorkspace {
        let gitURL: String
        let containerName: String
        let workspaceVolume: String
        let workspaceFolder: String
        let configVolumeName: String
        let configPathInContainer: String
        let configJSON: String
        let failConfigJSON: String
        let recoveredConfigJSON: String
        let hostScratch: URL
    }

    /// Bootstrap a clone-origin volume workspace without `CloneCommand`.
    ///
    /// This host's Apple container VMs have no outbound DNS and cannot reach host
    /// `file://` paths, so a live in-container `git clone` populate is impossible.
    /// Recovery E2E still needs real volumes + labels + Apple runtime; we stamp
    /// clone-origin identity and seed the volume tree via exec (no `container cp`).
    static func bootstrapCloneOriginWorkspace(
        runtime: AppleContainerRuntime
    ) throws -> OriginWorkspace {
        let fm = FileManager.default
        let token = String(UUID().uuidString.prefix(8)).lowercased()
        let scratch = fm.temporaryDirectory
            .appendingPathComponent("adev-rec-e2e-\(token)", isDirectory: true)
        try fm.createDirectory(at: scratch, withIntermediateDirectories: true)

        let configVolume = "adev-rec-e2e-cfg-\(token)"
        let image = IntegrationSupport.testImageOverride
            ?? "mcr.microsoft.com/devcontainers/base:ubuntu"
        let baseConfig: [String: Any] = [
            "name": "RecoveryE2E",
            "image": image,
            "remoteUser": "vscode",
            "mounts": [[
                "type": "volume",
                "source": configVolume,
                "target": "/recovery-cfg-vol"
            ]],
            "postCreateCommand":
                "printf '%s\\n' '\(configVolSentinelValue)' > \(configVolSentinelPath)"
        ]
        let configJSON = try jsonString(baseConfig)
        var failObj = baseConfig
        failObj["postCreateCommand"] = "exit 42"
        let failJSON = try jsonString(failObj)
        var okObj = baseConfig
        okObj["postCreateCommand"] =
            "printf '%s\\n' '\(recoveredMarker)' > /tmp/adev-recovered-marker "
            + "&& test -f \(configVolSentinelPath) "
            + "&& test -f \(workspaceSentinelName)"
        okObj["containerEnv"] = ["ADEV_RECOVERY_E2E_MARKER": recoveredMarker]
        let okJSON = try jsonString(okObj)

        let hostConfigDir = scratch.appendingPathComponent(".devcontainer", isDirectory: true)
        try fm.createDirectory(at: hostConfigDir, withIntermediateDirectories: true)
        try configJSON.write(
            to: hostConfigDir.appendingPathComponent("devcontainer.json"),
            atomically: true,
            encoding: .utf8
        )

        let gitURL = "https://example.com/adev-rec-e2e-\(token).git"
        let identity = ContainerIdentity.volumeModeIdentity(
            gitURL: gitURL,
            configRelativePath: ".devcontainer/devcontainer.json",
            configName: "RecoveryE2E"
        )
        let resolved = try ConfigResolver.resolve(
            workspacePath: scratch.path,
            localEnv: authorEnv(),
            workspaceFolderBasename: ContainerIdentity.repoBasename(fromGitURL: gitURL)
        )
        var effective = resolved.config
        // Bootstrap skips Features; rebuild injects git:1 via mock fetcher.
        effective.features = []

        let configHash = ContainerIdentity.configHash(from: effective.hashMaterial())
        let configVolumeNames = effective.mounts.filter { $0.type == .volume }.map(\.source)
        let labels = ContainerIdentity.volumeModeLabels(
            identity: identity,
            configHash: configHash,
            configVolumeNames: configVolumeNames,
            workspaceFolder: effective.workspaceFolder,
            remoteUser: effective.effectiveUser
        )
        let request = CreateRequest.fromVolumeMode(
            resolved: effective,
            identityName: identity.containerName,
            labels: labels,
            configHash: configHash,
            workspaceVolumeName: identity.workspaceVolumeName,
            platform: ContainerPlatform.defaultLinuxPlatform
        )

        if try runtime.findByName(identity.containerName) != nil {
            try runtime.delete(nameOrId: identity.containerName, force: true)
        }
        if try runtime.volumeExists(identity.workspaceVolumeName) {
            try runtime.deleteVolume(name: identity.workspaceVolumeName)
        }
        if try runtime.volumeExists(configVolume) {
            try runtime.deleteVolume(name: configVolume)
        }

        let id = try runtime.create(request: request, ensureVolumes: true)
        try runtime.start(nameOrId: id)
        try WorkspaceOwnership.ensureWorkspaceWritableByRemoteUser(
            containerId: id,
            workspaceFolder: effective.workspaceFolder,
            remoteUser: effective.effectiveUser,
            runtime: runtime
        )

        let configPath = "\(effective.workspaceFolder)/.devcontainer/devcontainer.json"
        // Seed dirs + sentinels as root; write config bytes via base64 (no container cp).
        let seedScript = """
        set -e
        ws="$1"
        mkdir -p "$ws/.devcontainer" /recovery-cfg-vol
        printf '%s\\n' '\(workspaceSentinelValue)' > "$ws/\(workspaceSentinelName)"
        printf '%s\\n' '\(configVolSentinelValue)' > \(configVolSentinelPath)
        if id -u vscode >/dev/null 2>&1; then
          chown -R vscode:vscode "$ws" /recovery-cfg-vol 2>/dev/null || true
        fi
        """
        let seed = try runtime.exec(
            nameOrId: id,
            command: ["sh", "-c", seedScript, "adev-rec-e2e-seed", effective.workspaceFolder],
            user: "root",
            workdir: "/",
            env: [:]
        )
        guard seed.succeeded else {
            throw MiniTest.Failure(
                message: "failed to seed clone-origin volume: \(seed.stderrString)"
            )
        }
        try writeConfigInContainer(
            runtime: runtime,
            containerName: identity.containerName,
            configPath: configPath,
            json: configJSON
        )

        return OriginWorkspace(
            gitURL: identity.normalizedGitURL,
            containerName: identity.containerName,
            workspaceVolume: identity.workspaceVolumeName,
            workspaceFolder: effective.workspaceFolder,
            configVolumeName: configVolume,
            configPathInContainer: configPath,
            configJSON: configJSON,
            failConfigJSON: failJSON,
            recoveredConfigJSON: okJSON,
            hostScratch: scratch
        )
    }

    static func jsonString(_ object: [String: Any]) throws -> String {
        let data = try JSONSerialization.data(
            withJSONObject: object,
            options: [.prettyPrinted, .sortedKeys]
        )
        guard let s = String(data: data, encoding: .utf8) else {
            throw MiniTest.Failure(message: "failed to encode JSON config")
        }
        return s
    }

    static func writeConfigInContainer(
        runtime: AppleContainerRuntime,
        containerName: String,
        configPath: String,
        json: String
    ) throws {
        // Pipe bytes through exec via base64 (no container cp). Use root: recovery helper
        // is Alpine without the stamped vscode user.
        let b64 = Data(json.utf8).base64EncodedString()
        let script =
            "mkdir -p \"$(dirname \"$1\")\" && printf '%s' \"$2\" | base64 -d > \"$1\""
        let result = try runtime.exec(
            nameOrId: containerName,
            command: ["sh", "-c", script, "adev-rec-e2e-write", configPath, b64],
            user: "root",
            workdir: "/",
            env: [:]
        )
        try MiniTest.expectEqual(result.exitCode, 0, "failed to write config into volume: \(result.stderrString)")
        let readBack = try runtime.readFile(nameOrId: containerName, path: configPath)
        try MiniTest.expectEqual(
            String(data: readBack, encoding: .utf8),
            json,
            "in-volume config write did not stick"
        )
    }

    /// Exec as root (helper Alpine has no stamped remoteUser).
    @discardableResult
    static func execRoot(
        runtime: AppleContainerRuntime,
        nameOrId: String,
        command: [String],
        workdir: String? = nil
    ) throws -> Int32 {
        let result = try runtime.exec(
            nameOrId: nameOrId,
            command: command,
            user: "root",
            workdir: workdir,
            env: [:]
        )
        return result.exitCode
    }

    static func cleanupResources(
        runtime: AppleContainerRuntime,
        containerName: String?,
        workspaceVolume: String?,
        configVolume: String?,
        sessionTempFile: String?,
        bareRoot: URL?
    ) {
        if let containerName, !containerName.isEmpty {
            try? runtime.delete(nameOrId: containerName, force: true)
        }
        if let workspaceVolume, !workspaceVolume.isEmpty {
            try? runtime.deleteVolume(name: workspaceVolume)
        }
        if let configVolume, !configVolume.isEmpty {
            try? runtime.deleteVolume(name: configVolume)
        }
        if let sessionTempFile {
            let sessionDir = URL(fileURLWithPath: sessionTempFile).deletingLastPathComponent()
            try? FileManager.default.removeItem(at: sessionDir)
        }
        if let bareRoot {
            try? FileManager.default.removeItem(at: bareRoot)
        }
    }

    static func runNonTTYJsonRecoveryFlow() throws {
        let baseRuntime = try requireRuntime()
        let restoreFeatures = installFeatureOverrides()
        defer { restoreFeatures() }

        let recorder = RecordingProcessRunner()
        let runtime = AppleContainerRuntime(
            executablePath: baseRuntime.executablePath,
            runner: recorder
        )

        var containerName: String?
        var workspaceVolume: String?
        var configVolumeName: String?
        var sessionTemp: String?
        var hostScratch: URL?
        var keepArtifactsOnFailure = false
        defer {
            if !keepArtifactsOnFailure {
                cleanupResources(
                    runtime: runtime,
                    containerName: containerName,
                    workspaceVolume: workspaceVolume,
                    configVolume: configVolumeName,
                    sessionTempFile: sessionTemp,
                    bareRoot: hostScratch
                )
            }
        }

        // ── 13.1 clone-origin volume workspace + labels + sentinels ──
        // Bootstrapped (not CloneCommand): guest VMs here lack DNS/host file:// reachability.
        let origin = try bootstrapCloneOriginWorkspace(runtime: runtime)
        containerName = origin.containerName
        workspaceVolume = origin.workspaceVolume
        configVolumeName = origin.configVolumeName
        hostScratch = origin.hostScratch
        let name = origin.containerName
        let wsVol = origin.workspaceVolume
        try MiniTest.expect(wsVol.hasSuffix("-ws"), "workspace volume is *-ws: \(wsVol)")

        let inspect = try InspectCommand.run(name: name, runtime: runtime)
        try MiniTest.expectEqual(
            inspect.labels[ContainerIdentity.labelManaged],
            ContainerIdentity.managedValue
        )
        try MiniTest.expectEqual(
            inspect.labels[ContainerIdentity.labelWorkspaceMode],
            ContainerIdentity.workspaceModeVolume
        )
        try MiniTest.expectEqual(inspect.labels[ContainerIdentity.labelWorkspaceVolume], wsVol)
        try MiniTest.expect(
            !(inspect.labels[ContainerIdentity.labelGitURL] ?? "").isEmpty,
            "git_url stamp present"
        )
        try MiniTest.expectEqual(
            inspect.labels[ContainerIdentity.labelConfigFile],
            ".devcontainer/devcontainer.json"
        )
        let workspaceFolder = inspect.labels[ContainerIdentity.labelWorkspaceFolder] ?? ""
        try MiniTest.expect(!workspaceFolder.isEmpty, "workspace_folder stamp present")
        try MiniTest.expectEqual(workspaceFolder, origin.workspaceFolder)
        let configPath = origin.configPathInContainer

        let wsSentinelCode = try ExecCommand.run(
            options: ExecOptions(
                command: [
                    "sh", "-lc",
                    "test -f \(workspaceSentinelName) && grep -qx \(workspaceSentinelValue) \(workspaceSentinelName)"
                ],
                name: name
            ),
            runtime: runtime
        )
        try MiniTest.expectEqual(wsSentinelCode, 0, "workspace sentinel present after clone")
        let cfgSentinelCode = try ExecCommand.run(
            options: ExecOptions(
                command: [
                    "sh", "-lc",
                    "test -f \(configVolSentinelPath) && grep -qx \(configVolSentinelValue) \(configVolSentinelPath)"
                ],
                name: name
            ),
            runtime: runtime
        )
        try MiniTest.expectEqual(cfgSentinelCode, 0, "config volume sentinel present after clone")

        // Force post-delete hard failure: break create-path hook in the volume config.
        try writeConfigInContainer(
            runtime: runtime,
            containerName: name,
            configPath: configPath,
            json: origin.failConfigJSON
        )

        // Snapshot volume mutations after setup; recovery phase must not alter them.
        let setupMutationCount = recorder.volumeMutations().count
        recorder.reset()

        // ── 13.2 post-delete helper + volume safety ──
        var recovery: RecoveryErrorDetails?
        do {
            _ = try RebuildCommand.run(
                options: RebuildOptions(name: name, skipPull: true, jsonOutput: true),
                runtime: runtime,
                localEnv: authorEnv()
            )
            throw MiniTest.Failure(message: "expected recovery_unavailable after post-delete hook failure")
        } catch let err as CLIError {
            try MiniTest.expectEqual(err.code, CLIErrorCode.recoveryUnavailable)
            guard let details = err.recovery else {
                throw MiniTest.Failure(message: "recovery details missing on structured error")
            }
            recovery = details
        } catch let fail as MiniTest.Failure {
            throw fail
        } catch {
            throw MiniTest.Failure(message: "unexpected rebuild error: \(error)")
        }
        let details = recovery!
        sessionTemp = details.tempFile
        try MiniTest.expectEqual(details.helperAvailable, true)
        try MiniTest.expectEqual(details.helperContainerName, name)
        try MiniTest.expectEqual(details.workspaceVolume, wsVol)
        try MiniTest.expect(details.retryCommand.contains("rebuild"), "retry command names rebuild")
        try MiniTest.expect(details.retryCommand.contains(name), "retry command targets helper name")
        try MiniTest.expect(
            FileManager.default.fileExists(atPath: details.tempFile),
            "secure temp file retained"
        )

        let helper = try runtime.findByName(name)
        try MiniTest.expect(helper != nil, "helper retained under original name")
        let helperInfo = helper!
        try MiniTest.expect(
            RecoveryHelper.isRecoveryHelper(helperInfo),
            "helper carries recovery marker"
        )
        try MiniTest.expect(
            RecoveryHelper.isPinnedHelperImage(helperInfo)
                || helperInfo.image == RecoveryHelper.helperImageReference
                || (helperInfo.image?.contains(RecoveryHelper.helperImageDigest) == true),
            "helper uses pinned image (got \(helperInfo.image ?? "nil"))"
        )
        try runtime.verifyVolumeAttachment(
            nameOrId: helperInfo.id,
            volumeName: wsVol,
            targetPath: workspaceFolder,
            readOnly: false
        )

        // Failed replacement must not remain attached.
        let attached = try runtime.containersAttached(to: wsVol)
        try MiniTest.expectEqual(attached.count, 1, "only the helper attaches the workspace volume")
        try MiniTest.expectEqual(attached[0].name, name)

        let recoveryMutations = recorder.volumeMutations()
        try MiniTest.expect(
            !recoveryMutations.contains { $0.dropFirst().first == "delete" && $0.contains(wsVol) },
            "recovery must not delete workspace volume"
        )
        try MiniTest.expect(
            !recoveryMutations.contains {
                $0.dropFirst().first == "delete" && $0.contains(configVolumeName!)
            },
            "recovery must not delete config volume"
        )
        try MiniTest.expect(
            !recoveryMutations.contains { $0.dropFirst().first == "create" && $0.contains(wsVol) },
            "recovery must not alter workspace volume"
        )
        try MiniTest.expect(!recorder.usedContainerCp(), "recovery path must not use container cp")
        _ = setupMutationCount

        // Sentinels still present through the helper mount.
        // Helper image is Alpine (no vscode); probe as root at the absolute workspace path.
        let helperWsCode = try execRoot(
            runtime: runtime,
            nameOrId: name,
            command: [
                "sh", "-c",
                "test -f \"$1/\(workspaceSentinelName)\" && grep -qx \(workspaceSentinelValue) \"$1/\(workspaceSentinelName)\"",
                "adev-rec-e2e-sentinel",
                workspaceFolder
            ]
        )
        try MiniTest.expectEqual(helperWsCode, 0, "workspace sentinel survives via helper")

        // ── 13.4 list [RECOVERY] + prune skip (while helper alive) ──
        let listed = try ListCommand.run(options: ListOptions(jsonOutput: false), runtime: runtime)
        try MiniTest.expect(listed.contains("[RECOVERY]"), "human list marks recovery helper")
        try MiniTest.expect(listed.contains(name), "human list includes helper name")

        let pruneCode = try PruneCommand.run(name: name, runtime: runtime)
        try MiniTest.expectEqual(pruneCode, 0)
        try MiniTest.expect(
            try runtime.findByName(name) != nil,
            "ordinary prune must leave the recovery helper"
        )
        try MiniTest.expect(
            try runtime.volumeExists(wsVol, requireObjectEntries: true),
            "prune must leave workspace volume"
        )
        try MiniTest.expect(
            try runtime.volumeExists(configVolumeName!),
            "prune must leave config volume"
        )

        // Named selection still addresses the helper (runtime exec; Alpine has no vscode).
        let execCode = try execRoot(
            runtime: runtime,
            nameOrId: name,
            command: ["true"]
        )
        try MiniTest.expectEqual(execCode, 0, "named helper remains exec-addressable")
        // Managed selection by --name still resolves the recovery helper.
        let selected = try ManagedContainers.resolveSelection(name: name, runtime: runtime)
        try MiniTest.expect(RecoveryHelper.isRecoveryHelper(selected), "rebuild --name selects helper")

        // ── 13.3 non-TTY edit temp + named retry + final hash ──
        try origin.recoveredConfigJSON.write(
            to: URL(fileURLWithPath: details.tempFile),
            atomically: true,
            encoding: .utf8
        )
        // Keep private mode after rewrite.
        try FileManager.default.setAttributes(
            [.posixPermissions: 0o600],
            ofItemAtPath: details.tempFile
        )
        let expectedHash = RecoveryConfigSession.sha256Hex(Data(origin.recoveredConfigJSON.utf8))

        recorder.reset()
        let rebuilt: RebuildResult
        do {
            rebuilt = try RebuildCommand.run(
                options: RebuildOptions(name: name, skipPull: true, jsonOutput: true),
                runtime: runtime,
                localEnv: authorEnv()
            )
        } catch {
            keepArtifactsOnFailure = true
            if let cli = error as? CLIError {
                throw MiniTest.Failure(
                    message: "named retry failed: \(cli.code) \(cli.message) hint=\(cli.hint ?? "") recovery=\(String(describing: cli.recovery))"
                )
            }
            throw error
        }
        try MiniTest.expectEqual(rebuilt.outcome, "success")
        try MiniTest.expectEqual(rebuilt.containerName ?? name, name)
        try MiniTest.expectEqual(rebuilt.workspaceVolume, wsVol)

        let retryMutations = recorder.volumeMutations()
        try MiniTest.expect(
            !retryMutations.contains { $0.dropFirst().first == "delete" && $0.contains(wsVol) },
            "retry must not delete workspace volume"
        )
        try MiniTest.expect(
            !retryMutations.contains { $0.dropFirst().first == "create" && $0.contains(wsVol) },
            "retry must not alter workspace volume"
        )
        try MiniTest.expect(!recorder.usedContainerCp(), "retry must not use container cp")

        let finalBytes = try runtime.readFile(nameOrId: name, path: configPath)
        try MiniTest.expectEqual(
            RecoveryConfigSession.sha256Hex(finalBytes),
            expectedHash,
            "final container sees edited config hash"
        )
        let finalText = String(data: finalBytes, encoding: .utf8) ?? ""
        try MiniTest.expect(
            finalText.contains(recoveredMarker),
            "final config carries recovery edit marker"
        )

        // Helper + secure session cleaned after success.
        let after = try runtime.findByName(name)
        try MiniTest.expect(after != nil, "final container remains")
        try MiniTest.expect(
            !RecoveryHelper.isRecoveryHelper(after!),
            "final container is not a recovery helper"
        )
        try MiniTest.expect(
            !FileManager.default.fileExists(atPath: details.tempFile),
            "secure temp session removed after success"
        )
        sessionTemp = nil

        // Sentinels still present on final container.
        let finalWs = try ExecCommand.run(
            options: ExecOptions(
                command: [
                    "sh", "-lc",
                    "test -f \(workspaceSentinelName) && grep -qx \(workspaceSentinelValue) \(workspaceSentinelName)"
                ],
                name: name
            ),
            runtime: runtime
        )
        try MiniTest.expectEqual(finalWs, 0, "workspace sentinel survives successful recovery")
        let finalCfg = try ExecCommand.run(
            options: ExecOptions(
                command: [
                    "sh", "-lc",
                    "test -f \(configVolSentinelPath) && grep -qx \(configVolSentinelValue) \(configVolSentinelPath)"
                ],
                name: name
            ),
            runtime: runtime
        )
        try MiniTest.expectEqual(finalCfg, 0, "config volume sentinel survives successful recovery")
    }
}
