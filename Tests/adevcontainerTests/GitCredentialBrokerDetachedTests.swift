import Foundation
import Darwin
@testable import ADevContainerLib

/// Test-owned detached broker. Runs the production service loop and control
/// socket with synthetic runtime/provider ports, from a private copy of this
/// executable, under the approved temporary root. No Apple runtime, provider,
/// network, keychain, launchd domain, or production path is reachable here.
enum GitCredentialDetachedProbe {
    private static let lock = NSLock()
    static func context(_ id: String) -> GitCredentialRuntimeContext {
        .init(id: id, incarnation: "synthetic:1", platform: "linux/arm64", user: "root", labels: ["devcontainer.managed": "adevcontainer"])
    }
    static func observation(_ id: String, root: String) -> GitCredentialObservation {
        guard let bytes = try? Data(contentsOf: URL(fileURLWithPath: root + "/observations.json")),
              let states = try? JSONDecoder().decode([String: String].self, from: bytes) else { return .unknown }
        switch states[id] {
        case "running": return .running(context(id))
        case "stopped": return .inactive
        default: return .unknown
        }
    }
    static func integer(_ name: String, root: String) -> Int {
        Int(String(decoding: (try? Data(contentsOf: URL(fileURLWithPath: root + "/" + name))) ?? Data(), as: UTF8.self)) ?? 0
    }
    private static func increment(_ name: String, root: String) {
        lock.lock(); defer { lock.unlock() }
        let next = integer(name, root: root) + 1
        try? Data("\(next)".utf8).write(to: URL(fileURLWithPath: root + "/" + name))
    }
    static func decode(_ path: String) throws -> GitCredentialLaunchContext {
        guard let directory = try? GitCredentialPrivateFiles.directory((path as NSString).deletingLastPathComponent, create: false) else { throw GitCredentialFailure.invalidContext }
        defer { close(directory) }
        guard (path as NSString).lastPathComponent == "launch-context.json",
              let data = try GitCredentialPrivateFiles.read("launch-context.json", directory: directory) else { throw GitCredentialFailure.invalidContext }
        let context = try JSONDecoder().decode(GitCredentialLaunchContext.self, from: data)
        guard !context.isProduction else { throw GitCredentialFailure.invalidContext }
        try context.validate()
        return context
    }
    /// CLI stand-in: one activation transaction, then exit like the invoking CLI.
    static func activate(_ path: String, id: String?) -> Int32 {
        do {
            let context = try decode(path)
            let service = GitCredentialBrokerService(context: context)
            try service.ensure()
            if let id, case .running(let identity) = GitCredentialDetachedProbe.observation(id, root: context.endpoints) {
                let registration = GitCredentialRegistration(context: identity, destinations: [try .init(url: "https://example.invalid/repo")],
                                                             directory: "/synthetic/credential", overrideRequired: false)
                _ = try service.request(.init(operation: .register, registration: registration))
            }
            return 0
        } catch { return 1 }
    }
    static func run(_ path: String) -> Int32 {
        do {
            let context = try decode(path)
            let root = context.endpoints
            let output = try GitCredentialPrivateFiles.directory(root, create: false); defer { close(output) }
            try GitCredentialPrivateFiles.write(Data("\(getpid())".utf8), name: "pid", directory: output)
            increment("starts", root: root)
            let stop = GitCredentialDetachedStop()
            let term = signal(SIGTERM, SIG_IGN), interrupt = signal(SIGINT, SIG_IGN), hangup = signal(SIGHUP, SIG_IGN)
            let sources = [SIGTERM, SIGINT].map { number -> DispatchSourceSignal in
                let source = DispatchSource.makeSignalSource(signal: number, queue: .global())
                source.setEventHandler { stop.stop() }; source.resume(); return source
            }
            defer { for source in sources { source.cancel() }; signal(SIGTERM, term); signal(SIGINT, interrupt); signal(SIGHUP, hangup) }
            let ports = GitCredentialBrokerPorts(context: { id in
                guard case .running(let context) = observation(id, root: root) else { throw GitCredentialFailure.invalidContext }
                return context
            }, connect: { _, generation, receive, _ in
                increment("connects", root: root)
                let channel = CredentialTestChannel()
                // A consumer is simulated only when the fixture asks for one, so
                // the crash/reuse tests can still prove zero provider lookups.
                DispatchQueue.global(qos: .utility).async {
                    let trigger = root + "/lookup", end = ProcessInfo.processInfo.systemUptime + 5
                    while !FileManager.default.fileExists(atPath: trigger), ProcessInfo.processInfo.systemUptime < end {
                        Thread.sleep(forTimeInterval: 0.025)
                    }
                    guard FileManager.default.fileExists(atPath: trigger) else { return }
                    receive(.init(operation: .get, request: 1, generation: generation,
                                  fields: [.scheme: "https", .host: "example.invalid", .path: "repo"]))
                    guard let reply = try? channel.take() else { return }
                    increment("lookups", root: root)
                    try? Data((reply.fields[.password] ?? "").utf8).write(to: URL(fileURLWithPath: root + "/lookup-reply"))
                }
                return channel
            }, acquire: { _, _, _ in
                increment("acquires", root: root)
                guard FileManager.default.fileExists(atPath: root + "/lookup") else { return nil }
                return .init(username: "host-account", password: "synthetic-upgrade")
            }, observe: { id, _ in observation(id, root: root) })
            try GitCredentialBrokerService(context: context).run(ports: ports, shouldStop: { stop.shouldStop() })
            return 0
        } catch { return 1 }
    }
}

private final class GitCredentialDetachedStop: @unchecked Sendable {
    private let lock = NSLock()
    private var stopped = false
    func stop() { lock.lock(); stopped = true; lock.unlock() }
    func shouldStop() -> Bool { lock.lock(); defer { lock.unlock() }; return stopped }
}

/// One isolated fixture: private root, test-owned executable copies, private
/// synthetic context. Cleanup terminates only pids this fixture recorded.
final class GitCredentialDetachedHarness: @unchecked Sendable {
    let root: URL
    let context: GitCredentialLaunchContext
    private let runner = FoundationProcessRunner()
    private let lock = NSLock()
    private var owned: Set<Int32> = []
    init(root: URL, executable: String) {
        self.root = root
        self.context = .init(label: "com.adevcontainer.git-credentials.test.\(UUID().uuidString)", state: root.path + "/state",
                             endpoints: root.path, executable: executable,
                             providerEnvironment: ["PATH": "/usr/bin:/bin:/usr/sbin:/sbin", "HOME": root.path + "/state",
                                                  "GIT_CONFIG_GLOBAL": root.path + "/state/synthetic.gitconfig", "GIT_CONFIG_SYSTEM": "/dev/null", "GIT_CONFIG_NOSYSTEM": "1"])
    }
    func prepare() throws {
        try FileManager.default.createDirectory(atPath: context.state, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        let state = try GitCredentialPrivateFiles.directory(context.state, create: false); defer { close(state) }
        try GitCredentialPrivateFiles.write(JSONEncoder().encode(context), name: "launch-context.json", directory: state)
        announce()
    }
    /// Secret-free recovery manifest. A parent SIGKILL cannot run cleanup, so
    /// the root/pid lines already written to stderr identify only this fixture.
    private func announce() {
        let line = "detached-broker fixture root=\(context.endpoints) state=\(context.state) pid=\(pid ?? 0)\n"
        FileHandle.standardError.write(Data(line.utf8))
    }
    var contextPath: String { context.state + "/launch-context.json" }
    func states(_ values: [String: String]) throws {
        try Data(JSONEncoder().encode(values)).write(to: URL(fileURLWithPath: context.endpoints + "/observations.json"))
    }
    func integer(_ name: String) -> Int { GitCredentialDetachedProbe.integer(name, root: context.endpoints) }
    var pid: Int32? {
        guard let data = try? Data(contentsOf: URL(fileURLWithPath: context.endpoints + "/pid")) else { return nil }
        return Int32(String(decoding: data, as: UTF8.self))
    }
    func socketExists() -> Bool { FileManager.default.fileExists(atPath: context.socket) }
    func registrations() throws -> [GitCredentialRegistration] { try GitCredentialBrokerRegistry(path: context.state).load() }
    @discardableResult func activate(_ id: String? = nil) throws -> Int32 {
        let result = try runner.run(executable: context.executable, arguments: ["__adevcontainer_git_activate", contextPath, id ?? "-"],
                                    environment: ["PATH": "/usr/bin:/bin:/usr/sbin:/sbin"], currentDirectory: nil)
        guard result.succeeded else { throw MiniTest.Failure(message: "isolated activation \(id ?? "-") failed: \(result.stderrString)") }
        if let pid { lock.lock(); owned.insert(pid); lock.unlock() }
        announce()
        return result.exitCode
    }
    func activateConcurrently(_ ids: [String]) throws {
        final class Flag: @unchecked Sendable {
            private let lock = NSLock()
            private var value = false
            func raise() { lock.lock(); value = true; lock.unlock() }
            var raised: Bool { lock.lock(); defer { lock.unlock() }; return value }
        }
        let group = DispatchGroup(), failed = Flag()
        for id in ids {
            group.enter()
            DispatchQueue.global().async { [self] in
                defer { group.leave() }
                do { try activate(id) } catch { failed.raise() }
            }
        }
        guard group.wait(timeout: .now() + 30) == .success, !failed.raised else { throw MiniTest.Failure(message: "concurrent isolated activation failed") }
    }
    func probe() throws -> GitCredentialBrokerStatus {
        try GitCredentialControlClient().probe(context, deadline: ProcessInfo.processInfo.systemUptime + 3)
    }
    func isOwned(_ expected: ExecutableIdentity) throws -> Bool {
        if case .owner(let running) = try probe() { return running.matches(expected) }
        return false
    }
    func expectConnection() throws { try wait(3, "no synthetic channel was connected") { integer("connects") >= 1 } }
    func alive(_ pid: Int32) -> Bool { kill(pid, 0) == 0 }
    func wait(_ seconds: TimeInterval, _ message: String, until body: () throws -> Bool) throws {
        let end = ProcessInfo.processInfo.systemUptime + seconds
        while try !body() {
            guard ProcessInfo.processInfo.systemUptime < end else { throw MiniTest.Failure(message: message) }
            Thread.sleep(forTimeInterval: 0.025)
        }
    }
    func pause(_ seconds: TimeInterval) throws {
        let end = ProcessInfo.processInfo.systemUptime + seconds
        try wait(seconds + 1, "timed observation interrupted") { ProcessInfo.processInfo.systemUptime >= end }
    }
    func waitExit(_ pid: Int32, _ seconds: TimeInterval) throws {
        try wait(seconds, "test-owned broker \(pid) did not exit") { !alive(pid) }
    }
    /// Terminates only pids recorded from this fixture's own private root.
    func cleanup() {
        lock.lock(); var pids = owned; if let current = pid { pids.insert(current) }; lock.unlock()
        for pid in pids where alive(pid) {
            _ = kill(pid, SIGTERM)
            let end = ProcessInfo.processInfo.systemUptime + 3
            while alive(pid), ProcessInfo.processInfo.systemUptime < end { Thread.sleep(forTimeInterval: 0.025) }
            if alive(pid) { _ = kill(pid, SIGKILL) }
        }
        try? FileManager.default.removeItem(at: root)
    }
}

private func detachedExecutableCopy(_ root: URL, _ name: String) throws -> String {
    let source = try ExecutableIdentity.currentExecutablePath()
    let target = root.appendingPathComponent(name).path
    try FileManager.default.copyItem(atPath: source, toPath: target)
    try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: target)
    return target
}

@MainActor let gitCredentialBrokerDetachedTests: [(String, () throws -> Void)] = ProcessInfo.processInfo.environment["ADEVCONTAINER_DETACHED_BROKER_TEST"] == "1" ? [
    ("credentials.detached.startBeforeConsumerAndSurviveCLI", {
        let root = try credentialShortRoot()
        let harness = GitCredentialDetachedHarness(root: root, executable: try detachedExecutableCopy(root, "probe-a"))
        defer { harness.cleanup() }
        try harness.prepare(); try harness.states(["first": "running"])
        let started = ProcessInfo.processInfo.systemUptime
        try harness.activate("first")
        guard let pid = harness.pid else { throw MiniTest.Failure(message: "detached broker did not record its pid") }
        try MiniTest.expect(pid != getpid() && pid > 1, "broker must be a different process from the CLI")
        try MiniTest.expect(harness.alive(pid), "broker must survive the invoking CLI")
        try harness.wait(3, "detached broker never answered hello after CLI exit") { try harness.isOwned(try credentialIdentity(harness.context.executable)) }
        print("detached start+surviveCLI: \(String(format: "%.3f", ProcessInfo.processInfo.systemUptime - started))s")
        try MiniTest.expectEqual(try harness.registrations().map(\.context.id), ["first"])
        // The same process serves a consumer that arrives after the CLI is gone.
        try harness.activate("first")
        try MiniTest.expectEqual(harness.pid, pid)
        try MiniTest.expectEqual(harness.integer("starts"), 1)
        try MiniTest.expectEqual(harness.integer("connects"), 1)
    }),
    ("credentials.detached.twoCLIsConverge", {
        let root = try credentialShortRoot()
        let harness = GitCredentialDetachedHarness(root: root, executable: try detachedExecutableCopy(root, "probe-a"))
        defer { harness.cleanup() }
        try harness.prepare(); try harness.states(["first": "running", "second": "running"])
        try harness.activateConcurrently(["first", "second"])
        guard let pid = harness.pid else { throw MiniTest.Failure(message: "no owner after concurrent activation") }
        try MiniTest.expectEqual(harness.integer("starts"), 1, "concurrent CLIs must start exactly one detached broker")
        try MiniTest.expectEqual(Set(try harness.registrations().map(\.context.id)), ["first", "second"])
        try MiniTest.expect(try harness.isOwned(try credentialIdentity(harness.context.executable)), "the expected executable is not the owner")
        // A later activation reuses the same owner without spawning another.
        try harness.activate("first")
        try MiniTest.expectEqual(harness.pid, pid); try MiniTest.expectEqual(harness.integer("starts"), 1)
    }),
    ("credentials.detached.idleExitAndSuccessor", {
        let root = try credentialShortRoot()
        let harness = GitCredentialDetachedHarness(root: root, executable: try detachedExecutableCopy(root, "probe-a"))
        defer { harness.cleanup() }
        try harness.prepare(); try harness.states(["first": "running"])
        try harness.activate("first")
        guard let first = harness.pid else { throw MiniTest.Failure(message: "no owner") }
        let service = GitCredentialBrokerService(context: harness.context)
        _ = try service.request(.init(operation: .unregister, id: "first"), activate: false)
        let started = ProcessInfo.processInfo.systemUptime
        try harness.waitExit(first, 7)
        let elapsed = ProcessInfo.processInfo.systemUptime - started
        try MiniTest.expect(elapsed >= 4.5 && elapsed <= 7, "idle exit took \(elapsed)s")
        print("detached idle exit: \(String(format: "%.3f", elapsed))s")
        try harness.wait(2, "idle exit left a stale control socket") { !harness.socketExists() }
        try MiniTest.expect(FileManager.default.fileExists(atPath: harness.context.endpoints + "/broker.lock"), "lock inodes are never unlinked")
        try MiniTest.expect(try harness.probe() == .absent, "no automatic replacement may start")
        try harness.activate("first")
        guard let second = harness.pid else { throw MiniTest.Failure(message: "later demand did not start a successor") }
        try MiniTest.expect(second != first); try MiniTest.expectEqual(harness.integer("starts"), 2)
        try harness.wait(3, "successor never answered hello") { try harness.isOwned(try credentialIdentity(harness.context.executable)) }
    }),
    ("credentials.detached.crashIsNotAutoRestarted", {
        let root = try credentialShortRoot()
        let harness = GitCredentialDetachedHarness(root: root, executable: try detachedExecutableCopy(root, "probe-a"))
        defer { harness.cleanup() }
        try harness.prepare(); try harness.states(["first": "running"])
        try harness.activate("first")
        guard let crashed = harness.pid else { throw MiniTest.Failure(message: "no owner") }
        try MiniTest.expectEqual(harness.integer("acquires"), 0, "idle broker must not poll a provider")
        // An explicit override lives only in the broker's memory.
        try harness.states(["first": "running", "second": "running"])
        let override = "synthetic-override-secret"
        let overridden = GitCredentialRegistration(context: GitCredentialDetachedProbe.context("second"),
                                                   destinations: [try .init(url: "https://example.invalid/repo")],
                                                   directory: "/synthetic/credential", overrideRequired: true)
        let service = GitCredentialBrokerService(context: harness.context)
        _ = try service.request(.init(operation: .register, registration: overridden, token: override))
        try MiniTest.expect(kill(crashed, SIGKILL) == 0)
        try harness.waitExit(crashed, 3)
        try harness.pause(6.5)
        try MiniTest.expectEqual(harness.integer("starts"), 1, "a crashed broker must not be replaced automatically")
        try MiniTest.expectEqual(harness.pid, crashed)
        try MiniTest.expect(try harness.probe() == .absent, "the stale socket is not usable")
        // The next eligible activation restores the process and reconciles intent.
        try harness.activate("first")
        guard let successor = harness.pid else { throw MiniTest.Failure(message: "no successor") }
        try MiniTest.expectEqual(harness.integer("starts"), 2)
        try MiniTest.expectEqual(Set(try harness.registrations().map(\.context.id)), ["first", "second"])
        try harness.wait(3, "successor did not reconnect the running registration") { harness.integer("connects") >= 1 }
        try MiniTest.expectEqual(harness.integer("acquires"), 0, "recovery must not replay provider requests")
        let persisted = try String(contentsOf: URL(fileURLWithPath: harness.context.state + "/registrations.json"), encoding: .utf8)
        try MiniTest.expect(!persisted.contains(override), "an explicit override is never persisted across restart")
        // The successor does not silently substitute another credential source:
        // the session that needed an override must be re-registered by a CLI.
        try harness.pause(2.2) // Let the successor reconcile before validating a lookup.
        try MiniTest.expectThrows({
            _ = try service.request(.init(operation: .refresh, registration: overridden, sources: ["https://example.invalid/repo"]))
        }, validate: { try MiniTest.expectEqual($0 as? GitCredentialFailure, .invalidContext) })
        try MiniTest.expectEqual(harness.integer("acquires"), 0)
        try MiniTest.expect(successor != crashed)
    }),
    ("credentials.detached.upgradeReplacesOwner", {
        let root = try credentialShortRoot()
        let old = try detachedExecutableCopy(root, "probe-a")
        let harness = GitCredentialDetachedHarness(root: root, executable: old)
        defer { harness.cleanup() }
        try harness.prepare(); try harness.states(["first": "running"])
        try harness.activate("first")
        guard let previous = harness.pid else { throw MiniTest.Failure(message: "no owner") }
        let connections = harness.integer("connects")
        // A second copy is a different file: device/inode differ even though the
        // build bytes are identical, which is exactly the upgrade signal.
        let upgraded = try detachedExecutableCopy(root, "probe-b")
        let next = GitCredentialLaunchContext(label: harness.context.label, state: harness.context.state, endpoints: harness.context.endpoints,
                                              executable: upgraded, providerEnvironment: harness.context.providerEnvironment)
        let state = try GitCredentialPrivateFiles.directory(next.state, create: false); defer { close(state) }
        try GitCredentialPrivateFiles.write(JSONEncoder().encode(next), name: "launch-context.json", directory: state)
        let upgradedHarness = GitCredentialDetachedHarness(root: root, executable: upgraded)
        let started = ProcessInfo.processInfo.systemUptime
        try upgradedHarness.activate("first")
        guard let successor = harness.pid else { throw MiniTest.Failure(message: "no successor") }
        try MiniTest.expect(successor != previous, "the upgraded executable must become the only owner")
        try harness.wait(3, "the old executable is still serving") { !harness.alive(previous) }
        print("detached upgrade replacement: \(String(format: "%.3f", ProcessInfo.processInfo.systemUptime - started))s")
        try MiniTest.expectEqual(harness.integer("starts"), 2)
        try MiniTest.expectEqual(try harness.registrations().map(\.context.id), ["first"], "registrations survive replacement")
        guard case .owner(let reported) = try GitCredentialControlClient().probe(next, deadline: ProcessInfo.processInfo.systemUptime + 3),
              reported.matches(try credentialIdentity(upgraded)) else {
            throw MiniTest.Failure(message: "the upgraded executable is not the only owner")
        }
        // E02: the successor serves a real channel lookup from the saved
        // registration, without the CLI registering it again.
        try harness.wait(3, "successor did not reconnect the saved registration") { harness.integer("connects") > connections }
        let lookupStarted = ProcessInfo.processInfo.systemUptime
        try Data().write(to: URL(fileURLWithPath: root.path + "/lookup"))
        try harness.wait(5, "lookup after upgrade did not complete") { harness.integer("lookups") >= 1 }
        try MiniTest.expectEqual(try String(contentsOfFile: root.path + "/lookup-reply", encoding: .utf8), "synthetic-upgrade")
        print("detached post-upgrade lookup: \(String(format: "%.3f", ProcessInfo.processInfo.systemUptime - lookupStarted))s")
        try MiniTest.expectEqual(harness.integer("acquires"), 1, "the successor served one provider lookup")
        // Repeating the activation must not kill the healthy successor.
        try upgradedHarness.activate("first")
        try MiniTest.expectEqual(harness.pid, successor); try MiniTest.expectEqual(harness.integer("starts"), 2)
    }),
    ("credentials.detached.exitCleansOwnedSocketOnly", {
        let root = try credentialShortRoot()
        let harness = GitCredentialDetachedHarness(root: root, executable: try detachedExecutableCopy(root, "probe-a"))
        defer { harness.cleanup() }
        try harness.prepare(); try harness.states(["first": "running"])
        try harness.activate("first")
        guard let pid = harness.pid else { throw MiniTest.Failure(message: "no owner") }
        try harness.expectConnection()
        let lockPath = harness.context.endpoints + "/broker.lock"
        let lockInode = try FileManager.default.attributesOfItem(atPath: lockPath)[.systemFileNumber] as? NSNumber
        try MiniTest.expect(kill(pid, SIGTERM) == 0)
        try harness.waitExit(pid, 7)
        try harness.wait(2, "graceful exit left its own control socket") { !harness.socketExists() }
        let after = try FileManager.default.attributesOfItem(atPath: lockPath)[.systemFileNumber] as? NSNumber
        try MiniTest.expectEqual(after, lockInode, "lock inodes are never unlinked or replaced")
        try MiniTest.expectEqual(try harness.registrations().map(\.context.id), ["first"], "registrations are preserved for the successor")
        try harness.activate("first")
        guard let successor = harness.pid else { throw MiniTest.Failure(message: "no successor") }
        try MiniTest.expect(successor != pid)
        try MiniTest.expect(try harness.isOwned(try credentialIdentity(harness.context.executable)), "the expected executable is not the owner")
    }),
    ("credentials.detached.staleAndSymlinkEndpointFailClosed", {
        let root = try credentialShortRoot()
        let harness = GitCredentialDetachedHarness(root: root, executable: try detachedExecutableCopy(root, "probe-a"))
        defer { harness.cleanup() }
        try harness.prepare(); try harness.states(["first": "running"])
        try harness.activate("first")
        guard let crashed = harness.pid else { throw MiniTest.Failure(message: "no owner") }
        try MiniTest.expect(kill(crashed, SIGKILL) == 0); try harness.waitExit(crashed, 3)
        try MiniTest.expect(harness.socketExists(), "abnormal exit leaves a stale socket for the successor")
        try harness.activate("first")
        guard let successor = harness.pid else { throw MiniTest.Failure(message: "successor did not replace the stale socket") }
        try MiniTest.expect(successor != crashed); try MiniTest.expectEqual(harness.integer("starts"), 2)
        try MiniTest.expect(try harness.isOwned(try credentialIdentity(harness.context.executable)), "the expected executable is not the owner")
        // A symlinked endpoint is foreign: fail closed without deleting anything.
        try MiniTest.expect(kill(successor, SIGTERM) == 0); try harness.waitExit(successor, 7)
        let target = root.appendingPathComponent("not-a-socket").path
        try Data("synthetic-target\n".utf8).write(to: URL(fileURLWithPath: target))
        try FileManager.default.createSymbolicLink(atPath: harness.context.socket, withDestinationPath: target)
        var refused = false
        do { try harness.activate("first") } catch { refused = true }
        try MiniTest.expect(refused, "a symlinked endpoint must fail activation")
        try MiniTest.expect(FileManager.default.fileExists(atPath: harness.context.socket), "the foreign endpoint is not unlinked")
        try MiniTest.expectEqual(try String(contentsOfFile: target, encoding: .utf8), "synthetic-target\n")
        try MiniTest.expectEqual(harness.integer("starts"), 2, "a foreign endpoint never spawns a competing owner")
    }),
    ("credentials.detached.silentEndpointFailsClosed", {
        let root = try credentialShortRoot()
        let harness = GitCredentialDetachedHarness(root: root, executable: try detachedExecutableCopy(root, "probe-a"))
        defer { harness.cleanup() }
        try harness.prepare(); try harness.states(["first": "running"])
        let listener = try CredentialMuteListener(path: harness.context.socket); defer { listener.stop() }
        var before = stat(); try MiniTest.expectEqual(lstat(harness.context.socket, &before), 0)
        let started = ProcessInfo.processInfo.systemUptime
        var refused = false
        do { _ = try harness.activate("first") } catch { refused = true }
        let elapsed = ProcessInfo.processInfo.systemUptime - started
        print("detached silent endpoint fail-closed: \(String(format: "%.3f", elapsed))s")
        try MiniTest.expect(elapsed < 5, "a silent endpoint must fail closed inside the probe bound, took \(elapsed)s")
        try MiniTest.expect(refused, "a silent same-user endpoint must fail activation")
        try MiniTest.expectEqual(harness.integer("starts"), 0, "a silent endpoint must never start a competing owner")
        try MiniTest.expect(harness.pid == nil, "no broker pid may be recorded")
        var after = stat(); try MiniTest.expectEqual(lstat(harness.context.socket, &after), 0)
        try MiniTest.expectEqual(after.st_ino, before.st_ino, "the live endpoint inode is never replaced")
        try MiniTest.expectEqual(after.st_dev, before.st_dev)
        // A later retry can converge once the unidentifiable endpoint is gone.
        listener.stop()
        try FileManager.default.removeItem(atPath: harness.context.socket)
        try harness.activate("first")
        try MiniTest.expectEqual(harness.integer("starts"), 1)
        try harness.wait(3, "the successor never answered hello") { try harness.isOwned(try credentialIdentity(harness.context.executable)) }
    }),
    ("credentials.detached.sighupAndSigtermExit", {
        let root = try credentialShortRoot()
        let harness = GitCredentialDetachedHarness(root: root, executable: try detachedExecutableCopy(root, "probe-a"))
        defer { harness.cleanup() }
        try harness.prepare(); try harness.states(["first": "running"])
        try harness.activate("first")
        guard let pid = harness.pid else { throw MiniTest.Failure(message: "no owner") }
        try MiniTest.expect(kill(pid, SIGHUP) == 0)
        Thread.sleep(forTimeInterval: 0.5)
        try MiniTest.expect(harness.alive(pid), "SIGHUP must not terminate a detached broker")
        try MiniTest.expectEqual(harness.pid, pid)
        try MiniTest.expect(try harness.isOwned(try credentialIdentity(harness.context.executable)), "the expected executable is not the owner")
        try MiniTest.expect(kill(pid, SIGTERM) == 0)
        try harness.waitExit(pid, 7)
        try harness.wait(2, "SIGTERM left the control socket") { !harness.socketExists() }
        try MiniTest.expectEqual(harness.integer("starts"), 1, "a signal exit is not restarted")
    })
] : []
