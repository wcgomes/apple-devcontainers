import Foundation

/// Shared bring-up recovery primitive consumed by `up`, `clone`, and `start` wiring.
///
/// Drives the "edit config and retry" loop after a bring-up failure with an editable
/// `devcontainer.json`: print the structured failure, prompt (default Y via the shared
/// `RecoveryOpenEditorPrompt`), run the caller's edit closure (which opens `RecoveryEditor`
/// and reopens on invalid content), then re-run the full bring-up path from scratch. A
/// further recoverable failure re-enters the prompt; decline/EOF throws the current failure
/// non-zero. Non-TTY / `--json` never prompts or edits and throws the original failure with
/// an edit/retry hint the caller's output layer surfaces.
public enum BringUpRecovery {
    /// Marker used by bring-up callers to distinguish failures that are eligible for the
    /// edit/retry flow from failures that must be returned normally (for example, a missing
    /// config, a failed feature build, or a post-attach failure).
    public struct EligibleFailure: Error {
        public let cause: Error
        public let resetExistingName: String?

        public init(cause: Error, resetExistingName: String? = nil) {
            self.cause = cause
            self.resetExistingName = resetExistingName
        }
    }

    /// Mark a failure from one of the recoverable bring-up stages.
    public static func eligible(
        _ error: Error,
        resetExistingName: String? = nil
    ) -> EligibleFailure {
        if let marked = error as? EligibleFailure {
            return EligibleFailure(
                cause: marked.cause,
                resetExistingName: resetExistingName ?? marked.resetExistingName
            )
        }
        return EligibleFailure(cause: error, resetExistingName: resetExistingName)
    }

    /// Edit/retry guidance a non-interactive caller surfaces in place of a prompt.
    public struct Guidance: Equatable, Sendable {
        public let configPath: String
        public let editCommand: String
        public let retryCommand: String

        public init(configPath: String, editCommand: String, retryCommand: String) {
            self.configPath = configPath
            self.editCommand = editCommand
            self.retryCommand = retryCommand
        }
    }

    public static let changeNamePromptText = "Change the name? [Y/n] "
    public static let newNamePromptText = "New name: "

    /// TTY offer for a foreign occupant: Y/n then a full-name prompt. Never opens an editor,
    /// never offers a suffix, never deletes the occupant. Decline/cancel/EOF rethrows the
    /// original name-in-use error.
    public static func runNameCollision<T>(
        failure: Error,
        guidance: Guidance,
        createName: String,
        isTTY: Bool,
        jsonOutput: Bool,
        prompt: RecoveryOpenEditorPrompt = .default,
        persistName: (String) throws -> Void,
        retry: () throws -> T
    ) throws -> T {
        let initialFailure = (failure as? EligibleFailure)?.cause ?? failure
        guard isTTY, !jsonOutput else {
            throw hintError(initialFailure, guidance)
        }

        var activeFailure = initialFailure
        var currentName = createName
        while true {
            emitNameCollisionWarning(
                name: currentName,
                failure: activeFailure,
                writeError: prompt.writeError
            )
            prompt.writeError(changeNamePromptText)
            switch RecoveryOpenEditorPrompt.classify(prompt.readLine()) {
            case .decline:
                throw activeFailure
            case .affirmative:
                break
            }

            let persisted = try readAcceptedCreateName(
                prompt: prompt,
                eofError: activeFailure
            )
            try persistName(persisted)
            currentName = persisted

            do {
                return try retry()
            } catch let next as EligibleFailure {
                let cause = next.cause
                if isNameInUse(cause) {
                    activeFailure = cause
                    if let cli = cause as? CLIError, let nextName = nameFromCollision(cli) {
                        currentName = nextName
                    }
                    continue
                }
                throw next
            } catch {
                if isNameInUse(error) {
                    activeFailure = error
                    continue
                }
                throw error
            }
        }
    }

    /// Prompt for a full create name until sanitize succeeds. Empty/invalid re-prompt.
    /// EOF throws `eofError`.
    private static func readAcceptedCreateName(
        prompt: RecoveryOpenEditorPrompt,
        eofError: Error
    ) throws -> String {
        while true {
            prompt.writeError(newNamePromptText)
            guard let raw = prompt.readLine() else { throw eofError }
            if let accepted = acceptedCreateName(raw) {
                return accepted
            }
        }
    }

    /// Sanitize a typed full name. Nil when empty after DNS-safe sanitize or longer than 63.
    public static func acceptedCreateName(_ raw: String) -> String? {
        let sanitized = ContainerIdentity.sanitizeCreateName(raw)
        guard !sanitized.isEmpty, sanitized.count <= 63 else { return nil }
        let unclipped = ContainerIdentity.sanitizeDNS(raw)
        guard unclipped.count <= 63 else { return nil }
        return sanitized
    }

    public static func isNameInUse(_ error: Error) -> Bool {
        (error as? CLIError)?.code == CLIErrorCode.containerNameInUse
            || ((error as? EligibleFailure)?.cause as? CLIError)?.code == CLIErrorCode.containerNameInUse
    }

    public static func createName(fromCollision failure: Error) -> String? {
        let cause = (failure as? EligibleFailure)?.cause ?? failure
        guard let cli = cause as? CLIError else { return nil }
        return nameFromCollision(cli)
    }

    private static func nameFromCollision(_ error: CLIError) -> String? {
        let prefix = "Container name '"
        guard error.message.hasPrefix(prefix),
              let end = error.message.range(of: "' is in use")
        else { return nil }
        let start = error.message.index(error.message.startIndex, offsetBy: prefix.count)
        return String(error.message[start..<end.lowerBound])
    }

    private static func emitNameCollisionWarning(
        name: String,
        failure: Error,
        writeError: (String) -> Void
    ) {
        writeError("warning: container name '\(name)' is in use and is not this workspace\n")
        if let cli = failure as? CLIError {
            writeError(cli.formatted() + "\n")
        }
    }

    /// Run the interactive recovery loop and return the result of the final retry.
    ///
    /// - Parameters:
    ///   - failure: the original bring-up failure (re-thrown on decline/EOF and, with a
    ///     hint, on the non-interactive path).
    ///   - guidance: config path + edit/retry commands for the non-interactive hint.
    ///   - isTTY: whether stdin is a terminal.
    ///   - jsonOutput: whether machine-readable output was requested.
    ///   - openEditorPrompt: shared prompt; only consulted in a TTY without `--json`.
    ///   - edit: opens the editor and validates, re-opening on invalid content; throws on
    ///     cancellation or editor failure.
    ///   - retry: re-runs the full bring-up path from scratch.
    public static func run<T>(
        failure: Error,
        guidance: Guidance,
        isTTY: Bool,
        jsonOutput: Bool,
        openEditorPrompt: RecoveryOpenEditorPrompt = .default,
        edit: () throws -> Void,
        retry: () throws -> T
    ) throws -> T {
        let markedFailure = failure is EligibleFailure
        let initialFailure = (failure as? EligibleFailure)?.cause ?? failure

        guard isTTY, !jsonOutput else {
            throw hintError(initialFailure, guidance)
        }

        var activeFailure = initialFailure
        while true {
            emitStructuredFailure(
                activeFailure,
                guidance: guidance,
                writeError: openEditorPrompt.writeError
            )
            switch openEditorPrompt.ask() {
            case .affirmative:
                break
            case .decline:
                throw activeFailure
            }

            try edit()

            do {
                return try retry()
            } catch {
                guard !markedFailure || error is EligibleFailure else { throw error }
                activeFailure = (error as? EligibleFailure)?.cause ?? error
            }
        }
    }

    /// Original failure plus an edit/retry hint for non-interactive callers. Preserves the
    /// original code/message/property so scripts can match on the failure that triggered
    /// recovery rather than a synthetic wrapper.
    private static func hintError(_ failure: Error, _ guidance: Guidance) -> CLIError {
        let path = shellQuote(guidance.configPath)
        let editor = guidance.editCommand.trimmingCharacters(in: .whitespacesAndNewlines)
        let editorHint = editor.isEmpty || editor == "recovery editor unavailable"
            ? ""
            : " using \(editor)"
        let editRetry = "Edit \(path)\(editorHint), then run \(guidance.retryCommand)"
        if let cli = failure as? CLIError {
            return CLIError(
                code: cli.code,
                property: cli.property,
                message: cli.message,
                hint: cli.hint.map { "\(editRetry) (\($0))" } ?? editRetry,
                recovery: cli.recovery
            )
        }
        return CLIError(
            code: CLIErrorCode.runtimeFailed,
            message: failure.localizedDescription,
            hint: editRetry
        )
    }

    /// Print the structured failure and edit/retry guidance to stderr before the prompt.
    private static func emitStructuredFailure(
        _ failure: Error,
        guidance: Guidance,
        writeError: (String) -> Void
    ) {
        let formatted: String
        if let cli = failure as? CLIError {
            formatted = cli.formatted()
        } else {
            formatted = TerminalStyle.errorPrefix + failure.localizedDescription
        }
        writeError(formatted + "\n")
        if !guidance.configPath.isEmpty {
            writeError("  configPath: \(guidance.configPath)\n")
        }
        if !guidance.editCommand.isEmpty {
            writeError("  edit: \(guidance.editCommand)\n")
        }
        if !guidance.retryCommand.isEmpty {
            writeError("  retry: \(guidance.retryCommand)\n")
        }
    }

    private static func shellQuote(_ value: String) -> String {
        "'" + value.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }
}
