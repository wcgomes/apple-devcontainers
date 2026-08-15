import Foundation

public struct RecoveryErrorDetails: Equatable, Sendable {
    public let status: String
    public let helperContainerID: String
    public let helperContainerName: String
    public let helperAvailable: Bool
    public let marker: String
    public let sessionID: String
    public let workspaceVolume: String
    public let configPath: String
    public let tempFile: String
    public let conflictFile: String?
    public let conflictHash: String?
    public let expectedHash: String
    public let failureKind: String
    public let editCommand: String
    public let retryCommand: String
    public let cleanupCommand: String
    /// Recovery mode: `"volume"` (helper session) or `"bind"` (host-path editor).
    public let mode: String

    public init(
        status: String = "retained",
        helperContainerID: String,
        helperContainerName: String,
        helperAvailable: Bool = true,
        marker: String = "devcontainer.recovery=adevcontainer",
        sessionID: String,
        workspaceVolume: String,
        configPath: String,
        tempFile: String,
        conflictFile: String? = nil,
        conflictHash: String? = nil,
        expectedHash: String,
        failureKind: String,
        editCommand: String,
        retryCommand: String,
        cleanupCommand: String,
        mode: String = "volume"
    ) {
        self.status = status
        self.helperContainerID = helperContainerID
        self.helperContainerName = helperContainerName
        self.helperAvailable = helperAvailable
        self.marker = marker
        self.sessionID = sessionID
        self.workspaceVolume = workspaceVolume
        self.configPath = configPath
        self.tempFile = tempFile
        self.conflictFile = conflictFile
        self.conflictHash = conflictHash
        self.expectedHash = expectedHash
        self.failureKind = failureKind
        self.editCommand = editCommand
        self.retryCommand = retryCommand
        self.cleanupCommand = cleanupCommand
        self.mode = mode
    }

    /// Bind host-path recovery details (no helper, no session temp, no cleanup helper delete).
    public static func bindHostPath(
        containerName: String,
        containerID: String = "",
        configPath: String,
        failureKind: String,
        editCommand: String,
        retryCommand: String,
        status: String = "retained"
    ) -> RecoveryErrorDetails {
        RecoveryErrorDetails(
            status: status,
            helperContainerID: containerID,
            helperContainerName: containerName,
            helperAvailable: false,
            marker: "",
            sessionID: "",
            workspaceVolume: "",
            configPath: configPath,
            tempFile: "",
            expectedHash: "",
            failureKind: failureKind,
            editCommand: editCommand,
            retryCommand: retryCommand,
            cleanupCommand: "",
            mode: "bind"
        )
    }

    public func jsonObject() -> [String: Any] {
        var value: [String: Any] = [
            "status": status,
            "helperContainerName": helperContainerName,
            "helperAvailable": helperAvailable,
            "configPath": configPath,
            "failureKind": failureKind,
            "editCommand": editCommand,
            "retryCommand": retryCommand,
            "mode": mode
        ]
        if !marker.isEmpty { value["marker"] = marker }
        if !sessionID.isEmpty { value["sessionId"] = sessionID }
        if !workspaceVolume.isEmpty { value["workspaceVolume"] = workspaceVolume }
        if !tempFile.isEmpty { value["tempFile"] = tempFile }
        if !expectedHash.isEmpty { value["expectedHash"] = expectedHash }
        if !cleanupCommand.isEmpty { value["cleanupCommand"] = cleanupCommand }
        if !["not-created", "not-available"].contains(helperContainerID), !helperContainerID.isEmpty {
            value["helperContainerId"] = helperContainerID
        }
        if let conflictFile { value["conflictFile"] = conflictFile }
        if let conflictHash { value["conflictHash"] = conflictHash }
        return value
    }
}

/// Structured CLI error with actionable fields for humans and machines.
public struct CLIError: Error, Equatable, Sendable, LocalizedError {
    public var code: String
    public var property: String?
    public var message: String
    public var hint: String?
    public var recovery: RecoveryErrorDetails?

    public init(
        code: String,
        property: String? = nil,
        message: String,
        hint: String? = nil,
        recovery: RecoveryErrorDetails? = nil
    ) {
        self.code = code
        self.property = property
        self.message = message
        self.hint = hint
        self.recovery = recovery
    }

    public var exitCode: Int32 { 1 }

    /// So `error.localizedDescription` (soft-fail warns, NSError bridges) carries `message`,
    /// not the opaque "ADevContainerLib.CLIError error 1".
    public var errorDescription: String? { message }

    /// Human presentation. When `color` is true (default: TerminalStyle policy), only the
    /// `error: ` label is red; message body and property/hint use dim info gray.
    /// Machine JSON still carries `code` separately — not repeated in the human head line.
    public func formatted(color: Bool = TerminalStyle.colorEnabled) -> String {
        var lines: [String] = [
            TerminalStyle.styleErrorLabel(TerminalStyle.errorPrefix, color: color)
                + TerminalStyle.styleErrorBody(message, color: color)
        ]
        if let property {
            lines.append(TerminalStyle.styleErrorBody("  property: \(property)", color: color))
        }
        if let hint {
            lines.append(TerminalStyle.styleHint("  hint: \(hint)", color: color))
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
        if let recovery { obj["recovery"] = recovery.jsonObject() }
        return obj
    }

    public func jsonData(pretty: Bool = true) throws -> Data {
        let options: JSONSerialization.WritingOptions = pretty
            ? [.prettyPrinted, .sortedKeys]
            : [.sortedKeys]
        return try JSONSerialization.data(withJSONObject: jsonObject(), options: options)
    }

    public func jsonString(pretty: Bool = true) throws -> String {
        guard let value = String(data: try jsonData(pretty: pretty), encoding: .utf8) else {
            throw CLIError(code: CLIErrorCode.internalError, message: "Failed to encode CLI error JSON")
        }
        return value
    }
}

/// Error rendering shared by the executable entry point and machine-output tests. JSON errors
/// are written to the error stream by the caller; successful command JSON remains stdout-only.
/// JSON path is always monochrome structured bytes; human path may apply TerminalStyle color.
public enum CLIErrorOutput {
    public static func data(for error: CLIError, json: Bool) -> Data {
        if json, let encoded = try? error.jsonData() {
            var output = encoded
            output.append(0x0A)
            return output
        }
        return Data((error.formatted() + "\n").utf8)
    }
}

public enum CLIErrorCode {
    public static let configNotFound = "config_not_found"
    public static let configParse = "config_parse"
    /// Create `--name` is empty after DNS-safe sanitize (no invented fallback).
    public static let invalidCreateName = "invalid_create_name"
    /// Desired create name is taken by a different workspace or an unmanaged container.
    public static let containerNameInUse = "container_name_in_use"
    /// This workspace already has a managed container (same name or leftover under another name).
    public static let workspaceContainerExists = "workspace_container_exists"
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
    /// Recovery prerequisites are unavailable or a recovery operation could not be established.
    public static let recoveryUnavailable = "recovery_unavailable"
    /// The recovery target changed after the session baseline was captured.
    public static let recoveryConflict = "recovery_conflict"
    /// The operator cancelled an interactive recovery attempt.
    public static let recoveryCancelled = "recovery_cancelled"
    /// Recovery readback or final visibility verification did not match the expected bytes.
    public static let recoveryVerificationFailed = "recovery_verification_failed"
}
