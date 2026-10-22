import Foundation
import Darwin

struct GitCredentialLaunchContext: Codable, Equatable, Sendable {
    static let productionLabel = "com.adevcontainer.git-credentials"
    let label: String
    let state: String
    let endpoints: String
    let executable: String
    /// Isolated verification only: the sanitized provider environment handed to
    /// the detached process. Production inherits the (token-free) host one.
    var providerEnvironment: [String: String]? = nil
    var socket: String { endpoints + "/control.sock" }
    var isProduction: Bool { label == Self.productionLabel }
    static func production() throws -> Self {
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        guard let physical = realpath(try ExecutableIdentity.currentExecutablePath(), nil) else { throw GitCredentialFailure.invalidContext }
        defer { free(physical) }
        return .init(label: productionLabel, state: home + "/Library/Application Support/adevcontainer/git-credentials",
                     endpoints: home + "/.adevcontainer/git-broker", executable: String(cString: physical))
    }
    func validate() throws {
        guard executable.hasPrefix("/"), FileManager.default.isExecutableFile(atPath: executable), socket.utf8.count < 104,
              [state, endpoints, executable].allSatisfy(GitCredentialProtocol.safe) else { throw GitCredentialFailure.invalidContext }
        if isProduction {
            guard self == (try Self.production()) else { throw GitCredentialFailure.invalidContext }
        } else {
            let prefix = "com.adevcontainer.git-credentials.test."
            guard label.hasPrefix(prefix), UUID(uuidString: String(label.dropFirst(prefix.count))) != nil,
                  let root = realpath(FileManager.default.temporaryDirectory.appendingPathComponent("opencode").path, nil) else { throw GitCredentialFailure.invalidContext }
            defer { free(root) }; let base = String(cString: root) + "/"
            guard [state, endpoints].allSatisfy({ $0.hasPrefix(base) && !$0.split(separator: "/").contains("..") }) else { throw GitCredentialFailure.invalidContext }
            if let environment = providerEnvironment {
                let allowed: Set<String> = ["PATH", "HOME", "GIT_CONFIG_GLOBAL", "GIT_CONFIG_SYSTEM", "GIT_CONFIG_NOSYSTEM"]
                guard Set(environment.keys).isSubset(of: allowed), environment["PATH"] == "/usr/bin:/bin:/usr/sbin:/sbin",
                      environment["HOME"] == state, environment["GIT_CONFIG_SYSTEM"] == "/dev/null", environment["GIT_CONFIG_NOSYSTEM"] == "1",
                      let global = environment["GIT_CONFIG_GLOBAL"], global.hasPrefix(state + "/"), !global.split(separator: "/").contains(".."),
                      environment.values.allSatisfy(GitCredentialProtocol.safe) else { throw GitCredentialFailure.invalidContext }
            }
        }
    }
}

final class GitCredentialServiceLock {
    private let fd: Int32
    init(directory: String, name: String = "broker.lock", wait: TimeInterval = 0) throws {
        guard ["broker.lock", "activation.lock", "provision.lock"].contains(name) else { throw GitCredentialFailure.unsafePath }
        let directory = try GitCredentialPrivateFiles.directory(directory, create: true); defer { close(directory) }
        let deadline = ProcessInfo.processInfo.systemUptime + wait
        var descriptor: Int32
        repeat {
            descriptor = openat(directory, name, O_CREAT | O_RDWR | O_NOFOLLOW | O_CLOEXEC, 0o600)
            if descriptor >= 0 { break }
            guard errno == ENOENT || errno == EINTR, ProcessInfo.processInfo.systemUptime < deadline else { throw GitCredentialFailure.unsafePath }
            Thread.sleep(forTimeInterval: 0.025)
        } while true
        var st = stat()
        guard fstat(descriptor, &st) == 0, st.st_uid == geteuid(), st.st_mode & S_IFMT == S_IFREG, st.st_mode & 0o777 == 0o600, st.st_nlink == 1 else { close(descriptor); throw GitCredentialFailure.unsafePath }
        while flock(descriptor, LOCK_EX | LOCK_NB) != 0 {
            guard (errno == EWOULDBLOCK || errno == EINTR), ProcessInfo.processInfo.systemUptime < deadline else { close(descriptor); throw GitCredentialFailure.overloaded }
            Thread.sleep(forTimeInterval: 0.025)
        }
        fd = descriptor
    }
    deinit { close(fd) }
}

/// Activation adapter. The CLI is the broker's only launcher: it starts the
/// same executable as a detached session when no acceptable owner is serving.
/// Tests pass a unique isolated context plus fake launch/probe ports; no test
/// selects or mutates the real per-user broker.
struct GitCredentialBrokerService: Sendable {
    static let replacementBound: TimeInterval = 4
    /// The pre-spawn identity probe is a liveness check, not a request. A
    /// connected-but-silent endpoint must fail closed quickly instead of
    /// consuming the activation deadline and then spawning over a live owner.
    static let probeBound: TimeInterval = 2
    static let readinessInterval: TimeInterval = 0.025
    /// A successor spawned while a retiring owner finishes cleanup waits for
    /// the lifetime lock instead of failing startup.
    static let lifetimeLockWait: TimeInterval = 5
    let context: GitCredentialLaunchContext
    let launcher: any DetachedProcessLaunching
    let control: any GitCredentialBrokerProbing
    init(context: GitCredentialLaunchContext, launcher: any DetachedProcessLaunching = PosixDetachedProcessLauncher(),
         control: any GitCredentialBrokerProbing = GitCredentialControlClient()) {
        self.context = context; self.launcher = launcher; self.control = control
    }
    func ensure(deadline: TimeInterval = ProcessInfo.processInfo.systemUptime + 30) throws {
        guard ProcessInfo.processInfo.systemUptime < deadline else { throw GitCredentialFailure.deadline }
        try context.validate()
        let identity = try ExecutableIdentity.read(context.executable)
        // Resolve the sanitized child environment before any side effect so a
        // broken isolated context cannot retire a healthy owner and then fail.
        let environment = try brokerEnvironment()
        let owner = try GitCredentialServiceLock(directory: context.endpoints, name: "activation.lock", wait: max(0, deadline - ProcessInfo.processInfo.systemUptime))
        defer { withExtendedLifetime(owner) {} }
        // Keep readiness polling on the full activation deadline: a newly
        // started broker may legitimately spend longer reconciling before it
        // answers hello. Only this pre-spawn identity check is short.
        let probeDeadline = min(deadline, ProcessInfo.processInfo.systemUptime + Self.probeBound)
        switch try control.probe(context, deadline: probeDeadline) {
        case .owner(let running) where running.matches(identity): return
        // An endpoint we cannot authenticate is never killed or replaced.
        case .unrecognized: throw GitCredentialFailure.invalidContext
        case .owner: try retireOwner(deadline)
        case .absent: break
        }
        // A probe may have consumed the caller's deadline. Recheck before any
        // side effect so a timed-out activation cannot still start a successor.
        guard ProcessInfo.processInfo.systemUptime < deadline else { throw GitCredentialFailure.deadline }
        if !context.isProduction {
            let state = try GitCredentialPrivateFiles.directory(context.state, create: true); defer { close(state) }
            try GitCredentialPrivateFiles.write(JSONEncoder().encode(context), name: "launch-context.json", directory: state)
        }
        guard ProcessInfo.processInfo.systemUptime < deadline else { throw GitCredentialFailure.deadline }
        let process = try launcher.launch(executable: context.executable, arguments: launchArguments, environment: environment)
        defer { launcher.reap(process) }
        try awaitOwner(identity, deadline)
    }
    private var launchArguments: [String] {
        var arguments = ["__adevcontainer_git_broker"]
        if !context.isProduction { arguments.append(context.state + "/launch-context.json") }
        return arguments
    }
    /// The explicit host token escape hatch never crosses into the broker, so a
    /// successor cannot inherit a credential the current session did not re-register.
    private func brokerEnvironment() throws -> [String: String] {
        if context.isProduction { return ProcessInfo.processInfo.environment.filter { $0.key != "ADEVCONTAINER_GIT_TOKEN" } }
        guard let isolated = context.providerEnvironment else { throw GitCredentialFailure.invalidContext }
        return isolated
    }
    /// One bounded graceful replacement. A refusal or hang is a soft setup
    /// failure, never an unauthenticated kill or second registry owner.
    private func retireOwner(_ deadline: TimeInterval) throws {
        guard ProcessInfo.processInfo.systemUptime < deadline else { throw GitCredentialFailure.deadline }
        let bound = min(deadline, ProcessInfo.processInfo.systemUptime + Self.replacementBound)
        try control.retire(context, deadline: bound)
        while true {
            guard ProcessInfo.processInfo.systemUptime < bound else { throw GitCredentialFailure.deadline }
            switch try control.probe(context, deadline: bound) {
            case .absent: return
            case .unrecognized: throw GitCredentialFailure.invalidContext
            case .owner: Thread.sleep(forTimeInterval: Self.readinessInterval)
            }
        }
    }
    /// Readiness poll. A concurrent activation may win the lifetime lock with a
    /// different executable; retire it once and keep converging instead of
    /// adopting an owner this executable did not start.
    private func awaitOwner(_ identity: ExecutableIdentity, _ deadline: TimeInterval) throws {
        var retired = false
        while true {
            guard ProcessInfo.processInfo.systemUptime < deadline else { throw GitCredentialFailure.deadline }
            switch try control.probe(context, deadline: deadline) {
            case .owner(let running) where running.matches(identity): return
            case .absent: break
            case .unrecognized: throw GitCredentialFailure.invalidContext
            case .owner:
                guard !retired else { throw GitCredentialFailure.deadline }
                retired = true
                try control.retire(context, deadline: min(deadline, ProcessInfo.processInfo.systemUptime + Self.replacementBound))
            }
            Thread.sleep(forTimeInterval: Self.readinessInterval)
        }
    }
}
