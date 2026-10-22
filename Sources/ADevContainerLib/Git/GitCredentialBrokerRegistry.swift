import Foundation
import Darwin

struct GitCredentialRegistration: Codable, Equatable, Sendable {
    var context: GitCredentialRuntimeContext
    var destinations: Set<GitCredentialDestination>
    var directory: String
    var overrideRequired: Bool
    var protocolVersion: Int = GitCredentialProtocol.version
}

/// Owner-private files opened relative to verified directory descriptors. Shared by
/// registry/control IPC so neither follows a user-writable symlink during cleanup.
enum GitCredentialPrivateFiles {
    static func directory(_ path: String, create: Bool, privateMode: Bool = true) throws -> Int32 {
        guard path.hasPrefix("/"), path.utf8.count < Int(PATH_MAX), !path.utf8.contains(0) else { throw GitCredentialFailure.unsafePath }
        let components = path.split(separator: "/").map(String.init)
        guard !components.isEmpty, !components.contains("."), !components.contains("..") else { throw GitCredentialFailure.unsafePath }
        var fd = open("/", O_RDONLY | O_DIRECTORY | O_CLOEXEC)
        guard fd >= 0 else { throw GitCredentialFailure.unsafePath }
        do {
            for component in components {
                var next = openat(fd, component, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
                if next < 0, errno == ENOENT, create {
                    guard mkdirat(fd, component, 0o700) == 0 || errno == EEXIST else { throw GitCredentialFailure.unsafePath }
                    next = openat(fd, component, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
                }
                guard next >= 0 else { throw GitCredentialFailure.unsafePath }
                close(fd); fd = next
            }
            var st = stat()
            guard fstat(fd, &st) == 0, st.st_uid == geteuid(), privateMode ? st.st_mode & 0o777 == 0o700 : st.st_mode & 0o022 == 0 else { throw GitCredentialFailure.unsafePath }
            return fd
        } catch { close(fd); throw error }
    }
    private static func valid(_ name: String) -> Bool { !name.isEmpty && !name.contains("/") && !name.utf8.contains(0) && name != "." && name != ".." }
    static func read(_ name: String, directory: Int32) throws -> Data? {
        guard valid(name) else { throw GitCredentialFailure.unsafePath }
        let fd = openat(directory, name, O_RDONLY | O_NOFOLLOW | O_CLOEXEC | O_NONBLOCK)
        if fd < 0, errno == ENOENT { return nil }
        guard fd >= 0 else { throw GitCredentialFailure.unsafePath }; defer { close(fd) }
        var st = stat()
        guard fstat(fd, &st) == 0, st.st_mode & S_IFMT == S_IFREG, st.st_uid == geteuid(), st.st_mode & 0o777 == 0o600,
              st.st_nlink == 1, st.st_size >= 0, st.st_size <= 1024 * 1024 else { throw GitCredentialFailure.unsafePath }
        var data = Data(), buffer = [UInt8](repeating: 0, count: 16384)
        while true {
            let count = Darwin.read(fd, &buffer, buffer.count)
            if count == 0 { return data }
            if count < 0 { if errno == EINTR { continue }; throw GitCredentialFailure.unsafePath }
            guard count <= 1024 * 1024 - data.count else { throw GitCredentialFailure.unsafePath }
            data.append(contentsOf: buffer.prefix(count))
        }
    }
    static func write(_ bytes: Data, name: String, directory: Int32) throws {
        guard valid(name), bytes.count <= 1024 * 1024 else { throw GitCredentialFailure.unsafePath }
        _ = try read(name, directory: directory) // Reject existing symlink/nonprivate/multilink objects.
        let temporary = ".\(name).\(UUID().uuidString)"
        let fd = openat(directory, temporary, O_CREAT | O_EXCL | O_WRONLY | O_NOFOLLOW | O_CLOEXEC, 0o600)
        guard fd >= 0 else { throw GitCredentialFailure.unsafePath }
        defer { close(fd); unlinkat(directory, temporary, 0) }
        try bytes.withUnsafeBytes { buffer in
            var offset = 0
            while offset < bytes.count {
                let count = Darwin.write(fd, buffer.baseAddress!.advanced(by: offset), bytes.count - offset)
                if count < 0 { if errno == EINTR { continue }; throw GitCredentialFailure.unsafePath }
                guard count > 0 else { throw GitCredentialFailure.unsafePath }; offset += count
            }
        }
        guard fsync(fd) == 0, renameat(directory, temporary, directory, name) == 0, fsync(directory) == 0 else { throw GitCredentialFailure.unsafePath }
    }
}

final class GitCredentialBrokerRegistry {
    private let path: String
    init(path: String) { self.path = path }
    func load() throws -> [GitCredentialRegistration] {
        let directory = try GitCredentialPrivateFiles.directory(path, create: true); defer { close(directory) }
        guard let data = try GitCredentialPrivateFiles.read("registrations.json", directory: directory) else { return [] }
        guard let registrations = try? JSONDecoder().decode([GitCredentialRegistration].self, from: data) else { throw GitCredentialFailure.invalidContext }
        try validate(registrations); return registrations
    }
    func save(_ registrations: [GitCredentialRegistration]) throws {
        try validate(registrations)
        let directory = try GitCredentialPrivateFiles.directory(path, create: true); defer { close(directory) }
        let encoder = JSONEncoder(); encoder.outputFormatting = [.sortedKeys]
        try GitCredentialPrivateFiles.write(encoder.encode(registrations.sorted { $0.context.id < $1.context.id }), name: "registrations.json", directory: directory)
    }
    private func validate(_ registrations: [GitCredentialRegistration]) throws {
        guard registrations.count <= 128, Set(registrations.map { $0.context.id }).count == registrations.count else { throw GitCredentialFailure.invalidContext }
        for registration in registrations {
            let context = registration.context
            guard registration.protocolVersion == GitCredentialProtocol.version, !context.id.isEmpty, !context.id.hasPrefix("-"),
                  !context.incarnation.isEmpty, !context.user.isEmpty, ["linux/arm64", "linux/amd64"].contains(context.platform),
                  context.labels[ContainerIdentity.labelManaged] == "adevcontainer", Set(context.labels.keys).isSubset(of: GitCredentialRuntimeContext.identityLabels),
                  ([context.id, context.incarnation, context.user] + Array(context.labels.values)).allSatisfy(GitCredentialProtocol.safe),
                  registration.directory.hasPrefix("/"), !registration.directory.split(separator: "/").contains(".."),
                  registration.directory.utf8.count <= 85, GitCredentialProtocol.safe(registration.directory), registration.destinations.count <= 64 else { throw GitCredentialFailure.invalidContext }
            for destination in registration.destinations {
                guard try GitCredentialDestination(scheme: destination.scheme, host: destination.hostField) == destination else { throw GitCredentialFailure.invalidDestination }
            }
        }
    }
}
