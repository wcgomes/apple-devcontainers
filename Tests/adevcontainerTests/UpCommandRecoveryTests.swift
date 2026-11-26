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
    ("upRecoveryReplaceUnregistersBeforeDelete", {
        let port = AutomaticCredentialCommandPort()
        GitCredentialLifecycle.setTestConnection(port)
        defer { GitCredentialLifecycle.setTestConnection(nil) }
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
                if args.first == "start" { return ProcessResult(exitCode: 0, stdout: Data(), stderr: Data()) }
                if args.first == "delete" {
                    port.record("runtime.delete")
                    return ProcessResult(exitCode: 0, stdout: Data(), stderr: Data())
                }
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
        let unregister = port.events.firstIndex(of: "unregister")
        let deleted = port.events.firstIndex(of: "runtime.delete")
        try MiniTest.expect(unregister != nil && deleted != nil && unregister! < deleted!, "replacement must unregister before delete")
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
        try MiniTest.expectEqual(
            mock.calls.filter { $0.arguments.first == "create" }.count,
            3,
            "volume initializer plus failed create path and retry"
        )
        try MiniTest.expectEqual(editorRunner.launches, 1)
    }),

    ("upVolumeCorruptionFailsFastWithoutConfigEditRecovery", {
        let initial = #"{ "image": "alpine:3.20", "remoteUser": "vscode", "mounts": [{ "type": "volume", "source": "up-data", "target": "/home/vscode/data" }] }"#
        let workspace = try TestRepo.makeTempWorkspace(configJSON: initial)
        defer { try? FileManager.default.removeItem(at: workspace) }
        let mock = MockProcessRunner()
        let resolved = try ConfigResolver.resolve(workspacePath: workspace.path, localEnv: [:])
        installUpCreatePathHandlers(mock, resolved: resolved)
        mock.handlers.insert({ args in
            guard args.first == "exec", args.joined(separator: " ").contains("chown -R") else { return nil }
            return ProcessResult(
                exitCode: 1,
                stdout: Data(),
                stderr: Data("chown: /home/vscode/data/cache/index: Structure needs cleaning\n".utf8)
            )
        }, at: 0)
        let editorRunner = UpRecoveryEditorRunner(payloads: [Data(initial.utf8)])
        final class Prompts: @unchecked Sendable { var lines: [String] = [] }
        let prompts = Prompts()
        let runtime = AppleContainerRuntime(executablePath: "/usr/local/bin/container", runner: mock)

        try MiniTest.expectThrows({
            _ = try UpCommand.run(
                options: UpOptions(workspacePath: workspace.path, skipPull: true),
                runtime: runtime,
                localEnv: [:],
                isTTY: true,
                recoveryEditor: upRecoveryEditor(runner: editorRunner),
                openEditorPrompt: upRecoveryPrompt(answers: ["y"], onWrite: { prompts.lines.append($0) })
            )
        }) { error in
            let cli = error as? CLIError
            try MiniTest.expectEqual(cli?.code, CLIErrorCode.volumeCorrupt)
            try MiniTest.expect(cli?.message.contains("'up-data' mounted at /home/vscode/data") == true)
            try MiniTest.expect(cli?.hint?.contains("cp -c") == true, "backup-first clone guidance")
            try MiniTest.expect(cli?.hint?.contains("e2fsck -fy") == true, "offline repair guidance")
        }
        try MiniTest.expectEqual(editorRunner.launches, 0, "corruption never opens the config editor")
        try MiniTest.expect(prompts.lines.isEmpty, "corruption never prompts for config-edit recovery")
        try MiniTest.expectEqual(mock.calls.filter { $0.arguments.first == "create" }.count, 2, "no retry create")
        try MiniTest.expect(
            !mock.calls.contains { $0.arguments.starts(with: ["volume", "delete"]) || $0.arguments.starts(with: ["volume", "rm"]) },
            "the corrupt volume is never deleted"
        )
    }),

    ("upVolumeHealthGateRefusesWarnsAndSkips", {
        let config = #"{ "image": "alpine:3.20", "remoteUser": "vscode", "mounts": [{ "type": "volume", "source": "up-data", "target": "/home/vscode/data" }] }"#
        let workspace = try TestRepo.makeTempWorkspace(configJSON: config)
        defer { try? FileManager.default.removeItem(at: workspace) }
        let resolved = try ConfigResolver.resolve(workspacePath: workspace.path, localEnv: [:])
        let corrupt = try makeSyntheticExt4Image(syntheticExt4Superblock(errorCount: 4))
        let unclean = try makeSyntheticExt4Image(syntheticExt4Superblock(state: 0, compat: 0))

        func runUp(image: String?, inUse: Bool, editor: UpRecoveryEditorRunner) throws -> (UpResult, MockProcessRunner, [String]) {
            let mock = MockProcessRunner()
            installUpCreatePathHandlers(mock, resolved: resolved)
            if let image {
                mock.handlers.insert(volumeInspectHandler(["up-data": image]), at: 0)
            }
            if inUse {
                mock.handlers.insert({ args in
                    guard args.starts(with: ["list"]) else { return nil }
                    let entries = [containerListEntryMounting(volume: "up-data", id: "other-app", state: "running")]
                    return ProcessResult(exitCode: 0, stdout: try! JSONSerialization.data(withJSONObject: entries), stderr: Data())
                }, at: 0)
            }
            let previous = StatusPrinter.onWarning
            var warnings: [String] = []
            StatusPrinter.onWarning = { warnings.append($0) }
            defer { StatusPrinter.onWarning = previous }
            let result = try UpCommand.run(
                options: UpOptions(workspacePath: workspace.path, skipPull: true),
                runtime: AppleContainerRuntime(executablePath: "/usr/local/bin/container", runner: mock),
                localEnv: [:],
                isTTY: true,
                recoveryEditor: upRecoveryEditor(runner: editor),
                openEditorPrompt: upRecoveryPrompt(answers: ["y"])
            )
            return (result, mock, warnings)
        }

        // Errors recorded: refuse before create, never offer config-edit recovery.
        let editor = UpRecoveryEditorRunner(payloads: [Data(config.utf8)])
        let refusedMock = MockProcessRunner()
        installUpCreatePathHandlers(refusedMock, resolved: resolved)
        refusedMock.handlers.insert(volumeInspectHandler(["up-data": corrupt]), at: 0)
        try MiniTest.expectThrows({
            _ = try UpCommand.run(
                options: UpOptions(workspacePath: workspace.path, skipPull: true),
                runtime: AppleContainerRuntime(executablePath: "/usr/local/bin/container", runner: refusedMock),
                localEnv: [:],
                isTTY: true,
                recoveryEditor: upRecoveryEditor(runner: editor),
                openEditorPrompt: upRecoveryPrompt(answers: ["y"])
            )
        }) { error in
            let cli = error as? CLIError
            try MiniTest.expectEqual(cli?.code, CLIErrorCode.volumeCorrupt)
            try MiniTest.expect(cli?.message.contains("'up-data'") == true)
        }
        try MiniTest.expectEqual(editor.launches, 0, "corruption never opens the config editor")
        try MiniTest.expect(!refusedMock.calls.contains { $0.arguments.first == "create" }, "no container is created")

        // Bare not-clean without journal: warn and continue.
        let (uncleanResult, _, uncleanWarnings) = try runUp(image: unclean, inUse: false, editor: editor)
        try MiniTest.expectEqual(uncleanResult.outcome, "success")
        try MiniTest.expect(uncleanWarnings.contains { $0.contains("'up-data'") && $0.contains("e2fsck") })

        // In use by a running container, or unreadable: skip silently.
        let (inUseResult, inUseMock, inUseWarnings) = try runUp(image: corrupt, inUse: true, editor: editor)
        try MiniTest.expectEqual(inUseResult.outcome, "success")
        try MiniTest.expect(!inUseWarnings.contains { $0.contains("'up-data'") })
        try MiniTest.expect(!inUseMock.calls.contains { $0.arguments.starts(with: ["volume", "inspect"]) })
        let (unreadableResult, _, unreadableWarnings) = try runUp(image: nil, inUse: false, editor: editor)
        try MiniTest.expectEqual(unreadableResult.outcome, "success")
        try MiniTest.expect(!unreadableWarnings.contains { $0.contains("'up-data'") })
    }),

    ("upParentFixupFailureDeletesAndStaysRecoveryEligible", {
        // No named volumes: the first chown-containing exec on the create path is the
        // parents-only fix-up. Its failure must delete the created container and stay
        // eligible for bring-up recovery (editor prompt → retry from scratch).
        let initial = #"{ "image": "alpine:3.20", "remoteUser": "vscode" }"#
        let workspace = try TestRepo.makeTempWorkspace(configJSON: initial)
        defer { try? FileManager.default.removeItem(at: workspace) }
        let mock = MockProcessRunner()
        let resolved = try ConfigResolver.resolve(workspacePath: workspace.path, localEnv: [:])
        installUpCreatePathHandlers(mock, resolved: resolved, ownershipFailuresBeforeSuccess: 1)
        let editorRunner = UpRecoveryEditorRunner(payloads: [Data(initial.utf8)])
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
        try MiniTest.expectEqual(mock.calls.filter { $0.arguments.first == "create" }.count, 2, "retry after parent fix-up failure")
        try MiniTest.expectEqual(editorRunner.launches, 1, "parent fix-up failure stays eligible for bring-up recovery")
        try MiniTest.expect(
            mock.calls.contains { $0.arguments.first == "delete" },
            "created container deleted on parent fix-up failure"
        )
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
    }),

    ("upTTYAsksWhetherToChangeNameThenPersistsFullName", {
        let workspace = try TestRepo.makeTempWorkspace(configJSON: """
        { "name": "My App", "image": "alpine:3.20" }
        """)
        defer { try? FileManager.default.removeItem(at: workspace) }
        let resolved = try ConfigResolver.resolve(workspacePath: workspace.path, localEnv: [:])
        try MiniTest.expectEqual(resolved.containerName, "my-app")
        let foreign = MockProcessRunner.containerListJSON(
            id: "my-app",
            state: "running",
            labels: [
                ContainerIdentity.labelManaged: ContainerIdentity.managedValue,
                ContainerIdentity.labelWorkspaceMode: ContainerIdentity.workspaceModeBind,
                ContainerIdentity.labelLocalFolder: "/other/workspace",
                ContainerIdentity.labelConfigFile: "/other/workspace/.devcontainer/devcontainer.json",
                ContainerIdentity.labelConfigHash: "other"
            ]
        )
        var lists = 0
        let mock = MockProcessRunner()
        mock.handlers = [
            { args in
                if args.starts(with: ["list"]) {
                    lists += 1
                    let payload: [[String: Any]] = lists == 1 ? [foreign] : []
                    return ProcessResult(
                        exitCode: 0,
                        stdout: try! JSONSerialization.data(withJSONObject: payload),
                        stderr: Data()
                    )
                }
                return nil
            },
            MockProcessRunner.imageInspectHandler(baseUser: nil),
            { args in
                if args.first == "create" {
                    return ProcessResult(
                        exitCode: 0,
                        stdout: Data("my-app-2\n".utf8),
                        stderr: Data()
                    )
                }
                if args.first == "start" || args.first == "exec" {
                    return ProcessResult(exitCode: 0, stdout: Data(), stderr: Data())
                }
                return nil
            }
        ]
        let editorRunner = UpRecoveryEditorRunner(payloads: [Data()])
        final class Writes: @unchecked Sendable { var lines: [String] = [] }
        let writes = Writes()
        let runtime = AppleContainerRuntime(executablePath: "/usr/local/bin/container", runner: mock)
        let result = try UpCommand.run(
            options: UpOptions(workspacePath: workspace.path, skipPull: true),
            runtime: runtime,
            localEnv: [:],
            isTTY: true,
            recoveryEditor: upRecoveryEditor(runner: editorRunner),
            openEditorPrompt: upRecoveryPrompt(answers: ["y", "My App 2"]) { writes.lines.append($0) }
        )
        try MiniTest.expectEqual(result.outcome, "success")
        try MiniTest.expectEqual(editorRunner.launches, 0, "foreign rename must not open an editor")
        try MiniTest.expect(!mock.calls.contains { $0.arguments.first == "delete" })
        let joined = writes.lines.joined()
        try MiniTest.expect(joined.contains("not this workspace"))
        try MiniTest.expect(joined.contains(BringUpRecovery.changeNamePromptText))
        try MiniTest.expect(joined.contains(BringUpRecovery.newNamePromptText))
        try MiniTest.expect(!joined.contains("Type a suffix"))
        try MiniTest.expect(!joined.contains("Open the recovery editor"))
        try MiniTest.expect(!joined.contains(RecoveryOpenEditorPrompt.promptText))
        let host = try String(contentsOfFile: resolved.configPath, encoding: .utf8)
        try MiniTest.expect(host.contains("my-app-2"))
        let createArgs = mock.calls.first { $0.arguments.first == "create" }?.arguments ?? []
        if let nameIdx = createArgs.firstIndex(of: "--name"), nameIdx + 1 < createArgs.count {
            try MiniTest.expectEqual(createArgs[nameIdx + 1], "my-app-2")
        } else {
            try MiniTest.expect(false, "expected create --name my-app-2")
        }
    }),

    ("upTTYEmptyOrInvalidNameRePromptsWithoutPersist", {
        let workspace = try TestRepo.makeTempWorkspace(configJSON: """
        { "name": "My App", "image": "alpine:3.20" }
        """)
        defer { try? FileManager.default.removeItem(at: workspace) }
        let resolved = try ConfigResolver.resolve(workspacePath: workspace.path, localEnv: [:])
        let foreign = MockProcessRunner.containerListJSON(
            id: "my-app",
            state: "running",
            labels: [
                ContainerIdentity.labelLocalFolder: "/other/workspace",
                ContainerIdentity.labelConfigFile: "/other/workspace/.devcontainer/devcontainer.json"
            ]
        )
        var lists = 0
        let mock = MockProcessRunner()
        mock.handlers = [
            { args in
                if args.starts(with: ["list"]) {
                    lists += 1
                    let payload: [[String: Any]] = lists == 1 ? [foreign] : []
                    return ProcessResult(
                        exitCode: 0,
                        stdout: try! JSONSerialization.data(withJSONObject: payload),
                        stderr: Data()
                    )
                }
                return nil
            },
            MockProcessRunner.imageInspectHandler(baseUser: nil),
            { args in
                if args.first == "create" || args.first == "start" || args.first == "exec" {
                    return ProcessResult(exitCode: 0, stdout: Data("free-name\n".utf8), stderr: Data())
                }
                return nil
            }
        ]
        let editorRunner = UpRecoveryEditorRunner(payloads: [Data()])
        final class Counter: @unchecked Sendable { var namePrompts = 0 }
        let counter = Counter()
        let runtime = AppleContainerRuntime(executablePath: "/usr/local/bin/container", runner: mock)
        _ = try UpCommand.run(
            options: UpOptions(workspacePath: workspace.path, skipPull: true),
            runtime: runtime,
            localEnv: [:],
            isTTY: true,
            recoveryEditor: upRecoveryEditor(runner: editorRunner),
            openEditorPrompt: upRecoveryPrompt(answers: ["y", "!!!", "free-name"]) { line in
                if line.contains(BringUpRecovery.newNamePromptText) { counter.namePrompts += 1 }
            }
        )
        try MiniTest.expectEqual(editorRunner.launches, 0)
        try MiniTest.expect(counter.namePrompts >= 2, "empty/invalid name must re-prompt")
        let host = try String(contentsOfFile: resolved.configPath, encoding: .utf8)
        try MiniTest.expect(host.contains("free-name"))
        try MiniTest.expect(!host.contains("!!!"))
    }),

    ("upTTYStillCollidingNameReAsksWithoutDeleting", {
        let workspace = try TestRepo.makeTempWorkspace(configJSON: """
        { "name": "My App", "image": "alpine:3.20" }
        """)
        defer { try? FileManager.default.removeItem(at: workspace) }
        let first = MockProcessRunner.containerListJSON(
            id: "my-app",
            state: "running",
            labels: [
                ContainerIdentity.labelLocalFolder: "/other/a",
                ContainerIdentity.labelConfigFile: "/other/a/.devcontainer/devcontainer.json"
            ]
        )
        let second = MockProcessRunner.containerListJSON(
            id: "taken-two",
            state: "running",
            labels: [
                ContainerIdentity.labelLocalFolder: "/other/b",
                ContainerIdentity.labelConfigFile: "/other/b/.devcontainer/devcontainer.json"
            ]
        )
        var lists = 0
        let mock = MockProcessRunner()
        mock.handlers = [
            { args in
                if args.starts(with: ["list"]) {
                    lists += 1
                    let payload: [[String: Any]]
                    if lists == 1 { payload = [first] }
                    else if lists == 2 { payload = [first, second] }
                    else { payload = [first, second] }
                    return ProcessResult(
                        exitCode: 0,
                        stdout: try! JSONSerialization.data(withJSONObject: payload),
                        stderr: Data()
                    )
                }
                return nil
            },
            MockProcessRunner.imageInspectHandler(baseUser: nil),
            { args in
                if args.first == "create" || args.first == "start" || args.first == "exec" {
                    return ProcessResult(exitCode: 0, stdout: Data("free-name\n".utf8), stderr: Data())
                }
                return nil
            }
        ]
        final class Counter: @unchecked Sendable { var ynPrompts = 0 }
        let counter = Counter()
        let editorRunner = UpRecoveryEditorRunner(payloads: [Data()])
        let runtime = AppleContainerRuntime(executablePath: "/usr/local/bin/container", runner: mock)
        _ = try UpCommand.run(
            options: UpOptions(workspacePath: workspace.path, skipPull: true),
            runtime: runtime,
            localEnv: [:],
            isTTY: true,
            recoveryEditor: upRecoveryEditor(runner: editorRunner),
            openEditorPrompt: upRecoveryPrompt(
                answers: ["y", "taken-two", "y", "free-name"]
            ) { line in
                if line.contains(BringUpRecovery.changeNamePromptText) { counter.ynPrompts += 1 }
            }
        )
        try MiniTest.expect(counter.ynPrompts >= 2, "still-colliding name must re-ask Y/n")
        try MiniTest.expectEqual(editorRunner.launches, 0)
        try MiniTest.expect(!mock.calls.contains { $0.arguments.first == "delete" })
    }),

    ("upTTYDeclineLeavesOccupantUntouched", {
        let workspace = try TestRepo.makeTempWorkspace(configJSON: """
        { "name": "My App", "image": "alpine:3.20" }
        """)
        defer { try? FileManager.default.removeItem(at: workspace) }
        let resolved = try ConfigResolver.resolve(workspacePath: workspace.path, localEnv: [:])
        let original = try String(contentsOfFile: resolved.configPath, encoding: .utf8)
        let foreign = MockProcessRunner.containerListJSON(
            id: "my-app",
            state: "running",
            labels: [
                ContainerIdentity.labelLocalFolder: "/other/workspace",
                ContainerIdentity.labelConfigFile: "/other/workspace/.devcontainer/devcontainer.json"
            ]
        )
        let mock = MockProcessRunner()
        mock.handlers = [
            { args in
                if args.starts(with: ["list"]) {
                    return ProcessResult(
                        exitCode: 0,
                        stdout: try! JSONSerialization.data(withJSONObject: [foreign]),
                        stderr: Data()
                    )
                }
                return nil
            }
        ]
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
            try MiniTest.expectEqual((error as? CLIError)?.code, CLIErrorCode.containerNameInUse)
        }
        try MiniTest.expectEqual(editorRunner.launches, 0)
        try MiniTest.expect(!mock.calls.contains { $0.arguments.first == "create" })
        try MiniTest.expect(!mock.calls.contains { $0.arguments.first == "delete" })
        let after = try String(contentsOfFile: resolved.configPath, encoding: .utf8)
        try MiniTest.expectEqual(after, original)
    }),

    ("upRenamePromptsRemainUsableUnderQuiet", {
        let previous = StatusPrinter.enabled
        StatusPrinter.enabled = false
        defer { StatusPrinter.enabled = previous }
        let workspace = try TestRepo.makeTempWorkspace(configJSON: """
        { "name": "My App", "image": "alpine:3.20" }
        """)
        defer { try? FileManager.default.removeItem(at: workspace) }
        let foreign = MockProcessRunner.containerListJSON(
            id: "my-app",
            state: "running",
            labels: [
                ContainerIdentity.labelLocalFolder: "/other/workspace",
                ContainerIdentity.labelConfigFile: "/other/workspace/.devcontainer/devcontainer.json"
            ]
        )
        var lists = 0
        let mock = MockProcessRunner()
        mock.handlers = [
            { args in
                if args.starts(with: ["list"]) {
                    lists += 1
                    let payload: [[String: Any]] = lists == 1 ? [foreign] : []
                    return ProcessResult(
                        exitCode: 0,
                        stdout: try! JSONSerialization.data(withJSONObject: payload),
                        stderr: Data()
                    )
                }
                return nil
            },
            MockProcessRunner.imageInspectHandler(baseUser: nil),
            { args in
                if args.first == "create" || args.first == "start" || args.first == "exec" {
                    return ProcessResult(exitCode: 0, stdout: Data("free-name\n".utf8), stderr: Data())
                }
                return nil
            }
        ]
        final class Writes: @unchecked Sendable { var lines: [String] = [] }
        let writes = Writes()
        let runtime = AppleContainerRuntime(executablePath: "/usr/local/bin/container", runner: mock)
        _ = try UpCommand.run(
            options: UpOptions(workspacePath: workspace.path, skipPull: true),
            runtime: runtime,
            localEnv: [:],
            isTTY: true,
            openEditorPrompt: upRecoveryPrompt(answers: ["y", "free-name"]) { writes.lines.append($0) }
        )
        let joined = writes.lines.joined()
        try MiniTest.expect(joined.contains("not this workspace"))
        try MiniTest.expect(joined.contains(BringUpRecovery.changeNamePromptText))
        try MiniTest.expect(joined.contains(BringUpRecovery.newNamePromptText))
    }),

    ("upNonTTYAndJsonNeverPromptOnForeignName", {
        let workspace = try TestRepo.makeTempWorkspace(configJSON: """
        { "name": "My App", "image": "alpine:3.20" }
        """)
        defer { try? FileManager.default.removeItem(at: workspace) }
        let foreign = MockProcessRunner.containerListJSON(
            id: "my-app",
            state: "running",
            labels: [
                ContainerIdentity.labelLocalFolder: "/other/workspace",
                ContainerIdentity.labelConfigFile: "/other/workspace/.devcontainer/devcontainer.json"
            ]
        )
        let mock = MockProcessRunner()
        mock.handlers = [
            { args in
                if args.starts(with: ["list"]) {
                    return ProcessResult(
                        exitCode: 0,
                        stdout: try! JSONSerialization.data(withJSONObject: [foreign]),
                        stderr: Data()
                    )
                }
                return nil
            }
        ]
        let runtime = AppleContainerRuntime(executablePath: "/usr/local/bin/container", runner: mock)
        let editorRunner = UpRecoveryEditorRunner(payloads: [Data()])
        final class Writes: @unchecked Sendable { var lines: [String] = [] }
        let writes = Writes()
        try MiniTest.expectThrows({
            _ = try UpCommand.run(
                options: UpOptions(workspacePath: workspace.path, jsonOutput: true, skipPull: true),
                runtime: runtime,
                localEnv: [:],
                isTTY: true,
                recoveryEditor: upRecoveryEditor(runner: editorRunner),
                openEditorPrompt: upRecoveryPrompt(answers: ["y", "other"]) { writes.lines.append($0) }
            )
        }) { error in
            let err = error as! CLIError
            try MiniTest.expectEqual(err.code, CLIErrorCode.containerNameInUse)
            try MiniTest.expect(err.hint?.contains("devcontainer.json") == true)
        }
        try MiniTest.expectEqual(editorRunner.launches, 0)
        try MiniTest.expect(writes.lines.isEmpty, "--json must not prompt")
        try MiniTest.expect(!mock.calls.contains { $0.arguments.first == "delete" })

        try MiniTest.expectThrows({
            _ = try UpCommand.run(
                options: UpOptions(workspacePath: workspace.path, skipPull: true),
                runtime: runtime,
                localEnv: [:],
                isTTY: false,
                recoveryEditor: upRecoveryEditor(runner: editorRunner)
            )
        }) { error in
            try MiniTest.expectEqual((error as? CLIError)?.code, CLIErrorCode.containerNameInUse)
        }
        try MiniTest.expectEqual(editorRunner.launches, 0)
    })
]
