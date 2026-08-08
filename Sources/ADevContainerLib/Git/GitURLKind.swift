import Foundation

/// Classification of a git remote URL for clone auth routing.
public enum GitURLKind: Equatable, Sendable {
    /// SCP-like (`git@host:path`) or `ssh://…`.
    case ssh
    /// `http://` or `https://`.
    case https
    /// Other / opaque forms (best-effort passthrough).
    case other
}

public enum GitURLClassifier {
    /// Classify a caller-supplied git URL for auth and populate strategy.
    public static func kind(of rawURL: String) -> GitURLKind {
        let url = rawURL.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !url.isEmpty else { return .other }

        let lower = url.lowercased()
        if lower.hasPrefix("ssh://") {
            return .ssh
        }
        if lower.hasPrefix("https://") || lower.hasPrefix("http://") {
            return .https
        }
        // scheme:// that is not http(s)/ssh
        if url.contains("://") {
            return .other
        }
        // SCP-like: user@host:path (colon after @, no scheme)
        if let at = url.firstIndex(of: "@") {
            let afterAt = url[url.index(after: at)...]
            if afterAt.contains(":") {
                return .ssh
            }
        }
        return .other
    }

    /// Parse HTTPS/HTTP URL into git-credential fill fields (protocol, host, path).
    /// Returns nil when the URL is not an http(s) form.
    public static func httpsCredentialFields(for rawURL: String) -> (protocolName: String, host: String, path: String)? {
        let trimmed = rawURL.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let comps = URLComponents(string: trimmed),
              let scheme = comps.scheme?.lowercased(),
              scheme == "http" || scheme == "https",
              let host = comps.host, !host.isEmpty
        else {
            return nil
        }
        var path = comps.path
        if path.hasPrefix("/") {
            path = String(path.dropFirst())
        }
        return (scheme, host, path)
    }
}
