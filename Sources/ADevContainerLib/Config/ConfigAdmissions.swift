import Foundation

/// Fail-closed admission for the supported property surface.
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
        "onCreateCommand",
        "updateContentCommand",
        "postStartCommand",
        "postAttachCommand",
        "customizations",
        "hostRequirements",
        "runArgs"
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

        // runArgs — allowlisted subset only
        if raw["runArgs"] != nil {
            _ = try RunArgsAdmission.parse(raw["runArgs"])
        }

        // hostRequirements — parse/validate (no longer pure-ignore)
        if raw["hostRequirements"] != nil {
            _ = try HostRequirements.parse(raw["hostRequirements"])
        }

        // Unknown top-level keys (fail closed)
        for key in raw.keys {
            if supportedKeys.contains(key) { continue }
            if composeKeys.contains(key) { continue } // already handled
            if key == "features" { continue } // handled
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
}
