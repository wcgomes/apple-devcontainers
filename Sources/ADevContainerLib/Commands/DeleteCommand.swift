import Foundation

public enum DeleteCommand {
    /// Delete container only (never workspace volume or config volumes).
    /// Selection is managed-only via `--name` / picker.
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
        StatusPrinter.status("Deleting container \(info.id)")
        try runtime.delete(nameOrId: info.id, force: true)
        print("Deleted \(info.id)")
    }
}
