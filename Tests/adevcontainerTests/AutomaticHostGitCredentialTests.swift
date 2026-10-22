import Foundation
@testable import ADevContainerLib

@MainActor let automaticHostGitCredentialTests: [(String, () throws -> Void)] = [
    ("credentials.provider.schemePortAzureAndPrompts", {
        let runner = MockProcessRunner()
        runner.stdinHandlers = [{ _, _ in .init(exitCode: 0, stdout: Data("username=host-account\npassword=synthetic\n\n".utf8), stderr: Data()) }]
        let provider = HostGitCredential(runner: runner, gitPathOverride: .some("/synthetic/git"), environment: ["GIT_TERMINAL_PROMPT": "1", "GCM_INTERACTIVE": "always"], ghPathOverride: .some(nil))
        _ = try provider.fillHTTPS(url: "http://dev.azure.com:8080/sibling/repository")
        guard let call = runner.calls.first else { throw MiniTest.Failure(message: "no provider call") }
        try MiniTest.expectEqual(call.arguments, ["credential", "fill"])
        try MiniTest.expectEqual(String(decoding: call.stdinData ?? Data(), as: UTF8.self), "protocol=http\nhost=dev.azure.com:8080\npath=sibling/repository\n\n")
        try MiniTest.expectEqual(call.environment?["GIT_TERMINAL_PROMPT"], "0")
        try MiniTest.expectEqual(call.environment?["GCM_INTERACTIVE"], "Never")
        try MiniTest.expectEqual(call.environment?["GCM_GUI_PROMPT"], "0")
        try MiniTest.expect(call.environment?["ADEVCONTAINER_GIT_TOKEN"] == nil)
        let before = runner.calls.count
        for url in ["https://dev.azure.com", "https://dev.azure.com/org%0Ainjected=x/repo", "https://example.invalid:99999/path", "ssh://example.invalid/path"] {
            try MiniTest.expect(try provider.fillHTTPS(url: url) == nil)
        }
        try MiniTest.expectEqual(runner.calls.count, before)
        let fields = GitURLClassifier.httpsCredentialFields(for: "https://EXAMPLE.invalid:8443/org/repo")
        try MiniTest.expectEqual(fields?.host, "example.invalid:8443")
    }),
    ("credentials.provider.precedenceAndMalformedOutput", {
        let runner = MockProcessRunner()
        let explicit = HostGitCredential(runner: runner, gitPathOverride: .some("/synthetic/git"), environment: ["ADEVCONTAINER_GIT_TOKEN": "synthetic-override"], ghPathOverride: .some(nil))
        try MiniTest.expectEqual(try explicit.fillHTTPS(url: "https://example.invalid/org/repo")?.password, "synthetic-override")
        try MiniTest.expect(runner.calls.isEmpty)
        runner.stdinHandlers = [{ _, _ in .init(exitCode: 0, stdout: Data("username=host\npassword=one\npassword=conflict\n".utf8), stderr: Data()) }]
        let provider = HostGitCredential(runner: runner, gitPathOverride: .some("/synthetic/git"), environment: [:], ghPathOverride: .some(nil))
        try MiniTest.expect(try provider.fillHTTPS(url: "https://example.invalid/org/repo") == nil)
        try MiniTest.expect(runner.calls.allSatisfy { $0.arguments == ["credential", "fill"] })
    }),
    ("credentials.provider.gitMissAllowsExistingGHFallback", {
        let runner = MockProcessRunner()
        runner.handlers = [{ arguments in
            if arguments == ["credential", "fill"] { return .init(exitCode: 1, stdout: Data(), stderr: Data("synthetic failure".utf8)) }
            if arguments == ["auth", "token"] { return .init(exitCode: 0, stdout: Data("synthetic-gh\n".utf8), stderr: Data()) }
            return nil
        }]
        let provider = HostGitCredential(runner: runner, gitPathOverride: .some("/synthetic/git"), environment: [:], ghPathOverride: .some("/synthetic/gh"))
        try MiniTest.expectEqual(try provider.fillHTTPS(url: "https://github.com/org/repo")?.password, "synthetic-gh")
        try MiniTest.expectEqual(runner.calls.map(\.arguments), [["credential", "fill"], ["auth", "token"]])
        try MiniTest.expect(runner.calls.allSatisfy { $0.environment?["GCM_INTERACTIVE"] == "Never" && $0.environment?["ADEVCONTAINER_GIT_TOKEN"] == nil })
    }),
    ("credentials.provider.processBoundsDeadlineAndEnvironment", {
        let runner = CredentialProviderProcessRunner(timeout: 0.2)
        try MiniTest.expectThrows({ _ = try runner.run(executable: "/bin/sh", arguments: ["-c", "sleep 60 & wait"], environment: ["PATH": "/usr/bin:/bin"], currentDirectory: nil, stdinData: nil) }, validate: { error in try MiniTest.expectEqual(error as? GitCredentialFailure, .deadline) })
        let output = try CredentialProviderProcessRunner().run(executable: "/usr/bin/env", arguments: [], environment: ["SYNTHETIC": "ok", "ADEVCONTAINER_GIT_TOKEN": "must-not-inherit"], currentDirectory: nil, stdinData: nil)
        try MiniTest.expectEqual(output.stdoutString, "SYNTHETIC=ok\n")
        try MiniTest.expectThrows({ _ = try CredentialProviderProcessRunner().run(executable: "/bin/sh", arguments: ["-c", "dd if=/dev/zero bs=1024 count=128 2>/dev/null"], environment: [:], currentDirectory: nil, stdinData: nil) }, validate: { error in try MiniTest.expectEqual(error as? GitCredentialFailure, .overloaded) })
        let root = try credentialTestRoot()
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
        defer { try? FileManager.default.removeItem(at: root) }
        let fixture = root.appendingPathComponent("synthetic-git")
        try Data("#!/bin/sh\n/bin/sleep 60 &\nwait\n".utf8).write(to: fixture)
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: fixture.path)
        let provider = HostGitCredential(runner: CredentialProviderProcessRunner(timeout: 0.1), gitPathOverride: .some(fixture.path), environment: [:], ghPathOverride: .some(nil))
        let before = ProcessInfo.processInfo.systemUptime
        try MiniTest.expect(try provider.fillHTTPS(url: "https://example.invalid/org/repo") == nil)
        try MiniTest.expect(ProcessInfo.processInfo.systemUptime - before < 2)
    })
]
