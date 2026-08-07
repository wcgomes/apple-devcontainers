import Foundation

public struct InspectPayload: Sendable {
    public var containerId: String
    public var containerName: String
    public var state: String
    public var image: String?
    public var remoteUser: String
    public var remoteWorkspaceFolder: String
    public var labels: [String: String]
    public var portsAttributes: [String: [String: String]]
    public var configPath: String
    public var workspacePath: String
    public var configHash: String

    public func jsonObject() -> [String: Any] {
        [
            "containerId": containerId,
            "containerName": containerName,
            "state": state,
            "image": image as Any,
            "remoteUser": remoteUser,
            "remoteWorkspaceFolder": remoteWorkspaceFolder,
            "labels": labels,
            "portsAttributes": portsAttributes,
            "configPath": configPath,
            "workspacePath": workspacePath,
            "configHash": configHash
        ]
    }

    public func jsonString() throws -> String {
        let data = try JSONSerialization.data(
            withJSONObject: jsonObject(),
            options: [.prettyPrinted, .sortedKeys]
        )
        guard let s = String(data: data, encoding: .utf8) else {
            throw CLIError(code: CLIErrorCode.internalError, message: "Failed to encode inspect JSON")
        }
        return s
    }
}

public enum InspectCommand {
    public static func run(
        workspacePath: String,
        runtime: AppleContainerRuntime,
        localEnv: [String: String] = ProcessInfo.processInfo.environment
    ) throws -> InspectPayload {
        let resolved = try ConfigResolver.resolve(
            workspacePath: workspacePath,
            localEnv: localEnv
        )
        guard let info = try runtime.findByName(resolved.containerName) else {
            throw CLIError(
                code: CLIErrorCode.containerNotFound,
                message: "No container for this workspace (expected \(resolved.containerName))",
                hint: "Run 'adevcontainer up' first"
            )
        }

        // Prefer live inspect for freshest state
        let live = (try? runtime.inspect(nameOrId: info.id)) ?? info

        return InspectPayload(
            containerId: live.id,
            containerName: live.name,
            state: live.state,
            image: live.image,
            remoteUser: resolved.config.effectiveUser ?? "",
            remoteWorkspaceFolder: resolved.config.workspaceFolder,
            labels: live.labels,
            portsAttributes: resolved.config.portsAttributes,
            configPath: resolved.configPath,
            workspacePath: resolved.workspacePath,
            configHash: resolved.configHash
        )
    }
}
