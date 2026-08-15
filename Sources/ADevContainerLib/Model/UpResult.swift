import Foundation

/// Machine-readable success payload for `adevcontainer up`.
public struct UpResult: Equatable, Sendable, Codable {
    public var outcome: String
    public var containerId: String
    public var remoteUser: String
    public var remoteWorkspaceFolder: String
    public var containerName: String? = nil

    enum CodingKeys: String, CodingKey {
        case outcome, containerId, remoteUser, remoteWorkspaceFolder
    }

    public init(
        outcome: String = "success",
        containerId: String,
        remoteUser: String,
        remoteWorkspaceFolder: String,
        containerName: String? = nil
    ) {
        self.outcome = outcome
        self.containerId = containerId
        self.remoteUser = remoteUser
        self.remoteWorkspaceFolder = remoteWorkspaceFolder
        self.containerName = containerName
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
                message: "Failed to encode UpResult as UTF-8"
            )
        }
        return s
    }
}
