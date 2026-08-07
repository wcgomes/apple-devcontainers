import Foundation

public struct MountSpec: Equatable, Sendable {
    public enum MountType: String, Sendable {
        case bind
        case volume
    }

    public var type: MountType
    public var source: String
    public var target: String
    public var readonly: Bool

    public init(type: MountType, source: String, target: String, readonly: Bool = false) {
        self.type = type
        self.source = source
        self.target = target
        self.readonly = readonly
    }

    /// Apple container `--mount` value.
    public var mountFlagValue: String {
        var parts = [
            "type=\(type.rawValue)",
            "source=\(source)",
            "target=\(target)"
        ]
        if readonly {
            parts.append("readonly")
        }
        return parts.joined(separator: ",")
    }
}

public struct CreateRequest: Equatable, Sendable {
    public var name: String
    public var image: String
    public var labels: [String: String]
    public var workspaceBindHost: String
    public var workspaceBindTarget: String
    public var env: [String: String]
    public var user: String?
    public var workdir: String?
    public var mounts: [MountSpec]
    public var publishPorts: [Int]
    public var portsAttributes: [String: [String: String]]
    public var runArgs: [AllowlistedRunArg]
    /// Apple `container create -m` value when hostRequirements.memory is set.
    public var memoryLimit: String?
    /// Apple `container create -c` value when hostRequirements.cpus is set.
    public var cpuLimit: String?
    public var configHash: String

    public init(
        name: String,
        image: String,
        labels: [String: String],
        workspaceBindHost: String,
        workspaceBindTarget: String,
        env: [String: String] = [:],
        user: String? = nil,
        workdir: String? = nil,
        mounts: [MountSpec] = [],
        publishPorts: [Int] = [],
        portsAttributes: [String: [String: String]] = [:],
        runArgs: [AllowlistedRunArg] = [],
        memoryLimit: String? = nil,
        cpuLimit: String? = nil,
        configHash: String
    ) {
        self.name = name
        self.image = image
        self.labels = labels
        self.workspaceBindHost = workspaceBindHost
        self.workspaceBindTarget = workspaceBindTarget
        self.env = env
        self.user = user
        self.workdir = workdir
        self.mounts = mounts
        self.publishPorts = publishPorts
        self.portsAttributes = portsAttributes
        self.runArgs = runArgs
        self.memoryLimit = memoryLimit
        self.cpuLimit = cpuLimit
        self.configHash = configHash
    }

    /// Build `container create` argv (without the executable).
    public func createArguments() -> [String] {
        var args: [String] = ["create", "--name", name]

        for (k, v) in labels.sorted(by: { $0.key < $1.key }) {
            args += ["-l", "\(k)=\(v)"]
        }

        // Workspace bind
        args += ["--mount", MountSpec(
            type: .bind,
            source: workspaceBindHost,
            target: workspaceBindTarget,
            readonly: false
        ).mountFlagValue]

        for mount in mounts {
            args += ["--mount", mount.mountFlagValue]
        }

        for (k, v) in env.sorted(by: { $0.key < $1.key }) {
            args += ["-e", "\(k)=\(v)"]
        }

        if let user, !user.isEmpty {
            args += ["-u", user]
        }

        if let workdir, !workdir.isEmpty {
            args += ["-w", workdir]
        }

        for port in publishPorts.sorted() {
            // host-port:container-port
            args += ["-p", "\(port):\(port)"]
        }

        // Allowlisted runArgs (no blind passthrough).
        for runArg in runArgs {
            args += runArg.createTokens
        }

        if let memoryLimit {
            args += ["-m", memoryLimit]
        }
        if let cpuLimit {
            args += ["-c", cpuLimit]
        }

        // Keep container alive for attach/exec.
        args += ["--entrypoint", "sleep", image, "infinity"]
        return args
    }

    public static func from(
        resolved: ResolvedDevContainerConfig,
        identityName: String,
        labels: [String: String],
        configHash: String,
        workspacePath: String
    ) -> CreateRequest {
        let (memoryLimit, cpuLimit) = mergeMemoryCpuLimits(from: resolved)
        return CreateRequest(
            name: identityName,
            image: resolved.image,
            labels: labels,
            workspaceBindHost: (workspacePath as NSString).standardizingPath,
            workspaceBindTarget: resolved.workspaceFolder,
            env: resolved.containerEnv,
            user: resolved.effectiveUser,
            workdir: resolved.workspaceFolder,
            mounts: resolved.mounts,
            publishPorts: resolved.forwardPorts,
            portsAttributes: resolved.portsAttributes,
            runArgs: resolved.runArgs,
            memoryLimit: memoryLimit,
            cpuLimit: cpuLimit,
            configHash: configHash
        )
    }

    /// hostRequirements wins when set; otherwise apply runArgs `--memory`/`--cpus`.
    private static func mergeMemoryCpuLimits(
        from resolved: ResolvedDevContainerConfig
    ) -> (memory: String?, cpus: String?) {
        var memoryLimit = resolved.hostRequirements?.memoryCreateFlagValue
        var cpuLimit = resolved.hostRequirements?.cpuCreateFlagValue

        var runArgsMemory: String?
        var runArgsCpus: String?
        for arg in resolved.runArgs {
            switch arg {
            case .memory(let raw):
                if runArgsMemory == nil {
                    runArgsMemory = normalizeRunArgsMemory(raw)
                }
            case .cpus(let raw):
                if runArgsCpus == nil {
                    runArgsCpus = normalizeRunArgsCpus(raw)
                }
            default:
                break
            }
        }

        if let runArgsMemory {
            if memoryLimit != nil {
                StatusPrinter.warning(
                    "runArgs --memory ignored; hostRequirements.memory wins"
                )
            } else {
                memoryLimit = runArgsMemory
            }
        }
        if let runArgsCpus {
            if cpuLimit != nil {
                StatusPrinter.warning(
                    "runArgs --cpus ignored; hostRequirements.cpus wins"
                )
            } else {
                cpuLimit = runArgsCpus
            }
        }

        return (memoryLimit, cpuLimit)
    }

    /// Normalize runArgs memory size to Apple `-m` form when parseable; else pass through.
    private static func normalizeRunArgsMemory(_ raw: String) -> String {
        if let bytes = HostRequirements.parseMemoryBytes(raw) {
            let hr = HostRequirements(memoryBytes: bytes, memoryRaw: raw)
            return hr.memoryCreateFlagValue ?? raw
        }
        return raw
    }

    private static func normalizeRunArgsCpus(_ raw: String) -> String {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        if let d = Double(trimmed), d > 0, d.isFinite {
            if d == floor(d), d <= Double(Int.max) {
                return "\(Int(d))"
            }
            return String(d)
        }
        return trimmed
    }
}
