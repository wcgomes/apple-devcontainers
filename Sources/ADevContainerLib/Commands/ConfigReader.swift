import Foundation

/// Reading posture for the shared dual-mode config read.
///
/// - `strict`: any insufficient/missing input throws a structured `config_not_found`
///   (or `config_parse` for JSONC/admission failures) — used by `rebuild` before any
///   destructive step.
/// - `bestEffort`: the same misses return nil ("postAttach absent" semantics used by
///   `PostAttachConfigLoader`); parse errors still propagate (unchanged behavior).
public enum ConfigReaderMode: Sendable {
    case strict
    case bestEffort
}

/// Single authoritative dual-mode reader for workspace devcontainer config from
/// managed-container labels (bind: host file; volume: exec `cat` → temp file).
///
/// `rebuild` and `PostAttachConfigLoader` share this implementation so label parsing,
/// temp-file handling, and basename rules can never drift.
public enum ConfigReader {
    /// Strictness-aware read. Returns nil only in best-effort mode for the
    /// missing-input family (missing/empty labels, missing host file, `cat` failure,
    /// empty config text). Missing-input in strict mode throws `config_not_found`.
    /// JSONC parse/admission failures propagate in both modes (`config_parse` etc.).
    public static func read(
        labels: [String: String],
        containerId: String,
        runtime: AppleContainerRuntime,
        localEnv: [String: String] = ProcessInfo.processInfo.environment,
        fileManager: FileManager = .default,
        mode: ConfigReaderMode = .strict
    ) throws -> ResolvedDevContainerConfig? {
        do {
            return try readOnce(
                labels: labels,
                containerId: containerId,
                runtime: runtime,
                localEnv: localEnv,
                fileManager: fileManager
            )
        } catch let miss as ConfigReaderMiss {
            switch mode {
            case .strict:
                throw miss.error
            case .bestEffort:
                return nil
            }
        }
    }

    // MARK: - Dispatch on stamped workspace mode

    private static func readOnce(
        labels: [String: String],
        containerId: String,
        runtime: AppleContainerRuntime,
        localEnv: [String: String],
        fileManager: FileManager
    ) throws -> ResolvedDevContainerConfig? {
        let mode = labels[ContainerIdentity.labelWorkspaceMode]
            ?? ContainerIdentity.workspaceModeBind
        if mode == ContainerIdentity.workspaceModeVolume {
            return try readVolume(
                labels: labels,
                containerId: containerId,
                runtime: runtime,
                fileManager: fileManager
            )
        }
        return try readBind(
            labels: labels,
            localEnv: localEnv,
            fileManager: fileManager
        )
    }

    // MARK: - Bind mode

    private static func readBind(
        labels: [String: String],
        localEnv: [String: String],
        fileManager: FileManager
    ) throws -> ResolvedDevContainerConfig? {
        let localFolder = labels[ContainerIdentity.labelLocalFolder]?
            .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        let configFile = labels[ContainerIdentity.labelConfigFile]?
            .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        guard !localFolder.isEmpty, !configFile.isEmpty else {
            throw ConfigReaderMiss(error: notFound(
                "the container is missing \(ContainerIdentity.labelLocalFolder) or \(ContainerIdentity.labelConfigFile) labels",
                hint: "Recreate the container with 'adevcontainer up' to restore the stamped labels"
            ))
        }
        guard fileManager.fileExists(atPath: configFile) else {
            throw ConfigReaderMiss(error: notFound(
                "devcontainer config file not found at \(configFile)",
                hint: "Fix the stamped devcontainer.config_file label or recreate the container with 'adevcontainer up'"
            ))
        }

        let resolved = try ConfigResolver.resolve(
            workspacePath: localFolder,
            configPath: configFile,
            localEnv: localEnv,
            fileManager: fileManager
        )
        return resolved.config
    }

    // MARK: - Volume mode

    private static func readVolume(
        labels: [String: String],
        containerId: String,
        runtime: AppleContainerRuntime,
        fileManager: FileManager
    ) throws -> ResolvedDevContainerConfig? {
        let configRel = labels[ContainerIdentity.labelConfigFile]?
            .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        guard !configRel.isEmpty else {
            throw ConfigReaderMiss(error: notFound(
                "the container is missing the \(ContainerIdentity.labelConfigFile) label (volume mode)",
                hint: "Recreate the container with 'adevcontainer clone <git-url>' to restore the stamped labels"
            ))
        }

        let stampedFolder = labels[ContainerIdentity.labelWorkspaceFolder]?
            .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        let workspace = !stampedFolder.isEmpty ? stampedFolder : "/workspaces"
        let pathInContainer: String
        if configRel.hasPrefix("/") {
            pathInContainer = configRel
        } else {
            pathInContainer = (workspace as NSString).appendingPathComponent(configRel)
        }

        let result = try runtime.exec(
            nameOrId: containerId,
            command: ["cat", pathInContainer],
            user: nil,
            workdir: nil,
            env: [:]
        )
        guard result.succeeded else {
            throw ConfigReaderMiss(error: notFound(
                "failed to read devcontainer config in container (cat \(pathInContainer) exited \(result.exitCode))",
                hint: "The container must be startable and the config file must exist inside it"
            ))
        }
        let text = result.stdoutString
        guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw ConfigReaderMiss(error: notFound(
                "devcontainer config is empty at \(pathInContainer)",
                hint: "Put the devcontainer.json inside the workspace volume before rebuilding"
            ))
        }

        // Write to a temp file so ConfigResolver/JSONCParser can load it.
        // Temp root uses FileManager.default (matches the pre-existing loader behavior).
        let tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("adev-postattach-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        defer {
            do {
                try FileManager.default.removeItem(at: tempDir)
            } catch {
                StatusPrinter.warning("Failed to remove temp config directory \(tempDir.path): \(error.localizedDescription)")
            }
        }

        let tempConfig = tempDir.appendingPathComponent("devcontainer.json")
        try Data(text.utf8).write(to: tempConfig)

        // Basename for default folder: last path component of workspace folder.
        let basename = (workspace as NSString).lastPathComponent
        let resolved = try ConfigResolver.resolve(
            workspacePath: tempDir.path,
            configPath: tempConfig.path,
            localEnv: [:],
            workspaceFolderBasename: basename.isEmpty ? nil : basename
        )
        return resolved.config
    }

    // MARK: - Miss model

    private static func notFound(_ detail: String, hint: String) -> CLIError {
        CLIError(
            code: CLIErrorCode.configNotFound,
            message: "Cannot read devcontainer config: \(detail)",
            hint: hint
        )
    }
}

/// Internal marker: strict mode maps it to the structured error; best-effort to nil.
private struct ConfigReaderMiss: Error {
    let error: CLIError
}