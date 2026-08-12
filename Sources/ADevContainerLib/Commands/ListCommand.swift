import Foundation

public struct ListOptions: Sendable {
    public var jsonOutput: Bool

    public init(jsonOutput: Bool = false) {
        self.jsonOutput = jsonOutput
    }
}

public enum ListCommand {
    public static func run(
        options: ListOptions,
        runtime: AppleContainerRuntime
    ) throws -> String {
        let managed = try ManagedContainers.list(runtime: runtime)

        if options.jsonOutput {
            let rows: [[String: Any]] = managed.map { info in
                var row: [String: Any] = [
                    "id": info.id,
                    "name": info.name,
                    "state": info.state,
                    "labels": info.labels
                ]
                if let image = info.image {
                    row["image"] = image
                }
                if let git = info.labels[ContainerIdentity.labelGitURL] {
                    row["gitUrl"] = git
                }
                if let mode = info.labels[ContainerIdentity.labelWorkspaceMode] {
                    row["workspaceMode"] = mode
                }
                if let vol = info.labels[ContainerIdentity.labelWorkspaceVolume] {
                    row["workspaceVolume"] = vol
                }
                return row
            }
            let data = try JSONSerialization.data(
                withJSONObject: rows,
                options: [.prettyPrinted, .sortedKeys]
            )
            guard let s = String(data: data, encoding: .utf8) else {
                throw CLIError(
                    code: CLIErrorCode.internalError,
                    message: "Failed to encode list JSON"
                )
            }
            return s
        }

        // Human table (shared layout with InteractivePicker).
        if managed.isEmpty {
            return "No managed containers"
        }
        let widths = ManagedContainerTable.Widths(containers: managed)
        var lines: [String] = [ManagedContainerTable.header(widths: widths)]
        for info in managed {
            lines.append(ManagedContainerTable.row(info: info, widths: widths))
        }
        return lines.joined(separator: "\n")
    }
}
