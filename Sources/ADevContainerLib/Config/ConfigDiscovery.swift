import Foundation

public struct ConfigDiscovery {
    public static let nestedRelativePath = ".devcontainer/devcontainer.json"
    public static let rootRelativePath = ".devcontainer.json"

    /// Search order: `.devcontainer/devcontainer.json` then `.devcontainer.json`.
    public static func discover(workspacePath: String, fileManager: FileManager = .default) throws -> String {
        let root = (workspacePath as NSString).standardizingPath
        let nested = (root as NSString).appendingPathComponent(nestedRelativePath)
        let fallback = (root as NSString).appendingPathComponent(rootRelativePath)

        var isDir: ObjCBool = false
        if fileManager.fileExists(atPath: nested, isDirectory: &isDir), !isDir.boolValue {
            return nested
        }
        if fileManager.fileExists(atPath: fallback, isDirectory: &isDir), !isDir.boolValue {
            return fallback
        }

        throw CLIError(
            code: CLIErrorCode.configNotFound,
            message: "No devcontainer.json found in workspace",
            hint: "Looked for \(nested) and \(fallback)"
        )
    }

    public static let candidateRelativePaths = [nestedRelativePath, rootRelativePath]
}
