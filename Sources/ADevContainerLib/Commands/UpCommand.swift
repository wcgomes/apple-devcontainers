import Foundation

public struct UpOptions: Sendable {
    public var workspacePath: String
    public var jsonOutput: Bool
    public var recreate: Bool
    public var skipPull: Bool

    public init(
        workspacePath: String,
        jsonOutput: Bool = false,
        recreate: Bool = false,
        skipPull: Bool = false
    ) {
        self.workspacePath = workspacePath
        self.jsonOutput = jsonOutput
        self.recreate = recreate
        self.skipPull = skipPull
    }
}

public enum UpCommand {
    public static func run(
        options: UpOptions,
        runtime: AppleContainerRuntime,
        localEnv: [String: String] = ProcessInfo.processInfo.environment
    ) throws -> UpResult {
        StatusPrinter.status("Resolving configuration")
        let resolved = try ConfigResolver.resolve(
            workspacePath: options.workspacePath,
            localEnv: localEnv
        )
        let request = CreateRequest.from(
            resolved: resolved.config,
            identityName: resolved.containerName,
            labels: resolved.labels,
            configHash: resolved.configHash,
            workspacePath: resolved.workspacePath
        )

        let existing = try runtime.findByName(resolved.containerName)

        if let existing {
            let existingHash = existing.labels[ContainerIdentity.labelConfigHash]
            if let existingHash, existingHash != resolved.configHash {
                if options.recreate {
                    try runtime.delete(nameOrId: existing.id, force: true)
                } else {
                    throw CLIError(
                        code: CLIErrorCode.configHashMismatch,
                        property: ContainerIdentity.labelConfigHash,
                        message: "Existing container config hash does not match current config",
                        hint: "Run 'adevcontainer up --recreate' to delete and recreate, or 'adevcontainer delete' first"
                    )
                }
            } else if options.recreate {
                try runtime.delete(nameOrId: existing.id, force: true)
            } else if existing.isRunning {
                StatusPrinter.status("Reusing running container \(existing.name)")
                StatusPrinter.status("Ready")
                return successResult(id: existing.id, name: existing.name, config: resolved.config)
            } else {
                StatusPrinter.status("Starting container")
                try runtime.start(nameOrId: existing.id)
                // postCreate only on fresh create, not restart
                StatusPrinter.status("Ready")
                return successResult(id: existing.id, name: existing.name, config: resolved.config)
            }
        }

        // Create path (missing or just deleted for recreate)
        if !resolved.mountPromotions.isEmpty {
            fputs(MountNormalizer.warningMessage(promotions: resolved.mountPromotions) + "\n", stderr)
        }
        if !options.skipPull {
            StatusPrinter.status("Pulling image \(request.image)")
            // Best-effort pull; create will also fetch if needed
            try? runtime.pullImage(request.image)
        }

        StatusPrinter.status("Creating container \(resolved.containerName)")
        let id = try runtime.create(request: request)
        StatusPrinter.status("Starting container")
        try runtime.start(nameOrId: id)

        if let postCreate = resolved.config.postCreateCommand {
            StatusPrinter.status("Running postCreateCommand")
            let execResult = try runtime.exec(
                nameOrId: id,
                command: postCreate.execArguments,
                user: resolved.config.effectiveUser,
                workdir: resolved.config.workspaceFolder,
                env: resolved.config.containerEnv
            )
            if !execResult.succeeded {
                // Do not leave a reusable container after a failed create-path postCreate.
                try? runtime.delete(nameOrId: id, force: true)
                let detail = [
                    execResult.stderrString.trimmingCharacters(in: .whitespacesAndNewlines),
                    execResult.stdoutString.trimmingCharacters(in: .whitespacesAndNewlines)
                ].filter { !$0.isEmpty }.joined(separator: " | ")
                throw CLIError(
                    code: CLIErrorCode.postCreateFailed,
                    property: "postCreateCommand",
                    message: "postCreateCommand failed with exit \(execResult.exitCode)"
                        + (detail.isEmpty ? "" : ": \(detail)"),
                    hint: "Fix the postCreateCommand or exec into the container to debug"
                )
            }
        }

        StatusPrinter.status("Ready")
        return successResult(id: id, name: resolved.containerName, config: resolved.config)
    }

    private static func successResult(
        id: String,
        name: String,
        config: ResolvedDevContainerConfig
    ) -> UpResult {
        UpResult(
            outcome: "success",
            containerId: id,
            remoteUser: config.effectiveUser ?? "",
            remoteWorkspaceFolder: config.workspaceFolder,
            containerName: name
        )
    }
}
