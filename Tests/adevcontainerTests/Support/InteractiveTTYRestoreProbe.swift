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
/// When `ADEVCONTAINER_TTY_STDIN_PROBE=1`, the child **reads stdin** and exits 0 only if it
/// receives the marker bytes written to the PTY master — proving foreground claim + group
/// SIGCONT actually deliver keyboard input (not only that a sleep child exits).
///
/// `launchUnderPTY()` / `launchStdinProbeUnderPTY()` start this binary via macOS `script` or
/// python `pty` so CI gets a real PTY even when the suite's own stdin is a pipe.
enum InteractiveTTYRestoreProbe {
    struct Result: Sendable {
        var exitCode: Int32
        var detail: String
    }

    /// Marker written to the PTY master for the stdin-read probe.
    static let stdinMarker = "ADEV_STDIN_OK"

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

    /// Probe body: interactive child must **read** marker bytes from inherited TTY stdin.
    /// Without a verified foreground claim + process-group SIGCONT, the child stops on
    /// SIGTTIN and never consumes input (the `exec -it` freeze).
    static func runStdinRead() -> Int32 {
        #if canImport(Darwin)
        guard InteractiveProcessRunner.stdinIsTTY() else {
            FileHandle.standardError.write(Data("STDIN_PROBE_FAIL not a tty\n".utf8))
            return 30
        }
        let beforeFG = tcgetpgrp(STDIN_FILENO)
        let beforeUs = getpgrp()
        guard beforeFG == beforeUs, beforeUs > 0 else {
            FileHandle.standardError.write(
                Data("STDIN_PROBE_FAIL not foreground at start fg=\(beforeFG) us=\(beforeUs)\n".utf8)
            )
            return 31
        }

        // Read one line from stdin; succeed only if it starts with the launcher marker.
        // Timeout via alarm-equivalent: python select so a hung SIGTTIN child fails the suite.
        let script = """
        import os, select, sys
        marker = \(String(reflecting: stdinMarker))
        # Wait up to 3s for bytes on fd 0; SIGTTIN-stopped children never become readable.
        r, _, _ = select.select([sys.stdin], [], [], 3.0)
        if not r:
            sys.stderr.write("STDIN_PROBE_FAIL timeout waiting for stdin\\n")
            sys.exit(2)
        data = sys.stdin.readline()
        if data.startswith(marker):
            sys.stdout.write("STDIN_OK received\\n")
            sys.exit(0)
        sys.stderr.write(f"STDIN_PROBE_FAIL bad data={data!r}\\n")
        sys.exit(3)
        """
        do {
            let result = try InteractiveProcessRunner().run(
                executable: "/usr/bin/python3",
                arguments: ["-c", script],
                environment: nil,
                currentDirectory: nil,
                stdinData: nil
            )
            guard result.exitCode == 0 else {
                FileHandle.standardError.write(
                    Data("STDIN_PROBE_FAIL child exit \(result.exitCode)\n".utf8)
                )
                return 32
            }
        } catch {
            FileHandle.standardError.write(
                Data("STDIN_PROBE_FAIL launch \(error)\n".utf8)
            )
            return 33
        }

        let afterFG = tcgetpgrp(STDIN_FILENO)
        let afterUs = getpgrp()
        guard afterFG == afterUs else {
            FileHandle.standardError.write(
                Data("STDIN_PROBE_FAIL parent not foreground after restore fg=\(afterFG) us=\(afterUs)\n".utf8)
            )
            return 34
        }
        let line = "STDIN_OK probe complete\n"
        let n = line.withCString { write(STDOUT_FILENO, $0, line.utf8.count) }
        guard n == line.utf8.count else {
            FileHandle.standardError.write(Data("STDIN_PROBE_FAIL write after restore\n".utf8))
            return 35
        }
        return 0
        #else
        FileHandle.standardError.write(Data("STDIN_PROBE_FAIL unsupported platform\n".utf8))
        return 36
        #endif
    }

    /// Launch this test binary under a PTY with the restore-probe env var set.
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

    /// Launch stdin-read probe under a PTY and write the marker to the master.
    /// Requires python3 (needs a writable PTY master; `script` wires master to null stdin).
    static func launchStdinProbeUnderPTY() -> Result {
        let binary = CommandLine.arguments[0]
        let fm = FileManager.default
        guard fm.isExecutableFile(atPath: binary) else {
            return Result(exitCode: 40, detail: "test binary not executable: \(binary)")
        }
        guard fm.isExecutableFile(atPath: "/usr/bin/python3") else {
            return Result(exitCode: 41, detail: "python3 required for stdin PTY probe")
        }
        return runPythonStdinPTYProbe(binary: binary)
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

    private static func runPythonStdinPTYProbe(binary: String) -> Result {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/python3")
        // pty.fork → session leader with controlling TTY; write marker after child claims FG.
        let py = """
        import os, pty, select, sys, time

        bin = sys.argv[1]
        marker = sys.argv[2]
        env = os.environ.copy()
        env["ADEVCONTAINER_TTY_STDIN_PROBE"] = "1"

        pid, master = pty.fork()
        if pid == 0:
            os.execve(bin, [bin], env)
            os._exit(127)

        output = bytearray()
        # Wait until InteractiveProcessRunner child is up and blocked in select/read.
        time.sleep(0.2)
        try:
            os.write(master, (marker + "\\n").encode())
        except OSError as e:
            sys.stderr.write(f"launcher write failed: {e}\\n")
            try:
                os.close(master)
            except OSError:
                pass
            os.waitpid(pid, 0)
            sys.exit(42)

        deadline = time.time() + 5.0
        status = None
        master_eof = False
        while time.time() < deadline and status is None:
            r, _, _ = select.select([master], [], [], 0.1)
            if r:
                try:
                    chunk = os.read(master, 4096)
                except OSError:
                    chunk = b""
                if not chunk:
                    master_eof = True
                else:
                    output.extend(chunk)
            wpid, st = os.waitpid(pid, os.WNOHANG)
            if wpid == pid:
                status = st
                break
            # Child closed the slave (EOF) — reap with a short blocking wait.
            if master_eof:
                try:
                    wpid, st = os.waitpid(pid, 0)
                    if wpid == pid:
                        status = st
                except ChildProcessError:
                    pass
                break

        # Drain any remaining master output after exit.
        if status is not None:
            drain_end = time.time() + 0.3
            while time.time() < drain_end:
                r, _, _ = select.select([master], [], [], 0.05)
                if not r:
                    break
                try:
                    chunk = os.read(master, 4096)
                except OSError:
                    break
                if not chunk:
                    break
                output.extend(chunk)

        try:
            os.close(master)
        except OSError:
            pass

        if status is None:
            try:
                os.kill(pid, 9)
            except OSError:
                pass
            try:
                os.waitpid(pid, 0)
            except ChildProcessError:
                pass
            sys.stderr.write("launcher timeout waiting for probe\\n")
            sys.stderr.write(output.decode(errors="replace"))
            sys.exit(43)

        if os.WIFEXITED(status):
            rc = os.WEXITSTATUS(status)
        elif os.WIFSIGNALED(status):
            rc = 128 + os.WTERMSIG(status)
        else:
            rc = 1
        sys.stdout.write(output.decode(errors="replace"))
        sys.exit(rc)
        """
        process.arguments = ["-c", py, binary, stdinMarker]
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
