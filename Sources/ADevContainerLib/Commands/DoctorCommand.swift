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

    /// `config.toml` plus `bin/dev`. A symlink `bin/dev` counts; do not require a regular file.
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

    /// Absolute symlink target for `bin/dev`.
    ///
    /// Homebrew formula `adevcontainer` (Cellar path, opt path, or brew `bin` symlink,
    /// including sudo with a bare argv0) targets
    /// `$(brew --prefix)/opt/adevcontainer/bin/adevcontainer`.
    /// That path is formed from the formula layout. It is never a Cellar path and never
    /// `resolvingSymlinksInPath` of the keg. If it cannot be formed, this throws.
    /// Otherwise the target is the running executable path with no realpath. A bare argv0
    /// is not a relative source path.
    ///
    /// When argv0 or the identified path is the plugin binary (`bin/dev`, or process name
    /// `dev`), the target is never that plugin path. An existing absolute link text is
    /// reused (Cellar becomes the opt path; an opt link is kept). A regular file, relative
    /// symlink, or self-symlink falls back to PATH `adevcontainer` or the Homebrew opt binary.
    public static func requiredSymlinkTarget(
        argv0: String,
        runningExecutablePath: String?,
        pathEnvironment: String?,
        installRoot: String,
        fileManager: FileManager = .default
    ) throws -> String {
        let pluginBinary = binaryPath(installRoot: installRoot)
        if argv0 == CommandSurface.pluginArgvName || isPluginBinaryPath(argv0, pluginBinary: pluginBinary) {
            let installed = try installedExecutableAvoidingPlugin(
                pluginBinary: pluginBinary,
                pathEnvironment: pathEnvironment,
                fileManager: fileManager
            )
            return try finalizedTarget(installed, pluginBinary: pluginBinary, fileManager: fileManager)
        }
        let identified = identifiedExecutablePath(
            argv0: argv0,
            runningExecutablePath: runningExecutablePath,
            pathEnvironment: pathEnvironment,
            fileManager: fileManager
        )
        if isPluginBinaryPath(identified, pluginBinary: pluginBinary) {
            let installed = try installedExecutableAvoidingPlugin(
                pluginBinary: pluginBinary,
                pathEnvironment: pathEnvironment,
                fileManager: fileManager
            )
            return try finalizedTarget(installed, pluginBinary: pluginBinary, fileManager: fileManager)
        }
        return try finalizedTarget(identified, pluginBinary: pluginBinary, fileManager: fileManager)
    }

    /// Create `bin/dev` as an absolute symlink and write `config.toml` as a regular file.
    /// Does not copy the Mach-O or chmod the symlink target.
    public static func installSymlink(
        installRoot: String,
        symlinkTarget: String,
        fileManager: FileManager = .default
    ) throws {
        guard symlinkTarget.hasPrefix("/") else {
            throw relativeSourceError(symlinkTarget)
        }
        let destBinary = binaryPath(installRoot: installRoot)
        guard !isPluginBinaryPath(symlinkTarget, pluginBinary: destBinary) else {
            throw refusingSelfLinkError(destBinary)
        }
        let dir = pluginDirectory(installRoot: installRoot)
        let destConfig = configPath(installRoot: installRoot)
        let binDir = (destBinary as NSString).deletingLastPathComponent
        do {
            try fileManager.createDirectory(atPath: binDir, withIntermediateDirectories: true)
            try replacePluginBinaryIfNeeded(
                destBinary: destBinary,
                symlinkTarget: symlinkTarget,
                fileManager: fileManager
            )
            try writeConfigAsRegularFile(at: destConfig, fileManager: fileManager)
        } catch let error as CLIError {
            throw error
        } catch {
            throw CLIError(
                code: CLIErrorCode.runtimeFailed,
                message: "Could not write Apple CLI plugin layout at \(dir): \(error.localizedDescription)",
                hint: installHint(installRoot: installRoot, fileManager: fileManager)
            )
        }
    }

    /// Remove `bin/dev` and `config.toml` only. Missing entries are success.
    /// Unlink symlinks; do not delete their targets, the keg, or any other path.
    public static func uninstall(installRoot: String, fileManager: FileManager = .default) throws {
        let destBinary = binaryPath(installRoot: installRoot)
        let destConfig = configPath(installRoot: installRoot)
        if !layoutEntryExists(destBinary, fileManager: fileManager),
           !layoutEntryExists(destConfig, fileManager: fileManager) {
            return
        }
        do {
            try removeLayoutEntry(destBinary, fileManager: fileManager)
            try removeLayoutEntry(destConfig, fileManager: fileManager)
        } catch {
            throw CLIError(
                code: CLIErrorCode.runtimeFailed,
                message: "Could not remove Apple CLI plugin layout at \(pluginDirectory(installRoot: installRoot)): \(error.localizedDescription)",
                hint: uninstallHint(installRoot: installRoot, fileManager: fileManager)
            )
        }
    }

    public static func missingPluginError(installRoot: String, fileManager: FileManager = .default) -> CLIError {
        CLIError(
            code: CLIErrorCode.runtimeFailed,
            message: "Apple CLI plugin 'dev' is not installed at \(pluginDirectory(installRoot: installRoot))",
            hint: installHint(installRoot: installRoot, fileManager: fileManager)
        )
    }

    static func installHint(installRoot: String, fileManager: FileManager) -> String {
        remediation(
            command: "plugin --install",
            action: "install the plugin",
            installRoot: installRoot,
            fileManager: fileManager
        )
    }

    static func uninstallHint(installRoot: String, fileManager: FileManager) -> String {
        remediation(
            command: "plugin --uninstall",
            action: "uninstall the plugin",
            installRoot: installRoot,
            fileManager: fileManager
        )
    }

    private static func remediation(
        command: String,
        action: String,
        installRoot: String,
        fileManager: FileManager
    ) -> String {
        requiresElevation(installRoot: installRoot, fileManager: fileManager)
            ? "Run 'sudo adevcontainer \(command)' to \(action) (destination requires elevated privileges)"
            : "Run 'adevcontainer \(command)' to \(action)"
    }

    /// Prefer an absolute running executable or PATH hit. Never treat a bare argv0 as relative.
    private static func identifiedExecutablePath(
        argv0: String,
        runningExecutablePath: String?,
        pathEnvironment: String?,
        fileManager: FileManager
    ) -> String {
        let isBareName = argv0.isEmpty || !argv0.contains("/")
        if !isBareName {
            if argv0.hasPrefix("/") {
                return argv0
            }
            // `./adevcontainer` is explicitly relative; absolute-ize lexically, do not realpath.
            return URL(fileURLWithPath: argv0).path
        }
        if let absolute = absolutePath(runningExecutablePath),
           fileManager.fileExists(atPath: absolute) {
            return absolute
        }
        if let found = pathHit(
            name: argv0.isEmpty ? CommandSurface.pathBinaryName : argv0,
            pathEnvironment: pathEnvironment,
            fileManager: fileManager
        ) {
            return found
        }
        if let absolute = absolutePath(runningExecutablePath) {
            return absolute
        }
        return argv0
    }

    private static func absolutePath(_ path: String?) -> String? {
        guard let path, path.hasPrefix("/") else { return nil }
        return path
    }

    private static func pathHit(name: String, pathEnvironment: String?, fileManager: FileManager) -> String? {
        guard let pathEnvironment else { return nil }
        for entry in pathEnvironment.split(separator: ":", omittingEmptySubsequences: false) {
            let directory = String(entry)
            guard directory.hasPrefix("/") else { continue }
            let candidate = (directory as NSString).appendingPathComponent(name)
            if fileManager.fileExists(atPath: candidate) {
                return candidate
            }
        }
        return nil
    }

    /// Nil when `executablePath` is not Homebrew formula `adevcontainer`.
    /// Throws when it is that formula but the opt path cannot be formed.
    private static func homebrewOptExecutable(
        executablePath: String,
        fileManager: FileManager
    ) throws -> String? {
        let name = CommandSurface.pathBinaryName
        if containsBounded(executablePath, marker: "/Cellar/\(name)")
            || containsBounded(executablePath, marker: "/opt/\(name)") {
            return try optExecutable(prefix: try brewPrefix(fromFormulaPath: executablePath))
        }
        if let prefix = try brewBinPrefix(executablePath, fileManager: fileManager) {
            return try optExecutable(prefix: prefix)
        }
        return nil
    }

    private static func brewPrefix(fromFormulaPath path: String) throws -> String {
        let name = CommandSurface.pathBinaryName
        if let range = boundedRange(in: path, marker: "/Cellar/\(name)") {
            return try requireBrewPrefix(String(path[..<range.lowerBound]))
        }
        if let range = boundedRange(in: path, marker: "/opt/\(name)") {
            return try requireBrewPrefix(String(path[..<range.lowerBound]))
        }
        throw unformableOptPathError()
    }

    /// `{prefix}/bin/adevcontainer` symlink whose link text names the formula.
    /// Reads the destination string only — does not `resolvingSymlinksInPath` the keg.
    private static func brewBinPrefix(_ path: String, fileManager: FileManager) throws -> String? {
        let name = CommandSurface.pathBinaryName
        let ns = path as NSString
        guard ns.lastPathComponent == name else { return nil }
        let binDir = ns.deletingLastPathComponent
        guard (binDir as NSString).lastPathComponent == "bin" else { return nil }
        guard let destination = symlinkDestination(path, fileManager: fileManager) else {
            return nil
        }
        let namesFormula = containsBounded(destination, marker: "Cellar/\(name)")
            || containsBounded(destination, marker: "opt/\(name)")
        guard namesFormula else { return nil }
        return try requireBrewPrefix((binDir as NSString).deletingLastPathComponent)
    }

    private static func requireBrewPrefix(_ prefix: String) throws -> String {
        let trimmed = prefix.hasSuffix("/") ? String(prefix.dropLast()) : prefix
        guard trimmed.hasPrefix("/"), trimmed != "/" else {
            throw unformableOptPathError()
        }
        return trimmed
    }

    private static func optExecutable(prefix: String) throws -> String {
        let name = CommandSurface.pathBinaryName
        let trimmed = try requireBrewPrefix(prefix)
        // String form of $(brew --prefix)/opt/adevcontainer/bin/adevcontainer.
        // Do not round-trip through URL — that can rewrite /var vs /private/var.
        return "\(trimmed)/opt/\(name)/bin/\(name)"
    }

    private static func replacePluginBinaryIfNeeded(
        destBinary: String,
        symlinkTarget: String,
        fileManager: FileManager
    ) throws {
        if let existing = symlinkDestination(destBinary, fileManager: fileManager) {
            if existing == symlinkTarget, existing.hasPrefix("/") {
                return
            }
            // removeItem unlinks the symlink and does not delete its target.
            try fileManager.removeItem(atPath: destBinary)
        } else if fileManager.fileExists(atPath: destBinary) {
            try fileManager.removeItem(atPath: destBinary)
        }
        try fileManager.createSymbolicLink(atPath: destBinary, withDestinationPath: symlinkTarget)
    }

    private static func writeConfigAsRegularFile(at path: String, fileManager: FileManager) throws {
        if symlinkDestination(path, fileManager: fileManager) != nil {
            try fileManager.removeItem(atPath: path)
        }
        try configTOML.write(toFile: path, atomically: true, encoding: .utf8)
    }

    private static func removeLayoutEntry(_ path: String, fileManager: FileManager) throws {
        if symlinkDestination(path, fileManager: fileManager) != nil || isRegularFile(path, fileManager: fileManager) {
            try fileManager.removeItem(atPath: path)
        }
    }

    private static func layoutEntryExists(_ path: String, fileManager: FileManager) -> Bool {
        symlinkDestination(path, fileManager: fileManager) != nil || fileManager.fileExists(atPath: path)
    }

    private static func isRegularFile(_ path: String, fileManager: FileManager) -> Bool {
        if symlinkDestination(path, fileManager: fileManager) != nil { return false }
        var isDirectory = ObjCBool(false)
        guard fileManager.fileExists(atPath: path, isDirectory: &isDirectory) else { return false }
        return !isDirectory.boolValue
    }

    private static func symlinkDestination(_ path: String, fileManager: FileManager) -> String? {
        try? fileManager.destinationOfSymbolicLink(atPath: path)
    }

    private static func containsBounded(_ path: String, marker: String) -> Bool {
        boundedRange(in: path, marker: marker) != nil
    }

    /// Marker must end at `/` or end-of-string so `adevcontainer-other` does not match.
    private static func boundedRange(in path: String, marker: String) -> Range<String.Index>? {
        var search = path.startIndex
        while let range = path.range(of: marker, range: search..<path.endIndex) {
            let after = range.upperBound
            if after == path.endIndex || path[after] == "/" {
                return range
            }
            search = after
        }
        return nil
    }

    private static func finalizedTarget(
        _ identified: String,
        pluginBinary: String,
        fileManager: FileManager
    ) throws -> String {
        let target = try targetForIdentifiedExecutable(identified, fileManager: fileManager)
        guard !isPluginBinaryPath(target, pluginBinary: pluginBinary) else {
            throw refusingSelfLinkError(pluginBinary)
        }
        return target
    }

    /// Homebrew vs non-Homebrew rules for an already-identified executable path.
    /// Does not `resolvingSymlinksInPath` the keg.
    private static func targetForIdentifiedExecutable(
        _ identified: String,
        fileManager: FileManager
    ) throws -> String {
        if let opt = try homebrewOptExecutable(executablePath: identified, fileManager: fileManager) {
            guard fileManager.fileExists(atPath: identified) else {
                throw sourceNotFoundError(identified)
            }
            guard opt.hasPrefix("/") else {
                throw unformableOptPathError()
            }
            return opt
        }
        guard identified.hasPrefix("/") else {
            throw relativeSourceError(identified)
        }
        guard fileManager.fileExists(atPath: identified) else {
            throw sourceNotFoundError(identified)
        }
        return identified
    }

    /// Link text of an absolute symlink to a different path, else PATH `adevcontainer`
    /// or the Homebrew opt binary. Never returns the plugin path.
    private static func installedExecutableAvoidingPlugin(
        pluginBinary: String,
        pathEnvironment: String?,
        fileManager: FileManager
    ) throws -> String {
        if let link = symlinkDestination(pluginBinary, fileManager: fileManager),
           link.hasPrefix("/"),
           !isPluginBinaryPath(link, pluginBinary: pluginBinary) {
            return link
        }
        if let found = pathHit(
            name: CommandSurface.pathBinaryName,
            pathEnvironment: pathEnvironment,
            fileManager: fileManager
        ), !isPluginBinaryPath(found, pluginBinary: pluginBinary) {
            return found
        }
        if let opt = homebrewOptBinaryOnPath(
            pathEnvironment: pathEnvironment,
            pluginBinary: pluginBinary,
            fileManager: fileManager
        ) {
            return opt
        }
        throw refusingSelfLinkError(pluginBinary)
    }

    /// `{prefix}/opt/adevcontainer/bin/adevcontainer` when a PATH `bin` directory's prefix has it.
    private static func homebrewOptBinaryOnPath(
        pathEnvironment: String?,
        pluginBinary: String,
        fileManager: FileManager
    ) -> String? {
        guard let pathEnvironment else { return nil }
        let name = CommandSurface.pathBinaryName
        for entry in pathEnvironment.split(separator: ":", omittingEmptySubsequences: false) {
            let directory = String(entry)
            guard directory.hasPrefix("/") else { continue }
            let ns = directory as NSString
            guard ns.lastPathComponent == "bin" else { continue }
            let prefix = ns.deletingLastPathComponent
            guard !prefix.isEmpty, prefix != "/" else { continue }
            let opt = "\(prefix)/opt/\(name)/bin/\(name)"
            guard !isPluginBinaryPath(opt, pluginBinary: pluginBinary) else { continue }
            guard fileManager.fileExists(atPath: opt) else { continue }
            return opt
        }
        return nil
    }

    /// Lexical path equality only. Does not resolve symlinks.
    private static func isPluginBinaryPath(_ path: String, pluginBinary: String) -> Bool {
        if path == pluginBinary { return true }
        guard path.hasPrefix("/"), pluginBinary.hasPrefix("/") else { return false }
        return URL(fileURLWithPath: path).standardizedFileURL.path
            == URL(fileURLWithPath: pluginBinary).standardizedFileURL.path
    }

    private static func refusingSelfLinkError(_ pluginBinary: String) -> CLIError {
        CLIError(
            code: CLIErrorCode.runtimeFailed,
            message: "Could not install Apple CLI plugin: refusing to link \(pluginBinary) to itself",
            hint: "Retry with PATH `adevcontainer plugin --install` or the full path to the installed executable"
        )
    }

    private static func sourceNotFoundError(_ path: String) -> CLIError {
        CLIError(
            code: CLIErrorCode.runtimeFailed,
            message: "Could not install Apple CLI plugin: source executable not found at \(path)",
            hint: "Reinstall adevcontainer onto PATH or retry using the full path to the binary"
        )
    }

    private static func relativeSourceError(_ path: String) -> CLIError {
        CLIError(
            code: CLIErrorCode.runtimeFailed,
            message: "Could not install Apple CLI plugin: refusing relative source path '\(path)'",
            hint: "Retry using the full path to the adevcontainer binary"
        )
    }

    private static func unformableOptPathError() -> CLIError {
        CLIError(
            code: CLIErrorCode.runtimeFailed,
            message: "Could not form Homebrew opt path $(brew --prefix)/opt/adevcontainer/bin/adevcontainer",
            hint: "Refusing to link a Cellar path or a realpath-resolved keg. Reinstall the Homebrew formula, then retry 'adevcontainer plugin --install'"
        )
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
