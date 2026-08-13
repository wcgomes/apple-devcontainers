import Foundation

/// `adevcontainer rebuild`: force-rebuild a managed container from its current
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
///   NEW container) → settings apply → extensions apply → open → postAttach gate
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
        fileManager: FileManager = .default,
        isTTY: Bool = AppleContainerConfig.stdinIsTTY(),
        recoveryEditor: RecoveryEditor? = nil,
        openEditorPrompt: RecoveryOpenEditorPrompt = .default
    ) throws -> RebuildResult {
        try runInternal(
            options: options,
            runtime: runtime,
            picker: picker,
            localEnv: localEnv,
            hostResources: hostResources,
            fileManager: fileManager,
            isTTY: isTTY,
            recoveryEditor: recoveryEditor,
            openEditorPrompt: openEditorPrompt
        )
    }

    private static func runInternal(
        options: RebuildOptions,
        runtime: AppleContainerRuntime,
        picker: InteractivePicker,
        localEnv: [String: String],
        hostResources: any HostResourceProviding,
        fileManager: FileManager,
        recovery: RecoveryOrchestrator.Prepared? = nil,
        recoveryHelperID: String? = nil,
        /// Same-process bind recovery retry: reuse stamps without requiring a live container.
        selectedOverride: ContainerInfo? = nil,
        allowRecovery: Bool = true,
        isTTY: Bool = AppleContainerConfig.stdinIsTTY(),
        recoveryEditor: RecoveryEditor? = nil,
        openEditorPrompt: RecoveryOpenEditorPrompt = .default
    ) throws -> RebuildResult {
        let selected: ContainerInfo
        if let selectedOverride {
            selected = selectedOverride
        } else {
            do {
                selected = try ManagedContainers.resolveSelection(
                    name: options.name,
                    runtime: runtime,
                    picker: picker
                )
            } catch let error as CLIError where error.code == CLIErrorCode.containerNotFound {
                // Named bind recovery retry after non-TTY retention: container was removed;
                // resume from retained stamps and the (already edited) host stamped path.
                if let name = options.name,
                   let resume = try BindRecoveryResume.load(name: name, fileManager: fileManager)
                {
                    selected = BindRecoveryResume.containerInfo(from: resume)
                } else {
                    throw error
                }
            }
        }
        let labels = selected.labels
        let isVolumeMode = labels[ContainerIdentity.labelWorkspaceMode]
            == ContainerIdentity.workspaceModeVolume
        let bindRecoveryEligible = RecoveryOrchestrator.isBindEligible(labels: labels)
        var recoveryContext = recovery
        var recoveryEndpointID = recoveryHelperID
        var crossedDeleteBoundary = false
        defer {
        if !crossedDeleteBoundary, let recoveryContext {
                if recoveryEndpointID == nil {
                    try? recoveryContext.session.cleanup()
                }
            }
        }

        // ═══════════════════════════ PHASE A (non-destructive gate) ═══════════════════════════

        // Volume mode: the config lives in the volume; a stopped container cannot cat it.
        // Bare runtime start (no lifecycle hooks) is the only pre-delete runtime action
        // allowed on the old container. Named recovery retry also needs the helper up before
        // apply/write — do not run recovery apply above this gate.
        if isVolumeMode, !selected.isRunning {
            StatusPrinter.status("Starting container")
            try runtime.start(nameOrId: selected.id)
        }

        // A later named retry uses the retained helper and session. Validate both identities and
        // write/edit through the helper before the normal strict config read or helper delete gate.
        // TTY (no --json): open the editor first so a retained broken config is fixed before rebuilding.
        // Non-TTY / --json: apply the current temp bytes (operator already edited offline).
        // openRetry/apply also bounce Apple zombie helpers (list=running, exec rejected).
        if recoveryContext == nil, RecoveryHelper.isRecoveryHelper(selected) {
            let opened = try RecoveryOrchestrator.openRetry(
                helper: selected,
                runtime: runtime,
                fileManager: fileManager,
                pullIfMissing: !options.skipPull
            )
            recoveryContext = opened
            recoveryEndpointID = selected.id
            try RecoveryOrchestrator.applyNamedRetryEdit(
                prepared: opened,
                helperID: selected.id,
                selectedName: selected.name,
                runtime: runtime,
                options: options,
                localEnv: localEnv,
                isTTY: isTTY,
                editor: recoveryEditor
            )
        }

        // Strict read of the CURRENT config from stamps. Any miss (config_not_found /
        // config_parse) fails here with the old container untouched (strict mode throws;
        // the guard is defensive only).
        let volumeRead: ResolvedVolumeConfigRead?
        let resolvedConfig: ResolvedDevContainerConfig
        if isVolumeMode {
            volumeRead = try ConfigReader.readVolumeWithRaw(
                labels: labels,
                containerId: selected.id,
                runtime: runtime,
                fileManager: fileManager
            )
            resolvedConfig = volumeRead!.config
        } else {
            volumeRead = nil
            guard let config = try ConfigReader.read(
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
                    hint: "Run 'adevcontainer up' or 'adevcontainer clone' to restore the container"
                )
            }
            resolvedConfig = config
        }

        if recoveryContext == nil, RecoveryHelper.isEligible(labels: labels), let volumeRead {
            // This is deliberately before host/Features work and before the old-container
            // delete. Preparation failures therefore leave the selected container untouched.
            recoveryContext = try RecoveryOrchestrator.prepare(
                container: selected,
                rawConfig: volumeRead.raw,
                runtime: runtime,
                fileManager: fileManager,
                pullIfMissing: !options.skipPull
            )
        }

        if recoveryContext == nil && isVolumeMode && RecoveryHelper.isEligible(labels: labels) {
            throw CLIError(
                code: CLIErrorCode.recoveryUnavailable,
                message: "Recovery config could not be retained",
                hint: "The old container was not deleted"
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
                StatusPrinter.status("Ensuring git feature for volume-mode dev container")
            }
            effectiveConfig.features = gitEnsure.features
        }

        // Features path (rosetta consent, pull/skip-pull, fetch/build with derived-tag
        // reuse; any failure fails before delete).
        var knownOCIUser: String?? = nil
        var knownMetadataUsers: DevContainerMetadataLabel.ImageMetadataUsers? = nil
        if !effectiveConfig.features.isEmpty {
            if let ensureNativeArmBuildOverride {
                try ensureNativeArmBuildOverride()
            } else {
                try AppleContainerConfig.ensureNativeArmBuild(runtime: runtime)
            }
            if !options.skipPull {
                StatusPrinter.status("Pulling image", item: effectiveConfig.image)
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
            if featuresResult.didInspectBaseUser {
                knownOCIUser = featuresResult.baseImageUser
            }
            knownMetadataUsers = featuresResult.metadataUsers
        } else if !options.skipPull {
            StatusPrinter.status("Pulling image", item: effectiveConfig.image)
            try? runtime.pullImage(effectiveConfig.image, platform: platform)
        }

        // Expand `${devcontainerId}` with the reused create name before hash / volume ensure.
        effectiveConfig = VariableSubstitutor.expandDevcontainerId(
            in: effectiveConfig,
            id: selected.name
        )

        // Identity. Bind: up parity → hash from the resolved (pre-feature) config. Volume:
        // clone parity → hash from the effective (post-feature) config. Either way labels
        // change only when the underlying material actually changed.
        // Hash before stamping OCI-resolved connection user onto effectiveConfig.
        let configHash = isVolumeMode
            ? ContainerIdentity.configHash(from: effectiveConfig.hashMaterial())
            : ContainerIdentity.configHash(from: resolvedConfig.hashMaterial())

        let connectionUser = try RemoteUserResolution.resolve(
            config: effectiveConfig,
            imageRef: effectiveConfig.image,
            runtime: runtime,
            knownOCIUser: knownOCIUser,
            knownMetadataUsers: knownMetadataUsers
        )
        effectiveConfig = RemoteUserResolution.applyingConnectionUser(connectionUser, to: effectiveConfig)

        // Label dict = COPY of the selected container's labels with only drift-eligible
        // keys updated (config_hash, workspace_folder, remote_user, config_volumes).
        // Never recomputed via ContainerIdentity volumeModeLabels/bindModeLabels; the
        // container's name is reused verbatim.
        let configVolumeNames = effectiveConfig.mounts
            .filter { $0.type == .volume }
            .map(\.source)
        var newLabels = RecoveryHelper.normalContainerLabels(labels)
        newLabels[ContainerIdentity.labelConfigHash] = configHash
        newLabels[ContainerIdentity.labelWorkspaceFolder] = effectiveConfig.workspaceFolder
        newLabels[ContainerIdentity.labelRemoteUser] = connectionUser
        if configVolumeNames.isEmpty {
            newLabels.removeValue(forKey: ContainerIdentity.labelConfigVolumes)
        } else {
            newLabels[ContainerIdentity.labelConfigVolumes] = configVolumeNames.joined(separator: ",")
        }

        // A retained helper is only a write endpoint for the exact pre-existing workspace
        // volume. Recheck before deleting it; recovery must never manufacture a blank volume.
        if isVolumeMode, let recovery = recoveryContext {
            let present: Bool
            do {
                present = try runtime.volumeExists(
                    stampedWorkspaceVolume(labels),
                    requireObjectEntries: true
                )
            } catch {
                throw RecoveryOrchestrator.retainedUnavailableFailure(
                    session: recovery.session,
                    helperID: recoveryEndpointID ?? selected.id,
                    selectedName: selected.name,
                    failure: error,
                    environment: localEnv,
                    helperAvailable: recoveryEndpointID != nil
                )
            }
            guard present else {
                let missing = CLIError(
                    code: CLIErrorCode.recoveryUnavailable,
                    message: "The retained recovery workspace volume is no longer present",
                    hint: "Recovery refuses to create a blank replacement volume"
                )
                throw RecoveryOrchestrator.retainedUnavailableFailure(
                    session: recovery.session,
                    helperID: recoveryEndpointID ?? selected.id,
                    selectedName: selected.name,
                    failure: missing,
                    environment: localEnv,
                    helperAvailable: recoveryEndpointID != nil
                )
            }
        }

        // ═══════════════════════════ PHASE B (destructive create path) ═══════════════════════════

        // Container-only delete of the OLD container (never volumes/images).
        // Bind recovery resume / same-process retry may already have no live container.
        if let existing = try runtime.findByName(selected.id)
            ?? (selected.name != selected.id ? try runtime.findByName(selected.name) : nil)
        {
            StatusPrinter.status("Deleting container", item: existing.id)
            try runtime.delete(nameOrId: existing.id, force: true)
        } else if selectedOverride != nil || bindRecoveryEligible {
            StatusPrinter.status("Old container already removed; continuing rebuild")
        } else {
            StatusPrinter.status("Deleting container", item: selected.id)
            try runtime.delete(nameOrId: selected.id, force: true)
        }
        crossedDeleteBoundary = true

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
        do {
            if isVolumeMode {
                if let recovery = recoveryContext {
                    let present: Bool
                    do {
                        present = try runtime.volumeExists(
                            stampedWorkspaceVolume(labels),
                            requireObjectEntries: true
                        )
                    } catch {
                        throw RecoveryOrchestrator.retainedUnavailableFailure(
                            session: recovery.session,
                            helperID: recoveryEndpointID ?? selected.id,
                            selectedName: selected.name,
                            failure: error,
                            environment: localEnv,
                            helperAvailable: false
                        )
                    }
                    guard present else {
                        let missing = CLIError(
                            code: CLIErrorCode.recoveryUnavailable,
                            message: "The retained recovery workspace volume disappeared before replacement create",
                            hint: "Recovery refuses to create a blank replacement volume"
                        )
                        throw RecoveryOrchestrator.retainedUnavailableFailure(
                            session: recovery.session,
                            helperID: recoveryEndpointID ?? selected.id,
                            selectedName: selected.name,
                            failure: missing,
                            environment: localEnv,
                            helperAvailable: false
                        )
                    }
                } else {
                    try runtime.ensureVolume(name: stampedWorkspaceVolume(labels))
                }
            }
            for mount in effectiveConfig.mounts where mount.type == .volume {
                try runtime.ensureVolume(name: mount.source)
            }
        } catch let error as CLIError where error.recovery != nil {
            throw error
        } catch {
            StatusPrinter.warning("Old container '\(selected.name)' was already removed; rebuild failed while ensuring named volumes")
            try? recoveryContext?.session.cleanup()
            throw CLIError(
                code: CLIErrorCode.runtimeFailed,
                property: "volumes",
                message: "Failed to ensure rebuild volumes: \(error.localizedDescription)",
                hint: "Existing volumes were preserved"
            )
        }
        StatusPrinter.status("Creating container", item: selected.name)
        let id: String
        do {
            id = try runtime.create(request: request, ensureVolumes: false)
        } catch {
            if allowRecovery, let recovery = recoveryContext {
                return try RecoveryOrchestrator.recover(
                    prepared: recovery,
                    failure: .init(error: error),
                    selected: selected,
                    runtime: runtime,
                    options: options,
                    localEnv: localEnv,
                    fileManager: fileManager,
                    isTTY: isTTY,
                    editor: recoveryEditor,
                    openEditorPrompt: openEditorPrompt,
                    retry: { helperID, session in
                        try runInternal(
                            options: options,
                            runtime: runtime,
                            picker: picker,
                            localEnv: localEnv,
                            hostResources: hostResources,
                            fileManager: fileManager,
                            recovery: recovery,
                            recoveryHelperID: helperID,
                            allowRecovery: false,
                            isTTY: isTTY,
                            recoveryEditor: recoveryEditor,
                            openEditorPrompt: openEditorPrompt
                        )
                    }
                )
            }
            if allowRecovery, bindRecoveryEligible {
                StatusPrinter.status("Create failed; entering recovery")
                return try offerBindRecovery(
                    failure: .init(error: error),
                    selected: selected,
                    labels: labels,
                    runtime: runtime,
                    options: options,
                    localEnv: localEnv,
                    hostResources: hostResources,
                    fileManager: fileManager,
                    picker: picker,
                    isTTY: isTTY,
                    recoveryEditor: recoveryEditor,
                    openEditorPrompt: openEditorPrompt
                )
            }
            StatusPrinter.warning("Old container '\(selected.name)' was already removed; rebuild failed before creating the new container")
            throw error
        }

        StatusPrinter.status("Starting container")
        do {
            try runtime.start(nameOrId: id)
        } catch {
            if allowRecovery, let recovery = recoveryContext {
                return try RecoveryOrchestrator.recover(
                    prepared: recovery,
                    failure: .init(error: error, containerID: id),
                    selected: selected,
                    runtime: runtime,
                    options: options,
                    localEnv: localEnv,
                    fileManager: fileManager,
                    isTTY: isTTY,
                    editor: recoveryEditor,
                    openEditorPrompt: openEditorPrompt,
                    retry: { helperID, _ in
                        try runInternal(
                            options: options,
                            runtime: runtime,
                            picker: picker,
                            localEnv: localEnv,
                            hostResources: hostResources,
                            fileManager: fileManager,
                            recovery: recovery,
                            recoveryHelperID: helperID,
                            allowRecovery: false,
                            isTTY: isTTY,
                            recoveryEditor: recoveryEditor,
                            openEditorPrompt: openEditorPrompt
                        )
                    }
                )
            }
            if allowRecovery, bindRecoveryEligible {
                StatusPrinter.status("Start failed; entering recovery")
                return try offerBindRecovery(
                    failure: .init(error: error, containerID: id),
                    selected: selected,
                    labels: labels,
                    runtime: runtime,
                    options: options,
                    localEnv: localEnv,
                    hostResources: hostResources,
                    fileManager: fileManager,
                    picker: picker,
                    isTTY: isTTY,
                    recoveryEditor: recoveryEditor,
                    openEditorPrompt: openEditorPrompt
                )
            }
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
                    remoteUser: effectiveConfig.connectionUser,
                    runtime: runtime
                )
            } catch {
                StatusPrinter.warning("Failed to chown workspace folder to \(effectiveConfig.connectionUser ?? "remoteUser"): \(error.localizedDescription)")
            }
        }

        // Config named volumes mount root:root (bind and volume mode). Soft-fail like workspace.
        do {
            try WorkspaceOwnership.ensureNamedVolumeMountsWritableByRemoteUser(
                containerId: id,
                mounts: effectiveConfig.mounts,
                remoteUser: effectiveConfig.connectionUser,
                runtime: runtime
            )
        } catch {
            StatusPrinter.warning(
                "Failed to chown named volume mounts for \(effectiveConfig.connectionUser ?? "remoteUser"): \(error.localizedDescription)"
            )
        }

        // Create-path hooks (delete-on-fail of the new container).
        do {
            try LifecycleRunner.runCreatePath(
                containerId: id,
                config: effectiveConfig,
                runtime: runtime
            )
        } catch {
            // Delete-on-fail must run exactly once. runCreatePath already deletes the
            // new container when a create-path hook exits non-zero; only an exec-level
            // failure (the hook could not run at all) leaves it in place. Deleting an
            // already-removed container a second time would stream a spurious runtime
            // notFound error to stderr before the warning below.
            if allowRecovery, let recovery = recoveryContext {
                StatusPrinter.status("Create-path hook failed; entering recovery")
                return try RecoveryOrchestrator.recover(
                    prepared: recovery,
                    failure: .init(error: error, containerID: id),
                    selected: selected,
                    runtime: runtime,
                    options: options,
                    localEnv: localEnv,
                    fileManager: fileManager,
                    isTTY: isTTY,
                    editor: recoveryEditor,
                    openEditorPrompt: openEditorPrompt,
                    retry: { helperID, _ in
                        try runInternal(
                            options: options,
                            runtime: runtime,
                            picker: picker,
                            localEnv: localEnv,
                            hostResources: hostResources,
                            fileManager: fileManager,
                            recovery: recovery,
                            recoveryHelperID: helperID,
                            allowRecovery: false,
                            isTTY: isTTY,
                            recoveryEditor: recoveryEditor,
                            openEditorPrompt: openEditorPrompt
                        )
                    }
                )
            }
            if allowRecovery, bindRecoveryEligible {
                StatusPrinter.status("Create-path hook failed; entering recovery")
                return try offerBindRecovery(
                    failure: .init(error: error, containerID: id),
                    selected: selected,
                    labels: labels,
                    runtime: runtime,
                    options: options,
                    localEnv: localEnv,
                    hostResources: hostResources,
                    fileManager: fileManager,
                    picker: picker,
                    isTTY: isTTY,
                    recoveryEditor: recoveryEditor,
                    openEditorPrompt: openEditorPrompt
                )
            }
            if (try? runtime.findByName(id)) != nil {
                try? runtime.delete(nameOrId: id, force: true)
            }
            StatusPrinter.warning("Old container '\(selected.name)' was already removed; rebuilt container deleted after hook failure")
            throw error
        }

        // Settings apply after create-path hooks; not gated on --vscode.
        _ = VSCodeCustomizationsApply.applySettingsIfNeeded(
            containerId: id,
            config: effectiveConfig,
            runtime: runtime
        )

        let result: RebuildResult
        do {
            result = try finish(
                options: options,
                id: id,
                name: selected.name,
                config: effectiveConfig,
                imagesLabels: labels,
                isVolumeMode: isVolumeMode,
                runtime: runtime
            )
        } catch {
            // Open/postAttach failures are terminal non-recovery outcomes. Do not leak the
            // prepared session after the delete boundary.
            if let recoveryContext { try? recoveryContext.session.cleanup() }
            throw error
        }
        if let recovery = recoveryContext {
            if recoveryEndpointID != nil {
                let expected = recovery.session.lastAppliedHash
                let finalBytes: Data?
                let readError: String?
                do {
                    finalBytes = try runtime.readFile(
                        nameOrId: id,
                        path: recovery.session.configPathInContainer
                    )
                    readError = nil
                } catch {
                    finalBytes = nil
                    readError = error.localizedDescription
                }
                let actualHash = finalBytes.map { RecoveryConfigSession.sha256Hex($0) }
                let verified = expected != nil && actualHash == expected
                if !verified {
                    let detail: String
                    if expected == nil {
                        detail = "missing last-applied hash on the recovery session"
                    } else if let readError {
                        detail = "final container config read failed: \(readError)"
                    } else if let actualHash {
                        detail = "hash mismatch expected=\(expected!) actual=\(actualHash)"
                    } else {
                        detail = "final container config was empty"
                    }
                    let verificationError = CLIError(
                        code: CLIErrorCode.recoveryVerificationFailed,
                        message: "The final container could not verify the recovered config (\(detail))",
                        hint: "The secure recovery session was retained; no recovery helper remains"
                    )
                    throw RecoveryOrchestrator.finalVerificationFailure(
                        session: recovery.session,
                        selectedName: selected.name,
                        failure: verificationError,
                        environment: localEnv
                    )
                }
            }
            do {
                try recovery.session.cleanup()
            } catch {
                throw RecoveryOrchestrator.retainedFailure(
                    session: recovery.session,
                    helperID: recoveryEndpointID ?? "not-created",
                    selectedName: selected.name,
                    failure: error,
                    environment: localEnv
                )
            }
        }
        // Bind recovery resume is only needed while the managed container is missing.
        try? BindRecoveryResume.cleanup(name: selected.name, fileManager: fileManager)
        // Connection hints: entry point after human outcome digest / JSON.
        return result
    }

    /// Shared bind host-editor recovery entry used by create/start/create-path hard failures.
    private static func offerBindRecovery(
        failure: RecoveryOrchestrator.Failure,
        selected: ContainerInfo,
        labels: [String: String],
        runtime: AppleContainerRuntime,
        options: RebuildOptions,
        localEnv: [String: String],
        hostResources: any HostResourceProviding,
        fileManager: FileManager,
        picker: InteractivePicker,
        isTTY: Bool,
        recoveryEditor: RecoveryEditor?,
        openEditorPrompt: RecoveryOpenEditorPrompt
    ) throws -> RebuildResult {
        StatusPrinter.warning(
            "Old container '\(selected.name)' was already removed; entering bind recovery"
        )
        return try RecoveryOrchestrator.recoverBind(
            labels: labels,
            failure: failure,
            selected: selected,
            runtime: runtime,
            options: options,
            localEnv: localEnv,
            fileManager: fileManager,
            isTTY: isTTY,
            editor: recoveryEditor,
            openEditorPrompt: openEditorPrompt,
            retry: {
                // Same-process retry: stamps only (container already gone). allowRecovery
                // stays false so a nested hard failure returns to recoverBind's loop.
                var retryOptions = options
                if retryOptions.name == nil {
                    retryOptions.name = selected.name
                }
                return try runInternal(
                    options: retryOptions,
                    runtime: runtime,
                    picker: picker,
                    localEnv: localEnv,
                    hostResources: hostResources,
                    fileManager: fileManager,
                    selectedOverride: selected,
                    allowRecovery: false,
                    isTTY: isTTY,
                    recoveryEditor: recoveryEditor,
                    openEditorPrompt: openEditorPrompt
                )
            }
        )
    }

    // MARK: - Finish (extensions → open → postAttach gate), up parity

    /// Extensions apply (not flag-gated) → open (optional) → postAttach gate → Ready.
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
            remoteUser: config.connectionUser ?? "",
            remoteWorkspaceFolder: config.workspaceFolder,
            containerName: name,
            gitUrl: isVolumeMode ? imagesLabels[ContainerIdentity.labelGitURL] : nil,
            workspaceVolume: isVolumeMode ? imagesLabels[ContainerIdentity.labelWorkspaceVolume] : nil
        )
        // Extensions apply when pending (not gated on `--vscode` or open success).
        _ = VSCodeCustomizationsApply.applyExtensionsIfNeeded(
            containerId: id,
            config: config,
            runtime: runtime
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
        let effective = config.connectionUser?
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
