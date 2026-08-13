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
        hostResources: any HostResourceProviding = SystemHostResourceInfo()
    ) throws -> UpResult {
        StatusPrinter.status("Resolving configuration")
        let resolved = try ConfigResolver.resolve(
            workspacePath: options.workspacePath,
            localEnv: localEnv
        )

        // hostRequirements: fail up on shortfall/unreadable host; warn gpu; limits applied on create.
        try enforceHostRequirements(config: resolved.config, host: hostResources)

        let existing = try runtime.findByName(resolved.containerName)

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
                try runtime.start(nameOrId: existing.id)
                let reuseConfig = configForReuse(resolved.config, labels: existing.labels)
                try LifecycleRunner.runRestartPostStart(
                    containerId: existing.id,
                    config: reuseConfig,
                    runtime: runtime
                )
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
            let nameBase = ContainerIdentity.humanBase(
                configName: resolved.config.name,
                workspacePath: resolved.workspacePath
            )
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
        } else if !options.skipPull {
            StatusPrinter.status("Pulling image", item: effectiveConfig.image)
            try? runtime.pullImage(effectiveConfig.image, platform: platform)
        }

        // Expand `${devcontainerId}` in feature/config mounts before volume ensure + create.
        effectiveConfig = VariableSubstitutor.expandDevcontainerId(
            in: effectiveConfig,
            id: resolved.containerName
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
        let id = try runtime.create(request: request)
        StatusPrinter.status("Starting container")
        do {
            try runtime.start(nameOrId: id)
        } catch {
            try? runtime.delete(nameOrId: id, force: true)
            throw error
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
            throw error
        }

        try LifecycleRunner.runCreatePath(
            containerId: id,
            config: effectiveConfig,
            runtime: runtime
        )

        // Settings apply after create-path hooks; not gated on --vscode.
        _ = VSCodeCustomizationsApply.applySettingsIfNeeded(
            containerId: id,
            config: effectiveConfig,
            runtime: runtime
        )

        return try finish(
            options: options,
            id: id,
            name: resolved.containerName,
            config: effectiveConfig,
            image: effectiveConfig.image,
            runtime: runtime
        )
    }

    /// Extensions apply (not flag-gated) → open (optional) → postAttach gate → Ready.
    /// postAttach is never before open when `--vscode`. Extensions never fold into postAttachCommand.
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
            containerId: id,
            config: postAttachConfig,
            runtime: runtime
        )
        // Connection hints are emitted by the entry point after the human outcome digest
        // so the terminal order is: Ready → outcome fields → blank → connect instructions.
        StatusPrinter.status("Ready")
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
}
