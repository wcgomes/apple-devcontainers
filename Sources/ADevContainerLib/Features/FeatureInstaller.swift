import Foundation

/// One feature ready for in-container install (`cp` package + `exec install.sh` as root).
public struct FeatureInstallStep: Equatable, Sendable {
    public var reference: String
    /// Host path to extracted feature package root (metadata + install.sh).
    public var packageDirectory: String
    /// Environment for install.sh (options + `_REMOTE_USER` / `_CONTAINER_USER` …).
    public var installEnv: [String: String]
    /// Safe directory name under `/tmp/adev-features/` inside the container.
    public var safeName: String

    public init(
        reference: String,
        packageDirectory: String,
        installEnv: [String: String],
        safeName: String
    ) {
        self.reference = reference
        self.packageDirectory = packageDirectory
        self.installEnv = installEnv
        self.safeName = safeName
    }

    /// Destination path inside the container for this feature package.
    public var containerPackagePath: String {
        "/tmp/adev-features/\(safeName)"
    }
}

/// Optional helper: install OCI features into a **running** container via `cp` + `exec` as root.
///
/// The Features **up** path uses Dockerfile + `container build` instead (see FeaturesRunner).
/// Retained for experiments and unit coverage of cp/exec install mechanics.
public enum FeatureInstaller {
    public static let containerFeaturesRoot = "/tmp/adev-features"

    /// Install each step in order. Fail-fast with structured error (caller deletes container).
    public static func install(
        into containerId: String,
        plan: [FeatureInstallStep],
        runtime: AppleContainerRuntime
    ) throws {
        guard !plan.isEmpty else { return }

        // Ensure parent install root exists (root).
        try ensureRemoteDirectory(
            containerId: containerId,
            path: containerFeaturesRoot,
            runtime: runtime
        )

        for step in plan {
            StatusPrinter.status("Installing feature", item: step.reference)
            try installOne(into: containerId, step: step, runtime: runtime)
        }
    }

    private static func installOne(
        into containerId: String,
        step: FeatureInstallStep,
        runtime: AppleContainerRuntime
    ) throws {
        let fm = FileManager.default
        let installHost = (step.packageDirectory as NSString).appendingPathComponent("install.sh")
        guard fm.fileExists(atPath: installHost) else {
            throw CLIError(
                code: CLIErrorCode.featureMetadata,
                property: "features",
                message: "Feature '\(step.reference)' package is missing install.sh",
                hint: "Each feature artifact must include install.sh"
            )
        }

        let remoteDir = step.containerPackagePath
        // Copy package directory into the container (contents land under remoteDir).
        // `container cp localDir id:remoteDir` — ensure remote parent exists first.
        try ensureRemoteDirectory(
            containerId: containerId,
            path: containerFeaturesRoot,
            runtime: runtime
        )

        do {
            try runtime.copy(
                from: step.packageDirectory,
                to: "\(containerId):\(remoteDir)"
            )
        } catch let err as CLIError {
            throw CLIError(
                code: CLIErrorCode.featureInstall,
                property: "features",
                message: "Failed to copy feature '\(step.reference)' into container: \(err.message)",
                hint: "Check Apple container cp support and feature cache permissions"
            )
        } catch {
            throw CLIError(
                code: CLIErrorCode.featureInstall,
                property: "features",
                message: "Failed to copy feature '\(step.reference)' into container: \(error.localizedDescription)",
                hint: "Check Apple container cp support and feature cache permissions"
            )
        }

        // exec as root with option env; run install.sh from package directory.
        let result: ProcessResult
        do {
            result = try runtime.exec(
                nameOrId: containerId,
                command: ["bash", "\(remoteDir)/install.sh"],
                user: "root",
                workdir: remoteDir,
                env: step.installEnv,
                interactive: false
            )
        } catch {
            throw CLIError(
                code: CLIErrorCode.featureInstall,
                property: "features",
                message: "Feature '\(step.reference)' install exec failed: \(error.localizedDescription)",
                hint: "Inspect install.sh and container logs for this feature"
            )
        }

        if !result.succeeded {
            let err = result.stderrString.trimmingCharacters(in: .whitespacesAndNewlines)
            let out = result.stdoutString.trimmingCharacters(in: .whitespacesAndNewlines)
            let detail = [err, out].filter { !$0.isEmpty }.joined(separator: " | ")
            throw CLIError(
                code: CLIErrorCode.featureInstall,
                property: "features",
                message: "Feature '\(step.reference)' install.sh failed (exit \(result.exitCode))"
                    + (detail.isEmpty ? "" : ": \(detail)"),
                hint: "Fix the feature options or base image packages required by this feature"
            )
        }
    }

    private static func ensureRemoteDirectory(
        containerId: String,
        path: String,
        runtime: AppleContainerRuntime
    ) throws {
        let result = try runtime.exec(
            nameOrId: containerId,
            command: ["mkdir", "-p", path],
            user: "root",
            interactive: false
        )
        if !result.succeeded {
            let detail = result.stderrString.trimmingCharacters(in: .whitespacesAndNewlines)
            throw CLIError(
                code: CLIErrorCode.featureInstall,
                property: "features",
                message: "Could not create \(path) in container"
                    + (detail.isEmpty ? "" : ": \(detail)"),
                hint: "Container must be running and allow root exec"
            )
        }
    }

    /// Filesystem-safe short name from a feature reference (for /tmp paths).
    public static func safeName(for reference: String, index: Int) -> String {
        let base = reference
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: ":", with: "_")
            .replacingOccurrences(of: "@", with: "_")
        let filtered = base.unicodeScalars.map { scalar -> Character in
            if CharacterSet.alphanumerics.contains(scalar) || scalar == "_" || scalar == "-" || scalar == "." {
                return Character(scalar)
            }
            return "_"
        }
        var name = String(filtered)
        while name.contains("__") {
            name = name.replacingOccurrences(of: "__", with: "_")
        }
        if name.count > 48 {
            name = String(name.prefix(48))
        }
        if name.isEmpty {
            name = "feature"
        }
        return "\(index)-\(name)"
    }
}
