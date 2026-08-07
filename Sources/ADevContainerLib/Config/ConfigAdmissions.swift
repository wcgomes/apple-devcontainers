import Foundation

/// Fail-closed admission for Phases 0–3 property surface.
public enum ConfigAdmissions {
    /// Keys that may appear and are either supported or intentionally ignored.
    private static let supportedKeys: Set<String> = [
        "name",
        "image",
        "containerEnv",
        "remoteUser",
        "containerUser",
        "workspaceFolder",
        "mounts",
        "forwardPorts",
        "portsAttributes",
        "postCreateCommand",
        "customizations",
        "hostRequirements" // ignore without failing
    ]

    private static let composeKeys: Set<String> = [
        "dockerComposeFile",
        "dockerComposePath",
        "service",
        "runServices",
        "composeFile"
    ]

    private static let dockerOODPrefix = "ghcr.io/devcontainers/features/docker-outside-of-docker"

    public static func admit(_ raw: [String: Any]) throws {
        // Compose keys
        for key in composeKeys where raw[key] != nil {
            throw CLIError(
                code: CLIErrorCode.unsupportedProperty,
                property: key,
                message: "Docker Compose configuration is not supported",
                hint: "Remove '\(key)' and use a single image-based devcontainer.json"
            )
        }

        // Features — any features block errors; docker-ood called out specially
        if let features = raw["features"] {
            try admitFeatures(features)
        }

        // runArgs
        if let runArgs = raw["runArgs"] {
            try admitRunArgs(runArgs)
        }

        // Unknown top-level keys (fail closed)
        for key in raw.keys {
            if supportedKeys.contains(key) { continue }
            if composeKeys.contains(key) { continue } // already handled
            if key == "features" || key == "runArgs" { continue } // handled
            throw CLIError(
                code: CLIErrorCode.unsupportedProperty,
                property: key,
                message: "Unsupported property '\(key)'",
                hint: "Remove '\(key)' or wait for a later phase that supports it"
            )
        }

        // image required
        guard let image = raw["image"] as? String, !image.isEmpty else {
            throw CLIError(
                code: CLIErrorCode.unsupportedProperty,
                property: "image",
                message: "Property 'image' is required for MVP image-based workspaces",
                hint: "Set \"image\": \"your-image:tag\""
            )
        }
        _ = image

        // customizations.vscode must not fail — only reject unknown customization namespaces if needed.
        // We allow any customizations content as metadata.
        if let customizations = raw["customizations"] {
            if !(customizations is [String: Any]) {
                throw CLIError(
                    code: CLIErrorCode.unsupportedProperty,
                    property: "customizations",
                    message: "customizations must be an object"
                )
            }
        }
    }

    private static func admitFeatures(_ features: Any) throws {
        guard let dict = features as? [String: Any] else {
            throw CLIError(
                code: CLIErrorCode.unsupportedFeature,
                property: "features",
                message: "features must be an object",
                hint: "Features are not supported on the MVP path — remove the features block"
            )
        }

        for featureId in dict.keys {
            let base = featureId.split(separator: ":").first.map(String.init) ?? featureId
            if base == dockerOODPrefix || featureId.hasPrefix(dockerOODPrefix) {
                throw CLIError(
                    code: CLIErrorCode.unsupportedFeature,
                    property: "features",
                    message: "Feature '\(featureId)' is forever-rejected (docker-outside-of-docker)",
                    hint: "Remove docker-outside-of-docker; Apple container has no privileged/device path for this"
                )
            }
        }

        // Any features on MVP path
        let ids = dict.keys.sorted().joined(separator: ", ")
        throw CLIError(
            code: CLIErrorCode.unsupportedFeature,
            property: "features",
            message: "Features are not supported on the MVP path: \(ids)",
            hint: "Remove the features block; features runner is post-MVP"
        )
    }

    private static func admitRunArgs(_ runArgs: Any) throws {
        guard let args = runArgs as? [Any] else {
            throw CLIError(
                code: CLIErrorCode.unsupportedProperty,
                property: "runArgs",
                message: "runArgs must be an array of strings"
            )
        }
        // MVP allowlist is empty — every entry errors; call out privileged/device specially.
        for item in args {
            guard let arg = item as? String else {
                throw CLIError(
                    code: CLIErrorCode.unsupportedProperty,
                    property: "runArgs",
                    message: "runArgs entries must be strings"
                )
            }
            if arg == "--privileged" || arg.hasPrefix("--privileged=") {
                throw CLIError(
                    code: CLIErrorCode.unsupportedProperty,
                    property: "runArgs",
                    message: "runArgs entry '--privileged' is forever-rejected",
                    hint: "Remove --privileged from runArgs"
                )
            }
            if arg == "--device" || arg.hasPrefix("--device=") || arg.hasPrefix("--device ") {
                throw CLIError(
                    code: CLIErrorCode.unsupportedProperty,
                    property: "runArgs",
                    message: "runArgs entry '\(arg)' (device passthrough) is forever-rejected",
                    hint: "Remove --device flags from runArgs"
                )
            }
            throw CLIError(
                code: CLIErrorCode.unsupportedProperty,
                property: "runArgs",
                message: "runArgs entry '\(arg)' is not on the allowlist",
                hint: "MVP runArgs allowlist is empty — remove all runArgs"
            )
        }
    }
}
