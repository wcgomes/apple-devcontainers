import Foundation

public enum StopCommand {
    /// Stop a managed container via `--name` or interactive picker.
    public static func run(
        name: String? = nil,
        runtime: AppleContainerRuntime,
        picker: InteractivePicker = .default
    ) throws {
        let info = try ManagedContainers.resolveSelection(
            name: name,
            runtime: runtime,
            picker: picker
        )

        if !info.isRunning {
            print("Container \(info.id) already stopped")
            return
        }
        StatusPrinter.status("Stopping container \(info.id)")
        try runtime.stop(nameOrId: info.id)
        print("Stopped \(info.id)")
    }
}
