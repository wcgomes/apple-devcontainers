import Foundation

/// Lifecycle command as string or argv array.
public enum LifecycleCommand: Equatable, Sendable {
    case shell(String)
    case argv([String])

    public static func parse(_ value: Any?, property: String) throws -> LifecycleCommand? {
        guard let value else { return nil }
        if let s = value as? String {
            return .shell(s)
        }
        if let arr = value as? [Any] {
            let parts = try arr.map { item -> String in
                guard let s = item as? String else {
                    throw CLIError(
                        code: CLIErrorCode.unsupportedProperty,
                        property: property,
                        message: "\(property) array entries must be strings"
                    )
                }
                return s
            }
            guard !parts.isEmpty else {
                throw CLIError(
                    code: CLIErrorCode.unsupportedProperty,
                    property: property,
                    message: "\(property) array must not be empty"
                )
            }
            return .argv(parts)
        }
        throw CLIError(
            code: CLIErrorCode.unsupportedProperty,
            property: property,
            message: "\(property) must be a string or array of strings"
        )
    }

    /// Arguments for `container exec` after container id.
    public var execArguments: [String] {
        switch self {
        case .shell(let cmd):
            return ["sh", "-lc", cmd]
        case .argv(let args):
            return args
        }
    }

    /// Stable encoding for config hash material.
    public var hashEncoding: Any {
        switch self {
        case .shell(let s): return s
        case .argv(let a): return a
        }
    }
}

/// Fully resolved devcontainer config ready for runtime mapping.
public struct ResolvedDevContainerConfig: Equatable {
    public var name: String?
    public var image: String
    public var containerEnv: [String: String]
    public var remoteUser: String?
    public var containerUser: String?
    public var workspaceFolder: String
    public var mounts: [MountSpec]
    public var forwardPorts: [Int]
    public var portsAttributes: [String: [String: String]]
    public var postCreateCommand: LifecycleCommand?
    public var onCreateCommand: LifecycleCommand?
    public var updateContentCommand: LifecycleCommand?
    public var postStartCommand: LifecycleCommand?
    public var postAttachCommand: LifecycleCommand?
    /// Allowlisted runArgs mapped onto create argv.
    public var runArgs: [AllowlistedRunArg]
    /// Evaluated hostRequirements (nil when absent).
    public var hostRequirements: HostRequirements?
    /// Present when config included customizations.vscode (metadata only; not Sendable JSON).
    public var hasVscodeCustomizations: Bool
    /// Admitted OCI features (empty = no Features runner work).
    public var features: [AdmittedFeature]
    /// Extra lifecycle hooks contributed by features (run after config hooks per stage).
    public var featureOnCreateCommands: [LifecycleCommand]
    public var featureUpdateContentCommands: [LifecycleCommand]
    public var featurePostCreateCommands: [LifecycleCommand]
    public var featurePostStartCommands: [LifecycleCommand]
    public var featurePostAttachCommands: [LifecycleCommand]

    public init(
        name: String? = nil,
        image: String,
        containerEnv: [String: String] = [:],
        remoteUser: String? = nil,
        containerUser: String? = nil,
        workspaceFolder: String,
        mounts: [MountSpec] = [],
        forwardPorts: [Int] = [],
        portsAttributes: [String: [String: String]] = [:],
        postCreateCommand: LifecycleCommand? = nil,
        onCreateCommand: LifecycleCommand? = nil,
        updateContentCommand: LifecycleCommand? = nil,
        postStartCommand: LifecycleCommand? = nil,
        postAttachCommand: LifecycleCommand? = nil,
        runArgs: [AllowlistedRunArg] = [],
        hostRequirements: HostRequirements? = nil,
        hasVscodeCustomizations: Bool = false,
        features: [AdmittedFeature] = [],
        featureOnCreateCommands: [LifecycleCommand] = [],
        featureUpdateContentCommands: [LifecycleCommand] = [],
        featurePostCreateCommands: [LifecycleCommand] = [],
        featurePostStartCommands: [LifecycleCommand] = [],
        featurePostAttachCommands: [LifecycleCommand] = []
    ) {
        self.name = name
        self.image = image
        self.containerEnv = containerEnv
        self.remoteUser = remoteUser
        self.containerUser = containerUser
        self.workspaceFolder = workspaceFolder
        self.mounts = mounts
        self.forwardPorts = forwardPorts
        self.portsAttributes = portsAttributes
        self.postCreateCommand = postCreateCommand
        self.onCreateCommand = onCreateCommand
        self.updateContentCommand = updateContentCommand
        self.postStartCommand = postStartCommand
        self.postAttachCommand = postAttachCommand
        self.runArgs = runArgs
        self.hostRequirements = hostRequirements
        self.hasVscodeCustomizations = hasVscodeCustomizations
        self.features = features
        self.featureOnCreateCommands = featureOnCreateCommands
        self.featureUpdateContentCommands = featureUpdateContentCommands
        self.featurePostCreateCommands = featurePostCreateCommands
        self.featurePostStartCommands = featurePostStartCommands
        self.featurePostAttachCommands = featurePostAttachCommands
    }

    public var effectiveUser: String? {
        // Prefer remoteUser for exec/attach semantics; fall back to containerUser.
        if let remoteUser, !remoteUser.isEmpty { return remoteUser }
        if let containerUser, !containerUser.isEmpty { return containerUser }
        return nil
    }

    /// Fields used for config hash / drift detection.
    public func hashMaterial() -> [String: Any] {
        var m: [String: Any] = [
            "image": image,
            "workspaceFolder": workspaceFolder,
            "containerEnv": containerEnv,
            "forwardPorts": forwardPorts.map { $0 as Any },
            "mounts": mounts.map { mount -> [String: Any] in
                [
                    "type": mount.type.rawValue,
                    "source": mount.source,
                    "target": mount.target,
                    "readonly": mount.readonly
                ]
            }
        ]
        if let remoteUser { m["remoteUser"] = remoteUser }
        if let containerUser { m["containerUser"] = containerUser }
        if let onCreateCommand { m["onCreateCommand"] = onCreateCommand.hashEncoding }
        if let updateContentCommand { m["updateContentCommand"] = updateContentCommand.hashEncoding }
        if let postCreateCommand { m["postCreateCommand"] = postCreateCommand.hashEncoding }
        if let postStartCommand { m["postStartCommand"] = postStartCommand.hashEncoding }
        // postAttach does not affect create identity; omit from hash.
        if !runArgs.isEmpty {
            m["runArgs"] = runArgs.map { $0.hashEncoding as Any }
        }
        // hostRequirements memory/cpus affect create limits; include when set.
        if let hostRequirements {
            if let memoryBytes = hostRequirements.memoryBytes {
                m["hostRequirements.memoryBytes"] = memoryBytes
            }
            if let cpus = hostRequirements.cpus {
                m["hostRequirements.cpus"] = cpus
            }
        }
        // portsAttributes are metadata; include for inspect consistency
        if !portsAttributes.isEmpty {
            m["portsAttributes"] = portsAttributes
        }
        // Features participate in identity hash (refs + options).
        if !features.isEmpty {
            m["features"] = features.map { $0.hashMaterial }
        }
        return m
    }
}
