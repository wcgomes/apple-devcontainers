import Foundation
@testable import ADevContainerLib
#if canImport(Darwin)
import Darwin
#elseif canImport(Glibc)
import Glibc
#endif

private func editorChecker(_ usable: Set<String>) -> (String) -> Bool {
    { usable.contains($0) }
}

nonisolated(unsafe) let recoveryEditorTests: [(String, () throws -> Void)] = [
    ("recoveryEditorUsesVisualBeforeEditorAndFallbacks", {
        let runner = MockProcessRunner()
        let editor = RecoveryEditor(
            environment: ["VISUAL": "/tools/visual", "EDITOR": "/tools/editor", "PATH": "/tools"],
            runner: runner,
            fallbackEditors: ["/usr/bin/nano", "/usr/bin/vi"],
            executableChecker: editorChecker(["/tools/visual", "/tools/editor", "/usr/bin/nano", "/usr/bin/vi"])
        )
        let resolved = try editor.requireEditor()
        try MiniTest.expectEqual(resolved.source, "$VISUAL")
        try MiniTest.expectEqual(resolved.executable, "/tools/visual")
        let outcome = editor.edit(filePath: "/private/tmp/with space/devcontainer.json", isTTY: true)
        try MiniTest.expectEqual(outcome, .normalExit)
        try MiniTest.expectEqual(runner.calls.count, 1)
        try MiniTest.expectEqual(runner.calls[0].executable, "/tools/visual")
        try MiniTest.expectEqual(runner.calls[0].arguments, ["/private/tmp/with space/devcontainer.json"])
    }),

    ("recoveryEditorFallsThroughUnusableVisualToEditorThenFallbacks", {
        let runner = MockProcessRunner()
        let editor = RecoveryEditor(
            environment: ["VISUAL": "/tools/missing", "EDITOR": "/tools/editor", "PATH": "/tools"],
            runner: runner,
            executableChecker: editorChecker(["/tools/editor", "/usr/bin/nano", "/usr/bin/vi"])
        )
        try MiniTest.expectEqual(editor.resolve()?.source, "$EDITOR")

        let fallbackRunner = MockProcessRunner()
        let fallback = RecoveryEditor(
            environment: ["PATH": "/tools"],
            runner: fallbackRunner,
            executableChecker: editorChecker(["/usr/bin/vi"])
        )
        try MiniTest.expectEqual(fallback.resolve()?.executable, "/usr/bin/vi")
    }),

    ("recoveryEditorKeepsEditorArgumentsSeparateFromTempPath", {
        let runner = MockProcessRunner()
        let editor = RecoveryEditor(
            environment: ["VISUAL": "/tools/editor --wait --reuse-window", "PATH": "/tools"],
            runner: runner,
            executableChecker: editorChecker(["/tools/editor"])
        )
        let path = "/private/tmp/a path/devcontainer.json"
        try MiniTest.expectEqual(
            editor.command(for: path),
            ["/tools/editor", "--wait", "--reuse-window", path]
        )
        try MiniTest.expectEqual(editor.edit(filePath: path, isTTY: true), .normalExit)
        try MiniTest.expectEqual(runner.calls[0].arguments, ["--wait", "--reuse-window", path])
    }),

    ("recoveryEditorNeverRunsOutsideTTYOrInJSON", {
        let runner = MockProcessRunner()
        let editor = RecoveryEditor(
            environment: ["VISUAL": "/tools/editor"],
            runner: runner,
            executableChecker: editorChecker(["/tools/editor"])
        )
        try MiniTest.expectEqual(editor.edit(filePath: "/tmp/config", isTTY: false), .notRun)
        try MiniTest.expectEqual(editor.edit(filePath: "/tmp/config", isTTY: true, jsonOutput: true), .notRun)
        try MiniTest.expect(runner.calls.isEmpty)
    }),

    ("recoveryEditorDistinguishesSignalCancellationFromExitFailure", {
        let runner = MockProcessRunner()
        runner.defaultResult = ProcessResult(exitCode: 2, stdout: Data(), stderr: Data())
        let editor = RecoveryEditor(
            environment: ["EDITOR": "/tools/editor"],
            runner: runner,
            executableChecker: editorChecker(["/tools/editor"])
        )
        try MiniTest.expectEqual(editor.edit(filePath: "/tmp/config", isTTY: true), .failed(exitCode: 2))
        runner.defaultResult = ProcessResult(
            exitCode: 2,
            stdout: Data(),
            stderr: Data(),
            terminationReason: .signal
        )
        try MiniTest.expectEqual(editor.edit(filePath: "/tmp/config", isTTY: true), .cancelled)
    }),
    ("recoveryEditorTreatsExplicitEOFAsCancellation", {
        let runner = MockProcessRunner()
        runner.defaultResult = ProcessResult(
            exitCode: 0,
            stdout: Data(),
            stderr: Data(),
            terminationReason: .eof
        )
        let editor = RecoveryEditor(
            environment: ["EDITOR": "/tools/editor"],
            runner: runner,
            executableChecker: editorChecker(["/tools/editor"])
        )
        try MiniTest.expectEqual(editor.edit(filePath: "/tmp/config", isTTY: true), .cancelled)
        try MiniTest.expectEqual(
            editor.edit(filePath: "/tmp/config", isTTY: true).cliError?.code,
            CLIErrorCode.recoveryCancelled
        )
    }),
    ("interactiveRunnerClosedInputReportsRealEOF", {
        let result = try InteractiveProcessRunner().run(
            executable: "/bin/cat",
            arguments: [],
            environment: nil,
            currentDirectory: nil,
            stdinData: Data()
        )
        try MiniTest.expect(result.succeeded)
        try MiniTest.expectEqual(result.terminationReason, .eof)

        // Normal editor use inherits the caller's TTY and does not claim EOF; Foundation
        // exposes terminal Ctrl-D as the editor's ordinary exit rather than an input event.
        let normal = try InteractiveProcessRunner().run(
            executable: "/usr/bin/true",
            arguments: [],
            environment: nil,
            currentDirectory: nil,
            stdinData: nil
        )
        try MiniTest.expectEqual(normal.terminationReason, .exited)
    }),

    ("interactiveRunnerInheritedStdioIsNotNullDevice", {
        // Editor path must inherit the caller's stdio (not redirect to /dev/null). When the
        // harness itself has /dev/null on stdin (common for non-interactive runners), inheriting
        // null is correct — prove identity with the parent fds rather than absolute non-null.
        let script = """
        import os, stat, sys
        # Parent identity is passed as "mode:rdev:ino" triples for fds 0/1/2.
        want = sys.argv[1].split(',')
        for fd, expected in enumerate(want):
            st = os.fstat(fd)
            got = f"{stat.S_IFMT(st.st_mode)}:{st.st_rdev}:{st.st_ino}"
            if got != expected:
                sys.exit(10 + fd)
        sys.exit(0)
        """
        #if canImport(Darwin) || canImport(Glibc)
        func fdIdentity(_ fd: Int32) -> String {
            var st = stat()
            guard fstat(fd, &st) == 0 else { return "missing" }
            return "\(st.st_mode & S_IFMT):\(st.st_rdev):\(st.st_ino)"
        }
        let identity = [0, 1, 2].map { fdIdentity(Int32($0)) }.joined(separator: ",")
        #else
        let identity = "0:0:0,0:0:0,0:0:0"
        #endif
        let result = try InteractiveProcessRunner().run(
            executable: "/usr/bin/python3",
            arguments: ["-c", script, identity],
            environment: nil,
            currentDirectory: nil,
            stdinData: nil
        )
        try MiniTest.expectEqual(
            result.exitCode,
            0,
            "child stdio must match parent identity (exit 10+fd means fd was redirected)"
        )
        try MiniTest.expectEqual(result.terminationReason, .exited)
    }),

    ("interactiveRunnerClaimsForegroundTTYWhenAvailable", {
        // When stdin is a TTY, the child must be the foreground process group; otherwise
        // nano/vi stop on SIGTTIN/SIGTTOU (STAT=T) and the parent hangs with no editor UI.
        // Without a TTY the claim is a no-op and the child simply succeeds.
        let script = """
        import os, sys
        if not os.isatty(0):
            sys.exit(0)
        sys.exit(0 if os.tcgetpgrp(0) == os.getpgrp() else 2)
        """
        let result = try InteractiveProcessRunner().run(
            executable: "/usr/bin/python3",
            arguments: ["-c", script],
            environment: nil,
            currentDirectory: nil,
            stdinData: nil
        )
        try MiniTest.expectEqual(
            result.exitCode,
            0,
            "interactive child must be foreground on a TTY (exit 2 means still background)"
        )
        try MiniTest.expectEqual(result.terminationReason, .exited)
    }),

    ("interactiveRunnerRestoresForegroundAfterChildExits", {
        // After the editor exits the parent must regain the TTY foreground group and be able
        // to write without stopping on SIGTTOU (zsh: suspended (tty output)). Without a TTY
        // the claim is a no-op and this only checks a clean exit.
        let script = """
        import os, sys, time
        # Brief pause so the parent can complete tcsetpgrp before we exit.
        time.sleep(0.05)
        sys.exit(0)
        """
        let result = try InteractiveProcessRunner().run(
            executable: "/usr/bin/python3",
            arguments: ["-c", script],
            environment: nil,
            currentDirectory: nil,
            stdinData: nil
        )
        try MiniTest.expectEqual(result.exitCode, 0)
        try MiniTest.expectEqual(result.terminationReason, .exited)

        #if canImport(Darwin)
        if InteractiveProcessRunner.stdinIsTTY() {
            let fg = tcgetpgrp(STDIN_FILENO)
            let us = getpgrp()
            try MiniTest.expectEqual(
                fg,
                us,
                "parent must regain TTY foreground after interactive child exits (fg=\(fg) us=\(us))"
            )
            // A real write must not stop the process (the failure mode behind zsh suspend).
            let marker = "[adev-tty-restore-ok]\n"
            let written = marker.withCString { write(STDERR_FILENO, $0, marker.utf8.count) }
            try MiniTest.expect(written == marker.utf8.count, "parent stderr write after restore must succeed")
        }
        #endif
    }),

    ("interactiveRunnerPTYRoundTripRestoresWithoutSuspend", {
        // Automated PTY proof: spawn this test binary under a fresh controlling terminal with
        // ADEVCONTAINER_TTY_RESTORE_PROBE=1. The probe runs InteractiveProcessRunner against a
        // short child, then prints a post-exit line and exits 0 only if it still owns the FG
        // group and was not stopped. Requires `script` (macOS) + a built test binary path.
        #if !canImport(Darwin)
        try MiniTest.skip("PTY restore probe requires Darwin")
        #endif
        let probe = InteractiveTTYRestoreProbe.launchUnderPTY()
        try MiniTest.expectEqual(
            probe.exitCode,
            0,
            "PTY restore probe failed (exit \(probe.exitCode)): \(probe.detail)"
        )
        try MiniTest.expect(
            probe.detail.contains("RESTORE_OK"),
            "probe must emit RESTORE_OK after editor-like child exits: \(probe.detail)"
        )
    }),

    ("interactiveRunnerPTYChildReceivesStdinBytes", {
        // Freeze regression: shell can look correct (right user) but accept no keyboard when
        // helpers stay SIGTTIN-stopped. Sleep-only probes miss that — child must read stdin.
        // Launcher uses python pty.fork, writes ADEV_STDIN_OK to the master after claim.
        #if !canImport(Darwin)
        try MiniTest.skip("PTY stdin probe requires Darwin")
        #endif
        let probe = InteractiveTTYRestoreProbe.launchStdinProbeUnderPTY()
        try MiniTest.expectEqual(
            probe.exitCode,
            0,
            "PTY stdin probe failed (exit \(probe.exitCode)): \(probe.detail)"
        )
        try MiniTest.expect(
            probe.detail.contains("STDIN_OK"),
            "probe must confirm child received stdin bytes: \(probe.detail)"
        )
    }),

    ("foregroundClaimRestoreDoesNotLeaveSIGTTOUIgnored", {
        // Scoped ignore only — permanent SIG_IGN would hide later job-control bugs.
        #if canImport(Darwin)
        guard InteractiveProcessRunner.stdinIsTTY() else { return }
        // Ensure default disposition before the claim so we can observe a real restore.
        _ = signal(SIGTTOU, SIG_DFL)
        _ = signal(SIGTTIN, SIG_DFL)
        let child = Process()
        child.executableURL = URL(fileURLWithPath: "/bin/sleep")
        child.arguments = ["0.05"]
        child.standardInput = FileHandle.standardInput
        child.standardOutput = FileHandle.standardOutput
        child.standardError = FileHandle.standardError
        try child.run()
        let claim = InteractiveProcessRunner.makeForeground(pid: child.processIdentifier)
        child.waitUntilExit()
        claim?.restore()
        // signal(2) returns the previous handler. After restore, installing SIG_DFL again
        // should report the previous handler as SIG_DFL (not SIG_IGN).
        let afterTTOU = signal(SIGTTOU, SIG_DFL)
        let afterTTIN = signal(SIGTTIN, SIG_DFL)
        let ignPtr = unsafeBitCast(SIG_IGN, to: Optional<OpaquePointer>.self)
        let ttouPtr = unsafeBitCast(afterTTOU, to: Optional<OpaquePointer>.self)
        let ttinPtr = unsafeBitCast(afterTTIN, to: Optional<OpaquePointer>.self)
        try MiniTest.expect(
            ttouPtr != ignPtr,
            "SIGTTOU must not remain ignored after ForegroundClaim.restore"
        )
        try MiniTest.expect(
            ttinPtr != ignPtr,
            "SIGTTIN must not remain ignored after ForegroundClaim.restore"
        )
        #endif
    }),

    ("recoveryEditorDistinguishesLaunchFailure", {
        let runner = MockProcessRunner()
        runner.throwingHandler = { _ in
            throw CLIError(code: CLIErrorCode.runtimeFailed, message: "launch failed")
        }
        let editor = RecoveryEditor(
            environment: ["EDITOR": "/tools/editor"],
            runner: runner,
            executableChecker: editorChecker(["/tools/editor"])
        )
        try MiniTest.expectEqual(editor.edit(filePath: "/tmp/config", isTTY: true), .launchFailed)
        try MiniTest.expectEqual(editor.edit(filePath: "/tmp/config", isTTY: true).cliError?.code, CLIErrorCode.recoveryUnavailable)
    }),

    ("recoveryEditorReportsNoExecutableWithoutLaunching", {
        let runner = MockProcessRunner()
        let editor = RecoveryEditor(
            environment: ["VISUAL": "/tools/no", "EDITOR": "/tools/no", "PATH": "/tools"],
            runner: runner,
            fallbackEditors: ["/tools/nano", "/tools/vi"],
            executableChecker: editorChecker([])
        )
        try MiniTest.expectEqual(editor.edit(filePath: "/tmp/config", isTTY: true), .noExecutable)
        try MiniTest.expect(runner.calls.isEmpty)
        try MiniTest.expectThrows({ _ = try editor.requireEditor() }, validate: { error in
            try MiniTest.expectEqual((error as? CLIError)?.code, CLIErrorCode.recoveryUnavailable)
        })
    }),

    ("recoveryEditorReturnsInvalidConfigForCallerToReopen", {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("adev-editor-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let file = root.appendingPathComponent("devcontainer.json")
        try Data("{ invalid".utf8).write(to: file)
        let runner = MockProcessRunner()
        let editor = RecoveryEditor(
            environment: ["EDITOR": "/tools/editor"],
            runner: runner,
            executableChecker: editorChecker(["/tools/editor"])
        )
        let outcome = editor.edit(filePath: file.path, isTTY: true) { _ in
            throw CLIError(
                code: CLIErrorCode.configParse,
                message: "invalid edited config"
            )
        }
        guard case .invalidConfig(let error) = outcome else {
            throw MiniTest.Failure(message: "expected invalid config outcome")
        }
        try MiniTest.expectEqual(error.code, CLIErrorCode.configParse)
        try MiniTest.expectEqual(runner.calls.count, 1)
    }),

    // MARK: - §15 Bind host path argument

    ("bindRecoveryEditorOpensHostStampedPathNotTemp", {
        let hostPath = "/Users/me/project/.devcontainer/devcontainer.json"
        let runner = MockProcessRunner()
        let editor = RecoveryEditor(
            environment: ["VISUAL": "/tools/visual", "PATH": "/tools"],
            runner: runner,
            fallbackEditors: ["/usr/bin/nano", "/usr/bin/vi"],
            executableChecker: editorChecker(["/tools/visual", "/usr/bin/nano", "/usr/bin/vi"])
        )
        try MiniTest.expectEqual(
            editor.command(for: hostPath),
            ["/tools/visual", hostPath]
        )
        try MiniTest.expectEqual(editor.edit(filePath: hostPath, isTTY: true), .normalExit)
        try MiniTest.expectEqual(runner.calls.count, 1)
        try MiniTest.expectEqual(runner.calls[0].arguments, [hostPath])
        try MiniTest.expect(!runner.calls[0].arguments.contains { $0.contains("adev-recovery") })
    })
]
