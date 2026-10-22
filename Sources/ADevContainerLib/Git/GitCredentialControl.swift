import Foundation
import Darwin

struct GitCredentialControlRequest: Codable, Sendable {
    enum Operation: String, Codable, Sendable { case register, unregister, refresh, hello, retire }
    var operation: Operation
    var registration: GitCredentialRegistration?
    var id: String?
    var token: String?
    var sources: [String]?
}
struct GitCredentialControlReply: Codable {
    let succeeded: Bool
    /// Refresh-only. A miss is not a transport failure and must not be reported as acquired.
    let acquired: Bool
    /// `hello` only: the authenticated owner's nonsecret process/executable identity.
    var identity: ExecutableIdentity? = nil
}

/// What an activation probe found at the private endpoint.
enum GitCredentialBrokerStatus: Equatable, Sendable {
    /// No listener: absent, or a stale socket the kernel refuses to connect to.
    case absent
    /// An authenticated same-user owner answered `hello`.
    case owner(ExecutableIdentity)
    /// The endpoint exists but is not a private socket or does not speak the
    /// control protocol. Activation fails closed rather than guessing.
    case unrecognized
}

/// The private control socket is the authority for liveness and identity: it
/// already enforces same-user peer credentials and private inode ownership.
protocol GitCredentialBrokerProbing: Sendable {
    func probe(_ context: GitCredentialLaunchContext, deadline: TimeInterval) throws -> GitCredentialBrokerStatus
    func retire(_ context: GitCredentialLaunchContext, deadline: TimeInterval) throws
    func exchange(_ request: GitCredentialControlRequest, context: GitCredentialLaunchContext, deadline: TimeInterval) throws -> GitCredentialControlReply
}

struct GitCredentialControlClient: GitCredentialBrokerProbing {
    func probe(_ context: GitCredentialLaunchContext, deadline: TimeInterval) throws -> GitCredentialBrokerStatus {
        let connection: Int32
        do { connection = try connect(context, deadline: deadline) }
        catch GitCredentialFailure.transport { return .absent }
        catch GitCredentialFailure.unsafePath { return .unrecognized }
        defer { close(connection) }
        do {
            try GitCredentialControlSocket.send(GitCredentialControlRequest(operation: .hello), fd: connection, deadline: deadline)
            let reply: GitCredentialControlReply = try GitCredentialControlSocket.receive(connection, deadline: deadline)
            guard reply.succeeded, let identity = reply.identity else { return .unrecognized }
            return .owner(identity)
        } catch GitCredentialFailure.deadline {
            // Connected but silent: the endpoint did not speak the control
            // protocol. Never treat this as absence — a successor would unlink
            // a live owner's socket and leave two processes serving.
            return .unrecognized
        } catch GitCredentialFailure.transport {
            // The owner disappeared between accept and reply: a race, not a
            // foreign endpoint. A successor still needs the lifetime lock.
            return .absent
        } catch { return .unrecognized }
    }
    func retire(_ context: GitCredentialLaunchContext, deadline: TimeInterval) throws {
        let connection = try connect(context, deadline: deadline)
        defer { close(connection) }
        try GitCredentialControlSocket.send(GitCredentialControlRequest(operation: .retire), fd: connection, deadline: deadline)
        let reply: GitCredentialControlReply = try GitCredentialControlSocket.receive(connection, deadline: deadline)
        guard reply.succeeded else { throw GitCredentialFailure.transport }
    }
    func exchange(_ request: GitCredentialControlRequest, context: GitCredentialLaunchContext, deadline: TimeInterval) throws -> GitCredentialControlReply {
        let connection = try connect(context, deadline: deadline)
        defer { close(connection) }
        try GitCredentialControlSocket.send(request, fd: connection, deadline: deadline)
        return try GitCredentialControlSocket.receive(connection, deadline: deadline)
    }
    private func connect(_ context: GitCredentialLaunchContext, deadline: TimeInterval) throws -> Int32 {
        guard let directory = try Self.endpoint(context) else { throw GitCredentialFailure.transport }
        defer { close(directory) }
        var st = stat()
        if fstatat(directory, "control.sock", &st, AT_SYMLINK_NOFOLLOW) != 0 { throw errno == ENOENT ? GitCredentialFailure.transport : GitCredentialFailure.unsafePath }
        guard st.st_mode & S_IFMT == S_IFSOCK,
              st.st_uid == geteuid(), st.st_mode & 0o077 == 0 else { throw GitCredentialFailure.unsafePath }
        let fd = socket(AF_UNIX, SOCK_STREAM, 0); guard fd >= 0 else { throw GitCredentialFailure.transport }
        do {
            try GitCredentialControlSocket.configure(fd)
            var address = try GitCredentialControlSocket.address(context.socket)
            let result = withUnsafePointer(to: &address) { $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { Darwin.connect(fd, $0, socklen_t(MemoryLayout<sockaddr_un>.size)) } }
            if result != 0 {
                guard errno == EINPROGRESS else { throw GitCredentialFailure.transport }
                var p = pollfd(fd: fd, events: Int16(POLLOUT), revents: 0)
                let remaining = deadline - ProcessInfo.processInfo.systemUptime
                guard remaining > 0, poll(&p, 1, Int32(min(remaining * 1000, 30000))) > 0 else { throw GitCredentialFailure.deadline }
            }
            var connectionError: Int32 = 0, errorSize = socklen_t(MemoryLayout<Int32>.size)
            guard getsockopt(fd, SOL_SOCKET, SO_ERROR, &connectionError, &errorSize) == 0, connectionError == 0 else { throw GitCredentialFailure.transport }
            guard GitCredentialControlSocket.peer(fd) else { throw GitCredentialFailure.unsafePath }
            return fd
        } catch { close(fd); throw error }
    }
    /// Missing endpoint directory means no broker has ever run: absence, not an
    /// unsafe path. Anything present but not an owner-private directory fails closed.
    private static func endpoint(_ context: GitCredentialLaunchContext) throws -> Int32? {
        do { return try GitCredentialPrivateFiles.directory(context.endpoints, create: false) }
        catch GitCredentialFailure.unsafePath {
            var st = stat()
            guard lstat(context.endpoints, &st) != 0, errno == ENOENT else { throw GitCredentialFailure.unsafePath }
            return nil
        }
    }
}

enum GitCredentialControlSocket {
    private static let creationLock = NSLock()
    static func bindPrivate(_ fd: Int32, address: inout sockaddr_un) -> Int32 {
        // A client can discover the socket immediately after bind, before a
        // later chmod. Create it private, rather than exposing a transient mode
        // that a racing client must correctly reject as unsafe. Serialize the
        // brief process-wide umask change across in-process service instances.
        creationLock.lock(); defer { creationLock.unlock() }
        let previous = umask(0o077); defer { umask(previous) }
        return withUnsafePointer(to: &address) { $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { Darwin.bind(fd, $0, socklen_t(MemoryLayout<sockaddr_un>.size)) } }
    }
    static func address(_ path: String) throws -> sockaddr_un {
        guard path.utf8.count < 104, !path.utf8.contains(0) else { throw GitCredentialFailure.unsafePath }
        var address = sockaddr_un(); address.sun_family = sa_family_t(AF_UNIX); address.sun_len = UInt8(MemoryLayout<sockaddr_un>.size)
        withUnsafeMutableBytes(of: &address.sun_path) { target in target.copyBytes(from: path.utf8CString.map { UInt8(bitPattern: $0) }) }
        return address
    }
    static func peer(_ fd: Int32) -> Bool {
        var uid: uid_t = 0, gid: gid_t = 0
        return getpeereid(fd, &uid, &gid) == 0 && uid == geteuid()
    }
    static func configure(_ fd: Int32) throws {
        guard fcntl(fd, F_SETFD, FD_CLOEXEC) == 0, fcntl(fd, F_SETFL, fcntl(fd, F_GETFL) | O_NONBLOCK) == 0,
              fcntl(fd, F_SETNOSIGPIPE, 1) == 0 else { throw GitCredentialFailure.transport }
    }
    static func transfer(_ fd: Int32, data: inout Data, writing: Bool, deadline: TimeInterval) throws {
        var offset = 0
        while offset < data.count {
            let remaining = deadline - ProcessInfo.processInfo.systemUptime
            guard remaining > 0 else { throw GitCredentialFailure.deadline }
            var p = pollfd(fd: fd, events: Int16(writing ? POLLOUT : POLLIN), revents: 0)
            let ready = poll(&p, 1, Int32(min(remaining * 1000, 1000)))
            if ready < 0 { if errno == EINTR { continue }; throw GitCredentialFailure.transport }
            if ready == 0 { continue }
            let count = data.withUnsafeMutableBytes { bytes in
                writing ? Darwin.write(fd, bytes.baseAddress!.advanced(by: offset), bytes.count - offset)
                        : Darwin.read(fd, bytes.baseAddress!.advanced(by: offset), bytes.count - offset)
            }
            if count < 0 { if errno == EINTR || errno == EAGAIN { continue }; throw GitCredentialFailure.transport }
            guard count > 0 else { throw GitCredentialFailure.transport }; offset += count
        }
    }
    static func receive<T: Decodable>(_ fd: Int32, deadline: TimeInterval) throws -> T {
        var header = Data(repeating: 0, count: 4); try transfer(fd, data: &header, writing: false, deadline: deadline)
        let size = Int(GitCredentialProtocol.integer(header, 0, 4))
        guard size > 0, size <= GitCredentialProtocol.limit else { throw GitCredentialFailure.invalidMessage }
        var body = Data(repeating: 0, count: size); try transfer(fd, data: &body, writing: false, deadline: deadline)
        guard let value = try? JSONDecoder().decode(T.self, from: body) else { throw GitCredentialFailure.invalidMessage }; return value
    }
    static func send<T: Encodable>(_ value: T, fd: Int32, deadline: TimeInterval) throws {
        var body = try JSONEncoder().encode(value)
        guard !body.isEmpty, body.count <= GitCredentialProtocol.limit else { throw GitCredentialFailure.invalidMessage }
        var header = Data((0..<4).reversed().map { UInt8(truncatingIfNeeded: body.count >> ($0 * 8)) })
        try transfer(fd, data: &header, writing: true, deadline: deadline); try transfer(fd, data: &body, writing: true, deadline: deadline)
    }
}

extension GitCredentialBrokerService {
    func request(_ request: GitCredentialControlRequest, activate: Bool = true, deadline: TimeInterval = ProcessInfo.processInfo.systemUptime + 30) throws -> Bool {
        guard ProcessInfo.processInfo.systemUptime < deadline else { throw GitCredentialFailure.deadline }
        if activate { try ensure(deadline: deadline) }; try context.validate()
        if !activate {
            // Teardown never starts, creates, or reconciles a broker. No
            // listener is a successful no-op; saved intent is revalidated by a
            // successor before any use.
            do { return try reply(request, deadline: deadline) }
            catch GitCredentialFailure.transport { return false }
        }
        while true {
            do { return try reply(request, deadline: deadline) }
            catch GitCredentialFailure.transport {
                guard ProcessInfo.processInfo.systemUptime < deadline else { throw GitCredentialFailure.transport }
                Thread.sleep(forTimeInterval: 0.05)
                try ensure(deadline: deadline)
            }
        }
    }
    private func reply(_ request: GitCredentialControlRequest, deadline: TimeInterval) throws -> Bool {
        let reply = try control.exchange(request, context: context, deadline: deadline)
        guard reply.succeeded else { throw GitCredentialFailure.invalidContext }
        return reply.acquired
    }

    func run(ports: GitCredentialBrokerPorts, shouldStop: @Sendable () -> Bool) throws {
        try context.validate()
        let identity = try ExecutableIdentity.current()
        let owner: GitCredentialServiceLock
        do { owner = try GitCredentialServiceLock(directory: context.endpoints, wait: Self.lifetimeLockWait) }
        // A spawned loser exits successfully without touching the winner's endpoint.
        catch GitCredentialFailure.overloaded { return }
        defer { withExtendedLifetime(owner) {} }
        let broker = try GitCredentialBroker(registry: GitCredentialBrokerRegistry(path: context.state), ports: ports)
        defer { broker.shutdown() }
        let directory = try GitCredentialPrivateFiles.directory(context.endpoints, create: true); defer { close(directory) }
        var existing = stat()
        if fstatat(directory, "control.sock", &existing, AT_SYMLINK_NOFOLLOW) == 0 {
            guard existing.st_mode & S_IFMT == S_IFSOCK, existing.st_uid == geteuid(), existing.st_mode & 0o077 == 0,
                  unlinkat(directory, "control.sock", 0) == 0 else { throw GitCredentialFailure.unsafePath }
        } else if errno != ENOENT { throw GitCredentialFailure.unsafePath }
        let listener = socket(AF_UNIX, SOCK_STREAM, 0); guard listener >= 0 else { throw GitCredentialFailure.transport }; defer { close(listener) }
        var address = try GitCredentialControlSocket.address(context.socket)
        let bound = GitCredentialControlSocket.bindPrivate(listener, address: &address)
        guard bound == 0 else { throw GitCredentialFailure.transport }
        var inode = stat(); guard fstatat(directory, "control.sock", &inode, AT_SYMLINK_NOFOLLOW) == 0 else { throw GitCredentialFailure.unsafePath }
        defer {
            // Remove only the private socket this process bound. A successor's
            // endpoint and every lock inode are never touched.
            var current = stat()
            if fstatat(directory, "control.sock", &current, AT_SYMLINK_NOFOLLOW) == 0, current.st_ino == inode.st_ino, current.st_dev == inode.st_dev,
               current.st_mode & S_IFMT == S_IFSOCK, current.st_uid == geteuid() { unlinkat(directory, "control.sock", 0) }
        }
        guard fchmodat(directory, "control.sock", 0o600, 0) == 0 else { throw GitCredentialFailure.unsafePath }
        try GitCredentialControlSocket.configure(listener)
        guard listen(listener, 64) == 0 else { throw GitCredentialFailure.transport }
        var nextReconcile: TimeInterval = 0
        var retired = false
        while !shouldStop() && !retired {
            let now = ProcessInfo.processInfo.systemUptime
            if now >= nextReconcile { nextReconcile = now + GitCredentialBroker.recheckInterval; broker.reconcile() }
            if broker.retireIfIdle() { return }
            var p = pollfd(fd: listener, events: Int16(POLLIN), revents: 0)
            let wait = Int32(max(0, min(100, (nextReconcile - ProcessInfo.processInfo.systemUptime) * 1000)))
            guard poll(&p, 1, wait) >= 0 || errno == EINTR else { throw GitCredentialFailure.transport }
            if p.revents & Int16(POLLIN) == 0 { continue }
            let peer = accept(listener, nil, nil); if peer < 0 { continue }
            defer { close(peer) }
            do {
                guard GitCredentialControlSocket.peer(peer) else { throw GitCredentialFailure.unsafePath }
                try GitCredentialControlSocket.configure(peer)
                let deadline = ProcessInfo.processInfo.systemUptime + 30
                let request: GitCredentialControlRequest = try GitCredentialControlSocket.receive(peer, deadline: deadline)
                switch request.operation {
                case .hello, .retire:
                    guard request.registration == nil, request.token == nil, request.id == nil, request.sources == nil else { throw GitCredentialFailure.invalidMessage }
                    // The reply leaves before the loop exits so the caller knows
                    // the authenticated owner accepted retirement.
                    try GitCredentialControlSocket.send(GitCredentialControlReply(succeeded: true, acquired: false, identity: identity), fd: peer, deadline: deadline)
                    if request.operation == .retire { retired = true }
                case .unregister:
                    guard let id = request.id, request.token == nil else { throw GitCredentialFailure.invalidMessage }
                    try broker.unregister(id)
                    try GitCredentialControlSocket.send(GitCredentialControlReply(succeeded: true, acquired: false), fd: peer, deadline: deadline)
                case .register, .refresh:
                    guard let registration = request.registration else { throw GitCredentialFailure.invalidMessage }
                    try broker.register(registration, override: request.token, reset: request.operation == .refresh)
                    let acquired = request.operation == .refresh ? try broker.validate(id: registration.context.id, sources: request.sources ?? []) : true
                    try GitCredentialControlSocket.send(GitCredentialControlReply(succeeded: true, acquired: acquired), fd: peer, deadline: deadline)
                }
            } catch {
                try? GitCredentialControlSocket.send(GitCredentialControlReply(succeeded: false, acquired: false), fd: peer, deadline: ProcessInfo.processInfo.systemUptime + 1)
            }
        }
    }
}
