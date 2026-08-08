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

    /// Create-path order: onCreate → updateContent → postCreate → postStart
    /// (config hook then any feature-contributed hooks per stage).
    public static func runCreatePath(
        containerId: String,
        config: ResolvedDevContainerConfig,
        runtime: AppleContainerRuntime
    ) throws {
        let stages: [(String, LifecycleCommand?, [LifecycleCommand])] = [
            ("onCreateCommand", config.onCreateCommand, config.featureOnCreateCommands),
            ("updateContentCommand", config.updateContentCommand, config.featureUpdateContentCommands),
            ("postCreateCommand", config.postCreateCommand, config.featurePostCreateCommands),
            ("postStartCommand", config.postStartCommand, config.featurePostStartCommands)
        ]
        for (property, primary, extras) in stages {
            try runIfPresent(
                property: property,
                command: primary,
                containerId: containerId,
                config: config,
                runtime: runtime,
                failurePolicy: .deleteContainerThenFail
            )
            for (index, extra) in extras.enumerated() {
                let label = extras.count == 1
                    ? "\(property) (feature)"
                    : "\(property) (feature \(index + 1))"
                try runIfPresent(
                    property: label,
                    command: extra,
                    containerId: containerId,
                    config: config,
                    runtime: runtime,
                    failurePolicy: .deleteContainerThenFail
                )
            }
        }
    }

    /// Restart path: postStart only (config + feature); do not delete on failure.
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
        for (index, extra) in config.featurePostStartCommands.enumerated() {
            let label = config.featurePostStartCommands.count == 1
                ? "postStartCommand (feature)"
                : "postStartCommand (feature \(index + 1))"
            try runIfPresent(
                property: label,
                command: extra,
                containerId: containerId,
                config: config,
                runtime: runtime,
                failurePolicy: .failKeepContainer
            )
        }
    }

    /// Emit one-time postAttach skip status when the property is set (config or feature).
    public static func emitPostAttachSkipIfNeeded(config: ResolvedDevContainerConfig) {
        let hasAttach = config.postAttachCommand != nil || !config.featurePostAttachCommands.isEmpty
        guard hasAttach else { return }
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

        // Map feature-labeled properties back to base code family.
        let baseProperty: String
        if let range = property.range(of: " (feature") {
            baseProperty = String(property[..<range.lowerBound])
        } else {
            baseProperty = property
        }

        let code: String
        if baseProperty == "postCreateCommand" {
            code = CLIErrorCode.postCreateFailed
        } else {
            code = CLIErrorCode.lifecycleFailed
        }

        return CLIError(
            code: code,
            property: property,
            message: "\(property) failed with exit \(execResult.exitCode)"
                + (detail.isEmpty ? "" : ": \(detail)"),
            hint: "Fix the \(baseProperty) or exec into the container to debug"
        )
    }
}
