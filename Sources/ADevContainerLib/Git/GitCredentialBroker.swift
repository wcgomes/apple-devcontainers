import Foundation

protocol GitCredentialBrokerChannel: AnyObject, Sendable {
    func send(_ frame: GitCredentialFrame) throws
    func cancel()
}

struct GitCredentialBrokerPorts: Sendable {
    var context: @Sendable (String) throws -> GitCredentialRuntimeContext
    var connect: @Sendable (GitCredentialRegistration, UInt64, @escaping @Sendable (GitCredentialFrame) -> Void, @escaping @Sendable () -> Void) throws -> any GitCredentialBrokerChannel
    var acquire: @Sendable (String, String?, TimeInterval) throws -> GitHTTPSCredentials?
    var observe: (@Sendable (String, TimeInterval) -> GitCredentialObservation)? = nil
}

enum GitCredentialObservation: Equatable, Sendable {
    case running(GitCredentialRuntimeContext), inactive, unknown
}

/// Serial state, fair bounded workers, and no persisted credential material.
final class GitCredentialBroker: @unchecked Sendable {
    static let idleGrace: TimeInterval = 5
    static let recheckInterval: TimeInterval = 2
    /// Overall bound for cancelling every channel on shutdown. Channels are
    /// cancelled concurrently so one slow adapter cannot serialize the exit.
    static let shutdownBound: TimeInterval = 1.5
    // All mutable domain state is accessed under lock. Runtime/provider work and
    // channel callbacks happen outside it, so one hung adapter cannot own state.
    private let lock = NSLock()
    private let registry: GitCredentialBrokerRegistry
    private let ports: GitCredentialBrokerPorts
    private let clock: @Sendable () -> TimeInterval
    private var policy = GitCredentialBrokerPolicy()
    private var admission = GitCredentialAdmission()
    private struct Session {
        var registration: GitCredentialRegistration
        var generation: UInt64
        var channel: (any GitCredentialBrokerChannel)?
        var token: String?
        var retryAt: TimeInterval = 0
        var failures = 0
        var validated = true
        var revision: UInt64 = 0
    }
    private struct Pending { let query: GitCredentialQuery; let deadline: TimeInterval }
    private var sessions: [String: Session] = [:]
    private var pending: [GitCredentialWork: Pending] = [:]
    private var stopped = false
    private var idleSince: TimeInterval?
    private var generationCounter = UInt64.random(in: 1..<UInt64.max)
    init(registry: GitCredentialBrokerRegistry, ports: GitCredentialBrokerPorts, clock: @escaping @Sendable () -> TimeInterval = { ProcessInfo.processInfo.systemUptime }) throws {
        self.registry = registry; self.ports = ports; self.clock = clock
        policy = GitCredentialBrokerPolicy(clock: clock)
        for registration in try registry.load() {
            sessions[registration.context.id] = .init(registration: registration, generation: 0, validated: false)
        }
        if sessions.isEmpty { idleSince = clock() }
    }
    deinit { shutdown() }
    private func saveLocked() throws { try registry.save(sessions.values.map(\.registration)) }
    private func nextGenerationLocked() throws -> UInt64 {
        guard generationCounter < UInt64.max else { throw GitCredentialFailure.overloaded }
        let generation = generationCounter; generationCounter += 1; return generation
    }
    func register(_ registration: GitCredentialRegistration, override: String? = nil, reset: Bool = false) throws {
        guard try ports.context(registration.context.id) == registration.context,
              override == nil || (!override!.isEmpty && GitCredentialProtocol.safe(override!) && override!.utf8.count <= 60000) else { throw GitCredentialFailure.invalidContext }
        let id = registration.context.id
        lock.lock()
        guard !stopped else { lock.unlock(); throw GitCredentialFailure.transport }
        idleSince = nil
        let previous = sessions[id]
        let sameIdentity = previous?.registration.context == registration.context
        let token = override ?? (sameIdentity ? previous?.token : nil)
        var registration = registration
        registration.overrideRequired = registration.overrideRequired || (sameIdentity && previous?.registration.overrideRequired == true) || override != nil
        guard !registration.overrideRequired || token != nil else { lock.unlock(); throw GitCredentialFailure.invalidContext }
        if let previous, previous.registration == registration, previous.channel != nil, previous.token == token {
            do { sessions[id]!.revision = try nextGenerationLocked() } catch { lock.unlock(); throw error }
            sessions[id]!.validated = true
            if reset { policy.reset(id) }; lock.unlock(); return
        }
        let generation: UInt64
        do { generation = try nextGenerationLocked() } catch { lock.unlock(); throw error }
        policy.unregister(id); admission.cancel(session: id); pending = pending.filter { $0.key.session != id }
        sessions[id] = .init(registration: registration, generation: generation, token: token, revision: generation)
        do { try saveLocked() } catch { sessions.removeValue(forKey: id); lock.unlock(); previous?.channel?.cancel(); throw error }
        lock.unlock(); previous?.channel?.cancel()
        try connect(id: id, generation: generation)
    }
    func unregister(_ id: String) throws {
        try unregister(id, revision: nil)
    }
    private func unregister(_ id: String, revision: UInt64?) throws {
        lock.lock()
        if let revision, sessions[id]?.revision != revision { lock.unlock(); return }
        let channel = sessions.removeValue(forKey: id)?.channel
        policy.unregister(id); admission.cancel(session: id); pending = pending.filter { $0.key.session != id }
        updateIdleLocked()
        do { try saveLocked() } catch { lock.unlock(); channel?.cancel(); throw error }
        lock.unlock(); channel?.cancel(); schedule()
    }
    private func updateIdleLocked() {
        if sessions.isEmpty && pending.isEmpty {
            if idleSince == nil { idleSince = clock() }
        } else { idleSince = nil }
    }
    /// Admission and retirement share this lock. A register losing the boundary
    /// gets transport failure and must activate a successor, never a false ack.
    func retireIfIdle() -> Bool {
        lock.lock(); defer { lock.unlock() }
        updateIdleLocked()
        guard !stopped, let idleSince, clock() - idleSince >= Self.idleGrace else { return false }
        stopped = true
        return true
    }
    private func connect(id: String, generation: UInt64) throws {
        lock.lock(); let snapshot = sessions[id]; lock.unlock()
        guard let snapshot, snapshot.generation == generation, !snapshot.registration.overrideRequired || snapshot.token != nil else { throw GitCredentialFailure.invalidContext }
        do {
            guard try ports.context(id) == snapshot.registration.context else { throw GitCredentialFailure.invalidContext }
            let channel = try ports.connect(snapshot.registration, generation, { [weak self] frame in
                // Identity belongs to this host-established channel, never to a
                // generation asserted in a payload from an obsolete peer.
                guard frame.generation == generation else { return }
                self?.receive(id: id, frame: frame)
            }, { [weak self] in self?.disconnected(id: id, generation: generation) })
            lock.lock()
            guard !stopped, sessions[id]?.generation == generation else { lock.unlock(); channel.cancel(); throw GitCredentialFailure.transport }
            sessions[id]!.channel = channel; sessions[id]!.failures = 0
            policy.register(id, generation: generation, destinations: snapshot.registration.destinations)
            lock.unlock()
        } catch { disconnected(id: id, generation: generation); throw GitCredentialFailure.transport }
    }
    private func disconnected(id: String, generation: UInt64) {
        lock.lock()
        guard sessions[id]?.generation == generation else { lock.unlock(); return }
        let channel = sessions[id]!.channel; sessions[id]!.channel = nil
        sessions[id]!.failures = min(5, sessions[id]!.failures + 1)
        sessions[id]!.retryAt = clock() + min(30, pow(2, Double(sessions[id]!.failures - 1)))
        // Fence first, before any asynchronous late completion can run.
        policy.unregister(id); admission.cancel(session: id); pending = pending.filter { $0.key.session != id }
        lock.unlock(); channel?.cancel(); schedule()
    }
    private func receive(id: String, frame: GitCredentialFrame) {
        lock.lock()
        guard !stopped, let session = sessions[id], session.channel != nil, session.validated else {
            let reason = stopped ? "stopped" : (sessions[id] == nil ? "no_session" : "no_channel")
            GitCredentialDiag.event("broker.drop", "reason=\(reason) req=\(frame.request)")
            lock.unlock(); return
        }
        guard policy.begin(id, generation: frame.generation, request: frame.request), let query = try? GitCredentialQuery(frame: frame) else {
            GitCredentialDiag.event("broker.drop", "reason=begin_or_query req=\(frame.request) keys=\(frame.fields.count)")
            lock.unlock(); return
        }
        let channel = session.channel!
        if frame.operation == .erase {
            policy.erase(id, generation: frame.generation, query: query); lock.unlock()
            try? channel.send(.init(operation: .reply, request: frame.request, generation: frame.generation, fields: [:])); return
        }
        let work = GitCredentialWork(session: id, generation: frame.generation, request: frame.request)
        guard policy.authorize(id, generation: frame.generation, query: query) != nil, admission.enqueue(work) else {
            GitCredentialDiag.event("broker.miss", "req=\(frame.request) path_len=\(query.path.utf8.count)")
            lock.unlock(); try? channel.send(.init(operation: .reply, request: frame.request, generation: frame.generation, fields: [:])); return
        }
        GitCredentialDiag.event("broker.accept", "req=\(frame.request) path_len=\(query.path.utf8.count)")
        pending[work] = .init(query: query, deadline: clock() + 15); lock.unlock(); schedule()
    }
    private func schedule() {
        lock.lock()
        var jobs: [(GitCredentialWork, Pending, String, String?)] = []
        while !stopped, let work = admission.next() {
            guard let request = pending[work], let session = sessions[work.session], session.generation == work.generation,
                  let url = policy.authorize(work.session, generation: work.generation, query: request.query) else { admission.complete(work); pending.removeValue(forKey: work); continue }
            jobs.append((work, request, url, session.token))
        }
        lock.unlock()
        for (work, request, url, token) in jobs {
            DispatchQueue.global(qos: .userInitiated).async { [weak self] in
                guard let self else { return }
                let started = clock()
                let credential = clock() < request.deadline ? (try? ports.acquire(url, token, request.deadline)) : nil
                let elapsed = Int((clock() - started) * 1000)
                GitCredentialDiag.event("broker.acquire", "req=\(work.request) ms=\(elapsed) result=\(credential == nil ? "absent" : "present")")
                complete(work, request: request, credential: credential)
            }
        }
    }
    private func complete(_ work: GitCredentialWork, request: Pending, credential: GitHTTPSCredentials?) {
        lock.lock(); admission.complete(work); pending.removeValue(forKey: work)
        guard !stopped, policy.current(work.session, generation: work.generation), let channel = sessions[work.session]?.channel else { lock.unlock(); schedule(); return }
        let result = sessions[work.session]?.validated == true && clock() < request.deadline ? credential.flatMap { policy.deliver(work.session, generation: work.generation, query: request.query, credential: $0) } : nil
        let fields: [GitCredentialField: String] = result.map { [.username: $0.username, .password: $0.password] } ?? [:]
        GitCredentialDiag.event("broker.reply", "req=\(work.request) delivered=\(result == nil ? "no" : "yes")")
        lock.unlock()
        do { try channel.send(.init(operation: .reply, request: work.request, generation: work.generation, fields: fields)) }
        catch { disconnected(id: work.session, generation: work.generation) }
        schedule()
    }
    func reconcile() {
        lock.lock(); let snapshots = sessions; let stopped = self.stopped; lock.unlock()
        guard !stopped else { return }
        // Share a bounded observation budget across registrations. An outage is
        // unknown, not a destructive inference from a failed inspect command.
        let deadline = clock() + 1
        for (id, snapshot) in snapshots {
            let observation = ports.observe?(id, deadline) ?? ((try? ports.context(id)).map(GitCredentialObservation.running) ?? .unknown)
            if observation == .inactive {
                try? unregister(id, revision: snapshot.revision); continue
            }
            guard case .running(let actual) = observation else {
                lock.lock()
                if sessions[id]?.revision == snapshot.revision { sessions[id]!.validated = false }
                lock.unlock(); continue
            }
            guard actual == snapshot.registration.context else { try? unregister(id, revision: snapshot.revision); continue }
            lock.lock()
            if sessions[id]?.revision == snapshot.revision { sessions[id]!.validated = true }
            lock.unlock()
            guard snapshot.channel == nil, clock() >= snapshot.retryAt, !snapshot.registration.overrideRequired || snapshot.token != nil else { continue }
            lock.lock()
            guard sessions[id]?.revision == snapshot.revision, sessions[id]?.generation == snapshot.generation, sessions[id]?.channel == nil else { lock.unlock(); continue }
            guard let generation = try? nextGenerationLocked() else { lock.unlock(); continue }
            sessions[id]!.generation = generation; sessions[id]!.revision = generation; lock.unlock()
            try? connect(id: id, generation: generation)
        }
    }
    func validate(id: String, sources: [String]) throws -> Bool {
        guard sources.count <= 64 else { throw GitCredentialFailure.overloaded }
        lock.lock(); let session = sessions[id]; policy.reset(id); lock.unlock()
        guard let session, session.channel != nil, session.validated else { throw GitCredentialFailure.invalidContext }
        let deadline = clock() + 30
        var acquired = false
        for source in sources {
            guard let fields = GitURLClassifier.httpsCredentialFields(for: source) else { continue }
            let query = GitCredentialQuery(scheme: fields.protocolName, host: fields.host, path: fields.path)
            lock.lock(); let url = policy.authorize(id, generation: session.generation, query: query); lock.unlock()
            guard let url, clock() < deadline else { throw GitCredentialFailure.invalidContext }
            guard let credential = try ports.acquire(url, session.token, min(deadline, clock() + 15)),
                  !credential.username.isEmpty, !credential.password.isEmpty else { return false }
            acquired = true
        }
        return acquired
    }
    func shutdown() {
        lock.lock(); stopped = true; let channels = sessions.values.compactMap(\.channel)
        for id in sessions.keys { policy.unregister(id); admission.cancel(session: id) }
        sessions.removeAll(); pending.removeAll(); lock.unlock()
        guard !channels.isEmpty else { return }
        let group = DispatchGroup()
        for channel in channels {
            group.enter()
            DispatchQueue.global(qos: .utility).async { channel.cancel(); group.leave() }
        }
        _ = group.wait(timeout: .now() + Self.shutdownBound)
    }
}
