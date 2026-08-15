import Foundation

/// Options for `adevcontainer rebuild`.
public struct RebuildOptions: Equatable, Sendable {
    /// Managed container name/id (nil → auto-single or picker).
    public var name: String?
    public var skipPull: Bool
    /// Best-effort open of VS Code on the remote workspace after lifecycle success.
    public var openVSCode: Bool
    public var jsonOutput: Bool

    public init(
        name: String? = nil,
        skipPull: Bool = false,
        openVSCode: Bool = false,
        jsonOutput: Bool = false
    ) {
        self.name = name
        self.skipPull = skipPull
        self.openVSCode = openVSCode
        self.jsonOutput = jsonOutput
    }
}

public extension ParsedArgs {
    /// Flag mapping used by the `rebuild` dispatch case (tested via this factory).
    func rebuildOptions() -> RebuildOptions {
        RebuildOptions(
            name: name,
            skipPull: flags.contains("skip-pull"),
            openVSCode: flags.contains("vscode"),
            jsonOutput: flags.contains("json")
        )
    }
}

/// Success result of `adevcontainer rebuild` (up-shape; volume mode may add gitUrl/workspaceVolume).
public struct RebuildResult: Sendable {
    public var outcome: String
    public var containerId: String
    public var remoteUser: String
    public var remoteWorkspaceFolder: String
    public var containerName: String?
    /// Volume mode only: stamped git URL and workspace volume name (nil for bind).
    public var gitUrl: String?
    public var workspaceVolume: String?

    public init(
        outcome: String,
        containerId: String,
        remoteUser: String,
        remoteWorkspaceFolder: String,
        containerName: String? = nil,
        gitUrl: String? = nil,
        workspaceVolume: String? = nil
    ) {
        self.outcome = outcome
        self.containerId = containerId
        self.remoteUser = remoteUser
        self.remoteWorkspaceFolder = remoteWorkspaceFolder
        self.containerName = containerName
        self.gitUrl = gitUrl
        self.workspaceVolume = workspaceVolume
    }

    public func jsonObject() -> [String: Any] {
        var obj: [String: Any] = [
            "outcome": outcome,
            "containerId": containerId,
            "remoteUser": remoteUser,
            "remoteWorkspaceFolder": remoteWorkspaceFolder
        ]
        if let gitUrl { obj["gitUrl"] = gitUrl }
        if let workspaceVolume { obj["workspaceVolume"] = workspaceVolume }
        return obj
    }

    public func jsonString() throws -> String {
        let data = try JSONSerialization.data(
            withJSONObject: jsonObject(),
            options: [.prettyPrinted, .sortedKeys]
        )
        guard let s = String(data: data, encoding: .utf8) else {
            throw CLIError(code: CLIErrorCode.internalError, message: "Failed to encode rebuild JSON")
        }
        return s
    }
}