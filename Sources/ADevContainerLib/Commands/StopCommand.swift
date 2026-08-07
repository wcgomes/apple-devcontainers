import Foundation

public enum StopCommand {
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
                hint: "Nothing to stop — run up first"
            )
        }
        if !info.isRunning {
            print("Container \(info.id) already stopped")
            return
        }
        StatusPrinter.status("Stopping container \(info.id)")
        try runtime.stop(nameOrId: info.id)
        print("Stopped \(info.id)")
    }
}
