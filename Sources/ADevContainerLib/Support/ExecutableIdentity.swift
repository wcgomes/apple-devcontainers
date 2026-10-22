import Foundation
import Darwin

/// Nonsecret identity of a broker executable. Device/inode catch a replaced
/// file (new keg, new copy); the Mach-O build UUID catches an in-place relink
/// that keeps the inode. Path strings never participate.
struct ExecutableIdentity: Codable, Equatable, Sendable {
    let executable: String
    let device: UInt64
    let inode: UInt64
    /// Mach-O LC_UUID as lowercase hex, or empty for non-Mach-O test wrappers.
    let build: String
    let protocolVersion: Int
    let process: Int32

    /// Identity of the running process, resolved through the physical path so a
    /// symlinked invocation still compares the same file.
    static func current() throws -> Self { try read(currentExecutablePath()) }

    /// Physical path of this process, independent of a selected `argv[0]`.
    static func currentExecutablePath() throws -> String {
        var size = UInt32(PATH_MAX)
        var buffer = [CChar](repeating: 0, count: Int(size))
        guard _NSGetExecutablePath(&buffer, &size) == 0 else { throw GitCredentialFailure.invalidContext }
        return String(decoding: buffer.prefix { $0 != 0 }.map { UInt8(bitPattern: $0) }, as: UTF8.self)
    }

    static func read(_ path: String) throws -> Self {
        guard path.hasPrefix("/"), let physical = realpath(path, nil) else { throw GitCredentialFailure.invalidContext }
        defer { free(physical) }
        let resolved = String(cString: physical)
        let fd = open(resolved, O_RDONLY | O_NOFOLLOW | O_CLOEXEC)
        guard fd >= 0 else { throw GitCredentialFailure.invalidContext }
        defer { close(fd) }
        var st = stat()
        guard fstat(fd, &st) == 0, st.st_mode & S_IFMT == S_IFREG, st.st_nlink >= 1 else { throw GitCredentialFailure.invalidContext }
        return .init(executable: resolved, device: UInt64(st.st_dev), inode: UInt64(st.st_ino), build: buildIdentifier(fd, size: st.st_size),
                     protocolVersion: GitCredentialProtocol.version, process: getpid())
    }

    /// Activation comparison. A non-Mach-O wrapper has no build UUID, so
    /// device/inode plus protocol must carry the decision; path equality never
    /// participates.
    func matches(_ other: Self) -> Bool {
        device == other.device && inode == other.inode && protocolVersion == other.protocolVersion
            && (build.isEmpty || other.build.isEmpty || build == other.build)
    }

    /// 64-bit thin Mach-O, or the first slice of a universal binary. Only the
    /// header and load commands are read; a non-Mach-O file reports no build
    /// identity, and a truncated header reports none rather than guessing.
    private static func buildIdentifier(_ fd: Int32, size: off_t) -> String {
        guard size >= 28 else { return "" }
        func read(_ offset: Int, _ count: Int) -> [UInt8] {
            guard offset >= 0, count > 0 else { return [] }
            var bytes = [UInt8](repeating: 0, count: count)
            let received = bytes.withUnsafeMutableBytes { pread(fd, $0.baseAddress, count, off_t(offset)) }
            return received == count ? bytes : []
        }
        func integer(_ bytes: [UInt8], _ offset: Int, bigEndian: Bool) -> UInt32 {
            guard offset >= 0, offset + 4 <= bytes.count else { return 0 }
            let value = bytes[offset..<(offset + 4)].reduce(UInt32(0)) { ($0 << 8) | UInt32($1) }
            return bigEndian ? value : value.byteSwapped
        }
        func long(_ bytes: [UInt8], _ offset: Int, bigEndian: Bool) -> UInt64 {
            guard offset >= 0, offset + 8 <= bytes.count else { return 0 }
            let value = bytes[offset..<(offset + 8)].reduce(UInt64(0)) { ($0 << 8) | UInt64($1) }
            return bigEndian ? value : value.byteSwapped
        }
        let header = read(0, 4096)
        guard header.count == 4096 else { return "" }
        // fat_arch entries carry the first slice offset after cputype/cpusubtype.
        var slice = 0
        switch integer(header, 0, bigEndian: true) {
        case 0xcafebabe: slice = Int(integer(header, 16, bigEndian: true))
        case 0xcafebabf: slice = Int(long(header, 16, bigEndian: true))
        case 0xbebafeca: slice = Int(integer(header, 16, bigEndian: false))
        case 0xbfbafeca: slice = Int(long(header, 16, bigEndian: false))
        default: break
        }
        let bytes = slice == 0 ? header : read(slice, 8192)
        guard bytes.count >= 32 else { return "" }
        let bigEndian: Bool
        switch integer(bytes, 0, bigEndian: true) {
        case 0xcffaedfe: bigEndian = false   // MH_MAGIC_64, little-endian arch
        case 0xfeedfacf: bigEndian = true    // MH_MAGIC_64, big-endian arch
        default: return ""                   // script, 32-bit, or unknown: no build identity
        }
        let commands = Int(integer(bytes, 16, bigEndian: bigEndian))
        var offset = 32
        for _ in 0..<min(commands, 4096) {
            let command = integer(bytes, offset, bigEndian: bigEndian), size = Int(integer(bytes, offset + 4, bigEndian: bigEndian))
            guard size >= 8, offset + size <= bytes.count else { return "" }
            if command == 0x1b, size >= 24 {
                return bytes[(offset + 8)..<(offset + 24)].map { String(format: "%02x", $0) }.joined()
            }
            offset += size
        }
        return ""
    }
}
