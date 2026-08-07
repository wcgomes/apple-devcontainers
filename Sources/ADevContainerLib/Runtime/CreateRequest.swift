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
        CreateRequest(
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
            configHash: configHash
        )
    }
}
