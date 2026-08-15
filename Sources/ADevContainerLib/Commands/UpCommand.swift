import Foundation

public struct UpOptions: Sendable {
    public var workspacePath: String
    public var jsonOutput: Bool
    public var skipPull: Bool
    /// Best-effort open of VS Code on the remote workspace after lifecycle success.
    public var openVSCode: Bool

    public init(
        workspacePath: String,
        jsonOutput: Bool = false,
        skipPull: Bool = false,
        openVSCode: Bool = false
    ) {
        self.workspacePath = workspacePath
        self.jsonOutput = jsonOutput
        self.skipPull = skipPull
        self.openVSCode = openVSCode
    }
}

public enum UpCommand {
    /// Optional Features fetch override for tests (nil → DefaultFeatureFetcher with workspace path).
    nonisolated(unsafe) public static var featuresFetcherOverride: (any FeatureFetching)?
    /// Optional Features cache root override for tests.
    nonisolated(unsafe) public static var featuresCacheRootOverride: String?
    /// Optional override for native-arm BuildKit ensure (tests inject no-op / mock).
    nonisolated(unsafe) public static var ensureNativeArmBuildOverride: (() throws -> Void)?

    public static func run(
        options: UpOptions,
        runtime: AppleContainerRuntime,
        localEnv: [String: String] = ProcessInfo.processInfo.environment,
        hostResources: any HostResourceProviding = SystemHostResourceInfo(),
        isTTY: Bool = AppleContainerConfig.stdinIsTTY(),
        recoveryEditor: RecoveryEditor? = nil,
        openEditorPrompt: RecoveryOpenEditorPrompt = .default
    ) throws -> UpResult {
        let editor = recoveryEditor ?? RecoveryEditor(environment: localEnv)

        // Discover the host devcontainer.json path up front to build recovery guidance and
        // decide eligibility. When no editable config exists, `up` fails normally (the ordinary
        // bring-up path raises the structured "config not found" error; recovery has nothing to
        // edit). Bind up recovery edits the host config directly — never a helper container or
        // a retained checkout (the config already lives on the host).
        let configPath: String
        do {
            configPath = try ConfigDiscovery.discover(workspacePath: options.workspacePath)
        } catch let error as CLIError where error.code == CLIErrorCode.configNotFound {
            throw error
        } catch {
            return try runBringUp(
                options: options,
                runtime: runtime,
                localEnv: localEnv,
                hostResources: hostResources
            )
        }
        let guidance = BringUpRecovery.Guidance(
            configPath: configPath,
            editCommand: editor.command(for: configPath).map(Self.shellQuoteCommand)
                ?? "recovery editor unavailable",
            retryCommand: upRetryCommand(options: options)
        )

        do {
            return try runBringUp(
                options: options,
                runtime: runtime,
                localEnv: localEnv,
                hostResources: hostResources
            )
        } catch let failure as BringUpRecovery.EligibleFailure {
            let editHost = {
                try editUpConfig(
                    filePath: configPath,
                    workspacePath: options.workspacePath,
                    localEnv: localEnv,
                    editor: editor
                )
            }
            if BringUpRecovery.isNameInUse(failure) {
                return try BringUpRecovery.runNameCollision(
                    failure: failure,
                    guidance: guidance,
                    createName: BringUpRecovery.createName(fromCollision: failure) ?? "",
                    isTTY: isTTY,
                    jsonOutput: options.jsonOutput,
                    prompt: openEditorPrompt,
                    persistName: { try ConfigNameWriter.persistCreateName($0, inFileAt: configPath) },
                    retry: {
                        try runBringUp(
                            options: options,
                            runtime: runtime,
                            localEnv: localEnv,
                            hostResources: hostResources
                        )
                    }
                )
            }
            // Each recoverable retry may report a different leftover. Capture the latest
            // identity so the next runBringUp deletes/recreates that container, not only
            // the one from the first EligibleFailure.
            var resetExistingName = failure.resetExistingName
            return try BringUpRecovery.run(
                failure: failure,
                guidance: guidance,
                isTTY: isTTY,
                jsonOutput: options.jsonOutput,
                openEditorPrompt: openEditorPrompt,
                edit: editHost,
                retry: {
                    do {
                        return try runBringUp(
                            options: options,
                            runtime: runtime,
                            localEnv: localEnv,
                            hostResources: hostResources,
                            resetExistingName: resetExistingName
                        )
                    } catch let next as BringUpRecovery.EligibleFailure {
                        resetExistingName = next.resetExistingName
                        throw next
                    }
                }
            )
        } catch {
            throw error
        }
    }

    /// One full bring-up attempt: resolve from host → reuse/start existing → create path →
    /// finish. Re-entrant: re-resolves from the host workspace on every entry, so a recovery
    /// retry never reuses cached resolved state.
    private static func runBringUp(
        options: UpOptions,
        runtime: AppleContainerRuntime,
        localEnv: [String: String],
        hostResources: any HostResourceProviding,
        resetExistingName: String? = nil
    ) throws -> UpResult {
        StatusPrinter.status("Resolving configuration")
        let resolved: ResolvedWorkspace
        do {
            resolved = try ConfigResolver.resolve(
                workspacePath: options.workspacePath,
                localEnv: localEnv
            )
        } catch let error as CLIError where error.code == CLIErrorCode.configNotFound {
            throw error
        } catch {
            throw BringUpRecovery.eligible(error)
        }

        // hostRequirements: fail up on shortfall/unreadable host; warn gpu; limits applied on create.
        try enforceHostRequirements(config: resolved.config, host: hostResources)

        do {
            try LifecycleRunner.runInitializeCommand(
                config: resolved.config,
                hostWorkspace: resolved.workspacePath
            )
        } catch {
            throw BringUpRecovery.eligible(error)
        }

        let occupants = try runtime.listAll()
        let occupancy = ContainerIdentity.classifyOccupancy(
            desiredName: resolved.containerName,
            containers: occupants,
            workspace: .bind(
                localFolder: resolved.workspacePath,
                configFile: resolved.configPath
            )
        )

        switch occupancy {
        case .sameWorkspaceDifferentName(let leftover):
            throw ContainerIdentity.workspaceExistsError(existingName: leftover.name)
        case .foreign:
            throw BringUpRecovery.eligible(
                ContainerIdentity.nameInUseError(name: resolved.containerName)
            )
        case .none, .sameWorkspaceSameName:
            break
        }

        var existing: ContainerInfo?
        if case .sameWorkspaceSameName(let occupant) = occupancy {
            existing = occupant
        }

        // A stopped existing container may have failed during start, and a running one may
        // have failed during restart postStart. Recovery must not see either as a successful
        // reuse on the next attempt: remove it before entering the fresh create path.
        // Never reset a foreign occupant — only the same-workspace container we own.
        if let existingContainer = existing, let resetExistingName,
           resetExistingName == existingContainer.name || resetExistingName == resolved.containerName
        {
            StatusPrinter.status("Replacing container", item: existingContainer.name)
            do {
                try runtime.delete(nameOrId: existingContainer.id, force: true)
            } catch {
                throw BringUpRecovery.eligible(
                    error,
                    resetExistingName: resetExistingName
                )
            }
            existing = nil
        }

        if let existing {
            let existingHash = existing.labels[ContainerIdentity.labelConfigHash]
            if let existingHash, existingHash != resolved.configHash {
                throw CLIError(
                    code: CLIErrorCode.configHashMismatch,
                    property: ContainerIdentity.labelConfigHash,
                    message: "Existing container config hash does not match current config",
                    hint: "Run 'adevcontainer rebuild' (managed selection: --name or auto) to force-rebuild from current config"
                )
            } else if existing.isRunning {
                // Reuse running: no feature fetch/build; settings+extensions repair on marker drift; postAttach gated after open.
                StatusPrinter.status("Reusing running container", item: existing.name)
                let reuseConfig = configForReuse(resolved.config, labels: existing.labels)
                _ = VSCodeCustomizationsApply.applySettingsIfNeeded(
                    containerId: existing.id,
                    config: reuseConfig,
                    runtime: runtime
                )
                return try finish(
                    options: options,
                    id: existing.id,
                    name: existing.name,
                    config: reuseConfig,
                    image: existing.image ?? resolved.config.image,
                    runtime: runtime
                )
            } else {
                // Start stopped: no rebuild (features already baked on create).
                StatusPrinter.status("Starting container")
                do {
                    try runtime.start(nameOrId: existing.id)
                } catch {
                    throw BringUpRecovery.eligible(
                        error,
                        resetExistingName: existing.name
                    )
                }
                var reuseConfig = configForReuse(resolved.config, labels: existing.labels)
                PostAttachConfigLoader.mergeFeaturePostAttach(
                    into: &reuseConfig,
                    labels: existing.labels,
                    imageRef: existing.image,
                    runtime: runtime
                )
                if LifecycleRunner.resumeShouldWaitForPostStart(reuseConfig.waitFor) {
                    do {
                        try LifecycleRunner.runRestartPostStart(
                            containerId: existing.id,
                            config: reuseConfig,
                            runtime: runtime
                        )
                    } catch {
                        throw BringUpRecovery.eligible(
                            error,
                            resetExistingName: existing.name
                        )
                    }
                    _ = VSCodeCustomizationsApply.applySettingsIfNeeded(
                        containerId: existing.id,
                        config: reuseConfig,
                        runtime: runtime
                    )
                    return try finish(
                        options: options,
                        id: existing.id,
                        name: existing.name,
                        config: reuseConfig,
                        image: existing.image ?? resolved.config.image,
                        runtime: runtime
                    )
                }
                // Create-path waitFor is already satisfied on resume. Ready/open/postAttach
                // fire now; this invocation's postStart still runs afterward.
                _ = VSCodeCustomizationsApply.applySettingsIfNeeded(
                    containerId: existing.id,
                    config: reuseConfig,
                    runtime: runtime
                )
                let result = try finish(
                    options: options,
                    id: existing.id,
                    name: existing.name,
                    config: reuseConfig,
                    image: existing.image ?? resolved.config.image,
                    runtime: runtime
                )
                do {
                    try LifecycleRunner.runRestartPostStart(
                        containerId: existing.id,
                        config: reuseConfig,
                        runtime: runtime
                    )
                } catch {
                    throw BringUpRecovery.eligible(
                        error,
                        resetExistingName: existing.name
                    )
                }
                return result
            }
        }

        // Create path (missing container)
        if !resolved.mountPromotions.isEmpty {
            StatusPrinter.warning(MountNormalizer.warningMessage(promotions: resolved.mountPromotions))
        }

        var effectiveConfig = resolved.config
        let platform = ContainerPlatform.defaultLinuxPlatform
        /// When Features inspected the base image, reuse that USER for connection resolution
        /// (derived final USER matches base after restore).
        var knownOCIUser: String?? = nil
        var knownMetadataUsers: DevContainerMetadataLabel.ImageMetadataUsers? = nil

        if !resolved.config.features.isEmpty {
            // One-time consent to disable BuildKit Rosetta for native arm64 feature image builds.
            if let override = ensureNativeArmBuildOverride {
                try override()
            } else {
                try AppleContainerConfig.ensureNativeArmBuild(runtime: runtime)
            }

            // Pull base image (native platform) before Features build FROM it.
            if !options.skipPull {
                StatusPrinter.status("Pulling image", item: resolved.config.image)
                try? runtime.pullImage(resolved.config.image, platform: platform)
            }
            let fetcher: any FeatureFetching = featuresFetcherOverride
                ?? DefaultFeatureFetcher(workspacePath: resolved.workspacePath)
            let cacheRoot = featuresCacheRootOverride ?? FeatureCache.defaultRoot()
            let deps = FeaturesRunner.Dependencies(
                fetcher: fetcher,
                runtime: runtime,
                cacheRoot: cacheRoot,
                platform: platform
            )
            let nameBase = ContainerIdentity.humanBase(workspacePath: resolved.workspacePath)
            let featuresResult = try FeaturesRunner.run(
                features: resolved.config.features,
                baseImage: resolved.config.image,
                deps: deps,
                remoteUser: resolved.config.remoteUser,
                containerUser: resolved.config.containerUser,
                nameBase: nameBase
            )
            // Create uses derived image; merge runtime contributions from feature metadata.
            effectiveConfig = try FeatureContributionMerge.apply(
                contributions: featuresResult.contributions,
                to: effectiveConfig
            )
            effectiveConfig.image = featuresResult.derivedImage
            if featuresResult.didInspectBaseUser {
                knownOCIUser = featuresResult.baseImageUser
            }
            knownMetadataUsers = featuresResult.metadataUsers
        } else {
            if !options.skipPull {
                StatusPrinter.status("Pulling image", item: effectiveConfig.image)
                try? runtime.pullImage(effectiveConfig.image, platform: platform)
            }
            let applied = try FeatureContributionMerge.applyFromImage(
                imageRef: effectiveConfig.image,
                to: effectiveConfig,
                runtime: runtime
            )
            effectiveConfig = applied.config
            knownMetadataUsers = applied.users
        }

        // Expand `${devcontainerId}` to the bind resource stem, never the DNS create name.
        effectiveConfig = VariableSubstitutor.expandDevcontainerId(
            in: effectiveConfig,
            id: ContainerIdentity.bindResourceIdentityStem(
                workspacePath: resolved.workspacePath,
                configPath: resolved.configPath
            )
        )

        // Resolve connection user (config > metadata > OCI USER > root) before labels/create.
        let connectionUser = try RemoteUserResolution.resolve(
            config: effectiveConfig,
            imageRef: effectiveConfig.image,
            runtime: runtime,
            knownOCIUser: knownOCIUser,
            knownMetadataUsers: knownMetadataUsers
        )
        effectiveConfig = RemoteUserResolution.applyingConnectionUser(connectionUser, to: effectiveConfig)

        var labels = resolved.labels
        labels[ContainerIdentity.labelRemoteUser] = connectionUser
        labels[ContainerIdentity.labelWorkspaceFolder] = effectiveConfig.workspaceFolder

        let request = CreateRequest.from(
            resolved: effectiveConfig,
            identityName: resolved.containerName,
            labels: labels,
            configHash: resolved.configHash,
            workspacePath: resolved.workspacePath,
            platform: platform
        )

        StatusPrinter.status("Creating container", item: resolved.containerName)
        let id: String
        do {
            id = try runtime.create(request: request)
        } catch {
            throw BringUpRecovery.eligible(error)
        }
        StatusPrinter.status("Starting container")
        do {
            try runtime.start(nameOrId: id)
        } catch {
            try? runtime.delete(nameOrId: id, force: true)
            throw BringUpRecovery.eligible(error)
        }

        // Config named volumes mount root:root; chown targets before hooks as connectionUser.
        do {
            try WorkspaceOwnership.ensureNamedVolumeMountsWritableByRemoteUser(
                containerId: id,
                mounts: effectiveConfig.mounts,
                remoteUser: connectionUser,
                runtime: runtime
            )
        } catch {
            try? runtime.delete(nameOrId: id, force: true)
            throw BringUpRecovery.eligible(error)
        }

        do {
            try LifecycleRunner.runCreatePathThroughWaitFor(
                containerId: id,
                config: effectiveConfig,
                runtime: runtime
            )
        } catch {
            throw BringUpRecovery.eligible(error)
        }

        // Settings + Ready / JSON / open / postAttach at the waitFor point.
        // Remaining create-path hooks still run so delete-on-fail and the exit
        // code stay correct; do not emit a later success JSON if they fail.
        var readyError: Error?
        var result: UpResult?
        do {
            _ = VSCodeCustomizationsApply.applySettingsIfNeeded(
                containerId: id,
                config: effectiveConfig,
                runtime: runtime
            )
            result = try finish(
                options: options,
                id: id,
                name: resolved.containerName,
                config: effectiveConfig,
                image: effectiveConfig.image,
                runtime: runtime
            )
        } catch {
            readyError = error
        }

        do {
            try LifecycleRunner.runCreatePathAfterWaitFor(
                containerId: id,
                config: effectiveConfig,
                runtime: runtime
            )
        } catch {
            throw BringUpRecovery.eligible(error)
        }
        if let readyError { throw readyError }
        guard let result else {
            throw CLIError(
                code: CLIErrorCode.internalError,
                message: "up finished waitFor without a result"
            )
        }
        return result
    }

    /// Extensions apply (not flag-gated) → open (optional) → CLI-attach postAttach → Ready
    /// (and `--json` success JSON). Called at the `waitFor` point, not after later hooks.
    /// postAttach is never before open when `--vscode`. Open soft-fail does not skip postAttach.
    /// Extensions never fold into postAttachCommand.
    private static func finish(
        options: UpOptions,
        id: String,
        name: String,
        config: ResolvedDevContainerConfig,
        image: String,
        runtime: AppleContainerRuntime
    ) throws -> UpResult {
        let result = successResult(id: id, name: name, config: config)
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
                image: image,
                remoteWorkspaceFolder: result.remoteWorkspaceFolder,
                containerName: result.containerName ?? name,
                remoteUser: result.remoteUser
            )
        )
        // Reuse/restart never re-runs Features; merge feature postAttach from image metadata.
        var postAttachConfig = config
        PostAttachConfigLoader.mergeFeaturePostAttach(
            into: &postAttachConfig,
            imageRef: image.isEmpty ? nil : image,
            runtime: runtime
        )
        try LifecycleRunner.applyPostAttachGate(
            openOutcome: openOutcome,
            kind: .cliAttach,
            containerId: id,
            config: postAttachConfig,
            runtime: runtime
        )
        // Connection hints are emitted by the entry point after the human outcome digest
        // so the terminal order is: Ready → outcome fields → blank → connect instructions.
        StatusPrinter.status("Ready")
        try SuccessPresentation.emitSuccessJSONIfRequested(
            result.jsonString(),
            jsonOutput: options.jsonOutput
        )
        return result
    }

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

    private static func successResult(
        id: String,
        name: String,
        config: ResolvedDevContainerConfig
    ) -> UpResult {
        UpResult(
            outcome: "success",
            containerId: id,
            remoteUser: config.connectionUser ?? "",
            remoteWorkspaceFolder: config.workspaceFolder,
            containerName: name
        )
    }

    /// Prefer stamped `devcontainer.remote_user` on reuse/start so connection user matches create.
    private static func configForReuse(
        _ config: ResolvedDevContainerConfig,
        labels: [String: String]
    ) -> ResolvedDevContainerConfig {
        if let stamped = RemoteUserResolution.nonEmptyTrimmed(labels[ContainerIdentity.labelRemoteUser]) {
            return RemoteUserResolution.applyingConnectionUser(stamped, to: config)
        }
        return config
    }

    /// Open the host devcontainer.json in the recovery editor, re-opening on invalid content
    /// (validated with bind-mode strict resolve — the explicit host config path, no discovery
    /// fallback) and throwing on terminal attempts.
    private static func editUpConfig(
        filePath: String,
        workspacePath: String,
        localEnv: [String: String],
        editor: RecoveryEditor
    ) throws {
        while true {
            StatusPrinter.status("Opening recovery editor for", item: filePath)
            let attempt = editor.edit(
                filePath: filePath,
                isTTY: true,
                jsonOutput: false,
                validate: { _ in
                    _ = try ConfigResolver.resolve(
                        workspacePath: workspacePath,
                        configPath: filePath,
                        localEnv: localEnv
                    )
                }
            )
            switch attempt {
            case .normalExit:
                return
            case .invalidConfig(let error):
                StatusPrinter.warning(error.message)
                continue
            case .cancelled, .noExecutable, .launchFailed, .failed:
                throw attempt.cliError!
            case .notRun:
                throw CLIError(
                    code: CLIErrorCode.recoveryUnavailable,
                    message: "Recovery editor did not run",
                    hint: "Re-run up on a TTY without --json, or edit the host config and retry"
                )
            }
        }
    }

    private static func shellQuoteCommand(_ args: [String]) -> String {
        args.map(shellQuote).joined(separator: " ")
    }

    private static func upRetryCommand(options: UpOptions) -> String {
        var command = "adevcontainer up --workspace \(shellQuote(options.workspacePath))"
        if options.jsonOutput { command += " --json" }
        if options.skipPull { command += " --skip-pull" }
        if options.openVSCode { command += " --vscode" }
        return command
    }

    private static func shellQuote(_ value: String) -> String {
        "'" + value.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }
}
