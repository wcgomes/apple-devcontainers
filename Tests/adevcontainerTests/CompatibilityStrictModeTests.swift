import Foundation
@testable import ADevContainerLib

private enum CompatibilityCommandSupport {
    static let degradedJSON = """
    { "image": "alpine:3.20", "privileged": true }
    """
    static let exactJSON = """
    { "image": "alpine:3.20", "$schema": "https://example.invalid/schema.json", "overrideCommand": true }
    """
    static let secretsJSON = """
    {
      "image": "alpine:3.20",
      "secrets": { "ghToken": { "description": "super-secret-value" } },
      "privileged": true
    }
    """
    static let malformedJSON = """
    { "image": "alpine:3.20", "privileged": "yes" }
    """

    static func mockEmptyList() -> MockProcessRunner {
        let mock = MockProcessRunner()
        mock.handlers = [
            { args in
                if args.starts(with: ["list"]) {
                    let data = try! JSONSerialization.data(withJSONObject: [] as [Any])
                    return ProcessResult(exitCode: 0, stdout: data, stderr: Data())
                }
                if args.first == "create" {
                    return ProcessResult(exitCode: 0, stdout: Data("created\n".utf8), stderr: Data())
                }
                if args.first == "start" || args.first == "delete" || args.first == "exec" {
                    return ProcessResult(exitCode: 0, stdout: Data(), stderr: Data())
                }
                if args.first == "build" {
                    return ProcessResult(exitCode: 0, stdout: Data(), stderr: Data())
                }
                return nil
            }
        ]
        return mock
    }

    static func mockReuse(resolved: ResolvedWorkspace, running: Bool) -> MockProcessRunner {
        let mock = MockProcessRunner()
        let entry = MockProcessRunner.containerListJSON(
            id: resolved.containerName,
            state: running ? "running" : "stopped",
            labels: resolved.labels
        )
        mock.handlers = [
            { args in
                if args.starts(with: ["list"]) {
                    let data = try! JSONSerialization.data(withJSONObject: [entry])
                    return ProcessResult(exitCode: 0, stdout: data, stderr: Data())
                }
                if args.first == "start" || args.first == "create" || args.first == "exec" {
                    return ProcessResult(exitCode: 0, stdout: Data(), stderr: Data())
                }
                return nil
            }
        ]
        return mock
    }
}

nonisolated(unsafe) let compatibilityStrictModeTests: [(String, () throws -> Void)] = [
    ("defaultTolerantModeContinues", {
        let previous = StatusPrinter.onWarning
        defer { StatusPrinter.onWarning = previous }
        var warnings: [String] = []
        StatusPrinter.onWarning = { warnings.append($0) }
        let workspace = try TestRepo.makeTempWorkspace(configJSON: CompatibilityCommandSupport.degradedJSON)
        defer { try? FileManager.default.removeItem(at: workspace) }
        let mock = CompatibilityCommandSupport.mockEmptyList()
        let runtime = AppleContainerRuntime(executablePath: "/usr/local/bin/container", runner: mock)
        _ = try UpCommand.run(
            options: UpOptions(workspacePath: workspace.path, skipPull: true),
            runtime: runtime,
            localEnv: [:],
            isTTY: false
        )
        try MiniTest.expect(warnings.contains { $0.contains(CompatibilityCode.configPrivilegedIgnored) })
        try MiniTest.expect(mock.calls.contains { $0.arguments.first == "create" })
    }),
    ("strictModeBlocksUpCreate", {
        let workspace = try TestRepo.makeTempWorkspace(configJSON: CompatibilityCommandSupport.degradedJSON)
        defer { try? FileManager.default.removeItem(at: workspace) }
        let mock = CompatibilityCommandSupport.mockEmptyList()
        let runtime = AppleContainerRuntime(executablePath: "/usr/local/bin/container", runner: mock)
        try MiniTest.expectThrows({
            _ = try UpCommand.run(
                options: UpOptions(workspacePath: workspace.path, skipPull: true),
                runtime: runtime,
                localEnv: [CompatibilityMode.environmentKey: "1"],
                isTTY: false
            )
        }) { error in
            let err = error as! CLIError
            try MiniTest.expectEqual(err.code, CLIErrorCode.compatibilityDegraded)
            try MiniTest.expectEqual(err.property, "privileged")
        }
        try MiniTest.expect(!mock.calls.contains { $0.arguments.first == "create" })
        try MiniTest.expect(!mock.calls.contains { $0.arguments.first == "start" })
        try MiniTest.expect(!mock.calls.contains { $0.arguments.first == "build" })
        try MiniTest.expect(!mock.calls.contains { $0.arguments.first == "delete" })
    }),
    ("strictModeBlocksUpReuseSuccess", {
        let workspace = try TestRepo.makeTempWorkspace(configJSON: CompatibilityCommandSupport.degradedJSON)
        defer { try? FileManager.default.removeItem(at: workspace) }
        let resolved = try ConfigResolver.resolve(workspacePath: workspace.path, localEnv: [:])
        let mock = CompatibilityCommandSupport.mockReuse(resolved: resolved, running: true)
        let runtime = AppleContainerRuntime(executablePath: "/usr/local/bin/container", runner: mock)
        try MiniTest.expectThrows({
            _ = try UpCommand.run(
                options: UpOptions(workspacePath: workspace.path, skipPull: true),
                runtime: runtime,
                localEnv: [CompatibilityMode.environmentKey: "1"],
                isTTY: false
            )
        }) { error in
            try MiniTest.expectEqual((error as! CLIError).code, CLIErrorCode.compatibilityDegraded)
        }
        try MiniTest.expect(!mock.calls.contains { $0.arguments.first == "exec" })
    }),
    ("strictModeBlocksUpStartStopped", {
        let workspace = try TestRepo.makeTempWorkspace(configJSON: CompatibilityCommandSupport.degradedJSON)
        defer { try? FileManager.default.removeItem(at: workspace) }
        let resolved = try ConfigResolver.resolve(workspacePath: workspace.path, localEnv: [:])
        let mock = CompatibilityCommandSupport.mockReuse(resolved: resolved, running: false)
        let runtime = AppleContainerRuntime(executablePath: "/usr/local/bin/container", runner: mock)
        try MiniTest.expectThrows({
            _ = try UpCommand.run(
                options: UpOptions(workspacePath: workspace.path, skipPull: true),
                runtime: runtime,
                localEnv: [CompatibilityMode.environmentKey: "1"],
                isTTY: false
            )
        }) { error in
            try MiniTest.expectEqual((error as! CLIError).code, CLIErrorCode.compatibilityDegraded)
        }
        try MiniTest.expect(!mock.calls.contains { $0.arguments.first == "start" })
    }),
    ("strictModeBlocksCloneBeforeCreate", {
        let git = MockGitClient()
        git.configJSONToWrite = CompatibilityCommandSupport.degradedJSON
        let mock = CompatibilityCommandSupport.mockEmptyList()
        let runtime = AppleContainerRuntime(executablePath: "/usr/local/bin/container", runner: mock)
        try MiniTest.expectThrows({
            _ = try CloneCommand.run(
                options: CloneOptions(gitURL: "https://example.invalid/repo.git", skipPull: true),
                runtime: runtime,
                git: git,
                credentials: MockGitCredential(),
                localEnv: [CompatibilityMode.environmentKey: "1"],
                isTTY: false
            )
        }) { error in
            try MiniTest.expectEqual((error as! CLIError).code, CLIErrorCode.compatibilityDegraded)
        }
        try MiniTest.expect(!mock.calls.contains { $0.arguments.first == "create" })
        try MiniTest.expect(!mock.calls.contains { $0.arguments.first == "build" })
        try MiniTest.expect(!mock.calls.contains { $0.arguments.first == "delete" })
    }),
    ("strictModeBlocksRebuildBeforeDelete", {
        let ws = try TestRepo.makeTempWorkspace(configJSON: CompatibilityCommandSupport.degradedJSON)
        defer { try? FileManager.default.removeItem(at: ws) }
        let s = RebuildScenario()
        let selected = RebuildScenario.container(
            id: "ctr",
            labels: s.bindLabels(
                localFolder: ws.path,
                configFile: ws.appendingPathComponent(".devcontainer/devcontainer.json").path
            )
        )
        s.containers = [selected]
        s.install()
        try MiniTest.expectThrows({
            _ = try RebuildCommand.run(
                options: RebuildOptions(name: "ctr", skipPull: true),
                runtime: s.runtime,
                localEnv: [CompatibilityMode.environmentKey: "1"],
                isTTY: false
            )
        }) { error in
            try MiniTest.expectEqual((error as! CLIError).code, CLIErrorCode.compatibilityDegraded)
        }
        try MiniTest.expect(!s.mock.calls.contains { $0.arguments.first == "delete" })
        try MiniTest.expect(!s.mock.calls.contains { $0.arguments.first == "create" })
        try MiniTest.expect(!s.mock.calls.contains { $0.arguments.first == "build" })
    }),
    ("strictModeBlocksStartBeforeRuntimeStart", {
        let workspace = try TestRepo.makeTempWorkspace(configJSON: CompatibilityCommandSupport.degradedJSON)
        defer { try? FileManager.default.removeItem(at: workspace) }
        let resolved = try ConfigResolver.resolve(workspacePath: workspace.path, localEnv: [:])
        let mock = CompatibilityCommandSupport.mockReuse(resolved: resolved, running: false)
        let runtime = AppleContainerRuntime(executablePath: "/usr/local/bin/container", runner: mock)
        try MiniTest.expectThrows({
            try StartCommand.run(
                options: StartOptions(name: resolved.containerName),
                runtime: runtime,
                localEnv: [CompatibilityMode.environmentKey: "1"]
            )
        }) { error in
            try MiniTest.expectEqual((error as! CLIError).code, CLIErrorCode.compatibilityDegraded)
        }
        try MiniTest.expect(!mock.calls.contains { $0.arguments.first == "start" })
    }),
    ("strictModeBlocksExecBeforeUserCommand", {
        let workspace = try TestRepo.makeTempWorkspace(configJSON: CompatibilityCommandSupport.degradedJSON)
        defer { try? FileManager.default.removeItem(at: workspace) }
        let resolved = try ConfigResolver.resolve(workspacePath: workspace.path, localEnv: [:])
        let mock = CompatibilityCommandSupport.mockReuse(resolved: resolved, running: true)
        let runtime = AppleContainerRuntime(executablePath: "/usr/local/bin/container", runner: mock)
        try MiniTest.expectThrows({
            _ = try ExecCommand.run(
                options: ExecOptions(command: ["echo", "ok"], name: resolved.containerName),
                runtime: runtime,
                localEnv: [CompatibilityMode.environmentKey: "1"]
            )
        }) { error in
            try MiniTest.expectEqual((error as! CLIError).code, CLIErrorCode.compatibilityDegraded)
        }
        try MiniTest.expect(!mock.calls.contains {
            $0.arguments.first == "exec" && $0.arguments.contains("echo")
        })
    }),
    ("strictModeAcceptsExactAndHarmlessInputs", {
        let workspace = try TestRepo.makeTempWorkspace(configJSON: CompatibilityCommandSupport.exactJSON)
        defer { try? FileManager.default.removeItem(at: workspace) }
        let mock = CompatibilityCommandSupport.mockEmptyList()
        let runtime = AppleContainerRuntime(executablePath: "/usr/local/bin/container", runner: mock)
        _ = try UpCommand.run(
            options: UpOptions(workspacePath: workspace.path, skipPull: true),
            runtime: runtime,
            localEnv: [CompatibilityMode.environmentKey: "1"],
            isTTY: false
        )
        try MiniTest.expect(mock.calls.contains { $0.arguments.first == "create" })
    }),
    ("malformedInputKeepsSpecificErrorInStrictMode", {
        let workspace = try TestRepo.makeTempWorkspace(configJSON: CompatibilityCommandSupport.malformedJSON)
        defer { try? FileManager.default.removeItem(at: workspace) }
        let mock = CompatibilityCommandSupport.mockEmptyList()
        let runtime = AppleContainerRuntime(executablePath: "/usr/local/bin/container", runner: mock)
        try MiniTest.expectThrows({
            _ = try UpCommand.run(
                options: UpOptions(workspacePath: workspace.path, jsonOutput: true, skipPull: true),
                runtime: runtime,
                localEnv: [CompatibilityMode.environmentKey: "1"],
                isTTY: false
            )
        }) { error in
            let err = error as! CLIError
            try MiniTest.expectEqual(err.code, CLIErrorCode.unsupportedProperty)
            try MiniTest.expectEqual(err.property, "privileged")
        }
        try MiniTest.expect(!mock.calls.contains { $0.arguments.first == "create" })
    }),
    ("strictErrorAggregationIsDeterministicAndRedacted", {
        let resolved = try TestRepo.resolveConfig(CompatibilityCommandSupport.secretsJSON)
        try MiniTest.expectThrows({
            try resolved.compatibilityReport.enforce(mode: .strict)
        }) { error in
            let err = error as! CLIError
            try MiniTest.expectEqual(err.code, CLIErrorCode.compatibilityDegraded)
            try MiniTest.expectEqual(err.property, "privileged")
            try MiniTest.expect(err.message.contains(CompatibilityCode.configPrivilegedIgnored))
            try MiniTest.expect(err.message.contains(CompatibilityCode.configSecretsIgnored))
            try MiniTest.expect(!err.message.contains("ghToken"))
            try MiniTest.expect(!err.message.contains("super-secret-value"))
        }
    }),
    ("otherEnvValuesDoNotEnableStrict", {
        let workspace = try TestRepo.makeTempWorkspace(configJSON: CompatibilityCommandSupport.degradedJSON)
        defer { try? FileManager.default.removeItem(at: workspace) }
        let mock = CompatibilityCommandSupport.mockEmptyList()
        let runtime = AppleContainerRuntime(executablePath: "/usr/local/bin/container", runner: mock)
        _ = try UpCommand.run(
            options: UpOptions(workspacePath: workspace.path, skipPull: true),
            runtime: runtime,
            localEnv: [CompatibilityMode.environmentKey: "true"],
            isTTY: false
        )
        try MiniTest.expect(mock.calls.contains { $0.arguments.first == "create" })
    }),
    ("strictSecurityOptBlocksBeforeCreate", {
        let workspace = try TestRepo.makeTempWorkspace(configJSON: """
        { "image": "alpine:3.20", "securityOpt": ["no-new-privileges"] }
        """)
        defer { try? FileManager.default.removeItem(at: workspace) }
        let mock = CompatibilityCommandSupport.mockEmptyList()
        let runtime = AppleContainerRuntime(executablePath: "/usr/local/bin/container", runner: mock)
        try MiniTest.expectThrows({
            _ = try UpCommand.run(
                options: UpOptions(workspacePath: workspace.path, skipPull: true),
                runtime: runtime,
                localEnv: [CompatibilityMode.environmentKey: "1"],
                isTTY: false
            )
        }) { error in
            let err = error as! CLIError
            try MiniTest.expectEqual(err.code, CLIErrorCode.compatibilityDegraded)
            try MiniTest.expectEqual(err.property, "securityOpt")
            try MiniTest.expect(err.message.contains(CompatibilityCode.configSecurityOptIgnored))
        }
        try MiniTest.expect(!mock.calls.contains { $0.arguments.first == "create" })
        try MiniTest.expect(!mock.calls.contains { $0.arguments.first == "start" })
    }),
    ("strictModeBlocksAlreadyRunningStart", {
        let workspace = try TestRepo.makeTempWorkspace(configJSON: CompatibilityCommandSupport.degradedJSON)
        defer { try? FileManager.default.removeItem(at: workspace) }
        let resolved = try ConfigResolver.resolve(workspacePath: workspace.path, localEnv: [:])
        let mock = CompatibilityCommandSupport.mockReuse(resolved: resolved, running: true)
        let runtime = AppleContainerRuntime(executablePath: "/usr/local/bin/container", runner: mock)
        try MiniTest.expectThrows({
            try StartCommand.run(
                options: StartOptions(name: resolved.containerName),
                runtime: runtime,
                localEnv: [CompatibilityMode.environmentKey: "1"]
            )
        }) { error in
            try MiniTest.expectEqual((error as! CLIError).code, CLIErrorCode.compatibilityDegraded)
        }
        try MiniTest.expect(!mock.calls.contains { $0.arguments.first == "start" })
        try MiniTest.expect(!mock.calls.contains {
            $0.arguments.first == "exec" && $0.arguments.contains("echo")
        })
    }),
    ("strictFeatureFileBindPromotionBlocksBeforeBuild", {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("feat-bind-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let kubeDir = root.appendingPathComponent(".kube", isDirectory: true)
        try FileManager.default.createDirectory(at: kubeDir, withIntermediateDirectories: true)
        let configFile = kubeDir.appendingPathComponent("config")
        try Data("k".utf8).write(to: configFile)

        let pkg = root.appendingPathComponent("feature", isDirectory: true)
        try FileManager.default.createDirectory(at: pkg, withIntermediateDirectories: true)
        try FileManager.default.copyItem(
            atPath: TestRepo.root()
                .appendingPathComponent("Tests/Fixtures/features-sample/sample-a/install.sh").path,
            toPath: pkg.appendingPathComponent("install.sh").path
        )
        try """
        {
          "id": "file-bind",
          "version": "1.0.0",
          "mounts": [
            {
              "type": "bind",
              "source": "\(configFile.path)",
              "target": "/home/vscode/.kube/config"
            }
          ]
        }
        """.write(to: pkg.appendingPathComponent("devcontainer-feature.json"), atomically: true, encoding: .utf8)

        let ref = "ghcr.io/adevcontainer/features/file-bind:1"
        let cache = root.appendingPathComponent("cache", isDirectory: true).path
        let mock = MockProcessRunner()
        mock.handlers = [
            MockProcessRunner.imageInspectHandler(baseUser: nil),
            { args in
                if args.starts(with: ["image", "list"]) {
                    return ProcessResult(exitCode: 1, stdout: Data(), stderr: Data("missing".utf8))
                }
                if args.first == "build" {
                    return ProcessResult(exitCode: 0, stdout: Data(), stderr: Data())
                }
                return ProcessResult(exitCode: 0, stdout: Data(), stderr: Data())
            }
        ]
        let runtime = AppleContainerRuntime(executablePath: "/usr/local/bin/container", runner: mock)
        try MiniTest.expectThrows({
            _ = try FeaturesRunner.run(
                features: [AdmittedFeature(reference: ref, options: [:])],
                baseImage: "alpine:3.20",
                deps: FeaturesRunner.Dependencies(
                    fetcher: MockFeatureFetcher(packagesByRef: [ref: pkg.path]),
                    runtime: runtime,
                    cacheRoot: cache,
                    platform: "linux/arm64"
                ),
                compatibilityMode: .strict
            )
        }) { error in
            let err = error as! CLIError
            try MiniTest.expectEqual(err.code, CLIErrorCode.compatibilityDegraded)
            try MiniTest.expectEqual(err.property, "mounts")
            try MiniTest.expect(err.message.contains(CompatibilityCode.mountFileBindPromoted))
        }
        try MiniTest.expect(!mock.calls.contains { $0.arguments.first == "build" })
        try MiniTest.expect(!mock.calls.contains { $0.arguments.first == "create" })
    }),
    ("strictFeatureFileBindPromotionBlocksUpBeforeBuildAndCreate", {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("feat-bind-up-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let kubeDir = root.appendingPathComponent(".kube", isDirectory: true)
        try FileManager.default.createDirectory(at: kubeDir, withIntermediateDirectories: true)
        let configFile = kubeDir.appendingPathComponent("config")
        try Data("k".utf8).write(to: configFile)

        let pkg = root.appendingPathComponent("feature", isDirectory: true)
        try FileManager.default.createDirectory(at: pkg, withIntermediateDirectories: true)
        try FileManager.default.copyItem(
            atPath: TestRepo.root()
                .appendingPathComponent("Tests/Fixtures/features-sample/sample-a/install.sh").path,
            toPath: pkg.appendingPathComponent("install.sh").path
        )
        try """
        {
          "id": "file-bind",
          "version": "1.0.0",
          "mounts": [
            {
              "type": "bind",
              "source": "\(configFile.path)",
              "target": "/home/vscode/.kube/config"
            }
          ]
        }
        """.write(to: pkg.appendingPathComponent("devcontainer-feature.json"), atomically: true, encoding: .utf8)

        let ref = "ghcr.io/adevcontainer/features/file-bind:1"
        let workspace = try TestRepo.makeTempWorkspace(configJSON: """
        { "image": "alpine:3.20", "features": { "\(ref)": {} } }
        """)
        defer { try? FileManager.default.removeItem(at: workspace) }
        let cache = root.appendingPathComponent("cache", isDirectory: true).path
        let previousFetcher = UpCommand.featuresFetcherOverride
        let previousCache = UpCommand.featuresCacheRootOverride
        let previousEnsure = UpCommand.ensureNativeArmBuildOverride
        defer {
            UpCommand.featuresFetcherOverride = previousFetcher
            UpCommand.featuresCacheRootOverride = previousCache
            UpCommand.ensureNativeArmBuildOverride = previousEnsure
        }
        UpCommand.featuresFetcherOverride = MockFeatureFetcher(packagesByRef: [ref: pkg.path])
        UpCommand.featuresCacheRootOverride = cache
        UpCommand.ensureNativeArmBuildOverride = {}

        let mock = CompatibilityCommandSupport.mockEmptyList()
        mock.handlers.insert(MockProcessRunner.imageInspectHandler(baseUser: nil), at: 0)
        let runtime = AppleContainerRuntime(executablePath: "/usr/local/bin/container", runner: mock)
        try MiniTest.expectThrows({
            _ = try UpCommand.run(
                options: UpOptions(workspacePath: workspace.path, skipPull: true),
                runtime: runtime,
                localEnv: [CompatibilityMode.environmentKey: "1"],
                isTTY: false
            )
        }) { error in
            let err = error as! CLIError
            try MiniTest.expectEqual(err.code, CLIErrorCode.compatibilityDegraded)
            try MiniTest.expectEqual(err.property, "mounts")
            try MiniTest.expect(err.message.contains(CompatibilityCode.mountFileBindPromoted))
        }
        try MiniTest.expect(!mock.calls.contains { $0.arguments.first == "build" })
        try MiniTest.expect(!mock.calls.contains { $0.arguments.first == "create" })
    })
]
