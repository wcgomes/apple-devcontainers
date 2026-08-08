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
    /// Start a stopped managed container. Volume-mode: runtime start only (no lifecycle hooks).
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
            openVSCodeIfRequested(options: options, nameOrId: info.id, runtime: runtime, picker: picker)
            return
        }

        StatusPrinter.status("Starting container \(info.id)")
        try runtime.start(nameOrId: info.id)
        // Bare start: runtime only (no lifecycle hooks). Bind postStart remains on `up` path.
        print("Started \(info.id)")
        openVSCodeIfRequested(options: options, nameOrId: info.id, runtime: runtime, picker: picker)
    }

    private static func openVSCodeIfRequested(
        options: StartOptions,
        nameOrId: String,
        runtime: AppleContainerRuntime,
        picker: InteractivePicker
    ) {
        guard options.openVSCode else { return }
        // id / image / folder from inspect (start has no UpResult).
        let payload: InspectPayload
        do {
            payload = try InspectCommand.run(name: nameOrId, runtime: runtime, picker: picker)
        } catch {
            StatusPrinter.warning(
                "VS Code open skipped: could not inspect container (\(error.localizedDescription))"
            )
            return
        }
        let image = (payload.image ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        VSCodeOpen.bestEffortOpen(
            target: VSCodeOpenTarget(
                containerId: payload.containerId,
                image: image,
                remoteWorkspaceFolder: payload.remoteWorkspaceFolder,
                containerName: payload.containerName,
                remoteUser: payload.remoteUser
            )
        )
    }
}
