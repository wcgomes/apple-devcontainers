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

        // Human table
        if managed.isEmpty {
            return "No managed containers"
        }
        var lines: [String] = []
        let displayNames = managed.map { info in
            RecoveryHelper.isRecoveryHelper(info) ? "\(info.name) [RECOVERY]" : info.name
        }
        let nameWidth = max(4, displayNames.map(\.count).max() ?? 4)
        let stateWidth = max(5, managed.map(\.state.count).max() ?? 5)
        let header =
            pad("NAME", nameWidth)
            + "  " + pad("STATE", stateWidth)
            + "  MODE    GIT_URL"
        lines.append(header)
        for (info, displayName) in zip(managed, displayNames) {
            let mode = info.labels[ContainerIdentity.labelWorkspaceMode] ?? "-"
            let git = info.labels[ContainerIdentity.labelGitURL] ?? ""
            lines.append(
                pad(displayName, nameWidth)
                + "  " + pad(info.state, stateWidth)
                + "  " + pad(mode, 6)
                + "  " + git
            )
        }
        return lines.joined(separator: "\n")
    }

    private static func pad(_ s: String, _ width: Int) -> String {
        if s.count >= width { return s }
        return s + String(repeating: " ", count: width - s.count)
    }
}
