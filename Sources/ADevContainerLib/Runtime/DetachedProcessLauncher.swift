import Foundation
import Darwin

/// Starts the broker as its own session leader with no inherited terminal.
/// The parent never waits, so the child outlives the invoking CLI.
protocol DetachedProcessLaunching: Sendable {
    /// Returns the child pid. The child owns a new session and `/dev/null` stdio.
    @discardableResult func launch(executable: String, arguments: [String], environment: [String: String]) throws -> Int32
    /// Reaps a child that exited during the readiness window; never blocks.
    func reap(_ process: Int32)
}

extension DetachedProcessLaunching {
    func reap(_ process: Int32) { _ = waitpid(process, nil, WNOHANG) }
}

struct PosixDetachedProcessLauncher: DetachedProcessLaunching {
    func launch(executable: String, arguments: [String], environment: [String: String]) throws -> Int32 {
        guard executable.hasPrefix("/"), arguments.allSatisfy({ !$0.utf8.contains(0) }),
              environment.keys.allSatisfy({ !$0.isEmpty && !$0.contains("=") }) else { throw GitCredentialFailure.invalidContext }
        var actions: posix_spawn_file_actions_t?, attributes: posix_spawnattr_t?
        guard posix_spawn_file_actions_init(&actions) == 0, posix_spawnattr_init(&attributes) == 0 else { throw GitCredentialFailure.transport }
        defer { posix_spawn_file_actions_destroy(&actions); posix_spawnattr_destroy(&attributes) }
        for descriptor: Int32 in [0, 1, 2] {
            guard posix_spawn_file_actions_addopen(&actions, descriptor, "/dev/null", O_RDWR, 0) == 0 else { throw GitCredentialFailure.transport }
        }
        var mask = sigset_t(), inherited = sigset_t()
        guard sigfillset(&mask) == 0, sigemptyset(&inherited) == 0,
              posix_spawnattr_setsigdefault(&attributes, &mask) == 0,
              posix_spawnattr_setsigmask(&attributes, &inherited) == 0,
              posix_spawnattr_setflags(&attributes, Int16(POSIX_SPAWN_SETSID | POSIX_SPAWN_CLOEXEC_DEFAULT | POSIX_SPAWN_SETSIGDEF | POSIX_SPAWN_SETSIGMASK)) == 0 else { throw GitCredentialFailure.transport }
        var argv = ([executable] + arguments).map { strdup($0) } + [nil]
        var envp = environment.keys.sorted().map { strdup("\($0)=\(environment[$0]!)") } + [nil]
        var child: pid_t = 0
        let result = argv.withUnsafeMutableBufferPointer { argv in
            envp.withUnsafeMutableBufferPointer { envp in
                posix_spawn(&child, executable, &actions, &attributes, argv.baseAddress, envp.baseAddress)
            }
        }
        for pointer in argv { free(pointer) }
        for pointer in envp { free(pointer) }
        guard result == 0, child > 0 else { throw GitCredentialFailure.transport }
        return child
    }
}
