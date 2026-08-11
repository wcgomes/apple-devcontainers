import Foundation

/// Parsed `devcontainer-feature.json` metadata.
public struct FeatureMetadata: Equatable, Sendable {
    public var id: String
    public var version: String?
    public var name: String?
    public var description: String?
    /// dependsOn: feature ref → options object (options ignored for order; presence matters).
    public var dependsOn: [String: [String: FeatureOptionValue]]
    public var installsAfter: [String]
    public var initProcess: Bool
    public var privileged: Bool
    public var securityOpt: [String]
    public var capAdd: [String]
    public var containerEnv: [String: String]
    public var mounts: [MountSpec]
    public var onCreateCommand: LifecycleCommand?
    public var updateContentCommand: LifecycleCommand?
    public var postCreateCommand: LifecycleCommand?
    public var postStartCommand: LifecycleCommand?
    public var postAttachCommand: LifecycleCommand?
    /// Declared option schemas (defaults applied when user omits).
    public var optionDefaults: [String: FeatureOptionValue]

    public init(
        id: String,
        version: String? = nil,
        name: String? = nil,
        description: String? = nil,
        dependsOn: [String: [String: FeatureOptionValue]] = [:],
        installsAfter: [String] = [],
        initProcess: Bool = false,
        privileged: Bool = false,
        securityOpt: [String] = [],
        capAdd: [String] = [],
        containerEnv: [String: String] = [:],
        mounts: [MountSpec] = [],
        onCreateCommand: LifecycleCommand? = nil,
        updateContentCommand: LifecycleCommand? = nil,
        postCreateCommand: LifecycleCommand? = nil,
        postStartCommand: LifecycleCommand? = nil,
        postAttachCommand: LifecycleCommand? = nil,
        optionDefaults: [String: FeatureOptionValue] = [:]
    ) {
        self.id = id
        self.version = version
        self.name = name
        self.description = description
        self.dependsOn = dependsOn
        self.installsAfter = installsAfter
        self.initProcess = initProcess
        self.privileged = privileged
        self.securityOpt = securityOpt
        self.capAdd = capAdd
        self.containerEnv = containerEnv
        self.mounts = mounts
        self.onCreateCommand = onCreateCommand
        self.updateContentCommand = updateContentCommand
        self.postCreateCommand = postCreateCommand
        self.postStartCommand = postStartCommand
        self.postAttachCommand = postAttachCommand
        self.optionDefaults = optionDefaults
    }

    public static func parse(data: Data, featureRef: String) throws -> FeatureMetadata {
        let obj: Any
        do {
            obj = try JSONSerialization.jsonObject(with: data, options: [.fragmentsAllowed])
        } catch {
            throw CLIError(
                code: CLIErrorCode.featureMetadata,
                property: "features",
                message: "Feature '\(featureRef)' has invalid devcontainer-feature.json: \(error.localizedDescription)",
                hint: "Ensure the feature artifact contains valid JSON metadata"
            )
        }
        guard let dict = obj as? [String: Any] else {
            throw CLIError(
                code: CLIErrorCode.featureMetadata,
                property: "features",
                message: "Feature '\(featureRef)' devcontainer-feature.json must be an object",
                hint: "Ensure the feature artifact root includes valid metadata"
            )
        }
        return try parse(dict, featureRef: featureRef)
    }

    public static func parse(_ dict: [String: Any], featureRef: String) throws -> FeatureMetadata {
        let id: String
        if let s = dict["id"] as? String, !s.isEmpty {
            id = s
        } else {
            id = FeatureRef.featureId(from: featureRef)
        }

        var dependsOn: [String: [String: FeatureOptionValue]] = [:]
        if let dep = dict["dependsOn"] as? [String: Any] {
            for (k, v) in dep {
                var opts: [String: FeatureOptionValue] = [:]
                if let o = v as? [String: Any] {
                    for (ok, ov) in o {
                        if let parsed = FeatureOptionValue(json: ov) {
                            opts[ok] = parsed
                        }
                    }
                }
                dependsOn[k] = opts
            }
        }

        var installsAfter: [String] = []
        if let arr = dict["installsAfter"] as? [Any] {
            installsAfter = arr.compactMap { $0 as? String }
        }

        let privileged = boolValue(dict["privileged"]) ?? false
        var securityOpt: [String] = []
        if let arr = dict["securityOpt"] as? [Any] {
            securityOpt = arr.compactMap { $0 as? String }
        } else if let s = dict["securityOpt"] as? String {
            securityOpt = [s]
        }

        var capAdd: [String] = []
        if let arr = dict["capAdd"] as? [Any] {
            capAdd = arr.compactMap { $0 as? String }
        }

        var containerEnv: [String: String] = [:]
        if let env = dict["containerEnv"] as? [String: Any] {
            for (k, v) in env {
                if let s = v as? String {
                    containerEnv[k] = s
                } else if let n = v as? NSNumber {
                    containerEnv[k] = "\(n)"
                }
            }
        }

        var mounts: [MountSpec] = []
        if let rawMounts = dict["mounts"] {
            mounts = try MountParser.parse(rawMounts)
        }

        var optionDefaults: [String: FeatureOptionValue] = [:]
        if let options = dict["options"] as? [String: Any] {
            for (name, schema) in options {
                guard let schemaObj = schema as? [String: Any] else { continue }
                if let def = schemaObj["default"], let parsed = FeatureOptionValue(json: def) {
                    optionDefaults[name] = parsed
                }
            }
        }

        return FeatureMetadata(
            id: id,
            version: dict["version"] as? String,
            name: dict["name"] as? String,
            description: dict["description"] as? String,
            dependsOn: dependsOn,
            installsAfter: installsAfter,
            initProcess: boolValue(dict["init"]) ?? false,
            privileged: privileged,
            securityOpt: securityOpt,
            capAdd: capAdd,
            containerEnv: containerEnv,
            mounts: mounts,
            onCreateCommand: try LifecycleCommand.parse(dict["onCreateCommand"], property: "onCreateCommand"),
            updateContentCommand: try LifecycleCommand.parse(dict["updateContentCommand"], property: "updateContentCommand"),
            postCreateCommand: try LifecycleCommand.parse(dict["postCreateCommand"], property: "postCreateCommand"),
            postStartCommand: try LifecycleCommand.parse(dict["postStartCommand"], property: "postStartCommand"),
            postAttachCommand: try LifecycleCommand.parse(dict["postAttachCommand"], property: "postAttachCommand"),
            optionDefaults: optionDefaults
        )
    }

    /// Warn-and-strip privileged / securityOpt contributions (feature may still install).
    public func warnStripUnsafeContributions(featureRef: String) {
        if privileged {
            StatusPrinter.warning(
                "Feature '\(featureRef)' sets privileged: true; ignored (not applied on Apple container)"
            )
        }
        if !securityOpt.isEmpty {
            StatusPrinter.warning(
                "Feature '\(featureRef)' sets securityOpt; ignored (not applied on Apple container)"
            )
        }
    }

    private static func boolValue(_ any: Any?) -> Bool? {
        if let b = any as? Bool { return b }
        return nil
    }
}
