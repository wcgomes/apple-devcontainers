import Foundation
@testable import ADevContainerLib

private func orchestratorLabels(
    mode: String = ContainerIdentity.workspaceModeVolume,
    gitURL: String = "https://example.test/repo.git",
    volume: String = "adev-repo-ws",
    config: String = ".devcontainer/devcontainer.json"
) -> [String: String] {
    [
        ContainerIdentity.labelManaged: ContainerIdentity.managedValue,
        ContainerIdentity.labelWorkspaceMode: mode,
        ContainerIdentity.labelGitURL: gitURL,
        ContainerIdentity.labelWorkspaceVolume: volume,
        ContainerIdentity.labelConfigFile: config,
        ContainerIdentity.labelWorkspaceFolder: "/workspaces/repo"
    ]
}

private func orchestratorImageJSON() -> Data {
    let object: [String: Any] = [
        "configuration": [
            "name": RecoveryHelper.helperImageReference,
            "variants": [[
                "digest": RecoveryHelper.helperImageDigest,
                "platform": ["os": "linux", "architecture": "arm64", "variant": "v8"]
            ]]
        ]
    ]
    return try! JSONSerialization.data(withJSONObject: [object])
}

private final class RecoveryWritingEditorRunner: ProcessRunning, @unchecked Sendable {
    let bytes: Data
    var launches = 0

    init(bytes: Data) { self.bytes = bytes }

    func run(
        executable: String,
        arguments: [String],
        environment: [String: String]?,
        currentDirectory: String?,
        stdinData: Data?
    ) throws -> ProcessResult {
        launches += 1
        if let path = arguments.last {
            try bytes.write(to: URL(fileURLWithPath: path))
        }
        return ProcessResult(exitCode: 0, stdout: Data(), stderr: Data())
    }
}

private final class RecoverySequenceEditorRunner: ProcessRunning, @unchecked Sendable {
    let payloads: [Data?]
    var launches = 0

    init(payloads: [Data?]) { self.payloads = payloads }

    func run(
        executable: String,
        arguments: [String],
        environment: [String: String]?,
        currentDirectory: String?,
        stdinData: Data?
    ) throws -> ProcessResult {
        let index = min(launches, payloads.count - 1)
        launches += 1
        if let payload = payloads[index], let path = arguments.last {
            try payload.write(to: URL(fileURLWithPath: path))
        }
        return ProcessResult(exitCode: 0, stdout: Data(), stderr: Data())
    }
}

private struct RecoveryCancellationRunner: ProcessRunning {
    func run(
        executable: String,
        arguments: [String],
        environment: [String: String]?,
        currentDirectory: String?,
        stdinData: Data?
    ) throws -> ProcessResult {
        ProcessResult(exitCode: 130, stdout: Data(), stderr: Data(), terminationReason: .signal)
    }
}

private func recoveryMountInspectionJSON(containerID: String, volume: String = "adev-repo-ws") -> Data {
    let object: [String: Any] = [
        "configuration": [
            "id": containerID,
            "mounts": [[
                "source": "/var/lib/container/volumes/\(volume).img",
                "destination": "/workspaces/repo",
                "options": [],
                "type": ["volume": ["name": volume]]
            ]]
        ]
    ]
    return try! JSONSerialization.data(withJSONObject: [object])
}

private func installRecoveryRuntime(
    _ mock: MockProcessRunner,
    rawBytes: Data,
    helperIDs: [String] = ["helper-id"],
    failCreateAfter: Int? = nil
) {
    var creates = 0
    mock.handlers.append { args in
        if args.starts(with: ["list", "--all"]) {
            return ProcessResult(exitCode: 0, stdout: Data("[]".utf8), stderr: Data())
        }
        if args.starts(with: ["volume", "list"]) {
            return ProcessResult(exitCode: 0, stdout: try! JSONSerialization.data(withJSONObject: [["configuration": ["name": "adev-repo-ws"]]]), stderr: Data())
        }
        if args.starts(with: ["image", "inspect"]) {
            return ProcessResult(exitCode: 0, stdout: orchestratorImageJSON(), stderr: Data())
        }
        if args.first == "create" {
            if let failCreateAfter, creates >= failCreateAfter {
                return ProcessResult(exitCode: 1, stdout: Data(), stderr: Data("helper create failed".utf8))
            }
            let helperID = helperIDs[min(creates, helperIDs.count - 1)]
            creates += 1
            return ProcessResult(exitCode: 0, stdout: Data("\(helperID)\n".utf8), stderr: Data())
        }
        if args.first == "inspect" {
            let helperID = args.last ?? helperIDs[0]
            return ProcessResult(exitCode: 0, stdout: recoveryMountInspectionJSON(containerID: helperID), stderr: Data())
        }
        if args.first == "exec", args.contains("cat") {
            return ProcessResult(exitCode: 0, stdout: rawBytes, stderr: Data())
        }
        if args.first == "exec", args.contains("adevcontainer-recovery-write") {
            let hash = RecoveryConfigSession.sha256Hex(rawBytes)
            return ProcessResult(exitCode: 0, stdout: Data("RECOVERY_APPLIED:\(hash)\n".utf8), stderr: Data())
        }
        return nil
    }
}

/// Injectable open-editor prompt for TTY recovery tests. Default answers Enter (affirmative).
private func affirmativeOpenEditorPrompt(
    answers: [String?] = [""],
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

private func declineOpenEditorPrompt(answer: String? = "n") -> RecoveryOpenEditorPrompt {
    affirmativeOpenEditorPrompt(answers: [answer])
}

private func runJSONDispatchError() throws -> (stdout: Data, stderr: Data, exitCode: Int32) {
    let binary = TestRepo.root().appendingPathComponent(".build/debug/adevcontainer")
    guard FileManager.default.isExecutableFile(atPath: binary.path) else {
        try MiniTest.skip("adevcontainer executable is not built")
    }
    let process = Process()
    process.executableURL = binary
    process.arguments = ["rebuild", "--json", "--name", "definitely-missing-recovery-container"]
    let stdout = Pipe()
    let stderr = Pipe()
    process.standardOutput = stdout
    process.standardError = stderr
    try process.run()
    process.waitUntilExit()
    return (
        stdout.fileHandleForReading.readDataToEndOfFile(),
        stderr.fileHandleForReading.readDataToEndOfFile(),
        process.terminationStatus
    )
}

nonisolated(unsafe) let recoveryOrchestratorTests: [(String, () throws -> Void)] = [
    ("recoveryOrchestratorEligibilityMatrix", {
        let labels = orchestratorLabels()
        try MiniTest.expect(RecoveryHelper.isEligible(labels: labels))
        try MiniTest.expect(!RecoveryHelper.isEligible(labels: orchestratorLabels(mode: ContainerIdentity.workspaceModeBind)))
        try MiniTest.expect(!RecoveryHelper.isEligible(labels: orchestratorLabels(gitURL: "")))
        try MiniTest.expect(!RecoveryHelper.isEligible(labels: orchestratorLabels(volume: "")))
        try MiniTest.expect(!RecoveryHelper.isEligible(labels: orchestratorLabels(config: "")))
    }),
    ("recoveryOrchestratorPreparePreflightsWithoutRuntimeMutation", {
        let mock = MockProcessRunner()
        mock.handlers.append { args in
            if args.starts(with: ["volume", "list"]) {
                return ProcessResult(exitCode: 0, stdout: try! JSONSerialization.data(withJSONObject: [["configuration": ["name": "adev-repo-ws"]]]), stderr: Data())
            }
            if args.starts(with: ["image", "inspect"]) {
                return ProcessResult(exitCode: 0, stdout: orchestratorImageJSON(), stderr: Data())
            }
            if args.starts(with: ["inspect", "helper-id"]) {
                let object: [String: Any] = [
                    "configuration": [
                        "id": "helper-id",
                        "mounts": [[
                            "source": "/var/lib/container/volumes/adev-repo-ws.img",
                            "destination": "/workspaces/repo",
                            "options": [],
                            "type": ["volume": ["name": "adev-repo-ws"]]
                        ]]
                    ]
                ]
                return ProcessResult(exitCode: 0, stdout: try! JSONSerialization.data(withJSONObject: [object]), stderr: Data())
            }
            return nil
        }
        let runtime = AppleContainerRuntime(executablePath: "container", runner: mock)
        let container = ContainerInfo(id: "old", name: "old", state: "running", labels: orchestratorLabels(), image: "alpine")
        let raw = RawVolumeConfig(
            bytes: Data(#"{"image":"alpine:3.20"}"#.utf8),
            pathInContainer: "/workspaces/repo/.devcontainer/devcontainer.json",
            workspaceFolder: "/workspaces/repo",
            workspaceFolderBasename: "repo"
        )
        let prepared = try RecoveryOrchestrator.prepare(
            container: container,
            rawConfig: raw,
            runtime: runtime,
            sessionID: "orchestrator-test",
            pullIfMissing: false
        )
        defer { try? prepared.session.cleanup() }
        try MiniTest.expectEqual(prepared.session.originalHash, RecoveryConfigSession.sha256Hex(raw.bytes))
        try MiniTest.expect(!mock.calls.contains { $0.arguments.first == "create" || $0.arguments.first == "delete" })
    }),
    ("recoveryOrchestratorRejectsMismatchedRetryAttachment", {
        let fileManager = FileManager.default
        let sessionID = "mismatch-session"
        let labels = orchestratorLabels()
        let helperLabels = labels.merging([
            RecoveryHelper.recoveryMarkerLabel: RecoveryHelper.recoveryMarkerValue,
            RecoveryHelper.recoverySessionLabel: sessionID
        ]) { _, new in new }
        let helper = ContainerInfo(id: "mismatch-helper", name: "old", state: "running", labels: helperLabels, image: RecoveryHelper.helperImageReference)
        let raw = RawVolumeConfig(
            bytes: Data(#"{"image":"alpine:3.20"}"#.utf8),
            pathInContainer: "/workspaces/repo/.devcontainer/devcontainer.json",
            workspaceFolder: "/workspaces/repo",
            workspaceFolderBasename: "repo"
        )
        let session = try RecoveryConfigSession(
            rawVolumeConfig: raw,
            targetContainerID: "old-id",
            targetContainerName: "old",
            workspaceVolume: "adev-repo-ws",
            configFile: ".devcontainer/devcontainer.json",
            fileManager: fileManager,
            sessionID: sessionID
        )
        defer { try? session.cleanup() }
        let mock = MockProcessRunner()
        mock.handlers.append { args in
            if args.starts(with: ["inspect", "mismatch-helper"]) {
                let object: [String: Any] = [
                    "configuration": [
                        "id": "mismatch-helper",
                        "mounts": [[
                            "source": "/var/lib/container/volumes/other.img",
                            "destination": "/workspaces/other",
                            "options": [],
                            "type": ["volume": ["name": "other"]]
                        ]]
                    ]
                ]
                return ProcessResult(exitCode: 0, stdout: try! JSONSerialization.data(withJSONObject: [object]), stderr: Data())
            }
            return nil
        }
        let runtime = AppleContainerRuntime(executablePath: "container", runner: mock)
        try MiniTest.expectThrows({
            _ = try RecoveryOrchestrator.openRetry(
                helper: helper,
                runtime: runtime,
                fileManager: fileManager,
                pullIfMissing: false
            )
        }) { error in
            try MiniTest.expectEqual((error as? CLIError)?.code, CLIErrorCode.recoveryUnavailable)
        }
    }),
    ("recoveryOrchestratorDetachedFailureIsFailClosed", {
        let mock = MockProcessRunner()
        mock.handlers.append { args in
            if args.starts(with: ["list", "--all"]) {
                return ProcessResult(exitCode: 0, stdout: Data(#"[{"id":"still-attached","configuration":{"id":"still-attached","labels":{},"mounts":[{"type":{"volume":{"name":"ws"}},"destination":"/workspaces/repo"}]},"status":{"state":"running"}}]"#.utf8), stderr: Data())
            }
            return nil
        }
        let runtime = AppleContainerRuntime(executablePath: "container", runner: mock)
        try MiniTest.expectThrows({
            try RecoveryOrchestrator.detachFailedContainer(containerID: nil, workspaceVolume: "ws", runtime: runtime)
        }) { error in
            try MiniTest.expectEqual((error as? CLIError)?.code, CLIErrorCode.recoveryUnavailable)
        }
        try MiniTest.expect(!mock.calls.contains { $0.arguments.first == "volume" })
    }),
    ("recoveryOrchestratorOpensExistingRetrySession", {
        let fileManager = FileManager.default
        let sessionID = "retry-session"
        let labels = orchestratorLabels()
        let helperLabels = labels.merging([
            RecoveryHelper.recoveryMarkerLabel: RecoveryHelper.recoveryMarkerValue,
            RecoveryHelper.recoverySessionLabel: sessionID
        ]) { _, new in new }
        let helper = ContainerInfo(id: "helper-id", name: "old", state: "running", labels: helperLabels, image: RecoveryHelper.helperImageReference)
        let raw = RawVolumeConfig(
            bytes: Data(#"{"image":"alpine:3.20"}"#.utf8),
            pathInContainer: "/workspaces/repo/.devcontainer/devcontainer.json",
            workspaceFolder: "/workspaces/repo",
            workspaceFolderBasename: "repo"
        )
        let session = try RecoveryConfigSession(
            rawVolumeConfig: raw,
            targetContainerID: "old-id",
            targetContainerName: "old",
            workspaceVolume: "adev-repo-ws",
            configFile: ".devcontainer/devcontainer.json",
            fileManager: fileManager,
            sessionID: sessionID
        )
        defer { try? session.cleanup() }
        let mock = MockProcessRunner()
        mock.handlers.append { args in
            if args.starts(with: ["volume", "list"]) {
                return ProcessResult(exitCode: 0, stdout: try! JSONSerialization.data(withJSONObject: [["configuration": ["name": "adev-repo-ws"]]]), stderr: Data())
            }
            if args.starts(with: ["image", "inspect"]) {
                return ProcessResult(exitCode: 0, stdout: orchestratorImageJSON(), stderr: Data())
            }
            if args.starts(with: ["inspect", "helper-id"]) {
                let object: [String: Any] = [
                    "configuration": [
                        "id": "helper-id",
                        "mounts": [[
                            "source": "/var/lib/container/volumes/adev-repo-ws.img",
                            "destination": "/workspaces/repo",
                            "options": [],
                            "type": ["volume": ["name": "adev-repo-ws"]]
                        ]]
                    ]
                ]
                return ProcessResult(exitCode: 0, stdout: try! JSONSerialization.data(withJSONObject: [object]), stderr: Data())
            }
            return nil
        }
        let runtime = AppleContainerRuntime(executablePath: "container", runner: mock)
        let opened = try RecoveryOrchestrator.openRetry(
            helper: helper,
            runtime: runtime,
            fileManager: fileManager,
            pullIfMissing: false
        )
        try MiniTest.expectEqual(opened.session.sessionID, sessionID)
        try MiniTest.expectEqual(opened.session.targetContainerName, "old")
        try MiniTest.expect(!mock.calls.contains { $0.arguments.first == "create" || $0.arguments.first == "delete" })
    }),
    ("recoveryOrchestratorRejectsTraversalSessionMarker", {
        let labels = orchestratorLabels().merging([
            RecoveryHelper.recoveryMarkerLabel: RecoveryHelper.recoveryMarkerValue,
            RecoveryHelper.recoverySessionLabel: "../outside"
        ]) { _, new in new }
        let helper = ContainerInfo(
            id: "helper-id",
            name: "old",
            state: "running",
            labels: labels,
            image: RecoveryHelper.helperImageReference
        )
        let mock = MockProcessRunner()
        let runtime = AppleContainerRuntime(executablePath: "container", runner: mock)
        try MiniTest.expectThrows({
            _ = try RecoveryOrchestrator.openRetry(
                helper: helper,
                runtime: runtime,
                pullIfMissing: false
            )
        }) { error in
            try MiniTest.expectEqual((error as? CLIError)?.code, CLIErrorCode.recoveryUnavailable)
        }
        try MiniTest.expect(mock.calls.isEmpty, "unsafe session id is rejected before filesystem or runtime access")
    }),
    ("recoveryOrchestratorRejectsWrongRetainedHelperImage", {
        let sessionID = "wrong-image-session"
        let raw = RawVolumeConfig(
            bytes: Data(#"{"image":"alpine:3.20"}"#.utf8),
            pathInContainer: "/workspaces/repo/.devcontainer/devcontainer.json",
            workspaceFolder: "/workspaces/repo",
            workspaceFolderBasename: "repo"
        )
        let session = try RecoveryConfigSession(
            rawVolumeConfig: raw,
            targetContainerID: "old-id",
            targetContainerName: "old",
            workspaceVolume: "adev-repo-ws",
            configFile: ".devcontainer/devcontainer.json",
            sessionID: sessionID
        )
        defer { try? session.cleanup() }
        let helperLabels = orchestratorLabels().merging([
            RecoveryHelper.recoveryMarkerLabel: RecoveryHelper.recoveryMarkerValue,
            RecoveryHelper.recoverySessionLabel: sessionID
        ]) { _, new in new }
        let helper = ContainerInfo(
            id: "helper-id",
            name: "old",
            state: "running",
            labels: helperLabels,
            image: "docker.io/library/alpine:3.20"
        )
        let mock = MockProcessRunner()
        let runtime = AppleContainerRuntime(executablePath: "container", runner: mock)
        try MiniTest.expectThrows({
            _ = try RecoveryOrchestrator.openRetry(
                helper: helper,
                runtime: runtime,
                pullIfMissing: false
            )
        }) { error in
            try MiniTest.expectEqual((error as? CLIError)?.code, CLIErrorCode.recoveryUnavailable)
        }
        try MiniTest.expect(mock.calls.isEmpty, "wrong helper image is rejected before editing or mounting")
    }),
    ("recoveryErrorDetailsEncodeWithoutRawConfig", {
        let details = RecoveryErrorDetails(
            helperContainerID: "helper-id",
            helperContainerName: "adev-repo",
            sessionID: "session-id",
            workspaceVolume: "adev-repo-ws",
            configPath: "/workspaces/repo/.devcontainer/devcontainer.json",
            tempFile: "/tmp/adev-recovery-session/devcontainer.json",
            expectedHash: String(repeating: "a", count: 64),
            failureKind: CLIErrorCode.lifecycleFailed,
            editCommand: "'/usr/bin/vi' '/tmp/adev-recovery-session/devcontainer.json'",
            retryCommand: "'adevcontainer' 'rebuild' '--name' 'adev-repo'",
            cleanupCommand: "'adevcontainer' 'delete' '--name' 'adev-repo'"
        )
        let error = CLIError(
            code: CLIErrorCode.recoveryUnavailable,
            message: "recovery retained",
            recovery: details
        )
        let object = error.jsonObject()
        let recovery = object["recovery"] as? [String: Any]
        try MiniTest.expectEqual(recovery?["helperContainerId"] as? String, "helper-id")
        try MiniTest.expectEqual(recovery?["configPath"] as? String, details.configPath)
        try MiniTest.expect(recovery?["editCommand"] != nil)
        try MiniTest.expect(recovery?["rawConfig"] == nil)
    }),
    ("recoveryErrorJSONRenderingIsStructuredAndStdoutSafe", {
        let details = RecoveryErrorDetails(
            helperContainerID: "helper-id",
            helperContainerName: "adev-repo",
            sessionID: "json-session",
            workspaceVolume: "adev-repo-ws",
            configPath: "/workspaces/repo/.devcontainer/devcontainer.json",
            tempFile: "/tmp/adev-recovery-session/devcontainer.json",
            expectedHash: String(repeating: "b", count: 64),
            failureKind: CLIErrorCode.recoveryUnavailable,
            editCommand: "'/usr/bin/vi' '/tmp/adev-recovery-session/devcontainer.json'",
            retryCommand: "'adevcontainer' 'rebuild' '--name' 'adev-repo'",
            cleanupCommand: "'adevcontainer' 'delete' '--name' 'adev-repo'"
        )
        let codes = [
            CLIErrorCode.recoveryUnavailable,
            CLIErrorCode.recoveryConflict,
            CLIErrorCode.recoveryCancelled,
            CLIErrorCode.recoveryVerificationFailed
        ]

        for code in codes {
            let error = CLIError(
                code: code,
                message: "recovery failure",
                hint: "session retained",
                recovery: details
            )
            let jsonData = CLIErrorOutput.data(for: error, json: true)
            let object = try JSONSerialization.jsonObject(with: jsonData) as? [String: Any]
            try MiniTest.expectEqual(object?["outcome"] as? String, "error", code)
            try MiniTest.expectEqual(object?["code"] as? String, code, code)
            try MiniTest.expect(object?["containerId"] == nil, "error JSON has no success containerId")
            try MiniTest.expect(object?["rawConfig"] == nil, "error JSON has no raw config")

            let human = String(data: CLIErrorOutput.data(for: error, json: false), encoding: .utf8) ?? ""
            try MiniTest.expect(human.hasPrefix("error:"), "human rendering remains non-JSON")
        }
    }),
    ("recoveryJSONDispatchWritesErrorToStderrOnly", {
        let result = try runJSONDispatchError()
        try MiniTest.expect(result.exitCode != 0)
        try MiniTest.expect(result.stdout.isEmpty, "JSON failure emits no success/stdout payload")
        let object = try JSONSerialization.jsonObject(with: result.stderr) as? [String: Any]
        try MiniTest.expectEqual(object?["outcome"] as? String, "error")
            try MiniTest.expect(object?["code"] as? String != nil)
            try MiniTest.expect(object?["containerId"] == nil)
    }),
    ("recoveryFailureRedactsRuntimeOutputAndExceptionDescription", {
        let rawBytes = Data(#"{"image":"alpine:3.20"}"#.utf8)
        let container = ContainerInfo(id: "old", name: "old", state: "running", labels: orchestratorLabels(), image: "alpine")
        let raw = RawVolumeConfig(
            bytes: rawBytes,
            pathInContainer: "/workspaces/repo/.devcontainer/devcontainer.json",
            workspaceFolder: "/workspaces/repo",
            workspaceFolderBasename: "repo"
        )
        let mock = MockProcessRunner()
        installRecoveryRuntime(mock, rawBytes: rawBytes)
        let runtime = AppleContainerRuntime(executablePath: "container", runner: mock)
        let prepared = try RecoveryOrchestrator.prepare(
            container: container,
            rawConfig: raw,
            runtime: runtime,
            sessionID: "secret-safe-session",
            pullIfMissing: false
        )
        defer { try? prepared.session.cleanup() }
        let sentinel = "SENTINEL_RECOVERY_SECRET_9f7a"
        let failure = CLIError(
            code: CLIErrorCode.lifecycleFailed,
            property: "postCreateCommand",
            message: "hook stderr: \(sentinel)",
            hint: "stdout: \(sentinel)"
        )
        let error = RecoveryOrchestrator.retainedFailure(
            session: prepared.session,
            helperID: "helper-id",
            selectedName: container.name,
            failure: failure,
            environment: [:]
        )
        let serialized = String(data: CLIErrorOutput.data(for: error, json: true), encoding: .utf8) ?? ""
        try MiniTest.expect(!serialized.contains(sentinel), "recovery JSON redacts hook output")
        try MiniTest.expect(serialized.contains(CLIErrorCode.lifecycleFailed), "failure phase remains visible")
        try MiniTest.expect(serialized.contains("status"), "recovery status remains visible")
    }),
    ("recoveryOrchestratorNonTTYRetainsDetailsWithoutLaunchingEditor", {
        let rawBytes = Data(#"{"image":"alpine:3.20"}"#.utf8)
        let container = ContainerInfo(id: "old", name: "old", state: "running", labels: orchestratorLabels(), image: "alpine")
        let raw = RawVolumeConfig(bytes: rawBytes, pathInContainer: "/workspaces/repo/.devcontainer/devcontainer.json", workspaceFolder: "/workspaces/repo", workspaceFolderBasename: "repo")
        let mock = MockProcessRunner()
        installRecoveryRuntime(mock, rawBytes: rawBytes)
        let runtime = AppleContainerRuntime(executablePath: "container", runner: mock)
        let prepared = try RecoveryOrchestrator.prepare(container: container, rawConfig: raw, runtime: runtime, sessionID: "non-tty-session", pullIfMissing: false)
        defer { try? prepared.session.cleanup() }
        let editorRunner = RecoveryWritingEditorRunner(bytes: rawBytes)
        let editor = RecoveryEditor(environment: ["VISUAL": "/test-editor"], runner: editorRunner, fallbackEditors: [], executableChecker: { _ in true })
        try MiniTest.expectThrows({
            _ = try RecoveryOrchestrator.recover(
                prepared: prepared,
                failure: .init(error: CLIError(code: CLIErrorCode.lifecycleFailed, message: "postCreate failed")),
                selected: container,
                runtime: runtime,
                options: RebuildOptions(jsonOutput: true),
                localEnv: [:],
                isTTY: false,
                editor: editor,
                retry: { _, _ in fatalError("non-TTY must not retry") }
            )
        }) { error in
            let cli = error as? CLIError
            try MiniTest.expectEqual(cli?.recovery?.sessionID, "non-tty-session")
            try MiniTest.expectEqual(cli?.recovery?.helperAvailable, true)
            try MiniTest.expect(cli?.recovery?.editCommand != nil)
        }
        try MiniTest.expectEqual(editorRunner.launches, 0)
    }),
    ("recoveryOrchestratorInvalidEditReopensWithoutInvalidWrite", {
        let rawBytes = Data(#"{"image":"alpine:3.20"}"#.utf8)
        let invalid = Data(#"{"image":}"#.utf8)
        let container = ContainerInfo(id: "old", name: "old", state: "running", labels: orchestratorLabels(), image: "alpine")
        let raw = RawVolumeConfig(bytes: rawBytes, pathInContainer: "/workspaces/repo/.devcontainer/devcontainer.json", workspaceFolder: "/workspaces/repo", workspaceFolderBasename: "repo")
        let mock = MockProcessRunner()
        installRecoveryRuntime(mock, rawBytes: rawBytes)
        let runtime = AppleContainerRuntime(executablePath: "container", runner: mock)
        let prepared = try RecoveryOrchestrator.prepare(container: container, rawConfig: raw, runtime: runtime, sessionID: "invalid-loop-session", pullIfMissing: false)
        defer { try? prepared.session.cleanup() }
        let editorRunner = RecoverySequenceEditorRunner(payloads: [invalid, rawBytes])
        let editor = RecoveryEditor(environment: ["VISUAL": "/test-editor"], runner: editorRunner, fallbackEditors: [], executableChecker: { _ in true })
        _ = try RecoveryOrchestrator.recover(
            prepared: prepared,
            failure: .init(error: CLIError(code: CLIErrorCode.lifecycleFailed, message: "hook failed")),
            selected: container,
            runtime: runtime,
            options: RebuildOptions(),
            localEnv: [:],
            isTTY: true,
            editor: editor,
            openEditorPrompt: affirmativeOpenEditorPrompt(),
            retry: { _, _ in RebuildResult(outcome: "success", containerId: "final", remoteUser: "vscode", remoteWorkspaceFolder: "/workspaces/repo") }
        )
        let writes = mock.calls.filter { $0.arguments.first == "exec" && $0.arguments.contains("adevcontainer-recovery-write") }
        try MiniTest.expectEqual(editorRunner.launches, 2)
        try MiniTest.expectEqual(writes.count, 1)
    }),
    ("recoveryOrchestratorCancellationRetainsHelperAndSession", {
        let rawBytes = Data(#"{"image":"alpine:3.20"}"#.utf8)
        let container = ContainerInfo(id: "old", name: "old", state: "running", labels: orchestratorLabels(), image: "alpine")
        let raw = RawVolumeConfig(bytes: rawBytes, pathInContainer: "/workspaces/repo/.devcontainer/devcontainer.json", workspaceFolder: "/workspaces/repo", workspaceFolderBasename: "repo")
        let mock = MockProcessRunner()
        installRecoveryRuntime(mock, rawBytes: rawBytes)
        let runtime = AppleContainerRuntime(executablePath: "container", runner: mock)
        let prepared = try RecoveryOrchestrator.prepare(container: container, rawConfig: raw, runtime: runtime, sessionID: "cancel-session", pullIfMissing: false)
        let editor = RecoveryEditor(environment: ["VISUAL": "/test-editor"], runner: RecoveryCancellationRunner(), fallbackEditors: [], executableChecker: { _ in true })
        try MiniTest.expectThrows({
            _ = try RecoveryOrchestrator.recover(
                prepared: prepared,
                failure: .init(error: CLIError(code: CLIErrorCode.lifecycleFailed, message: "hook failed")),
                selected: container,
                runtime: runtime,
                options: RebuildOptions(),
                localEnv: [:],
                isTTY: true,
                editor: editor,
                openEditorPrompt: affirmativeOpenEditorPrompt(),
                retry: { _, _ in fatalError("cancelled editor must not retry") }
            )
        }) { error in
            try MiniTest.expectEqual((error as? CLIError)?.code, CLIErrorCode.recoveryCancelled)
            try MiniTest.expect((error as? CLIError)?.recovery != nil)
        }
        try MiniTest.expect(FileManager.default.fileExists(atPath: prepared.session.tempFileURL.path))
        try MiniTest.expect(mock.calls.contains { $0.arguments.first == "create" })
        try? prepared.session.cleanup()
    }),
    ("recoveryOrchestratorHardRetryReplacesHelperAndContinues", {
        let rawBytes = Data(#"{"image":"alpine:3.20"}"#.utf8)
        let container = ContainerInfo(id: "old", name: "old", state: "running", labels: orchestratorLabels(), image: "alpine")
        let raw = RawVolumeConfig(bytes: rawBytes, pathInContainer: "/workspaces/repo/.devcontainer/devcontainer.json", workspaceFolder: "/workspaces/repo", workspaceFolderBasename: "repo")
        let mock = MockProcessRunner()
        installRecoveryRuntime(mock, rawBytes: rawBytes, helperIDs: ["helper-one", "helper-two"])
        let runtime = AppleContainerRuntime(executablePath: "container", runner: mock)
        let prepared = try RecoveryOrchestrator.prepare(container: container, rawConfig: raw, runtime: runtime, sessionID: "replacement-session", pullIfMissing: false)
        defer { try? prepared.session.cleanup() }
        let editorRunner = RecoverySequenceEditorRunner(payloads: [rawBytes, rawBytes])
        let editor = RecoveryEditor(environment: ["VISUAL": "/test-editor"], runner: editorRunner, fallbackEditors: [], executableChecker: { _ in true })
        var retryCalls = 0
        _ = try RecoveryOrchestrator.recover(
            prepared: prepared,
            failure: .init(error: CLIError(code: CLIErrorCode.lifecycleFailed, message: "initial hook failed")),
            selected: container,
            runtime: runtime,
            options: RebuildOptions(),
            localEnv: [:],
            isTTY: true,
            editor: editor,
            openEditorPrompt: affirmativeOpenEditorPrompt(answers: ["", ""]),
            retry: { _, _ in
                retryCalls += 1
                if retryCalls == 1 {
                    throw CLIError(code: CLIErrorCode.lifecycleFailed, message: "retry hook failed")
                }
                return RebuildResult(outcome: "success", containerId: "final", remoteUser: "vscode", remoteWorkspaceFolder: "/workspaces/repo")
            }
        )
        try MiniTest.expectEqual(retryCalls, 2)
        try MiniTest.expectEqual(editorRunner.launches, 2)
        try MiniTest.expectEqual(mock.calls.filter { $0.arguments.first == "create" }.count, 2)
    }),
    ("recoveryOrchestratorReplacementFailureDoesNotClaimHelper", {
        let rawBytes = Data(#"{"image":"alpine:3.20"}"#.utf8)
        let container = ContainerInfo(id: "old", name: "old", state: "running", labels: orchestratorLabels(), image: "alpine")
        let raw = RawVolumeConfig(bytes: rawBytes, pathInContainer: "/workspaces/repo/.devcontainer/devcontainer.json", workspaceFolder: "/workspaces/repo", workspaceFolderBasename: "repo")
        let mock = MockProcessRunner()
        installRecoveryRuntime(mock, rawBytes: rawBytes, helperIDs: ["helper-one", "helper-two"], failCreateAfter: 1)
        let runtime = AppleContainerRuntime(executablePath: "container", runner: mock)
        let prepared = try RecoveryOrchestrator.prepare(container: container, rawConfig: raw, runtime: runtime, sessionID: "replacement-failure-session", pullIfMissing: false)
        defer { try? prepared.session.cleanup() }
        let editor = RecoveryEditor(environment: ["VISUAL": "/test-editor"], runner: RecoverySequenceEditorRunner(payloads: [rawBytes, rawBytes]), fallbackEditors: [], executableChecker: { _ in true })
        try MiniTest.expectThrows({
            _ = try RecoveryOrchestrator.recover(
                prepared: prepared,
                failure: .init(error: CLIError(code: CLIErrorCode.lifecycleFailed, message: "initial failure")),
                selected: container,
                runtime: runtime,
                options: RebuildOptions(),
                localEnv: [:],
                isTTY: true,
                editor: editor,
                openEditorPrompt: affirmativeOpenEditorPrompt(),
                retry: { _, _ in
                    throw CLIError(code: CLIErrorCode.lifecycleFailed, message: "retry failure")
                }
            )
        }) { error in
            let cli = error as? CLIError
            try MiniTest.expectEqual(cli?.recovery?.helperAvailable, false)
            try MiniTest.expect(cli?.recovery?.cleanupCommand.contains("delete") == false)
            try MiniTest.expect(cli?.recovery?.tempFile.contains("devcontainer.json") == true)
            try MiniTest.expectEqual(cli?.recovery?.sessionID, "replacement-failure-session")
            try MiniTest.expectEqual(cli?.recovery?.expectedHash, RecoveryConfigSession.sha256Hex(rawBytes))
            try MiniTest.expect(cli?.jsonObject()["rawConfig"] == nil)
        }
    }),
    ("recoveryFinalVerificationDetailsDoNotClaimHelper", {
        let raw = RawVolumeConfig(
            bytes: Data(#"{"image":"alpine:3.20"}"#.utf8),
            pathInContainer: "/workspaces/repo/.devcontainer/devcontainer.json",
            workspaceFolder: "/workspaces/repo",
            workspaceFolderBasename: "repo"
        )
        let session = try RecoveryConfigSession(
            rawVolumeConfig: raw,
            targetContainerID: "old-id",
            targetContainerName: "old",
            workspaceVolume: "adev-repo-ws",
            configFile: ".devcontainer/devcontainer.json",
            sessionID: "final-verify-session"
        )
        defer { try? session.cleanup() }
        let error = RecoveryOrchestrator.finalVerificationFailure(
            session: session,
            selectedName: "adev-repo",
            failure: CLIError(
                code: CLIErrorCode.recoveryVerificationFailed,
                message: "final hash mismatch"
            ),
            environment: [:]
        )
        try MiniTest.expectEqual(error.code, CLIErrorCode.recoveryVerificationFailed)
        try MiniTest.expectEqual(error.recovery?.helperAvailable, false)
         try MiniTest.expectEqual(error.recovery?.helperContainerID, "")
         try MiniTest.expect(!error.hint!.contains("helper 'not-available' retained"))
         try MiniTest.expect(error.jsonObject()["recovery"] as? [String: Any] != nil)
         let serialized = String(data: CLIErrorOutput.data(for: error, json: true), encoding: .utf8) ?? ""
         try MiniTest.expect(!serialized.contains("not-available"))
        try MiniTest.expect(!error.recovery!.cleanupCommand.contains("delete"))
        try MiniTest.expectEqual(error.recovery?.failureKind, CLIErrorCode.recoveryVerificationFailed)
    }),
    ("recoveryCleanupFailureDetailsDoNotClaimDeletedHelper", {
        let raw = RawVolumeConfig(
            bytes: Data(#"{"image":"alpine:3.20"}"#.utf8),
            pathInContainer: "/workspaces/repo/.devcontainer/devcontainer.json",
            workspaceFolder: "/workspaces/repo",
            workspaceFolderBasename: "repo"
        )
        let session = try RecoveryConfigSession(
            rawVolumeConfig: raw,
            targetContainerID: "old-id",
            targetContainerName: "old",
            workspaceVolume: "adev-repo-ws",
            configFile: ".devcontainer/devcontainer.json",
            sessionID: "cleanup-failure-session"
        )
        defer { try? session.cleanup() }
        let error = RecoveryOrchestrator.retainedFailure(
            session: session,
            helperID: "not-created",
            selectedName: "adev-repo",
            failure: CLIError(
                code: CLIErrorCode.recoveryUnavailable,
                message: "secure session cleanup failed"
            ),
            environment: [:]
        )
        try MiniTest.expectEqual(error.recovery?.helperAvailable, false)
         try MiniTest.expectEqual(error.recovery?.helperContainerID, "")
         let serialized = String(data: CLIErrorOutput.data(for: error, json: true), encoding: .utf8) ?? ""
         try MiniTest.expect(!serialized.contains("not-created"))
        try MiniTest.expect(error.recovery?.cleanupCommand.contains("delete") == false)
        try MiniTest.expect(error.recovery?.tempFile.contains("devcontainer.json") == true)
        try MiniTest.expectEqual(error.recovery?.expectedHash, RecoveryConfigSession.sha256Hex(raw.bytes))
        try MiniTest.expect(error.recovery?.sessionID == "cleanup-failure-session")
        try MiniTest.expect(error.recovery?.jsonObject()["rawConfig"] == nil)
        try MiniTest.expect(error.hint?.contains("helper") == true)
    }),
    ("recoveryOrchestratorTTYEditWritesBeforeRetry", {
        let rawBytes = Data(#"{"image":"alpine:3.20"}"#.utf8)
        let container = ContainerInfo(id: "old", name: "old", state: "running", labels: orchestratorLabels(), image: "alpine")
        let raw = RawVolumeConfig(
            bytes: rawBytes,
            pathInContainer: "/workspaces/repo/.devcontainer/devcontainer.json",
            workspaceFolder: "/workspaces/repo",
            workspaceFolderBasename: "repo"
        )
        let mock = MockProcessRunner()
        mock.handlers.append { args in
            if args.starts(with: ["list", "--all"]) {
                return ProcessResult(exitCode: 0, stdout: Data("[]".utf8), stderr: Data())
            }
            if args.starts(with: ["volume", "list"]) {
                return ProcessResult(exitCode: 0, stdout: try! JSONSerialization.data(withJSONObject: [["configuration": ["name": "adev-repo-ws"]]]), stderr: Data())
            }
            if args.starts(with: ["image", "inspect"]) {
                return ProcessResult(exitCode: 0, stdout: orchestratorImageJSON(), stderr: Data())
            }
            if args.first == "create" {
                return ProcessResult(exitCode: 0, stdout: Data("helper-id\n".utf8), stderr: Data())
            }
            if args.first == "inspect" {
                return ProcessResult(exitCode: 0, stdout: recoveryMountInspectionJSON(containerID: "helper-id"), stderr: Data())
            }
            if args.first == "exec", args.contains("cat") {
                return ProcessResult(exitCode: 0, stdout: rawBytes, stderr: Data())
            }
            if args.first == "exec", args.contains("adevcontainer-recovery-write") {
                let hash = RecoveryConfigSession.sha256Hex(rawBytes)
                return ProcessResult(exitCode: 0, stdout: Data("RECOVERY_APPLIED:\(hash)\n".utf8), stderr: Data())
            }
            return nil
        }
        let runtime = AppleContainerRuntime(executablePath: "container", runner: mock)
        let prepared = try RecoveryOrchestrator.prepare(
            container: container,
            rawConfig: raw,
            runtime: runtime,
            sessionID: "tty-loop-session",
            pullIfMissing: false
        )
        defer { try? prepared.session.cleanup() }
        let editorRunner = RecoveryWritingEditorRunner(bytes: rawBytes)
        let editor = RecoveryEditor(
            environment: ["VISUAL": "/test-editor"],
            runner: editorRunner,
            fallbackEditors: [],
            executableChecker: { _ in true }
        )
        var retryCalls = 0
        let result = try RecoveryOrchestrator.recover(
            prepared: prepared,
            failure: .init(error: CLIError(code: CLIErrorCode.lifecycleFailed, message: "postCreate failed")),
            selected: container,
            runtime: runtime,
            options: RebuildOptions(),
            localEnv: [:],
            isTTY: true,
            editor: editor,
            openEditorPrompt: affirmativeOpenEditorPrompt(),
            retry: { _, _ in
                retryCalls += 1
                try MiniTest.expect(mock.calls.contains { $0.arguments.first == "exec" && $0.arguments.contains("adevcontainer-recovery-write") })
                return RebuildResult(outcome: "success", containerId: "final", remoteUser: "vscode", remoteWorkspaceFolder: "/workspaces/repo")
            }
        )
        try MiniTest.expectEqual(result.outcome, "success")
        try MiniTest.expectEqual(retryCalls, 1)
        try MiniTest.expectEqual(editorRunner.launches, 1)
      })
      ,("recoveryOrchestratorTTYConflictReopensWithRetainedBaseline", {
         let original = Data(#"{"image":"alpine:3.20"}"#.utf8)
         let current = Data(#"{"image":"alpine:3.20","name":"current"}"#.utf8)
         let container = ContainerInfo(id: "old", name: "old", state: "running", labels: orchestratorLabels(), image: "alpine")
         let raw = RawVolumeConfig(
             bytes: original,
             pathInContainer: "/workspaces/repo/.devcontainer/devcontainer.json",
             workspaceFolder: "/workspaces/repo",
             workspaceFolderBasename: "repo"
         )
         let mock = MockProcessRunner()
         var catCount = 0
         mock.handlers.append { args in
             if args.starts(with: ["list", "--all"]) {
                 return ProcessResult(exitCode: 0, stdout: Data("[]".utf8), stderr: Data())
             }
             if args.starts(with: ["volume", "list"]) {
                 return ProcessResult(
                     exitCode: 0,
                     stdout: try! JSONSerialization.data(withJSONObject: [["configuration": ["name": "adev-repo-ws"]]]),
                     stderr: Data()
                 )
             }
             if args.starts(with: ["image", "inspect"]) {
                 return ProcessResult(exitCode: 0, stdout: orchestratorImageJSON(), stderr: Data())
             }
             if args.first == "create" {
                 return ProcessResult(exitCode: 0, stdout: Data("helper-id\n".utf8), stderr: Data())
             }
             if args.first == "inspect" {
                 return ProcessResult(
                     exitCode: 0,
                     stdout: recoveryMountInspectionJSON(containerID: "helper-id"),
                     stderr: Data()
                 )
             }
             if args.first == "exec", args.contains("cat") {
                 catCount += 1
                 return ProcessResult(
                     exitCode: 0,
                     stdout: catCount < 4 ? current : original,
                     stderr: Data()
                 )
             }
             if args.first == "exec", args.contains("adevcontainer-recovery-write") {
                 let hash = RecoveryConfigSession.sha256Hex(original)
                 return ProcessResult(exitCode: 0, stdout: Data("RECOVERY_APPLIED:\(hash)\n".utf8), stderr: Data())
             }
             return nil
         }
         let runtime = AppleContainerRuntime(executablePath: "container", runner: mock)
         let prepared = try RecoveryOrchestrator.prepare(
             container: container,
             rawConfig: raw,
             runtime: runtime,
             sessionID: "tty-conflict-session",
             pullIfMissing: false
         )
         defer { try? prepared.session.cleanup() }
         let editorRunner = RecoverySequenceEditorRunner(payloads: [original, original])
         let editor = RecoveryEditor(
             environment: ["VISUAL": "/test-editor"],
             runner: editorRunner,
             fallbackEditors: [],
             executableChecker: { _ in true }
         )
         let result = try RecoveryOrchestrator.recover(
             prepared: prepared,
             failure: .init(error: CLIError(code: CLIErrorCode.lifecycleFailed, message: "hook failed")),
             selected: container,
             runtime: runtime,
             options: RebuildOptions(),
             localEnv: [:],
             isTTY: true,
             editor: editor,
             openEditorPrompt: affirmativeOpenEditorPrompt(),
             retry: { _, _ in
                 RebuildResult(outcome: "success", containerId: "final", remoteUser: "vscode", remoteWorkspaceFolder: "/workspaces/repo")
             }
         )
         try MiniTest.expectEqual(result.outcome, "success")
         try MiniTest.expectEqual(editorRunner.launches, 2, "conflict reopens the editor")
         try MiniTest.expectEqual(prepared.session.conflictHash, nil, "resolved conflict metadata is cleared after successful write")
         try MiniTest.expectEqual(prepared.session.conflictFileURL, nil)
     })
      ,("recoveryOrchestratorConflictDetailsRemainStructuredForJSON", {
          let original = Data(#"{"image":"alpine:3.20"}"#.utf8)
          let current = Data(#"{"image":"alpine:3.20","name":"current"}"#.utf8)
          let session = try RecoveryConfigSession(
              rawBytes: original,
              targetContainerID: "old-id",
              targetContainerName: "old",
              workspaceVolume: "adev-repo-ws",
              configFile: ".devcontainer/devcontainer.json",
              workspaceFolder: "/workspaces/repo",
              sessionID: "json-conflict-session"
          )
          defer { try? session.cleanup() }
          let mock = MockProcessRunner()
          mock.handlers = [{ args in
              guard args.first == "exec", args.contains("cat") else { return nil }
              return ProcessResult(exitCode: 0, stdout: current, stderr: Data())
          }]
          let runtime = AppleContainerRuntime(executablePath: "container", runner: mock)
          do {
              _ = try session.applyEdit(helperContainerID: "helper", runtime: runtime)
          } catch {
              // The first read intentionally detects the retained conflict baseline.
          }
          let error = RecoveryOrchestrator.conflictFailure(
              session: session,
              helperID: "helper",
              selectedName: "adev-repo",
              failure: CLIError(code: CLIErrorCode.recoveryConflict, message: "baseline changed"),
              environment: [:]
          )
          try MiniTest.expectEqual(error.code, CLIErrorCode.recoveryConflict)
          try MiniTest.expectEqual(error.recovery?.conflictHash, RecoveryConfigSession.sha256Hex(current))
          try MiniTest.expect(error.recovery?.conflictFile != nil)
          try MiniTest.expect(error.recovery?.retryCommand.contains("rebuild") == true)
          try MiniTest.expect(error.recovery?.editCommand.contains("devcontainer.json") == true)
          let serialized = String(data: CLIErrorOutput.data(for: error, json: true), encoding: .utf8) ?? ""
          try MiniTest.expect(serialized.contains(CLIErrorCode.recoveryConflict))
          try MiniTest.expect(!serialized.contains("rawConfig"))
      })
      ,("recoveryOrchestratorDoesNotRetryUnknownFailure", {
         let rawBytes = Data(#"{"image":"alpine:3.20"}"#.utf8)
         let container = ContainerInfo(id: "old", name: "old", state: "running", labels: orchestratorLabels(), image: "alpine")
         let raw = RawVolumeConfig(bytes: rawBytes, pathInContainer: "/workspaces/repo/.devcontainer/devcontainer.json", workspaceFolder: "/workspaces/repo", workspaceFolderBasename: "repo")
         let mock = MockProcessRunner()
         installRecoveryRuntime(mock, rawBytes: rawBytes)
         let runtime = AppleContainerRuntime(executablePath: "container", runner: mock)
         let prepared = try RecoveryOrchestrator.prepare(container: container, rawConfig: raw, runtime: runtime, sessionID: "unknown-failure-session", pullIfMissing: false)
         defer { try? prepared.session.cleanup() }
         let editor = RecoveryEditor(environment: ["VISUAL": "/test-editor"], runner: RecoveryWritingEditorRunner(bytes: rawBytes), fallbackEditors: [], executableChecker: { _ in true })
         var retryCalls = 0
         try MiniTest.expectThrows({
             _ = try RecoveryOrchestrator.recover(
                 prepared: prepared,
                 failure: .init(error: CLIError(code: CLIErrorCode.lifecycleFailed, message: "initial failure")),
                 selected: container,
                 runtime: runtime,
                 options: RebuildOptions(),
                 localEnv: [:],
                 isTTY: true,
                 editor: editor,
                 openEditorPrompt: affirmativeOpenEditorPrompt(),
                 retry: { _, _ in
                     retryCalls += 1
                     throw NSError(domain: "programmer", code: 1)
                 }
             )
         }) { error in
             try MiniTest.expectEqual((error as? CLIError)?.recovery?.helperAvailable, true)
         }
          try MiniTest.expectEqual(retryCalls, 1)
      })
      ,("recoveryOrchestratorDoesNotRecoverFeaturePostAttachFailure", {
          let rawBytes = Data(#"{"image":"alpine:3.20"}"#.utf8)
          let container = ContainerInfo(id: "old", name: "old", state: "running", labels: orchestratorLabels(), image: "alpine")
          let raw = RawVolumeConfig(
              bytes: rawBytes,
              pathInContainer: "/workspaces/repo/.devcontainer/devcontainer.json",
              workspaceFolder: "/workspaces/repo",
              workspaceFolderBasename: "repo"
          )
          let mock = MockProcessRunner()
          installRecoveryRuntime(mock, rawBytes: rawBytes)
          let runtime = AppleContainerRuntime(executablePath: "container", runner: mock)
          let prepared = try RecoveryOrchestrator.prepare(
              container: container,
              rawConfig: raw,
              runtime: runtime,
              sessionID: "feature-post-attach-session",
              pullIfMissing: false
          )
          let editor = RecoveryEditor(
              environment: ["VISUAL": "/test-editor"],
              runner: RecoveryWritingEditorRunner(bytes: rawBytes),
              fallbackEditors: [],
              executableChecker: { _ in true }
          )
          var retryCalls = 0
          let failure = CLIError(
              code: CLIErrorCode.lifecycleFailed,
              property: "postAttachCommand (feature)",
              message: "feature postAttach failed"
          )
          try MiniTest.expectThrows({
              _ = try RecoveryOrchestrator.recover(
                  prepared: prepared,
                  failure: .init(error: CLIError(code: CLIErrorCode.lifecycleFailed, message: "initial failure")),
                  selected: container,
                  runtime: runtime,
                  options: RebuildOptions(),
                  localEnv: [:],
                  isTTY: true,
                  editor: editor,
                  openEditorPrompt: affirmativeOpenEditorPrompt(),
                  retry: { _, _ in
                      retryCalls += 1
                      throw failure
                  }
              )
          }) { error in
              try MiniTest.expectEqual(error as? CLIError, failure)
          }
          try MiniTest.expectEqual(retryCalls, 1, "feature postAttach failure is terminal")
          try MiniTest.expect(
              !FileManager.default.fileExists(atPath: prepared.session.directoryURL.path),
              "terminal postAttach failure cleans the recovery session"
          )
      }),
    ("recoveryNamedRetryTTYOpensEditorBeforeApply", {
        // Retained broken config (e.g. postCreate exit 42) after non-TTY retention: the first
        // interactive named retry must open the editor before writing through the helper.
        let broken = Data(#"{"image":"alpine:3.20","postCreateCommand":"exit 42"}"#.utf8)
        let fixed = Data(#"{"image":"alpine:3.20","postCreateCommand":"true"}"#.utf8)
        let sessionID = "named-tty-\(String(UUID().uuidString.prefix(8)).lowercased())"
        let container = ContainerInfo(
            id: "helper-id",
            name: "old",
            state: "running",
            labels: orchestratorLabels(),
            image: "alpine"
        )
        let raw = RawVolumeConfig(
            bytes: broken,
            pathInContainer: "/workspaces/repo/.devcontainer/devcontainer.json",
            workspaceFolder: "/workspaces/repo",
            workspaceFolderBasename: "repo"
        )
        let prepMock = MockProcessRunner()
        installRecoveryRuntime(prepMock, rawBytes: broken)
        let prepRuntime = AppleContainerRuntime(executablePath: "container", runner: prepMock)
        let prepared = try RecoveryOrchestrator.prepare(
            container: container,
            rawConfig: raw,
            runtime: prepRuntime,
            sessionID: sessionID,
            pullIfMissing: false
        )
        defer { try? prepared.session.cleanup() }

        let mock = MockProcessRunner()
        var writeOrder: [String] = []
        var applied = false
        mock.handlers.append { args in
            if args.first == "exec", args.contains("cat") {
                writeOrder.append("cat")
                // Pre-write verification still sees the broken volume config; post-write
                // readback must return the edited bytes or applyValidatedEdit fails closed.
                return ProcessResult(exitCode: 0, stdout: applied ? fixed : broken, stderr: Data())
            }
            if args.first == "exec", args.contains("adevcontainer-recovery-write") {
                writeOrder.append("write")
                applied = true
                let hash = RecoveryConfigSession.sha256Hex(fixed)
                return ProcessResult(exitCode: 0, stdout: Data("RECOVERY_APPLIED:\(hash)\n".utf8), stderr: Data())
            }
            return nil
        }
        let runtime = AppleContainerRuntime(executablePath: "container", runner: mock)
        let editorRunner = RecoveryWritingEditorRunner(bytes: fixed)
        let editor = RecoveryEditor(
            environment: ["VISUAL": "/test-editor"],
            runner: editorRunner,
            fallbackEditors: [],
            executableChecker: { _ in true }
        )
        try RecoveryOrchestrator.applyNamedRetryEdit(
            prepared: prepared,
            helperID: "helper-id",
            selectedName: "old",
            runtime: runtime,
            options: RebuildOptions(),
            localEnv: [:],
            isTTY: true,
            editor: editor
        )
        try MiniTest.expectEqual(editorRunner.launches, 1, "TTY named retry opens the editor before apply")
        try MiniTest.expect(writeOrder.contains("write"), "atomic write happens after the editor exit")
        try MiniTest.expectEqual(prepared.session.lastAppliedHash, RecoveryConfigSession.sha256Hex(fixed))
    }),
    ("recoveryNamedRetryNonTTYAppliesWithoutEditor", {
        let bytes = Data(#"{"image":"alpine:3.20","postCreateCommand":"true"}"#.utf8)
        let sessionID = "named-nontty-\(String(UUID().uuidString.prefix(8)).lowercased())"
        let container = ContainerInfo(
            id: "helper-id",
            name: "old",
            state: "running",
            labels: orchestratorLabels(),
            image: "alpine"
        )
        let raw = RawVolumeConfig(
            bytes: bytes,
            pathInContainer: "/workspaces/repo/.devcontainer/devcontainer.json",
            workspaceFolder: "/workspaces/repo",
            workspaceFolderBasename: "repo"
        )
        let prepMock = MockProcessRunner()
        installRecoveryRuntime(prepMock, rawBytes: bytes)
        let prepRuntime = AppleContainerRuntime(executablePath: "container", runner: prepMock)
        let prepared = try RecoveryOrchestrator.prepare(
            container: container,
            rawConfig: raw,
            runtime: prepRuntime,
            sessionID: sessionID,
            pullIfMissing: false
        )
        defer { try? prepared.session.cleanup() }

        let mock = MockProcessRunner()
        mock.handlers.append { args in
            if args.first == "exec", args.contains("cat") {
                return ProcessResult(exitCode: 0, stdout: bytes, stderr: Data())
            }
            if args.first == "exec", args.contains("adevcontainer-recovery-write") {
                let hash = RecoveryConfigSession.sha256Hex(bytes)
                return ProcessResult(exitCode: 0, stdout: Data("RECOVERY_APPLIED:\(hash)\n".utf8), stderr: Data())
            }
            return nil
        }
        let runtime = AppleContainerRuntime(executablePath: "container", runner: mock)
        let editorRunner = RecoveryWritingEditorRunner(bytes: bytes)
        let editor = RecoveryEditor(
            environment: ["VISUAL": "/test-editor"],
            runner: editorRunner,
            fallbackEditors: [],
            executableChecker: { _ in true }
        )
        try RecoveryOrchestrator.applyNamedRetryEdit(
            prepared: prepared,
            helperID: "helper-id",
            selectedName: "old",
            runtime: runtime,
            options: RebuildOptions(jsonOutput: true),
            localEnv: [:],
            isTTY: false,
            editor: editor
        )
        try MiniTest.expectEqual(editorRunner.launches, 0, "non-TTY/json named retry never launches an editor")
        try MiniTest.expect(
            mock.calls.contains { $0.arguments.first == "exec" && $0.arguments.contains("adevcontainer-recovery-write") },
            "non-TTY named retry still applies temp bytes through the helper"
        )
    }),
    ("lifecycleHookExit42FailsClosedWithoutHang", {
        // Regression: postCreateCommand `exit 42` must complete and fail quickly (no hang).
        let mock = MockProcessRunner()
        var execCount = 0
        mock.handlers = [
            { args in
                if args.first == "exec" {
                    execCount += 1
                    return ProcessResult(exitCode: 42, stdout: Data(), stderr: Data())
                }
                if args.first == "delete" {
                    return ProcessResult(exitCode: 0, stdout: Data(), stderr: Data())
                }
                return nil
            }
        ]
        let runtime = AppleContainerRuntime(executablePath: "container", runner: mock)
        var config = ResolvedDevContainerConfig(image: "alpine:3.20", workspaceFolder: "/workspaces/x")
        config.postCreateCommand = .shell("exit 42")
        config.remoteUser = "vscode"
        try MiniTest.expectThrows({
            try LifecycleRunner.runCreatePath(containerId: "ctr", config: config, runtime: runtime)
        }, validate: { error in
            let cli = error as? CLIError
            try MiniTest.expectEqual(cli?.code, CLIErrorCode.postCreateFailed)
            try MiniTest.expect(cli?.message.contains("exit 42") == true)
        })
        try MiniTest.expectEqual(execCount, 1, "hook exec runs once and returns")
        try MiniTest.expect(
            mock.calls.contains { $0.arguments.first == "delete" },
            "delete-on-fail runs after non-zero hook exit"
        )
    }),

    // MARK: - Shared TTY open-editor prompt

    ("recoveryOpenEditorPromptClassification", {
        let cases: [(String?, RecoveryOpenEditorPrompt.Answer)] = [
            ("", .affirmative),
            ("   ", .affirmative),
            ("y", .affirmative),
            ("Y", .affirmative),
            ("yes", .affirmative),
            ("YES", .affirmative),
            ("y extra", .affirmative),
            ("n", .decline),
            ("N", .decline),
            ("no", .decline),
            ("NO", .decline),
            ("maybe", .decline),
            ("0", .decline),
            (nil, .decline)
        ]
        for (input, expected) in cases {
            try MiniTest.expectEqual(
                RecoveryOpenEditorPrompt.classify(input),
                expected,
                "classify(\(String(describing: input)))"
            )
        }
        try MiniTest.expectEqual(
            RecoveryOpenEditorPrompt.promptText.trimmingCharacters(in: .whitespaces),
            "Open the recovery editor now? [Y/n]"
        )
    }),

    ("volumeTTYPromptPrintsFailureThenOpensEditorOnYes", {
        let rawBytes = Data(#"{"image":"alpine:3.20"}"#.utf8)
        let container = ContainerInfo(id: "old", name: "old", state: "running", labels: orchestratorLabels(), image: "alpine")
        let raw = RawVolumeConfig(bytes: rawBytes, pathInContainer: "/workspaces/repo/.devcontainer/devcontainer.json", workspaceFolder: "/workspaces/repo", workspaceFolderBasename: "repo")
        let mock = MockProcessRunner()
        installRecoveryRuntime(mock, rawBytes: rawBytes)
        let runtime = AppleContainerRuntime(executablePath: "container", runner: mock)
        let prepared = try RecoveryOrchestrator.prepare(container: container, rawConfig: raw, runtime: runtime, sessionID: "prompt-yes-session", pullIfMissing: false)
        defer { try? prepared.session.cleanup() }
        let editorRunner = RecoveryWritingEditorRunner(bytes: rawBytes)
        let editor = RecoveryEditor(environment: ["VISUAL": "/test-editor"], runner: editorRunner, fallbackEditors: [], executableChecker: { _ in true })
        final class Writes: @unchecked Sendable { var lines: [String] = [] }
        let writes = Writes()
        let prompt = affirmativeOpenEditorPrompt(answers: ["y"]) { writes.lines.append($0) }
        _ = try RecoveryOrchestrator.recover(
            prepared: prepared,
            failure: .init(error: CLIError(code: CLIErrorCode.postCreateFailed, property: "postCreateCommand", message: "hook exit 1")),
            selected: container,
            runtime: runtime,
            options: RebuildOptions(),
            localEnv: [:],
            isTTY: true,
            editor: editor,
            openEditorPrompt: prompt,
            retry: { _, _ in RebuildResult(outcome: "success", containerId: "final", remoteUser: "vscode", remoteWorkspaceFolder: "/workspaces/repo") }
        )
        try MiniTest.expectEqual(editorRunner.launches, 1)
        let joined = writes.lines.joined()
        try MiniTest.expect(joined.contains("post_create_failed") || joined.contains("postCreate"), "structured failure printed before prompt")
        try MiniTest.expect(joined.contains(RecoveryOpenEditorPrompt.promptText), "prompt text on stderr")
        // Failure text must appear before the prompt line.
        let failIdx = writes.lines.firstIndex {
            TerminalStyle.stripANSI($0).hasPrefix("error:") || $0.contains("Rebuild failed")
        }
        let promptIdx = writes.lines.firstIndex { $0.contains(RecoveryOpenEditorPrompt.promptText) }
        try MiniTest.expect(failIdx != nil && promptIdx != nil && failIdx! < promptIdx!)
    }),

    ("volumeTTYPromptDeclineRetainsHelperWithoutEditor", {
        let rawBytes = Data(#"{"image":"alpine:3.20"}"#.utf8)
        let container = ContainerInfo(id: "old", name: "old", state: "running", labels: orchestratorLabels(), image: "alpine")
        let raw = RawVolumeConfig(bytes: rawBytes, pathInContainer: "/workspaces/repo/.devcontainer/devcontainer.json", workspaceFolder: "/workspaces/repo", workspaceFolderBasename: "repo")
        let mock = MockProcessRunner()
        installRecoveryRuntime(mock, rawBytes: rawBytes)
        let runtime = AppleContainerRuntime(executablePath: "container", runner: mock)
        let prepared = try RecoveryOrchestrator.prepare(container: container, rawConfig: raw, runtime: runtime, sessionID: "prompt-decline-session", pullIfMissing: false)
        defer { try? prepared.session.cleanup() }
        let editorRunner = RecoveryWritingEditorRunner(bytes: rawBytes)
        let editor = RecoveryEditor(environment: ["VISUAL": "/test-editor"], runner: editorRunner, fallbackEditors: [], executableChecker: { _ in true })
        try MiniTest.expectThrows({
            _ = try RecoveryOrchestrator.recover(
                prepared: prepared,
                failure: .init(error: CLIError(code: CLIErrorCode.lifecycleFailed, message: "hook failed")),
                selected: container,
                runtime: runtime,
                options: RebuildOptions(),
                localEnv: [:],
                isTTY: true,
                editor: editor,
                openEditorPrompt: declineOpenEditorPrompt(answer: "n"),
                retry: { _, _ in fatalError("decline must not retry") }
            )
        }) { error in
            let cli = error as? CLIError
            try MiniTest.expectEqual(cli?.code, CLIErrorCode.recoveryCancelled)
            try MiniTest.expectEqual(cli?.recovery?.sessionID, "prompt-decline-session")
            try MiniTest.expectEqual(cli?.recovery?.helperAvailable, true)
            try MiniTest.expect(cli?.recovery?.retryCommand.contains("rebuild") == true)
            try MiniTest.expect(cli?.recovery?.editCommand.contains("devcontainer.json") == true)
        }
        try MiniTest.expectEqual(editorRunner.launches, 0, "decline never launches editor")
        try MiniTest.expect(FileManager.default.fileExists(atPath: prepared.session.tempFileURL.path))
        try MiniTest.expect(mock.calls.contains { $0.arguments.first == "create" })
    }),

    ("volumeTTYPromptEOFDefersLikeDecline", {
        let rawBytes = Data(#"{"image":"alpine:3.20"}"#.utf8)
        let container = ContainerInfo(id: "old", name: "old", state: "running", labels: orchestratorLabels(), image: "alpine")
        let raw = RawVolumeConfig(bytes: rawBytes, pathInContainer: "/workspaces/repo/.devcontainer/devcontainer.json", workspaceFolder: "/workspaces/repo", workspaceFolderBasename: "repo")
        let mock = MockProcessRunner()
        installRecoveryRuntime(mock, rawBytes: rawBytes)
        let runtime = AppleContainerRuntime(executablePath: "container", runner: mock)
        let prepared = try RecoveryOrchestrator.prepare(container: container, rawConfig: raw, runtime: runtime, sessionID: "prompt-eof-session", pullIfMissing: false)
        defer { try? prepared.session.cleanup() }
        let editorRunner = RecoveryWritingEditorRunner(bytes: rawBytes)
        let editor = RecoveryEditor(environment: ["VISUAL": "/test-editor"], runner: editorRunner, fallbackEditors: [], executableChecker: { _ in true })
        try MiniTest.expectThrows({
            _ = try RecoveryOrchestrator.recover(
                prepared: prepared,
                failure: .init(error: CLIError(code: CLIErrorCode.lifecycleFailed, message: "hook failed")),
                selected: container,
                runtime: runtime,
                options: RebuildOptions(),
                localEnv: [:],
                isTTY: true,
                editor: editor,
                openEditorPrompt: declineOpenEditorPrompt(answer: nil),
                retry: { _, _ in fatalError("EOF must not retry") }
            )
        }) { error in
            try MiniTest.expectEqual((error as? CLIError)?.code, CLIErrorCode.recoveryCancelled)
            try MiniTest.expect((error as? CLIError)?.recovery != nil)
        }
        try MiniTest.expectEqual(editorRunner.launches, 0)
    }),

    ("volumeTTYInvalidReopenDoesNotRePrompt", {
        let rawBytes = Data(#"{"image":"alpine:3.20"}"#.utf8)
        let invalid = Data(#"{"image":}"#.utf8)
        let container = ContainerInfo(id: "old", name: "old", state: "running", labels: orchestratorLabels(), image: "alpine")
        let raw = RawVolumeConfig(bytes: rawBytes, pathInContainer: "/workspaces/repo/.devcontainer/devcontainer.json", workspaceFolder: "/workspaces/repo", workspaceFolderBasename: "repo")
        let mock = MockProcessRunner()
        installRecoveryRuntime(mock, rawBytes: rawBytes)
        let runtime = AppleContainerRuntime(executablePath: "container", runner: mock)
        let prepared = try RecoveryOrchestrator.prepare(container: container, rawConfig: raw, runtime: runtime, sessionID: "invalid-no-reprompt", pullIfMissing: false)
        defer { try? prepared.session.cleanup() }
        let editorRunner = RecoverySequenceEditorRunner(payloads: [invalid, rawBytes])
        let editor = RecoveryEditor(environment: ["VISUAL": "/test-editor"], runner: editorRunner, fallbackEditors: [], executableChecker: { _ in true })
        final class Counter: @unchecked Sendable { var prompts = 0 }
        let counter = Counter()
        let prompt = affirmativeOpenEditorPrompt(answers: [""]) { line in
            if line.contains(RecoveryOpenEditorPrompt.promptText) { counter.prompts += 1 }
        }
        _ = try RecoveryOrchestrator.recover(
            prepared: prepared,
            failure: .init(error: CLIError(code: CLIErrorCode.lifecycleFailed, message: "hook failed")),
            selected: container,
            runtime: runtime,
            options: RebuildOptions(),
            localEnv: [:],
            isTTY: true,
            editor: editor,
            openEditorPrompt: prompt,
            retry: { _, _ in RebuildResult(outcome: "success", containerId: "final", remoteUser: "vscode", remoteWorkspaceFolder: "/workspaces/repo") }
        )
        try MiniTest.expectEqual(editorRunner.launches, 2, "invalid edit reopens editor")
        try MiniTest.expectEqual(counter.prompts, 1, "invalid reopen must not re-ask open-editor prompt")
    }),

    ("volumeTTYHardRetryRePromptsOpenEditor", {
        let rawBytes = Data(#"{"image":"alpine:3.20"}"#.utf8)
        let container = ContainerInfo(id: "old", name: "old", state: "running", labels: orchestratorLabels(), image: "alpine")
        let raw = RawVolumeConfig(bytes: rawBytes, pathInContainer: "/workspaces/repo/.devcontainer/devcontainer.json", workspaceFolder: "/workspaces/repo", workspaceFolderBasename: "repo")
        let mock = MockProcessRunner()
        installRecoveryRuntime(mock, rawBytes: rawBytes, helperIDs: ["helper-one", "helper-two"])
        let runtime = AppleContainerRuntime(executablePath: "container", runner: mock)
        let prepared = try RecoveryOrchestrator.prepare(container: container, rawConfig: raw, runtime: runtime, sessionID: "reprompt-session", pullIfMissing: false)
        defer { try? prepared.session.cleanup() }
        let editorRunner = RecoverySequenceEditorRunner(payloads: [rawBytes, rawBytes])
        let editor = RecoveryEditor(environment: ["VISUAL": "/test-editor"], runner: editorRunner, fallbackEditors: [], executableChecker: { _ in true })
        final class Counter: @unchecked Sendable { var prompts = 0 }
        let counter = Counter()
        let prompt = affirmativeOpenEditorPrompt(answers: ["", ""]) { line in
            if line.contains(RecoveryOpenEditorPrompt.promptText) { counter.prompts += 1 }
        }
        var retryCalls = 0
        _ = try RecoveryOrchestrator.recover(
            prepared: prepared,
            failure: .init(error: CLIError(code: CLIErrorCode.lifecycleFailed, message: "initial")),
            selected: container,
            runtime: runtime,
            options: RebuildOptions(),
            localEnv: [:],
            isTTY: true,
            editor: editor,
            openEditorPrompt: prompt,
            retry: { _, _ in
                retryCalls += 1
                if retryCalls == 1 {
                    throw CLIError(code: CLIErrorCode.lifecycleFailed, message: "retry hook failed")
                }
                return RebuildResult(outcome: "success", containerId: "final", remoteUser: "vscode", remoteWorkspaceFolder: "/workspaces/repo")
            }
        )
        try MiniTest.expectEqual(retryCalls, 2)
        try MiniTest.expectEqual(counter.prompts, 2, "hard retry re-enters print-failure-then-prompt")
        try MiniTest.expectEqual(editorRunner.launches, 2)
    }),

    // MARK: - §15 Bind recovery

    ("bindRecoveryEligibilityMatrix", {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("adev-bind-elig-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let config = root.appendingPathComponent("devcontainer.json").path
        try Data(#"{"image":"alpine:3.20"}"#.utf8).write(to: URL(fileURLWithPath: config))

        let bindLabels: [String: String] = [
            ContainerIdentity.labelManaged: ContainerIdentity.managedValue,
            ContainerIdentity.labelWorkspaceMode: ContainerIdentity.workspaceModeBind,
            ContainerIdentity.labelLocalFolder: root.path,
            ContainerIdentity.labelConfigFile: config
        ]
        try MiniTest.expect(RecoveryOrchestrator.isBindEligible(labels: bindLabels))
        try MiniTest.expectEqual(RecoveryOrchestrator.mode(labels: bindLabels), .bindHostEditor)
        try MiniTest.expectEqual(RecoveryOrchestrator.hostConfigPath(labels: bindLabels), (config as NSString).standardizingPath)

        // Volume clone-origin is volume helper, not bind.
        try MiniTest.expectEqual(RecoveryOrchestrator.mode(labels: orchestratorLabels()), .volumeHelper)
        try MiniTest.expect(!RecoveryOrchestrator.isBindEligible(labels: orchestratorLabels()))

        // Non-clone volume (missing git) is ineligible for both.
        let nonClone = orchestratorLabels(gitURL: "")
        try MiniTest.expect(!RecoveryHelper.isEligible(labels: nonClone))
        try MiniTest.expect(!RecoveryOrchestrator.isBindEligible(labels: nonClone))
        try MiniTest.expectEqual(RecoveryOrchestrator.mode(labels: nonClone), .none)

        // Missing bind stamps.
        var missing = bindLabels
        missing[ContainerIdentity.labelLocalFolder] = ""
        try MiniTest.expect(!RecoveryOrchestrator.isBindEligible(labels: missing))
    }),

    ("bindRecoveryNonTTYRetainsHostPathWithoutHelper", {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("adev-bind-nontty-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let configPath = root.appendingPathComponent("devcontainer.json").path
        try Data(#"{"image":"alpine:3.20","postCreateCommand":"exit 1"}"#.utf8)
            .write(to: URL(fileURLWithPath: configPath))

        let labels: [String: String] = [
            ContainerIdentity.labelManaged: ContainerIdentity.managedValue,
            ContainerIdentity.labelWorkspaceMode: ContainerIdentity.workspaceModeBind,
            ContainerIdentity.labelLocalFolder: root.path,
            ContainerIdentity.labelConfigFile: configPath
        ]
        let selected = ContainerInfo(
            id: "bind-old",
            name: "adev-bind-ws",
            state: "running",
            labels: labels,
            image: "alpine"
        )
        let mock = MockProcessRunner()
        mock.handlers.append { args in
            if args.first == "delete" {
                return ProcessResult(exitCode: 0, stdout: Data(), stderr: Data())
            }
            if args.starts(with: ["list", "--all"]) {
                return ProcessResult(exitCode: 0, stdout: Data("[]".utf8), stderr: Data())
            }
            return nil
        }
        let runtime = AppleContainerRuntime(executablePath: "container", runner: mock)
        let editorRunner = RecoveryWritingEditorRunner(bytes: Data())
        let editor = RecoveryEditor(
            environment: ["VISUAL": "/test-editor"],
            runner: editorRunner,
            fallbackEditors: [],
            executableChecker: { _ in true }
        )
        defer { try? BindRecoveryResume.cleanup(name: selected.name) }

        try MiniTest.expectThrows({
            _ = try RecoveryOrchestrator.recoverBind(
                labels: labels,
                failure: .init(
                    error: CLIError(
                        code: CLIErrorCode.postCreateFailed,
                        property: "postCreateCommand",
                        message: "hook failed"
                    ),
                    containerID: "failed-new"
                ),
                selected: selected,
                runtime: runtime,
                options: RebuildOptions(jsonOutput: true),
                localEnv: [:],
                isTTY: false,
                editor: editor,
                retry: { fatalError("non-TTY must not retry") }
            )
        }) { error in
            let cli = error as? CLIError
            try MiniTest.expectEqual(cli?.code, CLIErrorCode.recoveryUnavailable)
            try MiniTest.expectEqual(cli?.recovery?.mode, "bind")
            try MiniTest.expectEqual(cli?.recovery?.configPath, (configPath as NSString).standardizingPath)
            try MiniTest.expectEqual(cli?.recovery?.helperAvailable, false)
            try MiniTest.expectEqual(cli?.recovery?.sessionID, "")
            try MiniTest.expectEqual(cli?.recovery?.workspaceVolume, "")
            try MiniTest.expectEqual(cli?.recovery?.tempFile, "")
            try MiniTest.expectEqual(cli?.recovery?.cleanupCommand, "")
            try MiniTest.expect(cli?.recovery?.retryCommand.contains("rebuild") == true)
            try MiniTest.expect(cli?.recovery?.editCommand.contains("devcontainer.json") == true)
            try MiniTest.expect(!(cli?.recovery?.cleanupCommand.contains("delete") ?? false))
            let json = cli?.recovery?.jsonObject() ?? [:]
            try MiniTest.expect(json["sessionId"] == nil)
            try MiniTest.expect(json["workspaceVolume"] == nil)
            try MiniTest.expect(json["tempFile"] == nil)
            try MiniTest.expect(json["cleanupCommand"] == nil)
            try MiniTest.expect(json["marker"] == nil)
        }
        try MiniTest.expectEqual(editorRunner.launches, 0)
        try MiniTest.expect(!mock.calls.contains { $0.arguments.first == "create" })
        try MiniTest.expect(!mock.calls.contains { $0.arguments.contains("image") })
        // Resume stamps retained for named retry.
        let resume = try BindRecoveryResume.load(name: selected.name)
        try MiniTest.expect(resume != nil)
        try MiniTest.expectEqual(resume?.hostConfigPath, (configPath as NSString).standardizingPath)
    }),

    ("bindTTYPromptDeclineRetainsResumeWithoutEditor", {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("adev-bind-decline-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let configPath = root.appendingPathComponent("devcontainer.json").path
        try Data(#"{"image":"alpine:3.20"}"#.utf8).write(to: URL(fileURLWithPath: configPath))

        let labels: [String: String] = [
            ContainerIdentity.labelManaged: ContainerIdentity.managedValue,
            ContainerIdentity.labelWorkspaceMode: ContainerIdentity.workspaceModeBind,
            ContainerIdentity.labelLocalFolder: root.path,
            ContainerIdentity.labelConfigFile: configPath
        ]
        let selected = ContainerInfo(
            id: "bind-old",
            name: "adev-bind-decline",
            state: "running",
            labels: labels,
            image: "alpine"
        )
        let mock = MockProcessRunner()
        mock.defaultResult = ProcessResult(exitCode: 0, stdout: Data("[]".utf8), stderr: Data())
        let runtime = AppleContainerRuntime(executablePath: "container", runner: mock)
        let editorRunner = RecoveryWritingEditorRunner(bytes: Data())
        let editor = RecoveryEditor(
            environment: ["VISUAL": "/test-editor"],
            runner: editorRunner,
            fallbackEditors: [],
            executableChecker: { _ in true }
        )
        defer { try? BindRecoveryResume.cleanup(name: selected.name) }

        try MiniTest.expectThrows({
            _ = try RecoveryOrchestrator.recoverBind(
                labels: labels,
                failure: .init(
                    error: CLIError(code: CLIErrorCode.postCreateFailed, property: "postCreateCommand", message: "hook"),
                    containerID: "failed-new"
                ),
                selected: selected,
                runtime: runtime,
                options: RebuildOptions(),
                localEnv: [:],
                isTTY: true,
                editor: editor,
                openEditorPrompt: declineOpenEditorPrompt(answer: "no"),
                retry: { fatalError("decline must not retry") }
            )
        }) { error in
            let cli = error as? CLIError
            try MiniTest.expectEqual(cli?.code, CLIErrorCode.recoveryCancelled)
            try MiniTest.expectEqual(cli?.recovery?.mode, "bind")
            try MiniTest.expect(cli?.recovery?.retryCommand.contains("rebuild") == true)
            try MiniTest.expect(cli?.recovery?.editCommand.contains("devcontainer.json") == true)
            try MiniTest.expectEqual(cli?.recovery?.cleanupCommand, "")
        }
        try MiniTest.expectEqual(editorRunner.launches, 0)
        try MiniTest.expect(try BindRecoveryResume.load(name: selected.name) != nil, "resume retained on defer")
    }),

    ("bindTTYPromptEOFDefersWithoutEditor", {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("adev-bind-eof-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let configPath = root.appendingPathComponent("devcontainer.json").path
        try Data(#"{"image":"alpine:3.20"}"#.utf8).write(to: URL(fileURLWithPath: configPath))

        let labels: [String: String] = [
            ContainerIdentity.labelManaged: ContainerIdentity.managedValue,
            ContainerIdentity.labelWorkspaceMode: ContainerIdentity.workspaceModeBind,
            ContainerIdentity.labelLocalFolder: root.path,
            ContainerIdentity.labelConfigFile: configPath
        ]
        let selected = ContainerInfo(
            id: "bind-old",
            name: "adev-bind-eof",
            state: "running",
            labels: labels,
            image: "alpine"
        )
        let mock = MockProcessRunner()
        mock.defaultResult = ProcessResult(exitCode: 0, stdout: Data("[]".utf8), stderr: Data())
        let runtime = AppleContainerRuntime(executablePath: "container", runner: mock)
        let editorRunner = RecoveryWritingEditorRunner(bytes: Data())
        let editor = RecoveryEditor(
            environment: ["VISUAL": "/test-editor"],
            runner: editorRunner,
            fallbackEditors: [],
            executableChecker: { _ in true }
        )
        defer { try? BindRecoveryResume.cleanup(name: selected.name) }

        try MiniTest.expectThrows({
            _ = try RecoveryOrchestrator.recoverBind(
                labels: labels,
                failure: .init(error: CLIError(code: CLIErrorCode.lifecycleFailed, message: "hook"), containerID: "x"),
                selected: selected,
                runtime: runtime,
                options: RebuildOptions(),
                localEnv: [:],
                isTTY: true,
                editor: editor,
                openEditorPrompt: declineOpenEditorPrompt(answer: nil),
                retry: { fatalError("EOF must not retry") }
            )
        }) { error in
            try MiniTest.expectEqual((error as? CLIError)?.code, CLIErrorCode.recoveryCancelled)
        }
        try MiniTest.expectEqual(editorRunner.launches, 0)
    }),

    ("bindTTYInvalidReopenDoesNotRePrompt", {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("adev-bind-noreprompt-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let configURL = root.appendingPathComponent("devcontainer.json")
        let valid = Data(#"{"image":"alpine:3.20"}"#.utf8)
        let invalid = Data(#"{"image":}"#.utf8)
        try valid.write(to: configURL)

        let labels: [String: String] = [
            ContainerIdentity.labelManaged: ContainerIdentity.managedValue,
            ContainerIdentity.labelWorkspaceMode: ContainerIdentity.workspaceModeBind,
            ContainerIdentity.labelLocalFolder: root.path,
            ContainerIdentity.labelConfigFile: configURL.path
        ]
        let selected = ContainerInfo(
            id: "bind-old",
            name: "adev-bind-noreprompt",
            state: "running",
            labels: labels,
            image: "alpine"
        )
        let mock = MockProcessRunner()
        mock.defaultResult = ProcessResult(exitCode: 0, stdout: Data("[]".utf8), stderr: Data())
        let runtime = AppleContainerRuntime(executablePath: "container", runner: mock)
        let editorRunner = RecoverySequenceEditorRunner(payloads: [invalid, valid])
        let editor = RecoveryEditor(
            environment: ["VISUAL": "/test-editor"],
            runner: editorRunner,
            fallbackEditors: [],
            executableChecker: { _ in true }
        )
        defer { try? BindRecoveryResume.cleanup(name: selected.name) }
        final class Counter: @unchecked Sendable { var prompts = 0 }
        let counter = Counter()
        let prompt = affirmativeOpenEditorPrompt(answers: [""]) { line in
            if line.contains(RecoveryOpenEditorPrompt.promptText) { counter.prompts += 1 }
        }
        _ = try RecoveryOrchestrator.recoverBind(
            labels: labels,
            failure: .init(error: CLIError(code: CLIErrorCode.lifecycleFailed, message: "hook")),
            selected: selected,
            runtime: runtime,
            options: RebuildOptions(),
            localEnv: [:],
            isTTY: true,
            editor: editor,
            openEditorPrompt: prompt,
            retry: {
                RebuildResult(outcome: "success", containerId: "final", remoteUser: "", remoteWorkspaceFolder: "/workspaces/x")
            }
        )
        try MiniTest.expectEqual(editorRunner.launches, 2)
        try MiniTest.expectEqual(counter.prompts, 1, "bind invalid reopen must not re-ask open-editor prompt")
    }),

    ("bindRecoveryTTYOpensHostPathAndRetries", {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("adev-bind-tty-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let configURL = root.appendingPathComponent("devcontainer.json")
        let broken = Data(#"{"image":"alpine:3.20","postCreateCommand":"exit 1"}"#.utf8)
        let fixed = Data(#"{"image":"alpine:3.20"}"#.utf8)
        try broken.write(to: configURL)

        let labels: [String: String] = [
            ContainerIdentity.labelManaged: ContainerIdentity.managedValue,
            ContainerIdentity.labelWorkspaceMode: ContainerIdentity.workspaceModeBind,
            ContainerIdentity.labelLocalFolder: root.path,
            ContainerIdentity.labelConfigFile: configURL.path
        ]
        let selected = ContainerInfo(
            id: "bind-old",
            name: "adev-bind-tty",
            state: "running",
            labels: labels,
            image: "alpine"
        )
        let mock = MockProcessRunner()
        mock.handlers.append { args in
            if args.first == "delete" || args.starts(with: ["list", "--all"]) {
                return ProcessResult(exitCode: 0, stdout: Data("[]".utf8), stderr: Data())
            }
            return nil
        }
        let runtime = AppleContainerRuntime(executablePath: "container", runner: mock)
        let editorRunner = RecoveryWritingEditorRunner(bytes: fixed)
        let editor = RecoveryEditor(
            environment: ["VISUAL": "/test-editor"],
            runner: editorRunner,
            fallbackEditors: [],
            executableChecker: { _ in true }
        )
        defer { try? BindRecoveryResume.cleanup(name: selected.name) }

        var retryCalls = 0
        var editorPath: String?
        let result = try RecoveryOrchestrator.recoverBind(
            labels: labels,
            failure: .init(
                error: CLIError(code: CLIErrorCode.postCreateFailed, message: "postCreate failed"),
                containerID: "failed-new"
            ),
            selected: selected,
            runtime: runtime,
            options: RebuildOptions(),
            localEnv: [:],
            isTTY: true,
            editor: editor,
            openEditorPrompt: affirmativeOpenEditorPrompt(),
            retry: {
                retryCalls += 1
                editorPath = editorRunner.launches > 0
                    ? (try? String(contentsOf: configURL, encoding: .utf8))
                    : nil
                // Editor wrote fixed bytes to host path.
                let onDisk = try Data(contentsOf: configURL)
                try MiniTest.expectEqual(onDisk, fixed)
                return RebuildResult(
                    outcome: "success",
                    containerId: "final-bind",
                    remoteUser: "vscode",
                    remoteWorkspaceFolder: "/workspaces/x"
                )
            }
        )
        try MiniTest.expectEqual(result.outcome, "success")
        try MiniTest.expectEqual(retryCalls, 1)
        try MiniTest.expectEqual(editorRunner.launches, 1)
        try MiniTest.expect(editorPath != nil)
        // No helper create / image preflight / recovery write.
        try MiniTest.expect(!mock.calls.contains { $0.arguments.first == "create" })
        try MiniTest.expect(!mock.calls.contains {
            $0.arguments.contains("adevcontainer-recovery-write")
        })
        try MiniTest.expect(!mock.calls.contains { $0.arguments.first == "image" })
    }),

    ("bindRecoveryTTYInvalidEditReopensWithoutRetry", {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("adev-bind-invalid-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let configURL = root.appendingPathComponent("devcontainer.json")
        let valid = Data(#"{"image":"alpine:3.20"}"#.utf8)
        let invalid = Data(#"{"image":}"#.utf8)
        try valid.write(to: configURL)

        let labels: [String: String] = [
            ContainerIdentity.labelManaged: ContainerIdentity.managedValue,
            ContainerIdentity.labelWorkspaceMode: ContainerIdentity.workspaceModeBind,
            ContainerIdentity.labelLocalFolder: root.path,
            ContainerIdentity.labelConfigFile: configURL.path
        ]
        let selected = ContainerInfo(
            id: "bind-old",
            name: "adev-bind-invalid",
            state: "running",
            labels: labels,
            image: "alpine"
        )
        let mock = MockProcessRunner()
        mock.defaultResult = ProcessResult(exitCode: 0, stdout: Data("[]".utf8), stderr: Data())
        let runtime = AppleContainerRuntime(executablePath: "container", runner: mock)
        let editorRunner = RecoverySequenceEditorRunner(payloads: [invalid, valid])
        let editor = RecoveryEditor(
            environment: ["VISUAL": "/test-editor"],
            runner: editorRunner,
            fallbackEditors: [],
            executableChecker: { _ in true }
        )
        defer { try? BindRecoveryResume.cleanup(name: selected.name) }

        var retryCalls = 0
        _ = try RecoveryOrchestrator.recoverBind(
            labels: labels,
            failure: .init(error: CLIError(code: CLIErrorCode.lifecycleFailed, message: "hook")),
            selected: selected,
            runtime: runtime,
            options: RebuildOptions(),
            localEnv: [:],
            isTTY: true,
            editor: editor,
            openEditorPrompt: affirmativeOpenEditorPrompt(),
            retry: {
                retryCalls += 1
                return RebuildResult(
                    outcome: "success",
                    containerId: "final",
                    remoteUser: "",
                    remoteWorkspaceFolder: "/workspaces/x"
                )
            }
        )
        try MiniTest.expectEqual(editorRunner.launches, 2, "invalid edit reopens editor")
        try MiniTest.expectEqual(retryCalls, 1, "retry only after valid bind resolve")
    }),

    ("bindRecoveryTTYCancelLeavesHostFileNoHelperCleanup", {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("adev-bind-cancel-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let configURL = root.appendingPathComponent("devcontainer.json")
        let original = Data(#"{"image":"alpine:3.20","name":"keep-me"}"#.utf8)
        try original.write(to: configURL)

        let labels: [String: String] = [
            ContainerIdentity.labelManaged: ContainerIdentity.managedValue,
            ContainerIdentity.labelWorkspaceMode: ContainerIdentity.workspaceModeBind,
            ContainerIdentity.labelLocalFolder: root.path,
            ContainerIdentity.labelConfigFile: configURL.path
        ]
        let selected = ContainerInfo(
            id: "bind-old",
            name: "adev-bind-cancel",
            state: "running",
            labels: labels,
            image: "alpine"
        )
        let mock = MockProcessRunner()
        mock.defaultResult = ProcessResult(exitCode: 0, stdout: Data("[]".utf8), stderr: Data())
        let runtime = AppleContainerRuntime(executablePath: "container", runner: mock)
        let editor = RecoveryEditor(
            environment: ["VISUAL": "/test-editor"],
            runner: RecoveryCancellationRunner(),
            fallbackEditors: [],
            executableChecker: { _ in true }
        )
        defer { try? BindRecoveryResume.cleanup(name: selected.name) }

        try MiniTest.expectThrows({
            _ = try RecoveryOrchestrator.recoverBind(
                labels: labels,
                failure: .init(error: CLIError(code: CLIErrorCode.lifecycleFailed, message: "hook")),
                selected: selected,
                runtime: runtime,
                options: RebuildOptions(),
                localEnv: [:],
                isTTY: true,
                editor: editor,
                openEditorPrompt: affirmativeOpenEditorPrompt(),
                retry: { fatalError("cancel must not retry") }
            )
        }) { error in
            let cli = error as? CLIError
            try MiniTest.expectEqual(cli?.code, CLIErrorCode.recoveryCancelled)
            try MiniTest.expectEqual(cli?.recovery?.mode, "bind")
            try MiniTest.expect(cli?.recovery?.retryCommand.contains("rebuild") == true)
            try MiniTest.expectEqual(cli?.recovery?.cleanupCommand, "")
            try MiniTest.expect(!(cli?.hint?.contains("helper") ?? false))
        }
        let onDisk = try Data(contentsOf: configURL)
        try MiniTest.expectEqual(onDisk, original, "cancel leaves host file as-is")
        try MiniTest.expect(!mock.calls.contains { $0.arguments.first == "create" })
    }),

    ("bindRecoveryHardFailureMatrixCleansNewNoHelper", {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("adev-bind-matrix-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let configPath = root.appendingPathComponent("devcontainer.json").path
        try Data(#"{"image":"alpine:3.20"}"#.utf8).write(to: URL(fileURLWithPath: configPath))

        let labels: [String: String] = [
            ContainerIdentity.labelManaged: ContainerIdentity.managedValue,
            ContainerIdentity.labelWorkspaceMode: ContainerIdentity.workspaceModeBind,
            ContainerIdentity.labelLocalFolder: root.path,
            ContainerIdentity.labelConfigFile: configPath
        ]
        let selected = ContainerInfo(
            id: "bind-old",
            name: "adev-bind-matrix",
            state: "running",
            labels: labels,
            image: "alpine"
        )
        defer { try? BindRecoveryResume.cleanup(name: selected.name) }

        let failures: [(String, CLIError)] = [
            ("create", CLIError(code: CLIErrorCode.runtimeFailed, message: "create failed")),
            ("start", CLIError(code: CLIErrorCode.runtimeFailed, message: "start failed")),
            ("onCreate", CLIError(code: CLIErrorCode.lifecycleFailed, property: "onCreateCommand", message: "onCreate")),
            ("updateContent", CLIError(code: CLIErrorCode.lifecycleFailed, property: "updateContentCommand", message: "update")),
            ("postCreate", CLIError(code: CLIErrorCode.postCreateFailed, property: "postCreateCommand", message: "postCreate")),
            ("postStart", CLIError(code: CLIErrorCode.lifecycleFailed, property: "postStartCommand", message: "postStart"))
        ]

        for (name, err) in failures {
            let mock = MockProcessRunner()
            var deleted: [String] = []
            mock.handlers.append { args in
                if args.first == "delete" {
                    deleted.append(args.last ?? "")
                    return ProcessResult(exitCode: 0, stdout: Data(), stderr: Data())
                }
                if args.starts(with: ["list", "--all"]) {
                    // findByName → list
                    let id = "failed-new-\(name)"
                    let json = """
                    [{"id":"\(id)","configuration":{"id":"\(id)","labels":{}},"status":{"state":"running"}}]
                    """
                    return ProcessResult(exitCode: 0, stdout: Data(json.utf8), stderr: Data())
                }
                return nil
            }
            let runtime = AppleContainerRuntime(executablePath: "container", runner: mock)
            let editor = RecoveryEditor(
                environment: ["VISUAL": "/test-editor"],
                runner: MockProcessRunner(),
                fallbackEditors: [],
                executableChecker: { _ in true }
            )
            try MiniTest.expectThrows({
                _ = try RecoveryOrchestrator.recoverBind(
                    labels: labels,
                    failure: .init(error: err, containerID: "failed-new-\(name)"),
                    selected: selected,
                    runtime: runtime,
                    options: RebuildOptions(jsonOutput: true),
                    localEnv: [:],
                    isTTY: false,
                    editor: editor,
                    retry: { fatalError("non-TTY") }
                )
            }) { error in
                try MiniTest.expectEqual((error as? CLIError)?.recovery?.mode, "bind", name)
                try MiniTest.expectEqual((error as? CLIError)?.recovery?.helperAvailable, false, name)
            }
            try MiniTest.expect(!mock.calls.contains { $0.arguments.first == "create" }, name)
            try MiniTest.expect(
                !mock.calls.contains { $0.arguments.first == "image" },
                "no Alpine preflight for bind (\(name))"
            )
            try MiniTest.expect(
                deleted.contains { $0.contains("failed-new") } || mock.calls.contains { $0.arguments.first == "delete" },
                "failed new cleaned (\(name))"
            )
        }
    }),

    ("bindRecoveryDoesNotRecoverPostAttach", {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("adev-bind-pa-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let configURL = root.appendingPathComponent("devcontainer.json")
        try Data(#"{"image":"alpine:3.20"}"#.utf8).write(to: configURL)

        let labels: [String: String] = [
            ContainerIdentity.labelManaged: ContainerIdentity.managedValue,
            ContainerIdentity.labelWorkspaceMode: ContainerIdentity.workspaceModeBind,
            ContainerIdentity.labelLocalFolder: root.path,
            ContainerIdentity.labelConfigFile: configURL.path
        ]
        let selected = ContainerInfo(
            id: "bind-old",
            name: "adev-bind-pa",
            state: "running",
            labels: labels,
            image: "alpine"
        )
        let mock = MockProcessRunner()
        mock.defaultResult = ProcessResult(exitCode: 0, stdout: Data("[]".utf8), stderr: Data())
        let runtime = AppleContainerRuntime(executablePath: "container", runner: mock)
        let editor = RecoveryEditor(
            environment: ["VISUAL": "/test-editor"],
            runner: RecoveryWritingEditorRunner(bytes: Data(#"{"image":"alpine:3.20"}"#.utf8)),
            fallbackEditors: [],
            executableChecker: { _ in true }
        )
        defer { try? BindRecoveryResume.cleanup(name: selected.name) }

        let postAttach = CLIError(
            code: CLIErrorCode.lifecycleFailed,
            property: "postAttachCommand",
            message: "postAttach failed"
        )
        try MiniTest.expectThrows({
            _ = try RecoveryOrchestrator.recoverBind(
                labels: labels,
                failure: .init(error: CLIError(code: CLIErrorCode.lifecycleFailed, message: "initial")),
                selected: selected,
                runtime: runtime,
                options: RebuildOptions(),
                localEnv: [:],
                isTTY: true,
                editor: editor,
                openEditorPrompt: affirmativeOpenEditorPrompt(),
                retry: { throw postAttach }
            )
        }) { error in
            try MiniTest.expectEqual(error as? CLIError, postAttach)
        }
    }),

    ("volumeRecoveryPathUnchangedWithBindPresent", {
        // Clone-origin volume hard failure still uses helper preflight + create + temp write.
        let rawBytes = Data(#"{"image":"alpine:3.20"}"#.utf8)
        let container = ContainerInfo(
            id: "old",
            name: "old",
            state: "running",
            labels: orchestratorLabels(),
            image: "alpine"
        )
        let raw = RawVolumeConfig(
            bytes: rawBytes,
            pathInContainer: "/workspaces/repo/.devcontainer/devcontainer.json",
            workspaceFolder: "/workspaces/repo",
            workspaceFolderBasename: "repo"
        )
        let mock = MockProcessRunner()
        installRecoveryRuntime(mock, rawBytes: rawBytes)
        let runtime = AppleContainerRuntime(executablePath: "container", runner: mock)
        let prepared = try RecoveryOrchestrator.prepare(
            container: container,
            rawConfig: raw,
            runtime: runtime,
            sessionID: "volume-unchanged-session",
            pullIfMissing: false
        )
        defer { try? prepared.session.cleanup() }
        let editorRunner = RecoveryWritingEditorRunner(bytes: rawBytes)
        let editor = RecoveryEditor(
            environment: ["VISUAL": "/test-editor"],
            runner: editorRunner,
            fallbackEditors: [],
            executableChecker: { _ in true }
        )
        _ = try RecoveryOrchestrator.recover(
            prepared: prepared,
            failure: .init(error: CLIError(code: CLIErrorCode.lifecycleFailed, message: "hook")),
            selected: container,
            runtime: runtime,
            options: RebuildOptions(),
            localEnv: [:],
            isTTY: true,
            editor: editor,
            openEditorPrompt: affirmativeOpenEditorPrompt(),
            retry: { _, _ in
                RebuildResult(
                    outcome: "success",
                    containerId: "final",
                    remoteUser: "vscode",
                    remoteWorkspaceFolder: "/workspaces/repo"
                )
            }
        )
        try MiniTest.expect(mock.calls.contains { $0.arguments.first == "create" })
        try MiniTest.expect(mock.calls.contains { $0.arguments.first == "image" || $0.arguments.contains("image") })
        try MiniTest.expect(
            mock.calls.contains {
                $0.arguments.first == "exec" && $0.arguments.contains("adevcontainer-recovery-write")
            }
        )
        try MiniTest.expectEqual(editorRunner.launches, 1)
        try MiniTest.expectEqual(RecoveryOrchestrator.mode(labels: orchestratorLabels()), .volumeHelper)
    })
  ]
