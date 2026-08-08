import Foundation

/// Load a local-path Dev Container feature package into the feature cache destination.
///
/// Resolves `./…`, `../…`, absolute `/…`, and `file://…` refs relative to the workspace root
/// (absolute and file URLs use their own path). Requires a directory containing
/// `devcontainer-feature.json` and `install.sh`.
public enum LocalFeatureLoader {
    /// Resolve `reference` to an absolute filesystem path under `workspacePath` rules.
    public static func resolveSourcePath(reference: String, workspacePath: String) throws -> String {
        let trimmed = reference.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            throw CLIError(
                code: CLIErrorCode.featureFetch,
                property: "features",
                message: "Empty local feature path",
                hint: "Use a relative path (./features/foo), absolute path, or file:// URI"
            )
        }

        if trimmed.hasPrefix("file://") {
            guard let url = URL(string: trimmed), url.isFileURL else {
                throw CLIError(
                    code: CLIErrorCode.featureFetch,
                    property: "features",
                    message: "Invalid file:// feature reference '\(reference)'",
                    hint: "Use a valid file URL pointing at a feature directory"
                )
            }
            return url.standardizedFileURL.path
        }

        if trimmed.hasPrefix("/") {
            return (trimmed as NSString).standardizingPath
        }

        // Relative to workspace root (./…, ../…, or bare relative).
        let joined = (workspacePath as NSString).appendingPathComponent(trimmed)
        return (joined as NSString).standardizingPath
    }

    /// Validate local package layout and copy into `destinationDirectory`.
    public static func load(
        reference: String,
        workspacePath: String,
        destinationDirectory: String,
        fileManager: FileManager = .default
    ) throws -> FetchedFeaturePackage {
        let source = try resolveSourcePath(reference: reference, workspacePath: workspacePath)

        var isDir: ObjCBool = false
        guard fileManager.fileExists(atPath: source, isDirectory: &isDir), isDir.boolValue else {
            throw CLIError(
                code: CLIErrorCode.featureFetch,
                property: "features",
                message: "Local feature '\(reference)' path does not exist or is not a directory: \(source)",
                hint: "Ensure the path is relative to the workspace root and points at a feature package directory"
            )
        }

        let metaPath = (source as NSString).appendingPathComponent("devcontainer-feature.json")
        guard fileManager.fileExists(atPath: metaPath) else {
            throw CLIError(
                code: CLIErrorCode.featureMetadata,
                property: "features",
                message: "Local feature '\(reference)' is missing devcontainer-feature.json at \(source)",
                hint: "Add devcontainer-feature.json at the feature package root"
            )
        }

        let installPath = (source as NSString).appendingPathComponent("install.sh")
        guard fileManager.fileExists(atPath: installPath) else {
            throw CLIError(
                code: CLIErrorCode.featureFetch,
                property: "features",
                message: "Local feature '\(reference)' is missing install.sh at \(source)",
                hint: "Add an install.sh script at the feature package root"
            )
        }

        try fileManager.createDirectory(atPath: destinationDirectory, withIntermediateDirectories: true)
        let contents = try fileManager.contentsOfDirectory(atPath: source)
        for name in contents {
            let from = (source as NSString).appendingPathComponent(name)
            let to = (destinationDirectory as NSString).appendingPathComponent(name)
            if fileManager.fileExists(atPath: to) {
                try fileManager.removeItem(atPath: to)
            }
            try fileManager.copyItem(atPath: from, toPath: to)
        }

        let destInstall = (destinationDirectory as NSString).appendingPathComponent("install.sh")
        try? fileManager.setAttributes([.posixPermissions: 0o755], ofItemAtPath: destInstall)

        return FetchedFeaturePackage(reference: reference, directoryPath: destinationDirectory)
    }
}
