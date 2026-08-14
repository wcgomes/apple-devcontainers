import Foundation
@testable import ADevContainerLib

private func bringUpGuidance(
    configPath: String = "/workspaces/repo/.devcontainer/devcontainer.json",
    editCommand: String = "nano '/workspaces/repo/.devcontainer/devcontainer.json'",
    retryCommand: String = "adevcontainer up"
) -> BringUpRecovery.Guidance {
    BringUpRecovery.Guidance(
        configPath: configPath,
        editCommand: editCommand,
        retryCommand: retryCommand
    )
}

private func bringUpFailure() -> CLIError {
    CLIError(code: CLIErrorCode.runtimeFailed, property: "forwardPorts", message: "port 8080 already in use")
}

/// Injectable prompt: answers consumed in order; empty string = Enter (affirmative),
/// `nil` = EOF (decline). Falls back to EOF once answers are exhausted.
private func bringUpPrompt(
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

nonisolated(unsafe) let bringUpRecoveryTests: [(String, () throws -> Void)] = [
    ("affirmativePrintsFailureThenPromptsAndRetries", {
        var editCalls = 0
        var retryCalls = 0
        final class Writes: @unchecked Sendable { var lines: [String] = [] }
        let writes = Writes()
        let result = try BringUpRecovery.run(
            failure: bringUpFailure(),
            guidance: bringUpGuidance(),
            isTTY: true,
            jsonOutput: false,
            openEditorPrompt: bringUpPrompt(answers: ["y"]) { writes.lines.append($0) },
            edit: { editCalls += 1 },
            retry: { retryCalls += 1; return "done" }
        )
        try MiniTest.expectEqual(result, "done")
        try MiniTest.expectEqual(editCalls, 1)
        try MiniTest.expectEqual(retryCalls, 1)
        let joined = writes.lines.joined()
        try MiniTest.expect(joined.contains("port 8080 already in use"), "structured failure printed")
        try MiniTest.expect(joined.contains(RecoveryOpenEditorPrompt.promptText), "prompt text on stderr")
        // Failure text must appear before the prompt line.
        let failIdx = writes.lines.firstIndex { $0.contains("port 8080 already in use") }
        let promptIdx = writes.lines.firstIndex { $0.contains(RecoveryOpenEditorPrompt.promptText) }
        try MiniTest.expect(failIdx != nil && promptIdx != nil && failIdx! < promptIdx!)
    }),

    ("declineThrowsOriginalErrorWithoutEditOrRetry", {
        var editCalls = 0
        var retryCalls = 0
        let failure = bringUpFailure()
        try MiniTest.expectThrows({
            _ = try BringUpRecovery.run(
                failure: failure,
                guidance: bringUpGuidance(),
                isTTY: true,
                jsonOutput: false,
                openEditorPrompt: bringUpPrompt(answers: ["n"]),
                edit: { editCalls += 1 },
                retry: { retryCalls += 1; return "done" }
            )
        }) { error in
            let cli = error as? CLIError
            try MiniTest.expectEqual(cli?.code, CLIErrorCode.runtimeFailed)
            try MiniTest.expectEqual(cli?.property, "forwardPorts")
            try MiniTest.expectEqual(cli?.message, "port 8080 already in use")
        }
        try MiniTest.expectEqual(editCalls, 0)
        try MiniTest.expectEqual(retryCalls, 0)
    }),

    ("eofThrowsOriginalErrorWithoutEditOrRetry", {
        var editCalls = 0
        var retryCalls = 0
        let failure = bringUpFailure()
        try MiniTest.expectThrows({
            _ = try BringUpRecovery.run(
                failure: failure,
                guidance: bringUpGuidance(),
                isTTY: true,
                jsonOutput: false,
                openEditorPrompt: bringUpPrompt(answers: [nil]),
                edit: { editCalls += 1 },
                retry: { retryCalls += 1; return "done" }
            )
        }) { error in
            try MiniTest.expectEqual((error as? CLIError)?.code, CLIErrorCode.runtimeFailed)
        }
        try MiniTest.expectEqual(editCalls, 0)
        try MiniTest.expectEqual(retryCalls, 0)
    }),

    ("nonTTYThrowsHintedErrorWithoutPromptingOrEditing", {
        var editCalls = 0
        var retryCalls = 0
        final class Writes: @unchecked Sendable { var lines: [String] = [] }
        let writes = Writes()
        let failure = bringUpFailure()
        try MiniTest.expectThrows({
            _ = try BringUpRecovery.run(
                failure: failure,
                guidance: bringUpGuidance(),
                isTTY: false,
                jsonOutput: false,
                openEditorPrompt: bringUpPrompt(answers: ["y"]) { writes.lines.append($0) },
                edit: { editCalls += 1 },
                retry: { retryCalls += 1; return "done" }
            )
        }) { error in
            let cli = error as? CLIError
            try MiniTest.expectEqual(cli?.code, CLIErrorCode.runtimeFailed)
            try MiniTest.expectEqual(cli?.message, "port 8080 already in use")
            try MiniTest.expect(cli?.hint?.contains("adevcontainer up") == true)
            try MiniTest.expect(cli?.hint?.contains("devcontainer.json") == true)
        }
        try MiniTest.expectEqual(editCalls, 0)
        try MiniTest.expectEqual(retryCalls, 0)
        try MiniTest.expect(writes.lines.isEmpty, "non-TTY must not print or prompt")
    }),

    ("jsonOutputNeverPromptsOrEdits", {
        var editCalls = 0
        var retryCalls = 0
        final class Writes: @unchecked Sendable { var lines: [String] = [] }
        let writes = Writes()
        let failure = bringUpFailure()
        try MiniTest.expectThrows({
            _ = try BringUpRecovery.run(
                failure: failure,
                guidance: bringUpGuidance(),
                isTTY: true,
                jsonOutput: true,
                openEditorPrompt: bringUpPrompt(answers: ["y"]) { writes.lines.append($0) },
                edit: { editCalls += 1 },
                retry: { retryCalls += 1; return "done" }
            )
        }) { error in
            let cli = error as? CLIError
            try MiniTest.expectEqual(cli?.code, CLIErrorCode.runtimeFailed)
            try MiniTest.expect(cli?.hint?.contains("adevcontainer up") == true)
        }
        try MiniTest.expectEqual(editCalls, 0)
        try MiniTest.expectEqual(retryCalls, 0)
        try MiniTest.expect(writes.lines.isEmpty, "--json must not print or prompt")
    }),

    ("invalidConfigReopensInsideEditWithoutRePrompting", {
        final class Counter: @unchecked Sendable { var attempts = 0; var prompts = 0 }
        let counter = Counter()
        var retryCalls = 0
        let prompt = bringUpPrompt(answers: [""]) { line in
            if line.contains(RecoveryOpenEditorPrompt.promptText) { counter.prompts += 1 }
        }
        let result = try BringUpRecovery.run(
            failure: bringUpFailure(),
            guidance: bringUpGuidance(),
            isTTY: true,
            jsonOutput: false,
            openEditorPrompt: prompt,
            edit: {
                // Simulate the edit closure's contract: open → validate → reopen on invalid
                // content → validate again → return on a valid edit.
                while true {
                    counter.attempts += 1
                    if counter.attempts == 1 { continue } // first attempt invalid → reopen
                    break // second attempt valid
                }
            },
            retry: { retryCalls += 1; return "done" }
        )
        try MiniTest.expectEqual(result, "done")
        try MiniTest.expectEqual(counter.attempts, 2, "invalid edit reopens the editor")
        try MiniTest.expectEqual(counter.prompts, 1, "invalid reopen must not re-ask the prompt")
        try MiniTest.expectEqual(retryCalls, 1)
    }),

    ("retryFailureReEntersPromptAndRetriesAgain", {
        var editCalls = 0
        var retryCalls = 0
        final class Counter: @unchecked Sendable { var prompts = 0 }
        let counter = Counter()
        let prompt = bringUpPrompt(answers: ["", ""]) { line in
            if line.contains(RecoveryOpenEditorPrompt.promptText) { counter.prompts += 1 }
        }
        let result = try BringUpRecovery.run(
            failure: bringUpFailure(),
            guidance: bringUpGuidance(),
            isTTY: true,
            jsonOutput: false,
            openEditorPrompt: prompt,
            edit: { editCalls += 1 },
            retry: {
                retryCalls += 1
                if retryCalls == 1 {
                    throw CLIError(code: CLIErrorCode.lifecycleFailed, message: "onCreate failed")
                }
                return "done"
            }
        )
        try MiniTest.expectEqual(result, "done")
        try MiniTest.expectEqual(retryCalls, 2)
        try MiniTest.expectEqual(editCalls, 2)
        try MiniTest.expectEqual(counter.prompts, 2, "recoverable retry failure re-enters the prompt")
    }),

    ("editCancellationPropagatesWithoutRetry", {
        var retryCalls = 0
        let cancelled = CLIError(code: CLIErrorCode.recoveryCancelled, message: "recovery editing was cancelled")
        try MiniTest.expectThrows({
            _ = try BringUpRecovery.run(
                failure: bringUpFailure(),
                guidance: bringUpGuidance(),
                isTTY: true,
                jsonOutput: false,
                openEditorPrompt: bringUpPrompt(answers: ["y"]),
                edit: { throw cancelled },
                retry: { retryCalls += 1; return "done" }
            )
        }) { error in
            try MiniTest.expectEqual((error as? CLIError)?.code, CLIErrorCode.recoveryCancelled)
        }
        try MiniTest.expectEqual(retryCalls, 0)
    })
]
