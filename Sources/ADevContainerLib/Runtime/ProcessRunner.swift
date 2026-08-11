import Foundation
#if canImport(Darwin)
import Darwin
#endif

public enum ProcessTerminationReason: String, Equatable, Sendable {
    case exited
    case signal
    /// An explicit closed-input process seam reached EOF before a successful exit. Normal
    /// terminal Ctrl-D/editor behavior is not observable through Foundation's inherited TTY;
    /// that path is therefore reported as `.exited` and handled as a normal editor exit.
    ///
    /// Foundation's Process API cannot infer this for every terminal/editor setup, but the
    /// reason is part of the process seam so interactive runners can report an explicit EOF
    /// without conflating it with a normal saved editor exit.
    case eof
}

public struct ProcessResult: Equatable, Sendable {
    public var exitCode: Int32
    public var stdout: Data
    public var stderr: Data
    public var terminationReason: ProcessTerminationReason

    public init(
        exitCode: Int32,
        stdout: Data,
        stderr: Data,
        terminationReason: ProcessTerminationReason = .exited
    ) {
        self.exitCode = exitCode
        self.stdout = stdout
        self.stderr = stderr
        self.terminationReason = terminationReason
    }

    public var stdoutString: String {
        String(data: stdout, encoding: .utf8) ?? ""
    }

    public var stderrString: String {
        String(data: stderr, encoding: .utf8) ?? ""
    }

    public var succeeded: Bool { exitCode == 0 }
}

public protocol ProcessRunning: Sendable {
    func run(
        executable: String,
        arguments: [String],
        environment: [String: String]?,
        currentDirectory: String?,
        stdinData: Data?
    ) throws -> ProcessResult
}

/// Runners that can tee child output to the host while still capturing it.
/// Used by lifecycle exec and (via `FoundationProcessRunner`) long-running container CLI ops.
public protocol StreamTeeingProcessRunning: ProcessRunning {
    func run(
        executable: String,
        arguments: [String],
        environment: [String: String]?,
        currentDirectory: String?,
        stdinData: Data?,
        streamStderr: Bool,
        teeStdoutToStderr: Bool
    ) throws -> ProcessResult
}

extension ProcessRunning {
    /// Convenience: no stdin payload.
    public func run(
        executable: String,
        arguments: [String],
        environment: [String: String]?,
        currentDirectory: String?
    ) throws -> ProcessResult {
        try run(
            executable: executable,
            arguments: arguments,
            environment: environment,
            currentDirectory: currentDirectory,
            stdinData: nil
        )
    }
}

public struct FoundationProcessRunner: StreamTeeingProcessRunning {
    public init() {}

    public func run(
        executable: String,
        arguments: [String],
        environment: [String: String]?,
        currentDirectory: String?,
        stdinData: Data?
    ) throws -> ProcessResult {
        try run(
            executable: executable,
            arguments: arguments,
            environment: environment,
            currentDirectory: currentDirectory,
            stdinData: stdinData,
            streamStderr: false,
            teeStdoutToStderr: false
        )
    }

    /// When `streamStderr` is true, tee child stderr to the host while still capturing it.
    /// When `teeStdoutToStderr` is true, also tee child stdout to host stderr (keeps host
    /// stdout pure for `--json`) while still capturing stdout for diagnostics.
    public func run(
        executable: String,
        arguments: [String],
        environment: [String: String]?,
        currentDirectory: String?,
        stdinData: Data? = nil,
        streamStderr: Bool,
        teeStdoutToStderr: Bool = false
    ) throws -> ProcessResult {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: executable)
        process.arguments = arguments

        var env = ProcessInfo.processInfo.environment
        if let environment {
            for (k, v) in environment {
                env[k] = v
            }
        }
        process.environment = env

        if let currentDirectory {
            process.currentDirectoryURL = URL(fileURLWithPath: currentDirectory)
        }

        let outPipe = Pipe()
        let errPipe = Pipe()
        process.standardOutput = outPipe
        process.standardError = errPipe

        let stdinPipe: Pipe?
        if stdinData != nil {
            let pipe = Pipe()
            process.standardInput = pipe
            stdinPipe = pipe
        } else {
            process.standardInput = FileHandle.nullDevice
            stdinPipe = nil
        }
        _ = stdinPipe

        // Drain pipes while the process runs to avoid pipe-buffer deadlock.
        final class DataBox: @unchecked Sendable {
            var value = Data()
        }
        let stdoutBox = DataBox()
        let stderrBox = DataBox()
        let group = DispatchGroup()

        group.enter()
        DispatchQueue.global(qos: .userInitiated).async {
            let handle = outPipe.fileHandleForReading
            if teeStdoutToStderr {
                var accumulated = Data()
                while true {
                    let chunk = handle.availableData
                    if chunk.isEmpty { break }
                    accumulated.append(chunk)
                    // Host stderr: progress/hook logs must not pollute `--json` stdout.
                    try? FileHandle.standardError.write(contentsOf: chunk)
                }
                stdoutBox.value = accumulated
            } else {
                stdoutBox.value = handle.readDataToEndOfFile()
            }
            group.leave()
        }
        group.enter()
        DispatchQueue.global(qos: .userInitiated).async {
            let handle = errPipe.fileHandleForReading
            if streamStderr {
                var accumulated = Data()
                while true {
                    let chunk = handle.availableData
                    if chunk.isEmpty { break }
                    accumulated.append(chunk)
                    try? FileHandle.standardError.write(contentsOf: chunk)
                }
                stderrBox.value = accumulated
            } else {
                stderrBox.value = handle.readDataToEndOfFile()
            }
            group.leave()
        }

        do {
            try process.run()
        } catch {
            try? stdinPipe?.fileHandleForWriting.close()
            throw CLIError(
                code: CLIErrorCode.runtimeFailed,
                message: "Failed to launch \(executable): \(error.localizedDescription)",
                hint: "Ensure the binary exists and is executable"
            )
        }

        // Launch first, then stream bounded chunks while stdout/stderr are already being
        // drained. Writing the complete payload before launch can deadlock above the pipe
        // capacity when recovery configs exceed 64 KiB.
        let stdinGroup = DispatchGroup()
        if let stdinData, let stdinPipe {
            stdinGroup.enter()
            DispatchQueue.global(qos: .userInitiated).async {
                let handle = stdinPipe.fileHandleForWriting
                let chunkSize = 32 * 1024
                var offset = 0
                while offset < stdinData.count {
                    let end = min(offset + chunkSize, stdinData.count)
                    do {
                        try handle.write(contentsOf: stdinData.subdata(in: offset..<end))
                    } catch {
                        break
                    }
                    offset = end
                }
                try? handle.close()
                stdinGroup.leave()
            }
        }

        process.waitUntilExit()
        stdinGroup.wait()
        group.wait()
        return ProcessResult(
            exitCode: process.terminationStatus,
            stdout: stdoutBox.value,
            stderr: stderrBox.value,
            terminationReason: process.terminationReason == .uncaughtSignal ? .signal : .exited
        )
    }
}

/// Process runner that inherits stdio for interactive `exec` sessions and local TTY editors.
///
/// Inheriting `FileHandle.standardInput/Output/Error` alone is not enough for full-screen
/// editors (`nano`/`vi`): Foundation launches the child in its own process group while the
/// parent remains the terminal's foreground group. The editor then receives `SIGTTIN`/`SIGTTOU`,
/// stops (`STAT=T`), and the parent hangs in `waitUntilExit` with no UI on the caller's TTY.
/// When stdin is a TTY and this is a true interactive launch (no `stdinData` pipe), the runner
/// claims the foreground process group for the child for the duration of the wait and restores
/// the caller's process group afterwards — **before** any further parent stdout/stderr writes.
///
/// Restore must ignore `SIGTTOU` only around `tcsetpgrp`. After the child exits the parent is
/// no longer the TTY foreground group; a bare `tcsetpgrp` (or the next `==>` status line) would
/// stop the process and surface as zsh `suspended (tty output)`.
public struct InteractiveProcessRunner: ProcessRunning {
    public init() {}

    public func run(
        executable: String,
        arguments: [String],
        environment: [String: String]?,
        currentDirectory: String?,
        stdinData: Data?
    ) throws -> ProcessResult {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: executable)
        process.arguments = arguments

        var env = ProcessInfo.processInfo.environment
        if let environment {
            for (k, v) in environment {
                env[k] = v
            }
        }
        process.environment = env

        if let currentDirectory {
            process.currentDirectoryURL = URL(fileURLWithPath: currentDirectory)
        }

        // Normal interactive sessions inherit the host TTY. A non-nil stdinData is an explicit
        // closed-input seam used by process-level tests and callers that need to exercise EOF;
        // it must not change the normal editor path above.
        let stdinPipe: Pipe?
        let claimForegroundTTY: Bool
        if stdinData != nil {
            let pipe = Pipe()
            process.standardInput = pipe
            stdinPipe = pipe
            claimForegroundTTY = false
        } else {
            process.standardInput = FileHandle.standardInput
            stdinPipe = nil
            claimForegroundTTY = Self.stdinIsTTY()
        }
        process.standardOutput = FileHandle.standardOutput
        process.standardError = FileHandle.standardError

        do {
            try process.run()
        } catch {
            try? stdinPipe?.fileHandleForWriting.close()
            throw CLIError(
                code: CLIErrorCode.runtimeFailed,
                message: "Failed to launch \(executable): \(error.localizedDescription)",
                hint: "Ensure the binary exists and is executable"
            )
        }

        // Record claim before wait; restore in defer so failure/cancel paths also return the TTY
        // to the caller's process group before any parent write after this method returns.
        let foreground = claimForegroundTTY
            ? Self.makeForeground(pid: process.processIdentifier)
            : nil
        defer { foreground?.restore() }

        let stdinGroup = DispatchGroup()
        if let stdinData, let stdinPipe {
            stdinGroup.enter()
            DispatchQueue.global(qos: .userInitiated).async {
                do {
                    if !stdinData.isEmpty {
                        try stdinPipe.fileHandleForWriting.write(contentsOf: stdinData)
                    }
                } catch {
                    // The child may close its input early; process termination still provides
                    // the authoritative signal for success/signal classification below.
                }
                try? stdinPipe.fileHandleForWriting.close()
                stdinGroup.leave()
            }
        }
        process.waitUntilExit()
        stdinGroup.wait()
        // Restore runs via defer immediately after this scope exits — before the caller prints
        // the next progress line. Do not write to the TTY between wait and restore.
        let terminationReason: ProcessTerminationReason
        if process.terminationReason == .uncaughtSignal {
            terminationReason = .signal
        } else if stdinData != nil, process.terminationStatus == 0 {
            terminationReason = .eof
        } else {
            terminationReason = .exited
        }
        return ProcessResult(
            exitCode: process.terminationStatus,
            stdout: Data(),
            stderr: Data(),
            terminationReason: terminationReason
        )
    }

    /// True when fd 0 is a terminal. Editors and interactive `exec` need this for job-control
    /// foreground claims; non-TTY callers must not touch `tcsetpgrp`.
    public static func stdinIsTTY() -> Bool {
        #if canImport(Darwin)
        return isatty(STDIN_FILENO) != 0
        #else
        return false
        #endif
    }

    /// Result of handing the controlling terminal's foreground process group to a child.
    ///
    /// - `previousPGID`: TTY foreground process group at claim time (usually the caller's job).
    /// - `callerPGID`: `getpgrp()` of the process that must write after restore (parent CLI).
    /// - `ttyFD`: controlling terminal fd used for `tcgetpgrp`/`tcsetpgrp`.
    public struct ForegroundClaim: Sendable {
        public let previousPGID: pid_t
        public let callerPGID: pid_t
        public let ttyFD: Int32

        /// Return the TTY foreground to the original caller job so the parent can write again.
        /// Scoped `SIGTTOU`/`SIGTTIN` ignore is required: after the child exits we are not the
        /// foreground group, so bare `tcsetpgrp` would stop us (zsh: suspended (tty output)).
        public func restore() {
            #if canImport(Darwin)
            Self.withJobControlSignalsIgnored {
                // Prefer the pre-claim foreground group (shell/pipeline PGID that owned the TTY).
                // Fall back to the caller's own process group so the parent can always write.
                if previousPGID > 0 {
                    _ = tcsetpgrp(ttyFD, previousPGID)
                }
                let now = tcgetpgrp(ttyFD)
                if now != callerPGID, callerPGID > 0 {
                    _ = tcsetpgrp(ttyFD, callerPGID)
                }
            }
            #endif
        }

        #if canImport(Darwin)
        /// Ignore SIGTTOU/SIGTTIN only for the duration of `body` (tcsetpgrp critical section).
        /// Never leave them ignored permanently — that hides job-control bugs.
        fileprivate static func withJobControlSignalsIgnored(_ body: () -> Void) {
            let previousTTOU = signal(SIGTTOU, SIG_IGN)
            let previousTTIN = signal(SIGTTIN, SIG_IGN)
            defer {
                _ = signal(SIGTTOU, previousTTOU ?? SIG_DFL)
                _ = signal(SIGTTIN, previousTTIN ?? SIG_DFL)
            }
            body()
        }
        #endif
    }

    /// Give `pid`'s process group the controlling TTY so full-screen editors are not stopped
    /// by job control. Safe no-op when stdin is not a TTY. Always pair with `restore()`.
    public static func makeForeground(pid: pid_t) -> ForegroundClaim? {
        #if canImport(Darwin)
        guard isatty(STDIN_FILENO) != 0 else { return nil }
        let ttyFD = STDIN_FILENO
        // Record who owned the TTY and who must own it again after the child exits.
        let previous = tcgetpgrp(ttyFD)
        guard previous >= 0 else { return nil }
        let callerPGID = getpgrp()

        // Child may already be in its own group (Foundation default) or still joining ours.
        // Prefer the child's current PGID; fall back to using the pid as the new group id.
        var childPG = getpgid(pid)
        if childPG < 0 {
            childPG = pid
        }
        if childPG != pid {
            // Best-effort: if still in our group and setpgid is still allowed, detach it.
            _ = setpgid(pid, pid)
            let refreshed = getpgid(pid)
            if refreshed > 0 { childPG = refreshed }
        }

        var claimed = false
        ForegroundClaim.withJobControlSignalsIgnored {
            if tcsetpgrp(ttyFD, childPG) == 0 {
                claimed = true
            }
        }
        guard claimed else { return nil }

        // If the child already stopped on SIGTTIN/SIGTTOU before the claim, continue it.
        _ = kill(pid, SIGCONT)
        return ForegroundClaim(previousPGID: previous, callerPGID: callerPGID, ttyFD: ttyFD)
        #else
        _ = pid
        return nil
        #endif
    }
}
