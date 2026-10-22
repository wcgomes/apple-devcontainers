import Foundation
import Darwin
@testable import ADevContainerLib

func credentialTestBase() throws -> URL {
    let approved = FileManager.default.temporaryDirectory.appendingPathComponent("opencode").path
    if !FileManager.default.fileExists(atPath: approved) {
        try FileManager.default.createDirectory(atPath: approved, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
    }
    guard let physical = realpath(approved, nil) else { throw MiniTest.Failure(message: "approved physical temporary root is unavailable") }
    defer { free(physical) }
    return URL(fileURLWithPath: String(cString: physical))
}
func credentialTestRoot() throws -> URL {
    try credentialTestBase().appendingPathComponent("credential-registry-\(UUID().uuidString)")
}
func credentialShortRoot() throws -> URL {
    var template = Array((try credentialTestBase().path + "/s.XXXXXX").utf8CString)
    guard let path = mkdtemp(&template) else { throw MiniTest.Failure(message: "private test root unavailable") }
    return URL(fileURLWithPath: String(cString: path))
}
final class CredentialServiceTestLifetime: @unchecked Sendable {
    private let condition = NSCondition()
    private var stopped = false
    private var finished = false
    private var successful = false
    func stop() { condition.lock(); stopped = true; condition.unlock() }
    func shouldStop() -> Bool { condition.lock(); defer { condition.unlock() }; return stopped }
    func finish(_ successful: Bool) { condition.lock(); finished = true; self.successful = successful; condition.broadcast(); condition.unlock() }
    func awaitFinish(within: TimeInterval = 3) -> Bool {
        condition.lock(); defer { condition.unlock() }; let deadline = Date().addingTimeInterval(within)
        while !finished { if !condition.wait(until: deadline) { break } }; return finished && successful
    }
}

/// A channel whose cancel never returns promptly. Broker shutdown must not
/// let one adapter serialize the process exit.
final class CredentialSlowCancelChannel: GitCredentialBrokerChannel, @unchecked Sendable {
    private let lock = NSLock()
    private let delay: TimeInterval
    private var cancellations = 0
    init(delay: TimeInterval = 3) { self.delay = delay }
    func send(_ frame: GitCredentialFrame) throws {}
    func cancel() { lock.lock(); cancellations += 1; lock.unlock(); Thread.sleep(forTimeInterval: delay) }
    var cancelCount: Int { lock.lock(); defer { lock.unlock() }; return cancellations }
}

final class CredentialTestChannel: GitCredentialBrokerChannel, @unchecked Sendable {
    private let condition = NSCondition()
    private var frames: [GitCredentialFrame] = []
    private var cancelled = false
    func send(_ frame: GitCredentialFrame) throws { condition.lock(); defer { condition.unlock() }; frames.append(frame); condition.broadcast() }
    func cancel() { condition.lock(); cancelled = true; condition.broadcast(); condition.unlock() }
    func take() throws -> GitCredentialFrame {
        condition.lock(); defer { condition.unlock() }; let end = Date().addingTimeInterval(3)
        while frames.isEmpty && !cancelled { if !condition.wait(until: end) { break } }
        guard !frames.isEmpty else { throw MiniTest.Failure(message: "synthetic broker reply timed out") }; return frames.removeFirst()
    }
}

final class CredentialTestBrokerPorts: @unchecked Sendable {
    private let lock = NSLock()
    let context: GitCredentialRuntimeContext
    private var receive: (@Sendable (GitCredentialFrame) -> Void)?
    private var generation: UInt64 = 0
    private var channel = CredentialTestChannel()
    private var providerCalls: [String] = []
    private var passwords: [String] = []
    private var disconnect: (@Sendable () -> Void)?
    private var connects = 0
    private var contextInvalid = false
    private var contextUnavailable = false
    private var miss = false
    private var reported: GitCredentialRuntimeContext
    var beforeObserve: (@Sendable () -> Void)?
    var beforeAcquire: (@Sendable () -> Void)?
    var beforeContext: (@Sendable () -> Void)?
    init(id: String = "synthetic") {
        context = .init(id: id, incarnation: "reference:800000000", platform: "linux/arm64", user: "root", labels: ["devcontainer.managed": "adevcontainer"])
        reported = context
    }
    func replaceContext(_ context: GitCredentialRuntimeContext) { lock.lock(); reported = context; lock.unlock() }
    var ports: GitCredentialBrokerPorts { .init(context: { [self] _ in
        beforeContext?()
        lock.lock(); defer { lock.unlock() }; if contextUnavailable { throw GitCredentialFailure.transport }; if contextInvalid { throw GitCredentialFailure.invalidContext }; return reported
    }, connect: { [self] _, generation, receive, disconnected in
        lock.lock(); defer { lock.unlock() }; self.generation = generation; self.receive = receive; disconnect = disconnected; connects += 1; channel = CredentialTestChannel(); return channel
    }, acquire: { [self] url, override, _ in
        beforeAcquire?()
        lock.lock(); defer { lock.unlock() }; providerCalls.append(url); if miss { return nil }
        let password = passwords.isEmpty ? (override ?? "synthetic") : passwords.removeFirst()
        return .init(username: "host-account", password: password)
    }, observe: { [self] _, _ in
        lock.lock(); let invalid = contextInvalid, unavailable = contextUnavailable, context = reported; lock.unlock()
        beforeObserve?()
        if unavailable { return .unknown }; return invalid ? .inactive : .running(context)
    }) }
    func failAcquisition() { lock.lock(); miss = true; lock.unlock() }
    func enqueuePasswords(_ values: [String]) { lock.lock(); passwords = values; lock.unlock() }
    func request(_ id: UInt64, host: String = "example.invalid", generation: UInt64? = nil) throws -> GitCredentialFrame {
        lock.lock(); let receive = self.receive, current = self.generation, channel = self.channel; lock.unlock()
        receive?(.init(operation: .get, request: id, generation: generation ?? current, fields: [.scheme: "https", .host: host, .path: "sibling/repo", .username: "guest"]))
        return try channel.take()
    }
    var calls: [String] { lock.lock(); defer { lock.unlock() }; return providerCalls }
    var receiver: (@Sendable (GitCredentialFrame) -> Void)? { lock.lock(); defer { lock.unlock() }; return receive }
    var connectionCount: Int { lock.lock(); defer { lock.unlock() }; return connects }
    func failChannel() { lock.lock(); let callback = disconnect; lock.unlock(); callback?() }
    func invalidateContext() { lock.lock(); contextInvalid = true; lock.unlock() }
    func unavailableContext() { lock.lock(); contextUnavailable = true; lock.unlock() }
    func restoreContext(_ context: GitCredentialRuntimeContext) { lock.lock(); reported = context; contextUnavailable = false; contextInvalid = false; lock.unlock() }
    var currentGeneration: UInt64 { lock.lock(); defer { lock.unlock() }; return generation }
    func takeReply() throws -> GitCredentialFrame { lock.lock(); let channel = channel; lock.unlock(); return try channel.take() }
}

final class CredentialTestClock: @unchecked Sendable {
    private let lock = NSLock()
    private var value: TimeInterval = 0
    func now() -> TimeInterval { lock.lock(); defer { lock.unlock() }; return value }
    func advance(_ interval: TimeInterval) { lock.lock(); value += interval; lock.unlock() }
}

func credentialIdentity(_ executable: String) throws -> ExecutableIdentity {
    let identity = try ExecutableIdentity.read(executable)
    return .init(executable: identity.executable, device: identity.device, inode: identity.inode,
                 build: identity.build, protocolVersion: identity.protocolVersion, process: 999)
}

final class CredentialDetachedLauncher: DetachedProcessLaunching, @unchecked Sendable {
    struct Launch { let executable: String; let arguments: [String]; let environment: [String: String] }
    private let lock = NSLock()
    private var stored: [Launch] = []
    var failure: GitCredentialFailure?
    var afterLaunch: (@Sendable () -> Void)?
    var launches: [Launch] { lock.lock(); defer { lock.unlock() }; return stored }
    func launch(executable: String, arguments: [String], environment: [String: String]) throws -> Int32 {
        if let failure { throw failure }
        lock.lock(); stored.append(.init(executable: executable, arguments: arguments, environment: environment)); lock.unlock()
        afterLaunch?(); return 4242
    }
    func reap(_ process: Int32) {}
}

/// Same-user, owner-private listener that accepts a connection and never
/// answers. It models an endpoint that speaks no control protocol but is still
/// alive: activation must fail closed without unlinking or replacing it.
final class CredentialMuteListener: @unchecked Sendable {
    private let listener: Int32
    private let release = DispatchSemaphore(value: 0)
    private let accepted = DispatchSemaphore(value: 0)
    init(path: String) throws {
        let fd = socket(AF_UNIX, SOCK_STREAM, 0)
        guard fd >= 0 else { throw MiniTest.Failure(message: "mute listener socket failed") }
        var address = try GitCredentialControlSocket.address(path)
        guard GitCredentialControlSocket.bindPrivate(fd, address: &address) == 0,
              chmod(path, 0o600) == 0, listen(fd, 4) == 0 else {
            close(fd); throw MiniTest.Failure(message: "mute listener bind failed")
        }
        listener = fd
        DispatchQueue.global().async { [self] in
            defer { close(listener) }
            var pending = pollfd(fd: listener, events: Int16(POLLIN), revents: 0)
            guard poll(&pending, 1, 5000) > 0, pending.revents & Int16(POLLIN) != 0 else { return }
            let peer = accept(listener, nil, nil)
            accepted.signal()
            if peer >= 0 { _ = release.wait(timeout: .now() + 10); close(peer) }
        }
    }
    func acceptOne() -> Bool { accepted.wait(timeout: .now() + 3) == .success }
    func stop() { release.signal() }
}

/// Probe that consumes more than the caller's deadline and still reports
/// absence. It models a connect phase that outlives activation: ensure must
/// recheck the deadline before writing a context or spawning a successor.
final class CredentialDelayedAbsentProbe: GitCredentialBrokerProbing, @unchecked Sendable {
    func probe(_ context: GitCredentialLaunchContext, deadline: TimeInterval) throws -> GitCredentialBrokerStatus {
        Thread.sleep(forTimeInterval: 0.4)
        return .absent
    }
    func retire(_ context: GitCredentialLaunchContext, deadline: TimeInterval) throws {}
    func exchange(_ request: GitCredentialControlRequest, context: GitCredentialLaunchContext, deadline: TimeInterval) throws -> GitCredentialControlReply {
        .init(succeeded: true, acquired: false)
    }
}

final class CredentialProbeFake: GitCredentialBrokerProbing, @unchecked Sendable {
    private let lock = NSLock()
    private var status: GitCredentialBrokerStatus
    private var retirements = 0
    private var exchanges = 0
    var onRetire: (@Sendable () -> Void)?
    init(_ status: GitCredentialBrokerStatus) { self.status = status }
    var retireCount: Int { lock.lock(); defer { lock.unlock() }; return retirements }
    var exchangeCount: Int { lock.lock(); defer { lock.unlock() }; return exchanges }
    func set(_ value: GitCredentialBrokerStatus) { lock.lock(); status = value; lock.unlock() }
    func probe(_ context: GitCredentialLaunchContext, deadline: TimeInterval) throws -> GitCredentialBrokerStatus {
        lock.lock(); defer { lock.unlock() }; return status
    }
    func retire(_ context: GitCredentialLaunchContext, deadline: TimeInterval) throws {
        lock.lock(); retirements += 1; lock.unlock(); onRetire?()
    }
    func exchange(_ request: GitCredentialControlRequest, context: GitCredentialLaunchContext, deadline: TimeInterval) throws -> GitCredentialControlReply {
        lock.lock(); exchanges += 1; lock.unlock()
        return .init(succeeded: true, acquired: false)
    }
}

func credentialServiceContext(_ root: URL) -> GitCredentialLaunchContext {
    .init(label: "com.adevcontainer.git-credentials.test.\(UUID().uuidString)", state: root.path + "/state", endpoints: root.path,
          executable: "/usr/bin/true", providerEnvironment: ["PATH": "/usr/bin:/bin:/usr/sbin:/sbin", "HOME": root.path + "/state",
          "GIT_CONFIG_GLOBAL": root.path + "/state/synthetic.gitconfig", "GIT_CONFIG_SYSTEM": "/dev/null", "GIT_CONFIG_NOSYSTEM": "1"])
}

@MainActor let gitCredentialBrokerServiceTests: [(String, () throws -> Void)] = [
    ("credentials.service.spawnsOneDetachedBroker", {
        let root = try credentialShortRoot(); defer { try? FileManager.default.removeItem(at: root) }
        let context = credentialServiceContext(root), identity = try credentialIdentity(context.executable)
        let probe = CredentialProbeFake(.absent), launcher = CredentialDetachedLauncher()
        launcher.afterLaunch = { probe.set(.owner(identity)) }
        let service = GitCredentialBrokerService(context: context, launcher: launcher, control: probe)
        try service.ensure()
        try MiniTest.expectEqual(launcher.launches.count, 1)
        guard let launch = launcher.launches.first else { throw MiniTest.Failure(message: "no detached launch recorded") }
        try MiniTest.expectEqual(launch.executable, context.executable)
        try MiniTest.expectEqual(launch.arguments, ["__adevcontainer_git_broker", context.state + "/launch-context.json"])
        try MiniTest.expect(launch.environment["ADEVCONTAINER_GIT_TOKEN"] == nil)
        try MiniTest.expectEqual(launch.environment["PATH"], "/usr/bin:/bin:/usr/sbin:/sbin")
        let state = try GitCredentialPrivateFiles.directory(context.state, create: false); defer { close(state) }
        guard let bytes = try GitCredentialPrivateFiles.read("launch-context.json", directory: state) else { throw MiniTest.Failure(message: "isolated context was not written") }
        try MiniTest.expectEqual(try JSONDecoder().decode(GitCredentialLaunchContext.self, from: bytes), context)
        // Concurrent activations serialize on the activation lock and converge on one spawn.
        let group = DispatchGroup(), concurrent = CredentialDetachedLauncher()
        concurrent.afterLaunch = { probe.set(.owner(identity)) }
        let shared = GitCredentialBrokerService(context: context, launcher: concurrent, control: probe)
        for _ in 0..<8 {
            group.enter(); DispatchQueue.global().async { defer { group.leave() }; _ = try? shared.ensure() }
        }
        try MiniTest.expect(group.wait(timeout: .now() + 10) == .success)
        try MiniTest.expectEqual(concurrent.launches.count, 0, "a healthy matching owner is reused without spawning")
    }),
    ("credentials.service.reusesMatchingIdentity", {
        let root = try credentialShortRoot(); defer { try? FileManager.default.removeItem(at: root) }
        let context = credentialServiceContext(root), identity = try credentialIdentity(context.executable)
        let probe = CredentialProbeFake(.owner(identity)), launcher = CredentialDetachedLauncher()
        let service = GitCredentialBrokerService(context: context, launcher: launcher, control: probe)
        for _ in 0..<3 { try service.ensure() }
        let group = DispatchGroup()
        for _ in 0..<8 {
            group.enter(); DispatchQueue.global().async { defer { group.leave() }; _ = try? service.ensure() }
        }
        try MiniTest.expect(group.wait(timeout: .now() + 10) == .success)
        try MiniTest.expectEqual(launcher.launches.count, 0, "reuse must not restart or reload")
        try MiniTest.expectEqual(probe.retireCount, 0)
        try MiniTest.expectEqual(probe.exchangeCount, 0, "reuse must not register or look up a provider")
    }),
    ("credentials.service.mismatchedIdentityRetiresOnce", {
        let root = try credentialShortRoot(); defer { try? FileManager.default.removeItem(at: root) }
        let context = credentialServiceContext(root), identity = try credentialIdentity(context.executable)
        let old = try credentialIdentity("/usr/bin/false")
        let probe = CredentialProbeFake(.owner(old)), launcher = CredentialDetachedLauncher()
        probe.onRetire = { probe.set(.absent) }
        launcher.afterLaunch = { probe.set(.owner(identity)) }
        try GitCredentialBrokerService(context: context, launcher: launcher, control: probe).ensure()
        try MiniTest.expectEqual(probe.retireCount, 1)
        try MiniTest.expectEqual(launcher.launches.count, 1)
        // A healthy successor from the same executable is never retired again.
        probe.set(.owner(identity))
        try GitCredentialBrokerService(context: context, launcher: launcher, control: probe).ensure()
        try MiniTest.expectEqual(probe.retireCount, 1); try MiniTest.expectEqual(launcher.launches.count, 1)
        // A second different executable in the readiness window is retired exactly once.
        let replacement = CredentialProbeFake(.owner(old)), relauncher = CredentialDetachedLauncher()
        relauncher.afterLaunch = { replacement.set(.owner(old)) }
        try MiniTest.expectThrows({
            try GitCredentialBrokerService(context: context, launcher: relauncher, control: replacement).ensure(deadline: ProcessInfo.processInfo.systemUptime + 1.5)
        }, validate: { try MiniTest.expectEqual($0 as? GitCredentialFailure, .deadline) })
        try MiniTest.expectEqual(replacement.retireCount, 1)
    }),
    ("credentials.service.unregisterWithoutBrokerDoesNotSpawn", {
        let root = try credentialShortRoot(); defer { try? FileManager.default.removeItem(at: root) }
        let context = credentialServiceContext(root)
        let probe = CredentialProbeFake(.absent), launcher = CredentialDetachedLauncher()
        let service = GitCredentialBrokerService(context: context, launcher: launcher, control: probe)
        let accepted = try service.request(.init(operation: .unregister, id: "gone"), activate: false)
        try MiniTest.expect(!accepted)
        try MiniTest.expectEqual(probe.retireCount, 0)
        try MiniTest.expectEqual(launcher.launches.count, 0, "teardown must never start a broker")
        try MiniTest.expect(!FileManager.default.fileExists(atPath: context.socket))
        try MiniTest.expect(!FileManager.default.fileExists(atPath: context.state))
    }),
    ("credentials.service.spawnFailureIsSoft", {
        let root = try credentialShortRoot(); defer { try? FileManager.default.removeItem(at: root) }
        let context = credentialServiceContext(root)
        let probe = CredentialProbeFake(.absent), launcher = CredentialDetachedLauncher()
        launcher.failure = .transport
        let service = GitCredentialBrokerService(context: context, launcher: launcher, control: probe)
        try MiniTest.expectThrows({ try service.ensure() }, validate: { try MiniTest.expectEqual($0 as? GitCredentialFailure, .transport) })
        try MiniTest.expectEqual(launcher.launches.count, 0)
        launcher.failure = nil
        try MiniTest.expectThrows({
            try GitCredentialBrokerService(context: context, launcher: launcher, control: probe).ensure(deadline: ProcessInfo.processInfo.systemUptime + 0.5)
        }, validate: { try MiniTest.expectEqual($0 as? GitCredentialFailure, .deadline) })
        try MiniTest.expectEqual(launcher.launches.count, 1)
    }),
    ("credentials.service.unrecognizedEndpointFailsClosed", {
        let root = try credentialShortRoot(); defer { try? FileManager.default.removeItem(at: root) }
        let context = credentialServiceContext(root)
        let probe = CredentialProbeFake(.unrecognized), launcher = CredentialDetachedLauncher()
        try MiniTest.expectThrows({
            try GitCredentialBrokerService(context: context, launcher: launcher, control: probe).ensure()
        }, validate: { try MiniTest.expectEqual($0 as? GitCredentialFailure, .invalidContext) })
        try MiniTest.expectEqual(launcher.launches.count, 0, "an unauthenticatable endpoint is never replaced")
        try MiniTest.expectEqual(probe.retireCount, 0, "an unauthenticatable endpoint is never killed")
        // Retirement that never completes is a bounded failure, not a second owner.
        let owner = CredentialProbeFake(.owner(try credentialIdentity("/usr/bin/false"))), stuck = CredentialDetachedLauncher()
        let started = ProcessInfo.processInfo.systemUptime
        try MiniTest.expectThrows({
            try GitCredentialBrokerService(context: context, launcher: stuck, control: owner).ensure(deadline: started + 1.5)
        }, validate: { try MiniTest.expectEqual($0 as? GitCredentialFailure, .deadline) })
        try MiniTest.expect(ProcessInfo.processInfo.systemUptime - started < 3, "replacement must stay inside the activation deadline")
        try MiniTest.expectEqual(stuck.launches.count, 0)
    }),
    ("credentials.service.silentListenerFailsClosedWithoutReplacingEndpoint", {
        let root = try credentialShortRoot(); defer { try? FileManager.default.removeItem(at: root) }
        let context = credentialServiceContext(root)
        let listener = try CredentialMuteListener(path: context.socket); defer { listener.stop() }
        var before = stat(); try MiniTest.expectEqual(lstat(context.socket, &before), 0)
        let launcher = CredentialDetachedLauncher()
        let started = ProcessInfo.processInfo.systemUptime
        try MiniTest.expectThrows({
            try GitCredentialBrokerService(context: context, launcher: launcher).ensure()
        }, validate: { try MiniTest.expectEqual($0 as? GitCredentialFailure, .invalidContext) })
        let elapsed = ProcessInfo.processInfo.systemUptime - started
        // Connected but silent is an unrecognized endpoint, not absence: the
        // probe must not consume the 30-second activation deadline.
        try MiniTest.expect(elapsed < 5, "a silent listener must fail closed inside the probe bound, took \(elapsed)s")
        try MiniTest.expect(listener.acceptOne(), "the mute listener never accepted the probe")
        try MiniTest.expectEqual(launcher.launches.count, 0, "a silent endpoint must not spawn a competing owner")
        var after = stat(); try MiniTest.expectEqual(lstat(context.socket, &after), 0)
        print("silent listener fail-closed: \(String(format: "%.3f", elapsed))s")
        try MiniTest.expectEqual(after.st_ino, before.st_ino, "a silent endpoint's inode is never replaced")
        try MiniTest.expectEqual(after.st_dev, before.st_dev, "a silent endpoint is never replaced")
    }),
    ("credentials.service.deadlineExpiryBeforeSpawnPreventsSideEffects", {
        let root = try credentialShortRoot(); defer { try? FileManager.default.removeItem(at: root) }
        let context = credentialServiceContext(root), launcher = CredentialDetachedLauncher()
        let started = ProcessInfo.processInfo.systemUptime
        try MiniTest.expectThrows({
            try GitCredentialBrokerService(context: context, launcher: launcher, control: CredentialDelayedAbsentProbe()).ensure(deadline: started + 0.2)
        }, validate: { try MiniTest.expectEqual($0 as? GitCredentialFailure, .deadline) })
        try MiniTest.expectEqual(launcher.launches.count, 0, "an expired activation must not spawn")
        try MiniTest.expect(!FileManager.default.fileExists(atPath: context.state), "an expired activation must not write a launch context")
    }),
    ("credentials.identity.deviceInodeBuildAndNonMachOFallback", {
        let root = try credentialShortRoot(); defer { try? FileManager.default.removeItem(at: root) }
        let machO = try ExecutableIdentity.read("/usr/bin/true")
        try MiniTest.expect(machO.build.count == 32 && machO.build.allSatisfy(\.isHexDigit), "a Mach-O binary must expose its build UUID")
        try MiniTest.expect(machO.device > 0 && machO.inode > 0)
        try MiniTest.expect(machO.matches(try ExecutableIdentity.read("/usr/bin/true")))
        // A non-Mach-O wrapper carries no build identity; device/inode decides.
        let script = root.appendingPathComponent("wrapper").path
        try Data("#!/bin/sh\nexit 0\n".utf8).write(to: URL(fileURLWithPath: script))
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: script)
        let wrapper = try ExecutableIdentity.read(script)
        try MiniTest.expectEqual(wrapper.build, "")
        try MiniTest.expect(wrapper.matches(try ExecutableIdentity.read(script)))
        // Equal bytes in a different file are a replacement, not a match.
        let copy = root.appendingPathComponent("wrapper-copy").path
        try FileManager.default.copyItem(atPath: script, toPath: copy)
        try MiniTest.expect(!wrapper.matches(try ExecutableIdentity.read(copy)))
        try MiniTest.expect(!machO.matches(wrapper), "device/inode equality is required")
        try MiniTest.expectThrows({ _ = try ExecutableIdentity.read(root.appendingPathComponent("missing").path) }, validate: { _ in })
        try MiniTest.expectThrows({ _ = try ExecutableIdentity.read("relative/path") }, validate: { _ in })
    }),
    ("credentials.service.activationLockIsSingleton", {
        let root = try credentialShortRoot(); defer { try? FileManager.default.removeItem(at: root) }
        let context = credentialServiceContext(root)
        var owner: GitCredentialServiceLock? = try GitCredentialServiceLock(directory: context.endpoints)
        try MiniTest.expect(owner != nil)
        try MiniTest.expectThrows({ _ = try GitCredentialServiceLock(directory: context.endpoints) }, validate: { _ in })
        owner = nil
        let replacement = try GitCredentialServiceLock(directory: context.endpoints); _ = replacement
    }),
    ("credentials.service.socketIsPrivateAtCreation", {
        let root = try credentialShortRoot(); defer { try? FileManager.default.removeItem(at: root) }
        let fd = socket(AF_UNIX, SOCK_STREAM, 0); try MiniTest.expect(fd >= 0); defer { close(fd) }
        var address = try GitCredentialControlSocket.address(root.path + "/creation.sock")
        try MiniTest.expectEqual(GitCredentialControlSocket.bindPrivate(fd, address: &address), 0)
        var attributes = stat(); try MiniTest.expectEqual(lstat(root.path + "/creation.sock", &attributes), 0)
        try MiniTest.expectEqual(attributes.st_mode & 0o077, 0, "socket must already be private before listen/chmod")
    }),
    ("credentials.broker.twoSessionsAndRecoveredOverrideAreDemand", {
        let root = try credentialTestRoot(); defer { try? FileManager.default.removeItem(at: root) }
        let first = CredentialTestBrokerPorts(id: "first"), second = CredentialTestBrokerPorts(id: "second"), clock = CredentialTestClock()
        let ports = GitCredentialBrokerPorts(context: { id in try (id == "first" ? first : second).ports.context(id) }, connect: { registration, generation, receive, disconnected in
            try (registration.context.id == "first" ? first : second).ports.connect(registration, generation, receive, disconnected)
        }, acquire: { _, _, _ in throw MiniTest.Failure(message: "idle must not acquire") }, observe: { id, end in (id == "first" ? first : second).ports.observe!(id, end) })
        let registry = GitCredentialBrokerRegistry(path: root.path)
        let broker = try GitCredentialBroker(registry: registry, ports: ports, clock: { clock.now() }); defer { broker.shutdown() }
        for port in [first, second] {
            try broker.register(.init(context: port.context, destinations: [try .init(url: "https://example.invalid/repo")], directory: "/private/credential", overrideRequired: true), override: "synthetic")
        }
        try broker.unregister("first"); clock.advance(20); try MiniTest.expect(!broker.retireIfIdle())
        broker.shutdown()
        let recovered = try GitCredentialBroker(registry: registry, ports: ports, clock: { clock.now() }); defer { recovered.shutdown() }
        recovered.reconcile(); clock.advance(20); try MiniTest.expect(!recovered.retireIfIdle())
        try MiniTest.expectEqual(try registry.load().count, 1)
        try recovered.unregister("second"); clock.advance(5); try MiniTest.expect(recovered.retireIfIdle())
    }),
    ("credentials.broker.registrationLosingRetirementCannotSucceed", {
        let root = try credentialTestRoot(); defer { try? FileManager.default.removeItem(at: root) }
        let ports = CredentialTestBrokerPorts(), clock = CredentialTestClock()
        let broker = try GitCredentialBroker(registry: .init(path: root.path), ports: ports.ports, clock: { clock.now() }); defer { broker.shutdown() }
        let entered = DispatchSemaphore(value: 0), resume = DispatchSemaphore(value: 0), lost = DispatchSemaphore(value: 0)
        ports.beforeContext = { entered.signal(); _ = resume.wait(timeout: .now() + 3) }
        DispatchQueue.global().async {
            do { try broker.register(.init(context: ports.context, destinations: [], directory: "/private/credential", overrideRequired: false)) }
            catch GitCredentialFailure.transport { lost.signal() }
            catch { }
        }
        try MiniTest.expect(entered.wait(timeout: .now() + 3) == .success)
        clock.advance(5); try MiniTest.expect(broker.retireIfIdle()); resume.signal()
        try MiniTest.expect(lost.wait(timeout: .now() + 3) == .success, "retirement wins before registration admission; caller must retry")
        ports.beforeContext = nil
    }),
    ("credentials.broker.graceDemandAndRetirementBoundary", {
        let root = try credentialTestRoot(); defer { try? FileManager.default.removeItem(at: root) }
        let registry = GitCredentialBrokerRegistry(path: root.path), ports = CredentialTestBrokerPorts(), clock = CredentialTestClock()
        let broker = try GitCredentialBroker(registry: registry, ports: ports.ports, clock: { clock.now() }); defer { broker.shutdown() }
        let registration = GitCredentialRegistration(context: ports.context, destinations: [try .init(url: "https://example.invalid/repo")], directory: "/private/credential", overrideRequired: false)
        clock.advance(4.999); try MiniTest.expect(!broker.retireIfIdle())
        try broker.register(registration); clock.advance(10); try MiniTest.expect(!broker.retireIfIdle())
        ports.failChannel(); clock.advance(10); try MiniTest.expect(!broker.retireIfIdle())
        try broker.unregister("synthetic"); clock.advance(4); try MiniTest.expect(!broker.retireIfIdle())
        try broker.register(registration); clock.advance(10); try MiniTest.expect(!broker.retireIfIdle())
        try broker.unregister("synthetic"); clock.advance(4.999); try MiniTest.expect(!broker.retireIfIdle())
        clock.advance(0.001); try MiniTest.expect(broker.retireIfIdle())
        try MiniTest.expectThrows({ try broker.register(registration) }, validate: { try MiniTest.expectEqual($0 as? GitCredentialFailure, .transport) })
        try MiniTest.expect(ports.calls.isEmpty)
        let successor = try GitCredentialBroker(registry: registry, ports: ports.ports, clock: { clock.now() }); defer { successor.shutdown() }
        try successor.register(registration); try MiniTest.expect(!successor.retireIfIdle())
    }),
    ("credentials.broker.externalStopAndLateObservationFence", {
        let root = try credentialTestRoot(); defer { try? FileManager.default.removeItem(at: root) }
        let registry = GitCredentialBrokerRegistry(path: root.path), ports = CredentialTestBrokerPorts(), clock = CredentialTestClock()
        let broker = try GitCredentialBroker(registry: registry, ports: ports.ports, clock: { clock.now() }); defer { broker.shutdown() }
        let registration = GitCredentialRegistration(context: ports.context, destinations: [try .init(url: "https://example.invalid/repo")], directory: "/private/credential", overrideRequired: false)
        try broker.register(registration)
        let entered = DispatchSemaphore(value: 0), resume = DispatchSemaphore(value: 0), done = DispatchSemaphore(value: 0)
        ports.beforeObserve = { entered.signal(); _ = resume.wait(timeout: .now() + 3) }
        ports.invalidateContext()
        DispatchQueue.global().async { broker.reconcile(); done.signal() }
        try MiniTest.expect(entered.wait(timeout: .now() + 3) == .success)
        let replacement = ports.context // Even healthy idempotent re-registration is newer evidence.
        ports.restoreContext(replacement)
        try broker.register(.init(context: replacement, destinations: registration.destinations, directory: registration.directory, overrideRequired: false))
        resume.signal(); try MiniTest.expect(done.wait(timeout: .now() + 3) == .success)
        try MiniTest.expectEqual(try registry.load().first?.context, replacement)
        ports.beforeObserve = nil; ports.invalidateContext(); clock.advance(2); broker.reconcile()
        try MiniTest.expect(try registry.load().isEmpty); try MiniTest.expect(!broker.retireIfIdle())
        clock.advance(5); try MiniTest.expect(broker.retireIfIdle()); try MiniTest.expect(ports.calls.isEmpty)
    }),
    ("credentials.broker.pendingRequestSurvivesUnknownButCannotLeak", {
        let root = try credentialTestRoot(); defer { try? FileManager.default.removeItem(at: root) }
        let registry = GitCredentialBrokerRegistry(path: root.path), ports = CredentialTestBrokerPorts(), clock = CredentialTestClock()
        let broker = try GitCredentialBroker(registry: registry, ports: ports.ports, clock: { clock.now() }); defer { broker.shutdown() }
        try broker.register(.init(context: ports.context, destinations: [try .init(url: "https://example.invalid/repo")], directory: "/private/credential", overrideRequired: false))
        let entered = DispatchSemaphore(value: 0), resume = DispatchSemaphore(value: 0)
        ports.beforeAcquire = { entered.signal(); _ = resume.wait(timeout: .now() + 3) }
        ports.receiver?(.init(operation: .get, request: 1, generation: ports.currentGeneration, fields: [.scheme: "https", .host: "example.invalid", .path: "repo"]))
        try MiniTest.expect(entered.wait(timeout: .now() + 3) == .success)
        ports.unavailableContext(); broker.reconcile(); clock.advance(10)
        try MiniTest.expect(!broker.retireIfIdle()); try MiniTest.expectEqual(try registry.load().count, 1)
        resume.signal(); let reply = try ports.takeReply()
        try MiniTest.expect(reply.fields.isEmpty, "unknown identity cannot receive provider secrets")
        ports.beforeAcquire = nil; ports.restoreContext(ports.context); broker.reconcile()
        try MiniTest.expectEqual(try ports.request(2).fields[.password], "synthetic")
    }),
    ("credentials.broker.runtimeUnknownPreservesRegistration", {
        let root = try credentialTestRoot(); defer { try? FileManager.default.removeItem(at: root) }
        let registry = GitCredentialBrokerRegistry(path: root.path), ports = CredentialTestBrokerPorts()
        let broker = try GitCredentialBroker(registry: registry, ports: ports.ports); defer { broker.shutdown() }
        let registration = GitCredentialRegistration(context: ports.context, destinations: [try .init(url: "https://example.invalid/repo")], directory: "/private/credential", overrideRequired: false)
        try broker.register(registration)
        ports.unavailableContext(); broker.reconcile()
        try MiniTest.expectEqual(try registry.load(), [registration], "a failed runtime observation is not proof of stop")
        try MiniTest.expect(ports.calls.isEmpty)
    }),
    ("credentials.service.emptyBrokerRetiresSuccessfully", {
        let root = try credentialShortRoot(); defer { try? FileManager.default.removeItem(at: root) }
        let context = credentialServiceContext(root)
        let service = GitCredentialBrokerService(context: context), lifetime = CredentialServiceTestLifetime()
        DispatchQueue.global().async {
            do { try service.run(ports: CredentialTestBrokerPorts().ports, shouldStop: { lifetime.shouldStop() }); lifetime.finish(true) }
            catch { lifetime.finish(false) }
        }
        defer { lifetime.stop(); _ = lifetime.awaitFinish() }
        Thread.sleep(forTimeInterval: 5.2)
        try MiniTest.expect(lifetime.awaitFinish(), "an empty service must exit successfully without a signal")
        try MiniTest.expect(!FileManager.default.fileExists(atPath: context.socket))
    }),
    ("credentials.service.slowChannelCancelKeepsExitBound", {
        let root = try credentialShortRoot(); defer { try? FileManager.default.removeItem(at: root) }
        let context = credentialServiceContext(root)
        let slow = CredentialSlowCancelChannel()
        let identity = CredentialTestBrokerPorts(id: "slow").context
        let ports = GitCredentialBrokerPorts(context: { _ in identity },
                                             connect: { _, _, _, _ in slow },
                                             acquire: { _, _, _ in nil },
                                             observe: { _, _ in .running(identity) })
        let service = GitCredentialBrokerService(context: context), lifetime = CredentialServiceTestLifetime()
        DispatchQueue.global().async {
            do { try service.run(ports: ports, shouldStop: { lifetime.shouldStop() }); lifetime.finish(true) }
            catch { lifetime.finish(false) }
        }
        defer { lifetime.stop(); _ = lifetime.awaitFinish(within: 4) }
        let deadline = Date().addingTimeInterval(3)
        while !FileManager.default.fileExists(atPath: context.socket) && Date() < deadline { Thread.sleep(forTimeInterval: 0.01) }
        let registration = GitCredentialRegistration(context: identity, destinations: [try .init(url: "https://example.invalid/repo")],
                                                     directory: "/private/credential", overrideRequired: false)
        _ = try service.request(.init(operation: .register, registration: registration), activate: false)
        let started = ProcessInfo.processInfo.systemUptime
        lifetime.stop()
        try MiniTest.expect(lifetime.awaitFinish(within: 8), "a slow channel blocked broker exit")
        let elapsed = ProcessInfo.processInfo.systemUptime - started
        try MiniTest.expect(elapsed <= 7, "slow channel shutdown took \(elapsed)s")
        try MiniTest.expectEqual(slow.cancelCount, 1, "shutdown cancels the channel once")
        print("slow channel exit: \(String(format: "%.3f", elapsed))s")
    }),
    ("credentials.service.slowChannelIdleExitStaysWithinBound", {
        let root = try credentialShortRoot(); defer { try? FileManager.default.removeItem(at: root) }
        let context = credentialServiceContext(root)
        let slow = CredentialSlowCancelChannel(delay: 1)
        let identity = CredentialTestBrokerPorts(id: "slow-idle").context
        let ports = GitCredentialBrokerPorts(context: { _ in identity }, connect: { _, _, _, _ in slow },
                                             acquire: { _, _, _ in nil }, observe: { _, _ in .running(identity) })
        let service = GitCredentialBrokerService(context: context), lifetime = CredentialServiceTestLifetime()
        DispatchQueue.global().async {
            do { try service.run(ports: ports, shouldStop: { lifetime.shouldStop() }); lifetime.finish(true) }
            catch { lifetime.finish(false) }
        }
        defer { lifetime.stop(); _ = lifetime.awaitFinish(within: 4) }
        let deadline = Date().addingTimeInterval(3)
        while !FileManager.default.fileExists(atPath: context.socket) && Date() < deadline { Thread.sleep(forTimeInterval: 0.01) }
        let registration = GitCredentialRegistration(context: identity, destinations: [try .init(url: "https://example.invalid/repo")],
                                                     directory: "/private/credential", overrideRequired: false)
        _ = try service.request(.init(operation: .register, registration: registration), activate: false)
        let started = ProcessInfo.processInfo.systemUptime
        _ = try service.request(.init(operation: .unregister, id: identity.id), activate: false)
        try MiniTest.expect(lifetime.awaitFinish(within: 8), "a slow channel blocked idle exit")
        let elapsed = ProcessInfo.processInfo.systemUptime - started
        try MiniTest.expect(elapsed >= 4.5 && elapsed <= 7, "slow-channel idle exit took \(elapsed)s")
        try MiniTest.expect(!FileManager.default.fileExists(atPath: context.socket), "idle exit left its control socket")
        print("slow channel idle exit: \(String(format: "%.3f", elapsed))s")
    }),
    ("credentials.service.privateIPCRegisterRefreshTeardown", {
        let root = try credentialShortRoot(); defer { try? FileManager.default.removeItem(at: root) }
        let context = credentialServiceContext(root)
        let service = GitCredentialBrokerService(context: context), ports = CredentialTestBrokerPorts(), lifetime = CredentialServiceTestLifetime()
        DispatchQueue.global().async {
            do { try service.run(ports: ports.ports, shouldStop: { lifetime.shouldStop() }); lifetime.finish(true) }
            catch { lifetime.finish(false) }
        }
        defer { lifetime.stop(); _ = lifetime.awaitFinish() }
        let deadline = Date().addingTimeInterval(3)
        while !FileManager.default.fileExists(atPath: context.socket) && Date() < deadline { Thread.sleep(forTimeInterval: 0.01) }
        let registration = GitCredentialRegistration(context: ports.context, destinations: [try .init(url: "https://example.invalid/repo")], directory: "/private/credential", overrideRequired: true)
        _ = try service.request(.init(operation: .register, registration: registration, token: "synthetic-service"), activate: false)
        try MiniTest.expect(ports.calls.isEmpty)
        try MiniTest.expect(try service.request(.init(operation: .refresh, registration: registration, token: "synthetic-service", sources: ["https://example.invalid/sibling/repo"]), activate: false))
        try MiniTest.expectEqual(ports.calls, ["https://example.invalid/sibling/repo"])
        _ = try service.request(.init(operation: .unregister, id: ports.context.id), activate: false)
        lifetime.stop(); try MiniTest.expect(lifetime.awaitFinish())
        try MiniTest.expect(!FileManager.default.fileExists(atPath: context.socket))
        try MiniTest.expect(try GitCredentialBrokerRegistry(path: context.state).load().isEmpty)
    }),
    ("credentials.broker.refreshMissIsNotAcquired", {
        let root = try credentialShortRoot(); defer { try? FileManager.default.removeItem(at: root) }
        let context = credentialServiceContext(root)
        let service = GitCredentialBrokerService(context: context), ports = CredentialTestBrokerPorts(), lifetime = CredentialServiceTestLifetime()
        ports.failAcquisition()
        DispatchQueue.global().async {
            do { try service.run(ports: ports.ports, shouldStop: { lifetime.shouldStop() }); lifetime.finish(true) }
            catch { lifetime.finish(false) }
        }
        defer { lifetime.stop(); _ = lifetime.awaitFinish() }
        let deadline = Date().addingTimeInterval(3)
        while !FileManager.default.fileExists(atPath: context.socket) && Date() < deadline { Thread.sleep(forTimeInterval: 0.01) }
        let registration = GitCredentialRegistration(context: ports.context, destinations: [try .init(url: "https://example.invalid/repo")], directory: "/private/credential", overrideRequired: true)
        _ = try service.request(.init(operation: .register, registration: registration, token: "synthetic-service"), activate: false)
        let acquired = try service.request(.init(operation: .refresh, registration: registration, token: "synthetic-service", sources: ["https://example.invalid/sibling/repo"]), activate: false)
        try MiniTest.expect(!acquired, "a provider miss must not be reported as a refreshed credential")
        try MiniTest.expectEqual(ports.calls, ["https://example.invalid/sibling/repo"])
        _ = try service.request(.init(operation: .unregister, id: ports.context.id), activate: false)
        lifetime.stop(); try MiniTest.expect(lifetime.awaitFinish())
        try MiniTest.expect(!FileManager.default.fileExists(atPath: context.socket))
        try MiniTest.expect(try GitCredentialBrokerRegistry(path: context.state).load().isEmpty)
    }),
    ("credentials.service.isolatedContextFileIsPrivateAndTokenFree", {
        let root = try credentialTestRoot(); defer { try? FileManager.default.removeItem(at: root) }
        let short = try credentialShortRoot(); defer { try? FileManager.default.removeItem(at: short) }
        let context = credentialServiceContext(short), identity = try credentialIdentity(context.executable)
        try context.validate()
        let probe = CredentialProbeFake(.absent), launcher = CredentialDetachedLauncher()
        launcher.afterLaunch = { probe.set(.owner(identity)) }
        let service = GitCredentialBrokerService(context: context, launcher: launcher, control: probe)
        try service.ensure()
        let contextFile = URL(fileURLWithPath: context.state + "/launch-context.json")
        let original = try Data(contentsOf: contextFile)
        let mode = try FileManager.default.attributesOfItem(atPath: contextFile.path)[.posixPermissions] as? NSNumber
        try MiniTest.expectEqual(mode?.intValue, 0o600)
        var unsafe = context; unsafe.providerEnvironment?["ADEVCONTAINER_GIT_TOKEN"] = "synthetic-must-not-persist"
        let unsafeLauncher = CredentialDetachedLauncher()
        try MiniTest.expectThrows({
            try GitCredentialBrokerService(context: unsafe, launcher: unsafeLauncher, control: probe).ensure()
        }, validate: { _ in })
        try MiniTest.expectEqual(unsafeLauncher.launches.count, 0)
        try MiniTest.expectEqual(try Data(contentsOf: contextFile), original)
    }),
    ("credentials.broker.reconciliationBackoffNoCredentialPolling", {
        let root = try credentialTestRoot(); defer { try? FileManager.default.removeItem(at: root) }
        let registry = GitCredentialBrokerRegistry(path: root.path), ports = CredentialTestBrokerPorts(), clock = CredentialTestClock()
        let broker = try GitCredentialBroker(registry: registry, ports: ports.ports, clock: { clock.now() }); defer { broker.shutdown() }
        let registration = GitCredentialRegistration(context: ports.context, destinations: [try .init(url: "https://example.invalid/org/repo")], directory: "/private/credential", overrideRequired: false)
        try broker.register(registration)
        try broker.register(registration); broker.reconcile()
        try MiniTest.expectEqual(ports.connectionCount, 1); try MiniTest.expect(ports.calls.isEmpty)
        ports.failChannel(); broker.reconcile(); try MiniTest.expectEqual(ports.connectionCount, 1)
        clock.advance(1); broker.reconcile(); try MiniTest.expectEqual(ports.connectionCount, 2)
        try MiniTest.expectEqual(try ports.request(1).fields[.password], "synthetic")
        ports.invalidateContext(); broker.reconcile()
        try MiniTest.expect(try registry.load().isEmpty)
        try MiniTest.expectEqual(ports.calls.count, 1)
    }),
    ("credentials.broker.authorizedFreshAndRestartOverrideFence", {
        let root = try credentialTestRoot(); defer { try? FileManager.default.removeItem(at: root) }
        let registry = GitCredentialBrokerRegistry(path: root.path), ports = CredentialTestBrokerPorts()
        let broker = try GitCredentialBroker(registry: registry, ports: ports.ports); defer { broker.shutdown() }
        let registration = GitCredentialRegistration(context: ports.context, destinations: [try .init(url: "https://example.invalid/org/repo")], directory: "/private/credential", overrideRequired: true)
        try broker.register(registration, override: "synthetic-override")
        let first = try ports.request(1)
        try MiniTest.expectEqual(first.fields[.password], "synthetic-override"); try MiniTest.expectEqual(first.fields[.username], "guest")
        let miss = try ports.request(2, host: "unknown.invalid"); try MiniTest.expect(miss.fields.isEmpty)
        _ = try ports.request(3); try MiniTest.expectEqual(ports.calls.count, 2)
        try MiniTest.expect(ports.calls.allSatisfy { $0 == "https://example.invalid/sibling/repo" })
        let persisted = try String(contentsOf: root.appendingPathComponent("registrations.json"), encoding: .utf8)
        try MiniTest.expect(!persisted.contains("synthetic-override"))
        broker.shutdown()
        let recovered = try GitCredentialBroker(registry: registry, ports: ports.ports); defer { recovered.shutdown() }
        recovered.reconcile(); try MiniTest.expectEqual(ports.calls.count, 2)
        try MiniTest.expectThrows({ try recovered.register(registration) }, validate: { _ in })
        try recovered.register(registration, override: "replacement-synthetic")
        let replacement = try ports.request(1)
        try MiniTest.expectEqual(replacement.fields[.password], "replacement-synthetic")
        let obsoleteChannel = ports.receiver
        try recovered.register(registration, override: "newer-synthetic")
        let newer = try ports.request(1)
        try MiniTest.expectEqual(newer.generation, replacement.generation + 1)
        obsoleteChannel?(.init(operation: .get, request: 999, generation: newer.generation, fields: [.scheme: "https", .host: "example.invalid", .path: "sibling/repo"]))
        try MiniTest.expectEqual(try ports.request(2).request, 2); try MiniTest.expectEqual(ports.calls.count, 5)
        try recovered.unregister("synthetic"); try MiniTest.expect(try registry.load().isEmpty)
    }),
    ("credentials.broker.secondGetReturnsChangedProviderPassword", {
        let root = try credentialTestRoot(); defer { try? FileManager.default.removeItem(at: root) }
        let registry = GitCredentialBrokerRegistry(path: root.path), ports = CredentialTestBrokerPorts()
        let broker = try GitCredentialBroker(registry: registry, ports: ports.ports); defer { broker.shutdown() }
        let registration = GitCredentialRegistration(context: ports.context, destinations: [try .init(url: "https://example.invalid/org/repo")], directory: "/private/credential", overrideRequired: false)
        ports.enqueuePasswords(["first-synthetic", "second-synthetic"])
        try broker.register(registration)
        let first = try ports.request(1)
        let second = try ports.request(2)
        try MiniTest.expectEqual(first.fields[.password], "first-synthetic")
        try MiniTest.expectEqual(second.fields[.password], "second-synthetic", "second get must return the new provider answer, not the previous credential")
        try MiniTest.expectEqual(ports.calls.count, 2)
    }),
    ("credentials.broker.replacedIncarnationDoesNotInheritOverride", {
        let root = try credentialTestRoot(); defer { try? FileManager.default.removeItem(at: root) }
        let registry = GitCredentialBrokerRegistry(path: root.path), ports = CredentialTestBrokerPorts()
        let broker = try GitCredentialBroker(registry: registry, ports: ports.ports); defer { broker.shutdown() }
        let registration = GitCredentialRegistration(context: ports.context, destinations: [try .init(url: "https://example.invalid/org/repo")], directory: "/private/credential", overrideRequired: true)
        try broker.register(registration, override: "old-synthetic-override")
        _ = try ports.request(1)
        let replacement = GitCredentialRuntimeContext(id: ports.context.id, incarnation: "reference:800000001", platform: ports.context.platform, user: ports.context.user, labels: ports.context.labels)
        ports.replaceContext(replacement)
        broker.reconcile()
        try MiniTest.expect(try registry.load().isEmpty, "a new same-named incarnation must not keep the failed session")
        try MiniTest.expectEqual(ports.calls.count, 1)
        let restarted = try GitCredentialBroker(registry: registry, ports: ports.ports); defer { restarted.shutdown() }
        let fresh = GitCredentialRegistration(context: replacement, destinations: registration.destinations, directory: registration.directory, overrideRequired: false)
        try restarted.register(fresh)
        let answer = try ports.request(1)
        try MiniTest.expectEqual(answer.fields[.password], "synthetic")
        try MiniTest.expect(ports.calls.allSatisfy { !$0.contains("old-synthetic-override") })
        try MiniTest.expect(!((try? String(contentsOf: root.appendingPathComponent("registrations.json"), encoding: .utf8)) ?? "").contains("old-synthetic-override"))
    }),
    ("credentials.registry.privateAtomicNonsecret", {
        let root = try credentialTestRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let registry = GitCredentialBrokerRegistry(path: root.path)
        func step<T>(_ name: String, _ body: () throws -> T) throws -> T {
            do { return try body() } catch { throw MiniTest.Failure(message: "registry \(name): \(error)") }
        }
        try MiniTest.expect(try step("initial load") { try registry.load() }.isEmpty)
        let context = GitCredentialRuntimeContext(id: "synthetic", incarnation: "reference:800000000", platform: "linux/arm64", user: "root", labels: ["devcontainer.managed": "adevcontainer"])
        let registration = GitCredentialRegistration(context: context, destinations: [try .init(url: "https://example.invalid/org/repo")], directory: "/home/synthetic/.adevcontainer/git", overrideRequired: true)
        try step("first save") { try registry.save([registration]) }; try MiniTest.expectEqual(try step("first load") { try registry.load() }, [registration])
        let url = root.appendingPathComponent("registrations.json")
        let bytes = try Data(contentsOf: url)
        try MiniTest.expect(!String(decoding: bytes, as: UTF8.self).contains("password"))
        let attributes = try FileManager.default.attributesOfItem(atPath: url.path)
        try MiniTest.expectEqual((attributes[.posixPermissions] as? NSNumber)?.intValue, 0o600)
        try step("empty save") { try registry.save([]) }; try MiniTest.expect(try step("empty load") { try registry.load() }.isEmpty)
        try Data("corrupt".utf8).write(to: url)
        try MiniTest.expectThrows({ _ = try registry.load() }, validate: { _ in })
        try FileManager.default.removeItem(at: url)
        try FileManager.default.createSymbolicLink(atPath: url.path, withDestinationPath: "/does-not-exist-synthetic")
        try MiniTest.expectThrows({ try registry.save([registration]) }, validate: { _ in })
        try MiniTest.expectThrows({ _ = try registry.load() }, validate: { _ in })
    }),
    ("credentials.registry.unsafeDirectoryAndLabels", {
        let root = try credentialTestRoot()
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o755])
        defer { try? FileManager.default.removeItem(at: root) }
        try MiniTest.expectThrows({ try GitCredentialBrokerRegistry(path: root.path).save([]) }, validate: { _ in })
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: root.path)
        let context = GitCredentialRuntimeContext(id: "synthetic", incarnation: "reference:800000000", platform: "linux/arm64", user: "root", labels: ["private-token": "must-not-persist"])
        let registration = GitCredentialRegistration(context: context, destinations: [], directory: "/private/helper", overrideRequired: false)
        try MiniTest.expectThrows({ try GitCredentialBrokerRegistry(path: root.path).save([registration]) }, validate: { _ in })
    })
]
