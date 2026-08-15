import Foundation

/// Load enough resolved config to run or skip postAttach **and** vscode customizations apply
/// on paths that no longer hold an in-memory `ResolvedDevContainerConfig` (notably bare `start`).
///
/// Bind-mode: re-resolve from host `local_folder` + `config_file` labels.
/// Volume-mode: `cat` the stamped config path inside the container workspace.
/// Feature postStart / postAttach: union container + image `devcontainer.metadata`, then remelt
/// from admitted feature packages on disk when metadata has no resume hooks.
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

        if var resolved = config {
            // Prefer stamped workspace folder / user for exec workdir and remoteUser.
            if !stampedFolder.isEmpty {
                resolved.workspaceFolder = stampedFolder
            }
            if let stampedUser, !stampedUser.isEmpty {
                resolved.remoteUser = stampedUser
            }

            // Feature-contributed postStart / postAttach may live on image metadata (not re-run Features).
            mergeFeaturePostAttach(
                into: &resolved,
                labels: labels,
                imageRef: imageRef,
                runtime: runtime
            )
            return resolved
        }

        // Config unreadable: still remelt container+image metadata into a feature-only stub
        // so resume postStart / CLI-attach postAttach survive. No vscode apply, no initialize.
        return remeltedMetadataOnlyConfig(
            labels: labels,
            imageRef: imageRef,
            runtime: runtime,
            workspaceFolder: stampedFolder,
            remoteUser: stampedUser
        )
    }

    /// Stub config from container+image metadata when the stamped config file cannot be read.
    static func remeltedMetadataOnlyConfig(
        labels: [String: String],
        imageRef: String?,
        runtime: AppleContainerRuntime,
        workspaceFolder: String,
        remoteUser: String?
    ) -> ResolvedDevContainerConfig? {
        var stub = ResolvedDevContainerConfig(
            image: imageRef ?? "",
            remoteUser: remoteUser,
            workspaceFolder: workspaceFolder.isEmpty ? "/" : workspaceFolder,
            userEnvProbe: .none
        )
        mergeFeaturePostAttach(
            into: &stub,
            labels: labels,
            imageRef: imageRef,
            runtime: runtime
        )
        if stub.featurePostStartCommands.isEmpty && stub.featurePostAttachCommands.isEmpty {
            return nil
        }
        return stub
    }

    /// Merge feature postStart and postAttach from image/container `devcontainer.metadata`
    /// when present. Used by bare `start` (via `load`) and by `up` reuse/restart (no Features re-run).
    ///
    /// Container and image labels are **unioned**: a container that inherited base-image
    /// metadata (e.g. `remoteUser` only) must not hide feature postStart on the derived image.
    /// When metadata still has no resume hooks, remelt from admitted features on disk
    /// (local package or feature cache) — the equivalent source for containers created
    /// before Features baked `devcontainer.metadata`.
    public static func mergeFeaturePostAttach(
        into config: inout ResolvedDevContainerConfig,
        labels: [String: String] = [:],
        imageRef: String?,
        runtime: AppleContainerRuntime,
        workspacePath: String? = nil
    ) {
        let fromContainer = DevContainerMetadataLabel.parseContributions(from: labels)
        var fromImage = FeatureContributions.empty
        if let imageRef,
           !imageRef.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
           let imageLabels = try? runtime.imageLabels(ref: imageRef)
        {
            fromImage = DevContainerMetadataLabel.parseContributions(from: imageLabels)
        }
        let remeltedStart = uniqueAppend(fromContainer.postStartCommands, fromImage.postStartCommands)
        let remeltedAttach = uniqueAppend(fromContainer.postAttachCommands, fromImage.postAttachCommands)
        // Union with apply-time hooks so finish remelt cannot replace-away base-image fragments.
        config.featurePostStartCommands = uniqueAppend(config.featurePostStartCommands, remeltedStart)
        config.featurePostAttachCommands = uniqueAppend(config.featurePostAttachCommands, remeltedAttach)
        remeltFromAdmittedFeatures(
            into: &config,
            workspacePath: workspacePath ?? labels[ContainerIdentity.labelLocalFolder]
        )
    }

    /// Best-effort remelt from resolved `features` without a Features rebuild or network fetch.
    /// Local path refs are read from the host workspace; OCI refs from the feature cache.
    static func remeltFromAdmittedFeatures(
        into config: inout ResolvedDevContainerConfig,
        workspacePath: String?,
        cacheRoot: String = FeatureCache.defaultRoot(),
        fileManager: FileManager = .default
    ) {
        let needsNames = config.featurePostStartCommands.contains { $0.name.isEmpty }
            || config.featurePostAttachCommands.contains { $0.name.isEmpty }
        if !config.featurePostStartCommands.isEmpty
            && !config.featurePostAttachCommands.isEmpty
            && !needsNames
        {
            return
        }
        guard !config.features.isEmpty else { return }

        let hostWorkspace = usableHostWorkspace(workspacePath)
        var orderedInput: [FeatureOrder.OrderedFeature] = []
        for feature in config.features {
            guard let metaPath = metadataPath(
                for: feature.reference,
                workspacePath: hostWorkspace,
                cacheRoot: cacheRoot,
                fileManager: fileManager
            ) else { continue }
            guard let data = try? Data(contentsOf: URL(fileURLWithPath: metaPath)),
                  let metadata = try? FeatureMetadata.parse(data: data, featureRef: feature.reference)
            else { continue }
            orderedInput.append(FeatureOrder.OrderedFeature(admitted: feature, metadata: metadata))
        }
        guard !orderedInput.isEmpty else { return }
        let ordered = (try? FeatureOrder.resolve(orderedInput)) ?? orderedInput
        guard let contrib = try? FeatureContributionMerge.collect(from: ordered) else { return }
        if config.featurePostStartCommands.isEmpty && !contrib.postStartCommands.isEmpty {
            config.featurePostStartCommands = contrib.postStartCommands
        } else {
            config.featurePostStartCommands = overlayNames(
                config.featurePostStartCommands,
                contrib.postStartCommands
            )
        }
        if config.featurePostAttachCommands.isEmpty && !contrib.postAttachCommands.isEmpty {
            config.featurePostAttachCommands = contrib.postAttachCommands
        } else {
            config.featurePostAttachCommands = overlayNames(
                config.featurePostAttachCommands,
                contrib.postAttachCommands
            )
        }
    }

    private static func overlayNames(
        _ existing: [NamedLifecycleCommand],
        _ named: [NamedLifecycleCommand]
    ) -> [NamedLifecycleCommand] {
        existing.map { entry in
            if !entry.name.isEmpty { return entry }
            guard let match = named.first(where: { $0.command == entry.command && !$0.name.isEmpty }) else {
                return entry
            }
            return NamedLifecycleCommand(name: match.name, command: entry.command)
        }
    }

    private static func uniqueAppend(
        _ first: [NamedLifecycleCommand],
        _ second: [NamedLifecycleCommand]
    ) -> [NamedLifecycleCommand] {
        var out = first
        for cmd in second {
            if let idx = out.firstIndex(where: { $0.command == cmd.command }) {
                if out[idx].name.isEmpty && !cmd.name.isEmpty {
                    out[idx] = cmd
                }
                continue
            }
            out.append(cmd)
        }
        return out
    }

    private static func usableHostWorkspace(_ path: String?) -> String? {
        guard let path else { return nil }
        let trimmed = path.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, !trimmed.hasPrefix("volume://") else { return nil }
        return trimmed
    }

    private static func metadataPath(
        for reference: String,
        workspacePath: String?,
        cacheRoot: String,
        fileManager: FileManager
    ) -> String? {
        if FeatureRef.isLocalPath(reference) {
            guard let workspacePath,
                  let source = try? LocalFeatureLoader.resolveSourcePath(
                    reference: reference,
                    workspacePath: workspacePath
                  )
            else { return nil }
            let path = (source as NSString).appendingPathComponent("devcontainer-feature.json")
            return fileManager.fileExists(atPath: path) ? path : nil
        }
        let dir = FeatureCache.directory(for: reference, cacheRoot: cacheRoot)
        let path = (dir as NSString).appendingPathComponent("devcontainer-feature.json")
        return fileManager.fileExists(atPath: path) ? path : nil
    }
}
