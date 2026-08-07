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
        localEnv: [String: String] = ProcessInfo.processInfo.environment,
        hostResources: any HostResourceProviding = SystemHostResourceInfo()
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

        // hostRequirements: fail up on shortfall/unreadable host; warn gpu; limits applied on create.
        try enforceHostRequirements(config: resolved.config, host: hostResources)

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
                LifecycleRunner.emitPostAttachSkipIfNeeded(config: resolved.config)
                StatusPrinter.status("Ready")
                return successResult(id: existing.id, name: existing.name, config: resolved.config)
            } else {
                StatusPrinter.status("Starting container")
                try runtime.start(nameOrId: existing.id)
                // Restart path: postStart only; do not delete on failure.
                try LifecycleRunner.runRestartPostStart(
                    containerId: existing.id,
                    config: resolved.config,
                    runtime: runtime
                )
                LifecycleRunner.emitPostAttachSkipIfNeeded(config: resolved.config)
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

        // Fresh create: onCreate → updateContent → postCreate → postStart; delete on any failure.
        try LifecycleRunner.runCreatePath(
            containerId: id,
            config: resolved.config,
            runtime: runtime
        )

        LifecycleRunner.emitPostAttachSkipIfNeeded(config: resolved.config)
        StatusPrinter.status("Ready")
        return successResult(id: id, name: resolved.containerName, config: resolved.config)
    }

    private static func enforceHostRequirements(
        config: ResolvedDevContainerConfig,
        host: any HostResourceProviding
    ) throws {
        let evaluation = HostRequirementsEvaluation.evaluate(config.hostRequirements, host: host)
        for warning in evaluation.warnings {
            StatusPrinter.warning(warning)
        }
        guard evaluation.hasHardFailures else { return }
        throw CLIError(
            code: CLIErrorCode.hostRequirements,
            property: "hostRequirements",
            message: evaluation.hardFailures.joined(separator: "; "),
            hint: "Reduce hostRequirements or run on a host with sufficient memory/CPUs"
        )
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
