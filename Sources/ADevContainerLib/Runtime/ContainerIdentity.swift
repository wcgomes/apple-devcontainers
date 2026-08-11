import Foundation
import Crypto

public enum ContainerIdentity {
    public static let labelLocalFolder = "devcontainer.local_folder"
    public static let labelConfigFile = "devcontainer.config_file"
    public static let labelConfigHash = "devcontainer.config_hash"
    /// Set on clone-created (managed) containers.
    public static let labelManaged = "devcontainer.managed"
    public static let managedValue = "adevcontainer"
    public static let labelGitURL = "devcontainer.git_url"
    public static let labelWorkspaceVolume = "devcontainer.workspace_volume"
    public static let labelWorkspaceMode = "devcontainer.workspace_mode"
    /// Comma-separated config `type=volume` mount source names (clone/managed prune).
    public static let labelConfigVolumes = "devcontainer.config_volumes"
    /// Container workspace folder for exec (volume-mode).
    public static let labelWorkspaceFolder = "devcontainer.workspace_folder"
    /// remoteUser/containerUser effective user for exec (volume-mode; may be empty).
    public static let labelRemoteUser = "devcontainer.remote_user"
    public static let workspaceModeVolume = "volume"
    public static let workspaceModeBind = "bind"

    /// DNS-safe human base (≤20) from config `name` when non-empty after trim; else workspace basename.
    public static func humanBase(configName: String?, workspacePath: String) -> String {
        let raw: String
        if let name = configName?.trimmingCharacters(in: .whitespacesAndNewlines), !name.isEmpty {
            raw = name
        } else {
            raw = ((workspacePath as NSString).standardizingPath as NSString).lastPathComponent
        }
        return sanitizeBase(raw)
    }

    /// Sanitize a human-readable name to DNS-safe base (≤20).
    /// Non-[a-z0-9-] → `-`, collapse consecutive hyphens, trim leading/trailing hyphens, clip ≤20.
    public static func sanitizeBase(_ raw: String) -> String {
        let base = raw
            .lowercased()
            .replacingOccurrences(of: "[^a-z0-9-]", with: "-", options: .regularExpression)
            .replacingOccurrences(of: "-{2,}", with: "-", options: .regularExpression)
            .trimmingCharacters(in: CharacterSet(charactersIn: "-"))
        return String(base.prefix(20)).trimmingCharacters(in: CharacterSet(charactersIn: "-"))
    }

    /// Deterministic DNS-safe container name ≤ 63 chars from workspace + config path.
    /// Human segment prefers config `name` when set; hash material remains workspace|config paths.
    public static func containerName(
        workspacePath: String,
        configPath: String,
        configName: String? = nil
    ) -> String {
        let workspace = (workspacePath as NSString).standardizingPath
        let config = (configPath as NSString).standardizingPath
        let material = "\(workspace)|\(config)"
        let digest = SHA256.hash(data: Data(material.utf8))
        let hex = digest.map { String(format: "%02x", $0) }.joined()
        let short = String(hex.prefix(12))

        let clippedBase = humanBase(configName: configName, workspacePath: workspace)
        return composeContainerName(base: clippedBase, hash12: short)
    }

    /// Stable hash of resolved config fields that affect runtime shape.
    public static func configHash(from fields: [String: Any]) -> String {
        let data = canonicalJSONData(fields)
        let digest = SHA256.hash(data: data)
        return digest.map { String(format: "%02x", $0) }.joined()
    }

    /// Minimal bind-mode labels (local_folder / config_file / config_hash). Prefer `bindModeLabels` on create.
    public static func labels(
        workspacePath: String,
        configPath: String,
        configHash: String
    ) -> [String: String] {
        bindModeLabels(
            workspacePath: workspacePath,
            configPath: configPath,
            configHash: configHash
        )
    }

    /// Bind-mode (`up`) labels for managed selection (`list` / `exec` / `stop` / …).
    ///
    /// Does **not** set `git_url` or `workspace_volume` (volume-mode only).
    public static func bindModeLabels(
        workspacePath: String,
        configPath: String,
        configHash: String,
        workspaceFolder: String = "",
        remoteUser: String? = nil,
        configVolumeNames: [String] = []
    ) -> [String: String] {
        var labels: [String: String] = [
            labelManaged: managedValue,
            labelWorkspaceMode: workspaceModeBind,
            labelLocalFolder: (workspacePath as NSString).standardizingPath,
            labelConfigFile: (configPath as NSString).standardizingPath,
            labelConfigHash: configHash,
            labelWorkspaceFolder: workspaceFolder,
            labelRemoteUser: remoteUser ?? ""
        ]
        if !configVolumeNames.isEmpty {
            labels[labelConfigVolumes] = configVolumeNames.joined(separator: ",")
        }
        return labels
    }

    // MARK: - Volume-mode identity (clone)

    /// Normalize git URL for durable identity (trim, strip trailing `/` and `.git`, lowercase scheme,
    /// strip `userinfo@` from scheme:// URLs so embedded tokens never enter labels/hash material).
    ///
    /// SCP-like forms (`git@host:path`) keep the username — it is not a secret and is required shape.
    public static func normalizeGitURL(_ url: String) -> String {
        var s = url.trimmingCharacters(in: .whitespacesAndNewlines)
        while s.hasSuffix("/") {
            s.removeLast()
        }
        if s.count >= 4 {
            let tail = s.suffix(4)
            if tail.lowercased() == ".git" {
                s = String(s.dropLast(4))
                while s.hasSuffix("/") {
                    s.removeLast()
                }
            }
        }
        if let schemeRange = s.range(of: "://") {
            let scheme = s[..<schemeRange.lowerBound].lowercased()
            var rest = String(s[schemeRange.upperBound...])
            // Strip userinfo (user / user:pass / token) before host — never store credentials in labels.
            if let at = rest.firstIndex(of: "@") {
                rest = String(rest[rest.index(after: at)...])
            }
            s = scheme + "://" + rest
        }
        return s
    }

    /// Repository basename from a git URL (not a host folder path).
    public static func repoBasename(fromGitURL url: String) -> String {
        let normalized = normalizeGitURL(url)
        var path = normalized
        if normalized.contains("://"),
           let schemeEnd = normalized.range(of: "://") {
            path = String(normalized[schemeEnd.upperBound...])
            if let slash = path.firstIndex(of: "/") {
                path = String(path[path.index(after: slash)...])
            }
        } else if let at = path.firstIndex(of: "@"),
                  let colon = path[path.index(after: at)...].firstIndex(of: ":"),
                  !path.contains("://") {
            // git@host:org/repo
            path = String(path[path.index(after: colon)...])
        }
        let base = (path as NSString).lastPathComponent
        return base.isEmpty ? "repo" : base
    }

    /// Volume-mode identity: hash(normalizedURL + configRelPath); base from name else repo basename.
    public struct VolumeModeIdentity: Equatable, Sendable {
        public var hash12: String
        public var base: String
        public var containerName: String
        public var workspaceVolumeName: String
        public var normalizedGitURL: String
        public var configRelativePath: String
    }

    public static func volumeModeIdentity(
        gitURL: String,
        configRelativePath: String,
        configName: String?
    ) -> VolumeModeIdentity {
        let normalized = normalizeGitURL(gitURL)
        let rel = configRelativePath.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        let material = "\(normalized)|\(rel)"
        let digest = SHA256.hash(data: Data(material.utf8))
        let hex = digest.map { String(format: "%02x", $0) }.joined()
        let hash12 = String(hex.prefix(12))

        let base: String
        if let name = configName?.trimmingCharacters(in: .whitespacesAndNewlines), !name.isEmpty {
            base = sanitizeBase(name)
        } else {
            base = sanitizeBase(repoBasename(fromGitURL: gitURL))
        }

        let container = composeContainerName(base: base, hash12: hash12)
        let volume = composeWorkspaceVolumeName(base: base, hash12: hash12)
        return VolumeModeIdentity(
            hash12: hash12,
            base: base,
            containerName: container,
            workspaceVolumeName: volume,
            normalizedGitURL: normalized,
            configRelativePath: rel
        )
    }

    public static func volumeModeLabels(
        identity: VolumeModeIdentity,
        configHash: String,
        configVolumeNames: [String] = [],
        workspaceFolder: String = "",
        remoteUser: String? = nil
    ) -> [String: String] {
        var labels: [String: String] = [
            labelManaged: managedValue,
            labelGitURL: identity.normalizedGitURL,
            labelWorkspaceVolume: identity.workspaceVolumeName,
            labelWorkspaceMode: workspaceModeVolume,
            labelLocalFolder: "volume://\(identity.workspaceVolumeName)",
            labelConfigFile: identity.configRelativePath,
            labelConfigHash: configHash,
            labelWorkspaceFolder: workspaceFolder,
            labelRemoteUser: remoteUser ?? ""
        ]
        if !configVolumeNames.isEmpty {
            labels[labelConfigVolumes] = configVolumeNames.joined(separator: ",")
        }
        return labels
    }

    /// Parse `devcontainer.config_volumes` label (comma-separated sources).
    public static func parseConfigVolumeNames(from labels: [String: String]) -> [String] {
        guard let raw = labels[labelConfigVolumes], !raw.isEmpty else { return [] }
        return raw.split(separator: ",")
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
    }

    /// `adev-{base}-{hash12}` (empty base → `adev-{hash12}`); ≤63; retains hash12.
    public static func composeContainerName(base: String, hash12: String) -> String {
        let maxLen = 63
        if base.isEmpty {
            return String("adev-\(hash12)".prefix(maxLen))
        }
        // adev- + base + - + hash12
        let fixed = 5 + 1 + hash12.count // "adev-" + "-" + hash
        let maxBase = max(0, maxLen - fixed)
        let clipped = String(base.prefix(maxBase))
            .trimmingCharacters(in: CharacterSet(charactersIn: "-"))
        if clipped.isEmpty {
            return String("adev-\(hash12)".prefix(maxLen))
        }
        return "adev-\(clipped)-\(hash12)"
    }

    /// `adev-{base}-{hash12}-ws`; retains hash12 and `-ws` when clipped.
    public static func composeWorkspaceVolumeName(base: String, hash12: String) -> String {
        let maxLen = 63
        let suffix = "-\(hash12)-ws"
        if base.isEmpty {
            return String("adev\(suffix)".prefix(maxLen))
        }
        let prefix = "adev-"
        let maxBase = max(0, maxLen - prefix.count - suffix.count)
        let clipped = String(base.prefix(maxBase))
            .trimmingCharacters(in: CharacterSet(charactersIn: "-"))
        if clipped.isEmpty {
            return String("adev\(suffix)".prefix(maxLen))
        }
        return "\(prefix)\(clipped)\(suffix)"
    }

    private static func canonicalJSONData(_ value: Any) -> Data {
        // Sort keys for stability when possible.
        if let dict = value as? [String: Any] {
            let sortedKeys = dict.keys.sorted()
            var parts: [String] = []
            for key in sortedKeys {
                let k = escapeJSONString(key)
                let v = String(data: canonicalJSONData(dict[key]!), encoding: .utf8) ?? "null"
                parts.append("\"\(k)\":\(v)")
            }
            return Data("{\(parts.joined(separator: ","))}".utf8)
        }
        if let arr = value as? [Any] {
            let parts = arr.map { String(data: canonicalJSONData($0), encoding: .utf8) ?? "null" }
            return Data("[\(parts.joined(separator: ","))]".utf8)
        }
        if let s = value as? String {
            return Data("\"\(escapeJSONString(s))\"".utf8)
        }
        if let b = value as? Bool {
            return Data((b ? "true" : "false").utf8)
        }
        if let n = value as? NSNumber {
            // Bool is caught above; NSNumber always serializes as a number.
            return Data("\(n)".utf8)
        }
        if value is NSNull {
            return Data("null".utf8)
        }
        return Data("null".utf8)
    }

    private static func escapeJSONString(_ s: String) -> String {
        var out = ""
        for ch in s {
            switch ch {
            case "\\": out += "\\\\"
            case "\"": out += "\\\""
            case "\n": out += "\\n"
            case "\r": out += "\\r"
            case "\t": out += "\\t"
            default: out.append(ch)
            }
        }
        return out
    }
}
