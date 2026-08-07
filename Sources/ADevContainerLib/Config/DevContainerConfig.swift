import Foundation

/// Lifecycle command as string or argv array.
public enum LifecycleCommand: Equatable, Sendable {
    case shell(String)
    case argv([String])

    public static func parse(_ value: Any?, property: String) throws -> LifecycleCommand? {
        guard let value else { return nil }
        if let s = value as? String {
            return .shell(s)
        }
        if let arr = value as? [Any] {
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
        throw CLIError(
            code: CLIErrorCode.unsupportedProperty,
            property: property,
            message: "\(property) must be a string or array of strings"
        )
    }

    /// Arguments for `container exec` after container id.
    public var execArguments: [String] {
        switch self {
        case .shell(let cmd):
            return ["sh", "-lc", cmd]
        case .argv(let args):
            return args
        }
    }
}

/// Fully resolved Phase 0–3 config ready for runtime mapping.
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
    /// Present when config included customizations.vscode (metadata only; not Sendable JSON).
    public var hasVscodeCustomizations: Bool

    public var effectiveUser: String? {
        // Prefer remoteUser for exec/attach semantics; fall back to containerUser.
        if let remoteUser, !remoteUser.isEmpty { return remoteUser }
        if let containerUser, !containerUser.isEmpty { return containerUser }
        return nil
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
        if let postCreateCommand {
            switch postCreateCommand {
            case .shell(let s): m["postCreateCommand"] = s
            case .argv(let a): m["postCreateCommand"] = a
            }
        }
        // portsAttributes are metadata; include for inspect consistency
        if !portsAttributes.isEmpty {
            m["portsAttributes"] = portsAttributes
        }
        return m
    }
}

// Make customizations comparable-ish by ignoring in Equatable via manual synthesis exclusion.
// We exclude customizationsVscode from Equatable by custom implementation:

