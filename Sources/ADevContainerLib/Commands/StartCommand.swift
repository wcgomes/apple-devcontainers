import Foundation

public struct StartOptions: Sendable {
    public var name: String?

    public init(name: String? = nil) {
        self.name = name
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
            return
        }

        StatusPrinter.status("Starting container \(info.id)")
        try runtime.start(nameOrId: info.id)
        // Bare start: runtime only (no lifecycle hooks). Bind postStart remains on `up` path.
        print("Started \(info.id)")
    }
}
