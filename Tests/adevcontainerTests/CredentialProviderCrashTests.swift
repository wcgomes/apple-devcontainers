import Foundation
import Darwin
@testable import ADevContainerLib

enum CredentialProviderCrashProbe {
    static func run() -> Int32 {
        guard let file = ProcessInfo.processInfo.environment["ADEVCONTAINER_PROVIDER_PID_FILE"] else { return 2 }
        do {
            _ = try CredentialProviderProcessRunner(timeout: 60).run(executable: "/bin/sh", arguments: ["-c", "sleep 60 & printf '%s %s\\n' $$ $! > \"$1\"; wait", "synthetic-provider", file], environment: ["PATH": "/usr/bin:/bin"], currentDirectory: nil, stdinData: nil)
            return 0
        } catch { return 1 }
    }
}

@MainActor let credentialProviderCrashTests: [(String, () throws -> Void)] = [
    ("credentials.provider.brokerCrashKillsOwnedProviderGroup", {
        let root = try credentialTestRoot()
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
        defer { try? FileManager.default.removeItem(at: root) }
        let file = root.appendingPathComponent("provider-pids")
        let parent = Process(); parent.executableURL = Bundle.main.executableURL
        parent.environment = ["ADEVCONTAINER_PROVIDER_CRASH_PROBE": "1", "ADEVCONTAINER_PROVIDER_PID_FILE": file.path, "PATH": "/usr/bin:/bin"]
        parent.standardInput = FileHandle.nullDevice; parent.standardOutput = FileHandle.nullDevice; parent.standardError = FileHandle.nullDevice
        try parent.run()
        defer { if parent.isRunning { kill(parent.processIdentifier, SIGKILL); parent.waitUntilExit() } }
        let end = Date().addingTimeInterval(3)
        while !FileManager.default.fileExists(atPath: file.path) && Date() < end { Thread.sleep(forTimeInterval: 0.01) }
        guard let text = try? String(contentsOf: file, encoding: .utf8) else { throw MiniTest.Failure(message: "synthetic provider did not start") }
        let pids = text.split(whereSeparator: \.isWhitespace).compactMap { Int32($0) }
        try MiniTest.expectEqual(pids.count, 2)
        let group = getpgid(pids[0]); try MiniTest.expect(group > 1 && group != getpgrp())
        defer { if getpgid(pids[0]) == group { kill(-group, SIGKILL) } }
        kill(parent.processIdentifier, SIGKILL); parent.waitUntilExit()
        func running() throws -> Bool {
            let result = try FoundationProcessRunner().run(executable: "/bin/ps", arguments: ["-p", pids.map(String.init).joined(separator: ","), "-o", "stat="], environment: [:], currentDirectory: nil)
            return result.stdoutString.split(whereSeparator: \.isNewline).contains { !$0.trimmingCharacters(in: .whitespaces).hasPrefix("Z") }
        }
        let cleanupDeadline = Date().addingTimeInterval(2)
        while try running(), Date() < cleanupDeadline { Thread.sleep(forTimeInterval: 0.025) }
        try MiniTest.expect(try !running(), "provider/descendant survived synthetic broker SIGKILL")
    })
]
