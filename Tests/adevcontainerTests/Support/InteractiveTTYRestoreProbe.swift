import Foundation
@testable import ADevContainerLib
#if canImport(Darwin)
import Darwin
#endif

/// PTY job-control probe for InteractiveProcessRunner claim/restore.
///
/// When `ADEVCONTAINER_TTY_RESTORE_PROBE=1`, the test binary runs `run()` under whatever
/// controlling terminal it was given, launches a short interactive child, then proves the
/// parent regained the foreground group and can write without stopping on SIGTTOU.
///
/// `launchUnderPTY()` starts this binary via macOS `script` so CI gets a real PTY even when
/// the suite's own stdin is a pipe.
enum InteractiveTTYRestoreProbe {
    struct Result: Sendable {
        var exitCode: Int32
        var detail: String
    }

    /// Probe body: editor-like child → restore → parent write → exit 0 on success.
    static func run() -> Int32 {
        #if canImport(Darwin)
        guard InteractiveProcessRunner.stdinIsTTY() else {
            FileHandle.standardError.write(Data("PROBE_FAIL not a tty\n".utf8))
            return 10
        }
        let beforeFG = tcgetpgrp(STDIN_FILENO)
        let beforeUs = getpgrp()
        guard beforeFG == beforeUs, beforeUs > 0 else {
            FileHandle.standardError.write(
                Data("PROBE_FAIL not foreground at start fg=\(beforeFG) us=\(beforeUs)\n".utf8)
            )
            return 11
        }

        do {
            // Short interactive-like child (not a full-screen editor; exercises the same
            // claim/wait/restore path used for nano/vi recovery).
            let result = try InteractiveProcessRunner().run(
                executable: "/usr/bin/python3",
                arguments: ["-c", "import time; time.sleep(0.05)"],
                environment: nil,
                currentDirectory: nil,
                stdinData: nil
            )
            guard result.exitCode == 0 else {
                FileHandle.standardError.write(
                    Data("PROBE_FAIL child exit \(result.exitCode)\n".utf8)
                )
                return 12
            }
        } catch {
            FileHandle.standardError.write(
                Data("PROBE_FAIL launch \(error)\n".utf8)
            )
            return 13
        }

        let afterFG = tcgetpgrp(STDIN_FILENO)
        let afterUs = getpgrp()
        guard afterFG == afterUs else {
            FileHandle.standardError.write(
                Data("PROBE_FAIL parent not foreground after restore fg=\(afterFG) us=\(afterUs)\n".utf8)
            )
            return 14
        }

        // The failure mode behind zsh "suspended (tty output)": write while background.
        let line = "RESTORE_OK post-editor parent write\n"
        let n = line.withCString { write(STDOUT_FILENO, $0, line.utf8.count) }
        guard n == line.utf8.count else {
            FileHandle.standardError.write(Data("PROBE_FAIL write after restore\n".utf8))
            return 15
        }
        return 0
        #else
        FileHandle.standardError.write(Data("PROBE_FAIL unsupported platform\n".utf8))
        return 16
        #endif
    }

    /// Launch this test binary under a PTY with the probe env var set.
    static func launchUnderPTY() -> Result {
        let binary = CommandLine.arguments[0]
        let fm = FileManager.default
        guard fm.isExecutableFile(atPath: binary) else {
            return Result(exitCode: 20, detail: "test binary not executable: \(binary)")
        }

        // macOS `script -q /dev/null <cmd>` allocates a PTY and runs cmd as the session leader.
        // Prefer `script`; fall back to python pty.spawn if script is missing.
        if fm.isExecutableFile(atPath: "/usr/bin/script") {
            return runScriptProbe(binary: binary)
        }
        if fm.isExecutableFile(atPath: "/usr/bin/python3") {
            return runPythonPTYProbe(binary: binary)
        }
        return Result(exitCode: 21, detail: "no PTY launcher (script/python3) available")
    }

    private static func runScriptProbe(binary: String) -> Result {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/script")
        // -q quiet; typescript to /dev/null; run env+probe under the allocated PTY.
        process.arguments = [
            "-q", "/dev/null",
            "/usr/bin/env", "ADEVCONTAINER_TTY_RESTORE_PROBE=1", binary
        ]
        return finish(process)
    }

    private static func runPythonPTYProbe(binary: String) -> Result {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/python3")
        let py = """
        import os, pty, sys
        bin = sys.argv[1]
        env = os.environ.copy()
        env["ADEVCONTAINER_TTY_RESTORE_PROBE"] = "1"
        rc = pty.spawn([bin], env=env)
        sys.exit(rc if isinstance(rc, int) and 0 <= rc < 256 else 1)
        """
        process.arguments = ["-c", py, binary]
        return finish(process)
    }

    private static func finish(_ process: Process) -> Result {
        let out = Pipe()
        let err = Pipe()
        process.standardOutput = out
        process.standardError = err
        process.standardInput = FileHandle.nullDevice
        do {
            try process.run()
        } catch {
            return Result(exitCode: 22, detail: "failed to launch PTY probe: \(error)")
        }
        process.waitUntilExit()
        let stdout = String(data: out.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
        let stderr = String(data: err.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
        let detail = (stdout + stderr).trimmingCharacters(in: .whitespacesAndNewlines)
        return Result(exitCode: process.terminationStatus, detail: detail.isEmpty ? "(no output)" : detail)
    }
}
