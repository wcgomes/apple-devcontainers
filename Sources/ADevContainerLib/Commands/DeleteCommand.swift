import Foundation

public enum DeleteCommand {
    public static func run(
        workspacePath: String,
        runtime: AppleContainerRuntime,
        localEnv: [String: String] = ProcessInfo.processInfo.environment
    ) throws {
        let resolved = try ConfigResolver.resolve(
            workspacePath: workspacePath,
            localEnv: localEnv
        )
        guard let info = try runtime.findByName(resolved.containerName) else {
            throw CLIError(
                code: CLIErrorCode.containerNotFound,
                message: "No container for this workspace (expected \(resolved.containerName))",
                hint: "Nothing to delete"
            )
        }
        StatusPrinter.status("Deleting container \(info.id)")
        try runtime.delete(nameOrId: info.id, force: true)
        print("Deleted \(info.id)")
    }
}
