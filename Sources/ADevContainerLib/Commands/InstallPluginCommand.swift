import Foundation

public enum InstallPluginCommand {
    public static func run(
        runtime: AppleContainerRuntime,
        currentExecutablePath: String = CommandLine.arguments.first ?? "",
        runningExecutablePath: String? = Bundle.main.executableURL?.path,
        pathEnvironment: String? = ProcessInfo.processInfo.environment["PATH"],
        fileManager: FileManager = .default
    ) throws {
        let path = runtime.executablePath
        guard runtime.binaryExists(fileManager: fileManager) else {
            throw CLIError(
                code: CLIErrorCode.runtimeMissing,
                message: "Apple container binary not found at \(path)",
                hint: "Install Apple container and ensure it is at /usr/local/bin/container or on PATH"
            )
        }
        let installRoot = ContainerPluginLayout.installRoot(containerBinaryPath: path)
        let source = ContainerPluginLayout.resolveSourceExecutable(
            argv0: currentExecutablePath,
            runningExecutablePath: runningExecutablePath,
            pathEnvironment: pathEnvironment,
            fileManager: fileManager
        )
        try ContainerPluginLayout.stage(
            installRoot: installRoot,
            executablePath: source,
            fileManager: fileManager
        )
    }

    public static func printSuccess() {
        print("\(CommandSurface.commandPrefix) install-plugin: staged Apple CLI plugin 'dev'")
    }
}
