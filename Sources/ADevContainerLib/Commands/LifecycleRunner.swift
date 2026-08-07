import Foundation

/// Shared lifecycle hook execution for `up` (exec + status + fail mapping).
public enum LifecycleRunner {
    public enum FailurePolicy: Sendable {
        /// Delete container before failing (create-path hooks including first-create postStart).
        case deleteContainerThenFail
        /// Fail without deleting (restart postStart).
        case failKeepContainer
    }

    /// Run a single lifecycle command if present. No-op when `command` is nil.
    public static func runIfPresent(
        property: String,
        command: LifecycleCommand?,
        containerId: String,
        config: ResolvedDevContainerConfig,
        runtime: AppleContainerRuntime,
        failurePolicy: FailurePolicy
    ) throws {
        guard let command else { return }

        StatusPrinter.status("Running \(property)")
        let execResult = try runtime.exec(
            nameOrId: containerId,
            command: command.execArguments,
            user: config.effectiveUser,
            workdir: config.workspaceFolder,
            env: config.containerEnv
        )
        guard execResult.succeeded else {
            if failurePolicy == .deleteContainerThenFail {
                try? runtime.delete(nameOrId: containerId, force: true)
            }
            throw lifecycleError(property: property, execResult: execResult)
        }
    }

    /// Create-path order: onCreate → updateContent → postCreate → postStart.
    public static func runCreatePath(
        containerId: String,
        config: ResolvedDevContainerConfig,
        runtime: AppleContainerRuntime
    ) throws {
        let steps: [(String, LifecycleCommand?)] = [
            ("onCreateCommand", config.onCreateCommand),
            ("updateContentCommand", config.updateContentCommand),
            ("postCreateCommand", config.postCreateCommand),
            ("postStartCommand", config.postStartCommand)
        ]
        for (property, command) in steps {
            try runIfPresent(
                property: property,
                command: command,
                containerId: containerId,
                config: config,
                runtime: runtime,
                failurePolicy: .deleteContainerThenFail
            )
        }
    }

    /// Restart path: postStart only; do not delete on failure.
    public static func runRestartPostStart(
        containerId: String,
        config: ResolvedDevContainerConfig,
        runtime: AppleContainerRuntime
    ) throws {
        try runIfPresent(
            property: "postStartCommand",
            command: config.postStartCommand,
            containerId: containerId,
            config: config,
            runtime: runtime,
            failurePolicy: .failKeepContainer
        )
    }

    /// Emit one-time postAttach skip status when the property is set.
    public static func emitPostAttachSkipIfNeeded(config: ResolvedDevContainerConfig) {
        guard config.postAttachCommand != nil else { return }
        StatusPrinter.status("postAttach skipped (no attach hook)")
    }

    private static func lifecycleError(
        property: String,
        execResult: ProcessResult
    ) -> CLIError {
        let detail = [
            execResult.stderrString.trimmingCharacters(in: .whitespacesAndNewlines),
            execResult.stdoutString.trimmingCharacters(in: .whitespacesAndNewlines)
        ].filter { !$0.isEmpty }.joined(separator: " | ")

        let code: String
        if property == "postCreateCommand" {
            code = CLIErrorCode.postCreateFailed
        } else {
            code = CLIErrorCode.lifecycleFailed
        }

        return CLIError(
            code: code,
            property: property,
            message: "\(property) failed with exit \(execResult.exitCode)"
                + (detail.isEmpty ? "" : ": \(detail)"),
            hint: "Fix the \(property) or exec into the container to debug"
        )
    }
}
