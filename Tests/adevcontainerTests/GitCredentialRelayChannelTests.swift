import Foundation
import Darwin
@testable import ADevContainerLib

/// Real native-process framing check; still no Apple runtime/broker/provider.
@MainActor let gitCredentialRelayChannelTests: [(String, () throws -> Void)] = [
    ("credentials.channel.nativeDuplex", {
        let relay = URL(fileURLWithPath: FileManager.default.currentDirectoryPath).appendingPathComponent(".build/guest-credential-relay-tests/relay").path
        guard FileManager.default.isExecutableFile(atPath: relay) else { throw MiniTest.Skip(message: "run sh scripts/test-guest-credential-relay.sh for optional native-channel execution") }
        let approved = try credentialTestBase().path
        var template = Array((approved + "/gc.XXXXXX").utf8CString)
        guard let directory = mkdtemp(&template) else { throw MiniTest.Failure(message: "native channel test directory unavailable") }
        let path = String(cString: directory); defer { try? FileManager.default.removeItem(atPath: path) }
        let context = GitCredentialRuntimeContext(id: "synthetic", incarnation: "reference:800000000", platform: "linux/arm64", user: "root", labels: ["devcontainer.managed": "adevcontainer"])
        let ports = GitCredentialBrokerPorts(context: { _ in context }, connect: { registration, generation, receive, disconnected in
            let process = try CredentialDuplexProcess(executable: relay, arguments: ["relay", path, String(generation)], environment: [:])
            let channel = try GitCredentialRelayChannel(process: process, platform: registration.context.platform, generation: generation)
            channel.start(receive: receive, disconnected: disconnected); return channel
        }, acquire: { url, _, _ in
            guard url == "https://example.invalid/org/repo" else { throw GitCredentialFailure.invalidDestination }
            return .init(username: "host-account", password: "synthetic-channel")
        })
        let broker = try GitCredentialBroker(registry: GitCredentialBrokerRegistry(path: path + "/registry"), ports: ports)
        defer { broker.shutdown() }
        try broker.register(.init(context: context, destinations: [try .init(url: "https://example.invalid/original/repo")], directory: path, overrideRequired: false))
        let end = Date().addingTimeInterval(2)
        while !FileManager.default.fileExists(atPath: path + "/credential.sock") && Date() < end { Thread.sleep(forTimeInterval: 0.01) }
        let result = try CredentialProviderProcessRunner(timeout: 3).run(executable: relay, arguments: ["client", path, "get"], environment: [:], currentDirectory: nil, stdinData: Data("protocol=https\nhost=example.invalid\npath=org/repo\nusername=guest\n\n".utf8))
        try MiniTest.expect(result.succeeded)
        try MiniTest.expectEqual(result.stdoutString, "username=guest\npassword=synthetic-channel\n\n")
    })
]
