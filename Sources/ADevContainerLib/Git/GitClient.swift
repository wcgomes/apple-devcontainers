import Foundation

/// Host-resolved git author identity (never invented).
public struct GitAuthorIdentity: Equatable, Sendable {
    public var name: String?
    public var email: String?

    public init(name: String? = nil, email: String? = nil) {
        self.name = name
        self.email = email
    }

    /// Both fields non-empty after trim.
    public var isComplete: Bool {
        let n = (name ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        let e = (email ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        return !n.isEmpty && !e.isEmpty
    }

    public var trimmedName: String {
        (name ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
    }

    public var trimmedEmail: String {
        (email ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
    }
}

/// Host git process boundary for clone.
///
/// Config-only fetch inherits the process environment so host `credential.helper`
/// and SSH agent apply. Full workspace populate runs **inside** the container;
/// HTTPS credentials are resolved separately via `GitCredentialProviding`.
/// There is no GCM detection/install and no PAT/token CLI surface as primary UX.
public protocol GitClient: Sendable {
    /// Resolve a usable `git` on PATH. Throws structured `git_missing` when absent.
    func requireGit() throws -> String

    /// Sparse and/or shallow clone sufficient to obtain devcontainer config files only.
    /// `directory` must not already exist as a non-empty git work tree (caller provides empty path).
    func fetchConfig(url: String, into directory: String) throws

    /// Full clone of `url` into `directory` on the host.
    /// Retained as a utility; clone happy path uses in-container git instead.
    func fullClone(url: String, into directory: String) throws

    /// Resolve `user.name` / `user.email` from a git work tree (includeIf by remote applies).
    /// Missing or empty values → nil for that field. Never invents defaults.
    func resolveAuthorIdentity(in directory: String) -> GitAuthorIdentity

    /// Read only the repository-local `user.name` / `user.email` pair.
    /// Missing or empty values → nil for that field. Never consults global config.
    func readLocalAuthorIdentity(in directory: String) -> GitAuthorIdentity
}

/// Production git client via `ProcessRunning` (default: host environment).
public struct HostGitClient: GitClient {
    public var runner: any ProcessRunning
    /// Override PATH lookup for tests (`nil` outer → real lookup; `.some(nil)` → missing).
    public var gitPathOverride: String??

    public init(
        runner: any ProcessRunning = FoundationProcessRunner(),
        gitPathOverride: String?? = nil
    ) {
        self.runner = runner
        self.gitPathOverride = gitPathOverride
    }

    public func requireGit() throws -> String {
        if let override = gitPathOverride {
            // Explicit override (including tests): nil → missing; non-nil trusted without isExecutable.
            guard let path = override else {
                throw Self.missingGitError()
            }
            return path
        }
        if let path = Self.whichGit() {
            return path
        }
        throw Self.missingGitError()
    }

    public func fetchConfig(url: String, into directory: String) throws {
        let git = try requireGit()
        // Prefer sparse+shallow config-only fetch; fall back to shallow full tree.
        // Always pass `--` before the URL so a malicious/odd URL cannot be parsed as a git option.
        do {
            try runGit(
                git,
                [
                    "clone",
                    "--depth", "1",
                    "--filter=blob:none",
                    "--sparse",
                    "--",
                    url,
                    directory
                ],
                redactCredentialMaterial: url
            )
            // Cone-mode includes the whole `.devcontainer/` tree (features/<id>) plus root files.
            try runGit(
                git,
                ["-C", directory, "sparse-checkout", "set", "--cone", ".devcontainer"]
            )
        } catch {
            // Clean partial and fall back to shallow clone for correctness.
            try? FileManager.default.removeItem(atPath: directory)
            try runGit(
                git,
                ["clone", "--depth", "1", "--", url, directory],
                redactCredentialMaterial: url
            )
        }
    }

    public func fullClone(url: String, into directory: String) throws {
        let git = try requireGit()
        try runGit(
            git,
            ["clone", "--", url, directory],
            redactCredentialMaterial: url
        )
    }

    public func resolveAuthorIdentity(in directory: String) -> GitAuthorIdentity {
        guard let git = try? requireGit() else {
            return GitAuthorIdentity()
        }
        let name = configGet(git: git, directory: directory, key: "user.name")
        let email = configGet(git: git, directory: directory, key: "user.email")
        return GitAuthorIdentity(name: name, email: email)
    }

    public func readLocalAuthorIdentity(in directory: String) -> GitAuthorIdentity {
        guard let git = try? requireGit() else {
            return GitAuthorIdentity()
        }
        let name = configGet(git: git, directory: directory, key: "user.name", scope: "--local")
        let email = configGet(git: git, directory: directory, key: "user.email", scope: "--local")
        return GitAuthorIdentity(name: name, email: email)
    }

    // MARK: - Internals

    /// `git -C dir config --get key` → trimmed value, or nil on failure/empty.
    private func configGet(
        git: String,
        directory: String,
        key: String,
        scope: String? = nil
    ) -> String? {
        let result: ProcessResult
        do {
            var arguments = ["-C", directory, "config"]
            if let scope {
                arguments.append(scope)
            }
            arguments += ["--get", key]
            result = try runner.run(
                executable: git,
                arguments: arguments,
                environment: nil,
                currentDirectory: nil
            )
        } catch {
            return nil
        }
        guard result.succeeded else { return nil }
        let value = result.stdoutString.trimmingCharacters(in: .whitespacesAndNewlines)
        return value.isEmpty ? nil : value
    }

    private func runGit(
        _ git: String,
        _ arguments: [String],
        redactCredentialMaterial: String? = nil
    ) throws {
        let result = try runner.run(
            executable: git,
            arguments: arguments,
            environment: nil, // inherit host env (credential.helper / SSH agent)
            currentDirectory: nil
        )
        guard result.succeeded else {
            var detail = [
                result.stderrString.trimmingCharacters(in: .whitespacesAndNewlines),
                result.stdoutString.trimmingCharacters(in: .whitespacesAndNewlines)
            ].filter { !$0.isEmpty }.joined(separator: " | ")
            if let material = redactCredentialMaterial {
                detail = Self.redactURLUserinfo(in: detail, originalURL: material)
            }
            throw CLIError(
                code: CLIErrorCode.gitFailed,
                message: "git \(arguments.first ?? "") failed (exit \(result.exitCode))"
                    + (detail.isEmpty ? "" : ": \(detail)"),
                hint: "Ensure the git URL is reachable with your host credentials (credential.helper / SSH agent)"
            )
        }
    }

    /// Replace embedded `scheme://userinfo@host` forms in error text so tokens/passwords are not logged.
    static func redactURLUserinfo(in text: String, originalURL: String) -> String {
        let trimmed = originalURL.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let at = trimmed.range(of: "@"),
              let scheme = trimmed.range(of: "://"),
              scheme.upperBound < at.lowerBound
        else {
            return text
        }
        let redacted = ContainerIdentity.normalizeGitURL(trimmed)
        guard redacted != trimmed else { return text }
        return text.replacingOccurrences(of: trimmed, with: redacted)
    }

    public static func whichGit(fileManager: FileManager = .default) -> String? {
        let fm = fileManager
        if let pathEnv = ProcessInfo.processInfo.environment["PATH"] {
            for dir in pathEnv.split(separator: ":") {
                let candidate = "\(dir)/git"
                if fm.isExecutableFile(atPath: candidate) {
                    return candidate
                }
            }
        }
        // Common absolute fallbacks
        for candidate in ["/usr/bin/git", "/opt/homebrew/bin/git", "/usr/local/bin/git"] {
            if fm.isExecutableFile(atPath: candidate) {
                return candidate
            }
        }
        return nil
    }

    private static func missingGitError() -> CLIError {
        CLIError(
            code: CLIErrorCode.gitMissing,
            property: "git",
            message: "Host git is required for clone but was not found on PATH",
            hint: "Install git and ensure it is on PATH; clone uses host git for config fetch and HTTPS credential fill"
        )
    }
}
