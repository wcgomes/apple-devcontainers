import Foundation

/// `adevcontainer rebuild`: force-recreate a managed container from its current
/// devcontainer.json, preserving the container identity (same name / same workspace
/// volume). Two phases split at the delete of the old container:
///
/// - Phase A (non-destructive gate): selection → stamps → (volume, stopped) bare runtime
///   start → strict config read → hostRequirements preflight → Features gate
///   (rosetta consent, pull/skip-pull, derived-tag reuse). Any failure here fails
///   `rebuild` with the old container untouched.
/// - Phase B (destructive create path): container-only delete of the old container →
///   ensureVolume list-then-reuse for workspace/config volumes (never deleted) →
///   create with the old label dict + drift-eligible updates only → start → volume
///   writable-if-user-changed (soft-fail) → create-path hooks (delete-on-fail of the
///   NEW container) → settings apply → `--vscode` open → extensions → postAttach gate
///   (fail-keep).
public enum RebuildCommand {
    /// Optional Features fetch override for tests (same pattern as `up`/`clone`).
    nonisolated(unsafe) public static var featuresFetcherOverride: (any FeatureFetching)?
    /// Optional Features cache root override for tests.
    nonisolated(unsafe) public static var featuresCacheRootOverride: String?
    /// Optional override for native-arm BuildKit ensure (tests inject no-op / mock).
    nonisolated(unsafe) public static var ensureNativeArmBuildOverride: (() throws -> Void)?

    public static func run(
        options: RebuildOptions,
        runtime: AppleContainerRuntime,
        picker: InteractivePicker = .default,
        localEnv: [String: String] = ProcessInfo.processInfo.environment,
        hostResources: any HostResourceProviding = SystemHostResourceInfo(),
        fileManager: FileManager = .default
    ) throws -> RebuildResult {
        let selected = try ManagedContainers.resolveSelection(
            name: options.name,
            runtime: runtime,
            picker: picker
        )
        let labels = selected.labels
        let isVolumeMode = labels[ContainerIdentity.labelWorkspaceMode]
            == ContainerIdentity.workspaceModeVolume

        // ═══════════════════════════ PHASE A (non-destructive gate) ═══════════════════════════

        // Volume mode: the config lives in the volume; a stopped container cannot cat it.
        // Bare runtime start (no lifecycle hooks) is the only pre-delete runtime action
        // allowed on the old container.
        if isVolumeMode, !selected.isRunning {
            StatusPrinter.status("Starting container")
            try runtime.start(nameOrId: selected.id)
        }

        // Strict read of the CURRENT config from stamps. Any miss (config_not_found /
        // config_parse) fails here with the old container untouched (strict mode throws;
        // the guard is defensive only).
        guard let resolvedConfig = try ConfigReader.read(
            labels: labels,
            containerId: selected.id,
            runtime: runtime,
            localEnv: localEnv,
            fileManager: fileManager,
            mode: .strict
        ) else {
            throw CLIError(
                code: CLIErrorCode.configNotFound,
                property: ContainerIdentity.labelConfigFile,
                message: "Managed container has no readable devcontainer config",
                hint: "Recreate the container with 'adevcontainer up' or 'adevcontainer clone'"
            )
        }

        // hostRequirements preflight (same gate as up/clone; before pull/build).
        try enforceHostRequirements(config: resolvedConfig, host: hostResources)

        var effectiveConfig = resolvedConfig
        let platform = ContainerPlatform.defaultLinuxPlatform

        // Volume-mode git parity: same keyed-auto-inject as clone (nothing to fetch when absent).
        if isVolumeMode {
            let gitEnsure = FeatureGitEnsure.ensurePresent(features: effectiveConfig.features)
            if gitEnsure.didInject {
                StatusPrinter.status("Ensuring git feature for volume workspace")
            }
            effectiveConfig.features = gitEnsure.features
        }

        // Features path (rosetta consent, pull/skip-pull, fetch/build with derived-tag
        // reuse; any failure fails before delete).
        if !effectiveConfig.features.isEmpty {
            if let ensureNativeArmBuildOverride {
                try ensureNativeArmBuildOverride()
            } else {
                try AppleContainerConfig.ensureNativeArmBuild(runtime: runtime)
            }
            if !options.skipPull {
                StatusPrinter.status("Pulling image \(effectiveConfig.image)")
                try? runtime.pullImage(effectiveConfig.image, platform: platform)
            }
            let fetcher: any FeatureFetching = RebuildCommand.featuresFetcherOverride
                ?? (isVolumeMode
                    ? OCIFeatureClient()
                    : DefaultFeatureFetcher(workspacePath: stampedLocalFolder(labels)))
            let cacheRoot = RebuildCommand.featuresCacheRootOverride ?? FeatureCache.defaultRoot()
            let deps = FeaturesRunner.Dependencies(
                fetcher: fetcher,
                runtime: runtime,
                cacheRoot: cacheRoot,
                platform: platform
            )
            let nameBase = derivedNameBase(
                containerName: selected.name,
                labels: labels,
                config: resolvedConfig,
                isVolumeMode: isVolumeMode
            )
            let featuresResult = try FeaturesRunner.run(
                features: effectiveConfig.features,
                baseImage: effectiveConfig.image,
                deps: deps,
                remoteUser: effectiveConfig.remoteUser,
                containerUser: effectiveConfig.containerUser,
                nameBase: nameBase
            )
            effectiveConfig = try FeatureContributionMerge.apply(
                contributions: featuresResult.contributions,
                to: effectiveConfig
            )
            effectiveConfig.image = featuresResult.derivedImage
        } else if !options.skipPull {
            StatusPrinter.status("Pulling image \(effectiveConfig.image)")
            try? runtime.pullImage(effectiveConfig.image, platform: platform)
        }

        // Identity. Bind: up parity → hash from the resolved (pre-feature) config. Volume:
        // clone parity → hash from the effective (post-feature) config. Either way labels
        // change only when the underlying material actually changed.
        let configHash = isVolumeMode
            ? ContainerIdentity.configHash(from: effectiveConfig.hashMaterial())
            : ContainerIdentity.configHash(from: resolvedConfig.hashMaterial())

        // Label dict = COPY of the selected container's labels with only drift-eligible
        // keys updated (config_hash, workspace_folder, remote_user, config_volumes).
        // Never recomputed via ContainerIdentity volumeModeLabels/bindModeLabels; the
        // container's name is reused verbatim.
        let configVolumeNames = effectiveConfig.mounts
            .filter { $0.type == .volume }
            .map(\.source)
        var newLabels = labels
        newLabels[ContainerIdentity.labelConfigHash] = configHash
        newLabels[ContainerIdentity.labelWorkspaceFolder] = effectiveConfig.workspaceFolder
        newLabels[ContainerIdentity.labelRemoteUser] = effectiveConfig.effectiveUser ?? ""
        if configVolumeNames.isEmpty {
            newLabels.removeValue(forKey: ContainerIdentity.labelConfigVolumes)
        } else {
            newLabels[ContainerIdentity.labelConfigVolumes] = configVolumeNames.joined(separator: ",")
        }

        // ═══════════════════════════ PHASE B (destructive create path) ═══════════════════════════

        // Container-only delete of the OLD container (never volumes/images).
        StatusPrinter.status("Deleting container \(selected.id)")
        try runtime.delete(nameOrId: selected.id, force: true)

        let request: CreateRequest
        if isVolumeMode {
            let sshForward = !(localEnv["SSH_AUTH_SOCK"] ?? "")
                .trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            request = CreateRequest.fromVolumeMode(
                resolved: effectiveConfig,
                identityName: selected.name,
                labels: newLabels,
                configHash: configHash,
                workspaceVolumeName: stampedWorkspaceVolume(labels),
                platform: platform,
                enableSSHForward: sshForward
            )
        } else {
            request = CreateRequest.from(
                resolved: effectiveConfig,
                identityName: selected.name,
                labels: newLabels,
                configHash: configHash,
                workspacePath: stampedLocalFolder(labels),
                platform: platform
            )
        }

        // create() ensureVolumes list-then-reuse workspace/config named volumes
        // (never delete; missing config volumes created on demand).
        StatusPrinter.status("Creating container \(selected.name)")
        let id: String
        do {
            id = try runtime.create(request: request)
        } catch {
            StatusPrinter.warning("Old container '\(selected.name)' was already removed; rebuild failed before creating the new container")
            throw error
        }

        StatusPrinter.status("Starting container")
        do {
            try runtime.start(nameOrId: id)
        } catch {
            try? runtime.delete(nameOrId: id, force: true)
            StatusPrinter.warning("Old container '\(selected.name)' was already removed; rebuilt container deleted after start failure")
            throw error
        }

        // Volume mode: root-owned named volumes. Chown only when the effective remote
        // user differs from the stamped one (volume data already belongs to that user).
        // Soft-fail: chown errors warn and continue (rebuild semantics differ from clone).
        if isVolumeMode, volumeUserChanged(labels: labels, config: effectiveConfig) {
            do {
                try WorkspaceOwnership.ensureWorkspaceWritableByRemoteUser(
                    containerId: id,
                    workspaceFolder: effectiveConfig.workspaceFolder,
                    remoteUser: effectiveConfig.effectiveUser,
                    runtime: runtime
                )
            } catch {
                StatusPrinter.warning("Failed to chown workspace to \(effectiveConfig.effectiveUser ?? "remoteUser"): \(error.localizedDescription)")
            }
        }

        // Create-path hooks (delete-on-fail of the new container).
        do {
            try LifecycleRunner.runCreatePath(
                containerId: id,
                config: effectiveConfig,
                runtime: runtime
            )
        } catch {
            // runCreatePath already deletes the new container on hook exec failure;
            // ensure it is gone for exec-level failures too.
            try? runtime.delete(nameOrId: id, force: true)
            StatusPrinter.warning("Old container '\(selected.name)' was already removed; rebuilt container deleted after hook failure")
            throw error
        }

        // Settings apply after create-path hooks; not gated on --vscode.
        _ = VSCodeCustomizationsApply.applySettingsIfNeeded(
            containerId: id,
            config: effectiveConfig,
            runtime: runtime
        )

        return try finish(
            options: options,
            id: id,
            name: selected.name,
            config: effectiveConfig,
            imagesLabels: labels,
            isVolumeMode: isVolumeMode,
            runtime: runtime
        )
    }

    // MARK: - Finish (open → extensions → postAttach gate), up parity

    /// Open (optional) → extensions apply (open success) → postAttach gate → Ready.
    /// postAttach is never before open when `--vscode`. Extensions never fold into postAttachCommand.
    private static func finish(
        options: RebuildOptions,
        id: String,
        name: String,
        config: ResolvedDevContainerConfig,
        imagesLabels: [String: String],
        isVolumeMode: Bool,
        runtime: AppleContainerRuntime
    ) throws -> RebuildResult {
        let result = RebuildResult(
            outcome: "success",
            containerId: id,
            remoteUser: config.effectiveUser ?? "",
            remoteWorkspaceFolder: config.workspaceFolder,
            containerName: name,
            gitUrl: isVolumeMode ? imagesLabels[ContainerIdentity.labelGitURL] : nil,
            workspaceVolume: isVolumeMode ? imagesLabels[ContainerIdentity.labelWorkspaceVolume] : nil
        )
        let openOutcome = VSCodeOpen.openIfRequested(
            options.openVSCode,
            target: VSCodeOpenTarget(
                containerId: result.containerId,
                image: config.image,
                remoteWorkspaceFolder: result.remoteWorkspaceFolder,
                containerName: result.containerName ?? name,
                remoteUser: result.remoteUser
            )
        )
        // Extensions only after successful open (same CLI attach hook as postAttach).
        if openOutcome.isOpenSuccess {
            _ = VSCodeCustomizationsApply.applyExtensionsIfNeeded(
                containerId: id,
                config: config,
                runtime: runtime
            )
        }
        // Rebuild never re-runs Features; merge feature postAttach from image metadata.
        var postAttachConfig = config
        PostAttachConfigLoader.mergeFeaturePostAttach(
            into: &postAttachConfig,
            imageRef: config.image.isEmpty ? nil : config.image,
            runtime: runtime
        )
        try LifecycleRunner.applyPostAttachGate(
            openOutcome: openOutcome,
            containerId: id,
            config: postAttachConfig,
            runtime: runtime
        )
        StatusPrinter.status("Ready")
        return result
    }

    // MARK: - Helpers

    private static func enforceHostRequirements(
        config: ResolvedDevContainerConfig,
        host: any HostResourceProviding
    ) throws {
        let evaluation = HostRequirementsEvaluation.evaluate(config.hostRequirements, host: host)
        for warning in evaluation.warnings {
            StatusPrinter.warning(warning)
        }
        guard evaluation.hasHardFailures else { return }
        throw CLIError(
            code: CLIErrorCode.hostRequirements,
            property: "hostRequirements",
            message: evaluation.hardFailures.joined(separator: "; "),
            hint: "Reduce hostRequirements or run on a host with sufficient memory/CPUs"
        )
    }

    private static func stampedLocalFolder(_ labels: [String: String]) -> String {
        labels[ContainerIdentity.labelLocalFolder]?
            .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
    }

    private static func stampedWorkspaceVolume(_ labels: [String: String]) -> String {
        labels[ContainerIdentity.labelWorkspaceVolume]?
            .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
    }

    private static func volumeUserChanged(
        labels: [String: String],
        config: ResolvedDevContainerConfig
    ) -> Bool {
        let stamped = labels[ContainerIdentity.labelRemoteUser]?
            .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        let effective = config.effectiveUser?
            .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return effective != stamped
    }

    /// Derived-tag nameBase for Features: reuse the OLD container-derived base so the
    /// tag matches the original create even when config `name` was edited
    /// (`adev-{base}-{hash12}` → base). Fallback: fresh-create parity.
    private static func derivedNameBase(
        containerName: String,
        labels: [String: String],
        config: ResolvedDevContainerConfig,
        isVolumeMode: Bool
    ) -> String {
        if let base = baseFromContainerName(containerName) {
            return base
        }
        if isVolumeMode {
            let identity = ContainerIdentity.volumeModeIdentity(
                gitURL: labels[ContainerIdentity.labelGitURL] ?? "",
                configRelativePath: labels[ContainerIdentity.labelConfigFile] ?? "",
                configName: config.name
            )
            return identity.base
        }
        return ContainerIdentity.humanBase(
            configName: config.name,
            workspacePath: stampedLocalFolder(labels)
        )
    }

    /// `adev-{base}-{hash12}` → `{base}` (sanitized); nil when the name does not match.
    private static func baseFromContainerName(_ name: String) -> String? {
        var s = name
        guard s.hasPrefix("adev-") else { return nil }
        s = String(s.dropFirst("adev-".count))
        let parts = s.split(separator: "-")
        guard let last = parts.last,
              last.count == 12,
              last.allSatisfy({ $0.isHexDigit })
        else { return nil }
        s = String(s.dropLast(last.count + 1))
        guard !s.isEmpty else { return nil }
        return ContainerIdentity.sanitizeBase(s)
    }
}