import Darwin
import Foundation
@testable import ADevContainerLib

final class SSHDiscoveryRunner: ProcessRunning, @unchecked Sendable {
    var output = "origin\tgit@example.invalid:group/repo.git (fetch)\n"
    var exitCode: Int32 = 0
    var fails = false
    var environments: [[String: String]?] = []
    var arguments: [[String]] = []
    func run(executable: String, arguments: [String], environment: [String: String]?, currentDirectory: String?, stdinData: Data?) throws -> ProcessResult {
        environments.append(environment); self.arguments.append(arguments)
        if fails { throw GitCredentialFailure.deadline }
        return .init(exitCode: exitCode, stdout: Data(output.utf8), stderr: Data("secret diagnostic".utf8))
    }
}

final class SSHSocketFixture {
    let directory: URL
    let path: String
    private let fd: Int32
    init() throws {
        directory = FileManager.default.temporaryDirectory.appendingPathComponent("s-" + UUID().uuidString.prefix(6))
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        path = directory.appendingPathComponent("s").path
        fd = socket(AF_UNIX, SOCK_STREAM, 0)
        var address = try GitCredentialControlSocket.address(path)
        guard fd >= 0, GitCredentialControlSocket.bindPrivate(fd, address: &address) == 0 else {
            if fd >= 0 { close(fd) }
            try? FileManager.default.removeItem(at: directory)
            throw MiniTest.Failure(message: "synthetic SSH socket bind failed")
        }
    }
    deinit { close(fd); try? FileManager.default.removeItem(at: directory) }
}

@MainActor let sshForwardingPolicyTests: [(String, () throws -> Void)] = [
    ("ssh.policy.S01S04S05.remoteFormsAndPush", {
        let socket = try SSHSocketFixture()
        let runner = SSHDiscoveryRunner()
        for remote in ["git@example.invalid:group/repo.git", "example.invalid:group/repo.git", "ssh://git@example.invalid/group/repo.git", "[::1]:group/repo.git", "git@[::1]:group/repo.git", "[2001:db8::1]:group/repo.git", "example.invalid:group::repo.git"] {
            runner.output = "origin\thttps://user:secret@example.invalid/repo (fetch)\nother\t\(remote) (push)\nother\t\(remote) (fetch)\n"
            let env = ["SSH_AUTH_SOCK": socket.path, "SYNTHETIC": "injected"]
            let decision = SSHForwardingPolicy.evaluate(workspace: "/synthetic", environment: env, explicitSSH: false, runner: runner, gitPath: "/fake/git")
            try MiniTest.expect(decision.automatic)
            try MiniTest.expect(decision.warning == nil)
            try MiniTest.expectEqual(runner.environments.last!, env.merging(["GIT_TERMINAL_PROMPT": "0"]) { _, new in new })
            try MiniTest.expectEqual(runner.arguments.last!, ["-C", "/synthetic", "remote", "-v"])
        }
    }),
    ("ssh.policy.S02.socketMetadataNotNonempty", {
        let socket = try SSHSocketFixture()
        let file = socket.directory.appendingPathComponent("file")
        try Data().write(to: file)
        let link = socket.directory.appendingPathComponent("link")
        try FileManager.default.createSymbolicLink(atPath: link.path, withDestinationPath: socket.path)
        for value in [nil, "", "  ", file.path, socket.directory.path, socket.path + "-missing", socket.path, link.path] as [String?] {
            let env = value.map { ["SSH_AUTH_SOCK": $0] } ?? [:]
            let decision = SSHForwardingPolicy.evaluate(workspace: "/synthetic", environment: env, explicitSSH: false, runner: SSHDiscoveryRunner(), gitPath: "/fake/git")
            let expected = value == socket.path || value == link.path
            try MiniTest.expectEqual(decision.automatic, expected)
            try MiniTest.expectEqual(decision.warning != nil, !expected)
            if let warning = decision.warning {
                try MiniTest.expect(warning.contains("SSH_AUTH_SOCK") && warning.contains("rebuild"))
                try MiniTest.expect(!warning.contains(socket.directory.path))
            }
        }
    }),
    ("ssh.policy.S03S06.safeFallbackAndExplicit", {
        let socket = try SSHSocketFixture()
        let runner = SSHDiscoveryRunner()
        for remote in ["https://user:secret@example.invalid/repo", "http://example.invalid/repo", "file:///local/repo", "/local/user@host:repo", "folder/user@host:repo", "./host:repo", "../host:repo", "other://host/repo", ""] {
            runner.output = "origin\t\(remote) (fetch)\n"
            let decision = SSHForwardingPolicy.evaluate(workspace: "/synthetic", environment: ["SSH_AUTH_SOCK": socket.path], explicitSSH: false, runner: runner, gitPath: "/fake/git")
            try MiniTest.expect(!decision.automatic && decision.warning == nil, remote)
        }
        runner.output = "origin\tgit@example.invalid:repo (fetch)\n"
        for explicit in [false, true] {
            runner.fails = true
            let decision = SSHForwardingPolicy.evaluate(workspace: "/synthetic", environment: [:], explicitSSH: explicit, runner: runner, gitPath: "/fake/git")
            try MiniTest.expect(!decision.automatic && decision.warning == nil)
        }
        runner.fails = false; runner.exitCode = 128
        let failed = SSHForwardingPolicy.evaluate(workspace: "/synthetic", environment: [:], explicitSSH: false, runner: runner, gitPath: "/fake/git")
        try MiniTest.expect(!failed.automatic && failed.warning == nil)
        let missing = SSHForwardingPolicy.evaluate(workspace: "/synthetic", environment: ["PATH": "/nonexistent"], explicitSSH: false, runner: runner)
        try MiniTest.expect(!missing.automatic && missing.warning == nil)
        let explicit = SSHForwardingPolicy.evaluate(workspace: "/synthetic", environment: [:], explicitSSH: true, runner: runner, gitPath: "/fake/git")
        try MiniTest.expect(!explicit.automatic && explicit.warning == nil)
    }),
    ("ssh.policy.realLocalGitAndBoundedDiscovery", {
        let socket = try SSHSocketFixture()
        let env = ["HOME": socket.directory.path, "PATH": "/usr/bin:/bin", "GIT_CONFIG_NOSYSTEM": "1", "GIT_CONFIG_GLOBAL": "/dev/null", "SSH_AUTH_SOCK": socket.path]
        let runner = FoundationProcessRunner()
        for args in [["init", socket.directory.path], ["-C", socket.directory.path, "config", "remote.origin.url", "https://user:secret@example.invalid/repo"], ["-C", socket.directory.path, "config", "remote.origin.pushurl", "git@example.invalid:group/repo.git"]] {
            let result = try runner.run(executable: "/usr/bin/git", arguments: args, environment: env, currentDirectory: nil)
            try MiniTest.expect(result.succeeded)
        }
        let decision = SSHForwardingPolicy.evaluate(workspace: socket.directory.path, environment: env, explicitSSH: false, runner: runner)
        try MiniTest.expect(decision.automatic && decision.warning == nil)
        let executable = socket.directory.appendingPathComponent("slow-git")
        try Data("#!/bin/sh\n/bin/sleep 10\n".utf8).write(to: executable)
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: executable.path)
        let start = ProcessInfo.processInfo.systemUptime
        let timeout = SSHForwardingPolicy.evaluate(workspace: socket.directory.path, environment: env, explicitSSH: false, runner: CredentialProviderProcessRunner(timeout: 0.1), gitPath: executable.path)
        try MiniTest.expect(!timeout.automatic && timeout.warning == nil)
        try MiniTest.expect(ProcessInfo.processInfo.systemUptime - start < 3)
    }),
    ("ssh.policy.remoteHelpersNeverAutomaticallyForward", {
        let socket = try SSHSocketFixture()
        let runner = SSHDiscoveryRunner()
        for remote in ["hg::/synthetic/repository", "https::https://example.invalid/repo", "ext::ssh-example", "hg::git@example.invalid:group/repo", "ssh::example.invalid/repo"] {
            runner.output = "origin\t\(remote) (fetch)\norigin\t\(remote) (push)\n"
            for agent in [false, true] {
                for explicit in [false, true] {
                    let decision = SSHForwardingPolicy.evaluate(workspace: "/synthetic", environment: agent ? ["SSH_AUTH_SOCK": socket.path] : [:], explicitSSH: explicit, runner: runner, gitPath: "/fake/git")
                    try MiniTest.expect(!decision.automatic && decision.warning == nil, remote)
                    let config = ResolvedDevContainerConfig(image: "alpine:3.20", workspaceFolder: "/workspaces/synthetic", runArgs: explicit ? [.ssh] : [])
                    let request = CreateRequest.from(resolved: config, identityName: "synthetic", labels: [:], configHash: "synthetic", workspacePath: "/synthetic", enableSSHForward: decision.automatic)
                    try MiniTest.expectEqual(request.createArguments().filter { $0 == "--ssh" }.count, explicit ? 1 : 0)
                }
            }
        }
    }),
    ("ssh.policy.disablesTraceFilesAndCredentialEnvironment", {
        let runner = SSHDiscoveryRunner()
        _ = SSHForwardingPolicy.evaluate(workspace: "/synthetic", environment: ["GIT_TRACE": "/synthetic/secret-trace", "GIT_TRACE2_EVENT": "/synthetic/secret-trace", "ADEVCONTAINER_GIT_TOKEN": "secret", "PATH": "/bin"], explicitSSH: false, runner: runner, gitPath: "/fake/git")
        let env = runner.environments.last!!
        try MiniTest.expect(env["GIT_TRACE"] == nil && env["GIT_TRACE2_EVENT"] == nil && env["ADEVCONTAINER_GIT_TOKEN"] == nil)
        try MiniTest.expectEqual(env["GIT_TERMINAL_PROMPT"], "0")
    })
]
