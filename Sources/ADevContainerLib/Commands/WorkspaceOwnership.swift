import Foundation

/// Shared container-side ownership fixup for Apple named volumes (root:root on mount).
///
/// CloneCommand applies workspace chown after first start (throwing — chown failure aborts
/// the clone); RebuildCommand applies workspace chown only when the effective remote user
/// differs from the stamped `devcontainer.remote_user`, tolerating failure (warning +
/// continue): the volume data already belongs to the previous user otherwise.
///
/// Config `type=volume` mount targets are chowned on create paths (`up`, `clone`, `rebuild`)
/// so non-root connection users can write home-dir volume mounts before lifecycle hooks.
/// Intermediate parents created by `mkdir -p` are non-recursively chowned (sibling mounts safe).
/// Readonly volume mounts and bind mount targets are never chowned.
public enum WorkspaceOwnership {
    /// Chown the workspace folder to the remote user. No-op when user is root/unset.
    /// Throws `populateFailed` when the chown script fails (clone semantics).
    public static func ensureWorkspaceWritableByRemoteUser(
        containerId: String,
        workspaceFolder: String,
        remoteUser: String?,
        runtime: AppleContainerRuntime
    ) throws {
        try ensurePathsWritableByRemoteUser(
            containerId: containerId,
            paths: [workspaceFolder],
            remoteUser: remoteUser,
            runtime: runtime,
            failureNoun: "workspace volume"
        )
    }

    /// Chown each config named-volume mount target to the remote user.
    /// Skips bind mounts, readonly volumes, empty targets, and root/unset users.
    /// Throws `populateFailed` when any chown script fails (create-path semantics).
    public static func ensureNamedVolumeMountsWritableByRemoteUser(
        containerId: String,
        mounts: [MountSpec],
        remoteUser: String?,
        runtime: AppleContainerRuntime
    ) throws {
        let paths = mounts.compactMap { mount -> String? in
            guard mount.type == .volume, !mount.readonly else { return nil }
            let target = mount.target.trimmingCharacters(in: .whitespacesAndNewlines)
            return target.isEmpty ? nil : target
        }
        try ensurePathsWritableByRemoteUser(
            containerId: containerId,
            paths: paths,
            remoteUser: remoteUser,
            runtime: runtime,
            failureNoun: "named volume mount"
        )
    }

    /// Chown each path to the remote user inside the container (as root).
    /// No-op when user is root/unset or `paths` is empty after trim.
    public static func ensurePathsWritableByRemoteUser(
        containerId: String,
        paths: [String],
        remoteUser: String?,
        runtime: AppleContainerRuntime,
        failureNoun: String
    ) throws {
        let user = remoteUser?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        guard !user.isEmpty, user != "root" else { return }

        let cleaned = paths
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
        guard !cleaned.isEmpty else { return }

        // One exec: mkdir + chown -R target; non-recursive chown of intermediate parents
        // (mkdir -p creates them as root; do not chown -R parents — sibling mounts).
        var script = "set -e\nU=\(shellSingleQuoted(user))\n"
        for path in cleaned {
            script += """
            T=\(shellSingleQuoted(path))
            mkdir -p "$T"
            if getent group "$U" >/dev/null 2>&1; then
              OWN="$U:$U"
            else
              OWN="$U"
            fi
            chown -R "$OWN" "$T"
            P=$(dirname "$T")
            while [ -n "$P" ] && [ "$P" != "." ]; do
              case "$P" in
                /|/home|/Users|/var|/usr|/opt|/tmp|/root|/etc|/mnt|/media|/dev|/proc|/sys|/run|/boot|/lib|/lib64|/bin|/sbin) break ;;
              esac
              chown "$OWN" "$P"
              N=$(dirname "$P")
              [ "$N" = "$P" ] && break
              P=$N
            done

            """
        }
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
                message: "Failed to chown \(failureNoun) for remoteUser \(user)"
                    + (detail.isEmpty ? "" : ": \(detail)"),
                hint: "Named volumes are root-owned; chown as root before running as remoteUser"
            )
        }
    }

    /// Shell-safe single quoting for paths/users in the chown script.
    public static func shellSingleQuoted(_ value: String) -> String {
        "'" + value.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }
}
