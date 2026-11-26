import Foundation

/// Chown scope for `ensurePathsWritableByRemoteUser`.
public enum WorkspaceOwnershipScope {
    /// Recursive chown of each path plus non-recursive ancestors (current behavior).
    case targetAndParents
    /// `mkdir -p` each path but chown only ancestors (bind-mode workspace parents;
    /// the workspace folder itself is never chowned).
    case parentsOnly
}

/// Shared container-side ownership fixup for Apple named volumes (root:root on mount).
///
/// CloneCommand applies workspace chown before populate; RebuildCommand applies it only
/// when the effective remote user differs from the stamped `devcontainer.remote_user`.
///
/// Config `type=volume` mounts are chowned on create paths (`up`, `clone`, `rebuild`)
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
        runtime: AppleContainerRuntime,
        createRequest: CreateRequest? = nil
    ) throws {
        if let createRequest,
           createRequest.workspaceMountMode == .volume,
           requiresOwnershipHelper(runArgs: createRequest.runArgs)
        {
            try ensureNamedVolumesViaHelper(
                mounts: [MountSpec(
                    type: .volume,
                    source: createRequest.workspaceBindHost,
                    target: workspaceFolder
                )],
                remoteUser: remoteUser,
                createRequest: createRequest,
                runtime: runtime,
                failureNoun: "workspace volume"
            )
            return
        }
        try ensurePathsWritableByRemoteUser(
            containerId: containerId,
            paths: [workspaceFolder],
            remoteUser: remoteUser,
            runtime: runtime,
            failureNoun: "workspace volume",
            volumeNames: createRequest
                .flatMap { $0.workspaceMountMode == .volume ? [workspaceFolder: $0.workspaceBindHost] : nil }
                ?? [:]
        )
    }

    /// Make only the container-rootfs parents of the workspace folder writable by the
    /// remote user (bind mode: the workspace folder is the host bind target and must
    /// never be chowned). No-op when user is root/unset. Throws `populateFailed` when
    /// the chown script fails (up create-path semantics).
    public static func ensureWorkspaceParentsWritableByRemoteUser(
        containerId: String,
        workspaceFolder: String,
        remoteUser: String?,
        runtime: AppleContainerRuntime,
        createRequest: CreateRequest? = nil
    ) throws {
        if let createRequest, requiresOwnershipHelper(runArgs: createRequest.runArgs) {
            try ensureWorkspaceParentsAccessibleWithoutChown(
                containerId: containerId,
                workspaceFolder: workspaceFolder,
                remoteUser: remoteUser,
                runtime: runtime
            )
            return
        }
        try ensurePathsWritableByRemoteUser(
            containerId: containerId,
            paths: [workspaceFolder],
            remoteUser: remoteUser,
            runtime: runtime,
            failureNoun: "workspace parents",
            scope: .parentsOnly
        )
    }

    /// Chown each config named-volume mount target to the remote user.
    /// Skips bind mounts, readonly volumes, empty targets, and root/unset users.
    /// Throws `populateFailed` when any chown script fails (create-path semantics).
    public static func ensureNamedVolumeMountsWritableByRemoteUser(
        containerId: String,
        mounts: [MountSpec],
        remoteUser: String?,
        runtime: AppleContainerRuntime,
        createRequest: CreateRequest? = nil
    ) throws {
        let writableVolumes = mounts.compactMap { mount -> MountSpec? in
            guard mount.type == .volume, !mount.readonly else { return nil }
            let target = mount.target.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !target.isEmpty else { return nil }
            return MountSpec(type: .volume, source: mount.source, target: target)
        }
        if let createRequest, requiresOwnershipHelper(runArgs: createRequest.runArgs) {
            try ensureNamedVolumesViaHelper(
                mounts: writableVolumes,
                remoteUser: remoteUser,
                createRequest: createRequest,
                runtime: runtime,
                failureNoun: "named volume mount"
            )
            return
        }
        try ensurePathsWritableByRemoteUser(
            containerId: containerId,
            paths: writableVolumes.map(\.target),
            remoteUser: remoteUser,
            runtime: runtime,
            failureNoun: "named volume mount",
            volumeNames: Dictionary(
                writableVolumes.map { ($0.target, $0.source) },
                uniquingKeysWith: { first, _ in first }
            )
        )
    }

    static func requiresOwnershipHelper(runArgs: [AllowlistedRunArg]) -> Bool {
        if runArgs.contains(.readOnly) {
            return true
        }
        if runArgs.contains(where: {
            if case .capAdd(let name) = $0 { return name.uppercased() == "CHOWN" }
            return false
        }) {
            return false
        }
        return runArgs.contains {
            if case .capDrop(let name) = $0 {
                return name.uppercased() == "ALL" || name.uppercased() == "CHOWN"
            }
            return false
        }
    }

    private static func ensureNamedVolumesViaHelper(
        mounts: [MountSpec],
        remoteUser: String?,
        createRequest: CreateRequest,
        runtime: AppleContainerRuntime,
        failureNoun: String
    ) throws {
        let user = remoteUser?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        guard !user.isEmpty, user != "root", !mounts.isEmpty else { return }

        let helperMounts = mounts.enumerated().map { index, mount in
            MountSpec(
                type: .volume,
                source: mount.source,
                target: "/mnt/adevcontainer-volume-\(index)"
            )
        }
        let helperName = "adev-ownership-\(UUID().uuidString.prefix(12).lowercased())"
        var helperRunArgs: [AllowlistedRunArg] = [
            .capDrop("ALL"), .capAdd("CHOWN"), .capAdd("DAC_READ_SEARCH")
        ]
        if createRequest.runArgs.contains(.rosetta) {
            helperRunArgs.append(.rosetta)
        }
        let helperRequest = CreateRequest(
            name: helperName,
            image: createRequest.image,
            labels: [:],
            workspaceBindHost: helperMounts[0].source,
            workspaceBindTarget: helperMounts[0].target,
            workspaceMountMode: .volume,
            user: "root",
            workdir: "/",
            mounts: Array(helperMounts.dropFirst()),
            runArgs: helperRunArgs,
            platform: createRequest.platform,
            configHash: "",
            featureEntrypoints: []
        )

        var script = """
        set -e
        U=\(shellSingleQuoted(user))
        TARGET_UID=$(id -u "$U")
        TARGET_GID=$(id -g "$U")
        case "$TARGET_UID:$TARGET_GID" in *[!0-9:]*|:|:*|*:) echo "invalid numeric uid/gid for $U" >&2; exit 1 ;; esac

        """
        for mount in helperMounts {
            script += """
            T=\(shellSingleQuoted(mount.target))
            FOUND=0
            while IFS=' ' read -r _ _ _ _ MOUNT_POINT _; do
              [ "$MOUNT_POINT" = "$T" ] && FOUND=1
            done < /proc/self/mountinfo
            [ "$FOUND" = 1 ] || { echo "expected named volume is not mounted at $T" >&2; exit 1; }
            chown -R "$TARGET_UID:$TARGET_GID" "$T"

            """
        }

        var helperID: String?
        var operationError: Error?
        do {
            let createdID = try runtime.create(request: helperRequest, ensureVolumes: false)
            helperID = createdID
            try runtime.start(nameOrId: createdID)
            let result = try runtime.exec(
                nameOrId: createdID,
                command: ["sh", "-c", script],
                user: "root",
                workdir: "/"
            )
            if !result.succeeded {
                throw ownershipError(
                    result: result,
                    failureNoun: failureNoun,
                    user: user,
                    volumes: zip(mounts, helperMounts).map {
                        OwnedVolume(name: $0.source, target: $0.target, scriptPath: $1.target)
                    }
                )
            }
        } catch {
            operationError = error
        }

        if let helperID {
            do {
                try runtime.delete(nameOrId: helperID, force: true)
            } catch {
                if operationError == nil { throw error }
            }
        }
        if let operationError { throw operationError }
    }

    private static func ensureWorkspaceParentsAccessibleWithoutChown(
        containerId: String,
        workspaceFolder: String,
        remoteUser: String?,
        runtime: AppleContainerRuntime
    ) throws {
        let user = remoteUser?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        guard !user.isEmpty, user != "root" else { return }
        let path = workspaceFolder.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !path.isEmpty else { return }
        let result = try runtime.exec(
            nameOrId: containerId,
            command: ["sh", "-c", "test -x \(shellSingleQuoted(path))"],
            user: user,
            workdir: "/"
        )
        guard result.succeeded else {
            throw CLIError(
                code: CLIErrorCode.populateFailed,
                message: "Workspace rootfs parents are not accessible by remoteUser \(user) and cannot be repaired in this container",
                hint: "The rootfs parents cannot be repaired without CAP_CHOWN and a writable root filesystem on the main container"
            )
        }
    }

    /// Chown each path to the remote user inside the container (as root).
    /// No-op when user is root/unset or `paths` is empty after trim.
    public static func ensurePathsWritableByRemoteUser(
        containerId: String,
        paths: [String],
        remoteUser: String?,
        runtime: AppleContainerRuntime,
        failureNoun: String,
        scope: WorkspaceOwnershipScope = .targetAndParents,
        volumeNames: [String: String] = [:]
    ) throws {
        let user = remoteUser?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        guard !user.isEmpty, user != "root" else { return }

        let cleaned = paths
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
        guard !cleaned.isEmpty else { return }

        // One exec: mkdir -p target; chown -R target in the default scope only;
        // non-recursive chown of intermediate parents (mkdir -p creates them as
        // root; do not chown -R parents — sibling mounts).
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

            """
            if scope == .targetAndParents {
                script += "chown -R \"$OWN\" \"$T\"\n"
            }
            script += """
            P=$(dirname "$T")
            while [ -n "$P" ] && [ "$P" != "." ]; do
              case "$P" in
                /|/home|/Users|/var|/usr|/opt|/tmp|/root|/etc|/mnt|/media|/dev|/proc|/sys|/run|/boot|/lib|/lib64|/bin|/sbin) break ;;
              esac
              chown "$OWN" "$P" || [ -x "$P" ]
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
            throw ownershipError(
                result: result,
                failureNoun: failureNoun,
                user: user,
                volumes: cleaned.map {
                    OwnedVolume(name: volumeNames[$0], target: $0, scriptPath: $0)
                }
            )
        }
    }

    /// A chown target: named volume (when known), its mount target in the main container,
    /// and the path the chown script used (differs on the scoped ownership helper).
    struct OwnedVolume {
        let name: String?
        let target: String
        let scriptPath: String
    }

    /// ext4 `EUCLEAN` text: the filesystem is corrupt, not a chown or config problem.
    static let filesystemCorruptionMarker = "Structure needs cleaning"

    /// True when an ownership failure reports on-disk volume corruption. Editing the config
    /// and retrying cannot fix it, so callers must not enter config-edit recovery.
    public static func isVolumeCorruption(_ error: Error) -> Bool {
        (error as? CLIError)?.code == CLIErrorCode.volumeCorrupt
    }

    static func ownershipError(
        result: ProcessResult,
        failureNoun: String,
        user: String,
        volumes: [OwnedVolume] = []
    ) -> CLIError {
        let detail = [
            result.stderrString.trimmingCharacters(in: .whitespacesAndNewlines),
            result.stdoutString.trimmingCharacters(in: .whitespacesAndNewlines)
        ].filter { !$0.isEmpty }.joined(separator: " | ")
        if let corruptLine = detail
            .split(whereSeparator: { $0.isNewline || $0 == "|" })
            .map({ $0.trimmingCharacters(in: .whitespaces) })
            .first(where: { $0.localizedCaseInsensitiveContains(filesystemCorruptionMarker) })
        {
            return volumeCorruptError(line: corruptLine, volumes: volumes)
        }
        return CLIError(
            code: CLIErrorCode.populateFailed,
            message: "Failed to chown \(failureNoun) for remoteUser \(user)"
                + (detail.isEmpty ? "" : ": \(detail)"),
            hint: "Named volumes are root-owned; chown as root before running as remoteUser"
        )
    }

    private static func volumeCorruptError(line: String, volumes: [OwnedVolume]) -> CLIError {
        // Prefer the volume whose path appears in the failing chown line.
        let matched = volumes.filter { volume in
            let path = volume.scriptPath
            return line.contains(path + "/") || line.contains(path + ":") || line.contains("'\(path)'")
        }
        let suspects = matched.isEmpty ? volumes : matched
        let described = suspects.map { volume in
            volume.name.map { "'\($0)' mounted at \(volume.target)" } ?? "mounted at \(volume.target)"
        }
        let subject = described.isEmpty
            ? "A named volume"
            : "Named volume " + described.joined(separator: ", ")
        let image = suspects.count == 1 && suspects[0].name != nil
            ? "the volume.img of '\(suspects[0].name!)' (see `container volume inspect \(suspects[0].name!)`)"
            : "the affected volume.img (see `container volume inspect <volume>`)"
        let excerpt = line.count > 300 ? String(line.prefix(300)) + "…" : line
        return CLIError(
            code: CLIErrorCode.volumeCorrupt,
            message: "\(subject) has a corrupted ext4 filesystem (EUCLEAN): \(excerpt)",
            hint: "Editing devcontainer.json cannot fix this. " + VolumeHealth.repairHint(image: image)
        )
    }

    /// Shell-safe single quoting for paths/users in the chown script.
    public static func shellSingleQuoted(_ value: String) -> String {
        "'" + value.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }
}
