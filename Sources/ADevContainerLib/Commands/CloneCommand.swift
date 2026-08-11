import Foundation

public struct CloneOptions: Sendable {
    public var gitURL: String
    public var skipPull: Bool
    /// Best-effort open of VS Code on the remote workspace after lifecycle success.
    public var openVSCode: Bool

    public init(gitURL: String, skipPull: Bool = false, openVSCode: Bool = false) {
        self.gitURL = gitURL
        self.skipPull = skipPull
        self.openVSCode = openVSCode
    }
}

public enum CloneCommand {
    /// Optional Features fetch override for tests.
    nonisolated(unsafe) public static var featuresFetcherOverride: (any FeatureFetching)?
    nonisolated(unsafe) public static var featuresCacheRootOverride: String?
    nonisolated(unsafe) public static var ensureNativeArmBuildOverride: (() throws -> Void)?

    public static func run(
        options: CloneOptions,
        runtime: AppleContainerRuntime,
        git: any GitClient = HostGitClient(),
        credentials: any GitCredentialProviding = HostGitCredential(),
        localEnv: [String: String] = ProcessInfo.processInfo.environment,
        hostResources: any HostResourceProviding = SystemHostResourceInfo(),
        fileManager: FileManager = .default,
        identityPrompt: IdentityPrompt = .default
    ) throws -> CloneResult {
        // 1. Require host git before any work (config-only fetch + HTTPS credential fill).
        _ = try git.requireGit()

        let url = options.gitURL.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !url.isEmpty else {
            throw CLIError(
                code: CLIErrorCode.usage,
                message: "clone requires a git URL",
                hint: "Usage: adevcontainer clone <git-url>"
            )
        }

        let urlKind = GitURLClassifier.kind(of: url)
        let sshAuthSock = (localEnv["SSH_AUTH_SOCK"] ?? "")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let enableSSHForward: Bool

        switch urlKind {
        case .ssh:
            if sshAuthSock.isEmpty {
                throw CLIError(
                    code: CLIErrorCode.gitFailed,
                    message: "SSH git URL requires a running ssh-agent (SSH_AUTH_SOCK is unset or empty)",
                    hint: "Start ssh-agent, run ssh-add, or use an HTTPS git URL instead"
                )
            }
            enableSSHForward = true
        case .https, .other:
            // Optional: forward agent when present so SSH after create remotes still work.
            enableSSHForward = !sshAuthSock.isEmpty
        }

        // Temp dir: config-only sparse/shallow fetch. Always cleaned.
        // Full tree clone runs inside the container (no host full-clone staging).
        let configTemp = fileManager.temporaryDirectory
            .appendingPathComponent("adev-clone-cfg-\(UUID().uuidString)", isDirectory: true)

        defer {
            removeTemp(configTemp, fileManager: fileManager)
        }

        // 2. Config-only fetch into temp (host credentials).
        StatusPrinter.status("Fetching devcontainer config")
        try git.fetchConfig(url: url, into: configTemp.path)

        // Resolve author from host git config in the sparse checkout (includeIf by remote).
        // Env overrides win per field when set. Never invent fake identity.
        let resolvedAuthor = Self.effectiveAuthorIdentity(
            resolved: git.resolveAuthorIdentity(in: configTemp.path),
            localEnv: localEnv
        )
        let bothAuthorEnvExplicit = Self.bothAuthorEnvOverridesSet(localEnv: localEnv)

        // 3. Discover config (nested then root)
        let configPath: String
        do {
            configPath = try ConfigDiscovery.discover(
                workspacePath: configTemp.path,
                fileManager: fileManager
            )
        } catch let err as CLIError where err.code == CLIErrorCode.configNotFound {
            throw CLIError(
                code: CLIErrorCode.configNotFound,
                message: "No devcontainer.json found in repository",
                hint: "Looked for \(ConfigDiscovery.nestedRelativePath) and \(ConfigDiscovery.rootRelativePath)"
            )
        }

        let configRelPath: String = {
            let root = (configTemp.path as NSString).standardizingPath
            let full = (configPath as NSString).standardizingPath
            if full.hasPrefix(root + "/") {
                return String(full.dropFirst(root.count + 1))
            }
            if full.hasSuffix(ConfigDiscovery.nestedRelativePath) {
                return ConfigDiscovery.nestedRelativePath
            }
            return ConfigDiscovery.rootRelativePath
        }()

        // 4. Resolve via existing pipeline (temp as workspace for discovery/paths only).
        StatusPrinter.status("Resolving configuration")
        let repoBasename = ContainerIdentity.repoBasename(fromGitURL: url)
        let resolved = try ConfigResolver.resolve(
            workspacePath: configTemp.path,
            configPath: configPath,
            localEnv: localEnv,
            fileManager: fileManager,
            workspaceFolderBasename: repoBasename
        )

        try enforceHostRequirements(config: resolved.config, host: hostResources)

        // 5. Volume-mode identity (git URL + config rel path — not temp path)
        let identity = ContainerIdentity.volumeModeIdentity(
            gitURL: url,
            configRelativePath: configRelPath,
            configName: resolved.config.name
        )

        // Spec does not require reuse on clone; fail if name already taken.
        if try runtime.findByName(identity.containerName) != nil {
            throw CLIError(
                code: CLIErrorCode.runtimeFailed,
                message: "Container '\(identity.containerName)' already exists",
                hint: "Stop/delete or prune the existing managed container, or use a different URL/config"
            )
        }

        if !resolved.mountPromotions.isEmpty {
            StatusPrinter.warning(MountNormalizer.warningMessage(promotions: resolved.mountPromotions))
        }

        // Confirm/collect author identity before Features build / image pull / create.
        let authorIdentity = try identityPrompt.confirmOrCollect(
            current: resolvedAuthor,
            bothEnvExplicit: bothAuthorEnvExplicit
        )

        var effectiveConfig = resolved.config
        let platform = ContainerPlatform.defaultLinuxPlatform
        var knownOCIUser: String?? = nil
        var knownMetadataUsers: DevContainerMetadataLabel.ImageMetadataUsers? = nil

        // Clone-only: ensure in-container git via Features when config lacks git/common-utils.
        let gitEnsure = FeatureGitEnsure.ensurePresent(features: effectiveConfig.features)
        if gitEnsure.didInject {
            StatusPrinter.status("Ensuring git feature for volume-mode dev container")
        }
        effectiveConfig.features = gitEnsure.features

        // Features path (same as up create; list may include clone-injected git)
        if !effectiveConfig.features.isEmpty {
            if let override = ensureNativeArmBuildOverride {
                try override()
            } else {
                try AppleContainerConfig.ensureNativeArmBuild(runtime: runtime)
            }
            if !options.skipPull {
                StatusPrinter.status("Pulling image", item: resolved.config.image)
                try? runtime.pullImage(resolved.config.image, platform: platform)
            }
            let fetcher: any FeatureFetching = featuresFetcherOverride
                ?? DefaultFeatureFetcher(workspacePath: configTemp.path)
            let cacheRoot = featuresCacheRootOverride ?? FeatureCache.defaultRoot()
            let deps = FeaturesRunner.Dependencies(
                fetcher: fetcher,
                runtime: runtime,
                cacheRoot: cacheRoot,
                platform: platform
            )
            let featuresResult = try FeaturesRunner.run(
                features: effectiveConfig.features,
                baseImage: resolved.config.image,
                deps: deps,
                remoteUser: resolved.config.remoteUser,
                containerUser: resolved.config.containerUser,
                nameBase: identity.base
            )
            effectiveConfig = try FeatureContributionMerge.apply(
                contributions: featuresResult.contributions,
                to: effectiveConfig
            )
            effectiveConfig.image = featuresResult.derivedImage
            if featuresResult.didInspectBaseUser {
                knownOCIUser = featuresResult.baseImageUser
            }
            knownMetadataUsers = featuresResult.metadataUsers
        } else if !options.skipPull {
            StatusPrinter.status("Pulling image", item: effectiveConfig.image)
            try? runtime.pullImage(effectiveConfig.image, platform: platform)
        }

        // Expand `${devcontainerId}` with volume-mode create name (not bind-mode resolve name).
        effectiveConfig = VariableSubstitutor.expandDevcontainerId(
            in: effectiveConfig,
            id: identity.containerName
        )

        // Hash from config material before stamping OCI-resolved connection user.
        let configHash = ContainerIdentity.configHash(from: effectiveConfig.hashMaterial())
        let connectionUser = try RemoteUserResolution.resolve(
            config: effectiveConfig,
            imageRef: effectiveConfig.image,
            runtime: runtime,
            knownOCIUser: knownOCIUser,
            knownMetadataUsers: knownMetadataUsers
        )
        effectiveConfig = RemoteUserResolution.applyingConnectionUser(connectionUser, to: effectiveConfig)

        let configVolumeNames = effectiveConfig.mounts
            .filter { $0.type == .volume }
            .map(\.source)
        let labels = ContainerIdentity.volumeModeLabels(
            identity: identity,
            configHash: configHash,
            configVolumeNames: configVolumeNames,
            workspaceFolder: effectiveConfig.workspaceFolder,
            remoteUser: connectionUser
        )

        let request = CreateRequest.fromVolumeMode(
            resolved: effectiveConfig,
            identityName: identity.containerName,
            labels: labels,
            configHash: configHash,
            workspaceVolumeName: identity.workspaceVolumeName,
            platform: platform,
            enableSSHForward: enableSSHForward
        )

        // Fresh workspace tree: volume may remain after container-only delete.
        if try runtime.volumeExists(identity.workspaceVolumeName) {
            StatusPrinter.status("Replacing workspace volume", item: identity.workspaceVolumeName)
            try runtime.deleteVolume(name: identity.workspaceVolumeName)
        }

        // 6–7. Ensure volume + create with volume workspace mount
        StatusPrinter.status("Creating container", item: identity.containerName)
        let id = try runtime.create(request: request)

        // 8. Start
        StatusPrinter.status("Starting container")
        do {
            try runtime.start(nameOrId: id)
        } catch {
            try? runtime.delete(nameOrId: id, force: true)
            try? runtime.deleteVolume(name: identity.workspaceVolumeName)
            throw error
        }

        // 9. Named volumes are root-owned (ext4); remoteUser cannot write until chown.
        do {
            try ensureWorkspaceWritableByRemoteUser(
                containerId: id,
                workspaceFolder: effectiveConfig.workspaceFolder,
                remoteUser: connectionUser,
                runtime: runtime
            )
            try WorkspaceOwnership.ensureNamedVolumeMountsWritableByRemoteUser(
                containerId: id,
                mounts: effectiveConfig.mounts,
                remoteUser: connectionUser,
                runtime: runtime
            )
        } catch {
            try? runtime.delete(nameOrId: id, force: true)
            try? runtime.deleteVolume(name: identity.workspaceVolumeName)
            throw error
        }

        // 10. Full clone INSIDE container (guest git + host-resolved auth for HTTPS)
        StatusPrinter.status("Populating workspace volume")
        do {
            try populateInContainer(
                url: url,
                urlKind: urlKind,
                containerId: id,
                workspaceFolder: effectiveConfig.workspaceFolder,
                remoteUser: connectionUser,
                containerEnv: effectiveConfig.containerEnv,
                credentials: credentials,
                runtime: runtime
            )
        } catch {
            try? runtime.delete(nameOrId: id, force: true)
            try? runtime.deleteVolume(name: identity.workspaceVolumeName)
            if let cli = error as? CLIError {
                throw cli
            }
            throw CLIError(
                code: CLIErrorCode.populateFailed,
                message: "Failed to populate workspace volume: \(error.localizedDescription)",
                hint: "Check git access for the repository URL and that in-container git is available"
            )
        }

        // 10b. Local git author identity inside the volume clone (both or neither).
        applyAuthorIdentityInContainer(
            identity: authorIdentity,
            containerId: id,
            workspaceFolder: effectiveConfig.workspaceFolder,
            remoteUser: connectionUser,
            runtime: runtime
        )

        // 11. Create-path lifecycle hooks (same matrix as up)
        do {
            try LifecycleRunner.runCreatePath(
                containerId: id,
                config: effectiveConfig,
                runtime: runtime
            )
        } catch {
            // LifecycleRunner already deletes container on create-path failure
            try? runtime.deleteVolume(name: identity.workspaceVolumeName)
            throw error
        }

        // Settings apply after create-path hooks; not gated on --vscode. Soft-fail never deletes.
        _ = VSCodeCustomizationsApply.applySettingsIfNeeded(
            containerId: id,
            config: effectiveConfig,
            runtime: runtime
        )

        let result = CloneResult(
            outcome: "success",
            containerId: id,
            remoteUser: connectionUser,
            remoteWorkspaceFolder: effectiveConfig.workspaceFolder,
            containerName: identity.containerName,
            gitUrl: identity.normalizedGitURL,
            workspaceVolume: identity.workspaceVolumeName
        )
        // Open → extensions (on success) → postAttach (never before open when --vscode).
        let openOutcome = VSCodeOpen.openIfRequested(
            options.openVSCode,
            target: VSCodeOpenTarget(
                containerId: result.containerId,
                image: effectiveConfig.image,
                remoteWorkspaceFolder: result.remoteWorkspaceFolder,
                containerName: result.containerName ?? identity.containerName,
                remoteUser: result.remoteUser
            )
        )
        if openOutcome.isOpenSuccess {
            _ = VSCodeCustomizationsApply.applyExtensionsIfNeeded(
                containerId: id,
                config: effectiveConfig,
                runtime: runtime
            )
        }
        try LifecycleRunner.applyPostAttachGate(
            openOutcome: openOutcome,
            containerId: id,
            config: effectiveConfig,
            runtime: runtime
        )
        // Connection hints: entry point after success JSON (Ready → JSON → blank → connect).
        StatusPrinter.status("Ready")
        return result
    }

    // MARK: - Git author identity

    /// Apply optional env overrides (`ADEVCONTAINER_GIT_AUTHOR_NAME` / `_EMAIL`) per field.
    static func effectiveAuthorIdentity(
        resolved: GitAuthorIdentity,
        localEnv: [String: String]
    ) -> GitAuthorIdentity {
        var result = resolved
        if let n = localEnv["ADEVCONTAINER_GIT_AUTHOR_NAME"]?
            .trimmingCharacters(in: .whitespacesAndNewlines), !n.isEmpty
        {
            result.name = n
        }
        if let e = localEnv["ADEVCONTAINER_GIT_AUTHOR_EMAIL"]?
            .trimmingCharacters(in: .whitespacesAndNewlines), !e.isEmpty
        {
            result.email = e
        }
        return result
    }

    /// True when both author env overrides are set non-empty (skip TTY prompt).
    static func bothAuthorEnvOverridesSet(localEnv: [String: String]) -> Bool {
        let n = localEnv["ADEVCONTAINER_GIT_AUTHOR_NAME"]?
            .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        let e = localEnv["ADEVCONTAINER_GIT_AUTHOR_EMAIL"]?
            .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return !n.isEmpty && !e.isEmpty
    }

    /// Set `--local` user.name/email in the in-container clone when both present; else warn once.
    private static func applyAuthorIdentityInContainer(
        identity: GitAuthorIdentity,
        containerId: String,
        workspaceFolder: String,
        remoteUser: String?,
        runtime: AppleContainerRuntime
    ) {
        guard identity.isComplete else {
            StatusPrinter.warning(
                "git user.name/email not resolved for this repo; configure before first commit (host includeIf/global or git config in container)"
            )
            return
        }
        let name = identity.trimmedName
        let email = identity.trimmedEmail
        let nameResult = try? runtime.exec(
            nameOrId: containerId,
            command: ["git", "-C", workspaceFolder, "config", "--local", "user.name", name],
            user: remoteUser,
            workdir: workspaceFolder,
            env: [:]
        )
        let emailResult = try? runtime.exec(
            nameOrId: containerId,
            command: ["git", "-C", workspaceFolder, "config", "--local", "user.email", email],
            user: remoteUser,
            workdir: workspaceFolder,
            env: [:]
        )
        if nameResult?.succeeded != true || emailResult?.succeeded != true {
            StatusPrinter.warning(
                "failed to set local git user.name/email in container; configure before first commit"
            )
        }
    }

    // MARK: - Workspace volume ownership

    /// Apple named volumes mount as root:root. Chown to remoteUser so in-container
    /// clone and in-container git (as remoteUser) can write. No-op when user is root/unset.
    /// Shared implementation with rebuild (WorkspaceOwnership).
    private static func ensureWorkspaceWritableByRemoteUser(
        containerId: String,
        workspaceFolder: String,
        remoteUser: String?,
        runtime: AppleContainerRuntime
    ) throws {
        try WorkspaceOwnership.ensureWorkspaceWritableByRemoteUser(
            containerId: containerId,
            workspaceFolder: workspaceFolder,
            remoteUser: remoteUser,
            runtime: runtime
        )
    }

    // MARK: - In-container populate

    private static func populateInContainer(
        url: String,
        urlKind: GitURLKind,
        containerId: String,
        workspaceFolder: String,
        remoteUser: String?,
        containerEnv: [String: String],
        credentials: any GitCredentialProviding,
        runtime: AppleContainerRuntime
    ) throws {
        // Normalize URL for clone argv (strip embedded userinfo from scheme:// so
        // secrets are not passed on the git clone command line; HTTPS uses helper).
        let cloneURL = ContainerIdentity.normalizeGitURL(url)
        // Prefer original for non-https when normalization only trims .git (SSH keeps shape).
        let effectiveCloneURL: String = {
            switch urlKind {
            case .https:
                // Always use credential-free URL; auth via ASKPASS/env.
                return cloneURL
            case .ssh, .other:
                return url
            }
        }()

        // HTTPS: prefer host credentials when available (private repos). Public repos
        // succeed anonymously when fill returns nil.
        var httpsCreds: GitHTTPSCredentials?
        if urlKind == .https {
            httpsCreds = try credentials.fillHTTPS(url: url)
        }

        var execEnv = containerEnv
        execEnv["GIT_TERMINAL_PROMPT"] = "0"
        execEnv["ADEV_CLONE_URL"] = effectiveCloneURL
        execEnv["ADEV_CLONE_WORKDIR"] = workspaceFolder
        if let creds = httpsCreds {
            execEnv["ADEV_CLONE_USER"] = creds.username
            execEnv["ADEV_CLONE_PASS"] = creds.password
            if let fields = GitURLClassifier.httpsCredentialFields(for: effectiveCloneURL) {
                execEnv["ADEV_CLONE_PROTO"] = fields.protocolName
                execEnv["ADEV_CLONE_HOST"] = fields.host
            }
        }

        let script = inContainerCloneScript(configureHTTPSStore: httpsCreds != nil)
        // Live-tee populate git clone like lifecycle hooks / Features build (framed tool lines).
        let result = try runtime.exec(
            nameOrId: containerId,
            command: ["sh", "-c", script],
            user: remoteUser,
            workdir: workspaceFolder,
            env: execEnv,
            streamOutput: true
        )

        guard result.succeeded else {
            var detail = [
                result.stderrString.trimmingCharacters(in: .whitespacesAndNewlines),
                result.stdoutString.trimmingCharacters(in: .whitespacesAndNewlines)
            ].filter { !$0.isEmpty }.joined(separator: " | ")
            detail = HostGitClient.redactURLUserinfo(in: detail, originalURL: url)
            if let user = httpsCreds?.username {
                detail = detail.replacingOccurrences(of: user, with: "***")
            }
            // Never include password material if git echoed it.
            if let pass = httpsCreds?.password, !pass.isEmpty {
                detail = detail.replacingOccurrences(of: pass, with: "***")
            }
            let httpsHint: String = {
                if httpsCreds == nil {
                    return "Private HTTPS repos need host git credentials (credential.helper / ADEVCONTAINER_GIT_TOKEN) or an SSH URL; ensure in-container git is installed"
                }
                return "Ensure host HTTPS credentials are valid and in-container git is installed"
            }()
            throw CLIError(
                code: CLIErrorCode.populateFailed,
                message: "In-container git clone failed (exit \(result.exitCode))"
                    + (detail.isEmpty ? "" : ": \(detail)"),
                hint: urlKind == .ssh
                    ? "Ensure SSH agent is forwarded (--ssh) and the key can access the repository"
                    : httpsHint
            )
        }

        // Verify .git landed in the workspace volume.
        let gitDir = (workspaceFolder as NSString).appendingPathComponent(".git")
        let exists: Bool
        do {
            exists = try runtime.pathExistsInContainer(containerId: containerId, path: gitDir)
        } catch {
            throw CLIError(
                code: CLIErrorCode.populateFailed,
                message: "Failed to verify workspace populate: \(error.localizedDescription)",
                hint: "Could not exec test -e for \(gitDir)"
            )
        }
        guard exists else {
            throw CLIError(
                code: CLIErrorCode.populateFailed,
                message: "Workspace volume appears empty after clone (missing \(gitDir))",
                hint: "In-container git clone did not produce a .git directory"
            )
        }
    }

    /// Portable sh script: clone into workspace (handles lost+found-only volumes).
    /// Credentials (when set) arrive via env ADEV_CLONE_USER / ADEV_CLONE_PASS — never printed.
    private static func inContainerCloneScript(configureHTTPSStore: Bool) -> String {
        // shellcheck-style: set -e; use env vars only.
        var lines: [String] = [
            "set -e",
            "WS=\"${ADEV_CLONE_WORKDIR:-.}\"",
            "URL=\"${ADEV_CLONE_URL:?}\"",
            "mkdir -p \"$WS\"",
            "export GIT_TERMINAL_PROMPT=0",
        ]

        if configureHTTPSStore {
            lines += [
                // One-shot ASKPASS: reads username/password from env at prompt time.
                "ASKPASS=\"$(mktemp)\"",
                "trap 'rm -f \"$ASKPASS\"' EXIT",
                "cat > \"$ASKPASS\" <<'ASKEOF'",
                "#!/bin/sh",
                "case \"$1\" in",
                "  *[Uu]sername*) printf '%s\\n' \"$ADEV_CLONE_USER\" ;;",
                "  *) printf '%s\\n' \"$ADEV_CLONE_PASS\" ;;",
                "esac",
                "ASKEOF",
                "chmod 700 \"$ASKPASS\"",
                "export GIT_ASKPASS=\"$ASKPASS\"",
                "export SSH_ASKPASS=\"$ASKPASS\"",
                "export GIT_ASKPASS_REQUIRE=force",
            ]
        }

        // Clone into a temp dir on the same volume, then move into WS.
        // Handles empty mounts and lost+found-only ext volumes.
        lines += [
            "TMP=\"$WS/.adev-clone-tmp-$$\"",
            "rm -rf \"$TMP\"",
            "git clone -- \"$URL\" \"$TMP\"",
            // Move all entries including dotfiles except . and ..
            "ls -A \"$TMP\" | while IFS= read -r f; do",
            "  mv \"$TMP/$f\" \"$WS/\"",
            "done",
            "rmdir \"$TMP\" 2>/dev/null || rm -rf \"$TMP\"",
        ]

        if configureHTTPSStore {
            // HTTPS after clone: store helper + approve once into ~/.git-credentials (user home layer).
            lines += [
                "git -C \"$WS\" config credential.helper store",
                "if [ -n \"${ADEV_CLONE_PROTO:-}\" ] && [ -n \"${ADEV_CLONE_HOST:-}\" ]; then",
                "  printf 'protocol=%s\\nhost=%s\\nusername=%s\\npassword=%s\\n\\n' \\",
                "    \"$ADEV_CLONE_PROTO\" \"$ADEV_CLONE_HOST\" \"$ADEV_CLONE_USER\" \"$ADEV_CLONE_PASS\" \\",
                "    | git -C \"$WS\" credential approve",
                "fi",
                "rm -f \"$ASKPASS\"",
                "trap - EXIT",
            ]
        }

        return lines.joined(separator: "\n")
    }

    // MARK: - Helpers

    private static func removeTemp(_ url: URL, fileManager: FileManager) {
        guard fileManager.fileExists(atPath: url.path) else { return }
        do {
            try fileManager.removeItem(at: url)
        } catch {
            // Spec: cleanup failure → stderr warning only; do not flip success.
            StatusPrinter.warning("Failed to remove temp directory \(url.path): \(error.localizedDescription)")
        }
    }

    private static func enforceHostRequirements(
        config: ResolvedDevContainerConfig,
        host: any HostResourceProviding
    ) throws {
        let evaluation = HostRequirementsEvaluation.evaluate(config.hostRequirements, host: host)
        for warning in evaluation.warnings {
            StatusPrinter.warning(warning)
        }
        guard evaluation.hasHardFailures else { return }
        throw CLIError(
            code: CLIErrorCode.hostRequirements,
            property: "hostRequirements",
            message: evaluation.hardFailures.joined(separator: "; "),
            hint: "Reduce hostRequirements or run on a host with sufficient memory/CPUs"
        )
    }
}
