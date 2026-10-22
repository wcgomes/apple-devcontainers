import Foundation
import Darwin
@testable import ADevContainerLib

@MainActor let gitCredentialBrokerEntryTests: [(String, () throws -> Void)] = [
    ("credentials.entry.invalidIsolatedContextAndPublicHelp", {
        let executable = FileManager.default.currentDirectoryPath + "/.build/debug/adevcontainer"
        try MiniTest.expect(FileManager.default.isExecutableFile(atPath: executable), "build the CLI product before entry tests")
        let runner = CredentialProviderProcessRunner(timeout: 3)
        let invalid = try runner.run(executable: executable, arguments: ["__adevcontainer_git_broker", "/invalid-synthetic-context/launch-context.json"], environment: [:], currentDirectory: nil, stdinData: nil)
        try MiniTest.expectEqual(invalid.exitCode, 1)
        // Provider runner intentionally discards stderr, so capture the safe CLI
        // diagnostic with the ordinary test runner; this path fails before I/O.
        let diagnostic = try FoundationProcessRunner().run(executable: executable, arguments: ["__adevcontainer_git_broker", "/invalid-synthetic-context/launch-context.json"], environment: [:], currentDirectory: nil)
        try MiniTest.expect(diagnostic.stderrString.contains("service could not start"))
        try MiniTest.expect(!diagnostic.stderrString.contains("invalid-synthetic-context"))
        let help = try runner.run(executable: executable, arguments: ["--help"], environment: [:], currentDirectory: nil, stdinData: nil)
        try MiniTest.expectEqual(help.exitCode, 0)
        try MiniTest.expect(!help.stdoutString.contains("__adevcontainer_git_broker"))
    }),
    ("credentials.entry.isolatedSessionIgnoresSIGHUPAndStopsOnSignal", {
        let executable = FileManager.default.currentDirectoryPath + "/.build/debug/adevcontainer"
        try MiniTest.expect(FileManager.default.isExecutableFile(atPath: executable), "build the CLI product before entry tests")
        let root = try credentialShortRoot(); defer { try? FileManager.default.removeItem(at: root) }
        let context = GitCredentialBrokerSmokeHarness.isolatedContext(root: root)
        let state = try GitCredentialPrivateFiles.directory(context.state, create: true); defer { close(state) }
        try GitCredentialPrivateFiles.write(JSONEncoder().encode(context), name: "launch-context.json", directory: state)
        let process = Process()
        process.executableURL = URL(fileURLWithPath: executable)
        process.arguments = ["__adevcontainer_git_broker", context.state + "/launch-context.json"]
        process.environment = context.providerEnvironment
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        try process.run()
        defer { if process.isRunning { _ = kill(process.processIdentifier, SIGKILL) } }
        let deadline = ProcessInfo.processInfo.systemUptime + 5
        while !FileManager.default.fileExists(atPath: context.socket), process.isRunning, ProcessInfo.processInfo.systemUptime < deadline {
            Thread.sleep(forTimeInterval: 0.025)
        }
        try MiniTest.expect(FileManager.default.fileExists(atPath: context.socket), "isolated session did not bind its private control socket")
        try MiniTest.expect(kill(process.processIdentifier, SIGHUP) == 0)
        Thread.sleep(forTimeInterval: 0.5)
        try MiniTest.expect(process.isRunning, "SIGHUP must not terminate the detached broker loop")
        guard case .owner(let reported) = try GitCredentialControlClient().probe(context, deadline: ProcessInfo.processInfo.systemUptime + 3),
              reported.matches(try credentialIdentity(executable)) else {
            throw MiniTest.Failure(message: "isolated session did not report its own executable identity")
        }
        try MiniTest.expect(kill(process.processIdentifier, SIGTERM) == 0)
        process.waitUntilExit()
        try MiniTest.expectEqual(process.terminationStatus, 0, "SIGTERM must use the graceful stop path")
        try MiniTest.expect(!FileManager.default.fileExists(atPath: context.socket), "graceful exit removes its owned socket")
        let entries = try FileManager.default.contentsOfDirectory(atPath: context.state).sorted()
        try MiniTest.expectEqual(entries, ["launch-context.json"], "a session creates no plist or service receipt")
    })
]
