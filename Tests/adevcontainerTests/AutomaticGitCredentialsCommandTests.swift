import Foundation
@testable import ADevContainerLib

final class AutomaticCredentialCommandPort: GitCredentialConnecting, @unchecked Sendable {
    private let lock = NSLock()
    private var recorded: [String] = []
    private var shouldFail = false
    struct Request: Equatable {
        let id: String
        let hostWorkspace: String?
        let gitURL: String?
        let refresh: Bool
    }
    private var requests: [Request] = []
    var setups: [Request] { lock.lock(); defer { lock.unlock() }; return requests }
    var fails: Bool { get { lock.lock(); defer { lock.unlock() }; return shouldFail } set { lock.lock(); shouldFail = newValue; lock.unlock() } }
    private var reportsCredential = true
    var acquired: Bool { get { lock.lock(); defer { lock.unlock() }; return reportsCredential } set { lock.lock(); reportsCredential = newValue; lock.unlock() } }
    var onEvent: ((String) -> Void)?
    func record(_ value: String) { lock.lock(); recorded.append(value); lock.unlock(); onEvent?(value) }
    var events: [String] { lock.lock(); defer { lock.unlock() }; return recorded }
    func setup(id: String, hostWorkspace: String?, gitURL: String?, refresh: Bool) throws -> Bool {
        lock.lock(); requests.append(.init(id: id, hostWorkspace: hostWorkspace, gitURL: gitURL, refresh: refresh)); lock.unlock()
        record(refresh ? "refresh" : "setup")
        if fails { throw GitCredentialFailure.transport }; return reportsCredential
    }
    func unregister(id: String) throws { record("unregister"); if fails { throw GitCredentialFailure.transport } }
}
@MainActor let automaticGitCredentialsCommandTests: [(String, () throws -> Void)] = [
    ("credentials.commands.hooksDisableAuthenticationPrompts", {
        let workspace = try TestRepo.makeTempWorkspace(configJSON: #"{"image":"alpine:3.20","remoteUser":"root","containerEnv":{"GIT_TERMINAL_PROMPT":"1","GCM_INTERACTIVE":"Always"}}"#)
        defer { try? FileManager.default.removeItem(at: workspace) }
        let config = try ConfigResolver.resolve(workspacePath: workspace.path, localEnv: [:]).config
        let runner = MockProcessRunner()
        try LifecycleRunner.runIfPresent(property: "postCreateCommand", command: .shell("git fetch"), containerId: "synthetic", config: config, runtime: .init(executablePath: "/synthetic/container", runner: runner), failurePolicy: .failKeepContainer)
        let arguments = runner.calls.first?.arguments ?? []
        for value in ["GIT_TERMINAL_PROMPT=0", "GCM_INTERACTIVE=Never", "GCM_GUI_PROMPT=0", "GIT_ASKPASS=/bin/false", "SSH_ASKPASS=/bin/false"] {
            try MiniTest.expect(arguments.contains(value), "hook must disable authentication prompts: \(value)")
        }
    }),
    ("credentials.commands.guestHooksAndCloneDropCredentialTraces", {
        let workspace = try TestRepo.makeTempWorkspace(configJSON: #"{"image":"alpine:3.20","remoteUser":"root","containerEnv":{"GIT_TRACE":"1","GIT_TRACE_PACKET":"/tmp/trace","GCM_TRACE":"1","GIT_CURL_VERBOSE":"1","GCM_DEBUG":"1","PATH":"/usr/bin"}}"#)
        defer { try? FileManager.default.removeItem(at: workspace) }
        let config = try ConfigResolver.resolve(workspacePath: workspace.path, localEnv: [:]).config
        let runner = MockProcessRunner()
        try LifecycleRunner.runIfPresent(property: "postCreateCommand", command: .shell("git fetch"), containerId: "synthetic", config: config, runtime: .init(executablePath: "/synthetic/container", runner: runner), failurePolicy: .failKeepContainer)
        let hookArguments = runner.calls.first?.arguments ?? []
        for forbidden in ["GIT_TRACE=1", "GIT_TRACE_PACKET=/tmp/trace", "GCM_TRACE=1", "GIT_CURL_VERBOSE=1", "GCM_DEBUG=1"] {
            try MiniTest.expect(!hookArguments.contains(forbidden), "hook forwarded credential trace: \(forbidden)")
        }
        try MiniTest.expect(hookArguments.contains("PATH=/usr/bin"))
        let restore = CloneGitFeatureTestSupport.installOverrides()
        defer { restore() }
        let connection = AutomaticCredentialCommandPort()
        GitCredentialLifecycle.setTestConnection(connection)
        defer { GitCredentialLifecycle.setTestConnection(nil) }
        let git = MockGitClient()
        git.configJSONToWrite = #"{"image":"alpine:3.20","containerEnv":{"GIT_TRACE":"1","GCM_TRACE":"1","GIT_CURL_VERBOSE":"1","GH_DEBUG":"1"}}"#
        let creds = MockGitCredential()
        creds.fillResult = .success(nil)
        let mock = MockProcessRunner()
        mock.handlers = CloneRuntimeMock.handlers()
        _ = try CloneCommand.run(
            options: CloneOptions(gitURL: "https://github.com/org/public.git", skipPull: true),
            runtime: .init(executablePath: "/synthetic/container", runner: mock),
            git: git,
            credentials: creds,
            localEnv: [:]
        )
        let cloneCall = mock.calls.first { $0.arguments.contains { $0.contains("git clone --") } }
        let cloneScript = cloneCall?.arguments.last ?? ""
        try MiniTest.expect(cloneScript.contains("unset GIT_TRACE"))
        try MiniTest.expect(cloneScript.contains("GIT_CURL_VERBOSE"))
        try MiniTest.expect(cloneScript.contains("GCM_TRACE"))
        let cloneArguments = cloneCall?.arguments ?? []
        for forbidden in ["GIT_TRACE=1", "GCM_TRACE=1", "GIT_CURL_VERBOSE=1", "GH_DEBUG=1"] {
            try MiniTest.expect(!cloneArguments.contains(forbidden), "clone forwarded credential trace: \(forbidden)")
        }
    }),
    ("credentials.commands.failedCreateHookUnregistersBeforeDelete", {
        let port = AutomaticCredentialCommandPort(); GitCredentialLifecycle.setTestConnection(port); defer { GitCredentialLifecycle.setTestConnection(nil) }
        let workspace = try TestRepo.makeTempWorkspace(configJSON: #"{"image":"alpine:3.20","remoteUser":"root"}"#)
        defer { try? FileManager.default.removeItem(at: workspace) }
        let config = try ConfigResolver.resolve(workspacePath: workspace.path, localEnv: [:]).config
        let runner = MockProcessRunner()
        runner.handlers = [{ args in
            if args.first == "delete" { port.record("runtime.delete") }
            return .init(exitCode: args.first == "exec" ? 1 : 0, stdout: Data(), stderr: Data())
        }]
        try MiniTest.expectThrows({
            try LifecycleRunner.runIfPresent(property: "postCreateCommand", command: .shell("false"), containerId: "synthetic", config: config, runtime: .init(executablePath: "/synthetic/container", runner: runner), failurePolicy: .deleteContainerThenFail)
        }, validate: { _ in })
        try MiniTest.expectEqual(port.events, ["unregister", "runtime.delete"])
    }),
    ("credentials.commands.runningReuseSetupAndTeardown", {
        let port = AutomaticCredentialCommandPort(); GitCredentialLifecycle.setTestConnection(port); defer { GitCredentialLifecycle.setTestConnection(nil) }
        let runner = MockProcessRunner()
        let object: [String: Any] = ["configuration": ["id": "synthetic", "labels": ["devcontainer.managed": "adevcontainer", "devcontainer.workspace_mode": "volume", "devcontainer.git_url": "https://example.invalid/repo"]], "status": ["state": "running"]]
        let inspect = try JSONSerialization.data(withJSONObject: object), list = try JSONSerialization.data(withJSONObject: [object])
        runner.handlers = [{ args in
            if args.first == "inspect" { return .init(exitCode: 0, stdout: inspect, stderr: Data()) }
            if args.first == "list" { return .init(exitCode: 0, stdout: list, stderr: Data()) }
            if ["stop", "delete"].contains(args.first ?? "") { port.record("runtime." + args[0]) }
            return .init(exitCode: 0, stdout: Data(), stderr: Data())
        }]
        let runtime = AppleContainerRuntime(executablePath: "/synthetic/container", runner: runner)
        try StartCommand.run(options: .init(name: "synthetic"), runtime: runtime)
        try MiniTest.expectEqual(port.events, ["setup"])
        try MiniTest.expectEqual(port.setups.first?.refresh, false)
        try StopCommand.run(name: "synthetic", runtime: runtime)
        try DeleteCommand.run(name: "synthetic", runtime: runtime)
        try MiniTest.expectEqual(Array(port.events.suffix(4)), ["unregister", "runtime.stop", "unregister", "runtime.delete"])
    }),
    ("credentials.commands.purgeUnregistersBeforeDeleteWithoutVolumePolicyChange", {
        let port = AutomaticCredentialCommandPort(); GitCredentialLifecycle.setTestConnection(port); defer { GitCredentialLifecycle.setTestConnection(nil) }
        let runner = MockProcessRunner()
        let labels = [ContainerIdentity.labelManaged: ContainerIdentity.managedValue, ContainerIdentity.labelWorkspaceMode: ContainerIdentity.workspaceModeVolume, ContainerIdentity.labelWorkspaceVolume: "synthetic-ws", ContainerIdentity.labelConfigVolumes: "synthetic-config"]
        let entry = MockProcessRunner.containerListJSON(id: "synthetic", state: "running", labels: labels)
        let list = try JSONSerialization.data(withJSONObject: [entry])
        let volumes = try JSONSerialization.data(withJSONObject: [["id": "synthetic-config"], ["id": "synthetic-ws"]])
        var deleted = false
        runner.handlers = [{ args in
            if args.first == "list" { return .init(exitCode: 0, stdout: deleted ? Data("[]".utf8) : list, stderr: Data()) }
            if args.first == "delete" { deleted = true; port.record("runtime.delete") }
            if args == ["volume", "list", "--format", "json"] { return .init(exitCode: 0, stdout: volumes, stderr: Data()) }
            if args.first == "image" { port.record("runtime.image") }
            return .init(exitCode: 0, stdout: Data(), stderr: Data())
        }]
        let code = try PurgeCommand.run(name: "synthetic", runtime: .init(executablePath: "/synthetic/container", runner: runner), isInteractive: false)
        try MiniTest.expectEqual(code, 0)
        try MiniTest.expectEqual(Array(port.events.prefix(2)), ["unregister", "runtime.delete"])
        try MiniTest.expect(runner.calls.contains { $0.arguments.starts(with: ["volume", "delete", "synthetic-ws"]) })
        try MiniTest.expect(!runner.calls.contains { $0.arguments.joined().contains("git-credential-adev") || $0.arguments.joined().contains("credential approve") })
    })
]
