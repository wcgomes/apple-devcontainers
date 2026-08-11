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
    /// How the container workspace folder is mounted.
    public enum WorkspaceMountMode: String, Sendable, Equatable {
        /// Host directory bind (default for `up`).
        case bind
        /// Named volume (clone / volume-mode).
        case volume
    }

    public var name: String
    public var image: String
    public var labels: [String: String]
    /// Host path (bind mode) or volume name (volume mode).
    public var workspaceBindHost: String
    public var workspaceBindTarget: String
    /// Workspace mount source kind. Default `.bind` preserves `up` behavior.
    public var workspaceMountMode: WorkspaceMountMode
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
    /// OCI platform for multi-arch images (e.g. `linux/arm64`). Never implies `--rosetta`.
    public var platform: String?
    public var configHash: String

    public init(
        name: String,
        image: String,
        labels: [String: String],
        workspaceBindHost: String,
        workspaceBindTarget: String,
        workspaceMountMode: WorkspaceMountMode = .bind,
        env: [String: String] = [:],
        user: String? = nil,
        workdir: String? = nil,
        mounts: [MountSpec] = [],
        publishPorts: [Int] = [],
        portsAttributes: [String: [String: String]] = [:],
        runArgs: [AllowlistedRunArg] = [],
        memoryLimit: String? = nil,
        cpuLimit: String? = nil,
        platform: String? = nil,
        configHash: String
    ) {
        self.name = name
        self.image = image
        self.labels = labels
        self.workspaceBindHost = workspaceBindHost
        self.workspaceBindTarget = workspaceBindTarget
        self.workspaceMountMode = workspaceMountMode
        self.env = env
        self.user = user
        self.workdir = workdir
        self.mounts = mounts
        self.publishPorts = publishPorts
        self.portsAttributes = portsAttributes
        self.runArgs = runArgs
        self.memoryLimit = memoryLimit
        self.cpuLimit = cpuLimit
        self.platform = platform
        self.configHash = configHash
    }

    /// Build `container create` argv (without the executable).
    public func createArguments() -> [String] {
        var args: [String] = ["create", "--name", name]

        for (k, v) in labels.sorted(by: { $0.key < $1.key }) {
            args += ["-l", "\(k)=\(v)"]
        }

        // Workspace mount (host bind or named volume)
        let workspaceType: MountSpec.MountType =
            workspaceMountMode == .volume ? .volume : .bind
        args += ["--mount", MountSpec(
            type: workspaceType,
            source: workspaceBindHost,
            target: workspaceBindTarget,
            readonly: false
        ).mountFlagValue]

        for mount in mounts {
            args += ["--mount", mount.mountFlagValue]
        }

        // Apple container does not expand ${PATH}/$PATH in -e values.
        let expandedEnv = Self.expandEnvPathRefs(env)
        for (k, v) in expandedEnv.sorted(by: { $0.key < $1.key }) {
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

        if let platform, !platform.isEmpty {
            args += ["--platform", platform]
        }

        // Keep container alive for attach/exec.
        // Never pass --rosetta here; user must opt in via runArgs if needed.
        args += ["--entrypoint", "/bin/sleep", image, "infinity"]
        return args
    }

    /// Default Linux PATH used when expanding `${PATH}` / `$PATH` (Apple container does not expand).
    public static let defaultLinuxPath =
        "/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin"

    /// Expand `${PATH}` and bare `$PATH` (word-boundary) in containerEnv values for create `-e`.
    /// PATH self-reference always substitutes `defaultLinuxPath` (not recursive).
    /// Other keys use the expanded PATH from the map when present, else the default.
    public static func expandEnvPathRefs(_ env: [String: String]) -> [String: String] {
        let expandedPath: String
        if let rawPath = env["PATH"] {
            expandedPath = expandPathRefs(in: rawPath, pathReplacement: defaultLinuxPath)
        } else {
            expandedPath = defaultLinuxPath
        }
        var out: [String: String] = [:]
        out.reserveCapacity(env.count)
        for (k, v) in env {
            if k == "PATH" {
                out[k] = expandedPath
            } else {
                out[k] = expandPathRefs(in: v, pathReplacement: expandedPath)
            }
        }
        return out
    }

    private static func expandPathRefs(in value: String, pathReplacement: String) -> String {
        guard value.contains("$") else { return value }
        var result = value.replacingOccurrences(of: "${PATH}", with: pathReplacement)
        result = expandBareDollarPath(in: result, replacement: pathReplacement)
        return result
    }

    /// Replace `$PATH` only when not a longer identifier (`$PATHNAME`, `$PATH_FOO`).
    private static func expandBareDollarPath(in value: String, replacement: String) -> String {
        var out = ""
        out.reserveCapacity(value.utf8.count)
        var i = value.startIndex
        while i < value.endIndex {
            if value[i] == "$" {
                let afterDollar = value.index(after: i)
                if value[afterDollar...].hasPrefix("PATH") {
                    let afterPath = value.index(afterDollar, offsetBy: 4)
                    let boundaryOK =
                        afterPath == value.endIndex
                        || !isEnvIdentContinuation(value[afterPath])
                    if boundaryOK {
                        out.append(contentsOf: replacement)
                        i = afterPath
                        continue
                    }
                }
            }
            out.append(value[i])
            i = value.index(after: i)
        }
        return out
    }

    private static func isEnvIdentContinuation(_ c: Character) -> Bool {
        c.isLetter || c.isNumber || c == "_"
    }

    public static func from(
        resolved: ResolvedDevContainerConfig,
        identityName: String,
        labels: [String: String],
        configHash: String,
        workspacePath: String,
        platform: String? = ContainerPlatform.defaultLinuxPlatform
    ) -> CreateRequest {
        let expanded = VariableSubstitutor.expandDevcontainerId(in: resolved, id: identityName)
        let (memoryLimit, cpuLimit) = mergeMemoryCpuLimits(from: expanded)
        return CreateRequest(
            name: identityName,
            image: expanded.image,
            labels: labelsWithExpandedConfigVolumes(labels, mounts: expanded.mounts),
            workspaceBindHost: (workspacePath as NSString).standardizingPath,
            workspaceBindTarget: expanded.workspaceFolder,
            workspaceMountMode: .bind,
            env: expanded.containerEnv,
            user: expanded.effectiveUser,
            workdir: expanded.workspaceFolder,
            mounts: expanded.mounts,
            publishPorts: expanded.forwardPorts,
            portsAttributes: expanded.portsAttributes,
            runArgs: expanded.runArgs,
            memoryLimit: memoryLimit,
            cpuLimit: cpuLimit,
            platform: platform,
            configHash: configHash
        )
    }

    /// Volume-mode create: workspace is a named volume (clone), not a host bind.
    ///
    /// - Parameter enableSSHForward: When true, ensures `AllowlistedRunArg.ssh` is present
    ///   so Apple `container create --ssh` forwards the host agent (SSH after create git).
    public static func fromVolumeMode(
        resolved: ResolvedDevContainerConfig,
        identityName: String,
        labels: [String: String],
        configHash: String,
        workspaceVolumeName: String,
        platform: String? = ContainerPlatform.defaultLinuxPlatform,
        enableSSHForward: Bool = false
    ) -> CreateRequest {
        let expanded = VariableSubstitutor.expandDevcontainerId(in: resolved, id: identityName)
        let (memoryLimit, cpuLimit) = mergeMemoryCpuLimits(from: expanded)
        var runArgs = expanded.runArgs
        if enableSSHForward, !runArgs.contains(.ssh) {
            runArgs.append(.ssh)
        }
        return CreateRequest(
            name: identityName,
            image: expanded.image,
            labels: labelsWithExpandedConfigVolumes(labels, mounts: expanded.mounts),
            workspaceBindHost: workspaceVolumeName,
            workspaceBindTarget: expanded.workspaceFolder,
            workspaceMountMode: .volume,
            env: expanded.containerEnv,
            user: expanded.effectiveUser,
            workdir: expanded.workspaceFolder,
            mounts: expanded.mounts,
            publishPorts: expanded.forwardPorts,
            portsAttributes: expanded.portsAttributes,
            runArgs: runArgs,
            memoryLimit: memoryLimit,
            cpuLimit: cpuLimit,
            platform: platform,
            configHash: configHash
        )
    }

    /// Stamp `devcontainer.config_volumes` from post-substitution volume mount sources.
    private static func labelsWithExpandedConfigVolumes(
        _ labels: [String: String],
        mounts: [MountSpec]
    ) -> [String: String] {
        var out = labels
        let volNames = mounts.filter { $0.type == .volume }.map(\.source)
        if volNames.isEmpty {
            out.removeValue(forKey: ContainerIdentity.labelConfigVolumes)
        } else {
            out[ContainerIdentity.labelConfigVolumes] = volNames.joined(separator: ",")
        }
        return out
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
