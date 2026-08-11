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

/// Exact bytes and stamped location of a volume-mode config read.
///
/// `ConfigReader.read` intentionally returns only the resolved model. Recovery needs the
/// bytes that crossed the runtime boundary before the reader's parser temp file is removed,
/// so this value is the narrow retention seam for that use case.
public struct RawVolumeConfig: Equatable, Sendable {
    public let bytes: Data
    public let pathInContainer: String
    public let workspaceFolder: String
    public let workspaceFolderBasename: String?

    public init(
        bytes: Data,
        pathInContainer: String,
        workspaceFolder: String,
        workspaceFolderBasename: String?
    ) {
        self.bytes = bytes
        self.pathInContainer = pathInContainer
        self.workspaceFolder = workspaceFolder
        self.workspaceFolderBasename = workspaceFolderBasename
    }
}

/// Stamped volume location used by both the strict reader and recovery validation.
public struct VolumeConfigLocation: Equatable, Sendable {
    public let pathInContainer: String
    public let workspaceFolder: String
    public let workspaceFolderBasename: String?

    public init(
        pathInContainer: String,
        workspaceFolder: String,
        workspaceFolderBasename: String?
    ) {
        self.pathInContainer = pathInContainer
        self.workspaceFolder = workspaceFolder
        self.workspaceFolderBasename = workspaceFolderBasename
    }
}

/// A single strict volume read carrying both the resolved model and the exact runtime bytes.
public struct ResolvedVolumeConfigRead: Equatable {
    public let config: ResolvedDevContainerConfig
    public let raw: RawVolumeConfig

    public init(config: ResolvedDevContainerConfig, raw: RawVolumeConfig) {
        self.config = config
        self.raw = raw
    }
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

    /// Read the exact raw bytes of the stamped volume-mode config without creating a parser
    /// temp file. This is the safe capture seam used before a destructive rebuild boundary.
    /// Missing-input failures use the same strict `config_not_found` mapping as `read`.
    public static func readVolumeRaw(
        labels: [String: String],
        containerId: String,
        runtime: AppleContainerRuntime,
        fileManager: FileManager = .default
    ) throws -> RawVolumeConfig {
        do {
            return try readVolumeRawOnce(
                labels: labels,
                containerId: containerId,
                runtime: runtime,
                fileManager: fileManager
            )
        } catch let miss as ConfigReaderMiss {
            throw miss.error
        }
    }

    /// Descriptive alias for callers preparing a recovery session before a delete gate.
    public static func retainRawVolumeConfig(
        labels: [String: String],
        containerId: String,
        runtime: AppleContainerRuntime,
        fileManager: FileManager = .default
    ) throws -> RawVolumeConfig {
        try readVolumeRaw(
            labels: labels,
            containerId: containerId,
            runtime: runtime,
            fileManager: fileManager
        )
    }

    /// Read and resolve the volume config once while retaining the exact same bytes for a
    /// recovery session. This avoids a second `cat` race between strict validation and capture.
    public static func readVolumeWithRaw(
        labels: [String: String],
        containerId: String,
        runtime: AppleContainerRuntime,
        fileManager: FileManager = .default
    ) throws -> ResolvedVolumeConfigRead {
        do {
            let raw = try readVolumeRawOnce(
                labels: labels,
                containerId: containerId,
                runtime: runtime,
                fileManager: fileManager
            )
            let config = try resolveRawVolume(
                raw: raw,
                labels: labels,
                fileManager: fileManager
            )
            return ResolvedVolumeConfigRead(config: config, raw: raw)
        } catch let miss as ConfigReaderMiss {
            throw miss.error
        }
    }

    /// Resolve a config file retained from a volume read with the same basename override used
    /// by the strict volume reader. The private recovery directory is deliberately not used as
    /// the basename source.
    public static func resolveVolumeFile(
        at configPath: String,
        labels: [String: String],
        localEnv: [String: String] = [:],
        fileManager: FileManager = .default
    ) throws -> ResolvedWorkspace {
        guard labels[ContainerIdentity.labelWorkspaceMode] == ContainerIdentity.workspaceModeVolume else {
            throw notFound(
                "recovery config validation requires a volume-mode stamp",
                hint: "Use the stamped volume-mode workspace config"
            )
        }
        let location = try volumeConfigLocation(labels: labels)
        let workspacePath = (configPath as NSString).deletingLastPathComponent
        return try ConfigResolver.resolve(
            workspacePath: workspacePath.isEmpty ? "." : workspacePath,
            configPath: configPath,
            localEnv: localEnv,
            fileManager: fileManager,
            workspaceFolderBasename: location.workspaceFolderBasename
        )
    }

    /// Compute the stamped in-volume config path and basename without reading the file.
    public static func volumeConfigLocation(
        labels: [String: String]
    ) throws -> VolumeConfigLocation {
        let configRel = labels[ContainerIdentity.labelConfigFile]?
            .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        guard !configRel.isEmpty else {
            throw notFound(
                "the container is missing the \(ContainerIdentity.labelConfigFile) label (volume mode)",
                hint: "Recreate the container with 'adevcontainer clone <git-url>' to restore the stamped labels"
            )
        }

        let stampedFolder = labels[ContainerIdentity.labelWorkspaceFolder]?
            .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        let workspaceValue = stampedFolder.isEmpty ? "/workspaces" : stampedFolder
        let workspace = (workspaceValue as NSString).standardizingPath
        guard workspace.hasPrefix("/"), workspace != "/" else {
            throw notFound(
                "effective workspace folder is not an absolute non-root path",
                hint: "Stamp an absolute workspace folder before using volume recovery"
            )
        }
        let candidate: String
        if configRel.hasPrefix("/") {
            candidate = configRel
        } else {
            candidate = (workspace as NSString).appendingPathComponent(configRel)
        }
        let pathInContainer = (candidate as NSString).standardizingPath
        let workspacePrefix = workspace.hasSuffix("/") ? workspace : "\(workspace)/"
        guard pathInContainer.hasPrefix(workspacePrefix) else {
            throw notFound(
                "stamped config path \(configRel) is outside effective workspace folder \(workspace)",
                hint: "Keep devcontainer.config_file beneath devcontainer.workspace_folder"
            )
        }
        let basename = (workspace as NSString).lastPathComponent
        return VolumeConfigLocation(
            pathInContainer: pathInContainer,
            workspaceFolder: workspace,
            workspaceFolderBasename: basename.isEmpty ? nil : basename
        )
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
        let raw = try readVolumeRawOnce(
            labels: labels,
            containerId: containerId,
            runtime: runtime,
            fileManager: fileManager
        )

        return try resolveRawVolume(raw: raw, labels: labels, fileManager: fileManager)
    }

    private static func resolveRawVolume(
        raw: RawVolumeConfig,
        labels: [String: String],
        fileManager: FileManager
    ) throws -> ResolvedDevContainerConfig {

        // Write to a temp file so ConfigResolver/JSONCParser can load it.
        // Temp root uses FileManager.default (matches the pre-existing loader behavior).
        let tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("adev-postattach-\(UUID().uuidString)", isDirectory: true)
        do {
            try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        } catch {
            throw ConfigReaderMiss(error: notFound(
                "failed to stage stamped config for resolution",
                hint: "Ensure the invoking user can write its temporary directory"
            ))
        }
        defer {
            do {
                try FileManager.default.removeItem(at: tempDir)
            } catch {
                StatusPrinter.warning("Failed to remove temp config directory: \(error.localizedDescription)")
            }
        }

        let tempConfig = tempDir.appendingPathComponent("devcontainer.json")
        do {
            try raw.bytes.write(to: tempConfig)
        } catch {
            throw ConfigReaderMiss(error: notFound(
                "failed to stage stamped config for resolution",
                hint: "Ensure the invoking user can write its temporary directory"
            ))
        }

        let resolved = try resolveVolumeFile(
            at: tempConfig.path,
            labels: labels,
            localEnv: [:],
            fileManager: fileManager
        )
        return resolved.config
    }

    private static func readVolumeRawOnce(
        labels: [String: String],
        containerId: String,
        runtime: AppleContainerRuntime,
        fileManager: FileManager
    ) throws -> RawVolumeConfig {
        guard labels[ContainerIdentity.labelWorkspaceMode] == ContainerIdentity.workspaceModeVolume else {
            throw ConfigReaderMiss(error: notFound(
                "raw config capture requires a volume-mode stamp",
                hint: "Recovery is available only for a stamped volume-mode container"
            ))
        }
        let location: VolumeConfigLocation
        do {
            location = try volumeConfigLocation(labels: labels)
        } catch let error as CLIError {
            throw ConfigReaderMiss(error: error)
        }

        let result: ProcessResult
        do {
            result = try runtime.exec(
                nameOrId: containerId,
                command: ["cat", location.pathInContainer],
                user: nil,
                workdir: nil,
                env: [:]
            )
        } catch {
            throw ConfigReaderMiss(error: notFound(
                "failed to read stamped devcontainer config at \(location.pathInContainer)",
                hint: "The container must be startable and the stamped config must be readable"
            ))
        }
        guard result.succeeded else {
            throw ConfigReaderMiss(error: notFound(
                "failed to read devcontainer config in container (cat \(location.pathInContainer) exited \(result.exitCode))",
                hint: "The container must be startable and the config file must exist inside it"
            ))
        }

        if let text = String(data: result.stdout, encoding: .utf8),
           text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        {
            throw ConfigReaderMiss(error: notFound(
                "devcontainer config is empty at \(location.pathInContainer)",
                hint: "Put the devcontainer.json inside the workspace volume before rebuilding"
            ))
        }
        guard !result.stdout.isEmpty else {
            throw ConfigReaderMiss(error: notFound(
                "devcontainer config is empty at \(location.pathInContainer)",
                hint: "Put the devcontainer.json inside the workspace volume before rebuilding"
            ))
        }

        _ = fileManager
        return RawVolumeConfig(
            bytes: result.stdout,
            pathInContainer: location.pathInContainer,
            workspaceFolder: location.workspaceFolder,
            workspaceFolderBasename: location.workspaceFolderBasename
        )
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
