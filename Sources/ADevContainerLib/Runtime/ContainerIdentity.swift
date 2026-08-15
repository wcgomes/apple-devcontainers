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
    /// Comma-separated config `type=volume` mount source names (clone/managed purge).
    public static let labelConfigVolumes = "devcontainer.config_volumes"
    /// Container workspace folder for exec (volume-mode).
    public static let labelWorkspaceFolder = "devcontainer.workspace_folder"
    /// Resolved remote connection user for exec/attach. New creates stamp non-empty; empty is legacy only.
    public static let labelRemoteUser = "devcontainer.remote_user"
    public static let workspaceModeVolume = "volume"
    public static let workspaceModeBind = "bind"

    /// Resource base (≤20) from workspace folder basename only. MUST NOT use config `name`.
    public static func humanBase(workspacePath: String) -> String {
        let raw = ((workspacePath as NSString).standardizingPath as NSString).lastPathComponent
        return sanitizeBase(raw)
    }

    /// Shared DNS-safe sanitize: lowercase; non-[a-z0-9-] → `-`; collapse hyphens; trim hyphens.
    public static func sanitizeDNS(_ raw: String) -> String {
        raw
            .lowercased()
            .replacingOccurrences(of: "[^a-z0-9-]", with: "-", options: .regularExpression)
            .replacingOccurrences(of: "-{2,}", with: "-", options: .regularExpression)
            .trimmingCharacters(in: CharacterSet(charactersIn: "-"))
    }

    /// Sanitize a human-readable name to DNS-safe base (≤20).
    /// Non-[a-z0-9-] → `-`, collapse consecutive hyphens, trim leading/trailing hyphens, clip ≤20.
    public static func sanitizeBase(_ raw: String) -> String {
        String(sanitizeDNS(raw).prefix(20)).trimmingCharacters(in: CharacterSet(charactersIn: "-"))
    }

    /// Sanitize a create `--name` / DNS hostname (≤63). No `adev-` prefix and no identity hash.
    public static func sanitizeCreateName(_ raw: String) -> String {
        String(sanitizeDNS(raw).prefix(63)).trimmingCharacters(in: CharacterSet(charactersIn: "-"))
    }

    /// Bind-mode identity hash12 (workspace path + config path). Used for occupancy tests and
    /// any hashed sidecar that still keys off bind identity — not appended to the create name.
    public static func bindWorkspaceHash12(workspacePath: String, configPath: String) -> String {
        let workspace = (workspacePath as NSString).standardizingPath
        let config = (configPath as NSString).standardizingPath
        let material = "\(workspace)|\(config)"
        let digest = SHA256.hash(data: Data(material.utf8))
        let hex = digest.map { String(format: "%02x", $0) }.joined()
        return String(hex.prefix(12))
    }

    /// Structured error when sanitize yields an empty create name. No invented `adev-{hash12}` fallback.
    public static func emptyCreateNameError() -> CLIError {
        CLIError(
            code: CLIErrorCode.invalidCreateName,
            property: "name",
            message: "Create name is empty after DNS-safe sanitize",
            hint: "Set a DNS-safe \"name\" in devcontainer.json (letters, digits, hyphens)"
        )
    }

    /// DNS-friendly create name from config `name` or a mode-specific fallback. Empty after sanitize
    /// returns `""` — callers that create (`up`/`clone`/resolve) MUST fail via `requireCreateName`.
    public static func createName(configName: String?, fallback: String) -> String {
        let raw: String
        if let name = configName?.trimmingCharacters(in: .whitespacesAndNewlines), !name.isEmpty {
            raw = name
        } else {
            raw = fallback
        }
        return sanitizeCreateName(raw)
    }

    public static func requireCreateName(_ name: String) throws -> String {
        guard !name.isEmpty else { throw emptyCreateNameError() }
        return name
    }

    /// Resource identity stem `adev-{base}-{hash12}` (empty base → `adev-{hash12}`).
    /// Same stem used for product workspace volumes (`{stem}-ws`). Not the DNS create name.
    public static func resourceIdentityStem(base: String, hash12: String) -> String {
        composeContainerName(base: base, hash12: hash12)
    }

    /// Bind-mode `${devcontainerId}` stem: folder basename + path+config `hash12`.
    public static func bindResourceIdentityStem(
        workspacePath: String,
        configPath: String
    ) -> String {
        resourceIdentityStem(
            base: humanBase(workspacePath: workspacePath),
            hash12: bindWorkspaceHash12(workspacePath: workspacePath, configPath: configPath)
        )
    }

    /// Deterministic DNS-safe create name ≤ 63 chars. Prefers config `name`; else workspace basename.
    /// MUST NOT prefix `adev-` or append an identity hash.
    public static func containerName(
        workspacePath: String,
        configPath: String,
        configName: String? = nil
    ) -> String {
        _ = configPath
        let workspace = (workspacePath as NSString).standardizingPath
        let fallback = (workspace as NSString).lastPathComponent
        return createName(configName: configName, fallback: fallback)
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

        /// `${devcontainerId}` stem: `adev-{base}-{hash12}` (same material as `workspaceVolumeName`).
        public var resourceIdentityStem: String {
            ContainerIdentity.resourceIdentityStem(base: base, hash12: hash12)
        }
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

        let fallback = repoBasename(fromGitURL: gitURL)
        // Resource base is repo basename only — config `name` drives create name, not `*-ws`/stem.
        let base = sanitizeBase(fallback)
        let container = createName(configName: configName, fallback: fallback)
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

    // MARK: - Create-name occupancy

    public enum WorkspaceIdentityKey: Equatable, Sendable {
        case bind(localFolder: String, configFile: String)
        case volume(gitURL: String, configIdentity: String)
    }

    public enum CreateNameOccupancy: Equatable, Sendable {
        case none
        case sameWorkspaceSameName(ContainerInfo)
        case sameWorkspaceDifferentName(ContainerInfo)
        case foreign(ContainerInfo)
    }

    public static func matchesWorkspace(
        _ info: ContainerInfo,
        workspace: WorkspaceIdentityKey
    ) -> Bool {
        switch workspace {
        case .bind(let localFolder, let configFile):
            let folder = (localFolder as NSString).standardizingPath
            let config = (configFile as NSString).standardizingPath
            let stampedFolder = (info.labels[labelLocalFolder] ?? "")
                .trimmingCharacters(in: .whitespacesAndNewlines)
            let stampedConfig = (info.labels[labelConfigFile] ?? "")
                .trimmingCharacters(in: .whitespacesAndNewlines)
            return (stampedFolder as NSString).standardizingPath == folder
                && (stampedConfig as NSString).standardizingPath == config
        case .volume(let gitURL, let configIdentity):
            let wantURL = normalizeGitURL(gitURL)
            let stampedURL = normalizeGitURL(info.labels[labelGitURL] ?? "")
            guard !wantURL.isEmpty, stampedURL == wantURL else { return false }
            return configIdentityMatches(
                stamped: info.labels[labelConfigFile] ?? "",
                expected: configIdentity
            )
        }
    }

    public static func configIdentityMatches(stamped: String, expected: String) -> Bool {
        let a = stamped.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let b = expected.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
            .trimmingCharacters(in: .whitespacesAndNewlines)
        if a.isEmpty || b.isEmpty { return false }
        if a == b { return true }
        return a.hasSuffix("/" + b) || b.hasSuffix("/" + a)
    }

    public static func containerHasName(_ info: ContainerInfo, _ name: String) -> Bool {
        info.id == name || info.name == name
    }

    /// Classify occupants of `desiredName` and any same-workspace leftover under another name.
    /// Same-workspace leftover wins over a foreign occupant of the desired name (delete-hint).
    public static func classifyOccupancy(
        desiredName: String,
        containers: [ContainerInfo],
        workspace: WorkspaceIdentityKey
    ) -> CreateNameOccupancy {
        let sameWorkspace = containers.filter { matchesWorkspace($0, workspace: workspace) }
        if let same = sameWorkspace.first(where: { containerHasName($0, desiredName) }) {
            return .sameWorkspaceSameName(same)
        }
        if let leftover = sameWorkspace.first {
            return .sameWorkspaceDifferentName(leftover)
        }
        if let occupant = containers.first(where: { containerHasName($0, desiredName) }) {
            return .foreign(occupant)
        }
        return .none
    }

    public static func nameInUseError(name: String) -> CLIError {
        CLIError(
            code: CLIErrorCode.containerNameInUse,
            property: "name",
            message: "Container name '\(name)' is in use and is not this workspace",
            hint: "Change \"name\" in devcontainer.json, or delete the occupant: adevcontainer delete --name \(name)"
        )
    }

    public static func workspaceExistsError(existingName: String) -> CLIError {
        CLIError(
            code: CLIErrorCode.workspaceContainerExists,
            message: "This workspace already has a managed container '\(existingName)'",
            hint: "Delete it first: adevcontainer delete --name \(existingName)"
        )
    }

    public static func cloneFailClosedError(existingName: String) -> CLIError {
        CLIError(
            code: CLIErrorCode.workspaceContainerExists,
            message: "Container '\(existingName)' already exists for this repository",
            hint: "Delete it first: adevcontainer delete --name \(existingName)"
        )
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
