import Foundation

public struct UpOptions: Sendable {
    public var workspacePath: String
    public var jsonOutput: Bool
    public var recreate: Bool
    public var skipPull: Bool
    /// Best-effort open of VS Code on the remote workspace after lifecycle success.
    public var openVSCode: Bool

    public init(
        workspacePath: String,
        jsonOutput: Bool = false,
        recreate: Bool = false,
        skipPull: Bool = false,
        openVSCode: Bool = false
    ) {
        self.workspacePath = workspacePath
        self.jsonOutput = jsonOutput
        self.recreate = recreate
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
                if options.recreate {
                    try runtime.delete(nameOrId: existing.id, force: true)
                } else {
                    throw CLIError(
                        code: CLIErrorCode.configHashMismatch,
                        property: ContainerIdentity.labelConfigHash,
                        message: "Existing container config hash does not match current config",
                        hint: "Run 'adevcontainer up --recreate' to delete and recreate, or 'adevcontainer delete' first"
                    )
                }
            } else if options.recreate {
                try runtime.delete(nameOrId: existing.id, force: true)
            } else if existing.isRunning {
                // Reuse running: no feature fetch/build; postAttach gated after open.
                StatusPrinter.status("Reusing running container \(existing.name)")
                return try finish(
                    options: options,
                    id: existing.id,
                    name: existing.name,
                    config: resolved.config,
                    image: existing.image ?? resolved.config.image,
                    runtime: runtime
                )
            } else {
                // Start stopped: no rebuild (features already baked on create).
                StatusPrinter.status("Starting container")
                try runtime.start(nameOrId: existing.id)
                try LifecycleRunner.runRestartPostStart(
                    containerId: existing.id,
                    config: resolved.config,
                    runtime: runtime
                )
                return try finish(
                    options: options,
                    id: existing.id,
                    name: existing.name,
                    config: resolved.config,
                    image: existing.image ?? resolved.config.image,
                    runtime: runtime
                )
            }
        }

        // Create path (missing or just deleted for recreate)
        if !resolved.mountPromotions.isEmpty {
            fputs(MountNormalizer.warningMessage(promotions: resolved.mountPromotions) + "\n", stderr)
        }

        var effectiveConfig = resolved.config
        let platform = ContainerPlatform.defaultLinuxPlatform

        if !resolved.config.features.isEmpty {
            // One-time consent to disable BuildKit Rosetta for native arm64 feature image builds.
            if let override = ensureNativeArmBuildOverride {
                try override()
            } else {
                try AppleContainerConfig.ensureNativeArmBuild(runtime: runtime)
            }

            // Pull base image (native platform) before Features build FROM it.
            if !options.skipPull {
                StatusPrinter.status("Pulling image \(resolved.config.image)")
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
        } else if !options.skipPull {
            StatusPrinter.status("Pulling image \(effectiveConfig.image)")
            try? runtime.pullImage(effectiveConfig.image, platform: platform)
        }

        let request = CreateRequest.from(
            resolved: effectiveConfig,
            identityName: resolved.containerName,
            labels: resolved.labels,
            configHash: resolved.configHash,
            workspacePath: resolved.workspacePath,
            platform: platform
        )

        StatusPrinter.status("Creating container \(resolved.containerName)")
        let id = try runtime.create(request: request)
        StatusPrinter.status("Starting container")
        do {
            try runtime.start(nameOrId: id)
        } catch {
            try? runtime.delete(nameOrId: id, force: true)
            throw error
        }

        try LifecycleRunner.runCreatePath(
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

    /// Open (optional) → postAttach gate → Ready. postAttach is never before open when `--vscode`.
    private static func finish(
        options: UpOptions,
        id: String,
        name: String,
        config: ResolvedDevContainerConfig,
        image: String,
        runtime: AppleContainerRuntime
    ) throws -> UpResult {
        let result = successResult(id: id, name: name, config: config)
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
            remoteUser: config.effectiveUser ?? "",
            remoteWorkspaceFolder: config.workspaceFolder,
            containerName: name
        )
    }
}
