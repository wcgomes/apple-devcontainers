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
            SuccessPresentation.emitConnectionHintsIfNeeded(
                openVSCode: options.openVSCode,
                nameOrId: info.name
            )
            return
        }

        StatusPrinter.status("Starting container", item: info.id)
        try runtime.start(nameOrId: info.id)
        // Bare start: no create-path / postStart. No settings or extensions apply. postAttach via open gate.
        print("Started \(info.id)")
        try openAndPostAttach(options: options, nameOrId: info.id, runtime: runtime, picker: picker)
        SuccessPresentation.emitConnectionHintsIfNeeded(
            openVSCode: options.openVSCode,
            nameOrId: info.name
        )
    }

    /// Open (optional) then postAttach gate. Loads config from stamped labels for postAttach only.
    /// `start` never applies settings or extensions.
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
                containerId: payload.containerId,
                config: config,
                runtime: runtime
            )
        }
        // nil config → treat postAttach as absent (start success preserved).
    }
}
