import Foundation

public struct DoctorReport: Equatable, Sendable {
    public var ok: Bool
    public var binaryPath: String
    public var version: String?
    public var status: String?
    public var messages: [String]

    public init(ok: Bool, binaryPath: String, version: String?, status: String?, messages: [String]) {
        self.ok = ok
        self.binaryPath = binaryPath
        self.version = version
        self.status = status
        self.messages = messages
    }
}

/// Apple CLI plugin `dev` layout under the parent of Apple `container`'s `bin/`.
public enum ContainerPluginLayout {
    public static let pluginName = "dev"
    public static let relativeDirectory = "libexec/container-plugins/dev"
    public static let configTOML = """
    abstract = "Native Swift CLI for devcontainer.json on Apple container"
    """

    public static func installRoot(containerBinaryPath: String) -> String {
        URL(fileURLWithPath: containerBinaryPath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .path
    }

    public static func pluginDirectory(installRoot: String) -> String {
        URL(fileURLWithPath: installRoot)
            .appendingPathComponent("libexec/container-plugins/dev")
            .path
    }

    public static func configPath(installRoot: String) -> String {
        URL(fileURLWithPath: pluginDirectory(installRoot: installRoot))
            .appendingPathComponent("config.toml")
            .path
    }

    public static func binaryPath(installRoot: String) -> String {
        URL(fileURLWithPath: pluginDirectory(installRoot: installRoot))
            .appendingPathComponent("bin/dev")
            .path
    }

    public static func isPresent(installRoot: String, fileManager: FileManager = .default) -> Bool {
        fileManager.fileExists(atPath: configPath(installRoot: installRoot))
            && fileManager.isExecutableFile(atPath: binaryPath(installRoot: installRoot))
    }

    public static func requiresElevation(installRoot: String, fileManager: FileManager = .default) -> Bool {
        var path = binaryPath(installRoot: installRoot)
        path = (path as NSString).deletingLastPathComponent
        while true {
            if fileManager.fileExists(atPath: path) {
                return !fileManager.isWritableFile(atPath: path)
            }
            let parent = (path as NSString).deletingLastPathComponent
            if parent == path || parent.isEmpty { return true }
            path = parent
        }
    }

    /// Prefer the running Mach-O over a relative argv[0] basename (e.g. `sudo adevcontainer`).
    public static func resolveSourceExecutable(
        argv0: String,
        runningExecutablePath: String? = Bundle.main.executableURL?.path,
        pathEnvironment: String? = ProcessInfo.processInfo.environment["PATH"],
        fileManager: FileManager = .default
    ) -> String {
        func resolvedExisting(_ path: String) -> String? {
            guard !path.isEmpty, fileManager.fileExists(atPath: path) else { return nil }
            return URL(fileURLWithPath: path).resolvingSymlinksInPath().path
        }

        let isBareName = argv0.isEmpty || !argv0.contains("/")
        if !isBareName {
            let standardized = URL(fileURLWithPath: argv0).standardizedFileURL.path
            return resolvedExisting(standardized) ?? standardized
        }

        if let running = runningExecutablePath, let resolved = resolvedExisting(running) {
            return resolved
        }
        if let pathEnvironment {
            for entry in pathEnvironment.split(separator: ":", omittingEmptySubsequences: false) {
                let directory = String(entry)
                guard directory.hasPrefix("/") else { continue }
                let candidate = (directory as NSString).appendingPathComponent(argv0)
                if let resolved = resolvedExisting(candidate) {
                    return resolved
                }
            }
        }
        if let running = runningExecutablePath, !running.isEmpty {
            return running
        }
        return argv0
    }

    public static func stage(
        installRoot: String,
        executablePath: String,
        fileManager: FileManager = .default
    ) throws {
        let dir = pluginDirectory(installRoot: installRoot)
        let destBinary = binaryPath(installRoot: installRoot)
        let destConfig = configPath(installRoot: installRoot)
        let binDir = (destBinary as NSString).deletingLastPathComponent
        let sourcePath = URL(fileURLWithPath: executablePath).resolvingSymlinksInPath().path
        let sourceExists = fileManager.fileExists(atPath: executablePath)
            || fileManager.fileExists(atPath: sourcePath)
        guard sourceExists else {
            throw CLIError(
                code: CLIErrorCode.runtimeFailed,
                message: "Could not restage Apple CLI plugin: source executable not found at \(executablePath)",
                hint: "Reinstall adevcontainer onto PATH or retry using the full path to the binary"
            )
        }
        do {
            try fileManager.createDirectory(atPath: binDir, withIntermediateDirectories: true)
            let destPath = URL(fileURLWithPath: destBinary).resolvingSymlinksInPath().path
            if sourcePath != destPath {
                if fileManager.fileExists(atPath: destBinary) {
                    try fileManager.removeItem(atPath: destBinary)
                }
                try fileManager.copyItem(atPath: sourcePath, toPath: destBinary)
            }
            try fileManager.setAttributes([.posixPermissions: 0o755], ofItemAtPath: destBinary)
            try configTOML.write(toFile: destConfig, atomically: true, encoding: .utf8)
        } catch {
            throw CLIError(
                code: CLIErrorCode.runtimeFailed,
                message: "Could not write Apple CLI plugin layout at \(dir): \(error.localizedDescription)",
                hint: restageHint(installRoot: installRoot, fileManager: fileManager)
            )
        }
    }

    public static func missingPluginError(installRoot: String, fileManager: FileManager = .default) -> CLIError {
        CLIError(
            code: CLIErrorCode.runtimeFailed,
            message: "Apple CLI plugin 'dev' is not installed at \(pluginDirectory(installRoot: installRoot))",
            hint: restageHint(installRoot: installRoot, fileManager: fileManager)
        )
    }

    static func restageHint(installRoot: String, fileManager: FileManager) -> String {
        requiresElevation(installRoot: installRoot, fileManager: fileManager)
            ? "Run 'sudo adevcontainer install-plugin' to restage the plugin (destination requires elevated privileges)"
            : "Run 'adevcontainer install-plugin' to restage the plugin"
    }
}

public enum DoctorCommand {
    public static func run(
        runtime: AppleContainerRuntime,
        fileManager: FileManager = .default
    ) throws -> DoctorReport {
        var messages: [String] = []
        let path = runtime.executablePath

        guard runtime.binaryExists(fileManager: fileManager) else {
            throw CLIError(
                code: CLIErrorCode.runtimeMissing,
                message: "Apple container binary not found at \(path)",
                hint: "Install Apple container and ensure it is at /usr/local/bin/container or on PATH"
            )
        }
        messages.append("binary: \(path)")

        let installRoot = ContainerPluginLayout.installRoot(containerBinaryPath: path)

        let versions = try runtime.systemVersion()
        let versionString: String
        if let first = versions.first {
            let v = first["version"] as? String ?? "unknown"
            let name = first["appName"] as? String ?? "container"
            versionString = "\(name) \(v)"
        } else {
            versionString = "unknown"
        }
        messages.append("version: \(versionString)")

        let statusObj = try runtime.systemStatus()
        let status = (statusObj["status"] as? String) ?? "unknown"
        messages.append("status: \(status)")

        let ok = status.lowercased() == "running"
        if !ok {
            throw CLIError(
                code: CLIErrorCode.runtimeFailed,
                message: "Apple container system status is '\(status)' (expected running)",
                hint: "Start the container system (e.g. container system start)"
            )
        }

        if !ContainerPluginLayout.isPresent(installRoot: installRoot, fileManager: fileManager) {
            throw ContainerPluginLayout.missingPluginError(
                installRoot: installRoot,
                fileManager: fileManager
            )
        }

        return DoctorReport(
            ok: true,
            binaryPath: path,
            version: versionString,
            status: status,
            messages: messages
        )
    }

    public static func printReport(_ report: DoctorReport) {
        print("\(CommandSurface.commandPrefix) doctor: PASS")
        for m in report.messages {
            print("  \(m)")
        }
    }
}
