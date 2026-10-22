import Darwin
import Foundation

/// Bind-only, host-local eligibility. Socket metadata is not an authentication probe.
enum SSHForwardingPolicy {
    static let label = "devcontainer.ssh_forwarded"
    struct Decision {
        var automatic = false
        var warning: String?
    }

    static func evaluate(
        workspace: String,
        environment: [String: String],
        explicitSSH: Bool,
        runner: (any ProcessRunning)? = nil,
        gitPath: String? = nil
    ) -> Decision {
        // Explicit intent retains the existing inherited runtime environment/behavior.
        guard !explicitSSH else { return Decision() }
        let git = gitPath ?? (environment["PATH"] ?? "/usr/bin:/bin")
            .split(separator: ":").map { String($0) + "/git" }
            .first { $0.hasPrefix("/") && FileManager.default.isExecutableFile(atPath: $0) }
        guard let git else { return Decision() }
        let selected = runner ?? LifecycleRunner.hostProcessRunnerOverride ?? CredentialProviderProcessRunner(timeout: 3)
        var discoveryEnvironment = HostGitCredential.strippingCredentialTraces(environment)
        discoveryEnvironment.removeValue(forKey: "ADEVCONTAINER_GIT_TOKEN")
        discoveryEnvironment["GIT_TERMINAL_PROMPT"] = "0"
        // No shell, transport, credential helper or raw diagnostic output. Both URL directions matter.
        guard let result = try? selected.run(
            executable: git, arguments: ["-C", workspace, "remote", "-v"],
            environment: discoveryEnvironment, currentDirectory: nil, stdinData: nil
        ), result.succeeded else { return Decision() }
        // Reuse the existing parser, changing only the terminal direction marker, never URL bytes.
        let bothDirections = result.stdoutString.split(whereSeparator: \.isNewline).map { line in
            line.hasSuffix("(push)") ? String(line.dropLast(6)) + "(fetch)" : String(line)
        }.joined(separator: "\n")
        let urls = GitCredentialDiscovery.uniqueFetchURLs(from: bothDirections)
        guard urls.contains(where: isSSH) else { return Decision() }
        guard hasSocket(environment) else {
            return Decision(warning: "SSH remote detected but SSH_AUTH_SOCK does not identify a host agent socket; continuing without automatic SSH forwarding. Expose your host agent via SSH_AUTH_SOCK, then run \(CommandSurface.commandPrefix) rebuild if the container was already created.")
        }
        return Decision(automatic: true)
    }

    private static func hasSocket(_ environment: [String: String]) -> Bool {
        let path = environment["SSH_AUTH_SOCK"] ?? ""
        var metadata = stat()
        return !path.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            && !path.utf8.contains(0) && stat(path, &metadata) == 0
            && metadata.st_mode & S_IFMT == S_IFSOCK
    }

    private static func isSSH(_ url: String) -> Bool {
        // Exclude local paths before using clone's classifier, which intentionally stays unchanged.
        guard !url.hasPrefix("/"), !url.hasPrefix("./"), !url.hasPrefix("../"), !url.hasPrefix("~"),
              !url.contains(where: { $0.isWhitespace || $0.isNewline }) else { return false }
        // Git's transport::address selects a remote helper, not SCP. Colons
        // inside a bracketed IPv6 host (or later in an SCP path) are not this separator.
        if let colon = url.firstIndex(of: ":"),
           url[url.index(after: colon)...].hasPrefix(":"), !url[..<colon].contains("[") { return false }
        if !url.contains("://"), let colon = url.firstIndex(of: ":"), url[..<colon].contains("/") { return false }
        if GitURLClassifier.kind(of: url) == .ssh { return true }
        guard !url.contains("://"), let colon = url.firstIndex(of: ":"),
              colon != url.startIndex, url.index(after: colon) != url.endIndex else { return false }
        let host = url[..<colon]
        return !host.contains("/") && !host.contains("@")
    }

    static func warnForExisting(labels: [String: String], name: String, environment: [String: String]) {
        guard labels[ContainerIdentity.labelWorkspaceMode] == ContainerIdentity.workspaceModeBind,
              labels[label] != "true", hasSocket(environment), let workspace = labels[ContainerIdentity.labelLocalFolder],
              evaluate(workspace: workspace, environment: environment, explicitSSH: false).automatic else { return }
        StatusPrinter.warning("SSH forwarding is fixed at container creation; if unavailable in this container, run '\(CommandSurface.commandPrefix) rebuild --name \(name)' to apply it. Existing forwarding has not been changed.")
    }
}
