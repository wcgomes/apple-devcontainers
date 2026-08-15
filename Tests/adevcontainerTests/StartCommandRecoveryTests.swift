import Foundation
@testable import ADevContainerLib

/// Injectable prompt: answers consumed in order; empty string = Enter (affirmative),
/// `nil` = EOF (decline). Falls back to EOF once answers are exhausted.
private func startRecoveryPrompt(
    answers: [String?],
    onWrite: (@Sendable (String) -> Void)? = nil
) -> RecoveryOpenEditorPrompt {
    final class Box: @unchecked Sendable {
        var remaining: [String?]
        init(_ answers: [String?]) { remaining = answers }
    }
    let box = Box(answers)
    return RecoveryOpenEditorPrompt(
        readLine: {
            if box.remaining.isEmpty { return nil }
            return box.remaining.removeFirst()
        },
        writeError: { line in onWrite?(line) }
    )
}

private let startRecoveryName = "adev-app-aaaabbbbcccc"

/// Mock runtime: one stopped managed container whose `start` fails (exit 1).
private func startRecoveryRuntime() -> (AppleContainerRuntime, MockProcessRunner) {
    let mock = MockProcessRunner()
    let entry = MockProcessRunner.containerListJSON(
        id: startRecoveryName,
        state: "stopped",
        labels: [ContainerIdentity.labelManaged: ContainerIdentity.managedValue]
    )
    mock.handlers = [
        { args in
            if args.starts(with: ["list"]) {
                return ProcessResult(
                    exitCode: 0,
                    stdout: try! JSONSerialization.data(withJSONObject: [entry]),
                    stderr: Data()
                )
            }
            if args.first == "start" {
                return ProcessResult(exitCode: 1, stdout: Data(), stderr: Data("start failed".utf8))
            }
            return nil
        }
    ]
    return (AppleContainerRuntime(executablePath: "/usr/local/bin/container", runner: mock), mock)
}

private func startRecoveryResult(_ name: String) -> RebuildResult {
    RebuildResult(
        outcome: "success",
        containerId: name,
        remoteUser: "vscode",
        remoteWorkspaceFolder: "/workspaces/app",
        containerName: name
    )
}

nonisolated(unsafe) let startCommandRecoveryTests: [(String, () throws -> Void)] = [
    ("ttyAffirmativeDelegatesToRebuildForSameContainer", {
        let (runtime, _) = startRecoveryRuntime()
        var delegated: RebuildOptions?
        StartCommand.rebuildOverride = { options in
            delegated = options
            return startRecoveryResult(options.name ?? "")
        }
        defer { StartCommand.rebuildOverride = nil }

        try StartCommand.run(
            options: StartOptions(name: startRecoveryName),
            runtime: runtime,
            isTTY: true,
            openEditorPrompt: startRecoveryPrompt(answers: ["y"])
        )
        try MiniTest.expectEqual(delegated?.name, startRecoveryName, "rebuild delegated for the same container")
        try MiniTest.expectEqual(delegated?.jsonOutput, false)
    }),

    ("ttyDeclineRethrowsOriginalErrorWithRebuildHint", {
        let (runtime, _) = startRecoveryRuntime()
        var delegated = false
        StartCommand.rebuildOverride = { _ in
            delegated = true
            return startRecoveryResult(startRecoveryName)
        }
        defer { StartCommand.rebuildOverride = nil }

        try MiniTest.expectThrows({
            try StartCommand.run(
                options: StartOptions(name: startRecoveryName),
                runtime: runtime,
                isTTY: true,
                openEditorPrompt: startRecoveryPrompt(answers: ["n"])
            )
        }) { error in
            let cli = error as! CLIError
            try MiniTest.expectEqual(cli.code, CLIErrorCode.runtimeFailed)
            try MiniTest.expect(cli.message.contains(startRecoveryName), "original start failure message preserved")
            try MiniTest.expect(
                cli.hint?.contains("adevcontainer rebuild --name \(startRecoveryName)") == true,
                "decline carries the rebuild --name hint"
            )
        }
        try MiniTest.expectEqual(delegated, false, "decline must not delegate to rebuild")
    }),

    ("ttyEOFRethrowsOriginalError", {
        let (runtime, _) = startRecoveryRuntime()
        var delegated = false
        StartCommand.rebuildOverride = { _ in
            delegated = true
            return startRecoveryResult(startRecoveryName)
        }
        defer { StartCommand.rebuildOverride = nil }

        try MiniTest.expectThrows({
            try StartCommand.run(
                options: StartOptions(name: startRecoveryName),
                runtime: runtime,
                isTTY: true,
                openEditorPrompt: startRecoveryPrompt(answers: [nil])
            )
        }) { error in
            let cli = error as! CLIError
            try MiniTest.expectEqual(cli.code, CLIErrorCode.runtimeFailed)
            try MiniTest.expect(cli.hint?.contains("adevcontainer rebuild --name") == true)
        }
        try MiniTest.expectEqual(delegated, false, "EOF must not delegate to rebuild")
    }),

    ("nonTTYRethrowsWithRebuildHintWithoutPrompting", {
        let (runtime, _) = startRecoveryRuntime()
        var delegated = false
        StartCommand.rebuildOverride = { _ in
            delegated = true
            return startRecoveryResult(startRecoveryName)
        }
        defer { StartCommand.rebuildOverride = nil }
        final class Writes: @unchecked Sendable { var lines: [String] = [] }
        let writes = Writes()

        try MiniTest.expectThrows({
            try StartCommand.run(
                options: StartOptions(name: startRecoveryName),
                runtime: runtime,
                isTTY: false,
                openEditorPrompt: startRecoveryPrompt(answers: ["y"]) { writes.lines.append($0) }
            )
        }) { error in
            let cli = error as! CLIError
            try MiniTest.expectEqual(cli.code, CLIErrorCode.runtimeFailed)
            try MiniTest.expect(
                cli.hint?.contains("adevcontainer rebuild --name \(startRecoveryName)") == true,
                "non-TTY carries the rebuild --name hint"
            )
        }
        try MiniTest.expectEqual(delegated, false, "non-TTY must not delegate to rebuild")
        try MiniTest.expect(writes.lines.isEmpty, "non-TTY must not print or prompt")
    }),

    ("jsonRethrowsWithRebuildHintWithoutPrompting", {
        let (runtime, _) = startRecoveryRuntime()
        var delegated = false
        StartCommand.rebuildOverride = { _ in
            delegated = true
            return startRecoveryResult(startRecoveryName)
        }
        defer { StartCommand.rebuildOverride = nil }

        try MiniTest.expectThrows({
            try StartCommand.run(
                options: StartOptions(name: startRecoveryName, jsonOutput: true),
                runtime: runtime,
                isTTY: true,
                openEditorPrompt: startRecoveryPrompt(answers: ["y"])
            )
        }) { error in
            let cli = error as! CLIError
            try MiniTest.expectEqual(cli.code, CLIErrorCode.runtimeFailed)
            try MiniTest.expect(cli.hint?.contains("adevcontainer rebuild --name \(startRecoveryName)") == true)
        }
        try MiniTest.expectEqual(delegated, false, "--json must not delegate or prompt")
    }),

    ("ttyAffirmativeNeverOpensEditorOrRerunsStart", {
        let (runtime, mock) = startRecoveryRuntime()
        var delegated = false
        StartCommand.rebuildOverride = { _ in
            delegated = true
            return startRecoveryResult(startRecoveryName)
        }
        defer { StartCommand.rebuildOverride = nil }

        try StartCommand.run(
            options: StartOptions(name: startRecoveryName),
            runtime: runtime,
            isTTY: true,
            openEditorPrompt: startRecoveryPrompt(answers: ["y"])
        )
        try MiniTest.expectEqual(delegated, true, "recovery action is rebuild delegation")
        // Only list + one (failed) start before delegating: no editor exec, no create, no start retry.
        try MiniTest.expectEqual(
            mock.calls.filter { $0.arguments.first == "start" }.count,
            1,
            "start attempted exactly once (not retried)"
        )
        let verbs = Set(mock.calls.map { $0.arguments.first ?? "" })
        try MiniTest.expectEqual(verbs, ["list", "start"], "start recovery only lists and attempts start before delegating")
    }),

    ("startRecoveryViaRebuildDoesNotDoubleRunPostStart", {
        let ws = try TestRepo.makeTempWorkspace(configJSON: """
        {
          "image": "alpine:3.20",
          "postStartCommand": "echo start-recovery-postStart"
        }
        """)
        defer { try? FileManager.default.removeItem(at: ws) }
        let labels: [String: String] = [
            ContainerIdentity.labelManaged: ContainerIdentity.managedValue,
            ContainerIdentity.labelWorkspaceMode: ContainerIdentity.workspaceModeBind,
            ContainerIdentity.labelLocalFolder: ws.path,
            ContainerIdentity.labelConfigFile: ws.appendingPathComponent(".devcontainer/devcontainer.json").path,
            ContainerIdentity.labelWorkspaceFolder: "/workspaces/app"
        ]
        let mock = MockProcessRunner()
        let entry = MockProcessRunner.containerListJSON(
            id: startRecoveryName,
            state: "stopped",
            labels: labels
        )
        mock.handlers = [
            { args in
                if args.starts(with: ["list"]) {
                    return ProcessResult(
                        exitCode: 0,
                        stdout: try! JSONSerialization.data(withJSONObject: [entry]),
                        stderr: Data()
                    )
                }
                if args.first == "start" {
                    return ProcessResult(exitCode: 1, stdout: Data(), stderr: Data("start failed".utf8))
                }
                if args.first == "inspect" {
                    return ProcessResult(
                        exitCode: 0,
                        stdout: try! JSONSerialization.data(withJSONObject: entry),
                        stderr: Data()
                    )
                }
                if args.first == "exec" {
                    return ProcessResult(exitCode: 0, stdout: Data(), stderr: Data())
                }
                return nil
            }
        ]
        let runtime = AppleContainerRuntime(executablePath: "/usr/local/bin/container", runner: mock)
        var rebuildPostStart = 0
        StartCommand.rebuildOverride = { _ in
            rebuildPostStart += 1
            return startRecoveryResult(startRecoveryName)
        }
        defer { StartCommand.rebuildOverride = nil }

        try StartCommand.run(
            options: StartOptions(name: startRecoveryName),
            runtime: runtime,
            isTTY: true,
            openEditorPrompt: startRecoveryPrompt(answers: ["y"])
        )
        try MiniTest.expectEqual(rebuildPostStart, 1, "rebuild create-path owns postStart")
        let startBodies = mock.calls.compactMap { call -> String? in
            guard call.arguments.first == "exec" else { return nil }
            if let lc = call.arguments.firstIndex(of: "-lc"), lc + 1 < call.arguments.count {
                return call.arguments[lc + 1]
            }
            return nil
        }
        try MiniTest.expect(
            !startBodies.contains("echo start-recovery-postStart"),
            "StartCommand must not exec postStart again after rebuild returns"
        )
    }),

    ("startRecoveryAddsNoConfigWritePath", {
        let (runtime, mock) = startRecoveryRuntime()
        var delegated: RebuildOptions?
        StartCommand.rebuildOverride = { options in
            delegated = options
            return startRecoveryResult(options.name ?? "")
        }
        defer { StartCommand.rebuildOverride = nil }

        try StartCommand.run(
            options: StartOptions(name: startRecoveryName),
            runtime: runtime,
            isTTY: true,
            openEditorPrompt: startRecoveryPrompt(answers: ["y"])
        )
        try MiniTest.expectEqual(delegated?.name, startRecoveryName, "start still delegates to rebuild")
        try MiniTest.expect(
            !mock.calls.contains { $0.arguments.first == "exec" || $0.arguments.first == "cp" },
            "start recovery must not write an edited config"
        )
        try MiniTest.expect(
            !mock.calls.contains {
                $0.arguments.contains("adevcontainer-clone-persist")
                    || $0.arguments.contains("adevcontainer-recovery-write")
            },
            "start recovery adds no persist or helper write path"
        )
        try MiniTest.expect(mock.calls.allSatisfy { $0.stdinData == nil }, "start recovery streams no config bytes")
    }),

    ("startDoesNotOfferCreateNameCollision", {
        let mock = MockProcessRunner()
        let managed = MockProcessRunner.containerListJSON(
            id: startRecoveryName,
            state: "running",
            labels: [ContainerIdentity.labelManaged: ContainerIdentity.managedValue]
        )
        let collider = MockProcessRunner.containerListJSON(
            id: "my-app",
            state: "running",
            labels: [:]
        )
        mock.handlers = [
            { args in
                if args.starts(with: ["list"]) {
                    return ProcessResult(
                        exitCode: 0,
                        stdout: try! JSONSerialization.data(withJSONObject: [managed, collider]),
                        stderr: Data()
                    )
                }
                return nil
            }
        ]
        let runtime = AppleContainerRuntime(executablePath: "/usr/local/bin/container", runner: mock)
        final class Writes: @unchecked Sendable { var lines: [String] = [] }
        let writes = Writes()
        try StartCommand.run(
            options: StartOptions(name: startRecoveryName),
            runtime: runtime,
            picker: InteractivePicker(
                isInteractive: true,
                readLine: { "1" },
                writeError: { writes.lines.append($0) }
            ),
            isTTY: true
        )
        let joined = writes.lines.joined()
        try MiniTest.expect(!joined.contains(BringUpRecovery.changeNamePromptText))
        try MiniTest.expect(!joined.contains("not this workspace"))
        try MiniTest.expect(!mock.calls.contains { $0.arguments.first == "create" })
        try MiniTest.expect(!mock.calls.contains { $0.arguments.first == "delete" })
    })
]
