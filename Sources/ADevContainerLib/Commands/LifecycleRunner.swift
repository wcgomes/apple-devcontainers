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
    /// Object-form (`.parallel`) runs each named command sequentially in sorted name order.
    public static func runIfPresent(
        property: String,
        command: LifecycleCommand?,
        containerId: String,
        config: ResolvedDevContainerConfig,
        runtime: AppleContainerRuntime,
        failurePolicy: FailurePolicy
    ) throws {
        guard let command else { return }

        switch command {
        case .shell, .argv:
            try runLeaf(
                property: property,
                command: command,
                containerId: containerId,
                config: config,
                runtime: runtime,
                failurePolicy: failurePolicy
            )
        case .parallel(let named):
            for entry in named {
                try runLeaf(
                    property: "\(property) (\(entry.name))",
                    command: entry.command,
                    containerId: containerId,
                    config: config,
                    runtime: runtime,
                    failurePolicy: failurePolicy
                )
            }
        }
    }

    private static func runLeaf(
        property: String,
        command: LifecycleCommand,
        containerId: String,
        config: ResolvedDevContainerConfig,
        runtime: AppleContainerRuntime,
        failurePolicy: FailurePolicy
    ) throws {
        StatusPrinter.status("Running", item: property)
        // Stream hook logs live (teed to host stderr) so long postCreate/etc scripts do not
        // look stuck. Capture is retained for failure diagnostics; QUIET only silences status.
        let execResult = try runtime.exec(
            nameOrId: containerId,
            command: command.execArguments,
            user: config.connectionUser,
            workdir: config.workspaceFolder,
            env: config.containerEnv,
            streamOutput: true
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

    /// True when config and/or feature postAttach hooks are present.
    public static func hasPostAttach(_ config: ResolvedDevContainerConfig) -> Bool {
        config.postAttachCommand != nil || !config.featurePostAttachCommands.isEmpty
    }

    /// Emit one-time postAttach skip status when the property is set (config or feature)
    /// and there is no CLI attach hook (`--vscode` absent).
    public static func emitPostAttachSkipIfNeeded(config: ResolvedDevContainerConfig) {
        guard hasPostAttach(config) else { return }
        StatusPrinter.status("postAttach skipped", item: "(no attach hook)")
    }

    /// Skip when `--vscode` was set but open soft-failed/skipped and postAttach is present.
    public static func emitPostAttachSkipOpenDidNotSucceedIfNeeded(config: ResolvedDevContainerConfig) {
        guard hasPostAttach(config) else { return }
        StatusPrinter.status("postAttach skipped", item: "(attach open did not succeed)")
    }

    /// Run config `postAttachCommand` then feature postAttach hooks via exec.
    /// Failure policy: keep container (already up; VS Code may already be opening).
    public static func runPostAttach(
        containerId: String,
        config: ResolvedDevContainerConfig,
        runtime: AppleContainerRuntime
    ) throws {
        try runIfPresent(
            property: "postAttachCommand",
            command: config.postAttachCommand,
            containerId: containerId,
            config: config,
            runtime: runtime,
            failurePolicy: .failKeepContainer
        )
        for (index, extra) in config.featurePostAttachCommands.enumerated() {
            let label = config.featurePostAttachCommands.count == 1
                ? "postAttachCommand (feature)"
                : "postAttachCommand (feature \(index + 1))"
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

    /// Outcome-aware postAttach gate after the open attempt (or no-op when not requested).
    ///
    /// Callers that apply vscode extensions MUST run extensions apply **before** this gate
    /// on open success. This gate never runs customizations apply and never uses
    /// `postAttachCommand` as an apply vehicle.
    ///
    /// - `.notRequested` → skip status when any postAttach present
    /// - `.opened` → run config then feature postAttach (`failKeepContainer`)
    /// - soft-fail open → skip status explaining attach open did not succeed
    public static func applyPostAttachGate(
        openOutcome: VSCodeOpenOutcome,
        containerId: String,
        config: ResolvedDevContainerConfig,
        runtime: AppleContainerRuntime
    ) throws {
        switch openOutcome {
        case .notRequested:
            emitPostAttachSkipIfNeeded(config: config)
        case .opened:
            try runPostAttach(containerId: containerId, config: config, runtime: runtime)
        case .skippedMissingCode, .skippedEmptyFolder, .skippedMissingImage, .skippedMissingId, .launchFailed:
            emitPostAttachSkipOpenDidNotSucceedIfNeeded(config: config)
        }
    }

    private static func lifecycleError(
        property: String,
        execResult: ProcessResult
    ) -> CLIError {
        let detail = [
            execResult.stderrString.trimmingCharacters(in: .whitespacesAndNewlines),
            execResult.stdoutString.trimmingCharacters(in: .whitespacesAndNewlines)
        ].filter { !$0.isEmpty }.joined(separator: " | ")

        // Map feature-labeled / named-object properties back to base code family.
        let baseProperty: String
        if let range = property.range(of: " (") {
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
