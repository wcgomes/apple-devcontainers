import Foundation

/// One entry in a lifecycle object-map (name → leaf command).
public struct NamedLifecycleCommand: Equatable, Sendable {
    public var name: String
    public var command: LifecycleCommand

    public init(name: String, command: LifecycleCommand) {
        self.name = name
        self.command = command
    }
}

/// Lifecycle command as string, argv array, or named object map (Dev Containers forms).
public enum LifecycleCommand: Equatable, Sendable {
    case shell(String)
    case argv([String])
    /// Object form: name → string or argv. Named entries run concurrently.
    case parallel([NamedLifecycleCommand])

    public static func parse(_ value: Any?, property: String) throws -> LifecycleCommand? {
        guard let value else { return nil }
        if let s = value as? String {
            return .shell(s)
        }
        if let arr = value as? [Any] {
            return try parseArgv(arr, property: property)
        }
        if let dict = value as? [String: Any] {
            if dict.isEmpty { return nil }
            var named: [NamedLifecycleCommand] = []
            for key in dict.keys.sorted() {
                let leaf = try parseLeaf(dict[key]!, property: "\(property).\(key)")
                named.append(NamedLifecycleCommand(name: key, command: leaf))
            }
            return .parallel(named)
        }
        throw CLIError(
            code: CLIErrorCode.unsupportedProperty,
            property: property,
            message: "\(property) must be a string, array of strings, or object of named commands"
        )
    }

    /// Leaf forms only (string or argv) — used for object-map values (no nested objects).
    private static func parseLeaf(_ value: Any, property: String) throws -> LifecycleCommand {
        if let s = value as? String {
            return .shell(s)
        }
        if let arr = value as? [Any] {
            return try parseArgv(arr, property: property)
        }
        throw CLIError(
            code: CLIErrorCode.unsupportedProperty,
            property: property,
            message: "\(property) must be a string or array of strings"
        )
    }

    private static func parseArgv(_ arr: [Any], property: String) throws -> LifecycleCommand {
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

    /// Arguments for `container exec` after container id. Only valid for leaf forms (shell/argv).
    public var execArguments: [String] {
        switch self {
        case .shell(let cmd):
            return ["sh", "-lc", cmd]
        case .argv(let args):
            return args
        case .parallel:
            return []
        }
    }

    /// Stable encoding for config hash material.
    public var hashEncoding: Any {
        switch self {
        case .shell(let s): return s
        case .argv(let a): return a
        case .parallel(let named):
            var d: [String: Any] = [:]
            for entry in named {
                d[entry.name] = entry.command.hashEncoding
            }
            return d
        }
    }
}

/// Official `waitFor` stage (omitted → `updateContentCommand`).
public enum WaitFor: String, Equatable, Sendable {
    case initializeCommand
    case onCreateCommand
    case updateContentCommand
    case postCreateCommand
    case postStartCommand

    public static let officialDefault = WaitFor.updateContentCommand

    /// Host initialize through postCreate — already satisfied on reuse / resume.
    public var isCreatePathStage: Bool {
        self != .postStartCommand
    }

    /// Inclusive index into in-container create-path stages
    /// (`onCreate` = 0 … `postStart` = 3). Host `initializeCommand` is `-1`
    /// (already finished before `runCreatePath`).
    public var createPathInclusiveIndex: Int {
        switch self {
        case .initializeCommand: return -1
        case .onCreateCommand: return 0
        case .updateContentCommand: return 1
        case .postCreateCommand: return 2
        case .postStartCommand: return 3
        }
    }

    public static func parse(_ value: Any?, property: String = "waitFor") throws -> WaitFor {
        guard let value else { return officialDefault }
        guard let raw = value as? String else {
            throw CLIError(
                code: CLIErrorCode.unsupportedProperty,
                property: property,
                message: "\(property) must be a string",
                hint: "Use initializeCommand, onCreateCommand, updateContentCommand, postCreateCommand, or postStartCommand"
            )
        }
        guard let parsed = WaitFor(rawValue: raw) else {
            throw CLIError(
                code: CLIErrorCode.unsupportedProperty,
                property: property,
                message: "Unknown \(property) value '\(raw)'",
                hint: "Use initializeCommand, onCreateCommand, updateContentCommand, postCreateCommand, or postStartCommand"
            )
        }
        return parsed
    }
}

/// Official `userEnvProbe` (omitted → `loginInteractiveShell`).
public enum UserEnvProbe: String, Equatable, Sendable {
    case none
    case interactiveShell
    case loginShell
    case loginInteractiveShell

    public static let officialDefault = UserEnvProbe.loginInteractiveShell

    /// `sh` dash-options for the probe (`-ic` / `-lc` / `-lic`). Nil when probing is skipped.
    public var shellDashOptions: String? {
        switch self {
        case .none: return nil
        case .interactiveShell: return "-ic"
        case .loginShell: return "-lc"
        case .loginInteractiveShell: return "-lic"
        }
    }

    public static func parse(_ value: Any?, property: String = "userEnvProbe") throws -> UserEnvProbe {
        guard let value else { return officialDefault }
        guard let raw = value as? String else {
            throw CLIError(
                code: CLIErrorCode.unsupportedProperty,
                property: property,
                message: "\(property) must be a string",
                hint: "Use none, interactiveShell, loginShell, or loginInteractiveShell"
            )
        }
        guard let parsed = UserEnvProbe(rawValue: raw) else {
            throw CLIError(
                code: CLIErrorCode.unsupportedProperty,
                property: property,
                message: "Unknown \(property) value '\(raw)'",
                hint: "Use none, interactiveShell, loginShell, or loginInteractiveShell"
            )
        }
        return parsed
    }
}

/// Official `shutdownAction` for this image product (omitted → `stopContainer`).
/// `stopCompose` is rejected at parse (Compose unsupported).
public enum ShutdownAction: String, Equatable, Sendable {
    case none
    case stopContainer

    public static let officialDefault = ShutdownAction.stopContainer

    public static func parse(_ value: Any?, property: String = "shutdownAction") throws -> ShutdownAction {
        guard let value else { return officialDefault }
        guard let raw = value as? String else {
            throw CLIError(
                code: CLIErrorCode.unsupportedProperty,
                property: property,
                message: "\(property) must be a string",
                hint: "Use stopContainer or none"
            )
        }
        if raw == "stopCompose" {
            throw CLIError(
                code: CLIErrorCode.unsupportedProperty,
                property: property,
                message: "Docker Compose configuration is not supported",
                hint: "Use \"shutdownAction\": \"stopContainer\" or \"none\" — Compose is not supported"
            )
        }
        guard let parsed = ShutdownAction(rawValue: raw) else {
            throw CLIError(
                code: CLIErrorCode.unsupportedProperty,
                property: property,
                message: "Unknown \(property) value '\(raw)'",
                hint: "Use stopContainer or none"
            )
        }
        return parsed
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
    public var initializeCommand: LifecycleCommand?
    public var waitFor: WaitFor
    public var userEnvProbe: UserEnvProbe
    public var shutdownAction: ShutdownAction
    /// Allowlisted runArgs mapped onto create argv.
    public var runArgs: [AllowlistedRunArg]
    /// Evaluated hostRequirements (nil when absent).
    public var hostRequirements: HostRequirements?
    /// Present when config included `customizations.vscode` (intent flag; nested shapes may be empty).
    public var hasVscodeCustomizations: Bool
    /// Normalized string extension IDs from `customizations.vscode.extensions` (empty = none / soft-skip).
    public var vscodeExtensions: [String]
    /// Canonical JSON object bytes for `customizations.vscode.settings` (`{}` when absent/empty/soft-skip).
    public var vscodeSettingsJSON: Data
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
        initializeCommand: LifecycleCommand? = nil,
        waitFor: WaitFor = .updateContentCommand,
        userEnvProbe: UserEnvProbe = .loginInteractiveShell,
        shutdownAction: ShutdownAction = .stopContainer,
        runArgs: [AllowlistedRunArg] = [],
        hostRequirements: HostRequirements? = nil,
        hasVscodeCustomizations: Bool = false,
        vscodeExtensions: [String] = [],
        vscodeSettingsJSON: Data = Data("{}".utf8),
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
        self.initializeCommand = initializeCommand
        self.waitFor = waitFor
        self.userEnvProbe = userEnvProbe
        self.shutdownAction = shutdownAction
        self.runArgs = runArgs
        self.hostRequirements = hostRequirements
        self.hasVscodeCustomizations = hasVscodeCustomizations
        self.vscodeExtensions = vscodeExtensions
        self.vscodeSettingsJSON = vscodeSettingsJSON
        self.features = features
        self.featureOnCreateCommands = featureOnCreateCommands
        self.featureUpdateContentCommands = featureUpdateContentCommands
        self.featurePostCreateCommands = featurePostCreateCommands
        self.featurePostStartCommands = featurePostStartCommands
        self.featurePostAttachCommands = featurePostAttachCommands
    }

    /// True when there is any applyable vscode customizations payload (extensions and/or non-empty settings).
    public var hasApplyableVscodeCustomizations: Bool {
        !vscodeExtensions.isEmpty || Self.settingsObjectHasKeys(vscodeSettingsJSON)
    }

    /// Settings JSON parses as an object with at least one key.
    public static func settingsObjectHasKeys(_ data: Data) -> Bool {
        guard let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return false
        }
        return !obj.isEmpty
    }

    /// Config-only remote connection user (`remoteUser` > `containerUser`).
    /// Does **not** include OCI USER or `root` fallback — use `RemoteUserResolution` on create.
    public var connectionUserFromConfig: String? {
        RemoteUserResolution.fromConfig(remoteUser: remoteUser, containerUser: containerUser)
    }

    /// Create process user for `container create -u`.
    /// Explicit `containerUser` wins; else non-root connection user (`remoteUser` after resolution stamp).
    /// See `RemoteUserResolution.createProcessUser`.
    public var createProcessUser: String? {
        RemoteUserResolution.createProcessUser(
            containerUser: containerUser,
            connectionUser: remoteUser ?? connectionUserFromConfig
        )
    }

    /// Connection-oriented user from config (`remoteUser` > `containerUser`).
    /// Prefer this (or a fully resolved stamp) for exec/hooks/VS Code.
    /// Create `-u` uses `createProcessUser` (explicit containerUser, else non-root connection).
    public var effectiveUser: String? {
        connectionUserFromConfig
    }

    /// Alias used by lifecycle / customizations after create-path resolution stamps `remoteUser`.
    public var connectionUser: String? {
        connectionUserFromConfig
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
        if let initializeCommand { m["initializeCommand"] = initializeCommand.hashEncoding }
        if waitFor != .updateContentCommand { m["waitFor"] = waitFor.rawValue }
        if userEnvProbe != .loginInteractiveShell { m["userEnvProbe"] = userEnvProbe.rawValue }
        // postAttach / shutdownAction do not affect create identity; omit from hash.
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
        // customizations.vscode (extensions/settings) intentionally omitted — apply uses guest marker.
        return m
    }
}
