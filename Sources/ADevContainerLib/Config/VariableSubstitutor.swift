import Foundation

public struct SubstitutionContext: Sendable {
    public var localWorkspaceFolder: String
    public var localWorkspaceFolderBasename: String
    public var containerWorkspaceFolder: String
    public var localEnv: [String: String]
    /// Resource identity stem `adev-{base}-{hash12}` (not the DNS create `--name`).
    /// When nil, `${devcontainerId}` is left unsubstituted for a later identity-known pass.
    public var devcontainerId: String?

    public init(
        localWorkspaceFolder: String,
        containerWorkspaceFolder: String,
        localEnv: [String: String] = ProcessInfo.processInfo.environment,
        localWorkspaceFolderBasename: String? = nil,
        devcontainerId: String? = nil
    ) {
        let ws = (localWorkspaceFolder as NSString).standardizingPath
        self.localWorkspaceFolder = ws
        if let override = localWorkspaceFolderBasename, !override.isEmpty {
            self.localWorkspaceFolderBasename = override
        } else {
            self.localWorkspaceFolderBasename = (ws as NSString).lastPathComponent
        }
        self.containerWorkspaceFolder = containerWorkspaceFolder
        self.localEnv = localEnv
        self.devcontainerId = devcontainerId
    }
}

public enum VariableSubstitutor {
    /// Match `${...}` tokens.
    private static let pattern = try! NSRegularExpression(
        pattern: #"\$\{([^}]+)\}"#,
        options: []
    )

    /// Literal token form preserved when `devcontainerId` is not yet known.
    public static let devcontainerIdToken = "${devcontainerId}"

    public static func substitute(_ input: String, context: SubstitutionContext) throws -> String {
        let ns = input as NSString
        let full = NSRange(location: 0, length: ns.length)
        let matches = pattern.matches(in: input, options: [], range: full)

        guard !matches.isEmpty else { return input }

        var result = input
        // Replace from end so ranges stay valid relative to original, rebuild carefully.
        // Use original ranges on `input`, apply to `result` which starts equal to input.
        for match in matches.reversed() {
            guard match.numberOfRanges >= 2,
                  let tokenRange = Range(match.range(at: 1), in: input),
                  let fullRange = Range(match.range(at: 0), in: result)
            else { continue }

            let token = String(input[tokenRange])
            let replacement = try resolve(token: token, context: context)
            result.replaceSubrange(fullRange, with: replacement)
        }
        return result
    }

    public static func substituteAny(_ value: Any, context: SubstitutionContext) throws -> Any {
        if let s = value as? String {
            return try substitute(s, context: context)
        }
        if let arr = value as? [Any] {
            return try arr.map { try substituteAny($0, context: context) }
        }
        if let dict = value as? [String: Any] {
            var out: [String: Any] = [:]
            for (k, v) in dict {
                out[k] = try substituteAny(v, context: context)
            }
            return out
        }
        return value
    }

    /// Expand `${devcontainerId}` to the resource identity stem (idempotent if already expanded).
    /// `id` MUST be `adev-{base}-{hash12}`, never the DNS create name.
    public static func expandDevcontainerId(in input: String, id: String) -> String {
        guard input.contains(devcontainerIdToken) else { return input }
        return input.replacingOccurrences(of: devcontainerIdToken, with: id)
    }

    /// Expand `${devcontainerId}` in mount source/target (feature + config named volumes).
    public static func expandDevcontainerId(in mounts: [MountSpec], id: String) -> [MountSpec] {
        guard mounts.contains(where: {
            $0.source.contains(devcontainerIdToken) || $0.target.contains(devcontainerIdToken)
        }) else {
            return mounts
        }
        return mounts.map { mount in
            MountSpec(
                type: mount.type,
                source: expandDevcontainerId(in: mount.source, id: id),
                target: expandDevcontainerId(in: mount.target, id: id),
                readonly: mount.readonly
            )
        }
    }

    /// Expand `${devcontainerId}` in mounts and containerEnv after identity is known.
    public static func expandDevcontainerId(
        in config: ResolvedDevContainerConfig,
        id: String
    ) -> ResolvedDevContainerConfig {
        var out = config
        out.mounts = expandDevcontainerId(in: config.mounts, id: id)
        if config.containerEnv.values.contains(where: { $0.contains(devcontainerIdToken) }) {
            var env = config.containerEnv
            for (k, v) in env {
                env[k] = expandDevcontainerId(in: v, id: id)
            }
            out.containerEnv = env
        }
        return out
    }

    private static func resolve(token: String, context: SubstitutionContext) throws -> String {
        if token == "localWorkspaceFolder" {
            return context.localWorkspaceFolder
        }
        if token == "localWorkspaceFolderBasename" {
            return context.localWorkspaceFolderBasename
        }
        if token == "containerWorkspaceFolder" {
            return context.containerWorkspaceFolder
        }
        if token == "devcontainerId" {
            // Expand when the resource identity stem is known; otherwise leave the token.
            if let id = context.devcontainerId, !id.isEmpty {
                return id
            }
            return devcontainerIdToken
        }
        if token.hasPrefix("localEnv:") {
            let name = String(token.dropFirst("localEnv:".count))
            return context.localEnv[name] ?? ""
        }
        throw CLIError(
            code: CLIErrorCode.unsupportedSubstitution,
            property: token,
            message: "Unsupported substitution token '\(token)'",
            hint: "Supported: localWorkspaceFolder, localWorkspaceFolderBasename, localEnv:VAR, containerWorkspaceFolder, devcontainerId"
        )
    }
}
