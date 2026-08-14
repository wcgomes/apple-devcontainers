import Foundation

/// Shared lifecycle hook execution for `up` (exec + status + fail mapping).
public enum LifecycleRunner {
    public enum FailurePolicy: Sendable {
        /// Delete container before failing (create-path hooks including first-create postStart).
        case deleteContainerThenFail
        /// Fail without deleting (restart postStart).
        case failKeepContainer
    }

    /// Test seam for host `initializeCommand`. Production uses `FoundationProcessRunner`.
    nonisolated(unsafe) public static var hostProcessRunnerOverride: (any ProcessRunning)?

    /// In-container dump of the remote user's shell environment (`/proc/self/environ`).
    public static let userEnvProbeScript = "cat /proc/self/environ"

    /// Host-only `initializeCommand`. No-op when the command is absent. Skip + warn when
    /// the caller reports no usable host workspace. Never delete-on-fail.
    public static func runInitializeCommand(
        config: ResolvedDevContainerConfig?,
        hostWorkspace: String?,
        fileManager: FileManager = .default
    ) throws {
        guard let command = config?.initializeCommand else { return }
        guard let cwd = usableHostWorkspace(hostWorkspace, fileManager: fileManager) else {
            StatusPrinter.warning("initializeCommand cannot run: no usable host workspace")
            return
        }
        try runHostIfPresent(
            property: "initializeCommand",
            command: command,
            currentDirectory: cwd
        )
    }

    /// Directory the host command may use as cwd, or nil when the path is missing / not a dir / volume URI.
    public static func usableHostWorkspace(
        _ path: String?,
        fileManager: FileManager = .default
    ) -> String? {
        guard let path else { return nil }
        let trimmed = path.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, !trimmed.hasPrefix("volume://") else { return nil }
        var isDir: ObjCBool = false
        guard fileManager.fileExists(atPath: trimmed, isDirectory: &isDir), isDir.boolValue else {
            return nil
        }
        return (trimmed as NSString).standardizingPath
    }

    /// Run a single lifecycle command if present. No-op when `command` is nil.
    /// Object-form (`.parallel`) runs named entries concurrently; the stage succeeds
    /// only if every entry exits 0. Host `initializeCommand` uses this same policy.
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
            try runParallel(
                property: property,
                named: named,
                containerId: containerId,
                config: config,
                runtime: runtime,
                failurePolicy: failurePolicy
            )
        }
    }

    /// Concurrent object-map stage. Leaves keep string/`argv` invocation unchanged.
    private static func runParallel(
        property: String,
        named: [NamedLifecycleCommand],
        containerId: String,
        config: ResolvedDevContainerConfig,
        runtime: AppleContainerRuntime,
        failurePolicy: FailurePolicy
    ) throws {
        final class ParallelState: @unchecked Sendable {
            let lock = NSLock()
            var errors: [String: Error] = [:]
            let property: String
            let containerId: String
            let config: ResolvedDevContainerConfig
            let runtime: AppleContainerRuntime

            init(
                property: String,
                containerId: String,
                config: ResolvedDevContainerConfig,
                runtime: AppleContainerRuntime
            ) {
                self.property = property
                self.containerId = containerId
                self.config = config
                self.runtime = runtime
            }

            func run(_ entry: NamedLifecycleCommand) {
                do {
                    try LifecycleRunner.runLeaf(
                        property: "\(property) (\(entry.name))",
                        command: entry.command,
                        containerId: containerId,
                        config: config,
                        runtime: runtime,
                        failurePolicy: .failKeepContainer
                    )
                } catch {
                    lock.lock()
                    if errors[entry.name] == nil {
                        errors[entry.name] = error
                    }
                    lock.unlock()
                }
            }
        }

        let state = ParallelState(
            property: property,
            containerId: containerId,
            config: config,
            runtime: runtime
        )
        let group = DispatchGroup()
        for entry in named {
            group.enter()
            DispatchQueue.global(qos: .userInitiated).async {
                state.run(entry)
                group.leave()
            }
        }
        group.wait()

        if let failed = named.first(where: { state.errors[$0.name] != nil }),
           let error = state.errors[failed.name] {
            if failurePolicy == .deleteContainerThenFail {
                try? runtime.delete(nameOrId: containerId, force: true)
            }
            throw error
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
        try runCreatePathThroughWaitFor(
            containerId: containerId,
            config: config,
            runtime: runtime
        )
        try runCreatePathAfterWaitFor(
            containerId: containerId,
            config: config,
            runtime: runtime
        )
    }

    /// In-container create-path stages through `waitFor` inclusive.
    /// Host `initializeCommand` is already done before this runs.
    public static func runCreatePathThroughWaitFor(
        containerId: String,
        config: ResolvedDevContainerConfig,
        runtime: AppleContainerRuntime
    ) throws {
        try runCreatePathStages(
            containerId: containerId,
            config: config,
            runtime: runtime,
            fromIndex: 0,
            throughIndex: config.waitFor.createPathInclusiveIndex
        )
    }

    /// Remaining create-path stages after `waitFor`. First-create `postStart`
    /// still starts after `postCreate` even when Ready already fired.
    public static func runCreatePathAfterWaitFor(
        containerId: String,
        config: ResolvedDevContainerConfig,
        runtime: AppleContainerRuntime
    ) throws {
        try runCreatePathStages(
            containerId: containerId,
            config: config,
            runtime: runtime,
            fromIndex: config.waitFor.createPathInclusiveIndex + 1,
            throughIndex: 3
        )
    }

    /// Probe the remote connection user's shell and merge into `config.containerEnv`.
    /// `none` is a no-op. Config `containerEnv` wins on key overlap. Never deletes.
    public static func applyUserEnvProbe(
        containerId: String,
        config: inout ResolvedDevContainerConfig,
        runtime: AppleContainerRuntime
    ) throws {
        guard let flags = config.userEnvProbe.shellDashOptions else { return }
        StatusPrinter.status("Probing user environment", item: config.userEnvProbe.rawValue)
        let result: ProcessResult
        do {
            result = try runtime.exec(
                nameOrId: containerId,
                command: ["sh", flags, userEnvProbeScript],
                user: config.connectionUser,
                workdir: config.workspaceFolder,
                env: [:],
                streamOutput: false
            )
        } catch let err as CLIError {
            throw userEnvProbeError(
                message: "userEnvProbe failed: \(err.message)",
                hint: err.hint
            )
        }
        guard result.succeeded else {
            throw userEnvProbeError(
                message: "userEnvProbe failed with exit \(result.exitCode)"
                    + probeDetailSuffix(result),
                hint: "Fix the remote user shell environment or set userEnvProbe to none"
            )
        }
        var merged = parseProbedEnviron(result.stdout)
        for (key, value) in config.containerEnv {
            merged[key] = value
        }
        config.containerEnv = merged
    }

    /// Parse null-separated `/proc/self/environ` or newline-separated `KEY=VALUE` lines.
    public static func parseProbedEnviron(_ data: Data) -> [String: String] {
        let text = String(data: data, encoding: .utf8) ?? String(decoding: data, as: UTF8.self)
        let records: [String]
        if text.contains("\0") {
            records = text.split(separator: "\0", omittingEmptySubsequences: true).map(String.init)
        } else {
            records = text.split(whereSeparator: { $0 == "\n" || $0 == "\r" }).map(String.init)
        }
        var env: [String: String] = [:]
        for record in records {
            guard let eq = record.firstIndex(of: "=") else { continue }
            let key = String(record[..<eq])
            guard !key.isEmpty else { continue }
            env[key] = String(record[record.index(after: eq)...])
        }
        return env
    }

    /// Resume: create-path `waitFor` is already satisfied. Hold Ready only when
    /// this invocation must wait for `postStartCommand`.
    public static func resumeShouldWaitForPostStart(_ waitFor: WaitFor) -> Bool {
        waitFor == .postStartCommand
    }

    private static func createPathStages(
        config: ResolvedDevContainerConfig
    ) -> [(String, LifecycleCommand?, [LifecycleCommand])] {
        [
            ("onCreateCommand", config.onCreateCommand, config.featureOnCreateCommands),
            ("updateContentCommand", config.updateContentCommand, config.featureUpdateContentCommands),
            ("postCreateCommand", config.postCreateCommand, config.featurePostCreateCommands),
            ("postStartCommand", config.postStartCommand, config.featurePostStartCommands)
        ]
    }

    private static func runCreatePathStages(
        containerId: String,
        config: ResolvedDevContainerConfig,
        runtime: AppleContainerRuntime,
        fromIndex: Int,
        throughIndex: Int
    ) throws {
        let stages = createPathStages(config: config)
        guard fromIndex <= throughIndex else { return }
        let lower = max(fromIndex, 0)
        let upper = min(throughIndex, stages.count - 1)
        guard lower <= upper else { return }
        var config = config
        if stages[lower...upper].contains(where: { $0.1 != nil || !$0.2.isEmpty }) {
            try applyUserEnvProbe(containerId: containerId, config: &config, runtime: runtime)
        }
        for index in lower...upper {
            let (property, primary, extras) = stages[index]
            try runIfPresent(
                property: property,
                command: primary,
                containerId: containerId,
                config: config,
                runtime: runtime,
                failurePolicy: .deleteContainerThenFail
            )
            for (extraIndex, extra) in extras.enumerated() {
                let label = extras.count == 1
                    ? "\(property) (feature)"
                    : "\(property) (feature \(extraIndex + 1))"
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
        var config = config
        if config.postStartCommand != nil || !config.featurePostStartCommands.isEmpty {
            try applyUserEnvProbe(containerId: containerId, config: &config, runtime: runtime)
        }
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
    /// and already-running `start` had no successful attach open.
    public static func emitPostAttachSkipIfNeeded(config: ResolvedDevContainerConfig) {
        guard hasPostAttach(config) else { return }
        StatusPrinter.status("postAttach skipped", item: "(no attach hook)")
    }

    /// Skip when already-running `start --vscode` open soft-failed/skipped and postAttach is present.
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
        var config = config
        if hasPostAttach(config) {
            try applyUserEnvProbe(containerId: containerId, config: &config, runtime: runtime)
        }
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

    /// Whether this invocation is itself a CLI attach (run postAttach) or an
    /// already-running `start` (run only after successful `--vscode` open).
    public enum PostAttachKind: Sendable {
        /// `up` / `clone` / `rebuild` / real `start` — run after waitFor.
        /// `--vscode` open success or soft-fail MUST NOT skip.
        case cliAttach
        /// Already-running `start` — run only after successful `--vscode` open.
        case alreadyRunning
    }

    /// Outcome-aware postAttach gate after the open attempt (or no-op when not requested).
    ///
    /// Callers that apply vscode extensions MUST run extensions apply **before** this gate
    /// on open success. This gate never runs customizations apply and never uses
    /// `postAttachCommand` as an apply vehicle.
    ///
    /// CLI-attach (`.cliAttach`): always run config then feature postAttach (`failKeepContainer`).
    /// Already-running (`.alreadyRunning`):
    /// - `.notRequested` → skip status when any postAttach present
    /// - `.opened` → run config then feature postAttach (`failKeepContainer`)
    /// - soft-fail open → skip status explaining attach open did not succeed
    public static func applyPostAttachGate(
        openOutcome: VSCodeOpenOutcome,
        kind: PostAttachKind,
        containerId: String,
        config: ResolvedDevContainerConfig,
        runtime: AppleContainerRuntime
    ) throws {
        switch kind {
        case .cliAttach:
            try runPostAttach(containerId: containerId, config: config, runtime: runtime)
        case .alreadyRunning:
            switch openOutcome {
            case .notRequested:
                emitPostAttachSkipIfNeeded(config: config)
            case .opened:
                try runPostAttach(containerId: containerId, config: config, runtime: runtime)
            case .skippedMissingCode, .skippedEmptyFolder, .skippedMissingImage, .skippedMissingId, .launchFailed:
                emitPostAttachSkipOpenDidNotSucceedIfNeeded(config: config)
            }
        }
    }

    private static func hostProcessRunner() -> any ProcessRunning {
        hostProcessRunnerOverride ?? FoundationProcessRunner()
    }

    private static func runHostIfPresent(
        property: String,
        command: LifecycleCommand,
        currentDirectory: String
    ) throws {
        switch command {
        case .shell, .argv:
            try runHostLeaf(
                property: property,
                command: command,
                currentDirectory: currentDirectory
            )
        case .parallel(let named):
            try runHostParallel(
                property: property,
                named: named,
                currentDirectory: currentDirectory
            )
        }
    }

    private static func runHostParallel(
        property: String,
        named: [NamedLifecycleCommand],
        currentDirectory: String
    ) throws {
        final class HostParallelState: @unchecked Sendable {
            let lock = NSLock()
            var errors: [String: Error] = [:]
            let property: String
            let currentDirectory: String

            init(property: String, currentDirectory: String) {
                self.property = property
                self.currentDirectory = currentDirectory
            }

            func run(_ entry: NamedLifecycleCommand) {
                do {
                    try LifecycleRunner.runHostLeaf(
                        property: "\(property) (\(entry.name))",
                        command: entry.command,
                        currentDirectory: currentDirectory
                    )
                } catch {
                    lock.lock()
                    if errors[entry.name] == nil {
                        errors[entry.name] = error
                    }
                    lock.unlock()
                }
            }
        }

        let state = HostParallelState(property: property, currentDirectory: currentDirectory)
        let group = DispatchGroup()
        for entry in named {
            group.enter()
            DispatchQueue.global(qos: .userInitiated).async {
                state.run(entry)
                group.leave()
            }
        }
        group.wait()

        if let failed = named.first(where: { state.errors[$0.name] != nil }),
           let error = state.errors[failed.name] {
            throw error
        }
    }

    private static func runHostLeaf(
        property: String,
        command: LifecycleCommand,
        currentDirectory: String
    ) throws {
        StatusPrinter.status("Running", item: property)
        let invocation = hostInvocation(command)
        let runner = hostProcessRunner()
        let result: ProcessResult
        if let streaming = runner as? any StreamTeeingProcessRunning {
            result = try streaming.run(
                executable: invocation.executable,
                arguments: invocation.arguments,
                environment: nil,
                currentDirectory: currentDirectory,
                stdinData: nil,
                streamStderr: true,
                teeStdoutToStderr: true
            )
        } else {
            result = try runner.run(
                executable: invocation.executable,
                arguments: invocation.arguments,
                environment: nil,
                currentDirectory: currentDirectory
            )
        }
        guard result.succeeded else {
            throw lifecycleError(property: property, execResult: result, isHost: true)
        }
    }

    private static func hostInvocation(
        _ command: LifecycleCommand
    ) -> (executable: String, arguments: [String]) {
        let argv = command.execArguments
        guard let first = argv.first else {
            return ("/bin/sh", ["-c", ":"])
        }
        if first.contains("/") {
            return (first, Array(argv.dropFirst()))
        }
        return ("/usr/bin/env", argv)
    }

    private static func lifecycleError(
        property: String,
        execResult: ProcessResult,
        isHost: Bool = false
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

        let hint: String
        if isHost || baseProperty == "initializeCommand" {
            hint = "Fix the \(baseProperty) and re-run"
        } else {
            hint = "Fix the \(baseProperty) or exec into the container to debug"
        }

        return CLIError(
            code: code,
            property: property,
            message: "\(property) failed with exit \(execResult.exitCode)"
                + (detail.isEmpty ? "" : ": \(detail)"),
            hint: hint
        )
    }

    private static func probeDetailSuffix(_ result: ProcessResult) -> String {
        let detail = [
            result.stderrString.trimmingCharacters(in: .whitespacesAndNewlines),
            result.stdoutString.trimmingCharacters(in: .whitespacesAndNewlines)
        ].filter { !$0.isEmpty }.joined(separator: " | ")
        return detail.isEmpty ? "" : ": \(detail)"
    }

    private static func userEnvProbeError(message: String, hint: String?) -> CLIError {
        CLIError(
            code: CLIErrorCode.lifecycleFailed,
            property: "userEnvProbe",
            message: message,
            hint: hint ?? "Fix the remote user shell environment or set userEnvProbe to none"
        )
    }
}
