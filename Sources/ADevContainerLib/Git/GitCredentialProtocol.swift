import Foundation

/// Secret-free trace hook. Never persists: tests and production must not grow diag.log.
enum GitCredentialDiag {
    static func event(_ code: String, _ detail: String = "", traceDirectory: String? = nil) {}
}

enum GitCredentialFailure: Error, Equatable, CustomStringConvertible {
    case invalidMessage, invalidDestination, invalidArtifact, unsupportedPlatform
    case transport, deadline, overloaded, unsafePath, invalidContext

    var description: String {
        "Git credential connection unavailable (\(diagnosticCode)); run adevcontainer start or up on the running container, or log in on the host."
    }
    /// Stable, secret-free reason. Safe to surface in CLI errors; never includes paths or provider output.
    var diagnosticCode: String {
        switch self {
        case .invalidMessage: "invalid message"
        case .invalidDestination: "invalid destination"
        case .invalidArtifact: "invalid guest artifact"
        case .unsupportedPlatform: "unsupported guest platform"
        case .transport: "transport failed"
        case .deadline: "deadline exceeded"
        case .overloaded: "capacity exceeded"
        case .unsafePath: "unsafe private path"
        case .invalidContext: "invalid runtime identity"
        }
    }
}

enum GitCredentialOperation: UInt16, Sendable { case hello = 1, get = 2, erase = 3, reply = 4 }
enum GitCredentialField: UInt16, Hashable, Sendable { case scheme = 1, host, path, username, password, platform }
struct GitCredentialFrame: Equatable, Sendable {
    var operation: GitCredentialOperation
    var request: UInt64
    var generation: UInt64
    var fields: [GitCredentialField: String]
}

enum GitCredentialProtocol {
    static let version = 1
    static let headerSize = 32
    static let limit = 65536
    static func safe(_ value: String) -> Bool {
        !value.utf8.contains(where: { $0 < 0x20 || $0 == 0x7f })
    }
    static func integer(_ bytes: Data, _ offset: Int, _ count: Int) -> UInt64 {
        bytes[offset..<(offset + count)].reduce(0) { ($0 << 8) | UInt64($1) }
    }
    private static func append(_ value: UInt64, count: Int, to bytes: inout Data) {
        for index in (0..<count).reversed() { bytes.append(UInt8(truncatingIfNeeded: value >> (index * 8))) }
    }
    static func encode(_ frame: GitCredentialFrame) throws -> Data {
        var payload = Data()
        for field in frame.fields.keys.sorted(by: { $0.rawValue < $1.rawValue }) {
            let value = frame.fields[field]!
            guard safe(value), value.utf8.count <= Int(UInt16.max), (frame.operation == .hello) == (field == .platform) else { throw GitCredentialFailure.invalidMessage }
            append(UInt64(field.rawValue), count: 2, to: &payload)
            append(UInt64(value.utf8.count), count: 2, to: &payload); payload.append(contentsOf: value.utf8)
        }
        guard payload.count <= limit - headerSize, frame.operation != .hello || frame.fields.count == 1 else { throw GitCredentialFailure.invalidMessage }
        var bytes = Data([65,71,67,82,0,1]); append(UInt64(frame.operation.rawValue), count: 2, to: &bytes)
        append(frame.request, count: 8, to: &bytes); append(frame.generation, count: 8, to: &bytes)
        append(UInt64(payload.count), count: 4, to: &bytes); append(0, count: 4, to: &bytes)
        bytes.append(payload); return bytes
    }
    static func size(_ data: Data) throws -> Int? {
        guard data.count >= headerSize else { return nil }
        guard Array(data.prefix(6)) == [65,71,67,82,0,1], integer(data, 28, 4) == 0,
              GitCredentialOperation(rawValue: UInt16(integer(data, 6, 2))) != nil else { throw GitCredentialFailure.invalidMessage }
        let count = integer(data, 24, 4)
        guard count <= limit - headerSize else { throw GitCredentialFailure.invalidMessage }
        return headerSize + Int(count)
    }
    static func decode(_ data: Data) throws -> GitCredentialFrame {
        // Copy to establish zero-based Data indices, including for sliced input.
        let data = Data(data)
        guard let count = try size(data), count == data.count,
              let operation = GitCredentialOperation(rawValue: UInt16(integer(data, 6, 2))) else { throw GitCredentialFailure.invalidMessage }
        var offset = headerSize, fields: [GitCredentialField: String] = [:]
        while offset < count {
            guard count - offset >= 4, let field = GitCredentialField(rawValue: UInt16(integer(data, offset, 2))),
                  fields[field] == nil, (operation == .hello) == (field == .platform) else { throw GitCredentialFailure.invalidMessage }
            let length = Int(integer(data, offset + 2, 2)); offset += 4
            guard length <= count - offset, let value = String(data: data.subdata(in: offset..<(offset + length)), encoding: .utf8), safe(value) else { throw GitCredentialFailure.invalidMessage }
            fields[field] = value; offset += length
        }
        guard operation != .hello || fields.count == 1 else { throw GitCredentialFailure.invalidMessage }
        return .init(operation: operation, request: integer(data, 8, 8), generation: integer(data, 16, 8), fields: fields)
    }
}

struct GitCredentialFrameDecoder {
    private var bytes = Data()
    var isEmpty: Bool { bytes.isEmpty }
    mutating func append(_ data: Data) throws -> [GitCredentialFrame] {
        var frames: [GitCredentialFrame] = []
        for byte in data {
            guard bytes.count < GitCredentialProtocol.limit else { throw GitCredentialFailure.invalidMessage }
            bytes.append(byte)
            if bytes.count >= GitCredentialProtocol.headerSize, let size = try GitCredentialProtocol.size(bytes), size == bytes.count {
                frames.append(try GitCredentialProtocol.decode(bytes)); bytes.removeAll(keepingCapacity: true)
            }
            // A caller controls read sizes; never collect an unbounded output list.
            guard frames.count <= 64 else { throw GitCredentialFailure.overloaded }
        }
        return frames
    }
    func finish() throws { if !bytes.isEmpty { throw GitCredentialFailure.invalidMessage } }
}
