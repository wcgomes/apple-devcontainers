import Foundation

public struct ExecOptions: Sendable {
    public var workspacePath: String
    public var command: [String]
    public var interactive: Bool

    public init(workspacePath: String, command: [String], interactive: Bool = false) {
        self.workspacePath = workspacePath
        self.command = command
        self.interactive = interactive
    }
}

public enum ExecCommand {
    /// Returns the remote process exit code.
    @discardableResult
    public static func run(
        options: ExecOptions,
        runtime: AppleContainerRuntime,
        localEnv: [String: String] = ProcessInfo.processInfo.environment
    ) throws -> Int32 {
        let resolved = try ConfigResolver.resolve(
            workspacePath: options.workspacePath,
            localEnv: localEnv
        )

        guard let info = try runtime.findByName(resolved.containerName) else {
            throw CLIError(
                code: CLIErrorCode.containerNotFound,
                message: "No container for this workspace (expected \(resolved.containerName))",
                hint: "Run 'adevcontainer up' first"
            )
        }
        guard info.isRunning else {
            throw CLIError(
                code: CLIErrorCode.containerNotRunning,
                message: "Container \(info.id) is not running (state: \(info.state))",
                hint: "Run 'adevcontainer up' to start it"
            )
        }

        let cmd = options.command.isEmpty ? ["bash"] : options.command
        let result = try runtime.exec(
            nameOrId: info.id,
            command: cmd,
            user: resolved.config.effectiveUser,
            workdir: resolved.config.workspaceFolder,
            env: resolved.config.containerEnv,
            interactive: options.interactive
        )

        // Interactive sessions inherit stdio; only surface captured I/O.
        if !options.interactive {
            let out = result.stdoutString
            let err = result.stderrString
            if !out.isEmpty {
                FileHandle.standardOutput.write(Data(out.utf8))
            }
            if !err.isEmpty {
                FileHandle.standardError.write(Data(err.utf8))
            }
        }

        return result.exitCode
    }
}
