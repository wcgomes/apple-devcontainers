import Foundation

public struct ExecOptions: Sendable {
    /// Managed container name/id (`--name`); nil → single managed / interactive picker.
    public var name: String?
    public var command: [String]
    public var interactive: Bool

    public init(
        command: [String],
        interactive: Bool = false,
        name: String? = nil
    ) {
        self.name = name
        self.command = command
        self.interactive = interactive
    }
}

public enum ExecCommand {
    /// Returns the remote process exit code.
    ///
    /// Selection is managed-only (`ManagedContainers.resolveSelection`). User and workdir
    /// come from labels stamped at `up`/`clone` create.
    @discardableResult
    public static func run(
        options: ExecOptions,
        runtime: AppleContainerRuntime
    ) throws -> Int32 {
        let info = try ManagedContainers.resolveSelection(name: options.name, runtime: runtime)
        let labeledUser = info.labels[ContainerIdentity.labelRemoteUser]
        let user = (labeledUser?.isEmpty == false) ? labeledUser : nil
        let labeledWorkdir = info.labels[ContainerIdentity.labelWorkspaceFolder]
        let workdir = (labeledWorkdir?.isEmpty == false) ? labeledWorkdir : nil

        guard info.isRunning else {
            throw CLIError(
                code: CLIErrorCode.containerNotRunning,
                message: "Container \(info.id) is not running (state: \(info.state))",
                hint: "Run 'adevcontainer start --name \(info.name)' or 'adevcontainer up' to start it"
            )
        }

        // Exec is not attach — probe (unless none) and merge; never run postAttach.
        var env: [String: String] = [:]
        if var loaded = try ConfigReader.read(
            labels: info.labels,
            containerId: info.id,
            runtime: runtime,
            mode: .bestEffort
        ) {
            if let user { loaded.remoteUser = user }
            if let workdir { loaded.workspaceFolder = workdir }
            try LifecycleRunner.applyUserEnvProbe(
                containerId: info.id,
                config: &loaded,
                runtime: runtime
            )
            env = loaded.containerEnv
        }

        let cmd = options.command.isEmpty ? ["bash"] : options.command
        let result = try runtime.exec(
            nameOrId: info.id,
            command: cmd,
            user: user,
            workdir: workdir,
            env: env,
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
