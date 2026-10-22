import Foundation
import Crypto

struct GuestGitCredentialArtifact {
    let platform: String
    let bytes: Data
    let sha256: String
    static func select(platform: String) throws -> Self {
        let payload: String, hash: String
        switch platform {
        case "linux/arm64": payload = GuestGitCredentialEmbeddedAssets.arm64Base64; hash = GuestGitCredentialEmbeddedAssets.arm64SHA256
        case "linux/amd64": payload = GuestGitCredentialEmbeddedAssets.amd64Base64; hash = GuestGitCredentialEmbeddedAssets.amd64SHA256
        default: throw GitCredentialFailure.unsupportedPlatform
        }
        guard GitCredentialProtocol.version == GuestGitCredentialEmbeddedAssets.protocolVersion, let bytes = Data(base64Encoded: payload) else { throw GitCredentialFailure.invalidArtifact }
        let artifact = Self(platform: platform, bytes: bytes, sha256: hash); try artifact.verify(); return artifact
    }
    func verify(readBack: Data? = nil) throws {
        let data = readBack ?? bytes
        guard data.count == bytes.count, data.count >= 64, data.count <= 2 * 1024 * 1024,
              Self.hash(data) == sha256, Array(data.prefix(7)) == [127,69,76,70,2,1,1] else { throw GitCredentialFailure.invalidArtifact }
        func number(_ offset: Int, _ count: Int) throws -> UInt64 {
            guard offset >= 0, count <= data.count - offset else { throw GitCredentialFailure.invalidArtifact }
            return (0..<count).reduce(0) { $0 | UInt64(data[offset + $1]) << ($1 * 8) }
        }
        let machine: UInt64
        switch platform { case "linux/arm64": machine = 183; case "linux/amd64": machine = 62; default: throw GitCredentialFailure.unsupportedPlatform }
        guard try number(16, 2) == 2, try number(18, 2) == machine, try number(20, 4) == 1, try number(52, 2) == 64 else { throw GitCredentialFailure.invalidArtifact }
        let offset = try number(32, 8), entrySize = try number(54, 2), count = try number(56, 2)
        guard offset >= 64, offset <= data.count, entrySize == 56, count > 0, count <= 128, count * entrySize <= UInt64(data.count) - offset else { throw GitCredentialFailure.invalidArtifact }
        let entryPoint = try number(24, 8); var executable = false
        for index in 0..<Int(count) {
            let p = Int(offset) + index * 56, kind = try number(p, 4), start = try number(p + 8, 8), size = try number(p + 32, 8)
            guard kind != 2, kind != 3, start <= data.count, size <= UInt64(data.count) - start else { throw GitCredentialFailure.invalidArtifact }
            if kind == 1 {
                let address = try number(p + 16, 8), memory = try number(p + 40, 8)
                guard memory >= size, address <= UInt64.max - memory else { throw GitCredentialFailure.invalidArtifact }
                if try number(p + 4, 4) & 1 != 0, entryPoint >= address, entryPoint - address < size { executable = true }
            }
        }
        let sections = try number(40, 8), sectionSize = try number(58, 2), sectionCount = try number(60, 2)
        guard executable, sections <= data.count, sectionCount <= 4096, sectionCount == 0 || sectionSize == 64,
              sectionSize * sectionCount <= UInt64(data.count) - sections else { throw GitCredentialFailure.invalidArtifact }
    }
    static func hash(_ data: Data) -> String { SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined() }
}
