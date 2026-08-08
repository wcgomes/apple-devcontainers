import Foundation

/// Load enough resolved config to run or skip postAttach on paths that no longer hold
/// an in-memory `ResolvedDevContainerConfig` (notably bare `start`).
///
/// Bind-mode: re-resolve from host `local_folder` + `config_file` labels.
/// Volume-mode: `cat` the stamped config path inside the container workspace.
/// Feature postAttach: merge from image `devcontainer.metadata` when inspect labels expose it.
public enum PostAttachConfigLoader {
    /// Best-effort load. Returns nil when labels/paths are insufficient (caller skips postAttach
    /// without a status line — equivalent to “postAttach absent”).
    public static func load(
        labels: [String: String],
        containerId: String,
        imageRef: String?,
        runtime: AppleContainerRuntime,
        localEnv: [String: String] = ProcessInfo.processInfo.environment,
        fileManager: FileManager = .default
    ) throws -> ResolvedDevContainerConfig? {
        let mode = labels[ContainerIdentity.labelWorkspaceMode] ?? ContainerIdentity.workspaceModeBind
        let stampedFolder = labels[ContainerIdentity.labelWorkspaceFolder]?
            .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        let stampedUser = labels[ContainerIdentity.labelRemoteUser]?
            .trimmingCharacters(in: .whitespacesAndNewlines)

        var config: ResolvedDevContainerConfig?

        if mode == ContainerIdentity.workspaceModeVolume {
            config = try loadVolumeMode(
                labels: labels,
                containerId: containerId,
                runtime: runtime,
                stampedFolder: stampedFolder
            )
        } else {
            config = try loadBindMode(
                labels: labels,
                localEnv: localEnv,
                fileManager: fileManager
            )
        }

        guard var resolved = config else { return nil }

        // Prefer stamped workspace folder / user for exec workdir and remoteUser.
        if !stampedFolder.isEmpty {
            resolved.workspaceFolder = stampedFolder
        }
        if let stampedUser, !stampedUser.isEmpty {
            resolved.remoteUser = stampedUser
        }

        // Feature-contributed postAttach may live on image metadata (not re-run Features).
        mergeFeaturePostAttach(
            into: &resolved,
            labels: labels,
            imageRef: imageRef,
            runtime: runtime
        )

        return resolved
    }

    /// Merge feature postAttach from image/container `devcontainer.metadata` when present.
    /// Used by bare `start` (via `load`) and by `up` reuse/restart (no Features re-run).
    public static func mergeFeaturePostAttach(
        into config: inout ResolvedDevContainerConfig,
        labels: [String: String] = [:],
        imageRef: String?,
        runtime: AppleContainerRuntime
    ) {
        var labelSource = labels
        if labelSource[DevContainerMetadataLabel.labelKey] == nil,
           let imageRef,
           !imageRef.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
           let imageLabels = try? runtime.imageLabels(ref: imageRef)
        {
            labelSource = imageLabels
        }
        let meta = DevContainerMetadataLabel.parseContributions(from: labelSource)
        if !meta.postAttachCommands.isEmpty {
            config.featurePostAttachCommands = meta.postAttachCommands
        }
    }

    // MARK: - Bind

    private static func loadBindMode(
        labels: [String: String],
        localEnv: [String: String],
        fileManager: FileManager
    ) throws -> ResolvedDevContainerConfig? {
        let localFolder = labels[ContainerIdentity.labelLocalFolder]?
            .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        let configFile = labels[ContainerIdentity.labelConfigFile]?
            .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        guard !localFolder.isEmpty, !configFile.isEmpty else { return nil }
        guard fileManager.fileExists(atPath: configFile) else { return nil }

        let resolved = try ConfigResolver.resolve(
            workspacePath: localFolder,
            configPath: configFile,
            localEnv: localEnv,
            fileManager: fileManager
        )
        return resolved.config
    }

    // MARK: - Volume

    private static func loadVolumeMode(
        labels: [String: String],
        containerId: String,
        runtime: AppleContainerRuntime,
        stampedFolder: String
    ) throws -> ResolvedDevContainerConfig? {
        let configRel = labels[ContainerIdentity.labelConfigFile]?
            .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        guard !configRel.isEmpty else { return nil }

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
        guard result.succeeded else { return nil }
        let text = result.stdoutString
        guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return nil }

        // Write to a temp file so ConfigResolver/JSONCParser can load it.
        let tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("adev-postattach-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tempDir) }

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
}
