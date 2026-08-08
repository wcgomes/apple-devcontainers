import Foundation

/// HTTPS credentials obtained on the host for a one-shot in-container clone.
public struct GitHTTPSCredentials: Equatable, Sendable {
    public var username: String
    public var password: String

    public init(username: String, password: String) {
        self.username = username
        self.password = password
    }
}

/// Host-side HTTPS credential lookup for clone populate (not GCM product integration).
public protocol GitCredentialProviding: Sendable {
    /// Resolve HTTPS credentials for `url` via host git credential helper / fallbacks.
    /// Returns nil when no credentials are available (caller maps to structured error).
    func fillHTTPS(url: String) throws -> GitHTTPSCredentials?
}

/// Production credential provider: `git credential fill`, then optional env/gh fallbacks.
///
/// Does **not** install or detect GCM. Uses whatever `credential.helper` the host already has
/// (osxkeychain, manager, store, etc.) via standard git credential protocol.
public struct HostGitCredential: GitCredentialProviding {
    public var runner: any ProcessRunning
    /// Override PATH lookup for tests (`nil` outer → real lookup; `.some(nil)` → missing git).
    public var gitPathOverride: String??
    /// Environment for fill + fallbacks (defaults to process environment).
    public var environment: [String: String]
    /// Override `gh` path lookup for tests.
    public var ghPathOverride: String??

    public init(
        runner: any ProcessRunning = FoundationProcessRunner(),
        gitPathOverride: String?? = nil,
        environment: [String: String] = ProcessInfo.processInfo.environment,
        ghPathOverride: String?? = nil
    ) {
        self.runner = runner
        self.gitPathOverride = gitPathOverride
        self.environment = environment
        self.ghPathOverride = ghPathOverride
    }

    public func fillHTTPS(url: String) throws -> GitHTTPSCredentials? {
        // Escape hatch: explicit token (not primary UX).
        if let token = environment["ADEVCONTAINER_GIT_TOKEN"]?
            .trimmingCharacters(in: .whitespacesAndNewlines),
           !token.isEmpty
        {
            return GitHTTPSCredentials(username: "x-access-token", password: token)
        }

        if let fromGit = try fillViaGitCredential(url: url) {
            return fromGit
        }

        // Optional github.com fallback when `gh` is logged in.
        if let fromGH = try fillViaGitHubCLI(url: url) {
            return fromGH
        }

        return nil
    }

    // MARK: - git credential fill

    private func fillViaGitCredential(url: String) throws -> GitHTTPSCredentials? {
        guard let fields = GitURLClassifier.httpsCredentialFields(for: url) else {
            return nil
        }
        let git: String
        do {
            git = try resolveGitPath()
        } catch {
            return nil
        }

        var input = "protocol=\(fields.protocolName)\nhost=\(fields.host)\n"
        if !fields.path.isEmpty {
            input += "path=\(fields.path)\n"
        }
        input += "\n"

        let result: ProcessResult
        do {
            result = try runner.run(
                executable: git,
                arguments: ["credential", "fill"],
                environment: mergedEnvironment(),
                currentDirectory: nil,
                stdinData: Data(input.utf8)
            )
        } catch {
            return nil
        }
        guard result.succeeded else { return nil }

        let parsed = Self.parseCredentialOutput(result.stdoutString)
        guard let username = parsed["username"], !username.isEmpty,
              let password = parsed["password"], !password.isEmpty
        else {
            return nil
        }
        return GitHTTPSCredentials(username: username, password: password)
    }

    // MARK: - gh auth token

    private func fillViaGitHubCLI(url: String) throws -> GitHTTPSCredentials? {
        guard let fields = GitURLClassifier.httpsCredentialFields(for: url) else {
            return nil
        }
        let host = fields.host.lowercased()
        guard host == "github.com" || host.hasSuffix(".github.com") else {
            return nil
        }
        guard let gh = resolveGHPath() else { return nil }

        let result: ProcessResult
        do {
            result = try runner.run(
                executable: gh,
                arguments: ["auth", "token"],
                environment: mergedEnvironment(),
                currentDirectory: nil,
                stdinData: nil
            )
        } catch {
            return nil
        }
        guard result.succeeded else { return nil }
        let token = result.stdoutString.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !token.isEmpty else { return nil }
        return GitHTTPSCredentials(username: "x-access-token", password: token)
    }

    // MARK: - Helpers

    private func resolveGitPath() throws -> String {
        if let override = gitPathOverride {
            guard let path = override else {
                throw CLIError(
                    code: CLIErrorCode.gitMissing,
                    property: "git",
                    message: "Host git is required for clone but was not found on PATH",
                    hint: "Install git and ensure it is on PATH"
                )
            }
            return path
        }
        if let path = HostGitClient.whichGit() {
            return path
        }
        throw CLIError(
            code: CLIErrorCode.gitMissing,
            property: "git",
            message: "Host git is required for clone but was not found on PATH",
            hint: "Install git and ensure it is on PATH"
        )
    }

    private func resolveGHPath() -> String? {
        if let override = ghPathOverride {
            return override
        }
        return Self.whichExecutable("gh", environment: environment)
    }

    private func mergedEnvironment() -> [String: String] {
        // Start from process env so PATH helpers work, then overlay explicit map.
        var env = ProcessInfo.processInfo.environment
        for (k, v) in environment {
            env[k] = v
        }
        env["GIT_TERMINAL_PROMPT"] = "0"
        return env
    }

    /// Parse `git credential fill` stdout key=value lines.
    static func parseCredentialOutput(_ text: String) -> [String: String] {
        var result: [String: String] = [:]
        for line in text.split(whereSeparator: \.isNewline) {
            let s = String(line)
            guard let eq = s.firstIndex(of: "=") else { continue }
            let key = String(s[..<eq])
            let value = String(s[s.index(after: eq)...])
            if !key.isEmpty {
                result[key] = value
            }
        }
        return result
    }

    static func whichExecutable(_ name: String, environment: [String: String], fileManager: FileManager = .default) -> String? {
        if let pathEnv = environment["PATH"] ?? ProcessInfo.processInfo.environment["PATH"] {
            for dir in pathEnv.split(separator: ":") {
                let candidate = "\(dir)/\(name)"
                if fileManager.isExecutableFile(atPath: candidate) {
                    return candidate
                }
            }
        }
        for candidate in ["/opt/homebrew/bin/\(name)", "/usr/local/bin/\(name)", "/usr/bin/\(name)"] {
            if fileManager.isExecutableFile(atPath: candidate) {
                return candidate
            }
        }
        return nil
    }
}
