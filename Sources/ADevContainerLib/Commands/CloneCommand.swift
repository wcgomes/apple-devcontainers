import Foundation

public struct CloneOptions: Sendable {
    public var gitURL: String
    public var skipPull: Bool
    /// Best-effort open of VS Code on the remote workspace after lifecycle success.
    public var openVSCode: Bool
    /// Machine-readable success JSON on stdout when true; human digest otherwise.
    public var jsonOutput: Bool
    /// Retained config-only checkout directory for a non-interactive `--resume` retry.
    /// When set, clone skips the host git config fetch and re-resolves from this checkout.
    public var resumeConfigDir: String?

    public init(
        gitURL: String,
        skipPull: Bool = false,
        openVSCode: Bool = false,
        jsonOutput: Bool = false,
        resumeConfigDir: String? = nil
    ) {
        self.gitURL = gitURL
        self.skipPull = skipPull
        self.openVSCode = openVSCode
        self.jsonOutput = jsonOutput
        self.resumeConfigDir = resumeConfigDir
    }
}

public enum CloneCommand {
    /// Optional Features fetch override for tests.
    nonisolated(unsafe) public static var featuresFetcherOverride: (any FeatureFetching)?
    nonisolated(unsafe) public static var featuresCacheRootOverride: String?
    nonisolated(unsafe) public static var ensureNativeArmBuildOverride: (() throws -> Void)?
    /// Optional retained-checkout root override for tests (nil → user Application Support).
    nonisolated(unsafe) public static var retainedCheckoutRootOverride: String?

    private static let retainedCheckoutMarkerName = ".adevcontainer-retained-checkout"
    private static let retainedCheckoutMarker = "adevcontainer-clone-recovery-v1\n"

    public static func run(
        options: CloneOptions,
        runtime: AppleContainerRuntime,
        git: any GitClient = HostGitClient(),
        credentials: any GitCredentialProviding = HostGitCredential(),
        localEnv: [String: String] = ProcessInfo.processInfo.environment,
        hostResources: any HostResourceProviding = SystemHostResourceInfo(),
        fileManager: FileManager = .default,
        identityPrompt: IdentityPrompt = .default,
        isTTY: Bool = AppleContainerConfig.stdinIsTTY(),
        openEditorPrompt: RecoveryOpenEditorPrompt = .default,
        editor: RecoveryEditor? = nil
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

        let repoBasename = ContainerIdentity.repoBasename(fromGitURL: url)

        // Working checkout dir: `--resume` reuses a retained checkout (no fetch); a fresh
        // clone fetches config-only into a temp dir. Full tree clone runs inside the container.
        var checkoutDir: URL
        let isResume: Bool
        if let resumeDir = nonEmptyTrimmed(options.resumeConfigDir) {
            isResume = true
            checkoutDir = try Self.validatedRetainedCheckout(
                URL(fileURLWithPath: resumeDir),
                fileManager: fileManager
            )
        } else {
            isResume = false
            checkoutDir = fileManager.temporaryDirectory
                .appendingPathComponent("adev-clone-cfg-\(UUID().uuidString)", isDirectory: true)
        }

        // A fresh temp checkout is removed on exit unless it was retained (moved) for recovery.
        var retained = false
        let freshTempDir: URL? = isResume ? nil : checkoutDir
        defer {
            if let freshTempDir, !retained {
                removeTemp(freshTempDir, fileManager: fileManager)
            }
        }

        if !isResume {
            // 2. Config-only fetch into temp (host credentials).
            StatusPrinter.status("Fetching devcontainer config")
            try git.fetchConfig(url: url, into: checkoutDir.path)
        }

        // Resolve author from host git config in the checkout (includeIf by remote).
        // Env overrides win per field when set. Never invent fake identity.
        let resolvedAuthor = Self.effectiveAuthorIdentity(
            resolved: git.resolveAuthorIdentity(in: checkoutDir.path),
            localEnv: localEnv
        )
        let bothAuthorEnvExplicit = Self.bothAuthorEnvOverridesSet(localEnv: localEnv)

        // 3. Discover config (nested then root). Config-not-found has no editable config → no recovery.
        let configPath: String
        do {
            configPath = try ConfigDiscovery.discover(
                workspacePath: checkoutDir.path,
                fileManager: fileManager
            )
        } catch let err as CLIError where err.code == CLIErrorCode.configNotFound {
            throw CLIError(
                code: CLIErrorCode.configNotFound,
                message: "No devcontainer.json found in repository",
                hint: "Looked for \(ConfigDiscovery.nestedRelativePath) and \(ConfigDiscovery.rootRelativePath)"
            )
        }

        let configRelPath = Self.configRelativePath(configPath, root: checkoutDir.path)

        // Confirm/collect author identity once (independent of devcontainer.json edits).
        let authorIdentity = try identityPrompt.confirmOrCollect(
            current: resolvedAuthor,
            bothEnvExplicit: bothAuthorEnvExplicit
        )

        // Re-entrant post-fetch pipeline keyed on the current checkout dir. `retry` re-runs
        // this from the retained checkout (never a fresh git.fetchConfig). Persist the
        // retained/edited host config into the volume only on `--resume` or a recovery retry —
        // never on a non-recovery first clone.
        var persistEditedConfig = isResume
        func pipeline() throws -> CloneResult {
            try Self.runPostFetchPipeline(
                checkoutDir: checkoutDir.path,
                configRelPath: configRelPath,
                authorIdentity: authorIdentity,
                url: url,
                urlKind: urlKind,
                enableSSHForward: enableSSHForward,
                repoBasename: repoBasename,
                options: options,
                runtime: runtime,
                credentials: credentials,
                localEnv: localEnv,
                hostResources: hostResources,
                fileManager: fileManager,
                persistEditedConfig: persistEditedConfig
            )
        }

        do {
            let result = try pipeline()
            if isResume {
                removeRetainedCheckout(checkoutDir, fileManager: fileManager)
            }
            return result
        } catch let failure as BringUpRecovery.EligibleFailure {
            // Eligible bring-up failure with an editable config checkout: retain it in a
            // stable non-temporary location, then drive the shared edit-and-retry loop.
            var retainedCheckoutDir = checkoutDir
            if !isResume {
                retainedCheckoutDir = try Self.retainCheckout(
                    sourceDir: checkoutDir,
                    repoBasename: repoBasename,
                    fileManager: fileManager
                )
                retained = true
                checkoutDir = retainedCheckoutDir
            }

            let retainedConfigPath = (retainedCheckoutDir.path as NSString)
                .appendingPathComponent(configRelPath)
            let resolvedEditor = editor ?? RecoveryEditor(environment: localEnv)
            let editCommand = resolvedEditor.command(for: retainedConfigPath)
                .map(Self.shellQuoteCommand)
                ?? "recovery editor unavailable"
            let retryCommand = Self.cloneResumeCommand(
                url: url,
                checkoutDir: retainedCheckoutDir.path,
                options: options
            )
            let guidance = BringUpRecovery.Guidance(
                configPath: retainedConfigPath,
                editCommand: editCommand,
                retryCommand: retryCommand
            )

            persistEditedConfig = true
            let recovered = try BringUpRecovery.run(
                failure: failure,
                guidance: guidance,
                isTTY: isTTY,
                jsonOutput: options.jsonOutput,
                openEditorPrompt: openEditorPrompt,
                edit: {
                    try Self.editRetainedConfig(
                        configPath: retainedConfigPath,
                        checkoutDir: retainedCheckoutDir.path,
                        repoBasename: repoBasename,
                        localEnv: localEnv,
                        fileManager: fileManager,
                        editor: resolvedEditor
                    )
                },
                retry: { try pipeline() }
            )
            // Recovery succeeded: the retained checkout has served its purpose. Only
            // retained on failure (decline/EOF/non-TTY) for a later `--resume`.
            removeRetainedCheckout(retainedCheckoutDir, fileManager: fileManager)
            return recovered
        }
    }

    // MARK: - Post-fetch pipeline (re-entrant, keyed on the checkout dir)

    /// Re-runs resolve → features → create → start → ownership → populate → hooks from the
    /// checkout dir. `checkoutDir` is the temp dir on first run and the retained checkout on retry.
    private static func runPostFetchPipeline(
        checkoutDir: String,
        configRelPath: String,
        authorIdentity: GitAuthorIdentity,
        url: String,
        urlKind: GitURLKind,
        enableSSHForward: Bool,
        repoBasename: String,
        options: CloneOptions,
        runtime: AppleContainerRuntime,
        credentials: any GitCredentialProviding,
        localEnv: [String: String],
        hostResources: any HostResourceProviding,
        fileManager: FileManager,
        persistEditedConfig: Bool
    ) throws -> CloneResult {
        let configPath = (checkoutDir as NSString).appendingPathComponent(configRelPath)

        // 4. Resolve via existing pipeline (checkout as workspace for discovery/paths only).
        StatusPrinter.status("Resolving configuration")
        let resolved: ResolvedWorkspace
        do {
            resolved = try ConfigResolver.resolve(
                workspacePath: checkoutDir,
                configPath: configPath,
                localEnv: localEnv,
                fileManager: fileManager,
                workspaceFolderBasename: repoBasename
            )
        } catch let error as CLIError where error.code == CLIErrorCode.configNotFound {
            throw error
        } catch {
            throw BringUpRecovery.eligible(error)
        }

        try enforceHostRequirements(config: resolved.config, host: hostResources)

        // 5. Volume-mode identity (git URL + config rel path — not checkout path)
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
                ?? DefaultFeatureFetcher(workspacePath: checkoutDir)
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
        let id: String
        do {
            id = try runtime.create(request: request)
        } catch {
            // `runtime.create` ensures the clone workspace volume before invoking the
            // container create operation. Remove that empty/partial workspace before recovery
            // so a later retry starts from the same clean clone semantics as a fresh invocation.
            try? runtime.deleteVolume(name: identity.workspaceVolumeName)
            throw BringUpRecovery.eligible(error)
        }

        // 8. Start
        StatusPrinter.status("Starting container")
        do {
            try runtime.start(nameOrId: id)
        } catch {
            try? runtime.delete(nameOrId: id, force: true)
            try? runtime.deleteVolume(name: identity.workspaceVolumeName)
            throw BringUpRecovery.eligible(error)
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
            throw BringUpRecovery.eligible(error)
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
                throw BringUpRecovery.eligible(cli)
            }
            throw BringUpRecovery.eligible(CLIError(
                code: CLIErrorCode.populateFailed,
                message: "Failed to populate workspace volume: \(error.localizedDescription)",
                hint: "Check git access for the repository URL and that in-container git is available"
            ))
        }

        // 10a. Recovery/`--resume`: populate cloned the original remote config; overlay
        // the retained/edited host bytes at the same relative path so a later open
        // does not need to re-apply the recovery edit.
        if persistEditedConfig {
            do {
                try persistEditedConfigIntoWorkspace(
                    hostConfigPath: configPath,
                    containerId: id,
                    workspaceFolder: effectiveConfig.workspaceFolder,
                    configRelPath: configRelPath,
                    remoteUser: connectionUser,
                    runtime: runtime
                )
            } catch {
                try? runtime.delete(nameOrId: id, force: true)
                try? runtime.deleteVolume(name: identity.workspaceVolumeName)
                if let cli = error as? CLIError {
                    throw BringUpRecovery.eligible(cli)
                }
                throw BringUpRecovery.eligible(CLIError(
                    code: CLIErrorCode.populateFailed,
                    message: "Failed to persist edited devcontainer.json into the workspace: \(error.localizedDescription)",
                    hint: "The recovery edit could not be written after populate"
                ))
            }
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
            throw BringUpRecovery.eligible(error)
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
        // Extensions apply when pending (not gated on `--vscode`) → open → postAttach.
        _ = VSCodeCustomizationsApply.applyExtensionsIfNeeded(
            containerId: id,
            config: effectiveConfig,
            runtime: runtime
        )
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

    // MARK: - Recovery wiring

    /// Stable, non-temporary root for retained clone config checkouts. Defaults to
    /// `~/Library/Application Support/adevcontainer/clone-recovery` (tests override).
    public static func retainedCheckoutRoot(fileManager: FileManager = .default) -> String {
        if let override = retainedCheckoutRootOverride { return override }
        let base = fileManager.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? URL(fileURLWithPath: NSTemporaryDirectory())
        return base
            .appendingPathComponent("adevcontainer", isDirectory: true)
            .appendingPathComponent("clone-recovery", isDirectory: true)
            .path
    }

    /// Move a fresh temp checkout into the stable retained root. The source path is gone
    /// afterward, so the `defer removeTemp` on the temp dir is naturally a no-op.
    private static func retainCheckout(
        sourceDir: URL,
        repoBasename: String,
        fileManager: FileManager
    ) throws -> URL {
        let root = URL(fileURLWithPath: retainedCheckoutRoot(fileManager: fileManager))
        try fileManager.createDirectory(
            at: root,
            withIntermediateDirectories: true,
            attributes: [.posixPermissions: NSNumber(value: 0o700)]
        )
        let target = root.appendingPathComponent(
            "\(safeNameComponent(repoBasename))-\(UUID().uuidString.prefix(8))",
            isDirectory: true
        )
        do {
            try fileManager.moveItem(at: sourceDir, to: target)
        } catch {
            // Cross-volume move fallback: copy then remove the temp source.
            try fileManager.copyItem(at: sourceDir, to: target)
            try? fileManager.removeItem(at: sourceDir)
        }
        try fileManager.setAttributes(
            [.posixPermissions: NSNumber(value: 0o700)],
            ofItemAtPath: target.path
        )
        let markerURL = target.appendingPathComponent(retainedCheckoutMarkerName, isDirectory: false)
        try Data(retainedCheckoutMarker.utf8).write(to: markerURL, options: .atomic)
        try fileManager.setAttributes(
            [.posixPermissions: NSNumber(value: 0o600)],
            ofItemAtPath: markerURL.path
        )
        return target
    }

    /// Open the retained config in the editor, validating with clone resolve rules and
    /// re-opening on invalid content. Terminal attempts (cancel/editor failure) throw.
    private static func editRetainedConfig(
        configPath: String,
        checkoutDir: String,
        repoBasename: String,
        localEnv: [String: String],
        fileManager: FileManager,
        editor: RecoveryEditor
    ) throws {
        while true {
            StatusPrinter.status("Opening recovery editor for", item: configPath)
            let attempt = editor.edit(
                filePath: configPath,
                isTTY: true,
                jsonOutput: false,
                validate: { _ in
                    try validateRetainedConfig(
                        configPath: configPath,
                        checkoutDir: checkoutDir,
                        repoBasename: repoBasename,
                        localEnv: localEnv,
                        fileManager: fileManager
                    )
                }
            )
            switch attempt {
            case .normalExit:
                return
            case .invalidConfig(let error):
                StatusPrinter.warning(error.message)
                continue
            case .cancelled:
                throw attempt.cliError!
            case .noExecutable, .launchFailed, .failed:
                throw attempt.cliError!
            case .notRun:
                throw CLIError(
                    code: CLIErrorCode.recoveryUnavailable,
                    message: "Recovery editor did not run",
                    hint: "Re-run clone on a TTY without --json, or edit the retained config and retry with --resume"
                )
            }
        }
    }

    /// Volume/parse validation used by the clone resolve path (re-resolve the retained checkout).
    private static func validateRetainedConfig(
        configPath: String,
        checkoutDir: String,
        repoBasename: String,
        localEnv: [String: String],
        fileManager: FileManager
    ) throws {
        _ = try ConfigResolver.resolve(
            workspacePath: checkoutDir,
            configPath: configPath,
            localEnv: localEnv,
            fileManager: fileManager,
            workspaceFolderBasename: repoBasename
        )
    }

    /// Exact non-interactive resume command for a retained checkout.
    private static func cloneResumeCommand(
        url: String,
        checkoutDir: String,
        options: CloneOptions
    ) -> String {
        var command = "adevcontainer clone \(shellQuote(url))"
        if options.skipPull { command += " --skip-pull" }
        if options.openVSCode { command += " --vscode" }
        if options.jsonOutput { command += " --json" }
        command += " --resume \(shellQuote(checkoutDir))"
        return command
    }

    private static func shellQuoteCommand(_ args: [String]) -> String {
        args.map(shellQuote).joined(separator: " ")
    }

    private static func shellQuote(_ value: String) -> String {
        "'" + value.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }

    private static func safeNameComponent(_ value: String) -> String {
        let allowed = CharacterSet.alphanumerics.union(CharacterSet(charactersIn: "-_."))
        let filtered = String(value.unicodeScalars.map { allowed.contains($0) ? Character($0) : "_" })
        let trimmed = String(filtered.prefix(60))
        return trimmed.isEmpty ? "repo" : trimmed
    }

    /// Relative config path (`<root>-relative`) reused across checkout moves.
    private static func configRelativePath(_ configPath: String, root: String) -> String {
        let rootPath = (root as NSString).standardizingPath
        let full = (configPath as NSString).standardizingPath
        if full.hasPrefix(rootPath + "/") {
            return String(full.dropFirst(rootPath.count + 1))
        }
        if full.hasSuffix(ConfigDiscovery.nestedRelativePath) {
            return ConfigDiscovery.nestedRelativePath
        }
        return ConfigDiscovery.rootRelativePath
    }

    private static func nonEmptyTrimmed(_ value: String?) -> String? {
        let trimmed = value?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return trimmed.isEmpty ? nil : trimmed
    }

    /// Resume accepts only a product-retained direct child of the managed root. The marker
    /// prevents a user-created directory inside that root from becoming removable product
    /// state, while canonical containment rejects `..` and symlink escapes.
    private static func validatedRetainedCheckout(
        _ suppliedURL: URL,
        fileManager: FileManager
    ) throws -> URL {
        let root = URL(fileURLWithPath: retainedCheckoutRoot(fileManager: fileManager))
            .standardizedFileURL
        let canonicalRoot = root.resolvingSymlinksInPath().standardizedFileURL
        var rootIsDirectory: ObjCBool = false
        guard fileManager.fileExists(atPath: root.path, isDirectory: &rootIsDirectory),
              rootIsDirectory.boolValue
        else {
            throw invalidResumeCheckout(suppliedURL.path)
        }

        let candidate = suppliedURL.standardizedFileURL
        let canonicalCandidate = candidate.resolvingSymlinksInPath().standardizedFileURL
        guard candidate.path != root.path,
              candidate.lastPathComponent == canonicalCandidate.lastPathComponent,
              canonicalCandidate.deletingLastPathComponent() == canonicalRoot
        else {
            throw invalidResumeCheckout(candidate.path)
        }

        var isDirectory: ObjCBool = false
        guard fileManager.fileExists(atPath: candidate.path, isDirectory: &isDirectory),
              isDirectory.boolValue,
              !isSymbolicLink(candidate.path, fileManager: fileManager)
        else {
            throw invalidResumeCheckout(candidate.path)
        }

        let markerURL = candidate.appendingPathComponent(retainedCheckoutMarkerName, isDirectory: false)
        guard !isSymbolicLink(markerURL.path, fileManager: fileManager),
              let marker = try? String(contentsOf: markerURL, encoding: .utf8),
              marker == retainedCheckoutMarker
        else {
            throw invalidResumeCheckout(candidate.path)
        }
        return candidate
    }

    private static func invalidResumeCheckout(_ path: String) -> CLIError {
        CLIError(
            code: CLIErrorCode.recoveryUnavailable,
            message: "Resume checkout is not a managed retained clone checkout: \(path)",
            hint: "Use the exact config directory printed by an earlier clone recovery failure"
        )
    }

    private static func isSymbolicLink(_ path: String, fileManager: FileManager) -> Bool {
        (try? fileManager.destinationOfSymbolicLink(atPath: path)) != nil
    }

    private static func removeRetainedCheckout(_ url: URL, fileManager: FileManager) {
        guard (try? validatedRetainedCheckout(url, fileManager: fileManager)) != nil else {
            StatusPrinter.warning("Refusing to remove an unmanaged clone recovery checkout \(url.path)")
            return
        }
        removeTemp(url, fileManager: fileManager)
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

    /// Overlay the retained/edited host `devcontainer.json` onto the in-container workspace
    /// after populate. Path is argv (`$1`), never shell-interpolated. Used only on a clone
    /// recovery retry or `--resume` — not rebuild helper write-back.
    private static func persistEditedConfigIntoWorkspace(
        hostConfigPath: String,
        containerId: String,
        workspaceFolder: String,
        configRelPath: String,
        remoteUser: String?,
        runtime: AppleContainerRuntime
    ) throws {
        let bytes: Data
        do {
            bytes = try Data(contentsOf: URL(fileURLWithPath: hostConfigPath))
        } catch {
            throw CLIError(
                code: CLIErrorCode.populateFailed,
                message: "Failed to read edited devcontainer.json for workspace persist",
                hint: "Ensure the retained checkout config is readable"
            )
        }
        let dest = (workspaceFolder as NSString).appendingPathComponent(configRelPath)
        let result = try runtime.exec(
            nameOrId: containerId,
            command: [
                "sh", "-c", "cat > \"$1\"",
                "adevcontainer-clone-persist",
                dest
            ],
            user: remoteUser,
            workdir: workspaceFolder,
            stdinData: bytes
        )
        guard result.succeeded else {
            throw CLIError(
                code: CLIErrorCode.populateFailed,
                message: "Failed to persist edited devcontainer.json into the workspace",
                hint: "The recovery edit could not be written after populate"
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
