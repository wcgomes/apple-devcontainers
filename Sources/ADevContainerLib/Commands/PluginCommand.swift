import Foundation

public enum PluginCommand {
    public static func run(
        install: Bool,
        uninstall: Bool,
        runtime: AppleContainerRuntime,
        currentExecutablePath: String = CommandLine.arguments.first ?? "",
        runningExecutablePath: String? = Bundle.main.executableURL?.path,
        pathEnvironment: String? = ProcessInfo.processInfo.environment["PATH"],
        fileManager: FileManager = .default
    ) throws {
        guard install != uninstall else {
            throw CLIError(
                code: CLIErrorCode.usage,
                message: "plugin requires exactly one of --install or --uninstall",
                hint: "Usage: adevcontainer plugin --install | adevcontainer plugin --uninstall"
            )
        }
        let path = runtime.executablePath
        guard runtime.binaryExists(fileManager: fileManager) else {
            throw CLIError(
                code: CLIErrorCode.runtimeMissing,
                message: "Apple container binary not found at \(path)",
                hint: "Install Apple container and ensure it is at /usr/local/bin/container or on PATH"
            )
        }
        let installRoot = ContainerPluginLayout.installRoot(containerBinaryPath: path)
        if uninstall {
            try ContainerPluginLayout.uninstall(installRoot: installRoot, fileManager: fileManager)
            return
        }
        let target = try ContainerPluginLayout.requiredSymlinkTarget(
            argv0: currentExecutablePath,
            runningExecutablePath: runningExecutablePath,
            pathEnvironment: pathEnvironment,
            installRoot: installRoot,
            fileManager: fileManager
        )
        try ContainerPluginLayout.installSymlink(
            installRoot: installRoot,
            symlinkTarget: target,
            fileManager: fileManager
        )
    }

    public static func printSuccess(installed: Bool) {
        if installed {
            print("\(CommandSurface.commandPrefix) plugin --install: linked Apple CLI plugin 'dev'")
        } else {
            print("\(CommandSurface.commandPrefix) plugin --uninstall: removed Apple CLI plugin layout entries")
        }
    }
}
