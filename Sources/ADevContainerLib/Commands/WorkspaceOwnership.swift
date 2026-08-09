import Foundation

/// Shared container-side workspace ownership fixup for named-volume workspaces.
///
/// CloneCommand applies it after first populate (throwing — chown failure aborts the
/// clone); RebuildCommand applies it only when the effective remote user differs from
/// the stamped `devcontainer.remote_user`, tolerating failure (warning + continue):
/// the volume data already belongs to the previous user otherwise.
public enum WorkspaceOwnership {
    /// Chown the workspace folder to the remote user. No-op when user is root/unset.
    /// Throws `populateFailed` when the chown script fails (clone semantics).
    public static func ensureWorkspaceWritableByRemoteUser(
        containerId: String,
        workspaceFolder: String,
        remoteUser: String?,
        runtime: AppleContainerRuntime
    ) throws {
        let user = remoteUser?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        guard !user.isEmpty, user != "root" else { return }

        // chown user:user when group exists; fall back to user-only.
        let script = """
        set -e
        WS=\(shellSingleQuoted(workspaceFolder))
        U=\(shellSingleQuoted(user))
        mkdir -p "$WS"
        if getent group "$U" >/dev/null 2>&1; then
          chown -R "$U:$U" "$WS"
        else
          chown -R "$U" "$WS"
        fi
        """
        let result = try runtime.exec(
            nameOrId: containerId,
            command: ["sh", "-c", script],
            user: "root",
            workdir: "/",
            env: [:]
        )
        guard result.succeeded else {
            let detail = [
                result.stderrString.trimmingCharacters(in: .whitespacesAndNewlines),
                result.stdoutString.trimmingCharacters(in: .whitespacesAndNewlines)
            ].filter { !$0.isEmpty }.joined(separator: " | ")
            throw CLIError(
                code: CLIErrorCode.populateFailed,
                message: "Failed to chown workspace volume for remoteUser \(user)"
                    + (detail.isEmpty ? "" : ": \(detail)"),
                hint: "Named volumes are root-owned; chown as root before clone as remoteUser"
            )
        }
    }

    /// Shell-safe single quoting for paths/users in the chown script.
    public static func shellSingleQuoted(_ value: String) -> String {
        "'" + value.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }
}