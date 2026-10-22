import Foundation
import Darwin

/// Same-executable lifetime guardian. It keeps the process-group leader alive
/// until the complete provider group is killed, including after broker SIGKILL.
/// FD 3 is a byte-free parent-liveness pipe; FD 4 carries only an exit status.
public enum CredentialProcessGuardianEntry {
    public static func run(arguments: [String]) -> Int32? {
        guard arguments.first == "__adevcontainer_credential_guard" else { return nil }
        guard arguments.count >= 3, getpgrp() == getpid(), arguments[2].hasPrefix("/"),
              arguments.allSatisfy({ !$0.utf8.contains(0) }) else { return 1 }
        var alive = stat(), status = stat()
        guard fstat(3, &alive) == 0, alive.st_mode & S_IFMT == S_IFIFO,
              fstat(4, &status) == 0, status.st_mode & S_IFMT == S_IFIFO else { return 1 }
        let deadline: TimeInterval
        if arguments[1] == "none" { deadline = .infinity }
        else {
            guard let value = TimeInterval(arguments[1]), value.isFinite else { return 1 }; deadline = value
        }
        func finish(_ code: Int32) -> Never {
            signal(SIGPIPE, SIG_IGN)
            let bytes: [UInt8] = [71, 67, 83, 49, 0, 0, 0, UInt8(clamping: code)]
            _ = bytes.withUnsafeBytes { Darwin.write(4, $0.baseAddress, $0.count) }
            // Killing our own group also terminates descendants that inherited
            // stdout/stderr; init reaps orphans when the broker is gone.
            kill(0, SIGKILL); _exit(127)
        }
        guard ProcessInfo.processInfo.systemUptime < deadline else { finish(137) }
        var actions: posix_spawn_file_actions_t?, attributes: posix_spawnattr_t?
        guard posix_spawn_file_actions_init(&actions) == 0 else { finish(127) }
        guard posix_spawnattr_init(&attributes) == 0 else { finish(127) }
        // The actual provider inherits this guardian's already-established PG.
        var mask = sigset_t()
        var inherited = sigset_t()
        guard sigemptyset(&mask) == 0, sigprocmask(SIG_SETMASK, nil, &inherited) == 0,
              posix_spawnattr_setsigmask(&attributes, &mask) == 0,
              posix_spawnattr_setflags(&attributes, Int16(POSIX_SPAWN_CLOEXEC_DEFAULT | POSIX_SPAWN_SETSIGMASK)) == 0 else { finish(127) }
        let interactive = ProcessInfo.processInfo.environment["GCM_INTERACTIVE"]
        let mode = interactive == "never" || interactive == "Never" ? "disabled" : (interactive == nil ? "unset" : "other")
        GitCredentialDiag.event("guardian.spawn", "inherited=\(inherited) interactive=\(mode)")
        for fd: Int32 in [0, 1, 2] {
            guard posix_spawn_file_actions_addinherit_np(&actions, fd) == 0 else { finish(127) }
        }
        let executable = arguments[2]
        var argv = Array(arguments.dropFirst(2)).map { strdup($0) } + [nil]
        let environment = ProcessInfo.processInfo.environment.filter { $0.key != "ADEVCONTAINER_GIT_TOKEN" && $0.key != "__CF_USER_TEXT_ENCODING" }
        var envp = environment.keys.sorted().map { strdup("\($0)=\(environment[$0]!)") } + [nil]
        var child: pid_t = 0
        let result = argv.withUnsafeMutableBufferPointer { argv in envp.withUnsafeMutableBufferPointer { envp in
            posix_spawn(&child, executable, &actions, &attributes, argv.baseAddress, envp.baseAddress)
        } }
        for pointer in argv { free(pointer) }; for pointer in envp { free(pointer) }
        posix_spawn_file_actions_destroy(&actions); posix_spawnattr_destroy(&attributes)
        guard result == 0 else { finish(127) }
        while true {
            var peer = pollfd(fd: 3, events: Int16(POLLIN), revents: 0)
            let ready = poll(&peer, 1, 10)
            if ProcessInfo.processInfo.systemUptime >= deadline || peer.revents != 0 || (ready < 0 && errno != EINTR) { finish(137) }
            var status: Int32 = 0
            let exited = waitpid(child, &status, WNOHANG)
            if exited == child { finish((status & 0x7f) == 0 ? (status >> 8) & 0xff : 128 + (status & 0x7f)) }
            if exited < 0 && errno != EINTR { finish(127) }
        }
    }
}
