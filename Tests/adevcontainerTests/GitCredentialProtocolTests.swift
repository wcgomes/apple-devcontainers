import Foundation
@testable import ADevContainerLib

@MainActor let gitCredentialProtocolTests: [(String, () throws -> Void)] = [
    ("credentials.codec.nativeFixture", {
        let frame = GitCredentialFrame(operation: .get, request: 1, generation: 7, fields: [.scheme: "https", .host: "example.invalid:8443", .path: "org/répô@x:y", .username: "u@:/é"])
        let bytes = try GitCredentialProtocol.encode(frame)
        try MiniTest.expectEqual(Array(bytes.prefix(32)), [65,71,67,82,0,1,0,2,0,0,0,0,0,0,0,1,0,0,0,0,0,0,0,7,0,0,0,61,0,0,0,0])
        try MiniTest.expectEqual(try GitCredentialProtocol.decode(bytes), frame)
        var decoder = GitCredentialFrameDecoder(), received: [GitCredentialFrame] = []
        for byte in bytes { received += try decoder.append(Data([byte])) }
        try MiniTest.expectEqual(received, [frame]); try decoder.finish()
    }),
    ("credentials.codec.boundsInjectionAndTruncation", {
        let valid = GitCredentialFrame(operation: .reply, request: 42, generation: 7, fields: [.username: "synthetic", .password: "synthetic"])
        let bytes = try GitCredentialProtocol.encode(valid)
        for value in ["x\ny", "x\ry", "x\0y", String(repeating: "x", count: 65536)] {
            var bad = valid; bad.fields[.password] = value
            try MiniTest.expectThrows({ _ = try GitCredentialProtocol.encode(bad) }, validate: { _ in })
        }
        for count in [0, 1, 31, bytes.count - 1] {
            try MiniTest.expectThrows({ _ = try GitCredentialProtocol.decode(bytes.prefix(count)) }, validate: { _ in })
        }
        var decoder = GitCredentialFrameDecoder(); _ = try decoder.append(bytes.prefix(33))
        try MiniTest.expectThrows({ try decoder.finish() }, validate: { _ in })
        var oversized = bytes; oversized[24] = 1
        try MiniTest.expectThrows({ _ = try decoder.append(oversized) }, validate: { _ in })
        var duplicate = bytes
        duplicate.append(contentsOf: [0,4,0,1,120]); duplicate[27] += 5
        try MiniTest.expectThrows({ _ = try GitCredentialProtocol.decode(duplicate) }, validate: { _ in })
        var reserved = bytes; reserved[31] = 1
        try MiniTest.expectThrows({ _ = try GitCredentialProtocol.decode(reserved) }, validate: { _ in })
        var outOfOrder = GitCredentialFrameDecoder()
        var second = valid; second.request = 1
        let frames = try outOfOrder.append(bytes + GitCredentialProtocol.encode(second))
        try MiniTest.expectEqual(frames.map(\.request), [42,1])
    }),
    ("credentials.diag.existingBrokerDirectoryWritesNothing", {
        let root = try credentialTestRoot(); defer { try? FileManager.default.removeItem(at: root) }
        let dir = root.path + "/git-broker"
        try FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        GitCredentialDiag.event("broker.acquire", "req=1 result=present", traceDirectory: dir)
        try MiniTest.expect(!FileManager.default.fileExists(atPath: dir + "/diag.log"), "diagnostic must not write diag.log when a broker directory exists")
        let homeLog = NSHomeDirectory() + "/.adevcontainer/git-broker/diag.log"
        GitCredentialDiag.event("broker.reply", "req=1 delivered=yes")
        try MiniTest.expect(!FileManager.default.fileExists(atPath: homeLog), "diagnostic must not create ~/.adevcontainer/git-broker/diag.log")
    })
]
