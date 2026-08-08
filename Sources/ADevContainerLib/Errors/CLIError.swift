import Foundation

/// Structured CLI error with actionable fields for humans and machines.
public struct CLIError: Error, Equatable, Sendable {
    public var code: String
    public var property: String?
    public var message: String
    public var hint: String?

    public init(code: String, property: String? = nil, message: String, hint: String? = nil) {
        self.code = code
        self.property = property
        self.message = message
        self.hint = hint
    }

    public var exitCode: Int32 { 1 }

    public func formatted() -> String {
        var lines: [String] = ["error[\(code)]: \(message)"]
        if let property {
            lines.append("  property: \(property)")
        }
        if let hint {
            lines.append("  hint: \(hint)")
        }
        return lines.joined(separator: "\n")
    }

    public func jsonObject() -> [String: Any] {
        var obj: [String: Any] = [
            "outcome": "error",
            "code": code,
            "message": message
        ]
        if let property { obj["property"] = property }
        if let hint { obj["hint"] = hint }
        return obj
    }
}

public enum CLIErrorCode {
    public static let configNotFound = "config_not_found"
    public static let configParse = "config_parse"
    public static let unsupportedProperty = "unsupported_property"
    public static let unsupportedFeature = "unsupported_feature"
    public static let unsupportedSubstitution = "unsupported_substitution"
    public static let runtimeMissing = "runtime_missing"
    public static let runtimeFailed = "runtime_failed"
    public static let containerNotFound = "container_not_found"
    public static let containerNotRunning = "container_not_running"
    public static let configHashMismatch = "config_hash_mismatch"
    public static let postCreateFailed = "post_create_failed"
    /// Lifecycle hook failure (onCreate / updateContent / postStart / etc.).
    public static let lifecycleFailed = "lifecycle_failed"
    /// hostRequirements capacity shortfall or unverifiable host resources.
    public static let hostRequirements = "host_requirements"
    /// OCI feature artifact fetch failure (network, 404, malformed).
    public static let featureFetch = "feature_fetch"
    /// Missing or invalid devcontainer-feature.json.
    public static let featureMetadata = "feature_metadata"
    /// Feature dependsOn/installsAfter cycle.
    public static let featureDependencyCycle = "feature_dependency_cycle"
    /// Legacy derived-image build failure (BuildKit path retained for optional future use).
    public static let featureBuild = "feature_build"
    /// In-container feature install failure (`cp` / `exec install.sh`) — retained helper path.
    public static let featureInstall = "feature_install"
    /// User declined or non-interactive failure configuring `build.rosetta=false` for Features builds.
    public static let buildRosettaConfig = "build_rosetta_config"
    public static let usage = "usage"
    public static let internalError = "internal_error"
    /// Host `git` missing or not executable (clone prerequisite).
    public static let gitMissing = "git_missing"
    /// Host `git` clone/fetch failed.
    public static let gitFailed = "git_failed"
    /// Populate (copy into volume) failed after container create.
    public static let populateFailed = "populate_failed"
    /// Multiple managed containers and no `--name` in non-interactive mode.
    public static let selectionRequired = "selection_required"
}

