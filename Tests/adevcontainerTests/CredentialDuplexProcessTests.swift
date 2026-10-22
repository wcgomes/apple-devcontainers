import Foundation
import Darwin
@testable import ADevContainerLib

@MainActor let credentialDuplexProcessTests: [(String, () throws -> Void)] = [
    ("credentials.process.duplexAndStderr", {
        let process = try CredentialDuplexProcess(executable: "/bin/sh", arguments: ["-c", "dd if=/dev/zero bs=1024 count=128 >&2 2>/dev/null; cat"], environment: ["PATH": "/usr/bin:/bin"])
        defer { process.cancel() }
        let input = Data(repeating: 65, count: 32000)
        try process.send(input); process.closeInput()
        var output = Data()
        while let chunk = try process.read(deadline: ProcessInfo.processInfo.systemUptime + 3) { output.append(chunk) }
        try MiniTest.expectEqual(output, input)
        try MiniTest.expectEqual(process.cancel(), 0)
        let inverted = try CredentialDuplexProcess(executable: "/bin/sh", arguments: ["-c", "IFS= read -r a; IFS= read -r b; printf '%s\\n%s\\n' \"$b\" \"$a\""], environment: [:])
        defer { inverted.cancel() }
        try inverted.send(Data("one\ntwo\n".utf8)); inverted.closeInput()
        var replies = Data()
        while let chunk = try inverted.read(deadline: ProcessInfo.processInfo.systemUptime + 3) { replies.append(chunk) }
        try MiniTest.expectEqual(String(decoding: replies, as: UTF8.self), "two\none\n")
    }),
    ("credentials.process.hungDescendantCancellation", {
        let process = try CredentialDuplexProcess(executable: "/bin/sh", arguments: ["-c", "sleep 60 & printf '%s\\n' $!; wait"], environment: ["PATH": "/usr/bin:/bin"])
        defer { process.cancel() }
        guard let data = try process.read(deadline: ProcessInfo.processInfo.systemUptime + 2), let pid = Int32(String(decoding: data, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)) else { throw MiniTest.Failure(message: "synthetic child did not report PID") }
        try MiniTest.expectThrows({ _ = try process.read(deadline: ProcessInfo.processInfo.systemUptime + 0.1) }, validate: { error in try MiniTest.expectEqual(error as? GitCredentialFailure, .deadline) })
        process.cancel()
        // A child may briefly be a reparented zombie, but must not remain a running sleeper.
        let check = try FoundationProcessRunner().run(executable: "/bin/ps", arguments: ["-p", "\(pid)", "-o", "stat="], environment: [:], currentDirectory: nil)
        try MiniTest.expect(!check.succeeded || check.stdoutString.trimmingCharacters(in: .whitespacesAndNewlines).hasPrefix("Z") || check.stdoutString.isEmpty)
    }),
    ("credentials.process.cancelHonorsDeadline", {
        let process = try CredentialDuplexProcess(executable: "/bin/sleep", arguments: ["30"], environment: ["PATH": "/usr/bin:/bin"])
        let started = ProcessInfo.processInfo.systemUptime
        // Deliberately expired: the group is still signalled, but the caller
        // must never block waiting for an exit it may not observe.
        let code = process.cancel(deadline: started - 1)
        let elapsed = ProcessInfo.processInfo.systemUptime - started
        try MiniTest.expectEqual(code, 137)
        try MiniTest.expect(elapsed < 1, "a bounded cancel blocked for \(elapsed)s")
        // A later call may retry the non-blocking reap without changing the outcome.
        try MiniTest.expectEqual(process.cancel(), 137)
    }),
    ("credentials.process.spawnClearsBlockedSignalMask", {
        // Production gets acquire on a Dispatch worker, which blocks signals.
        // GCM inherits that mask and never returns. The child must start unblocked.
        let ready = DispatchSemaphore(value: 0)
        var reported = ""
        var caught: Error?
        DispatchQueue.global(qos: .userInitiated).async {
            var blocked = sigset_t(), previous = sigset_t()
            sigfillset(&blocked)
            sigprocmask(SIG_SETMASK, &blocked, &previous)
            defer { sigprocmask(SIG_SETMASK, &previous, nil) }
            do {
                let process = try CredentialDuplexProcess(executable: "/usr/bin/python3", arguments: ["-c", """
import ctypes
libc = ctypes.CDLL("/usr/lib/libSystem.B.dylib")
current = ctypes.c_uint32()
libc.sigprocmask(0, None, ctypes.byref(current))
print(current.value)
"""], environment: ["PATH": "/usr/bin:/bin"], guarded: true)
                defer { process.cancel() }
                process.closeInput()
                var output = Data()
                while let chunk = try process.read(deadline: ProcessInfo.processInfo.systemUptime + 3) { output.append(chunk) }
                reported = String(decoding: output, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
            } catch { caught = error }
            ready.signal()
        }
        try MiniTest.expect(ready.wait(timeout: .now() + 5) == .success)
        if let caught { throw caught }
        try MiniTest.expectEqual(reported, "0")
    }),
    ("credentials.process.boundsAndSafeFailure", {
        try MiniTest.expectThrows({ _ = try CredentialDuplexProcess(executable: "/does-not-exist-synthetic", arguments: [], environment: [:]) }, validate: { error in
            try MiniTest.expectEqual(error as? GitCredentialFailure, .transport)
            try MiniTest.expect(!String(describing: error).contains("synthetic"))
        })
        let process = try CredentialDuplexProcess(executable: "/bin/cat", arguments: [], environment: [:]); defer { process.cancel() }
        try MiniTest.expectThrows({ try process.send(Data(repeating: 0, count: 1024 * 1024 + 1)) }, validate: { _ in })
    })
]
