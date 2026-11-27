import Foundation

public enum DeleteCommand {
    /// Delete container only (never workspace volume or config volumes).
    /// Selection is managed-only via `--name` / picker.
    ///
    /// When no `--name` is given and the only managed container was auto-selected, confirms on
    /// a TTY first (default no; selection is not cwd-scoped). Non-TTY proceeds without a prompt.
    public static func run(
        name: String? = nil,
        runtime: AppleContainerRuntime,
        picker: InteractivePicker = .default,
        isInteractive: Bool = AppleContainerConfig.stdinIsTTY(),
        readLine: @escaping () -> String? = { Swift.readLine() }
    ) throws {
        let (info, isAutoSingle) = try ManagedContainers.resolveSelectionReportingAutoSingle(
            name: name,
            runtime: runtime,
            picker: picker
        )
        if isAutoSingle, isInteractive {
            guard ManagedContainers.confirmTarget(
                info,
                isAutoSingle: true,
                action: "Delete",
                note: "Removes the container only; volumes and workspace are kept.",
                readLine: readLine
            ) else {
                FileHandle.standardError.write(Data("Delete cancelled\n".utf8))
                return
            }
        }
        StatusPrinter.status("Deleting container", item: info.id)
        GitCredentialLifecycle.unregisterSoft(id: info.id, runtime: runtime)
        try runtime.delete(nameOrId: info.id, force: true)
        print("Deleted \(info.id)")
    }
}
