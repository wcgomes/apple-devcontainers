import Foundation

/// Writes a complete author pair to the resolved connection user's global git config.
public struct GitAuthorIdentitySync: Sendable {
    public init() {}

    public func write(
        identity: GitAuthorIdentity,
        containerId: String,
        connectionUser: String?,
        runtime: AppleContainerRuntime
    ) throws {
        guard identity.isComplete else { return }

        let result = try runtime.exec(
            nameOrId: containerId,
            command: ["sh", "-c", Self.script()],
            user: connectionUser,
            env: [:],
            stdinData: Data("\(identity.trimmedName)\n\(identity.trimmedEmail)\n".utf8)
        )
        guard result.succeeded else {
            throw CLIError(
                code: CLIErrorCode.lifecycleFailed,
                message: "Failed to set global git user.name/email in the container (exit \(result.exitCode))",
                hint: "Ensure the connection user can write its home directory and git global config"
            )
        }
    }

    /// Resolve the exec user's home rather than trusting inherited HOME, then write only the
    /// two global author keys. Values arrive on stdin and are passed to git as quoted argv.
    public static func script() -> String {
        [
            "set -e",
            "IFS= read -r author_name || exit 1",
            "IFS= read -r author_email || exit 1",
            "uid=\"$(id -u 2>/dev/null)\"",
            "resolved_home=\"\"",
            "if command -v getent >/dev/null 2>&1; then",
            "  if passwd_entry=$(getent passwd \"$uid\" 2>/dev/null); then",
            "    old_ifs=$IFS",
            "    IFS=:",
            "    read -r _ _ _ _ _ resolved_home _ <<EOF",
            "$passwd_entry",
            "EOF",
            "    IFS=$old_ifs",
            "  fi",
            "fi",
            "if [ -z \"$resolved_home\" ] && [ -r /etc/passwd ]; then",
            "  while IFS=: read -r passwd_name passwd_password passwd_uid passwd_gid passwd_gecos passwd_home passwd_shell; do",
            "    if [ \"$passwd_uid\" = \"$uid\" ]; then",
            "      resolved_home=\"$passwd_home\"",
            "      break",
            "    fi",
            "  done < /etc/passwd 2>/dev/null",
            "fi",
            "[ -n \"$resolved_home\" ] || exit 1",
            "if [ ! -d \"$resolved_home\" ]; then",
            "  mkdir -p \"$resolved_home\" 2>/dev/null || exit 1",
            "fi",
            "[ -d \"$resolved_home\" ] || exit 1",
            "HOME=\"$resolved_home\"",
            "export HOME",
            "unset GIT_CONFIG_GLOBAL XDG_CONFIG_HOME",
            "git config --global --replace-all user.name \"$author_name\" >/dev/null 2>&1",
            "git config --global --replace-all user.email \"$author_email\" >/dev/null 2>&1"
        ].joined(separator: "\n")
    }
}
