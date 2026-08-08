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
    /// Inspect a managed container via `--name` / picker.
    ///
    /// Identity fields come from runtime + labels stamped at create (no ConfigResolver).
    /// `portsAttributes` is empty in v1 (not stored on labels).
    public static func run(
        name: String? = nil,
        runtime: AppleContainerRuntime,
        picker: InteractivePicker = .default
    ) throws -> InspectPayload {
        let info = try ManagedContainers.resolveSelection(
            name: name,
            runtime: runtime,
            picker: picker
        )

        // Prefer live inspect for freshest state
        let live = (try? runtime.inspect(nameOrId: info.id)) ?? info
        let labels = live.labels

        return InspectPayload(
            containerId: live.id,
            containerName: live.name,
            state: live.state,
            image: live.image,
            remoteUser: labels[ContainerIdentity.labelRemoteUser] ?? "",
            remoteWorkspaceFolder: labels[ContainerIdentity.labelWorkspaceFolder] ?? "",
            labels: labels,
            portsAttributes: [:],
            configPath: labels[ContainerIdentity.labelConfigFile] ?? "",
            workspacePath: labels[ContainerIdentity.labelLocalFolder] ?? "",
            configHash: labels[ContainerIdentity.labelConfigHash] ?? ""
        )
    }
}
