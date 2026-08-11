import Foundation

public struct RecoveryEditorSpec: Equatable, Sendable {
    public let executable: String
    public let arguments: [String]
    public let source: String

    public init(executable: String, arguments: [String] = [], source: String) {
        self.executable = executable
        self.arguments = arguments
        self.source = source
    }

    public func commandArguments(for filePath: String) -> [String] {
        arguments + [filePath]
    }
}

public enum RecoveryEditorAttempt: Equatable, Sendable {
    case notRun
    case normalExit
    case invalidConfig(CLIError)
    case cancelled
    case noExecutable
    case launchFailed
    case failed(exitCode: Int32)

    public var cliError: CLIError? {
        switch self {
        case .notRun, .normalExit, .invalidConfig:
            return nil
        case .cancelled:
            return CLIError(
                code: CLIErrorCode.recoveryCancelled,
                message: "Recovery editing was cancelled",
                hint: "The helper and secure recovery session were retained"
            )
        case .noExecutable:
            return CLIError(
                code: CLIErrorCode.recoveryUnavailable,
                message: "No usable recovery editor was found",
                hint: "Set VISUAL or EDITOR, or install /usr/bin/nano or /usr/bin/vi"
            )
        case .launchFailed:
            return CLIError(
                code: CLIErrorCode.recoveryUnavailable,
                message: "The selected recovery editor could not be launched",
                hint: "Check the editor executable and retain the recovery session for retry"
            )
        case .failed(let exitCode):
            return CLIError(
                code: CLIErrorCode.recoveryUnavailable,
                message: "The recovery editor exited unsuccessfully (exit \(exitCode))",
                hint: "Correct the editor invocation or retain the recovery session for retry"
            )
        }
    }
}

/// Ordered, non-shell editor launcher for TTY recovery.
///
/// The editor is resolved before launch, its path and arguments are passed as separate process
/// values, and the process is awaited. The type has no prompt behavior and returns `.notRun`
/// for non-TTY/JSON callers.
public struct RecoveryEditor {
    public static let defaultFallbackEditors = ["/usr/bin/nano", "/usr/bin/vi"]

    public var environment: [String: String]
    public var runner: any ProcessRunning
    public var fallbackEditors: [String]
    public var executableChecker: (String) -> Bool

    public init(
        environment: [String: String] = ProcessInfo.processInfo.environment,
        runner: any ProcessRunning = InteractiveProcessRunner(),
        fallbackEditors: [String] = RecoveryEditor.defaultFallbackEditors,
        fileManager: FileManager = .default,
        executableChecker: ((String) -> Bool)? = nil
    ) {
        self.environment = environment
        self.runner = runner
        self.fallbackEditors = fallbackEditors
        self.executableChecker = executableChecker ?? { path in
            fileManager.isExecutableFile(atPath: path)
        }
    }

    /// Resolve the first usable candidate in the locked order.
    public func resolve() -> RecoveryEditorSpec? {
        var candidates: [(String, String)] = []
        if let visual = nonEmpty(environment["VISUAL"]) {
            candidates.append((visual, "$VISUAL"))
        }
        if let editor = nonEmpty(environment["EDITOR"]) {
            candidates.append((editor, "$EDITOR"))
        }
        candidates.append(contentsOf: fallbackEditors.map { ($0, $0) })

        for (raw, source) in candidates {
            let tokens = tokenize(raw)
            guard let first = tokens.first, !first.isEmpty,
                  let executable = resolveExecutable(first)
            else { continue }
            return RecoveryEditorSpec(
                executable: executable,
                arguments: Array(tokens.dropFirst()),
                source: source
            )
        }
        return nil
    }

    /// Resolve an editor or throw the stable structured recovery-unavailable code.
    public func requireEditor() throws -> RecoveryEditorSpec {
        guard let resolved = resolve() else {
            throw CLIError(
                code: CLIErrorCode.recoveryUnavailable,
                message: "No usable recovery editor was found",
                hint: "Set VISUAL or EDITOR, or install /usr/bin/nano or /usr/bin/vi"
            )
        }
        return resolved
    }

    /// Return the exact argv command without launching an editor. This is used by a later
    /// non-interactive output layer to provide an operator-facing edit command.
    public func command(for filePath: String) -> [String]? {
        guard let editor = resolve() else { return nil }
        return [editor.executable] + editor.commandArguments(for: filePath)
    }

    /// Run one edit attempt. A validation failure is returned distinctly so the caller can
    /// reopen the same editor; it never writes to a volume. Non-TTY and JSON calls do not even
    /// resolve or launch an editor.
    public func edit(
        filePath: String,
        isTTY: Bool,
        jsonOutput: Bool = false,
        validate: ((Data) throws -> Void)? = nil
    ) -> RecoveryEditorAttempt {
        guard isTTY, !jsonOutput else { return .notRun }
        guard let editor = resolve() else { return .noExecutable }

        let result: ProcessResult
        do {
            result = try runner.run(
                executable: editor.executable,
                arguments: editor.commandArguments(for: filePath),
                environment: nil,
                currentDirectory: nil,
                stdinData: nil
            )
        } catch {
            return .launchFailed
        }

        if result.terminationReason == .signal || result.terminationReason == .eof
            || result.exitCode == 130
            || result.exitCode == 143
        {
            return .cancelled
        }
        guard result.succeeded else {
            return .failed(exitCode: result.exitCode)
        }

        guard let validate else { return .normalExit }
        let bytes: Data
        do {
            bytes = try Data(contentsOf: URL(fileURLWithPath: filePath))
        } catch {
            return .invalidConfig(CLIError(
                code: CLIErrorCode.recoveryVerificationFailed,
                message: "The edited recovery config could not be read",
                hint: "Keep the recovery session and retry the edit"
            ))
        }
        do {
            try validate(bytes)
            return .normalExit
        } catch let error as CLIError {
            return .invalidConfig(error)
        } catch {
            return .invalidConfig(CLIError(
                code: CLIErrorCode.configParse,
                message: "The edited recovery config is invalid",
                hint: "Correct the file and save it again"
            ))
        }
    }

    private func resolveExecutable(_ value: String) -> String? {
        if value.contains("/") {
            return executableChecker(value) ? value : nil
        }
        let pathEnvironment = environment["PATH"] ?? ""
        let pathEntries = pathEnvironment.split(separator: ":", omittingEmptySubsequences: false)
        if pathEntries.isEmpty, executableChecker(value) { return value }
        for entry in pathEntries {
            let directory = entry.isEmpty ? "." : String(entry)
            let candidate = (directory as NSString).appendingPathComponent(value)
            if executableChecker(candidate) { return candidate }
        }
        return nil
    }

    private func nonEmpty(_ value: String?) -> String? {
        let trimmed = value?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return trimmed.isEmpty ? nil : trimmed
    }

    /// Small argv tokenizer for VISUAL/EDITOR values. It supports quoted paths and backslash
    /// escapes but never evaluates shell syntax or interpolates the temp path.
    private func tokenize(_ value: String) -> [String] {
        var tokens: [String] = []
        var current = ""
        var quote: Character?
        var escaped = false
        var started = false

        for character in value {
            if escaped {
                current.append(character)
                escaped = false
                started = true
                continue
            }
            if character == "\\" {
                escaped = true
                started = true
                continue
            }
            if let activeQuote = quote {
                if character == activeQuote {
                    quote = nil
                } else {
                    current.append(character)
                }
                continue
            }
            if character == "'" || character == "\"" {
                quote = character
                started = true
                continue
            }
            if character.isWhitespace {
                if started {
                    tokens.append(current)
                    current = ""
                    started = false
                }
            } else {
                current.append(character)
                started = true
            }
        }
        if escaped { current.append("\\") }
        if started { tokens.append(current) }
        return tokens
    }
}
