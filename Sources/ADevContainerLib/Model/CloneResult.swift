import Foundation

/// Machine-readable success payload for `adevcontainer clone`.
public struct CloneResult: Equatable, Sendable, Codable {
    public var outcome: String
    public var containerId: String
    public var remoteUser: String
    public var remoteWorkspaceFolder: String
    public var containerName: String? = nil
    public var gitUrl: String
    public var workspaceVolume: String

    enum CodingKeys: String, CodingKey {
        case outcome, containerId, remoteUser, remoteWorkspaceFolder, gitUrl, workspaceVolume
    }

    public init(
        outcome: String = "success",
        containerId: String,
        remoteUser: String,
        remoteWorkspaceFolder: String,
        containerName: String? = nil,
        gitUrl: String,
        workspaceVolume: String
    ) {
        self.outcome = outcome
        self.containerId = containerId
        self.remoteUser = remoteUser
        self.remoteWorkspaceFolder = remoteWorkspaceFolder
        self.containerName = containerName
        self.gitUrl = gitUrl
        self.workspaceVolume = workspaceVolume
    }

    public func jsonData(pretty: Bool = true) throws -> Data {
        let encoder = JSONEncoder()
        if pretty {
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        }
        return try encoder.encode(self)
    }

    public func jsonString(pretty: Bool = true) throws -> String {
        let data = try jsonData(pretty: pretty)
        guard let s = String(data: data, encoding: .utf8) else {
            throw CLIError(
                code: CLIErrorCode.internalError,
                message: "Failed to encode CloneResult as UTF-8"
            )
        }
        return s
    }
}
