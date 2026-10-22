import Foundation
import Darwin

/// Credential-only process lifetime. Unlike the general runner, never tees payloads.
final class CredentialDuplexProcess: @unchecked Sendable {
    /// A SIGKILLed process group normally reaps in milliseconds. The wait stays
    /// bounded so one process in an uninterruptible state cannot hang broker
    /// shutdown, and a deadline exception never blocks on reaping.
    static let cancelBound: TimeInterval = 2
    // State/queue/lifetime are protected by state; exactly one reader owns pipe
    // drainage. Descriptors close only after all method references release self.
    private let state = NSLock()
    private let reader = NSLock()
    private let pid: pid_t
    private let input: Int32
    private let output: Int32
    private let errors: Int32
    private let alive: Int32?
    private let childStatus: Int32?
    private var pending = Data()
    private var inputClosing = false
    private var inputClosed = false
    private var result: Int32?
    private var outputEOF = false
    private var errorEOF = false

    init(executable: String, arguments: [String], environment: [String: String], guarded: Bool = false, deadline: TimeInterval? = nil) throws {
        guard executable.hasPrefix("/"), !executable.utf8.contains(0), arguments.allSatisfy({ !$0.utf8.contains(0) }),
              environment.allSatisfy({ !$0.key.contains("=") && !$0.key.utf8.contains(0) && !$0.value.utf8.contains(0) }) else { throw GitCredentialFailure.transport }
        var pipes: [Int32] = []
        defer { for fd in pipes { Darwin.close(fd) } }
        for _ in 0..<(guarded ? 5 : 3) {
            var pair: [Int32] = [-1, -1]
            guard Darwin.pipe(&pair) == 0 else { throw GitCredentialFailure.transport }
            pipes += pair
            for fd in pair { guard fcntl(fd, F_SETFD, FD_CLOEXEC) == 0 else { throw GitCredentialFailure.transport } }
        }
        var actions: posix_spawn_file_actions_t?, attributes: posix_spawnattr_t?
        guard posix_spawn_file_actions_init(&actions) == 0 else { throw GitCredentialFailure.transport }
        defer { posix_spawn_file_actions_destroy(&actions) }
        guard posix_spawnattr_init(&attributes) == 0 else { throw GitCredentialFailure.transport }
        defer { posix_spawnattr_destroy(&attributes) }
        // Dispatch workers block signals. A child that inherits that mask — GCM in
        // particular — waits forever instead of returning a cached credential.
        var mask = sigset_t()
        guard sigemptyset(&mask) == 0,
              posix_spawnattr_setsigmask(&attributes, &mask) == 0,
              posix_spawnattr_setflags(&attributes, Int16(POSIX_SPAWN_SETPGROUP | POSIX_SPAWN_CLOEXEC_DEFAULT | POSIX_SPAWN_SETSIGMASK)) == 0,
              posix_spawnattr_setpgroup(&attributes, 0) == 0 else { throw GitCredentialFailure.transport }
        for (fd, target) in [(pipes[0], Int32(0)), (pipes[3], Int32(1)), (pipes[5], Int32(2))] {
            guard posix_spawn_file_actions_adddup2(&actions, fd, target) == 0 else { throw GitCredentialFailure.transport }
        }
        for (index, fd) in pipes.enumerated() where !guarded || (index != 6 && index != 9) {
            guard posix_spawn_file_actions_addclose(&actions, fd) == 0 else { throw GitCredentialFailure.transport }
        }
        if guarded {
            for (fd, target) in [(pipes[6], Int32(3)), (pipes[9], Int32(4))] {
                guard posix_spawn_file_actions_adddup2(&actions, fd, target) == 0,
                      posix_spawn_file_actions_addclose(&actions, fd) == 0 else { throw GitCredentialFailure.transport }
            }
        }
        let launched: String
        let launchedArguments: [String]
        if guarded {
            guard let own = Bundle.main.executableURL else { throw GitCredentialFailure.transport }
            let candidate = own.lastPathComponent.contains("Tests") ? own.deletingLastPathComponent().appendingPathComponent("adevcontainer") : own
            launched = candidate.resolvingSymlinksInPath().path
            launchedArguments = ["__adevcontainer_credential_guard", deadline.map(String.init(describing:)) ?? "none", executable] + arguments
        } else { launched = executable; launchedArguments = arguments }
        var argv = ([launched] + launchedArguments).map { strdup($0) } + [nil]
        // Foundation's ordinary runner merges with parent env. This boundary must
        // instead pass the exact sanitized environment, never a token override.
        var sanitized = environment; sanitized.removeValue(forKey: "ADEVCONTAINER_GIT_TOKEN")
        var envp = sanitized.keys.sorted().map { strdup("\($0)=\(sanitized[$0]!)") } + [nil]
        defer { for p in argv { free(p) }; for p in envp { free(p) } }
        var child: pid_t = 0
        let status = argv.withUnsafeMutableBufferPointer { argv in envp.withUnsafeMutableBufferPointer { envp in
            posix_spawn(&child, launched, &actions, &attributes, argv.baseAddress, envp.baseAddress)
        } }
        guard status == 0 else { throw GitCredentialFailure.transport }
        for fd in [pipes[1], pipes[2], pipes[4]] + (guarded ? [pipes[8]] : []) {
            guard fcntl(fd, F_SETFL, fcntl(fd, F_GETFL) | O_NONBLOCK) == 0 else {
                kill(-child, SIGKILL); var status: Int32 = 0; while waitpid(child, &status, 0) < 0 && errno == EINTR {}
                throw GitCredentialFailure.transport
            }
        }
        guard fcntl(pipes[1], F_SETNOSIGPIPE, 1) == 0 else {
            kill(-child, SIGKILL); var status: Int32 = 0; while waitpid(child, &status, 0) < 0 && errno == EINTR {}
            throw GitCredentialFailure.transport
        }
        pid = child; input = pipes[1]; output = pipes[2]; errors = pipes[4]
        alive = guarded ? pipes[7] : nil; childStatus = guarded ? pipes[8] : nil
        for fd in [pipes[0], pipes[3], pipes[5]] + (guarded ? [pipes[6], pipes[9]] : []) { Darwin.close(fd) }; pipes.removeAll()
    }
    deinit { cancel(); if !inputClosed { Darwin.close(input) }; Darwin.close(output); Darwin.close(errors); if let alive { Darwin.close(alive) }; if let childStatus { Darwin.close(childStatus) } }
    func send(_ data: Data) throws {
        state.lock(); defer { state.unlock() }
        guard result == nil, !inputClosing, data.count <= 1024 * 1024 - pending.count else { throw GitCredentialFailure.overloaded }
        pending.append(data)
    }
    func closeInput() { state.lock(); inputClosing = true; state.unlock() }
    func read(deadline: TimeInterval, cancelOnTimeout: Bool = true) throws -> Data? {
        reader.lock(); defer { reader.unlock() }
        var buffer = [UInt8](repeating: 0, count: 16384)
        while true {
            if ProcessInfo.processInfo.systemUptime >= deadline {
                if cancelOnTimeout { cancel(deadline: ProcessInfo.processInfo.systemUptime) }
                throw GitCredentialFailure.deadline
            }
            state.lock()
            if result != nil { state.unlock(); throw GitCredentialFailure.transport }
            if inputClosing && pending.isEmpty && !inputClosed { Darwin.close(input); inputClosed = true }
            let writable = !inputClosed && !pending.isEmpty
            state.unlock()
            if outputEOF && errorEOF { return nil }
            var fds = [pollfd(fd: outputEOF ? -1 : output, events: Int16(POLLIN), revents: 0),
                       pollfd(fd: errorEOF ? -1 : errors, events: Int16(POLLIN), revents: 0),
                       pollfd(fd: writable ? input : -1, events: Int16(POLLOUT), revents: 0)]
            let ready = poll(&fds, 3, 25)
            if ready < 0 { if errno == EINTR { continue }; cancel(); throw GitCredentialFailure.transport }
            if fds[2].revents != 0 {
                state.lock()
                let written = pending.withUnsafeBytes { Darwin.write(input, $0.baseAddress, $0.count) }
                if written > 0 { pending.removeFirst(written) }
                let failed = written < 0 && errno != EAGAIN && errno != EINTR
                state.unlock()
                if failed { cancel(); throw GitCredentialFailure.transport }
            }
            if fds[1].revents != 0 {
                let count = Darwin.read(errors, &buffer, buffer.count)
                if count == 0 { errorEOF = true }
                else if count < 0 && errno != EAGAIN && errno != EINTR { cancel(); throw GitCredentialFailure.transport }
                // Raw stderr is discarded: neither retained nor teed.
            }
            if fds[0].revents != 0 {
                let count = Darwin.read(output, &buffer, buffer.count)
                if count > 0 { return Data(buffer.prefix(count)) }
                if count == 0 { outputEOF = true }
                else if errno != EAGAIN && errno != EINTR { cancel(); throw GitCredentialFailure.transport }
            }
        }
    }
    @discardableResult func cancel(deadline: TimeInterval? = nil) -> Int32 {
        state.lock(); defer { state.unlock() }
        if let result { return result }
        let end = deadline ?? ProcessInfo.processInfo.systemUptime + Self.cancelBound
        // Spawn atomically established the group. Do not reap before signaling:
        // retaining the leader PID prevents a reused PID/group from being killed.
        kill(-pid, SIGKILL)
        var status: Int32 = 0
        while true {
            let waited = waitpid(pid, &status, WNOHANG)
            if waited == pid { break }
            if waited < 0 && errno != EINTR { break }
            guard ProcessInfo.processInfo.systemUptime < end else {
                // The group was signaled; never hold an exit path past its
                // deadline. A later cancel retries the non-blocking reap.
                pending.removeAll(); return 137
            }
            Thread.sleep(forTimeInterval: 0.01)
        }
        var exit = (status & 0x7f) == 0 ? (status >> 8) & 0xff : 128 + (status & 0x7f)
        if let childStatus {
            var bytes = [UInt8](repeating: 0, count: 8)
            if Darwin.read(childStatus, &bytes, bytes.count) == 8, Array(bytes.prefix(7)) == [71,67,83,49,0,0,0] { exit = Int32(bytes[7]) }
        }
        result = exit; pending.removeAll(); return exit
    }
}
