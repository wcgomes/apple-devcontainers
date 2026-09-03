import Foundation
import CoreFoundation

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
        "features",
        "init",
        "securityOpt",
        "$schema",
        "otherPortsAttributes",
        "secrets",
        "privileged",
        "overrideCommand",
        "capAdd"
    ]

    private static let blockedWorkspaceOrProcessKeys: [String: String] = [
        "workspaceMount": "workspaceMount is unsupported because it would mount different content than the implicit workspace bind",
        "remoteEnv": "remoteEnv is unsupported because it would run a different process environment than containerEnv"
    ]

    private static let blockedSourceKeys: [String: String] = [
        "build": "Dockerfile build is not supported",
        "dockerFile": "Dockerfile build is not supported",
        "dockerfile": "Dockerfile build is not supported",
        "context": "Dockerfile build is not supported"
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

        for (key, message) in blockedSourceKeys where raw[key] != nil {
            throw CLIError(
                code: CLIErrorCode.unsupportedProperty,
                property: key,
                message: message,
                hint: "Remove '\(key)' and use a single image-based devcontainer.json"
            )
        }

        for (key, message) in blockedWorkspaceOrProcessKeys where raw[key] != nil {
            throw CLIError(
                code: CLIErrorCode.unsupportedProperty,
                property: key,
                message: message,
                hint: "Remove '\(key)'"
            )
        }

        if let schema = raw["$schema"], !(schema is String) {
            throw CLIError(
                code: CLIErrorCode.unsupportedProperty,
                property: "$schema",
                message: "$schema must be a string"
            )
        }

        if let otherPorts = raw["otherPortsAttributes"], !(otherPorts is [String: Any]) {
            throw CLIError(
                code: CLIErrorCode.unsupportedProperty,
                property: "otherPortsAttributes",
                message: "otherPortsAttributes must be an object"
            )
        }

        if let secrets = raw["secrets"] {
            guard let dict = secrets as? [String: Any] else {
                throw CLIError(
                    code: CLIErrorCode.unsupportedProperty,
                    property: "secrets",
                    message: "secrets must be an object whose entries are objects"
                )
            }
            for (_, value) in dict {
                guard value is [String: Any] else {
                    throw CLIError(
                        code: CLIErrorCode.unsupportedProperty,
                        property: "secrets",
                        message: "secrets entries must be objects"
                    )
                }
            }
        }

        if let privileged = raw["privileged"], !isJSONBoolean(privileged) {
            throw CLIError(
                code: CLIErrorCode.unsupportedProperty,
                property: "privileged",
                message: "privileged must be a Boolean"
            )
        }

        if let overrideCommand = raw["overrideCommand"] {
            guard isJSONBoolean(overrideCommand) else {
                throw CLIError(
                    code: CLIErrorCode.unsupportedProperty,
                    property: "overrideCommand",
                    message: "overrideCommand must be a Boolean"
                )
            }
            if overrideCommand as? Bool == false {
                throw CLIError(
                    code: CLIErrorCode.unsupportedProperty,
                    property: "overrideCommand",
                    message: "overrideCommand false is unsupported because the image command is not preserved",
                    hint: "Omit overrideCommand or set it to true to keep the existing keep-alive override"
                )
            }
        }

        if let capAdd = raw["capAdd"] {
            guard let values = capAdd as? [Any] else {
                throw CLIError(
                    code: CLIErrorCode.unsupportedProperty,
                    property: "capAdd",
                    message: "capAdd must be an array of capability-name strings"
                )
            }
            for item in values {
                guard let name = item as? String else {
                    throw CLIError(
                        code: CLIErrorCode.unsupportedProperty,
                        property: "capAdd",
                        message: "capAdd entries must be strings"
                    )
                }
                guard RunArgsAdmission.isValidCapabilityName(name) else {
                    throw CLIError(
                        code: CLIErrorCode.unsupportedProperty,
                        property: "capAdd",
                        message: "capAdd entry '\(name)' is not a valid capability name"
                    )
                }
            }
        }

        if let initValue = raw["init"], !isJSONBoolean(initValue) {
            throw CLIError(
                code: CLIErrorCode.unsupportedProperty,
                property: "init",
                message: "init must be a Boolean"
            )
        }

        if let securityOpt = raw["securityOpt"] {
            guard let values = securityOpt as? [Any] else {
                throw CLIError(
                    code: CLIErrorCode.unsupportedProperty,
                    property: "securityOpt",
                    message: "securityOpt must be an array of strings"
                )
            }
            guard values.allSatisfy({ $0 is String }) else {
                throw CLIError(
                    code: CLIErrorCode.unsupportedProperty,
                    property: "securityOpt",
                    message: "securityOpt entries must be strings"
                )
            }
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

    /// JSONSerialization bridges both JSON booleans and some NSNumber values to Bool on
    /// supported platforms. Use the Foundation boolean type identity so numeric 0/1 cannot pass
    /// Boolean admission while retaining compatibility with native Bool values.
    private static func isJSONBoolean(_ value: Any) -> Bool {
        guard let number = value as? NSNumber else {
            return value is Bool
        }
        return CFGetTypeID(number) == CFBooleanGetTypeID()
    }
}
