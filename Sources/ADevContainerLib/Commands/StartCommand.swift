import Foundation

public struct StartOptions: Sendable {
    public var name: String?
    /// Best-effort open of VS Code on the remote workspace after start success.
    public var openVSCode: Bool

    public init(name: String? = nil, openVSCode: Bool = false) {
        self.name = name
        self.openVSCode = openVSCode
    }
}

public enum StartCommand {
    /// Start a stopped managed container.
    /// Create-path / postStart hooks stay on `up`/`clone`; postAttach is gated after optional open.
    public static func run(
        options: StartOptions,
        runtime: AppleContainerRuntime,
        picker: InteractivePicker = .default
    ) throws {
        let info = try ManagedContainers.resolveSelection(
            name: options.name,
            runtime: runtime,
            picker: picker
        )

        if info.isRunning {
            print("Container \(info.id) already running")
            try openAndPostAttach(options: options, nameOrId: info.id, runtime: runtime, picker: picker)
            return
        }

        StatusPrinter.status("Starting container \(info.id)")
        try runtime.start(nameOrId: info.id)
        // Bare start: no create-path / postStart. postAttach only via --vscode open gate.
        print("Started \(info.id)")
        try openAndPostAttach(options: options, nameOrId: info.id, runtime: runtime, picker: picker)
    }

    /// Open (optional) then postAttach gate. Loads config from stamped labels when needed.
    private static func openAndPostAttach(
        options: StartOptions,
        nameOrId: String,
        runtime: AppleContainerRuntime,
        picker: InteractivePicker
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

        // Resolve config from labels (bind host paths or volume cat) for postAttach + vscode apply.
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
        if let config {
            // Settings repair on marker drift (not gated on --vscode).
            _ = VSCodeCustomizationsApply.applySettingsIfNeeded(
                containerId: payload.containerId,
                config: config,
                runtime: runtime
            )
            // Extensions only after successful open.
            if openOutcome.isOpenSuccess {
                _ = VSCodeCustomizationsApply.applyExtensionsIfNeeded(
                    containerId: payload.containerId,
                    config: config,
                    runtime: runtime
                )
            }
            try LifecycleRunner.applyPostAttachGate(
                openOutcome: openOutcome,
                containerId: payload.containerId,
                config: config,
                runtime: runtime
            )
        }
        // nil config → treat postAttach / customizations apply as absent (start success preserved).
    }
}
