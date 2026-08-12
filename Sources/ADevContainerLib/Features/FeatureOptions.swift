import Foundation

/// Map feature options to install.sh environment variables (Features convention).
public enum FeatureOptions {
    /// Merge user options over metadata defaults.
    public static func resolvedOptions(
        user: [String: FeatureOptionValue],
        defaults: [String: FeatureOptionValue]
    ) -> [String: FeatureOptionValue] {
        var merged = defaults
        for (k, v) in user {
            merged[k] = v
        }
        return merged
    }

    /// Convert option name `version` → env `VERSION` (UPPER_SNAKE_CASE).
    public static func envName(forOption optionKey: String) -> String {
        var out = ""
        var prevLower = false
        for ch in optionKey {
            if ch == "-" || ch == " " || ch == "." {
                out.append("_")
                prevLower = false
                continue
            }
            if ch.isUppercase, prevLower {
                out.append("_")
            }
            out.append(ch.uppercased())
            prevLower = ch.isLowercase
        }
        // Collapse multiple underscores
        while out.contains("__") {
            out = out.replacingOccurrences(of: "__", with: "_")
        }
        return out.trimmingCharacters(in: CharacterSet(charactersIn: "_"))
    }

    /// Environment map for install.sh from resolved options (UPPER_SNAKE keys).
    /// Feature metadata `containerEnv` is emitted as Dockerfile `ENV` lines (install-time,
    /// BuildKit expands `$VAR`/`${VAR}`) and merged again at runtime create/exec (config-wins).
    public static func installEnvironment(
        user: [String: FeatureOptionValue],
        defaults: [String: FeatureOptionValue]
    ) -> [String: String] {
        let merged = resolvedOptions(user: user, defaults: defaults)
        var env: [String: String] = [:]
        for key in merged.keys.sorted() {
            env[envName(forOption: key)] = merged[key]!.stringValue
        }
        return env
    }

    /// Standard Features install contract user env (`_REMOTE_USER`, `_CONTAINER_USER`, homes).
    /// Each side falls back to the other, then inspected base image USER, then `"root"`.
    /// Homes: `/root` or `/home/<user>`. Never hardcodes editor usernames.
    ///
    /// - Parameter baseUser: Base image OCI `USER` from a **successful** inspect (nil/empty → `root`).
    ///   Callers MUST fail closed on inspect failure before invoking with a fabricated user.
    public static func userInstallEnvironment(
        remoteUser: String?,
        containerUser: String?,
        baseUser: String? = nil
    ) -> [String: String] {
        let fallback = RemoteUserResolution.nonEmptyTrimmed(baseUser) ?? "root"
        let remote = nonEmpty(remoteUser) ?? nonEmpty(containerUser) ?? fallback
        let container = nonEmpty(containerUser) ?? nonEmpty(remoteUser) ?? fallback
        return [
            "_REMOTE_USER": remote,
            "_REMOTE_USER_HOME": defaultHome(for: remote),
            "_CONTAINER_USER": container,
            "_CONTAINER_USER_HOME": defaultHome(for: container)
        ]
    }

    private static func nonEmpty(_ s: String?) -> String? {
        guard let s else { return nil }
        let t = s.trimmingCharacters(in: .whitespacesAndNewlines)
        return t.isEmpty ? nil : t
    }

    private static func defaultHome(for user: String) -> String {
        user == "root" ? "/root" : "/home/\(user)"
    }

    /// Dockerfile `ENV KEY=value` lines for feature metadata `containerEnv`.
    /// Values preserve `$VAR` / `${VAR}` for BuildKit/Docker ENV expansion — never
    /// shell single-quote (that would wipe PATH when value is `$PATH:…`).
    public static func dockerfileEnvLines(_ env: [String: String]) -> [String] {
        guard !env.isEmpty else { return [] }
        return env.keys.sorted().map { key in
            "ENV \(key)=\(dockerfileEnvValue(env[key] ?? ""))"
        }
    }

    /// Shell export prefix for RUN install.sh (options + user contract keys).
    /// Uses single-quote escaping; do **not** put feature `containerEnv` with `$VAR`
    /// refs through this path — use `dockerfileEnvLines` instead.
    public static func installEnvExportPrefix(_ env: [String: String]) -> String {
        guard !env.isEmpty else { return "" }
        let parts = env.keys.sorted().map { key in
            let val = shellEscape(env[key] ?? "")
            return "\(key)=\(val)"
        }
        return parts.joined(separator: " ") + " "
    }

    /// Escape a value for a Dockerfile `ENV KEY=…` assignment without blocking `$` expansion.
    private static func dockerfileEnvValue(_ s: String) -> String {
        if s.isEmpty { return "\"\"" }
        // Unquoted when safe; include $ { } so PATH=$PATH:$DOTNET_ROOT stays expandable.
        let safe = CharacterSet.alphanumerics.union(CharacterSet(charactersIn: "-_./:+@${}"))
        if s.unicodeScalars.allSatisfy({ safe.contains($0) }) {
            return s
        }
        // Double-quote when whitespace/special chars present; Docker still expands $VAR.
        let escaped = s
            .replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "\"", with: "\\\"")
        return "\"\(escaped)\""
    }

    private static func shellEscape(_ s: String) -> String {
        // Single-quote with embedded ' → '\'' 
        if s.isEmpty { return "''" }
        if s.unicodeScalars.allSatisfy({ CharacterSet.alphanumerics.contains($0) || "-_./:+@".unicodeScalars.contains($0) }) {
            return s
        }
        let escaped = s.replacingOccurrences(of: "'", with: "'\\''")
        return "'\(escaped)'"
    }
}
