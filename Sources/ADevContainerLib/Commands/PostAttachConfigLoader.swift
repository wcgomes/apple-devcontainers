import Foundation

/// Load enough resolved config to run or skip postAttach **and** vscode customizations apply
/// on paths that no longer hold an in-memory `ResolvedDevContainerConfig` (notably bare `start`).
///
/// Bind-mode: re-resolve from host `local_folder` + `config_file` labels.
/// Volume-mode: `cat` the stamped config path inside the container workspace.
/// Feature postAttach: merge from image `devcontainer.metadata` when inspect labels expose it.
///
/// Resolved config retains `vscodeExtensions` / `vscodeSettingsJSON` from the config file
/// (ConfigResolver); callers use the same model for settings repair and open-gated extensions.
public enum PostAttachConfigLoader {
    /// Best-effort load. Returns nil when labels/paths are insufficient (caller skips postAttach
    /// without a status line — equivalent to “postAttach absent”).
    ///
    /// Thin wrapper over the shared `ConfigReader` (best-effort mode): the reader owns the
    /// dual-mode (bind/volume) label → host file / exec `cat` → temp file logic.
    public static func load(
        labels: [String: String],
        containerId: String,
        imageRef: String?,
        runtime: AppleContainerRuntime,
        localEnv: [String: String] = ProcessInfo.processInfo.environment,
        fileManager: FileManager = .default
    ) throws -> ResolvedDevContainerConfig? {
        let stampedFolder = labels[ContainerIdentity.labelWorkspaceFolder]?
            .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        let stampedUser = labels[ContainerIdentity.labelRemoteUser]?
            .trimmingCharacters(in: .whitespacesAndNewlines)

        let config = try ConfigReader.read(
            labels: labels,
            containerId: containerId,
            runtime: runtime,
            localEnv: localEnv,
            fileManager: fileManager,
            mode: .bestEffort
        )

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
}
