import Foundation
@testable import ADevContainerLib

// MARK: - Helpers

/// Injectable recovery prompt; `nil`/exhausted answers → EOF (decline). Writes are discarded
/// so the structured-failure stderr does not pollute the test harness.
private func clonePrompt(answers: [String?]) -> RecoveryOpenEditorPrompt {
    final class Box: @unchecked Sendable {
        var remaining: [String?]
        init(_ a: [String?]) { remaining = a }
    }
    let box = Box(answers)
    return RecoveryOpenEditorPrompt(
        readLine: {
            if box.remaining.isEmpty { return nil }
            return box.remaining.removeFirst()
        },
        writeError: { _ in }
    )
}

/// No-op editor that always resolves to `/tools/editor` and exits 0.
private func cloneEditor() -> (RecoveryEditor, MockProcessRunner) {
    let runner = MockProcessRunner()
    let editor = RecoveryEditor(
        environment: ["EDITOR": "/tools/editor"],
        runner: runner,
        executableChecker: { $0 == "/tools/editor" }
    )
    return (editor, runner)
}

/// A runtime whose `container create` fails `createFailures` times, then succeeds
/// (delegating the rest of the command surface to `CloneRuntimeMock.handlers`).
private func createFailsThenSucceedsRuntime(
    createFailures: Int = 1
) -> (AppleContainerRuntime, MockProcessRunner, () -> Int) {
    final class Counter: @unchecked Sendable { var value = 0 }
    let counter = Counter()
    let mock = MockProcessRunner()
    mock.handlers = [
        { args in
            guard args.first == "create" else { return nil }
            counter.value += 1
            if counter.value <= createFailures {
                return ProcessResult(
                    exitCode: 1,
                    stdout: Data(),
                    stderr: Data("create failed".utf8)
                )
            }
            return nil // fall through to the success handler below
        }
    ] + CloneRuntimeMock.handlers()
    let runtime = AppleContainerRuntime(executablePath: "/usr/local/bin/container", runner: mock)
    return (runtime, mock, { counter.value })
}

private func retainedEntries(in root: String) -> [String] {
    guard let entries = try? FileManager.default.contentsOfDirectory(atPath: root) else { return [] }
    return entries.map { (root as NSString).appendingPathComponent($0) }
}

// MARK: - Persist-after-populate helpers

private let clonePersistToken = "adevcontainer-clone-persist"
private let cloneOriginalConfigJSON = #"{ "image": "alpine:3.20" }"#
private let cloneEditedConfigJSON = #"{ "image": "alpine:3.20", "name": "fixed" }"#
private let cloneEditedConfigBytes = Data(cloneEditedConfigJSON.utf8)

private func cloneWorkspaceConfigPath(gitURL: String) -> String {
    let base = ContainerIdentity.repoBasename(fromGitURL: gitURL)
    return "/workspaces/\(base)/.devcontainer/devcontainer.json"
}

/// In-container workspace files as seen after populate (git original) and persist (edited).
private final class CloneWorkspaceFiles: @unchecked Sendable {
    var files: [String: Data] = [:]
}

/// Editor that writes `json` onto the retained host config path (last argv).
private func cloneEditorWriting(_ json: String) -> (RecoveryEditor, MockProcessRunner) {
    let runner = MockProcessRunner()
    runner.handlers = [{ args in
        if let path = args.last {
            try? json.write(toFile: path, atomically: true, encoding: .utf8)
        }
        return ProcessResult(exitCode: 0, stdout: Data(), stderr: Data())
    }]
    let editor = RecoveryEditor(
        environment: ["EDITOR": "/tools/editor"],
        runner: runner,
        executableChecker: { $0 == "/tools/editor" }
    )
    return (editor, runner)
}

/// Runtime that seeds the workspace config on populate, records persist writes, and
/// serves those bytes on a later `cat` (in-container open).
private func persistAwareRuntime(
    workspaceConfigPath: String,
    files: CloneWorkspaceFiles,
    createFailures: Int = 0
) -> (AppleContainerRuntime, MockProcessRunner, () -> Int) {
    final class Counter: @unchecked Sendable { var value = 0 }
    let counter = Counter()
    let mock = MockProcessRunner()
    mock.stdinHandlers = [
        { args, stdin in
            guard args.first == "exec",
                  let tokenIdx = args.firstIndex(of: clonePersistToken),
                  tokenIdx + 1 < args.count
            else { return nil }
            let dest = args[tokenIdx + 1]
            let bytes = stdin ?? Data()
            files.files[dest] = bytes
            return ProcessResult(exitCode: 0, stdout: Data(), stderr: Data())
        }
    ]
    mock.handlers = [
        { args in
            guard args.first == "create" else { return nil }
            counter.value += 1
            if counter.value <= createFailures {
                return ProcessResult(
                    exitCode: 1,
                    stdout: Data(),
                    stderr: Data("create failed".utf8)
                )
            }
            return nil
        },
        { args in
            guard args.first == "exec" else { return nil }
            if let catIdx = args.firstIndex(of: "cat"), catIdx + 1 < args.count {
                let path = args[catIdx + 1]
                if let data = files.files[path] {
                    return ProcessResult(exitCode: 0, stdout: data, stderr: Data())
                }
                return ProcessResult(exitCode: 1, stdout: Data(), stderr: Data("missing".utf8))
            }
            // In-container git populate restores the original remote config.
            if args.contains("-c"), !args.contains("-lc"), !(args.last?.contains("--global") == true) {
                files.files[workspaceConfigPath] = Data(cloneOriginalConfigJSON.utf8)
            }
            return nil
        }
    ] + CloneRuntimeMock.handlers()
    let runtime = AppleContainerRuntime(executablePath: "/usr/local/bin/container", runner: mock)
    return (runtime, mock, { counter.value })
}

private func persistWrites(in mock: MockProcessRunner) -> [MockProcessRunner.MockProcessCall] {
    mock.calls.filter { $0.arguments.contains(clonePersistToken) }
}

// MARK: - Suite

nonisolated(unsafe) let cloneRecoveryTests: [(String, () throws -> Void)] = [
    ("cloneConfigParseFailureRecoversButFetchFailureDoesNot", {
        let restore = CloneGitFeatureTestSupport.installOverrides()
        defer { restore() }
        let retainedRoot = FileManager.default.temporaryDirectory
            .appendingPathComponent("clone-rec-root-\(UUID().uuidString)", isDirectory: true).path
        CloneCommand.retainedCheckoutRootOverride = retainedRoot
        defer {
            CloneCommand.retainedCheckoutRootOverride = nil
            try? FileManager.default.removeItem(atPath: retainedRoot)
        }

        let git = MockGitClient()
        git.configJSONToWrite = #"{ "image": }"#
        let mock = MockProcessRunner()
        mock.handlers = CloneRuntimeMock.handlers()
        let runtime = AppleContainerRuntime(executablePath: "/usr/local/bin/container", runner: mock)
        let (editor, editorRunner) = cloneEditor()

        try MiniTest.expectThrows({
            _ = try CloneCommand.run(
                options: CloneOptions(gitURL: "https://github.com/org/parse.git", skipPull: true),
                runtime: runtime,
                git: git,
                credentials: MockGitCredential(),
                localEnv: [:],
                isTTY: false,
                editor: editor
            )
        }) { error in
            try MiniTest.expectEqual((error as? CLIError)?.code, CLIErrorCode.configParse)
        }
        try MiniTest.expectEqual(retainedEntries(in: retainedRoot).count, 1)
        try MiniTest.expect(editorRunner.calls.isEmpty)

        let fetchFailingGit = MockGitClient()
        fetchFailingGit.fetchConfigHandler = { _, _ in
            throw CLIError(code: CLIErrorCode.gitFailed, message: "fetch failed")
        }
        try MiniTest.expectThrows({
            _ = try CloneCommand.run(
                options: CloneOptions(gitURL: "https://github.com/org/fetch.git", skipPull: true),
                runtime: runtime,
                git: fetchFailingGit,
                credentials: MockGitCredential(),
                localEnv: [:],
                isTTY: true,
                openEditorPrompt: clonePrompt(answers: ["y"]),
                editor: editor
            )
        }) { error in
            try MiniTest.expectEqual((error as? CLIError)?.code, CLIErrorCode.gitFailed)
        }
        try MiniTest.expectEqual(editorRunner.calls.count, 0, "fetch failure has no editable config")
    }),
    ("cloneResumeRejectsExternalCheckoutWithoutDeletingIt", {
        let restore = CloneGitFeatureTestSupport.installOverrides()
        defer { restore() }
        let retainedRoot = FileManager.default.temporaryDirectory
            .appendingPathComponent("clone-rec-root-\(UUID().uuidString)", isDirectory: true)
        CloneCommand.retainedCheckoutRootOverride = retainedRoot.path
        defer {
            CloneCommand.retainedCheckoutRootOverride = nil
            try? FileManager.default.removeItem(at: retainedRoot)
        }

        let external = FileManager.default.temporaryDirectory
            .appendingPathComponent("external-checkout-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: external, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: external) }
        let configDir = external.appendingPathComponent(".devcontainer", isDirectory: true)
        try FileManager.default.createDirectory(at: configDir, withIntermediateDirectories: true)
        try #"{ "image": "alpine:3.20" }"#.write(
            to: configDir.appendingPathComponent("devcontainer.json"),
            atomically: true,
            encoding: .utf8
        )

        let git = MockGitClient()
        let mock = MockProcessRunner()
        mock.handlers = CloneRuntimeMock.handlers()
        let runtime = AppleContainerRuntime(executablePath: "/usr/local/bin/container", runner: mock)
        try MiniTest.expectThrows({
            _ = try CloneCommand.run(
                options: CloneOptions(
                    gitURL: "https://github.com/org/external.git",
                    skipPull: true,
                    resumeConfigDir: external.path
                ),
                runtime: runtime,
                git: git,
                credentials: MockGitCredential(),
                localEnv: [:],
                isTTY: false
            )
        }) { error in
            try MiniTest.expectEqual((error as? CLIError)?.code, CLIErrorCode.recoveryUnavailable)
        }
        try MiniTest.expect(FileManager.default.fileExists(atPath: external.path))
        try MiniTest.expect(git.fetchConfigCalls.isEmpty)
    }),
    ("cloneCreateFailureRetainsCheckoutAndRetriesWithoutRefetch", {
        let restore = CloneGitFeatureTestSupport.installOverrides()
        defer { restore() }
        let retainedRoot = FileManager.default.temporaryDirectory
            .appendingPathComponent("clone-rec-root-\(UUID().uuidString)", isDirectory: true).path
        CloneCommand.retainedCheckoutRootOverride = retainedRoot
        defer {
            CloneCommand.retainedCheckoutRootOverride = nil
            try? FileManager.default.removeItem(atPath: retainedRoot)
        }

        let git = MockGitClient()
        git.configJSONToWrite = #"{ "image": "alpine:3.20" }"#

        let (runtime, _, createCount) = createFailsThenSucceedsRuntime()
        let (editor, editorRunner) = cloneEditor()

        let result = try CloneCommand.run(
            options: CloneOptions(gitURL: "https://github.com/org/recovery.git", skipPull: true),
            runtime: runtime,
            git: git,
            credentials: MockGitCredential(),
            localEnv: [:],
            isTTY: true,
            openEditorPrompt: clonePrompt(answers: ["y"]),
            editor: editor
        )
        try MiniTest.expectEqual(result.outcome, "success")
        try MiniTest.expectEqual(createCount(), 2, "create retried after edit")
        try MiniTest.expectEqual(git.fetchConfigCalls.count, 1, "retry must not re-fetch git")
        try MiniTest.expectEqual(editorRunner.calls.count, 1, "editor opened exactly once")
        // Successful recovery cleans the retained checkout.
        try MiniTest.expect(retainedEntries(in: retainedRoot).isEmpty, "retained checkout removed after success")
    }),

    ("cloneNonTTYRetainsCheckoutAndEmitsExactResumeCommand", {
        let restore = CloneGitFeatureTestSupport.installOverrides()
        defer { restore() }
        let retainedRoot = FileManager.default.temporaryDirectory
            .appendingPathComponent("clone-rec-root-\(UUID().uuidString)", isDirectory: true).path
        CloneCommand.retainedCheckoutRootOverride = retainedRoot
        defer {
            CloneCommand.retainedCheckoutRootOverride = nil
            try? FileManager.default.removeItem(atPath: retainedRoot)
        }

        let git = MockGitClient()
        git.configJSONToWrite = #"{ "image": "alpine:3.20" }"#

        let (runtime, _, createCount) = createFailsThenSucceedsRuntime()
        let (editor, editorRunner) = cloneEditor()

        try MiniTest.expectThrows({
            _ = try CloneCommand.run(
                options: CloneOptions(
                    gitURL: "https://github.com/org/recovery.git",
                    skipPull: true,
                    openVSCode: true,
                    jsonOutput: true
                ),
                runtime: runtime,
                git: git,
                credentials: MockGitCredential(),
                localEnv: [:],
                isTTY: false,
                openEditorPrompt: clonePrompt(answers: ["y"]),
                editor: editor
            )
        }) { error in
            let cli = error as? CLIError
            try MiniTest.expectEqual(cli?.code, CLIErrorCode.runtimeFailed)
            let retained = retainedEntries(in: retainedRoot)
            try MiniTest.expectEqual(retained.count, 1, "one retained checkout")
            let dir = retained[0]
            let expectedRetry = "adevcontainer clone 'https://github.com/org/recovery.git' --skip-pull --vscode --json --resume '\(dir)'"
            try MiniTest.expect(
                cli?.hint?.contains(expectedRetry) == true,
                "non-TTY hint contains the exact --resume retry command"
            )
        }
        try MiniTest.expectEqual(createCount(), 1, "no retry on non-TTY")
        try MiniTest.expectEqual(git.fetchConfigCalls.count, 1)
        try MiniTest.expect(editorRunner.calls.isEmpty, "non-TTY never opens the editor")
        // Checkout retained on disk (config still present).
        let retained = retainedEntries(in: retainedRoot)
        try MiniTest.expectEqual(retained.count, 1)
        let configPath = (retained[0] as NSString).appendingPathComponent(".devcontainer/devcontainer.json")
        try MiniTest.expect(FileManager.default.fileExists(atPath: configPath), "retained config present")
    }),

    ("cloneDeclineRethrowsOriginalErrorAndRetainsCheckout", {
        let restore = CloneGitFeatureTestSupport.installOverrides()
        defer { restore() }
        let retainedRoot = FileManager.default.temporaryDirectory
            .appendingPathComponent("clone-rec-root-\(UUID().uuidString)", isDirectory: true).path
        CloneCommand.retainedCheckoutRootOverride = retainedRoot
        defer {
            CloneCommand.retainedCheckoutRootOverride = nil
            try? FileManager.default.removeItem(atPath: retainedRoot)
        }

        let git = MockGitClient()
        git.configJSONToWrite = #"{ "image": "alpine:3.20" }"#

        let (runtime, _, createCount) = createFailsThenSucceedsRuntime()
        let (editor, editorRunner) = cloneEditor()

        try MiniTest.expectThrows({
            _ = try CloneCommand.run(
                options: CloneOptions(gitURL: "https://github.com/org/recovery.git", skipPull: true),
                runtime: runtime,
                git: git,
                credentials: MockGitCredential(),
                localEnv: [:],
                isTTY: true,
                openEditorPrompt: clonePrompt(answers: ["n"]),
                editor: editor
            )
        }) { error in
            let cli = error as? CLIError
            try MiniTest.expectEqual(cli?.code, CLIErrorCode.runtimeFailed, "original failure rethrown on decline")
        }
        try MiniTest.expectEqual(createCount(), 1, "decline does not retry")
        try MiniTest.expectEqual(git.fetchConfigCalls.count, 1)
        try MiniTest.expect(editorRunner.calls.isEmpty, "decline never opens the editor")
        // Checkout retained for a later --resume.
        try MiniTest.expectEqual(retainedEntries(in: retainedRoot).count, 1)
    }),

    ("cloneInvalidConfigReopensEditorBeforeRetry", {
        let restore = CloneGitFeatureTestSupport.installOverrides()
        defer { restore() }
        let retainedRoot = FileManager.default.temporaryDirectory
            .appendingPathComponent("clone-rec-root-\(UUID().uuidString)", isDirectory: true).path
        CloneCommand.retainedCheckoutRootOverride = retainedRoot
        defer {
            CloneCommand.retainedCheckoutRootOverride = nil
            try? FileManager.default.removeItem(atPath: retainedRoot)
        }

        let git = MockGitClient()
        git.configJSONToWrite = #"{ "image": "alpine:3.20" }"#

        let (runtime, _, createCount) = createFailsThenSucceedsRuntime()

        // Editor writes invalid config on the first save, valid on the second.
        final class Edits: @unchecked Sendable { var count = 0 }
        let edits = Edits()
        let editorRunner = MockProcessRunner()
        editorRunner.handlers = [{ args in
            edits.count += 1
            let filePath = args.last!
            let content = edits.count == 1 ? "{ invalid" : #"{ "image": "alpine:3.20" }"#
            try? content.write(toFile: filePath, atomically: true, encoding: .utf8)
            return ProcessResult(exitCode: 0, stdout: Data(), stderr: Data())
        }]
        let editor = RecoveryEditor(
            environment: ["EDITOR": "/tools/editor"],
            runner: editorRunner,
            executableChecker: { $0 == "/tools/editor" }
        )

        let result = try CloneCommand.run(
            options: CloneOptions(gitURL: "https://github.com/org/recovery.git", skipPull: true),
            runtime: runtime,
            git: git,
            credentials: MockGitCredential(),
            localEnv: [:],
            isTTY: true,
            openEditorPrompt: clonePrompt(answers: ["y"]),
            editor: editor
        )
        try MiniTest.expectEqual(result.outcome, "success")
        try MiniTest.expectEqual(edits.count, 2, "invalid config reopens the editor")
        try MiniTest.expectEqual(createCount(), 2, "retry runs after a valid edit")
        try MiniTest.expectEqual(git.fetchConfigCalls.count, 1, "retry must not re-fetch git")
    }),

    ("cloneResumeReusesRetainedCheckoutWithoutRefetching", {
        let restore = CloneGitFeatureTestSupport.installOverrides()
        defer { restore() }
        let retainedRoot = FileManager.default.temporaryDirectory
            .appendingPathComponent("clone-rec-root-\(UUID().uuidString)", isDirectory: true).path
        CloneCommand.retainedCheckoutRootOverride = retainedRoot
        defer {
            CloneCommand.retainedCheckoutRootOverride = nil
            try? FileManager.default.removeItem(atPath: retainedRoot)
        }

        let git = MockGitClient()
        git.configJSONToWrite = #"{ "image": "alpine:3.20" }"#

        // First run: non-TTY create failure retains the checkout.
        let (failingRuntime, _, _) = createFailsThenSucceedsRuntime()
        var retainedDir: String = ""
        try MiniTest.expectThrows({
            _ = try CloneCommand.run(
                options: CloneOptions(gitURL: "https://github.com/org/recovery.git", skipPull: true),
                runtime: failingRuntime,
                git: git,
                credentials: MockGitCredential(),
                localEnv: [:],
                isTTY: false
            )
        }) { _ in
            let retained = retainedEntries(in: retainedRoot)
            try MiniTest.expectEqual(retained.count, 1)
            retainedDir = retained[0]
        }
        try MiniTest.expectEqual(git.fetchConfigCalls.count, 1)

        // Resume: create succeeds; no fresh fetchConfig.
        let resumeMock = MockProcessRunner()
        resumeMock.handlers = CloneRuntimeMock.handlers()
        let resumeRuntime = AppleContainerRuntime(executablePath: "/usr/local/bin/container", runner: resumeMock)
        let resumed = try CloneCommand.run(
            options: CloneOptions(
                gitURL: "https://github.com/org/recovery.git",
                skipPull: true,
                resumeConfigDir: retainedDir
            ),
            runtime: resumeRuntime,
            git: git,
            credentials: MockGitCredential(),
            localEnv: [:],
            isTTY: false
        )
        try MiniTest.expectEqual(resumed.outcome, "success")
        try MiniTest.expectEqual(git.fetchConfigCalls.count, 1, "resume must not re-fetch git")
        try MiniTest.expect(!FileManager.default.fileExists(atPath: retainedDir), "successful resume cleans retained checkout")
    }),

    ("cloneTTYRecoveryPersistsEditedConfigAfterPopulate", {
        let restore = CloneGitFeatureTestSupport.installOverrides()
        defer { restore() }
        let retainedRoot = FileManager.default.temporaryDirectory
            .appendingPathComponent("clone-rec-root-\(UUID().uuidString)", isDirectory: true).path
        CloneCommand.retainedCheckoutRootOverride = retainedRoot
        defer {
            CloneCommand.retainedCheckoutRootOverride = nil
            try? FileManager.default.removeItem(atPath: retainedRoot)
        }

        let gitURL = "https://github.com/org/recovery.git"
        let dest = cloneWorkspaceConfigPath(gitURL: gitURL)
        let files = CloneWorkspaceFiles()
        let git = MockGitClient()
        git.configJSONToWrite = cloneOriginalConfigJSON
        let (runtime, mock, createCount) = persistAwareRuntime(
            workspaceConfigPath: dest,
            files: files,
            createFailures: 1
        )
        let (editor, editorRunner) = cloneEditorWriting(cloneEditedConfigJSON)

        let result = try CloneCommand.run(
            options: CloneOptions(gitURL: gitURL, skipPull: true),
            runtime: runtime,
            git: git,
            credentials: MockGitCredential(),
            localEnv: [:],
            isTTY: true,
            openEditorPrompt: clonePrompt(answers: ["y"]),
            editor: editor
        )
        try MiniTest.expectEqual(result.outcome, "success")
        try MiniTest.expectEqual(createCount(), 2)
        try MiniTest.expectEqual(editorRunner.calls.count, 1)
        let writes = persistWrites(in: mock)
        try MiniTest.expectEqual(writes.count, 1, "recovery retry persists edited bytes after populate")
        try MiniTest.expect(writes[0].arguments.contains(dest), "persist targets the workspace config path")
        try MiniTest.expectEqual(writes[0].stdinData, cloneEditedConfigBytes)
        try MiniTest.expectEqual(files.files[dest], cloneEditedConfigBytes)

        let opened = try runtime.readFile(nameOrId: result.containerId, path: dest)
        try MiniTest.expectEqual(opened, cloneEditedConfigBytes, "later in-container open sees the edited bytes")
    }),

    ("cloneResumePersistsEditedConfigAfterPopulate", {
        let restore = CloneGitFeatureTestSupport.installOverrides()
        defer { restore() }
        let retainedRoot = FileManager.default.temporaryDirectory
            .appendingPathComponent("clone-rec-root-\(UUID().uuidString)", isDirectory: true).path
        CloneCommand.retainedCheckoutRootOverride = retainedRoot
        defer {
            CloneCommand.retainedCheckoutRootOverride = nil
            try? FileManager.default.removeItem(atPath: retainedRoot)
        }

        let gitURL = "https://github.com/org/recovery.git"
        let dest = cloneWorkspaceConfigPath(gitURL: gitURL)
        let git = MockGitClient()
        git.configJSONToWrite = cloneOriginalConfigJSON

        let (failingRuntime, _, _) = persistAwareRuntime(
            workspaceConfigPath: dest,
            files: CloneWorkspaceFiles(),
            createFailures: 1
        )
        var retainedDir: String = ""
        try MiniTest.expectThrows({
            _ = try CloneCommand.run(
                options: CloneOptions(gitURL: gitURL, skipPull: true),
                runtime: failingRuntime,
                git: git,
                credentials: MockGitCredential(),
                localEnv: [:],
                isTTY: false
            )
        }) { _ in
            let retained = retainedEntries(in: retainedRoot)
            try MiniTest.expectEqual(retained.count, 1)
            retainedDir = retained[0]
        }

        let retainedConfig = (retainedDir as NSString)
            .appendingPathComponent(ConfigDiscovery.nestedRelativePath)
        try cloneEditedConfigJSON.write(toFile: retainedConfig, atomically: true, encoding: .utf8)

        let files = CloneWorkspaceFiles()
        let (resumeRuntime, resumeMock, _) = persistAwareRuntime(
            workspaceConfigPath: dest,
            files: files
        )
        let resumed = try CloneCommand.run(
            options: CloneOptions(gitURL: gitURL, skipPull: true, resumeConfigDir: retainedDir),
            runtime: resumeRuntime,
            git: git,
            credentials: MockGitCredential(),
            localEnv: [:],
            isTTY: false
        )
        try MiniTest.expectEqual(resumed.outcome, "success")
        try MiniTest.expectEqual(git.fetchConfigCalls.count, 1, "resume must not re-fetch git")
        let writes = persistWrites(in: resumeMock)
        try MiniTest.expectEqual(writes.count, 1, "--resume persists retained edited bytes after populate")
        try MiniTest.expect(writes[0].arguments.contains(dest))
        try MiniTest.expectEqual(writes[0].stdinData, cloneEditedConfigBytes)

        let opened = try resumeRuntime.readFile(nameOrId: resumed.containerId, path: dest)
        try MiniTest.expectEqual(opened, cloneEditedConfigBytes, "later in-container open sees the edited bytes")
    }),

    ("cloneFirstSuccessDoesNotOverlayWorkspaceConfig", {
        let restore = CloneGitFeatureTestSupport.installOverrides()
        defer { restore() }

        let gitURL = "https://github.com/org/recovery.git"
        let dest = cloneWorkspaceConfigPath(gitURL: gitURL)
        let files = CloneWorkspaceFiles()
        let git = MockGitClient()
        git.configJSONToWrite = cloneOriginalConfigJSON
        let (runtime, mock, createCount) = persistAwareRuntime(
            workspaceConfigPath: dest,
            files: files
        )

        let result = try CloneCommand.run(
            options: CloneOptions(gitURL: gitURL, skipPull: true),
            runtime: runtime,
            git: git,
            credentials: MockGitCredential(),
            localEnv: [:],
            isTTY: false
        )
        try MiniTest.expectEqual(result.outcome, "success")
        try MiniTest.expectEqual(createCount(), 1)
        try MiniTest.expect(persistWrites(in: mock).isEmpty, "first clone must not overlay the workspace config")
        try MiniTest.expectEqual(files.files[dest], Data(cloneOriginalConfigJSON.utf8))

        let opened = try runtime.readFile(nameOrId: result.containerId, path: dest)
        try MiniTest.expectEqual(opened, Data(cloneOriginalConfigJSON.utf8), "non-recovery clone keeps git-populated bytes")
    }),

    ("cloneFetchFailureDoesNotOverlayWorkspaceConfig", {
        let restore = CloneGitFeatureTestSupport.installOverrides()
        defer { restore() }

        let gitURL = "https://github.com/org/fetch.git"
        let dest = cloneWorkspaceConfigPath(gitURL: gitURL)
        let files = CloneWorkspaceFiles()
        let git = MockGitClient()
        git.fetchConfigHandler = { _, _ in
            throw CLIError(code: CLIErrorCode.gitFailed, message: "fetch failed")
        }
        let (runtime, mock, createCount) = persistAwareRuntime(
            workspaceConfigPath: dest,
            files: files
        )
        let (editor, editorRunner) = cloneEditorWriting(cloneEditedConfigJSON)

        try MiniTest.expectThrows({
            _ = try CloneCommand.run(
                options: CloneOptions(gitURL: gitURL, skipPull: true),
                runtime: runtime,
                git: git,
                credentials: MockGitCredential(),
                localEnv: [:],
                isTTY: true,
                openEditorPrompt: clonePrompt(answers: ["y"]),
                editor: editor
            )
        }) { error in
            try MiniTest.expectEqual((error as? CLIError)?.code, CLIErrorCode.gitFailed)
        }
        try MiniTest.expectEqual(createCount(), 0, "fetch failure never reaches create")
        try MiniTest.expect(editorRunner.calls.isEmpty, "no editable config → no recovery editor")
        try MiniTest.expect(persistWrites(in: mock).isEmpty, "no overlay when fetch fails before a config exists")
        try MiniTest.expect(files.files.isEmpty)
    }),

    ("cloneTTYRenamePersistsNameWithoutEditorAndOverlaysAfterPopulate", {
        let restore = CloneGitFeatureTestSupport.installOverrides()
        defer { restore() }
        let retainedRoot = FileManager.default.temporaryDirectory
            .appendingPathComponent("clone-rename-\(UUID().uuidString)", isDirectory: true).path
        CloneCommand.retainedCheckoutRootOverride = retainedRoot
        defer {
            CloneCommand.retainedCheckoutRootOverride = nil
            try? FileManager.default.removeItem(atPath: retainedRoot)
        }

        let gitURL = "https://github.com/org/my-app.git"
        let dest = cloneWorkspaceConfigPath(gitURL: gitURL)
        let files = CloneWorkspaceFiles()
        let git = MockGitClient()
        git.configJSONToWrite = #"{ "name": "My App", "image": "alpine:3.20" }"#
        let other = ContainerIdentity.volumeModeIdentity(
            gitURL: "https://github.com/other/repo.git",
            configRelativePath: ".devcontainer/devcontainer.json",
            configName: "My App"
        )
        let occupant = MockProcessRunner.containerListJSON(
            id: "my-app",
            state: "running",
            labels: ContainerIdentity.volumeModeLabels(identity: other, configHash: "h")
        )
        var lists = 0
        let (runtime, mock, _) = persistAwareRuntime(workspaceConfigPath: dest, files: files)
        mock.handlers.insert({ args in
            if args.starts(with: ["list"]) {
                lists += 1
                let payload: [[String: Any]] = lists == 1 ? [occupant] : []
                return ProcessResult(
                    exitCode: 0,
                    stdout: try! JSONSerialization.data(withJSONObject: payload),
                    stderr: Data()
                )
            }
            return nil
        }, at: 0)

        let (editor, editorRunner) = cloneEditor()
        let result = try CloneCommand.run(
            options: CloneOptions(gitURL: gitURL, skipPull: true),
            runtime: runtime,
            git: git,
            credentials: MockGitCredential(),
            localEnv: [:],
            isTTY: true,
            openEditorPrompt: clonePrompt(answers: ["y", "My App 2"]),
            editor: editor
        )
        try MiniTest.expectEqual(result.outcome, "success")
        try MiniTest.expect(editorRunner.calls.isEmpty, "foreign rename must not open the recovery editor")
        try MiniTest.expect(!mock.calls.contains { $0.arguments.first == "delete" })
        let writes = persistWrites(in: mock)
        try MiniTest.expectEqual(writes.count, 1, "rename retry overlays persisted name after populate")
        let overlay = String(data: writes[0].stdinData ?? Data(), encoding: .utf8) ?? ""
        try MiniTest.expect(overlay.contains("my-app-2"))
        try MiniTest.expectEqual(files.files[dest].flatMap { String(data: $0, encoding: .utf8) }?.contains("my-app-2"), true)
    }),

    ("cloneNonTTYAndJsonNeverPromptOnForeignName", {
        let restore = CloneGitFeatureTestSupport.installOverrides()
        defer { restore() }
        let gitURL = "https://github.com/org/my-app.git"
        let dest = cloneWorkspaceConfigPath(gitURL: gitURL)
        let files = CloneWorkspaceFiles()
        let git = MockGitClient()
        git.configJSONToWrite = #"{ "name": "My App", "image": "alpine:3.20" }"#
        let other = ContainerIdentity.volumeModeIdentity(
            gitURL: "https://github.com/other/repo.git",
            configRelativePath: ".devcontainer/devcontainer.json",
            configName: "My App"
        )
        let occupant = MockProcessRunner.containerListJSON(
            id: "my-app",
            state: "running",
            labels: ContainerIdentity.volumeModeLabels(identity: other, configHash: "h")
        )
        let (runtime, mock, createCount) = persistAwareRuntime(workspaceConfigPath: dest, files: files)
        mock.handlers.insert({ args in
            if args.starts(with: ["list"]) {
                return ProcessResult(
                    exitCode: 0,
                    stdout: try! JSONSerialization.data(withJSONObject: [occupant]),
                    stderr: Data()
                )
            }
            return nil
        }, at: 0)
        let (editor, editorRunner) = cloneEditor()
        final class Writes: @unchecked Sendable { var lines: [String] = [] }
        let writes = Writes()
        try MiniTest.expectThrows({
            _ = try CloneCommand.run(
                options: CloneOptions(gitURL: gitURL, skipPull: true, jsonOutput: true),
                runtime: runtime,
                git: git,
                credentials: MockGitCredential(),
                localEnv: [:],
                isTTY: true,
                openEditorPrompt: RecoveryOpenEditorPrompt(
                    readLine: { "y" },
                    writeError: { writes.lines.append($0) }
                ),
                editor: editor
            )
        }) { error in
            let err = error as! CLIError
            try MiniTest.expectEqual(err.code, CLIErrorCode.containerNameInUse)
            try MiniTest.expect(err.hint?.contains("devcontainer.json") == true)
            try MiniTest.expect(err.hint?.contains("clone") == true)
        }
        try MiniTest.expectEqual(createCount(), 0)
        try MiniTest.expect(editorRunner.calls.isEmpty)
        try MiniTest.expect(writes.lines.isEmpty)
        try MiniTest.expect(!mock.calls.contains { $0.arguments.first == "delete" })
    })
]
