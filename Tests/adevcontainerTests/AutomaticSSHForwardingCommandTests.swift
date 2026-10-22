import Darwin
import Foundation
@testable import ADevContainerLib

private struct SSHPlainFoundationRunner: ProcessRunning {
    func run(executable: String, arguments: [String], environment: [String: String]?, currentDirectory: String?, stdinData: Data?) throws -> ProcessResult {
        try FoundationProcessRunner().run(executable: executable, arguments: arguments, environment: environment, currentDirectory: currentDirectory, stdinData: stdinData)
    }
}

@MainActor let automaticSSHForwardingCommandTests: [(String, () throws -> Void)] = [
    ("ssh.commands.S01S02S03S04S06.freshCreateMatrix", {
        let socket = try SSHSocketFixture()
        let discovery = SSHDiscoveryRunner()
        let prior = LifecycleRunner.hostProcessRunnerOverride
        LifecycleRunner.hostProcessRunnerOverride = discovery
        let port = AutomaticCredentialCommandPort()
        GitCredentialLifecycle.setTestConnection(port)
        let oldWarning = StatusPrinter.onWarning
        defer { LifecycleRunner.hostProcessRunnerOverride = prior; GitCredentialLifecycle.setTestConnection(nil); StatusPrinter.onWarning = oldWarning }
        for transport in ["ssh", "https", "mixed"] {
            for agent in [false, true] {
                for explicit in [false, true] {
                    let json = "{\"image\":\"alpine:3.20\",\"remoteUser\":\"root\",\"runArgs\":\(explicit ? "[\"--ssh\",\"--ssh\"]" : "[]"),\"postCreateCommand\":\"echo synthetic-hook\"}"
                    let ws = try TestRepo.makeTempWorkspace(configJSON: json)
                    defer { try? FileManager.default.removeItem(at: ws) }
                    let env = agent ? ["SSH_AUTH_SOCK": socket.path] : [:]
                    let resolved = try ConfigResolver.resolve(workspacePath: ws.path, localEnv: env)
                    discovery.output = transport == "ssh" ? "origin\tgit@example.invalid:repo (fetch)\n" : "origin\thttps://user:secret@example.invalid/repo (fetch)\n"
                    if transport == "mixed" { discovery.output += "origin\tgit@example.invalid:repo (push)\n" }
                    var warnings: [String] = []
                    var warningsAtHook: [String] = []
                    let mock = MockProcessRunner()
                    mock.handlers = [MockProcessRunner.imageInspectHandler(baseUser: nil), { args in
                        if args.first == "list" { return .init(exitCode: 0, stdout: Data("[]".utf8), stderr: Data()) }
                        if args.first == "create" { return .init(exitCode: 0, stdout: Data(resolved.containerName.utf8), stderr: Data()) }
                        if args.first == "exec", args.last?.contains("synthetic-hook") == true { warningsAtHook = warnings }
                        return nil
                    }]
                    StatusPrinter.onWarning = { warnings.append($0) }
                    let runtime = AppleContainerRuntime(executablePath: "/synthetic/container", runner: mock)
                    var stdout = ""
                    fflush(nil)
                    try withCapturedStdout({
                        _ = try UpCommand.run(options: .init(workspacePath: ws.path, jsonOutput: true, skipPull: true), runtime: runtime, localEnv: env, isTTY: false)
                    }, capture: &stdout)
                    let result = try JSONSerialization.jsonObject(with: Data(stdout.utf8)) as? [String: Any]
                    try MiniTest.expectEqual(result?["outcome"] as? String, "success")
                    try MiniTest.expect(!stdout.contains(socket.path) && !stdout.contains("secret"))
                    let call = mock.calls.first { $0.arguments.first == "create" }!
                    let automatic = transport != "https" && agent && !explicit
                    let enabled = explicit || automatic
                    try MiniTest.expectEqual(call.arguments.filter { $0 == "--ssh" }.count, enabled ? 1 : 0)
                    try MiniTest.expect(call.arguments.contains("devcontainer.ssh_forwarded=\(enabled)"))
                    try MiniTest.expectEqual(call.environment, automatic ? env : nil)
                    try MiniTest.expect(!call.arguments.joined().contains(socket.path))
                    try MiniTest.expect(!call.arguments.joined().contains("secret"))
                    let sshWarnings = warnings.filter { $0.contains("SSH_AUTH_SOCK") }
                    try MiniTest.expectEqual(sshWarnings.count, transport != "https" && !agent && !explicit ? 1 : 0)
                    try MiniTest.expectEqual(warningsAtHook.filter { $0.contains("SSH_AUTH_SOCK") }.count, sshWarnings.count)
                    try MiniTest.expectEqual(try ConfigResolver.resolve(workspacePath: ws.path, localEnv: env).configHash, resolved.configHash)
                }
            }
        }
    }),
    ("ssh.commands.S07.bindRebuildParity", {
        let socket = try SSHSocketFixture()
        let discovery = SSHDiscoveryRunner()
        let prior = LifecycleRunner.hostProcessRunnerOverride
        LifecycleRunner.hostProcessRunnerOverride = discovery
        GitCredentialLifecycle.setTestConnection(AutomaticCredentialCommandPort())
        defer { LifecycleRunner.hostProcessRunnerOverride = prior; GitCredentialLifecycle.setTestConnection(nil) }
        for hasSSH in [false, true] {
            for agent in [false, true] {
                let ws = try TestRepo.makeTempWorkspace(configJSON: #"{"image":"alpine:3.20","remoteUser":"root"}"#)
                defer { try? FileManager.default.removeItem(at: ws) }
                let s = RebuildScenario()
                s.containers = [RebuildScenario.container(id: "old-id", labels: s.bindLabels(localFolder: ws.path, configFile: ws.appendingPathComponent(".devcontainer/devcontainer.json").path))]
                s.install()
                discovery.output = "origin\t\(hasSSH ? "git@example.invalid:repo" : "https://example.invalid/repo") (fetch)\n"
                let env = agent ? ["SSH_AUTH_SOCK": socket.path] : [:]
                _ = try RebuildCommand.run(options: .init(name: "old-id", skipPull: true), runtime: s.runtime, localEnv: env, isTTY: false)
                let call = s.mock.calls.first { $0.arguments.first == "create" }!
                try MiniTest.expectEqual(call.arguments.filter { $0 == "--ssh" }.count, hasSSH && agent ? 1 : 0)
                try MiniTest.expectEqual(call.environment, hasSSH && agent ? env : nil)
                try MiniTest.expect(!s.mock.calls.contains { $0.arguments.starts(with: ["volume", "delete"]) })
                try MiniTest.expect(!call.arguments.joined().contains(socket.path))
            }
        }
    }),
    ("ssh.commands.S08S09.immutableReuseAndStart", {
        let socket = try SSHSocketFixture()
        let discovery = SSHDiscoveryRunner()
        let prior = LifecycleRunner.hostProcessRunnerOverride
        let oldWarning = StatusPrinter.onWarning
        let oldPrefix = CommandSurface.commandPrefix
        CommandSurface.commandPrefix = "container dev"
        LifecycleRunner.hostProcessRunnerOverride = discovery
        GitCredentialLifecycle.setTestConnection(AutomaticCredentialCommandPort())
        defer { LifecycleRunner.hostProcessRunnerOverride = prior; StatusPrinter.onWarning = oldWarning; CommandSurface.commandPrefix = oldPrefix; GitCredentialLifecycle.setTestConnection(nil) }
        let ws = try TestRepo.makeTempWorkspace(configJSON: #"{"image":"alpine:3.20","remoteUser":"root"}"#)
        defer { try? FileManager.default.removeItem(at: ws) }
        let resolved = try ConfigResolver.resolve(workspacePath: ws.path, localEnv: [:])
        for running in [false, true] {
            for marker in [nil, "false", "true"] as [String?] {
                for start in [false, true] {
                    for (agent, hasSSH) in [(false, false), (false, true), (true, false), (true, true)] {
                        discovery.output = hasSSH ? "origin\tgit@example.invalid:repo (fetch)\n" : "origin\thttps://example.invalid/repo (fetch)\n"
                        var labels = resolved.labels
                        labels[SSHForwardingPolicy.label] = marker
                        let entry = MockProcessRunner.containerListJSON(id: resolved.containerName, state: running ? "running" : "stopped", labels: labels)
                        let mock = MockProcessRunner()
                        mock.handlers = [{ args in
                            if args.first == "list" { return .init(exitCode: 0, stdout: try! JSONSerialization.data(withJSONObject: [entry]), stderr: Data()) }
                            if args.first == "inspect" { return .init(exitCode: 0, stdout: try! JSONSerialization.data(withJSONObject: entry), stderr: Data()) }
                            return nil
                        }]
                        var warnings: [String] = []
                        StatusPrinter.onWarning = { warnings.append($0) }
                        let runtime = AppleContainerRuntime(executablePath: "/synthetic/container", runner: mock)
                        let env = agent ? ["SSH_AUTH_SOCK": socket.path] : [:]
                        if start { try StartCommand.run(options: .init(name: resolved.containerName), runtime: runtime, localEnv: env) }
                        else {
                            var stdout = ""
                            fflush(nil)
                            try withCapturedStdout({
                                _ = try UpCommand.run(options: .init(workspacePath: ws.path, jsonOutput: true, skipPull: true), runtime: runtime, localEnv: env, isTTY: false)
                            }, capture: &stdout)
                            let result = try JSONSerialization.jsonObject(with: Data(stdout.utf8)) as? [String: Any]
                            try MiniTest.expectEqual(result?["outcome"] as? String, "success")
                            try MiniTest.expect(!stdout.contains("rebuild") && !stdout.contains(socket.path))
                        }
                        try MiniTest.expect(!mock.calls.contains { ["create", "delete"].contains($0.arguments.first ?? "") })
                        try MiniTest.expect(!mock.calls.contains { $0.arguments.contains("--ssh") })
                        let hints = warnings.filter { $0.contains("SSH forwarding is fixed") }
                        try MiniTest.expectEqual(hints.count, marker != "true" && agent && hasSSH ? 1 : 0)
                        if let hint = hints.first {
                            try MiniTest.expect(hint.contains("container dev rebuild --name \(resolved.containerName)") && hint.contains("if unavailable"))
                            try MiniTest.expect(!hint.contains(socket.path))
                        }
                    }
                }
            }
        }
    }),
    ("ssh.runtime.foundationPayloadAndRedactedFailure", {
        let socket = try SSHSocketFixture()
        let ws = try TestRepo.makeTempWorkspace(configJSON: #"{"image":"alpine:3.20","remoteUser":"root"}"#)
        defer { try? FileManager.default.removeItem(at: ws) }
        let resolved = try ConfigResolver.resolve(workspacePath: ws.path, localEnv: [:])
        let request = CreateRequest.from(resolved: resolved.config, identityName: "synthetic", labels: resolved.labels, configHash: resolved.configHash, workspacePath: ws.path, enableSSHForward: true)
        let script = socket.directory.appendingPathComponent("container-fake")
        let capture = socket.directory.appendingPathComponent("capture")
        try Data("#!/bin/sh\nprintf '%s' \"$SSH_AUTH_SOCK\" > \"$CAPTURE\"\nif [ \"$FAIL\" = 1 ]; then printf '%s' \"$SSH_AUTH_SOCK\" >&2; exit 1; fi\nprintf 'synthetic\\n'\n".utf8).write(to: script)
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: script.path)
        for runner: any ProcessRunning in [FoundationProcessRunner(), SSHPlainFoundationRunner()] {
            let runtime = AppleContainerRuntime(executablePath: script.path, runner: runner)
            let env = ["SSH_AUTH_SOCK": socket.path, "CAPTURE": capture.path]
            try MiniTest.expectEqual(try runtime.create(request: request, ensureVolumes: false, hostEnvironment: env), "synthetic")
            try MiniTest.expectEqual(try String(contentsOf: capture, encoding: .utf8), socket.path)
            _ = try runtime.invoke(["create"], streamStderr: true, environment: env)
            try MiniTest.expectEqual(try String(contentsOf: capture, encoding: .utf8), socket.path)
            try MiniTest.expectThrows({
                _ = try runtime.create(request: request, ensureVolumes: false, hostEnvironment: env.merging(["FAIL": "1"]) { _, new in new })
            }, validate: { error in
                try MiniTest.expect(!((error as? CLIError)?.message.contains(socket.path) ?? false))
            })
        }
    })
]
