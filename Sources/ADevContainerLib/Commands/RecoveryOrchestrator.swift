import Foundation

/// Shared TTY open-editor prompt for bind and volume recovery (design: print failure → [Y/n]).
///
/// Runs only when stdin is a TTY and `--json` is absent. Named `rebuild --name` retries do not
/// use this prompt — they open the editor (volume) or run rebuild (bind) directly.
public struct RecoveryOpenEditorPrompt: Sendable {
    public static let promptText = "Open the recovery editor now? [Y/n] "

    public enum Answer: Equatable, Sendable {
        case affirmative
        case decline
    }

    public var readLine: @Sendable () -> String?
    public var writeError: @Sendable (String) -> Void

    public init(
        readLine: @escaping @Sendable () -> String?,
        writeError: @escaping @Sendable (String) -> Void = { FileHandle.standardError.write(Data($0.utf8)) }
    ) {
        self.readLine = readLine
        self.writeError = writeError
    }

    public static var `default`: RecoveryOpenEditorPrompt {
        RecoveryOpenEditorPrompt(
            readLine: { Swift.readLine(strippingNewline: true) }
        )
    }

    /// Classify one stdin line after trim. Empty / Enter → yes (default Y).
    /// First token case-insensitively `y`/`yes` → affirmative; `n`/`no`/other/EOF → decline.
    public static func classify(_ line: String?) -> Answer {
        guard let line else { return .decline }
        let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty { return .affirmative }
        let token = trimmed.split(whereSeparator: { $0.isWhitespace }).first.map(String.init) ?? ""
        switch token.lowercased() {
        case "y", "yes":
            return .affirmative
        default:
            return .decline
        }
    }

    /// Write the prompt to stderr and read one line from stdin.
    public func ask() -> Answer {
        writeError(Self.promptText)
        return Self.classify(readLine())
    }
}

/// Coordinates the recovery boundary for a failed rebuild.
///
/// Volume clone-origin recovery owns helper/session resources and never deletes volumes.
/// Bind-mode recovery opens the host stamped config path directly (no helper, no Alpine
/// preflight, no volume write). Both modes delegate the actual retry to `RebuildCommand`
/// so the normal create-path ordering remains authoritative.
public enum RecoveryOrchestrator {
    public enum Mode: Equatable, Sendable {
        case volumeHelper
        case bindHostEditor
        case none
    }

    public struct Prepared: Sendable {
        public let session: RecoveryConfigSession
        public let preparation: RecoveryHelper.Preparation

        public init(session: RecoveryConfigSession, preparation: RecoveryHelper.Preparation) {
            self.session = session
            self.preparation = preparation
        }
    }

    public struct Failure: Sendable {
        public let error: Error
        public let containerID: String?

        public init(error: Error, containerID: String? = nil) {
            self.error = error
            self.containerID = containerID
        }
    }

    /// Classify recovery mode from managed stamps after selection.
    public static func mode(labels: [String: String]) -> Mode {
        if RecoveryHelper.isEligible(labels: labels) {
            return .volumeHelper
        }
        if isBindEligible(labels: labels) {
            return .bindHostEditor
        }
        return .none
    }

    /// Managed bind-mode stamps: not volume mode, non-empty local_folder + config_file.
    public static func isBindEligible(labels: [String: String]) -> Bool {
        let managed = labels[ContainerIdentity.labelManaged]?
            .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        guard managed == ContainerIdentity.managedValue else { return false }
        let mode = labels[ContainerIdentity.labelWorkspaceMode]?
            .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        if mode == ContainerIdentity.workspaceModeVolume { return false }
        let localFolder = labels[ContainerIdentity.labelLocalFolder]?
            .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        let configFile = labels[ContainerIdentity.labelConfigFile]?
            .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return !localFolder.isEmpty && !configFile.isEmpty
    }

    /// Host stamped config path (absolute `config_file` label — same as bind ConfigReader).
    public static func hostConfigPath(labels: [String: String]) -> String? {
        guard isBindEligible(labels: labels) else { return nil }
        let configFile = labels[ContainerIdentity.labelConfigFile]?
            .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        guard !configFile.isEmpty else { return nil }
        return (configFile as NSString).standardizingPath
    }

    /// Validate host stamped path with bind-mode strict ConfigResolver rules.
    public static func validateBindHostConfig(
        labels: [String: String],
        hostConfigPath: String,
        localEnv: [String: String],
        fileManager: FileManager = .default
    ) throws {
        let localFolder = labels[ContainerIdentity.labelLocalFolder]?
            .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        guard !localFolder.isEmpty else {
            throw CLIError(
                code: CLIErrorCode.configNotFound,
                property: ContainerIdentity.labelLocalFolder,
                message: "Bind recovery is missing \(ContainerIdentity.labelLocalFolder)",
                hint: "Run 'adevcontainer up' to restore the container"
            )
        }
        guard fileManager.fileExists(atPath: hostConfigPath) else {
            throw CLIError(
                code: CLIErrorCode.configNotFound,
                property: ContainerIdentity.labelConfigFile,
                message: "devcontainer config file not found at \(hostConfigPath)",
                hint: "Restore the host stamped config path and retry"
            )
        }
        _ = try ConfigResolver.resolve(
            workspacePath: localFolder,
            configPath: hostConfigPath,
            localEnv: localEnv,
            fileManager: fileManager
        )
    }

    /// Prepare the secure session and immutable helper capability before the delete gate.
    public static func prepare(
        container: ContainerInfo,
        rawConfig: RawVolumeConfig,
        runtime: AppleContainerRuntime,
        fileManager: FileManager = .default,
        sessionID: String = UUID().uuidString.lowercased(),
        pullIfMissing: Bool = true
    ) throws -> Prepared {
        let session = try RecoveryConfigSession.capture(
            rawVolumeConfig: rawConfig,
            container: container,
            fileManager: fileManager,
            sessionID: sessionID
        )
        do {
            let preparation = try RecoveryHelper.prepare(
                for: container,
                sessionID: session.sessionID,
                runtime: runtime,
                pullIfMissing: pullIfMissing
            )
            return Prepared(session: session, preparation: preparation)
        } catch {
            try? session.cleanup()
            throw error
        }
    }

    /// Open the retained session for a marked helper. This never captures a new session and
    /// never creates a helper; it only validates the existing endpoint and prepares the pinned
    /// request needed by the ordinary rebuild delete gate.
    public static func openRetry(
        helper: ContainerInfo,
        runtime: AppleContainerRuntime,
        fileManager: FileManager = .default,
        pullIfMissing: Bool = true
    ) throws -> Prepared {
        guard RecoveryHelper.isRecoveryHelper(helper),
               let sessionID = helper.labels[RecoveryHelper.recoverySessionLabel],
               RecoveryConfigSession.isSafeSessionID(sessionID)
        else {
            throw CLIError(
                code: CLIErrorCode.recoveryUnavailable,
                message: "The selected recovery helper has no valid session marker"
            )
        }
        guard RecoveryHelper.isPinnedHelperImage(helper) else {
            throw CLIError(
                code: CLIErrorCode.recoveryUnavailable,
                message: "The retained recovery helper is not the pinned native helper image",
                hint: "Recovery requires the checked-in digest-pinned linux/arm64 helper"
            )
        }
        let directory = try RecoveryConfigSession.directoryURL(
            forSessionID: sessionID,
            fileManager: fileManager
        )
        let session = try RecoveryConfigSession.open(directoryURL: directory, fileManager: fileManager)
        do {
            try session.validateAgainstHelper(helper)
            // Named retry applies before RebuildCommand's volume auto-start. Ensure the helper
            // can exec (start stopped; bounce Apple zombie running-but-not-executing).
            try RecoveryHelper.ensureExecReady(nameOrId: helper.id, runtime: runtime)
            _ = try RecoveryHelper.preflightImage(runtime: runtime, pullIfMissing: pullIfMissing)
            try runtime.verifyVolumeAttachment(
                nameOrId: helper.id,
                volumeName: session.workspaceVolume,
                targetPath: session.workspaceFolder,
                readOnly: false
            )
            let preparation = try RecoveryHelper.prepare(
                for: helper,
                sessionID: session.sessionID,
                runtime: runtime,
                pullIfMissing: pullIfMissing
            )
            return Prepared(session: session, preparation: preparation)
        } catch {
            throw error
        }
    }

    /// Apply the retained session onto a live recovery helper before a named `rebuild` reads
    /// config. TTY (without `--json`) MUST open the editor first so the operator can fix a
    /// retained broken config (e.g. after non-TTY retention) before the destructive rebuild.
    /// Non-TTY / `--json` apply the current temp bytes directly — the operator is expected to
    /// have edited the reported temp path already.
    public static func applyNamedRetryEdit(
        prepared: Prepared,
        helperID: String,
        selectedName: String,
        runtime: AppleContainerRuntime,
        options: RebuildOptions,
        localEnv: [String: String],
        isTTY: Bool = AppleContainerConfig.stdinIsTTY(),
        editor: RecoveryEditor? = nil
    ) throws {
        let resolvedEditor = editor ?? RecoveryEditor(environment: localEnv)
        if isTTY, !options.jsonOutput {
            try editAndApplyThroughHelper(
                session: prepared.session,
                helperID: helperID,
                selectedName: selectedName,
                runtime: runtime,
                localEnv: localEnv,
                editor: resolvedEditor
            )
            return
        }
        do {
            if prepared.session.conflictHash != nil {
                try prepared.session.acknowledgeConflict(
                    helperContainerID: helperID,
                    runtime: runtime
                )
            }
            _ = try prepared.session.applyValidatedEdit(
                helperContainerID: helperID,
                runtime: runtime,
                localEnv: localEnv
            )
        } catch let error as CLIError where error.code == CLIErrorCode.recoveryConflict {
            throw conflictFailure(
                session: prepared.session,
                helperID: helperID,
                selectedName: selectedName,
                failure: error,
                environment: localEnv
            )
        }
    }

    /// Shared TTY edit → validate → atomic write/readback loop used by same-process recovery
    /// and by a later interactive named retry on a retained helper.
    private static func editAndApplyThroughHelper(
        session: RecoveryConfigSession,
        helperID: String,
        selectedName: String,
        runtime: AppleContainerRuntime,
        localEnv: [String: String],
        editor: RecoveryEditor
    ) throws {
        while true {
            if let conflictFile = session.conflictFileURL,
               let conflictHash = session.conflictHash {
                StatusPrinter.warning(
                    "Recovery conflict retained: review edited config \(shellQuote(session.tempFileURL.path)) "
                        + "against current baseline \(shellQuote(conflictFile.path)) "
                        + "(sha256 \(conflictHash)); save and exit to acknowledge before retry"
                )
            }
            StatusPrinter.status("Opening recovery editor for", item: session.tempFileURL.path)
            let attempt = editor.edit(
                filePath: session.tempFileURL.path,
                isTTY: true,
                validate: { _ in
                    _ = try session.validateEditedConfig(localEnv: localEnv)
                }
            )
            switch attempt {
            case .normalExit:
                do {
                    if session.conflictHash != nil {
                        try session.acknowledgeConflict(
                            helperContainerID: helperID,
                            runtime: runtime
                        )
                    }
                    _ = try session.applyValidatedEdit(
                        helperContainerID: helperID,
                        runtime: runtime,
                        localEnv: localEnv
                    )
                    return
                } catch let error as CLIError where error.code == CLIErrorCode.recoveryConflict {
                    // Keep the edited file and newly captured conflict artifact. The next
                    // editor pass is the operator acknowledgement boundary; no write occurs
                    // until the current baseline is stable and acknowledged.
                    continue
                }
            case .invalidConfig(let error):
                StatusPrinter.warning(error.message)
                continue
            case .cancelled:
                throw retainedError(
                    session,
                    helperID: helperID,
                    selectedName: selectedName,
                    failure: attempt.cliError!,
                    editor: editor,
                    code: CLIErrorCode.recoveryCancelled
                )
            case .noExecutable, .launchFailed, .failed:
                throw retainedError(
                    session,
                    helperID: helperID,
                    selectedName: selectedName,
                    failure: attempt.cliError!,
                    editor: editor
                )
            case .notRun:
                throw retainedError(
                    session,
                    helperID: helperID,
                    selectedName: selectedName,
                    failure: CLIError(
                        code: CLIErrorCode.recoveryUnavailable,
                        message: "Recovery editor did not run",
                        hint: "Re-run rebuild on a TTY without --json, or edit the temp file and retry"
                    ),
                    editor: editor
                )
            }
        }
    }

    /// Clean a failed replacement and fail closed unless its workspace volume is detached.
    public static func detachFailedContainer(
        containerID: String?,
        workspaceVolume: String,
        runtime: AppleContainerRuntime
    ) throws {
        if let containerID {
            if let existing = try runtime.findByName(containerID) {
                try runtime.delete(nameOrId: existing.id, force: true)
            }
        }
        try RecoveryHelper.verifyWorkspaceVolumeDetached(volumeName: workspaceVolume, runtime: runtime)
    }

    /// Clean a failed replacement container for bind recovery (no volume detachment check).
    public static func detachFailedBindContainer(
        containerID: String?,
        runtime: AppleContainerRuntime
    ) throws {
        guard let containerID, !containerID.isEmpty else { return }
        // Prefer resolved id when listed; otherwise force-delete by the given id/name
        // (start failures may leave a container that list has not yet reflected in tests,
        // and LifecycleRunner may already have removed a hook-failed container).
        if let existing = try runtime.findByName(containerID) {
            try runtime.delete(nameOrId: existing.id, force: true)
        } else {
            try? runtime.delete(nameOrId: containerID, force: true)
        }
    }

    /// Bind host-editor recovery after a hard post-delete failure.
    ///
    /// No helper, no Alpine preflight, no volume write. TTY prints structured failure then
    /// prompts before opening the host stamped path; non-TTY/`--json` returns structured
    /// host-path details and retains resume stamps for a later named `rebuild --name`.
    public static func recoverBind(
        labels: [String: String],
        failure: Failure,
        selected: ContainerInfo,
        runtime: AppleContainerRuntime,
        options: RebuildOptions,
        localEnv: [String: String],
        fileManager: FileManager = .default,
        isTTY: Bool = AppleContainerConfig.stdinIsTTY(),
        editor: RecoveryEditor? = nil,
        openEditorPrompt: RecoveryOpenEditorPrompt = .default,
        retry: () throws -> RebuildResult
    ) throws -> RebuildResult {
        guard let hostPath = hostConfigPath(labels: labels) else {
            throw CLIError(
                code: CLIErrorCode.recoveryUnavailable,
                message: "Bind recovery requires stamped local_folder and config_file",
                hint: "Run 'adevcontainer up' to restore the container"
            )
        }

        try detachFailedBindContainer(containerID: failure.containerID, runtime: runtime)

        // Retain stamps so a later named rebuild can resume without a live container.
        try? BindRecoveryResume.retain(
            container: selected,
            hostConfigPath: hostPath,
            fileManager: fileManager
        )

        let resolvedEditor = editor ?? RecoveryEditor(environment: localEnv)
        guard isTTY, !options.jsonOutput else {
            throw bindRetainedError(
                hostPath: hostPath,
                selected: selected,
                failure: failure.error,
                editor: resolvedEditor
            )
        }

        var activeFailure = failure.error
        while true {
            // Shared TTY gate: print structured failure → prompt → affirmative opens editor.
            // Invalid-config reopen (below) does NOT re-ask; hard retry re-entry does.
            let gateError = bindRetainedError(
                hostPath: hostPath,
                selected: selected,
                failure: activeFailure,
                editor: resolvedEditor
            )
            emitStructuredFailure(gateError, writeError: openEditorPrompt.writeError)
            switch openEditorPrompt.ask() {
            case .affirmative:
                break
            case .decline:
                throw bindRetainedError(
                    hostPath: hostPath,
                    selected: selected,
                    failure: activeFailure,
                    editor: resolvedEditor,
                    code: CLIErrorCode.recoveryCancelled
                )
            }

            // Editor loop: invalid config reopens without a second open-editor prompt.
            editorLoop: while true {
                StatusPrinter.status("Opening recovery editor for", item: hostPath)
                let attempt = resolvedEditor.edit(
                    filePath: hostPath,
                    isTTY: true,
                    validate: { _ in
                        try validateBindHostConfig(
                            labels: labels,
                            hostConfigPath: hostPath,
                            localEnv: localEnv,
                            fileManager: fileManager
                        )
                    }
                )
                switch attempt {
                case .normalExit:
                    break editorLoop
                case .invalidConfig(let error):
                    StatusPrinter.warning(error.message)
                    continue editorLoop
                case .cancelled:
                    throw bindRetainedError(
                        hostPath: hostPath,
                        selected: selected,
                        failure: attempt.cliError!,
                        editor: resolvedEditor,
                        code: CLIErrorCode.recoveryCancelled
                    )
                case .noExecutable, .launchFailed, .failed:
                    throw bindRetainedError(
                        hostPath: hostPath,
                        selected: selected,
                        failure: attempt.cliError!,
                        editor: resolvedEditor
                    )
                case .notRun:
                    throw bindRetainedError(
                        hostPath: hostPath,
                        selected: selected,
                        failure: CLIError(
                            code: CLIErrorCode.recoveryUnavailable,
                            message: "Recovery editor did not run",
                            hint: "Re-run rebuild on a TTY without --json, or edit the host config and retry"
                        ),
                        editor: resolvedEditor
                    )
                }
            }

            do {
                return try retry()
            } catch {
                if isPostAttachFailure(error) {
                    try? BindRecoveryResume.cleanup(name: selected.name, fileManager: fileManager)
                    throw error
                }
                if let cli = error as? CLIError, cli.property == "volumes" {
                    try? BindRecoveryResume.cleanup(name: selected.name, fileManager: fileManager)
                    throw error
                }
                guard isRetryableHardFailure(error) else {
                    throw bindRetainedError(
                        hostPath: hostPath,
                        selected: selected,
                        failure: error,
                        editor: resolvedEditor
                    )
                }
                // Retry may have left a failed new container; clean and re-enter TTY gate.
                try? detachFailedBindContainer(containerID: selected.name, runtime: runtime)
                try? detachFailedBindContainer(containerID: selected.id, runtime: runtime)
                activeFailure = error
                continue
            }
        }
    }

    /// Establish a helper after a hard post-delete failure and either run the TTY retry loop or
    /// return a retained, structured recovery error for non-interactive callers.
    ///
    /// TTY (no `--json`): print structured failure → open-editor prompt → editor loop on yes;
    /// decline/EOF retains helper+session with non-TTY-equivalent details. Named retry does not
    /// use this path (`applyNamedRetryEdit` opens the editor without the Y/n gate).
    public static func recover(
        prepared: Prepared,
        failure: Failure,
        selected: ContainerInfo,
        runtime: AppleContainerRuntime,
        options: RebuildOptions,
        localEnv: [String: String],
        fileManager: FileManager = .default,
        isTTY: Bool = AppleContainerConfig.stdinIsTTY(),
        editor: RecoveryEditor? = nil,
        openEditorPrompt: RecoveryOpenEditorPrompt = .default,
        retry: (String, RecoveryConfigSession) throws -> RebuildResult
    ) throws -> RebuildResult {
        do {
            try detachFailedContainer(
                containerID: failure.containerID,
                workspaceVolume: prepared.session.workspaceVolume,
                runtime: runtime
            )
            var helperID = try RecoveryHelper.createHelper(
                preparation: prepared.preparation,
                runtime: runtime
            )

            let resolvedEditor = editor ?? RecoveryEditor(environment: localEnv)
            guard isTTY, !options.jsonOutput else {
                throw retainedError(
                    prepared.session,
                    helperID: helperID,
                    selectedName: selected.name,
                    failure: failure.error,
                    editor: resolvedEditor
                )
            }

            var activeFailure = failure.error
            while true {
                // Shared TTY gate: print structured failure → prompt. Invalid-config reopen
                // inside editAndApplyThroughHelper does not re-ask; hard retry re-entry does.
                let gateError = retainedError(
                    prepared.session,
                    helperID: helperID,
                    selectedName: selected.name,
                    failure: activeFailure,
                    editor: resolvedEditor
                )
                emitStructuredFailure(gateError, writeError: openEditorPrompt.writeError)
                switch openEditorPrompt.ask() {
                case .affirmative:
                    break
                case .decline:
                    throw retainedError(
                        prepared.session,
                        helperID: helperID,
                        selectedName: selected.name,
                        failure: activeFailure,
                        editor: resolvedEditor,
                        code: CLIErrorCode.recoveryCancelled
                    )
                }

                // Cancellation / editor failure throw and leave helper+session for a later retry.
                try editAndApplyThroughHelper(
                    session: prepared.session,
                    helperID: helperID,
                    selectedName: selected.name,
                    runtime: runtime,
                    localEnv: localEnv,
                    editor: resolvedEditor
                )
                do {
                    return try retry(helperID, prepared.session)
                } catch {
                    let retryError = error
                    if isPostAttachFailure(error) {
                        try? prepared.session.cleanup()
                        throw error
                    }
                    if let cli = error as? CLIError, cli.property == "volumes" {
                        try? prepared.session.cleanup()
                        throw error
                    }
                    guard isRetryableHardFailure(error) else {
                        throw retainedError(
                            prepared.session,
                            helperID: helperID,
                            selectedName: selected.name,
                            failure: error,
                            editor: resolvedEditor
                        )
                    }
                    // A retry may have crossed the helper delete gate. Preserve the
                    // session and restore/retain a helper, then re-enter the TTY gate.
                    let helperExists: Bool
                    do {
                        helperExists = try runtime.findByName(helperID) != nil
                    } catch {
                        helperExists = false
                    }
                    if helperExists {
                        // The retry failed before its delete gate; the current helper is
                        // still the safe write endpoint.
                    } else {
                        do {
                            try detachFailedContainer(
                                containerID: nil,
                                workspaceVolume: prepared.session.workspaceVolume,
                                runtime: runtime
                            )
                            helperID = try RecoveryHelper.createHelper(
                                preparation: prepared.preparation,
                                runtime: runtime
                            )
                        } catch {
                            throw retainedError(
                                prepared.session,
                                helperID: helperID,
                                selectedName: selected.name,
                                failure: retryError,
                                editor: resolvedEditor,
                                helperAvailable: false
                            )
                        }
                    }
                    activeFailure = retryError
                    continue
                }
            }
        } catch let error as CLIError {
            if isPostAttachFailure(error) {
                throw error
            }
            throw sanitizedRecoveryError(error)
        } catch {
            throw CLIError(
                code: CLIErrorCode.recoveryUnavailable,
                message: "Recovery could not be established",
                hint: "The workspace and config volumes were not deleted"
            )
        }
    }

    public static func retainedFailure(
        session: RecoveryConfigSession,
        helperID: String,
        selectedName: String,
        failure: Error,
        environment: [String: String]
    ) -> CLIError {
        retainedError(
            session,
            helperID: helperID,
            selectedName: selectedName,
            failure: failure,
            editor: RecoveryEditor(environment: environment),
            code: CLIErrorCode.recoveryVerificationFailed,
            helperAvailable: false
        )
    }

    public static func conflictFailure(
        session: RecoveryConfigSession,
        helperID: String,
        selectedName: String,
        failure: Error,
        environment: [String: String]
    ) -> CLIError {
        retainedError(
            session,
            helperID: helperID,
            selectedName: selectedName,
            failure: failure,
            editor: RecoveryEditor(environment: environment),
            code: CLIErrorCode.recoveryConflict,
            helperAvailable: true
        )
    }

    public static func retainedUnavailableFailure(
        session: RecoveryConfigSession,
        helperID: String,
        selectedName: String,
        failure: Error,
        environment: [String: String],
        helperAvailable: Bool = true
    ) -> CLIError {
        retainedError(
            session,
            helperID: helperID,
            selectedName: selectedName,
            failure: failure,
            editor: RecoveryEditor(environment: environment),
            code: CLIErrorCode.recoveryUnavailable,
            helperAvailable: helperAvailable
        )
    }

    public static func finalVerificationFailure(
        session: RecoveryConfigSession,
        selectedName: String,
        failure: Error,
        environment: [String: String]
    ) -> CLIError {
        retainedError(
            session,
            helperID: "not-available",
            selectedName: selectedName,
            failure: failure,
            editor: RecoveryEditor(environment: environment),
            code: CLIErrorCode.recoveryVerificationFailed,
            helperAvailable: false
        )
    }

    private static func retainedError(
        _ session: RecoveryConfigSession,
        helperID: String,
        selectedName: String,
        failure: Error,
        editor: RecoveryEditor,
        code: String = CLIErrorCode.recoveryUnavailable,
        helperAvailable: Bool = true
    ) -> CLIError {
        let edit = editor.command(for: session.tempFileURL.path)
            .map(shellQuoteCommand)
            ?? "recovery editor unavailable"
        let retry = shellQuoteCommand(["adevcontainer", "rebuild", "--name", selectedName])
        let cleanup = helperAvailable
            ? "adevcontainer delete --name \(shellQuote(selectedName)); rm -rf -- \(shellQuote(session.directoryURL.path))"
            : "rm -rf -- \(shellQuote(session.directoryURL.path))"
        let failureKind = (failure as? CLIError)?.code ?? "runtime_failure"
        let reason: String
        if let cli = failure as? CLIError {
            // Never embed raw failure messages here — they may contain hook stdout/stderr
            // secrets. Surface code/property only; detailed verification text stays on the
            // originating CLIError when callers inspect it before wrapping.
            reason = cli.property.map { "\(failureKind) failure (\($0))" } ?? "\(failureKind) failure"
        } else {
            reason = "runtime failure"
        }
        let details = RecoveryErrorDetails(
            helperContainerID: sanitizedHelperID(helperID),
            helperContainerName: selectedName,
            helperAvailable: helperAvailable,
            sessionID: session.sessionID,
            workspaceVolume: session.workspaceVolume,
            configPath: session.configPathInContainer,
            tempFile: session.tempFileURL.path,
            conflictFile: session.conflictFileURL?.path,
            conflictHash: session.conflictHash,
            expectedHash: session.baselineHash,
            failureKind: failureKind,
            editCommand: edit,
            retryCommand: retry,
            cleanupCommand: cleanup,
            mode: "volume"
        )
        let hint: String
        if code == CLIErrorCode.recoveryConflict,
           let conflictFile = session.conflictFileURL,
           let conflictHash = session.conflictHash {
            hint = "Review conflict file \(shellQuote(conflictFile.path)) (sha256 \(conflictHash)) against the edited file, then run \(retry)"
        } else {
            hint = helperAvailable
                ? "Recovery helper \(helperID) and session \(session.sessionID) retained"
                : "No recovery helper remains; secure session \(session.sessionID) retained for inspection"
        }
        return CLIError(
            code: code,
            message: "Rebuild failed after the old container was removed: \(reason)",
            hint: hint,
            recovery: details
        )
    }

    private static func bindRetainedError(
        hostPath: String,
        selected: ContainerInfo,
        failure: Error,
        editor: RecoveryEditor,
        code: String = CLIErrorCode.recoveryUnavailable
    ) -> CLIError {
        let edit = editor.command(for: hostPath)
            .map(shellQuoteCommand)
            ?? "recovery editor unavailable"
        let retry = shellQuoteCommand(["adevcontainer", "rebuild", "--name", selected.name])
        let failureKind = (failure as? CLIError)?.code ?? "runtime_failure"
        let reason: String
        if let cli = failure as? CLIError {
            reason = cli.property.map { "\(failureKind) failure (\($0))" } ?? "\(failureKind) failure"
        } else {
            reason = "runtime failure"
        }
        let details = RecoveryErrorDetails.bindHostPath(
            containerName: selected.name,
            containerID: selected.id,
            configPath: hostPath,
            failureKind: failureKind,
            editCommand: edit,
            retryCommand: retry
        )
        let hint: String
        if code == CLIErrorCode.recoveryCancelled {
            hint = "Host config left as edited at \(shellQuote(hostPath)); run \(retry) after fixing"
        } else {
            hint = "Edit host config \(shellQuote(hostPath)), then run \(retry)"
        }
        return CLIError(
            code: code,
            message: "Rebuild failed after the old container was removed: \(reason)",
            hint: hint,
            recovery: details
        )
    }

    private static func shellQuoteCommand(_ args: [String]) -> String {
        args.map(shellQuote).joined(separator: " ")
    }

    private static func shellQuote(_ value: String) -> String {
        "'" + value.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }

    /// Print structured failure/reason on stderr before the open-editor prompt.
    /// Same human fields as non-TTY retain (message/property/hint + recovery commands).
    private static func emitStructuredFailure(
        _ error: CLIError,
        writeError: @escaping (String) -> Void
    ) {
        writeError(error.formatted() + "\n")
        guard let recovery = error.recovery else { return }
        if !recovery.configPath.isEmpty {
            writeError("  configPath: \(recovery.configPath)\n")
        }
        if !recovery.tempFile.isEmpty {
            writeError("  tempFile: \(recovery.tempFile)\n")
        }
        if let conflict = recovery.conflictFile, !conflict.isEmpty {
            writeError("  conflictFile: \(conflict)\n")
        }
        if !recovery.editCommand.isEmpty {
            writeError("  edit: \(recovery.editCommand)\n")
        }
        if !recovery.retryCommand.isEmpty {
            writeError("  retry: \(recovery.retryCommand)\n")
        }
        if !recovery.cleanupCommand.isEmpty {
            writeError("  cleanup: \(recovery.cleanupCommand)\n")
        }
    }

    private static func isRetryableHardFailure(_ error: Error) -> Bool {
        guard let cli = error as? CLIError else { return false }
        return [CLIErrorCode.runtimeFailed, CLIErrorCode.lifecycleFailed, CLIErrorCode.postCreateFailed]
            .contains(cli.code)
    }

    private static func isPostAttachFailure(_ error: Error) -> Bool {
        guard let property = (error as? CLIError)?.property else { return false }
        return property == "postAttachCommand"
            || property.hasPrefix("postAttachCommand (")
    }

    private static func sanitizedHelperID(_ helperID: String) -> String {
        ["not-created", "not-available"].contains(helperID) ? "" : helperID
    }

    private static func sanitizedRecoveryError(_ error: CLIError) -> CLIError {
        guard error.recovery == nil, error.code != CLIErrorCode.recoveryConflict else { return error }
        let phase = error.property.map { " (\($0))" } ?? ""
        return CLIError(
            code: error.code,
            property: error.property,
            message: "Recovery operation failed\(phase)",
            hint: "The recovery operation did not complete; inspect the retained recovery state"
        )
    }
}
