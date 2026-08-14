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
        "initializeCommand",
        "waitFor",
        "userEnvProbe",
        "shutdownAction",
        "customizations",
        "hostRequirements",
        "runArgs",
        "features"
    ]

    private static let composeKeys: Set<String> = [
        "dockerComposeFile",
        "dockerComposePath",
        "service",
        "runServices",
        "composeFile"
    ]

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

        // Features — OCI/local admitted; docker-* markers warn-skipped (no warn here:
        // ConfigResolver.buildResolved is the single user-facing parse that emits).
        if let features = raw["features"] {
            _ = try FeatureAdmission.parse(features, emitWarnings: false)
        }

        // runArgs — allowlisted subset; known Apple-incompatibles warn-skipped
        // (warnings deferred to buildResolved; see FeatureAdmission note above).
        if raw["runArgs"] != nil {
            _ = try RunArgsAdmission.parse(raw["runArgs"], emitWarnings: false)
        }

        // hostRequirements — parse/validate (no longer pure-ignore)
        if raw["hostRequirements"] != nil {
            _ = try HostRequirements.parse(raw["hostRequirements"])
        }

        // Unknown top-level keys (fail closed)
        for key in raw.keys {
            if supportedKeys.contains(key) { continue }
            if composeKeys.contains(key) { continue } // already handled
            throw CLIError(
                code: CLIErrorCode.unsupportedProperty,
                property: key,
                message: "Unsupported property '\(key)'",
                hint: "Remove '\(key)' or wait for a later release that supports it"
            )
        }

        // image required
        guard let image = raw["image"] as? String, !image.isEmpty else {
            throw CLIError(
                code: CLIErrorCode.unsupportedProperty,
                property: "image",
                message: "Property 'image' is required for MVP image-based dev containers",
                hint: "Set \"image\": \"your-image:tag\""
            )
        }
        _ = image

        // customizations must be an object when present. Nested customizations.vscode is admitted
        // without hard-fail on nested shape: well-formed extensions/settings are retained for
        // runtime apply; malformed nested types soft-skip apply (see ConfigResolver).
        // Other customizations.* namespaces remain non-applied metadata.
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
}
