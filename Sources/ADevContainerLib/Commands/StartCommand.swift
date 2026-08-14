import Foundation

public struct StartOptions: Sendable {
    public var name: String?
    /// Best-effort open of VS Code on the remote workspace after start success.
    public var openVSCode: Bool
    /// Machine-readable error mode suppresses interactive recovery.
    public var jsonOutput: Bool

    public init(name: String? = nil, openVSCode: Bool = false, jsonOutput: Bool = false) {
        self.name = name
        self.openVSCode = openVSCode
        self.jsonOutput = jsonOutput
    }
}

public enum StartCommand {
    /// Optional rebuild-delegation seam for tests (same pattern as RebuildCommand overrides).
    /// When set, replaces the `RebuildCommand.run` delegation used by start recovery.
    nonisolated(unsafe) public static var rebuildOverride: ((RebuildOptions) throws -> RebuildResult)?

    /// Start a stopped managed container.
    /// Host initialize runs on a real start when a host workspace exists; then start;
    /// then config + remelted feature postStart. Already-running skips those hooks.
    /// Real start runs postAttach as CLI attach (not `--vscode`-gated). Already-running
    /// runs postAttach only after successful `--vscode` open. Never applies settings or extensions.
    /// Hook progress and `==> Ready` use StatusPrinter (stderr); `--json` keeps stdout clean.
    public static func run(
        options: StartOptions,
        runtime: AppleContainerRuntime,
        picker: InteractivePicker = .default,
        isTTY: Bool = AppleContainerConfig.stdinIsTTY(),
        openEditorPrompt: RecoveryOpenEditorPrompt = .default
    ) throws {
        let info = try ManagedContainers.resolveSelection(
            name: options.name,
            runtime: runtime,
            picker: picker
        )

        if info.isRunning {
            StatusPrinter.status("Container already running", item: info.id)
            try openAndPostAttach(
                options: options,
                nameOrId: info.id,
                runtime: runtime,
                picker: picker,
                kind: .alreadyRunning
            )
            StatusPrinter.status("Ready")
            SuccessPresentation.emitConnectionHintsIfNeeded(
                openVSCode: options.openVSCode,
                nameOrId: info.name
            )
            return
        }

        let hostWorkspace = info.labels[ContainerIdentity.labelLocalFolder]
        // Initialize is host/config-only — do not remelt metadata before start
        // (start-failure recovery must not inspect the image).
        var hooksConfig = loadInitializeConfig(info: info, runtime: runtime)
        try LifecycleRunner.runInitializeCommand(
            config: hooksConfig,
            hostWorkspace: hostWorkspace
        )

        StatusPrinter.status("Starting container", item: info.id)
        do {
            try runtime.start(nameOrId: info.id)
        } catch {
            try recoverStartFailure(
                failure: error,
                info: info,
                options: options,
                runtime: runtime,
                picker: picker,
                isTTY: isTTY,
                openEditorPrompt: openEditorPrompt
            )
            return
        }
        // Remelt after start for postStart/postAttach. Never run initialize here:
        // volume config becoming readable must not violate initialize-before-start.
        if hooksConfig == nil {
            hooksConfig = loadHooksConfig(info: info, runtime: runtime)
        } else if var loaded = hooksConfig {
            // Remelt again after start so image-only metadata and a fresh inspect
            // (list may omit image ref / inherited labels) are visible.
            let live = (try? runtime.inspect(nameOrId: info.id)) ?? info
            PostAttachConfigLoader.mergeFeaturePostAttach(
                into: &loaded,
                labels: live.labels,
                imageRef: live.image ?? info.image,
                runtime: runtime,
                workspacePath: hostWorkspace
            )
            hooksConfig = loaded
        }
        // Resume: create-path waitFor is already satisfied — do not re-exec onCreate /
        // updateContent / postCreate. Config then remelted feature postStart run via
        // LifecycleRunner (userEnvProbe merge applies). If waitFor is postStartCommand,
        // hold open / postAttach until this start's postStart finishes.
        // Recovery that delegated to rebuild already returned. Never apply settings/extensions.
        if let config = hooksConfig {
            if LifecycleRunner.resumeShouldWaitForPostStart(config.waitFor) {
                try LifecycleRunner.runRestartPostStart(
                    containerId: info.id,
                    config: config,
                    runtime: runtime
                )
                try openAndPostAttach(
                    options: options,
                    nameOrId: info.id,
                    runtime: runtime,
                    picker: picker,
                    kind: .cliAttach
                )
            } else {
                try openAndPostAttach(
                    options: options,
                    nameOrId: info.id,
                    runtime: runtime,
                    picker: picker,
                    kind: .cliAttach
                )
                try LifecycleRunner.runRestartPostStart(
                    containerId: info.id,
                    config: config,
                    runtime: runtime
                )
            }
        } else {
            try openAndPostAttach(
                options: options,
                nameOrId: info.id,
                runtime: runtime,
                picker: picker,
                kind: .cliAttach
            )
        }
        StatusPrinter.status("Ready")
        SuccessPresentation.emitConnectionHintsIfNeeded(
            openVSCode: options.openVSCode,
            nameOrId: info.name
        )
    }

    /// Recovery for a failed `runtime.start`: in a TTY print the structured failure and prompt
    /// (default Y), then on affirmative delegate to `RebuildCommand.run` for the same container.
    /// Decline/EOF or non-TTY throw the original error with a `rebuild --name` hint. Never opens
    /// an editor and never re-runs `start` (ports/labels are baked at create).
    private static func recoverStartFailure(
        failure: Error,
        info: ContainerInfo,
        options: StartOptions,
        runtime: AppleContainerRuntime,
        picker: InteractivePicker,
        isTTY: Bool,
        openEditorPrompt: RecoveryOpenEditorPrompt
    ) throws {
        let hinted = startRecoveryHintError(failure, name: info.name)
        guard isTTY, !options.jsonOutput else {
            throw hinted
        }

        // Print the structured failure, then prompt (default Y).
        openEditorPrompt.writeError(hinted.formatted() + "\n")
        switch openEditorPrompt.ask() {
        case .decline:
            throw hinted
        case .affirmative:
            break
        }

        let result = try runRebuild(
            options: RebuildOptions(
                name: info.name,
                skipPull: false,
                openVSCode: options.openVSCode,
                jsonOutput: false
            ),
            runtime: runtime,
            picker: picker,
            isTTY: isTTY,
            openEditorPrompt: openEditorPrompt
        )
        SuccessPresentation.emitHumanDigest(result)
        SuccessPresentation.emitConnectionHintsIfNeeded(
            openVSCode: options.openVSCode,
            nameOrId: result.containerName ?? result.containerId
        )
    }

    /// Original failure plus a `rebuild --name` hint (preserves code/message/property so
    /// scripts can match on the failure that triggered recovery rather than a synthetic wrapper).
    private static func startRecoveryHintError(_ failure: Error, name: String) -> CLIError {
        let retry = "adevcontainer rebuild --name \(name)"
        if let cli = failure as? CLIError {
            return CLIError(
                code: cli.code,
                property: cli.property,
                message: cli.message,
                hint: cli.hint.map { "\(retry) (\($0))" } ?? retry,
                recovery: cli.recovery
            )
        }
        return CLIError(
            code: CLIErrorCode.runtimeFailed,
            message: failure.localizedDescription,
            hint: retry
        )
    }

    /// Delegate to `RebuildCommand.run` (or the test seam) and propagate its result/error.
    private static func runRebuild(
        options: RebuildOptions,
        runtime: AppleContainerRuntime,
        picker: InteractivePicker,
        isTTY: Bool,
        openEditorPrompt: RecoveryOpenEditorPrompt
    ) throws -> RebuildResult {
        if let override = rebuildOverride {
            return try override(options)
        }
        return try RebuildCommand.run(
            options: options,
            runtime: runtime,
            picker: picker,
            isTTY: isTTY,
            openEditorPrompt: openEditorPrompt
        )
    }

    /// Host initialize only: stamped config without metadata remelt (no image inspect).
    private static func loadInitializeConfig(
        info: ContainerInfo,
        runtime: AppleContainerRuntime
    ) -> ResolvedDevContainerConfig? {
        do {
            return try ConfigReader.read(
                labels: info.labels,
                containerId: info.id,
                runtime: runtime,
                mode: .bestEffort
            )
        } catch {
            return nil
        }
    }

    /// Hooks/open/postAttach config from stamped labels. Never used to apply settings/extensions.
    /// Remelts container+image metadata even when the stamped config is unreadable.
    private static func loadHooksConfig(
        info: ContainerInfo,
        runtime: AppleContainerRuntime
    ) -> ResolvedDevContainerConfig? {
        do {
            return try PostAttachConfigLoader.load(
                labels: info.labels,
                containerId: info.id,
                imageRef: info.image,
                runtime: runtime
            )
        } catch {
            return nil
        }
    }

    /// Open (optional) then postAttach gate. Loads config from stamped labels for postAttach only.
    /// `start` never applies settings or extensions. Real start is CLI attach; already-running
    /// runs postAttach only after successful `--vscode` open.
    private static func openAndPostAttach(
        options: StartOptions,
        nameOrId: String,
        runtime: AppleContainerRuntime,
        picker: InteractivePicker,
        kind: LifecycleRunner.PostAttachKind
    ) throws {
        // id / image / folder / labels from inspect (start has no UpResult).
        let payload: InspectPayload?
        do {
            payload = try InspectCommand.run(name: nameOrId, runtime: runtime, picker: picker)
        } catch {
            if options.openVSCode {
                StatusPrinter.warning(
                    "VS Code open skipped: could not inspect container (\(error.localizedDescription))"
                )
            }
            // Without inspect we cannot load postAttach config or open inputs.
            return
        }
        guard let payload else { return }

        let image = (payload.image ?? "").trimmingCharacters(in: .whitespacesAndNewlines)

        // Resolve config from labels for postAttach only — never for settings/extensions apply.
        // Load must not fail start after container is already up — treat errors as absent.
        let config: ResolvedDevContainerConfig?
        do {
            config = try PostAttachConfigLoader.load(
                labels: payload.labels,
                containerId: payload.containerId,
                imageRef: image.isEmpty ? nil : image,
                runtime: runtime
            )
        } catch {
            StatusPrinter.warning(
                "postAttach config unavailable (\(error.localizedDescription))"
            )
            config = nil
        }

        let openOutcome: VSCodeOpenOutcome
        if options.openVSCode {
            openOutcome = VSCodeOpen.bestEffortOpen(
                target: VSCodeOpenTarget(
                    containerId: payload.containerId,
                    image: image,
                    remoteWorkspaceFolder: payload.remoteWorkspaceFolder,
                    containerName: payload.containerName,
                    remoteUser: payload.remoteUser
                )
            )
        } else {
            openOutcome = .notRequested
        }

        if let config {
            try LifecycleRunner.applyPostAttachGate(
                openOutcome: openOutcome,
                kind: kind,
                containerId: payload.containerId,
                config: config,
                runtime: runtime
            )
        }
        // nil config → treat postAttach as absent (start success preserved).
    }
}
