import Foundation
@testable import ADevContainerLib

/// §15.5 Bind non-TTY / `--json` recovery detail contracts (host path, no helper cleanup).
nonisolated(unsafe) let recoveryOutputTests: [(String, () throws -> Void)] = [
    ("bindRecoveryDetailsOmitHelperFieldsInJSON", {
        let details = RecoveryErrorDetails.bindHostPath(
            containerName: "adev-bind",
            containerID: "ctr-123",
            configPath: "/Users/me/ws/.devcontainer/devcontainer.json",
            failureKind: CLIErrorCode.postCreateFailed,
            editCommand: "'/usr/bin/vi' '/Users/me/ws/.devcontainer/devcontainer.json'",
            retryCommand: "'adevcontainer' 'rebuild' '--name' 'adev-bind'"
        )
        let error = CLIError(
            code: CLIErrorCode.recoveryUnavailable,
            message: "Rebuild failed after the old container was removed",
            hint: "Edit host config",
            recovery: details
        )
        let object = error.jsonObject()
        let recovery = object["recovery"] as? [String: Any]
        try MiniTest.expectEqual(recovery?["mode"] as? String, "bind")
        try MiniTest.expectEqual(
            recovery?["configPath"] as? String,
            "/Users/me/ws/.devcontainer/devcontainer.json"
        )
        try MiniTest.expectEqual(recovery?["helperContainerName"] as? String, "adev-bind")
        try MiniTest.expectEqual(recovery?["helperContainerId"] as? String, "ctr-123")
        try MiniTest.expectEqual(recovery?["helperAvailable"] as? Bool, false)
        try MiniTest.expectEqual(recovery?["failureKind"] as? String, CLIErrorCode.postCreateFailed)
        try MiniTest.expect(recovery?["editCommand"] as? String != nil)
        try MiniTest.expect(
            (recovery?["retryCommand"] as? String)?.contains("rebuild") == true
        )
        try MiniTest.expect(recovery?["sessionId"] == nil)
        try MiniTest.expect(recovery?["workspaceVolume"] == nil)
        try MiniTest.expect(recovery?["tempFile"] == nil)
        try MiniTest.expect(recovery?["cleanupCommand"] == nil)
        try MiniTest.expect(recovery?["marker"] == nil)
        try MiniTest.expect(recovery?["expectedHash"] == nil)
        try MiniTest.expect(object["rawConfig"] == nil)

        let serialized = String(data: CLIErrorOutput.data(for: error, json: true), encoding: .utf8) ?? ""
        try MiniTest.expect(!serialized.contains("helper delete"))
        try MiniTest.expect(!serialized.contains("adevcontainer delete"))
        try MiniTest.expect(serialized.contains("rebuild"))
        try MiniTest.expect(serialized.contains("configPath"))
    }),

    ("bindRecoveryCancelledDetailsIncludeHostPathAndRetry", {
        let details = RecoveryErrorDetails.bindHostPath(
            containerName: "adev-bind",
            configPath: "/tmp/ws/.devcontainer/devcontainer.json",
            failureKind: CLIErrorCode.recoveryCancelled,
            editCommand: "'/usr/bin/nano' '/tmp/ws/.devcontainer/devcontainer.json'",
            retryCommand: "'adevcontainer' 'rebuild' '--name' 'adev-bind'"
        )
        let error = CLIError(
            code: CLIErrorCode.recoveryCancelled,
            message: "Recovery editing was cancelled",
            hint: "Host config left as edited",
            recovery: details
        )
        let recovery = error.jsonObject()["recovery"] as? [String: Any]
        try MiniTest.expectEqual(recovery?["mode"] as? String, "bind")
        try MiniTest.expect(recovery?["cleanupCommand"] == nil)
        try MiniTest.expect(
            (recovery?["retryCommand"] as? String)?.contains("--name") == true
        )
    }),

    ("volumeRecoveryDetailsStillIncludeHelperFields", {
        // Regression: volume JSON shape must not lose helper/session fields when bind exists.
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
            cleanupCommand: "adevcontainer delete --name 'adev-repo'; rm -rf -- '/tmp/session'"
        )
        let recovery = details.jsonObject()
        try MiniTest.expectEqual(recovery["mode"] as? String, "volume")
        try MiniTest.expectEqual(recovery["sessionId"] as? String, "session-id")
        try MiniTest.expectEqual(recovery["workspaceVolume"] as? String, "adev-repo-ws")
        try MiniTest.expectEqual(recovery["tempFile"] as? String, details.tempFile)
        try MiniTest.expectEqual(recovery["helperContainerId"] as? String, "helper-id")
        try MiniTest.expect(recovery["cleanupCommand"] as? String != nil)
        try MiniTest.expect(recovery["marker"] as? String != nil)
        try MiniTest.expect(recovery["expectedHash"] as? String != nil)
    })
]
