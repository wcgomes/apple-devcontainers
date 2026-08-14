import Foundation

/// Merged runtime contributions from features (+ optional image metadata label).
public struct FeatureContributions: Equatable, Sendable {
    public var initProcess: Bool
    public var capAdd: [String]
    public var containerEnv: [String: String]
    public var mounts: [MountSpec]
    public var onCreateCommands: [LifecycleCommand]
    public var updateContentCommands: [LifecycleCommand]
    public var postCreateCommands: [LifecycleCommand]
    public var postStartCommands: [LifecycleCommand]
    public var postAttachCommands: [LifecycleCommand]

    public init(
        initProcess: Bool = false,
        capAdd: [String] = [],
        containerEnv: [String: String] = [:],
        mounts: [MountSpec] = [],
        onCreateCommands: [LifecycleCommand] = [],
        updateContentCommands: [LifecycleCommand] = [],
        postCreateCommands: [LifecycleCommand] = [],
        postStartCommands: [LifecycleCommand] = [],
        postAttachCommands: [LifecycleCommand] = []
    ) {
        self.initProcess = initProcess
        self.capAdd = capAdd
        self.containerEnv = containerEnv
        self.mounts = mounts
        self.onCreateCommands = onCreateCommands
        self.updateContentCommands = updateContentCommands
        self.postCreateCommands = postCreateCommands
        self.postStartCommands = postStartCommands
        self.postAttachCommands = postAttachCommands
    }

    public static let empty = FeatureContributions()
}

public enum FeatureContributionMerge {
    /// Collect contributions from ordered features (privileged/securityOpt already warn-stripped).
    public static func collect(from ordered: [FeatureOrder.OrderedFeature]) throws -> FeatureContributions {
        var result = FeatureContributions()
        for f in ordered {
            let meta = f.metadata
            if meta.initProcess { result.initProcess = true }
            for cap in meta.capAdd {
                if !result.capAdd.contains(cap) {
                    result.capAdd.append(cap)
                }
            }
            // Feature env first; config wins later at apply time.
            for (k, v) in meta.containerEnv {
                if result.containerEnv[k] == nil {
                    result.containerEnv[k] = v
                }
            }
            result.mounts.append(contentsOf: meta.mounts)
            if let c = meta.onCreateCommand { result.onCreateCommands.append(c) }
            if let c = meta.updateContentCommand { result.updateContentCommands.append(c) }
            if let c = meta.postCreateCommand { result.postCreateCommands.append(c) }
            if let c = meta.postStartCommand { result.postStartCommands.append(c) }
            if let c = meta.postAttachCommand { result.postAttachCommands.append(c) }
        }
        return result
    }

    /// Merge feature contributions into resolved config.
    /// - containerEnv: **config wins** on key conflict
    /// - runArgs: add `--init` and allowlisted `--cap-add` when not already present
    /// - mounts: append feature mounts (caller may normalize)
    /// - lifecycle: feature hooks stored as additional arrays on config
    public static func apply(
        contributions: FeatureContributions,
        to config: ResolvedDevContainerConfig,
        fileManager: FileManager = .default
    ) throws -> ResolvedDevContainerConfig {
        var out = config

        // Env: feature base, config overwrites
        var env = contributions.containerEnv
        for (k, v) in config.containerEnv {
            env[k] = v
        }
        out.containerEnv = env

        // Mounts
        var mounts = config.mounts
        mounts.append(contentsOf: contributions.mounts)
        let normalized = MountNormalizer.normalize(mounts: mounts, fileManager: fileManager)
        out.mounts = normalized.mounts

        // runArgs: init + capAdd via allowlist path
        var runArgs = config.runArgs
        if contributions.initProcess, !runArgs.contains(.initFlag) {
            runArgs.append(.initFlag)
        }
        for cap in contributions.capAdd {
            // Validate through the same allowlist rules as runArgs --cap-add
            guard isValidCapabilityName(cap) else {
                throw CLIError(
                    code: CLIErrorCode.unsupportedFeature,
                    property: "features",
                    message: "Feature capAdd '\(cap)' is not a valid capability name",
                    hint: "Use standard Linux capability names (e.g. SYS_PTRACE)"
                )
            }
            if !runArgs.contains(.capAdd(cap)) {
                runArgs.append(.capAdd(cap))
            }
        }
        out.runArgs = runArgs

        out.featureOnCreateCommands = contributions.onCreateCommands
        out.featureUpdateContentCommands = contributions.updateContentCommands
        out.featurePostCreateCommands = contributions.postCreateCommands
        out.featurePostStartCommands = contributions.postStartCommands
        out.featurePostAttachCommands = contributions.postAttachCommands

        return out
    }

    /// Apply base-image `devcontainer.metadata` when Features did not run (empty features).
    public static func applyFromImage(
        imageRef: String,
        to config: ResolvedDevContainerConfig,
        runtime: AppleContainerRuntime
    ) throws -> (config: ResolvedDevContainerConfig, users: DevContainerMetadataLabel.ImageMetadataUsers) {
        let loaded = DevContainerMetadataLabel.loadContributions(imageRef: imageRef, runtime: runtime)
        guard loaded.contributions != .empty else {
            return (config, loaded.users)
        }
        return (try apply(contributions: loaded.contributions, to: config), loaded.users)
    }

    private static func isValidCapabilityName(_ name: String) -> Bool {
        !name.isEmpty && !name.hasPrefix("-")
    }
}
