import Foundation

public struct ResolvedWorkspace: Equatable {
    public var workspacePath: String
    public var configPath: String
    public var config: ResolvedDevContainerConfig
    public var configHash: String
    public var containerName: String
    public var labels: [String: String]
    /// File binds rewritten to parent directories (Apple container).
    public var mountPromotions: [MountNormalizer.Promotion]

    public init(
        workspacePath: String,
        configPath: String,
        config: ResolvedDevContainerConfig,
        configHash: String,
        containerName: String,
        labels: [String: String],
        mountPromotions: [MountNormalizer.Promotion] = []
    ) {
        self.workspacePath = workspacePath
        self.configPath = configPath
        self.config = config
        self.configHash = configHash
        self.containerName = containerName
        self.labels = labels
        self.mountPromotions = mountPromotions
    }
}

public enum ConfigResolver {
    public static func resolve(
        workspacePath: String,
        configPath: String? = nil,
        localEnv: [String: String] = ProcessInfo.processInfo.environment,
        fileManager: FileManager = .default,
        /// When set (e.g. clone), default `/workspaces/<basename>` and
        /// `${localWorkspaceFolderBasename}` use this instead of the host path basename.
        workspaceFolderBasename: String? = nil
    ) throws -> ResolvedWorkspace {
        let workspace = (workspacePath as NSString).standardizingPath
        let path = try configPath ?? ConfigDiscovery.discover(workspacePath: workspace, fileManager: fileManager)
        let raw = try JSONCParser.loadFile(at: path)

        // Admit before deep work so hard-errors fail fast (also re-admit after sub for mounts).
        try ConfigAdmissions.admit(raw)

        let basename: String = {
            if let override = workspaceFolderBasename, !override.isEmpty {
                return override
            }
            return (workspace as NSString).lastPathComponent
        }()
        let defaultWorkspaceFolder = "/workspaces/\(basename)"

        // Pre-resolve workspaceFolder with a temporary context (container folder may self-ref).
        let provisionalFolder: String
        if let wf = raw["workspaceFolder"] as? String {
            let ctx = SubstitutionContext(
                localWorkspaceFolder: workspace,
                containerWorkspaceFolder: defaultWorkspaceFolder,
                localEnv: localEnv,
                localWorkspaceFolderBasename: workspaceFolderBasename
            )
            provisionalFolder = try VariableSubstitutor.substitute(wf, context: ctx)
        } else {
            provisionalFolder = defaultWorkspaceFolder
        }

        let context = SubstitutionContext(
            localWorkspaceFolder: workspace,
            containerWorkspaceFolder: provisionalFolder,
            localEnv: localEnv,
            localWorkspaceFolderBasename: workspaceFolderBasename
        )

        let substituted = try VariableSubstitutor.substituteAny(raw, context: context)
        guard let subDict = substituted as? [String: Any] else {
            throw CLIError(code: CLIErrorCode.configParse, message: "Internal: substituted root is not an object")
        }

        // Re-admit post-substitution (structure unchanged but keeps single path).
        try ConfigAdmissions.admit(subDict)

        var resolved = try buildResolved(
            subDict,
            defaultWorkspaceFolder: provisionalFolder,
            configPath: path,
            fileManager: fileManager
        )
        let normalized = MountNormalizer.normalize(mounts: resolved.mounts, fileManager: fileManager)
        resolved.mounts = normalized.mounts
        for promotion in normalized.promotions {
            resolved.compatibilityReport.add(MountNormalizer.compatibilityIssue(for: promotion))
        }
        resolved.compatibilityReport.emitWarnings()
        let hash = ContainerIdentity.configHash(from: resolved.hashMaterial())
        let name = try ContainerIdentity.requireCreateName(
            ContainerIdentity.containerName(
                workspacePath: workspace,
                configPath: path,
                configName: resolved.name
            )
        )
        let configVolumeNames = resolved.mounts
            .filter { $0.type == .volume }
            .map(\.source)
        let labels = ContainerIdentity.bindModeLabels(
            workspacePath: workspace,
            configPath: path,
            configHash: hash,
            workspaceFolder: resolved.workspaceFolder,
            remoteUser: resolved.effectiveUser,
            configVolumeNames: configVolumeNames
        )

        return ResolvedWorkspace(
            workspacePath: workspace,
            configPath: path,
            config: resolved,
            configHash: hash,
            containerName: name,
            labels: labels,
            mountPromotions: normalized.promotions
        )
    }

    private static func buildResolved(
        _ raw: [String: Any],
        defaultWorkspaceFolder: String,
        configPath: String,
        fileManager: FileManager
    ) throws -> ResolvedDevContainerConfig {
        let dockerfileBuild = try parseDockerfileBuild(
            raw["build"],
            configPath: configPath,
            fileManager: fileManager
        )
        let image: String
        if let img = raw["image"] as? String, !img.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            image = img
        } else {
            image = ""
        }

        var env: [String: String] = [:]
        if let containerEnv = raw["containerEnv"] as? [String: Any] {
            for (k, v) in containerEnv {
                if let s = v as? String {
                    env[k] = s
                } else if let n = v as? NSNumber {
                    env[k] = "\(n)"
                } else {
                    throw CLIError(
                        code: CLIErrorCode.unsupportedProperty,
                        property: "containerEnv.\(k)",
                        message: "containerEnv values must be strings"
                    )
                }
            }
        }

        let remoteUser = raw["remoteUser"] as? String
        let containerUser = raw["containerUser"] as? String
        let workspaceFolder = (raw["workspaceFolder"] as? String).flatMap { $0.isEmpty ? nil : $0 }
            ?? defaultWorkspaceFolder

        var mounts: [MountSpec] = []
        if let rawMounts = raw["mounts"] {
            mounts = try MountParser.parse(rawMounts)
        }

        var forwardPorts: [Int] = []
        if let ports = raw["forwardPorts"] as? [Any] {
            forwardPorts = try ports.map { item in
                if let i = item as? Int { return i }
                if let n = item as? NSNumber { return n.intValue }
                if let s = item as? String, let i = Int(s) { return i }
                throw CLIError(
                    code: CLIErrorCode.unsupportedProperty,
                    property: "forwardPorts",
                    message: "forwardPorts entries must be integers"
                )
            }
        }

        var portsAttributes: [String: [String: String]] = [:]
        if let pa = raw["portsAttributes"] as? [String: Any] {
            for (portKey, value) in pa {
                guard let obj = value as? [String: Any] else { continue }
                var meta: [String: String] = [:]
                for (mk, mv) in obj {
                    if let s = mv as? String {
                        meta[mk] = s
                    } else if let b = mv as? Bool {
                        meta[mk] = b ? "true" : "false"
                    } else if let n = mv as? NSNumber {
                        meta[mk] = "\(n)"
                    }
                }
                portsAttributes[portKey] = meta
            }
        }

        let initialize = try LifecycleCommand.parse(raw["initializeCommand"], property: "initializeCommand")
        let onCreate = try LifecycleCommand.parse(raw["onCreateCommand"], property: "onCreateCommand")
        let updateContent = try LifecycleCommand.parse(raw["updateContentCommand"], property: "updateContentCommand")
        let postCreate = try LifecycleCommand.parse(raw["postCreateCommand"], property: "postCreateCommand")
        let postStart = try LifecycleCommand.parse(raw["postStartCommand"], property: "postStartCommand")
        let postAttach = try LifecycleCommand.parse(raw["postAttachCommand"], property: "postAttachCommand")
        let waitFor = try WaitFor.parse(raw["waitFor"])
        let userEnvProbe = try UserEnvProbe.parse(raw["userEnvProbe"])
        let shutdownAction = try ShutdownAction.parse(raw["shutdownAction"])

        let parsedRunArgs = try RunArgsAdmission.parseResult(raw["runArgs"])
        var report = CompatibilityReport(issues: parsedRunArgs.issues)
        var topLevelCaps: [String] = []
        if let capAdd = raw["capAdd"] as? [Any] {
            topLevelCaps = capAdd.compactMap { $0 as? String }
        }
        var effectiveRunArgs = RunArgsAdmission.mergingCapabilities(topLevelCaps, into: parsedRunArgs.args)
        if raw["init"] as? Bool == true, !effectiveRunArgs.contains(.initFlag) {
            effectiveRunArgs.append(.initFlag)
        }
        RunArgsAdmission.emitNetAdminSidecarIfNeeded(
            skippedPrivilegedOrDevice: parsedRunArgs.skippedPrivilegedOrDevice,
            args: effectiveRunArgs
        )
        if let securityOpt = raw["securityOpt"] as? [Any], !securityOpt.isEmpty {
            let includesNoNewPrivileges = securityOpt.contains {
                ($0 as? String) == "no-new-privileges"
            }
            let message: String
            if includesNoNewPrivileges {
                message =
                    "Top-level securityOpt was ignored and not applied on Apple container; "
                    + "no-new-privileges is not enforced"
            } else {
                message = "Top-level securityOpt was ignored and not applied on Apple container"
            }
            report.add(CompatibilityIssue(
                code: CompatibilityCode.configSecurityOptIgnored,
                propertyPath: "securityOpt",
                disposition: .ignored,
                message: message
            ))
        }
        if let otherPorts = raw["otherPortsAttributes"] as? [String: Any], !otherPorts.isEmpty {
            report.add(CompatibilityIssue(
                code: CompatibilityCode.configOtherPortsAttributesIgnored,
                propertyPath: "otherPortsAttributes",
                disposition: .ignored,
                message: "otherPortsAttributes default port UI/auto-forward actions are not applied"
            ))
        }
        if let secrets = raw["secrets"] as? [String: Any], !secrets.isEmpty {
            report.add(CompatibilityIssue(
                code: CompatibilityCode.configSecretsIgnored,
                propertyPath: "secrets",
                disposition: .ignored,
                message: "secrets recommendation metadata is not injected or validated"
            ))
        }
        if raw["privileged"] as? Bool == true {
            report.add(CompatibilityIssue(
                code: CompatibilityCode.configPrivilegedIgnored,
                propertyPath: "privileged",
                disposition: .ignored,
                message: "privileged is not applied on Apple container"
            ))
        }
        let hostRequirements = try HostRequirements.parse(raw["hostRequirements"])

        let vscode = parseVscodeCustomizations(raw["customizations"])

        let parsedFeatures = try FeatureAdmission.parseResult(raw["features"])
        report.add(contentsOf: parsedFeatures.issues)

        return ResolvedDevContainerConfig(
            name: raw["name"] as? String,
            image: image,
            dockerfileBuild: dockerfileBuild,
            containerEnv: env,
            remoteUser: remoteUser,
            containerUser: containerUser,
            workspaceFolder: workspaceFolder,
            mounts: mounts,
            forwardPorts: forwardPorts,
            portsAttributes: portsAttributes,
            postCreateCommand: postCreate,
            onCreateCommand: onCreate,
            updateContentCommand: updateContent,
            postStartCommand: postStart,
            postAttachCommand: postAttach,
            initializeCommand: initialize,
            waitFor: waitFor,
            userEnvProbe: userEnvProbe,
            shutdownAction: shutdownAction,
            runArgs: effectiveRunArgs,
            hostRequirements: hostRequirements,
            hasVscodeCustomizations: vscode.hasVscode,
            vscodeExtensions: vscode.extensions,
            vscodeSettingsJSON: vscode.settingsJSON,
            features: parsedFeatures.features,
            compatibilityReport: report
        )
    }

    private static func parseDockerfileBuild(
        _ raw: Any?,
        configPath: String,
        fileManager: FileManager
    ) throws -> DockerfileBuild? {
        guard let raw else { return nil }
        guard let obj = raw as? [String: Any] else {
            throw CLIError(
                code: CLIErrorCode.unsupportedProperty,
                property: "build",
                message: "build must be an object"
            )
        }
        guard let dockerfile = obj["dockerfile"] as? String,
              !dockerfile.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        else {
            throw CLIError(
                code: CLIErrorCode.unsupportedProperty,
                property: "build",
                message: "build.dockerfile must be a non-empty string"
            )
        }
        let context: String
        if let rawContext = obj["context"] {
            guard let s = rawContext as? String else {
                throw CLIError(
                    code: CLIErrorCode.unsupportedProperty,
                    property: "build",
                    message: "build.context must be a string"
                )
            }
            context = s.isEmpty ? "." : s
        } else {
            context = "."
        }
        var args: [String: String] = [:]
        if let rawArgs = obj["args"] {
            guard let map = rawArgs as? [String: Any] else {
                throw CLIError(
                    code: CLIErrorCode.unsupportedProperty,
                    property: "build",
                    message: "build.args must be an object of string values"
                )
            }
            for key in map.keys.sorted() {
                guard let value = map[key] as? String else {
                    throw CLIError(
                        code: CLIErrorCode.unsupportedProperty,
                        property: "build",
                        message: "build.args values must be strings"
                    )
                }
                args[key] = value
            }
        }
        let target: String?
        if let rawTarget = obj["target"] {
            guard let s = rawTarget as? String else {
                throw CLIError(
                    code: CLIErrorCode.unsupportedProperty,
                    property: "build",
                    message: "build.target must be a string"
                )
            }
            target = s
        } else {
            target = nil
        }
        let configDir = (configPath as NSString).deletingLastPathComponent
        let dockerfilePath = (configDir as NSString).appendingPathComponent(dockerfile)
        let bytes = fileManager.contents(atPath: dockerfilePath) ?? Data()
        return DockerfileBuild(
            dockerfile: dockerfile,
            context: context,
            args: args,
            target: target,
            dockerfileBytes: bytes
        )
    }

    /// Parse `customizations.vscode` for apply payload. Never fails resolve for nested type issues.
    private static func parseVscodeCustomizations(_ raw: Any?) -> (
        hasVscode: Bool,
        extensions: [String],
        settingsJSON: Data
    ) {
        let emptySettings = Data("{}".utf8)
        guard let customizations = raw as? [String: Any] else {
            return (false, [], emptySettings)
        }
        guard let vscodeRaw = customizations["vscode"] else {
            return (false, [], emptySettings)
        }
        // vscode key present → intent flag; non-object → no applyable payload (MAY warn).
        guard let vscode = vscodeRaw as? [String: Any] else {
            StatusPrinter.warning(
                "customizations.vscode is not an object; vscode customizations apply skipped"
            )
            return (true, [], emptySettings)
        }

        var extensions: [String] = []
        if let extRaw = vscode["extensions"] {
            if let arr = extRaw as? [Any] {
                var skippedNonString = false
                for item in arr {
                    if let s = item as? String {
                        let trimmed = s.trimmingCharacters(in: .whitespacesAndNewlines)
                        if !trimmed.isEmpty {
                            extensions.append(trimmed)
                        }
                    } else {
                        skippedNonString = true
                    }
                }
                if skippedNonString {
                    StatusPrinter.warning(
                        "customizations.vscode.extensions contains non-string entries; those entries were skipped"
                    )
                }
            } else {
                StatusPrinter.warning(
                    "customizations.vscode.extensions is not an array; extensions apply soft-skipped"
                )
            }
        }

        var settingsJSON = emptySettings
        if let settingsRaw = vscode["settings"] {
            if let obj = settingsRaw as? [String: Any] {
                if let data = try? JSONSerialization.data(
                    withJSONObject: obj,
                    options: [.sortedKeys]
                ) {
                    settingsJSON = data
                } else {
                    StatusPrinter.warning(
                        "customizations.vscode.settings could not be serialized; settings apply soft-skipped"
                    )
                }
            } else {
                StatusPrinter.warning(
                    "customizations.vscode.settings is not an object; settings apply soft-skipped"
                )
            }
        }

        return (true, extensions, settingsJSON)
    }
}
