import Foundation
@testable import ADevContainerLib

// MARK: - Helpers

/// Fake editor process runner: writes the next payload to the edited config path (the last
/// argument) on each launch. Used to simulate an operator saving a valid (or, in sequence,
/// first invalid then valid) devcontainer.json.
private final class UpRecoveryEditorRunner: ProcessRunning, @unchecked Sendable {
    let payloads: [Data]
    var launches = 0

    init(payloads: [Data]) { self.payloads = payloads }

    func run(
        executable: String,
        arguments: [String],
        environment: [String: String]?,
        currentDirectory: String?,
        stdinData: Data?
    ) throws -> ProcessResult {
        let index = min(launches, payloads.count - 1)
        launches += 1
        if let path = arguments.last {
            try payloads[index].write(to: URL(fileURLWithPath: path))
        }
        return ProcessResult(exitCode: 0, stdout: Data(), stderr: Data())
    }
}

/// Injectable open-editor prompt for TTY recovery tests. Default answers Enter (affirmative);
/// `nil` = EOF (decline).
private func upRecoveryPrompt(
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

/// Configure a runtime mock for the bind `up` create path (no features, skip-pull). The first
/// `createFailuresBeforeSuccess` `create` calls fail (runtime failure) before a successful create.
private func installUpCreatePathHandlers(
    _ mock: MockProcessRunner,
    resolved: ResolvedWorkspace,
    createFailuresBeforeSuccess: Int = 0,
    startFailuresBeforeSuccess: Int = 0,
    ownershipFailuresBeforeSuccess: Int = 0,
    hookFailuresBeforeSuccess: Int = 0
) {
    var creates = 0
    var starts = 0
    var ownershipFailures = 0
    var hookFailures = 0
    mock.handlers = [
        { args in
            if args.starts(with: ["list"]) {
                return ProcessResult(exitCode: 0, stdout: Data("[]".utf8), stderr: Data())
            }
            return nil
        },
        MockProcessRunner.imageInspectHandler(baseUser: nil),
        { args in
            if args.first == "create" {
                if creates < createFailuresBeforeSuccess {
                    creates += 1
                    return ProcessResult(
                        exitCode: 1,
                        stdout: Data(),
                        stderr: Data("port 8080 already in use".utf8)
                    )
                }
                creates += 1
                return ProcessResult(
                    exitCode: 0,
                    stdout: Data("\(resolved.containerName)\n".utf8),
                    stderr: Data()
                )
            }
            return nil
        },
        { args in
            if args.first == "start" {
                if starts < startFailuresBeforeSuccess {
                    starts += 1
                    return ProcessResult(exitCode: 1, stdout: Data(), stderr: Data("start failed".utf8))
                }
                starts += 1
                return ProcessResult(exitCode: 0, stdout: Data(), stderr: Data())
            }
            return nil
        },
        { args in
            guard args.first == "exec" else { return nil }
            let command = args.joined(separator: " ")
            if command.contains("chown") {
                if ownershipFailures < ownershipFailuresBeforeSuccess {
                    ownershipFailures += 1
                    return ProcessResult(exitCode: 1, stdout: Data(), stderr: Data("ownership failed".utf8))
                }
                ownershipFailures += 1
            }
            if args.contains("-lc") {
                if hookFailures < hookFailuresBeforeSuccess {
                    hookFailures += 1
                    return ProcessResult(exitCode: 1, stdout: Data(), stderr: Data("hook failed".utf8))
                }
                hookFailures += 1
            }
            return ProcessResult(exitCode: 0, stdout: Data(), stderr: Data())
        }
    ]
}

private func upRecoveryEditor(
    runner: any ProcessRunning
) -> RecoveryEditor {
    RecoveryEditor(
        environment: ["VISUAL": "/test-editor"],
        runner: runner,
        fallbackEditors: [],
        executableChecker: { _ in true }
    )
}

nonisolated(unsafe) let upCommandRecoveryTests: [(String, () throws -> Void)] = [
    ("upCreateFailureRecoversEditsAndRetries", {
        let workspace = try TestRepo.makeTempWorkspace(configJSON: #"{ "image": "alpine:3.20" }"#)
        defer { try? FileManager.default.removeItem(at: workspace) }
        let mock = MockProcessRunner()
        let resolved = try ConfigResolver.resolve(workspacePath: workspace.path, localEnv: [:])
        installUpCreatePathHandlers(mock, resolved: resolved, createFailuresBeforeSuccess: 1)

        let editorRunner = UpRecoveryEditorRunner(
            payloads: [Data(#"{ "image": "alpine:3.20" }"#.utf8)]
        )
        final class Writes: @unchecked Sendable { var lines: [String] = [] }
        let writes = Writes()
        let runtime = AppleContainerRuntime(executablePath: "/usr/local/bin/container", runner: mock)

        let result = try UpCommand.run(
            options: UpOptions(workspacePath: workspace.path, skipPull: true),
            runtime: runtime,
            localEnv: [:],
            isTTY: true,
            recoveryEditor: upRecoveryEditor(runner: editorRunner),
            openEditorPrompt: upRecoveryPrompt(answers: ["y"]) { writes.lines.append($0) }
        )

        try MiniTest.expectEqual(result.outcome, "success")
        let createCalls = mock.calls.filter { $0.arguments.first == "create" }
        try MiniTest.expectEqual(createCalls.count, 2, "create failed once then retried from scratch")
        // Re-resolve/re-find on retry (findByName → list) proves no cached resolved state.
        let listCalls = mock.calls.filter { $0.arguments.first == "list" }
        try MiniTest.expectEqual(listCalls.count, 2, "retry re-resolves from host (list per attempt)")
        try MiniTest.expectEqual(editorRunner.launches, 1, "editor opened once")
        try MiniTest.expect(
            writes.lines.joined().contains(RecoveryOpenEditorPrompt.promptText),
            "prompt text printed to stderr"
        )
        try MiniTest.expect(
            !mock.calls.contains { $0.arguments.first == "volume" },
            "up recovery must not create a helper container or volume"
        )
    }),

    ("upConfigParseFailureRecoversFromHostConfig", {
        let workspace = try TestRepo.makeTempWorkspace(configJSON: #"{ "image": "alpine:3.20" }"#)
        defer { try? FileManager.default.removeItem(at: workspace) }
        let resolved = try ConfigResolver.resolve(workspacePath: workspace.path, localEnv: [:])
        try #"{ "image": }"#.write(
            to: URL(fileURLWithPath: resolved.configPath),
            atomically: true,
            encoding: .utf8
        )
        let mock = MockProcessRunner()
        installUpCreatePathHandlers(mock, resolved: resolved)
        let editorRunner = UpRecoveryEditorRunner(
            payloads: [Data(#"{ "image": "alpine:3.20" }"#.utf8)]
        )
        let runtime = AppleContainerRuntime(executablePath: "/usr/local/bin/container", runner: mock)

        let result = try UpCommand.run(
            options: UpOptions(workspacePath: workspace.path, skipPull: true),
            runtime: runtime,
            localEnv: [:],
            isTTY: true,
            recoveryEditor: upRecoveryEditor(runner: editorRunner),
            openEditorPrompt: upRecoveryPrompt(answers: ["y"])
        )
        try MiniTest.expectEqual(result.outcome, "success")
        try MiniTest.expectEqual(editorRunner.launches, 1)
        try MiniTest.expectEqual(mock.calls.filter { $0.arguments.first == "create" }.count, 1)
    }),

    ("upRecoveryHintPreservesWorkspaceAndFlags", {
        let workspace = try TestRepo.makeTempWorkspace(configJSON: #"{ "image": "alpine:3.20" }"#)
        defer { try? FileManager.default.removeItem(at: workspace) }
        let mock = MockProcessRunner()
        let resolved = try ConfigResolver.resolve(workspacePath: workspace.path, localEnv: [:])
        installUpCreatePathHandlers(mock, resolved: resolved, createFailuresBeforeSuccess: 1)
        let runtime = AppleContainerRuntime(executablePath: "/usr/local/bin/container", runner: mock)
        try MiniTest.expectThrows({
            _ = try UpCommand.run(
                options: UpOptions(
                    workspacePath: workspace.path,
                    jsonOutput: true,
                    skipPull: true,
                    openVSCode: true
                ),
                runtime: runtime,
                localEnv: [:],
                isTTY: false
            )
        }) { error in
            let hint = (error as? CLIError)?.hint ?? ""
            try MiniTest.expect(hint.contains("adevcontainer up --workspace '") && hint.contains(workspace.path))
            try MiniTest.expect(hint.contains("--json"))
            try MiniTest.expect(hint.contains("--skip-pull"))
            try MiniTest.expect(hint.contains("--vscode"))
        }
    }),

    ("upCreateFailureDeclineRethrowsOriginal", {
        let workspace = try TestRepo.makeTempWorkspace(configJSON: #"{ "image": "alpine:3.20" }"#)
        defer { try? FileManager.default.removeItem(at: workspace) }
        let mock = MockProcessRunner()
        let resolved = try ConfigResolver.resolve(workspacePath: workspace.path, localEnv: [:])
        installUpCreatePathHandlers(mock, resolved: resolved, createFailuresBeforeSuccess: 1)

        let editorRunner = UpRecoveryEditorRunner(payloads: [Data()])
        let runtime = AppleContainerRuntime(executablePath: "/usr/local/bin/container", runner: mock)

        try MiniTest.expectThrows({
            _ = try UpCommand.run(
                options: UpOptions(workspacePath: workspace.path, skipPull: true),
                runtime: runtime,
                localEnv: [:],
                isTTY: true,
                recoveryEditor: upRecoveryEditor(runner: editorRunner),
                openEditorPrompt: upRecoveryPrompt(answers: ["n"])
            )
        }) { error in
            let cli = error as? CLIError
            try MiniTest.expectEqual(cli?.code, CLIErrorCode.runtimeFailed)
            try MiniTest.expect(cli?.message.contains("port 8080 already in use") == true)
        }
        try MiniTest.expectEqual(mock.calls.filter { $0.arguments.first == "create" }.count, 1)
        try MiniTest.expectEqual(editorRunner.launches, 0, "decline must not open the editor")
    }),

    ("upCreateFailureNonTTYNeverPromptsOrEdits", {
        let workspace = try TestRepo.makeTempWorkspace(configJSON: #"{ "image": "alpine:3.20" }"#)
        defer { try? FileManager.default.removeItem(at: workspace) }
        let mock = MockProcessRunner()
        let resolved = try ConfigResolver.resolve(workspacePath: workspace.path, localEnv: [:])
        installUpCreatePathHandlers(mock, resolved: resolved, createFailuresBeforeSuccess: 1)

        let editorRunner = UpRecoveryEditorRunner(payloads: [Data()])
        final class Writes: @unchecked Sendable { var lines: [String] = [] }
        let writes = Writes()
        let runtime = AppleContainerRuntime(executablePath: "/usr/local/bin/container", runner: mock)

        try MiniTest.expectThrows({
            _ = try UpCommand.run(
                options: UpOptions(workspacePath: workspace.path, skipPull: true),
                runtime: runtime,
                localEnv: [:],
                isTTY: false,
                recoveryEditor: upRecoveryEditor(runner: editorRunner),
                openEditorPrompt: upRecoveryPrompt(answers: ["y"]) { writes.lines.append($0) }
            )
        }) { error in
            let cli = error as? CLIError
            try MiniTest.expectEqual(cli?.code, CLIErrorCode.runtimeFailed)
            try MiniTest.expect(cli?.hint?.contains(resolved.configPath) == true, "hint names host config path")
            try MiniTest.expect(cli?.hint?.contains("adevcontainer up") == true, "hint names retry command")
        }
        try MiniTest.expectEqual(mock.calls.filter { $0.arguments.first == "create" }.count, 1)
        try MiniTest.expectEqual(editorRunner.launches, 0)
        try MiniTest.expect(writes.lines.isEmpty, "non-TTY must not print or prompt")
    }),

    ("upRecoveryInvalidConfigReopensEditor", {
        let workspace = try TestRepo.makeTempWorkspace(configJSON: #"{ "image": "alpine:3.20" }"#)
        defer { try? FileManager.default.removeItem(at: workspace) }
        let mock = MockProcessRunner()
        let resolved = try ConfigResolver.resolve(workspacePath: workspace.path, localEnv: [:])
        installUpCreatePathHandlers(mock, resolved: resolved, createFailuresBeforeSuccess: 1)

        let invalid = Data(#"{ "image": }"#.utf8)
        let valid = Data(#"{ "image": "alpine:3.20" }"#.utf8)
        let editorRunner = UpRecoveryEditorRunner(payloads: [invalid, valid])
        let runtime = AppleContainerRuntime(executablePath: "/usr/local/bin/container", runner: mock)

        let result = try UpCommand.run(
            options: UpOptions(workspacePath: workspace.path, skipPull: true),
            runtime: runtime,
            localEnv: [:],
            isTTY: true,
            recoveryEditor: upRecoveryEditor(runner: editorRunner),
            openEditorPrompt: upRecoveryPrompt(answers: ["y"])
        )

        try MiniTest.expectEqual(result.outcome, "success")
        try MiniTest.expectEqual(editorRunner.launches, 2, "invalid config reopens the editor")
        try MiniTest.expectEqual(
            mock.calls.filter { $0.arguments.first == "create" }.count,
            2,
            "retry after a valid edit re-runs the create path"
        )
    }),

    ("upStartFailureUsesRecoveryAndRetriesFromScratch", {
        let workspace = try TestRepo.makeTempWorkspace(configJSON: #"{ "image": "alpine:3.20" }"#)
        defer { try? FileManager.default.removeItem(at: workspace) }
        let mock = MockProcessRunner()
        let resolved = try ConfigResolver.resolve(workspacePath: workspace.path, localEnv: [:])
        installUpCreatePathHandlers(mock, resolved: resolved, startFailuresBeforeSuccess: 1)
        let editorRunner = UpRecoveryEditorRunner(payloads: [Data(#"{ "image": "alpine:3.20" }"#.utf8)])
        let runtime = AppleContainerRuntime(executablePath: "/usr/local/bin/container", runner: mock)

        let result = try UpCommand.run(
            options: UpOptions(workspacePath: workspace.path, skipPull: true),
            runtime: runtime,
            localEnv: [:],
            isTTY: true,
            recoveryEditor: upRecoveryEditor(runner: editorRunner),
            openEditorPrompt: upRecoveryPrompt(answers: ["y"])
        )
        try MiniTest.expectEqual(result.outcome, "success")
        try MiniTest.expectEqual(mock.calls.filter { $0.arguments.first == "create" }.count, 2)
        try MiniTest.expectEqual(mock.calls.filter { $0.arguments.first == "start" }.count, 2)
    }),

    ("upStoppedExistingStartFailureRecreatesContainerOnRecovery", {
        let workspace = try TestRepo.makeTempWorkspace(configJSON: #"{ "image": "alpine:3.20" }"#)
        defer { try? FileManager.default.removeItem(at: workspace) }
        let mock = MockProcessRunner()
        let resolved = try ConfigResolver.resolve(workspacePath: workspace.path, localEnv: [:])
        let existing = MockProcessRunner.containerListJSON(
            id: resolved.containerName,
            state: "stopped",
            labels: resolved.labels
        )
        var listCalls = 0
        var starts = 0
        var creates = 0
        mock.handlers = [
            { args in
                if args.starts(with: ["list"]) {
                    listCalls += 1
                    let values: [[String: Any]] = listCalls == 1 ? [existing] : []
                    return ProcessResult(
                        exitCode: 0,
                        stdout: try! JSONSerialization.data(withJSONObject: values),
                        stderr: Data()
                    )
                }
                if args.first == "create" {
                    creates += 1
                    return ProcessResult(exitCode: 0, stdout: Data("new-container\n".utf8), stderr: Data())
                }
                if args.first == "start" {
                    starts += 1
                    return ProcessResult(
                        exitCode: starts == 1 ? 1 : 0,
                        stdout: Data(),
                        stderr: starts == 1 ? Data("start failed".utf8) : Data()
                    )
                }
                if args.first == "delete" || args.first == "exec" { return ProcessResult(exitCode: 0, stdout: Data(), stderr: Data()) }
                return nil
            },
            MockProcessRunner.imageInspectHandler(baseUser: nil)
        ]
        let editorRunner = UpRecoveryEditorRunner(payloads: [Data(#"{ "image": "alpine:3.20" }"#.utf8)])
        let runtime = AppleContainerRuntime(executablePath: "/usr/local/bin/container", runner: mock)
        let result = try UpCommand.run(
            options: UpOptions(workspacePath: workspace.path, skipPull: true),
            runtime: runtime,
            localEnv: [:],
            isTTY: true,
            recoveryEditor: upRecoveryEditor(runner: editorRunner),
            openEditorPrompt: upRecoveryPrompt(answers: ["y"])
        )
        try MiniTest.expectEqual(result.outcome, "success")
        try MiniTest.expectEqual(creates, 1, "retry creates a replacement instead of reusing the stopped container")
        try MiniTest.expectEqual(starts, 2)
    }),

    ("upRestartPostStartFailureRecreatesContainerOnRecovery", {
        let workspace = try TestRepo.makeTempWorkspace(configJSON: #"{ "image": "alpine:3.20", "postStartCommand": "echo post-start" }"#)
        defer { try? FileManager.default.removeItem(at: workspace) }
        let mock = MockProcessRunner()
        let resolved = try ConfigResolver.resolve(workspacePath: workspace.path, localEnv: [:])
        let existing = MockProcessRunner.containerListJSON(
            id: resolved.containerName,
            state: "stopped",
            labels: resolved.labels
        )
        var creates = 0
        var execCalls = 0
        mock.handlers = [
            { args in
                if args.starts(with: ["list"]) {
                    let values: [[String: Any]] = [existing]
                    return ProcessResult(exitCode: 0, stdout: try! JSONSerialization.data(withJSONObject: values), stderr: Data())
                }
                if args.first == "create" {
                    creates += 1
                    return ProcessResult(exitCode: 0, stdout: Data("new-container\n".utf8), stderr: Data())
                }
                if args.first == "start" || args.first == "delete" { return ProcessResult(exitCode: 0, stdout: Data(), stderr: Data()) }
                if args.first == "exec" {
                    execCalls += 1
                    return ProcessResult(
                        exitCode: execCalls == 1 ? 1 : 0,
                        stdout: Data(),
                        stderr: execCalls == 1 ? Data("post-start failed".utf8) : Data()
                    )
                }
                return nil
            },
            MockProcessRunner.imageInspectHandler(baseUser: nil)
        ]
        let editorRunner = UpRecoveryEditorRunner(payloads: [Data(#"{ "image": "alpine:3.20" }"#.utf8)])
        let runtime = AppleContainerRuntime(executablePath: "/usr/local/bin/container", runner: mock)
        let result = try UpCommand.run(
            options: UpOptions(workspacePath: workspace.path, skipPull: true),
            runtime: runtime,
            localEnv: [:],
            isTTY: true,
            recoveryEditor: upRecoveryEditor(runner: editorRunner),
            openEditorPrompt: upRecoveryPrompt(answers: ["y"])
        )
        try MiniTest.expectEqual(result.outcome, "success")
        try MiniTest.expectEqual(creates, 1, "retry creates after restart postStart failure")
    }),

    ("upLaterRetryDeletesLeftoverFromLatestFailure", {
        // First eligible failure is create (no leftover). A later retry then hits a
        // leftover stopped container whose start fails. The next retry must delete
        // that later identity — not the first failure's nil resetExistingName.
        let workspace = try TestRepo.makeTempWorkspace(configJSON: #"{ "image": "alpine:3.20" }"#)
        defer { try? FileManager.default.removeItem(at: workspace) }
        let mock = MockProcessRunner()
        let resolved = try ConfigResolver.resolve(workspacePath: workspace.path, localEnv: [:])
        let leftover = MockProcessRunner.containerListJSON(
            id: resolved.containerName,
            state: "stopped",
            labels: resolved.labels
        )
        var listCalls = 0
        var creates = 0
        var starts = 0
        var deletes = 0
        mock.handlers = [
            { args in
                if args.starts(with: ["list"]) {
                    listCalls += 1
                    let values: [[String: Any]] = listCalls == 1 ? [] : [leftover]
                    return ProcessResult(
                        exitCode: 0,
                        stdout: try! JSONSerialization.data(withJSONObject: values),
                        stderr: Data()
                    )
                }
                if args.first == "create" {
                    creates += 1
                    return ProcessResult(
                        exitCode: creates == 1 ? 1 : 0,
                        stdout: creates == 1 ? Data() : Data("replacement\n".utf8),
                        stderr: creates == 1 ? Data("port 8080 already in use".utf8) : Data()
                    )
                }
                if args.first == "start" {
                    starts += 1
                    return ProcessResult(
                        exitCode: starts == 1 ? 1 : 0,
                        stdout: Data(),
                        stderr: starts == 1 ? Data("start failed".utf8) : Data()
                    )
                }
                if args.first == "delete" {
                    deletes += 1
                    return ProcessResult(exitCode: 0, stdout: Data(), stderr: Data())
                }
                if args.first == "exec" {
                    return ProcessResult(exitCode: 0, stdout: Data(), stderr: Data())
                }
                return nil
            },
            MockProcessRunner.imageInspectHandler(baseUser: nil)
        ]
        let editorRunner = UpRecoveryEditorRunner(
            payloads: [
                Data(#"{ "image": "alpine:3.20" }"#.utf8),
                Data(#"{ "image": "alpine:3.20" }"#.utf8)
            ]
        )
        let runtime = AppleContainerRuntime(executablePath: "/usr/local/bin/container", runner: mock)
        let result = try UpCommand.run(
            options: UpOptions(workspacePath: workspace.path, skipPull: true),
            runtime: runtime,
            localEnv: [:],
            isTTY: true,
            recoveryEditor: upRecoveryEditor(runner: editorRunner),
            openEditorPrompt: upRecoveryPrompt(answers: ["y", "y"])
        )
        try MiniTest.expectEqual(result.outcome, "success")
        try MiniTest.expectEqual(creates, 2, "create fails first, then succeeds after leftover delete")
        try MiniTest.expectEqual(starts, 2, "leftover start fails, then replacement start succeeds")
        try MiniTest.expectEqual(deletes, 1, "later leftover identity is deleted before the successful retry")
        try MiniTest.expect(
            mock.calls.contains { $0.arguments.first == "delete" && $0.arguments.last == resolved.containerName },
            "retry deletes the leftover name reported by the later failure"
        )
        try MiniTest.expectEqual(editorRunner.launches, 2)
    }),

    ("upOwnershipFailureUsesRecoveryAndRetriesFromScratch", {
        let initial = #"{ "image": "alpine:3.20", "remoteUser": "vscode", "mounts": [{ "type": "volume", "source": "up-data", "target": "/home/vscode/data" }] }"#
        let workspace = try TestRepo.makeTempWorkspace(configJSON: initial)
        defer { try? FileManager.default.removeItem(at: workspace) }
        let mock = MockProcessRunner()
        let resolved = try ConfigResolver.resolve(workspacePath: workspace.path, localEnv: [:])
        installUpCreatePathHandlers(mock, resolved: resolved, ownershipFailuresBeforeSuccess: 1)
        let editorRunner = UpRecoveryEditorRunner(payloads: [Data(#"{ "image": "alpine:3.20" }"#.utf8)])
        let runtime = AppleContainerRuntime(executablePath: "/usr/local/bin/container", runner: mock)

        let result = try UpCommand.run(
            options: UpOptions(workspacePath: workspace.path, skipPull: true),
            runtime: runtime,
            localEnv: [:],
            isTTY: true,
            recoveryEditor: upRecoveryEditor(runner: editorRunner),
            openEditorPrompt: upRecoveryPrompt(answers: ["y"])
        )
        try MiniTest.expectEqual(result.outcome, "success")
        try MiniTest.expectEqual(mock.calls.filter { $0.arguments.first == "create" }.count, 2)
        try MiniTest.expectEqual(editorRunner.launches, 1)
    }),

    ("upCreatePathHookFailureUsesRecoveryAndRetriesFromScratch", {
        let initial = #"{ "image": "alpine:3.20", "postCreateCommand": "exit 42" }"#
        let workspace = try TestRepo.makeTempWorkspace(configJSON: initial)
        defer { try? FileManager.default.removeItem(at: workspace) }
        let mock = MockProcessRunner()
        let resolved = try ConfigResolver.resolve(workspacePath: workspace.path, localEnv: [:])
        installUpCreatePathHandlers(mock, resolved: resolved, hookFailuresBeforeSuccess: 1)
        let editorRunner = UpRecoveryEditorRunner(payloads: [Data(#"{ "image": "alpine:3.20" }"#.utf8)])
        let runtime = AppleContainerRuntime(executablePath: "/usr/local/bin/container", runner: mock)

        let result = try UpCommand.run(
            options: UpOptions(workspacePath: workspace.path, skipPull: true),
            runtime: runtime,
            localEnv: [:],
            isTTY: true,
            recoveryEditor: upRecoveryEditor(runner: editorRunner),
            openEditorPrompt: upRecoveryPrompt(answers: ["y"])
        )
        try MiniTest.expectEqual(result.outcome, "success")
        try MiniTest.expectEqual(mock.calls.filter { $0.arguments.first == "create" }.count, 2)
    }),

    ("upRecoveryStaysHostEditOnlyWithNoWorkspaceCopy", {
        let edited = #"{ "image": "alpine:3.20", "name": "fixed" }"#
        let workspace = try TestRepo.makeTempWorkspace(configJSON: #"{ "image": "alpine:3.20" }"#)
        defer { try? FileManager.default.removeItem(at: workspace) }
        let mock = MockProcessRunner()
        let resolved = try ConfigResolver.resolve(workspacePath: workspace.path, localEnv: [:])
        installUpCreatePathHandlers(mock, resolved: resolved, createFailuresBeforeSuccess: 1)
        let editorRunner = UpRecoveryEditorRunner(payloads: [Data(edited.utf8)])
        let runtime = AppleContainerRuntime(executablePath: "/usr/local/bin/container", runner: mock)

        let result = try UpCommand.run(
            options: UpOptions(workspacePath: workspace.path, skipPull: true),
            runtime: runtime,
            localEnv: [:],
            isTTY: true,
            recoveryEditor: upRecoveryEditor(runner: editorRunner),
            openEditorPrompt: upRecoveryPrompt(answers: ["y"])
        )
        try MiniTest.expectEqual(result.outcome, "success")
        try MiniTest.expectEqual(editorRunner.launches, 1)
        let hostConfig = try String(contentsOfFile: resolved.configPath, encoding: .utf8)
        try MiniTest.expectEqual(hostConfig, edited, "host file remains the workspace file")
        try MiniTest.expect(
            !mock.calls.contains { $0.arguments.contains("adevcontainer-clone-persist") },
            "bind up recovery must not persist a clone overlay"
        )
        try MiniTest.expect(
            !mock.calls.contains { $0.arguments.contains("adevcontainer-recovery-write") },
            "bind up recovery must not use rebuild helper write-back"
        )
        try MiniTest.expect(
            !mock.calls.contains { call in
                call.arguments.first == "exec" && call.stdinData == Data(edited.utf8)
            },
            "bind up recovery must not copy edited config bytes into the container"
        )
        try MiniTest.expect(
            !mock.calls.contains { $0.arguments.first == "cp" || $0.arguments.first == "copy" },
            "bind up recovery must not container-cp the edited config"
        )
    })
]
