import Foundation

/// Load a local-path Dev Container feature package into the feature cache destination.
///
/// Resolves `./…` / `../…` against the config directory, then `workspace/.devcontainer/`
/// if distinct, then the workspace root (absolute and `file://` use their own path).
/// Requires a directory containing `devcontainer-feature.json` and `install.sh`.
public enum LocalFeatureLoader {
    /// Resolve `reference` to an absolute filesystem path under workspace / config-dir rules.
    public static func resolveSourcePath(
        reference: String,
        workspacePath: String,
        configDirectory: String? = nil,
        fileManager: FileManager = .default
    ) throws -> String {
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

        let candidates = relativeCandidatePaths(
            reference: trimmed,
            workspacePath: workspacePath,
            configDirectory: configDirectory
        )
        if let match = candidates.first(where: { isValidPackage(at: $0, fileManager: fileManager) }) {
            return match
        }
        throw unresolvedRelativeError(
            reference: reference,
            candidates: candidates,
            fileManager: fileManager
        )
    }

    /// Validate local package layout and copy into `destinationDirectory`.
    public static func load(
        reference: String,
        workspacePath: String,
        destinationDirectory: String,
        configDirectory: String? = nil,
        fileManager: FileManager = .default
    ) throws -> FetchedFeaturePackage {
        let source = try resolveSourcePath(
            reference: reference,
            workspacePath: workspacePath,
            configDirectory: configDirectory,
            fileManager: fileManager
        )

        var isDir: ObjCBool = false
        guard fileManager.fileExists(atPath: source, isDirectory: &isDir), isDir.boolValue else {
            throw CLIError(
                code: CLIErrorCode.featureFetch,
                property: "features",
                message: "Local feature '\(reference)' path does not exist or is not a directory: \(source)",
                hint: unresolvedHint
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

    private static let unresolvedHint =
        "Place the package (devcontainer-feature.json and install.sh) relative to the workspace root or the .devcontainer / config directory"

    private static func relativeCandidatePaths(
        reference: String,
        workspacePath: String,
        configDirectory: String?
    ) -> [String] {
        let workspace = (workspacePath as NSString).standardizingPath
        let workspaceDevcontainer = (workspace as NSString).appendingPathComponent(".devcontainer")
        let trimmedConfig = configDirectory?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        let configDir = trimmedConfig.isEmpty
            ? workspaceDevcontainer
            : (trimmedConfig as NSString).standardizingPath

        var bases: [String] = []
        func appendUnique(_ path: String) {
            let standardized = (path as NSString).standardizingPath
            if !bases.contains(standardized) {
                bases.append(standardized)
            }
        }
        appendUnique(configDir)
        appendUnique(workspaceDevcontainer)
        appendUnique(workspace)

        var paths: [String] = []
        for base in bases {
            let joined = (base as NSString).appendingPathComponent(reference)
            let standardized = (joined as NSString).standardizingPath
            if !paths.contains(standardized) {
                paths.append(standardized)
            }
        }
        return paths
    }

    private static func isValidPackage(at path: String, fileManager: FileManager) -> Bool {
        var isDir: ObjCBool = false
        guard fileManager.fileExists(atPath: path, isDirectory: &isDir), isDir.boolValue else {
            return false
        }
        let metaPath = (path as NSString).appendingPathComponent("devcontainer-feature.json")
        let installPath = (path as NSString).appendingPathComponent("install.sh")
        return fileManager.fileExists(atPath: metaPath) && fileManager.fileExists(atPath: installPath)
    }

    private static func unresolvedRelativeError(
        reference: String,
        candidates: [String],
        fileManager: FileManager
    ) -> CLIError {
        for path in candidates {
            var isDir: ObjCBool = false
            guard fileManager.fileExists(atPath: path, isDirectory: &isDir), isDir.boolValue else {
                continue
            }
            let metaPath = (path as NSString).appendingPathComponent("devcontainer-feature.json")
            if !fileManager.fileExists(atPath: metaPath) {
                return CLIError(
                    code: CLIErrorCode.featureMetadata,
                    property: "features",
                    message: "Local feature '\(reference)' is missing devcontainer-feature.json at \(path)",
                    hint: unresolvedHint
                )
            }
            let installPath = (path as NSString).appendingPathComponent("install.sh")
            if !fileManager.fileExists(atPath: installPath) {
                return CLIError(
                    code: CLIErrorCode.featureFetch,
                    property: "features",
                    message: "Local feature '\(reference)' is missing install.sh at \(path)",
                    hint: unresolvedHint
                )
            }
        }
        let listed = candidates.joined(separator: ", ")
        return CLIError(
            code: CLIErrorCode.featureFetch,
            property: "features",
            message: "Local feature '\(reference)' path does not exist or is not a directory"
                + (listed.isEmpty ? "" : ": \(listed)"),
            hint: unresolvedHint
        )
    }
}
