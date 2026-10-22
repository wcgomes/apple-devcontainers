import Foundation
import Crypto

struct GitCredentialDestination: Hashable, Codable, Sendable {
    let scheme: String
    let hostname: String
    let port: Int
    init(scheme: String, host: String) throws {
        guard scheme == "http" || scheme == "https", !host.isEmpty, GitCredentialProtocol.safe(host),
              !host.contains(where: { $0.isWhitespace }), let components = URLComponents(string: "\(scheme)://\(host)"),
              components.user == nil, components.password == nil, components.path.isEmpty,
              components.query == nil, components.fragment == nil, let name = components.host,
              !name.isEmpty, GitCredentialProtocol.safe(name), !name.contains(where: { $0.isWhitespace }), !name.contains("%"), components.port == nil || (1...65535).contains(components.port!) else { throw GitCredentialFailure.invalidDestination }
        self.scheme = scheme; hostname = name.lowercased(); port = components.port ?? (scheme == "https" ? 443 : 80)
    }
    init(url: String) throws {
        guard GitCredentialProtocol.safe(url), let c = URLComponents(string: url), let scheme = c.scheme?.lowercased(),
              let host = c.host, GitCredentialProtocol.safe(c.path) else { throw GitCredentialFailure.invalidDestination }
        try self.init(scheme: scheme, host: host + (c.port.map { ":\($0)" } ?? ""))
    }
    var hostField: String { hostname + (port == (scheme == "https" ? 443 : 80) ? "" : ":\(port)") }
}
struct GitCredentialQuery: Equatable, Sendable {
    var scheme: String
    var host: String
    var path: String = ""
    var username: String = ""
    var password: String = ""
    init(scheme: String, host: String, path: String = "", username: String = "", password: String = "") {
        self.scheme = scheme; self.host = host; self.path = path; self.username = username; self.password = password
    }
    init(frame: GitCredentialFrame) throws {
        guard frame.operation == .get || frame.operation == .erase, let scheme = frame.fields[.scheme], let host = frame.fields[.host] else { throw GitCredentialFailure.invalidMessage }
        self.init(scheme: scheme, host: host, path: frame.fields[.path] ?? "", username: frame.fields[.username] ?? "", password: frame.fields[.password] ?? "")
    }
}
struct GitCredentialBrokerPolicy {
    private let clock: () -> TimeInterval
    private let key = SymmetricKey(size: .bits256)
    private struct Session { var generation: UInt64; var destinations: Set<GitCredentialDestination>; var lastRequest: UInt64 = 0 }
    private struct Delivery { let session: String; let scope: String; let fingerprint: Data; let username: String }
    private struct Rejection { let session: String; let scope: String; let fingerprint: Data; let until: TimeInterval }
    private var sessions: [String: Session] = [:]
    private var deliveries: [Delivery] = []
    private var rejections: [Rejection] = []
    init(clock: @escaping () -> TimeInterval = { ProcessInfo.processInfo.systemUptime }) { self.clock = clock }
    mutating func register(_ session: String, generation: UInt64, destinations: Set<GitCredentialDestination>) {
        unregister(session); guard generation != 0, destinations.count <= 64, sessions.count < 128 else { return }
        sessions[session] = .init(generation: generation, destinations: destinations)
    }
    mutating func unregister(_ session: String) { sessions.removeValue(forKey: session); reset(session) }
    func authorize(_ session: String, generation: UInt64, query: GitCredentialQuery) -> String? {
        guard current(session, generation: generation), [query.path, query.username, query.password].allSatisfy(GitCredentialProtocol.safe),
              let destination = try? GitCredentialDestination(scheme: query.scheme, host: query.host),
              sessions[session]!.destinations.contains(destination), destination.hostname != "dev.azure.com" || !query.path.split(separator: "/").isEmpty else { return nil }
        var components = URLComponents(); components.scheme = destination.scheme; components.host = destination.hostname
        if destination.port != (destination.scheme == "https" ? 443 : 80) { components.port = destination.port }
        components.path = query.path.isEmpty ? "" : "/" + query.path
        return components.string
    }
    private func fingerprint(_ value: String) -> Data { Data(HMAC<SHA256>.authenticationCode(for: Data(value.utf8), using: key)) }
    mutating func deliver(_ session: String, generation: UInt64, query: GitCredentialQuery, credential: GitHTTPSCredentials) -> GitHTTPSCredentials? {
        guard let scope = authorize(session, generation: generation, query: query), !credential.password.isEmpty,
              !credential.username.isEmpty, GitCredentialProtocol.safe(credential.password), GitCredentialProtocol.safe(credential.username),
              credential.password.utf8.count + credential.username.utf8.count + query.username.utf8.count <= 60000 else { return nil }
        let now = clock()
        rejections.removeAll { $0.until <= now }
        let hash = fingerprint(credential.password)
        guard !rejections.contains(where: { $0.session == session && $0.scope == scope && $0.fingerprint == hash }) else { return nil }
        let username = query.username.isEmpty ? credential.username : query.username
        deliveries.append(.init(session: session, scope: scope, fingerprint: hash, username: username))
        if deliveries.count > 256 { deliveries.removeFirst(deliveries.count - 256) }
        return .init(username: username, password: credential.password)
    }
    mutating func erase(_ session: String, generation: UInt64, query: GitCredentialQuery) {
        guard let scope = authorize(session, generation: generation, query: query), !query.password.isEmpty else { return }
        let hash = fingerprint(query.password)
        guard deliveries.contains(where: { $0.session == session && $0.scope == scope && $0.fingerprint == hash && (query.username.isEmpty || query.username == $0.username) }) else { return }
        let now = clock()
        rejections.removeAll { $0.until <= now || ($0.session == session && $0.scope == scope && $0.fingerprint == hash) }
        rejections.append(.init(session: session, scope: scope, fingerprint: hash, until: now + 30))
        if rejections.count > 256 { rejections.removeFirst(rejections.count - 256) }
    }
    mutating func reset(_ session: String) { deliveries.removeAll { $0.session == session }; rejections.removeAll { $0.session == session } }
    mutating func begin(_ session: String, generation: UInt64, request: UInt64) -> Bool {
        guard current(session, generation: generation), request > sessions[session]!.lastRequest else { return false }
        sessions[session]!.lastRequest = request; return true
    }
    func current(_ session: String, generation: UInt64) -> Bool { generation != 0 && sessions[session]?.generation == generation }
}

struct GitCredentialWork: Hashable, Sendable {
    let session: String
    let generation: UInt64
    let request: UInt64
}
struct GitCredentialAdmission {
    private let activeLimit: Int
    private let queueLimit: Int
    private var queued: [GitCredentialWork] = []
    private var active: Set<GitCredentialWork> = []
    private var lastSession: String?
    init(activeLimit: Int = 8, queueLimit: Int = 64) { self.activeLimit = max(1, activeLimit); self.queueLimit = max(0, queueLimit) }
    mutating func enqueue(_ work: GitCredentialWork) -> Bool {
        guard queued.count < queueLimit, !queued.contains(work), !active.contains(work) else { return false }
        queued.append(work); return true
    }
    mutating func next() -> GitCredentialWork? {
        guard active.count < activeLimit, !queued.isEmpty else { return nil }
        let index = queued.firstIndex(where: { $0.session != lastSession }) ?? 0
        let work = queued.remove(at: index); lastSession = work.session; active.insert(work); return work
    }
    mutating func complete(_ work: GitCredentialWork) { active.remove(work) }
    // A canceled worker retains its capacity slot until its child really exits;
    // fencing a session must not create unbounded replacement provider jobs.
    mutating func cancel(session: String) { queued.removeAll { $0.session == session } }
}
