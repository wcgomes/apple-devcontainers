import Foundation
@testable import ADevContainerLib

final class PluginTestFileManager: FileManager, @unchecked Sendable {
    var executablePaths: Set<String> = []

    override func isExecutableFile(atPath path: String) -> Bool {
        executablePaths.contains(path)
    }
}

/// Records symlink replacement so an already-correct link can be proven untouched.
final class RemoveRecordingFileManager: FileManager, @unchecked Sendable {
    var removedPaths: [String] = []
    var createdLinks: [(path: String, destination: String)] = []

    override func removeItem(atPath path: String) throws {
        removedPaths.append(path)
        try super.removeItem(atPath: path)
    }

    override func createSymbolicLink(atPath path: String, withDestinationPath destPath: String) throws {
        createdLinks.append((path, destPath))
        try super.createSymbolicLink(atPath: path, withDestinationPath: destPath)
    }
}

enum PluginTestSupport {
    static func makeInstallRoot() throws -> URL {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("adev-plugin-\(UUID().uuidString)", isDirectory: true)
        let bin = root.appendingPathComponent("bin", isDirectory: true)
        try FileManager.default.createDirectory(at: bin, withIntermediateDirectories: true)
        let container = bin.appendingPathComponent("container")
        try Data("#!/bin/sh\nexit 0\n".utf8).write(to: container)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: container.path)
        return root
    }

    static func containerBinary(in installRoot: URL) -> String {
        installRoot.appendingPathComponent("bin/container").path
    }

    static func writeExecutable(at url: URL, contents: Data = Data("adevcontainer-mach-o-stub\n".utf8)) throws {
        try FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try contents.write(to: url)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: url.path)
    }

    static func stagePluginLayout(installRoot: URL, executableContents: Data = Data("plugin-dev-stub\n".utf8)) throws {
        let pluginDir = installRoot.appendingPathComponent("libexec/container-plugins/dev")
        let pluginBin = pluginDir.appendingPathComponent("bin", isDirectory: true)
        try FileManager.default.createDirectory(at: pluginBin, withIntermediateDirectories: true)
        try ContainerPluginLayout.configTOML.write(
            to: pluginDir.appendingPathComponent("config.toml"),
            atomically: true,
            encoding: .utf8
        )
        try writeExecutable(
            at: pluginBin.appendingPathComponent("dev"),
            contents: executableContents
        )
    }

    static func readyRuntime(
        executablePath: String,
        status: String = "running"
    ) throws -> AppleContainerRuntime {
        let mock = MockProcessRunner()
        try mock.enqueueJSON([["appName": "container", "version": "1.2.1"]])
        try mock.enqueueJSON(["status": status, "apiServerVersion": "1.2.1"] as [String: Any])
        return AppleContainerRuntime(executablePath: executablePath, runner: mock)
    }

    static func withCommandPrefix(_ prefix: String, _ body: () throws -> Void) throws {
        let previous = CommandSurface.commandPrefix
        CommandSurface.commandPrefix = prefix
        defer { CommandSurface.commandPrefix = previous }
        try body()
    }

    static func homebrewOptPath(prefix: URL) -> String {
        "\(prefix.path)/opt/adevcontainer/bin/adevcontainer"
    }

    /// Cellar binary is a symlink to `real` so a realpath of the keg is not the opt path.
    static func makeHomebrewCellar(
        prefix: URL,
        contents: Data
    ) throws -> (cellar: String, opt: String, real: String) {
        let real = prefix.appendingPathComponent("real-keg-mach-o")
        try writeExecutable(at: real, contents: contents)
        let cellar = prefix
            .appendingPathComponent("Cellar")
            .appendingPathComponent("adevcontainer")
            .appendingPathComponent("1.2.3")
            .appendingPathComponent("bin")
            .appendingPathComponent("adevcontainer")
        try FileManager.default.createDirectory(
            at: cellar.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try FileManager.default.createSymbolicLink(atPath: cellar.path, withDestinationPath: real.path)
        return (cellar.path, homebrewOptPath(prefix: prefix), real.path)
    }

    static func installPlugin(
        installRoot: URL,
        currentExecutablePath: String,
        runningExecutablePath: String? = nil,
        pathEnvironment: String? = "",
        fileManager: FileManager = .default
    ) throws {
        let runtime = try readyRuntime(executablePath: containerBinary(in: installRoot))
        try PluginCommand.run(
            install: true,
            uninstall: false,
            runtime: runtime,
            currentExecutablePath: currentExecutablePath,
            runningExecutablePath: runningExecutablePath,
            pathEnvironment: pathEnvironment,
            fileManager: fileManager
        )
    }

    static func uninstallPlugin(installRoot: URL, fileManager: FileManager = .default) throws {
        let runtime = try readyRuntime(executablePath: containerBinary(in: installRoot))
        try PluginCommand.run(
            install: false,
            uninstall: true,
            runtime: runtime,
            pathEnvironment: "",
            fileManager: fileManager
        )
    }

    static func expectSymlink(at path: String, target: String, _ message: String) throws {
        let destination = try FileManager.default.destinationOfSymbolicLink(atPath: path)
        try MiniTest.expectEqual(destination, target, message)
        try MiniTest.expect(destination.hasPrefix("/"), "\(message): target is absolute")
    }

    static func expectRegularCLIConfig(installRoot: String) throws {
        let configPath = ContainerPluginLayout.configPath(installRoot: installRoot)
        try MiniTest.expect(
            (try? FileManager.default.destinationOfSymbolicLink(atPath: configPath)) == nil,
            "config.toml is a regular file, not a symlink"
        )
        let toml = try String(contentsOfFile: configPath, encoding: .utf8)
        try MiniTest.expect(toml.contains("abstract"), "config.toml includes abstract")
        try MiniTest.expect(!toml.contains("[servicesConfig]"), "config.toml omits [servicesConfig]")
        try MiniTest.expect(!toml.contains("servicesConfig"), "config.toml omits servicesConfig")
    }

    static func posixMode(_ path: String) throws -> Int {
        let attrs = try FileManager.default.attributesOfItem(atPath: path)
        return (attrs[.posixPermissions] as? NSNumber)?.intValue ?? -1
    }

    static func expectExactlyOneFlagError(_ error: Error) throws {
        let err = error as! CLIError
        try MiniTest.expectEqual(err.code, CLIErrorCode.usage)
        let text = err.message + " " + (err.hint ?? "")
        try MiniTest.expect(text.contains("--install"), "names --install")
        try MiniTest.expect(text.contains("--uninstall"), "names --uninstall")
        try MiniTest.expect(text.contains("exactly one"), "states exactly one is required")
        try MiniTest.expect(!text.contains("install-plugin"), "does not name install-plugin")
    }
}

nonisolated(unsafe) let containerPluginTests: [(String, () throws -> Void)] = [
    ("pluginProductArgumentsStripDevToken", {
        try MiniTest.expectEqual(
            CommandSurface.productArguments(from: ["dev", "doctor", "--repair"]),
            ["doctor", "--repair"]
        )
        try MiniTest.expectEqual(
            CommandSurface.productArguments(from: ["dev", "up", "-w", "/tmp/ws"]),
            ["up", "-w", "/tmp/ws"]
        )
        try MiniTest.expectEqual(
            CommandSurface.productArguments(from: ["doctor"]),
            ["doctor"]
        )
        try MiniTest.expectEqual(
            CommandSurface.productArguments(from: []),
            []
        )
    }),

    ("pluginInvocationPrefixFromProcessNameAndArgv", {
        try MiniTest.expectEqual(
            CommandSurface.invocationPrefix(
                processPath: "/usr/local/bin/adevcontainer",
                argv: ["doctor"]
            ),
            CommandSurface.pathBinaryName
        )
        try MiniTest.expectEqual(
            CommandSurface.invocationPrefix(
                processPath: "/usr/local/libexec/container-plugins/dev/bin/dev",
                argv: ["dev", "doctor"]
            ),
            CommandSurface.pluginInvocationPrefix
        )
        try MiniTest.expectEqual(
            CommandSurface.invocationPrefix(
                processPath: "/usr/local/libexec/container-plugins/dev/bin/dev",
                argv: ["up"]
            ),
            CommandSurface.pluginInvocationPrefix
        )
        try MiniTest.expectEqual(
            CommandSurface.invocationPrefix(
                processPath: "/usr/local/bin/adevcontainer",
                argv: ["dev", "list"]
            ),
            CommandSurface.pluginInvocationPrefix
        )
    }),

    ("pluginHelpAndUsageUseContainerDevPrefix", {
        try PluginTestSupport.withCommandPrefix(CommandSurface.pluginInvocationPrefix) {
            let usage = CommandSurface.usageText()
            try MiniTest.expect(usage.contains("container dev <command>"), "usage uses plugin prefix")
            try MiniTest.expect(
                usage.contains("devcontainer.managed=adevcontainer"),
                "managed identity stays adevcontainer in usage"
            )
            let up = CommandSurface.commandHelpText("up") ?? ""
            try MiniTest.expect(up.contains("container dev up"), "up help uses plugin prefix")
            let doctor = CommandSurface.commandHelpText("doctor") ?? ""
            try MiniTest.expect(doctor.contains("container dev doctor"), "doctor help uses plugin prefix")
            try MiniTest.expect(!doctor.contains("--repair"), "doctor help does not document --repair")
            try MiniTest.expect(
                doctor.contains("adevcontainer plugin --install"),
                "missing-plugin help names PATH adevcontainer plugin --install"
            )
            try MiniTest.expect(
                !doctor.contains("container dev plugin --install"),
                "missing-plugin help must not name container dev plugin --install"
            )
            try MiniTest.expect(!doctor.contains("install-plugin"), "doctor help does not name install-plugin")
            try MiniTest.expect(usage.contains("plugin --install"), "usage documents plugin --install")
            try MiniTest.expect(usage.contains("--uninstall"), "usage documents --uninstall")
            try MiniTest.expect(usage.contains("exactly one"), "usage states exactly one flag is required")
            try MiniTest.expect(!usage.contains("install-plugin"), "usage does not document install-plugin")
            try MiniTest.expect(!usage.contains("--repair"), "usage does not document --repair")
            let plugin = CommandSurface.commandHelpText("plugin") ?? ""
            try MiniTest.expect(plugin.contains("container dev plugin --install"), "plugin help stays invocation-aware")
            try MiniTest.expect(plugin.contains("--uninstall"), "plugin help documents --uninstall")
            try MiniTest.expect(
                plugin.lowercased().contains("exactly one"),
                "plugin help states exactly one flag is required"
            )
            try MiniTest.expect(
                plugin.contains("adevcontainer plugin --install"),
                "plugin help restage sentence uses PATH"
            )
            try MiniTest.expect(!plugin.contains("install-plugin"), "plugin help does not document install-plugin")
            try MiniTest.expect(!plugin.contains("--repair"), "plugin help does not document --repair")
            try MiniTest.expect(CommandSurface.commandHelpText("install-plugin") == nil, "install-plugin is not an alias")
            let hint = ContainerIdentity.nameInUseError(name: "ctr").hint ?? ""
            try MiniTest.expect(hint.contains("container dev delete --name ctr"), "retry hint uses plugin prefix")
            try MiniTest.expect(
                !hint.contains("plugin --install"),
                "occupancy hint is not missing-plugin remediation"
            )
        }
    }),

    ("pathHelpAndUsageUseAdevcontainerPrefix", {
        try PluginTestSupport.withCommandPrefix(CommandSurface.pathBinaryName) {
            let usage = CommandSurface.usageText()
            try MiniTest.expect(usage.contains("adevcontainer <command>"), "usage uses PATH prefix")
            let up = CommandSurface.commandHelpText("up") ?? ""
            try MiniTest.expect(up.contains("adevcontainer up"), "up help uses PATH prefix")
            let doctor = CommandSurface.commandHelpText("doctor") ?? ""
            try MiniTest.expect(doctor.contains("adevcontainer doctor"), "doctor help uses PATH prefix")
            try MiniTest.expect(!doctor.contains("--repair"), "doctor help does not document --repair")
            try MiniTest.expect(
                doctor.contains("adevcontainer plugin --install"),
                "missing-plugin help names PATH adevcontainer plugin --install"
            )
            try MiniTest.expect(
                !doctor.contains("container dev plugin --install"),
                "missing-plugin help must not name container dev plugin --install"
            )
            try MiniTest.expect(!usage.contains("install-plugin"), "usage does not document install-plugin")
            try MiniTest.expect(!usage.contains("--repair"), "usage does not document --repair")
            try MiniTest.expect(usage.contains("plugin --install") && usage.contains("--uninstall"))
            let plugin = CommandSurface.commandHelpText("plugin") ?? ""
            try MiniTest.expect(plugin.contains("adevcontainer plugin --install"), "plugin help uses PATH prefix")
            try MiniTest.expect(plugin.contains("--uninstall"))
            try MiniTest.expect(!plugin.contains("install-plugin"))
            try MiniTest.expect(!plugin.contains("--repair"))
            try MiniTest.expect(
                !plugin.contains("container dev plugin --install"),
                "PATH plugin help must not name container dev plugin --install"
            )
            let hint = ContainerIdentity.nameInUseError(name: "ctr").hint ?? ""
            try MiniTest.expect(hint.contains("adevcontainer delete --name ctr"), "retry hint uses PATH prefix")
        }
    }),

    ("pluginInvocationKeepsManagedIdentityAdevcontainer", {
        try PluginTestSupport.withCommandPrefix(CommandSurface.pluginInvocationPrefix) {
            try MiniTest.expectEqual(ContainerIdentity.managedValue, "adevcontainer")
            try MiniTest.expectEqual(ContainerIdentity.labelManaged, "devcontainer.managed")
            let usage = CommandSurface.usageText()
            try MiniTest.expect(usage.contains("devcontainer.managed=adevcontainer"))
        }
    }),

    ("pluginWithNeitherFlagIsUsageError", {
        let parsed = try CommandSurface.parseArgs([])
        try MiniTest.expectThrows({
            try CommandSurface.enforcePluginInvocation(subcommand: "plugin", parsed: parsed)
        }, validate: PluginTestSupport.expectExactlyOneFlagError)
    }),

    ("pluginWithBothFlagsIsUsageError", {
        let parsed = try CommandSurface.parseArgs(["--install", "--uninstall"])
        try MiniTest.expectThrows({
            try CommandSurface.enforcePluginInvocation(subcommand: "plugin", parsed: parsed)
        }, validate: PluginTestSupport.expectExactlyOneFlagError)
    }),

    ("installPluginIsNotACommand", {
        try MiniTest.expect(CommandSurface.commandHelpText("install-plugin") == nil, "not an alias")
        try MiniTest.expect(!CommandSurface.usageText().contains("install-plugin"))
        let err = CommandSurface.unknownSubcommandError(subcommand: "install-plugin")
        try MiniTest.expectEqual(err.code, CLIErrorCode.usage)
        let hint = err.hint ?? ""
        try MiniTest.expect(hint.contains("plugin"), "unknown-command hint names plugin")
        try MiniTest.expect(!hint.contains("install-plugin"), "unknown-command hint does not list install-plugin")
    }),

    ("repairFlagFailsAsUsageAndHintsPluginInstall", {
        try MiniTest.expectThrows({
            _ = try CommandSurface.parseArgs(["--repair"])
        }) { error in
            let err = error as! CLIError
            try MiniTest.expectEqual(err.code, CLIErrorCode.usage)
            try MiniTest.expectEqual(err.property, "--repair")
            let hint = err.hint ?? ""
            try MiniTest.expect(hint.contains("plugin --install"), "parse --repair hints plugin --install")
            try MiniTest.expect(!hint.contains("install-plugin"), "parse --repair does not name install-plugin")
            try MiniTest.expect(
                !hint.contains("container dev plugin"),
                "parse --repair must not suggest container dev plugin --install"
            )
        }
        for subcommand in ["doctor", "plugin", "up"] {
            try MiniTest.expectThrows({
                try CommandSurface.enforceWorkspaceGate(
                    subcommand: subcommand,
                    parsed: ParsedArgs(flags: ["repair"])
                )
            }) { error in
                let err = error as! CLIError
                try MiniTest.expectEqual(err.code, CLIErrorCode.usage)
                try MiniTest.expectEqual(err.property, "--repair")
                let hint = err.hint ?? ""
                try MiniTest.expect(
                    hint.contains("plugin --install"),
                    "\(subcommand) --repair hints plugin --install"
                )
                try MiniTest.expect(
                    !hint.contains("install-plugin"),
                    "\(subcommand) --repair does not name install-plugin"
                )
                try MiniTest.expect(
                    !hint.contains("container dev plugin"),
                    "\(subcommand) --repair must not suggest container dev plugin --install"
                )
            }
        }
    }),

    ("doctorMissingPluginReportsPathPluginInstall", {
        let root = try PluginTestSupport.makeInstallRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let runtime = try PluginTestSupport.readyRuntime(
            executablePath: PluginTestSupport.containerBinary(in: root)
        )
        try MiniTest.expectThrows({
            _ = try DoctorCommand.run(runtime: runtime)
        }) { error in
            let err = error as! CLIError
            let hint = err.hint ?? ""
            let message = err.message
            try MiniTest.expect(message.lowercased().contains("plugin"), "names the missing plugin")
            try MiniTest.expect(
                hint.contains("adevcontainer plugin --install"),
                "PATH remediation for a missing plugin"
            )
            try MiniTest.expect(!hint.contains("sudo"), "writable destination does not ask for sudo")
            try MiniTest.expect(
                !hint.contains("container dev plugin --install"),
                "must not suggest plugin invocation when the plugin is missing"
            )
            try MiniTest.expect(!hint.contains("install-plugin"), "must not name install-plugin")
            try MiniTest.expect(!hint.contains("doctor --repair"), "must not hint doctor --repair")
        }
        let pluginDir = ContainerPluginLayout.pluginDirectory(installRoot: root.path)
        try MiniTest.expect(!FileManager.default.fileExists(atPath: pluginDir), "doctor does not restage")
    }),

    ("pluginInstallCreatesAbsoluteSymlinkAndConfig", {
        let root = try PluginTestSupport.makeInstallRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let source = root.appendingPathComponent("bin/adevcontainer")
        try PluginTestSupport.writeExecutable(at: source, contents: Data("path-mach-o\n".utf8))
        try PluginTestSupport.installPlugin(installRoot: root, currentExecutablePath: source.path)
        let binaryPath = ContainerPluginLayout.binaryPath(installRoot: root.path)
        try PluginTestSupport.expectSymlink(at: binaryPath, target: source.path, "absolute symlink to the installed executable")
        try PluginTestSupport.expectRegularCLIConfig(installRoot: root.path)
        let opt = PluginTestSupport.homebrewOptPath(prefix: root)
        try MiniTest.expect(
            try FileManager.default.destinationOfSymbolicLink(atPath: binaryPath) != opt,
            "a regular file under bin/ is not treated as the Homebrew formula"
        )
    }),

    ("pluginInstallReplacesCopiedPluginBinary", {
        let root = try PluginTestSupport.makeInstallRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let source = root.appendingPathComponent("installed/adevcontainer")
        try PluginTestSupport.writeExecutable(at: source, contents: Data("kept-target\n".utf8))
        let binaryPath = ContainerPluginLayout.binaryPath(installRoot: root.path)
        try PluginTestSupport.writeExecutable(
            at: URL(fileURLWithPath: binaryPath),
            contents: Data("old-copy\n".utf8)
        )
        try PluginTestSupport.installPlugin(installRoot: root, currentExecutablePath: source.path)
        try PluginTestSupport.expectSymlink(at: binaryPath, target: source.path, "replaces the regular-file copy")
        let followed = try String(contentsOfFile: binaryPath, encoding: .utf8)
        try MiniTest.expectEqual(followed, "kept-target\n")
        try MiniTest.expectEqual(try String(contentsOfFile: source.path, encoding: .utf8), "kept-target\n")
    }),

    ("pluginInstallReplacesWrongSymlinkWithoutDeletingTarget", {
        let root = try PluginTestSupport.makeInstallRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let source = root.appendingPathComponent("installed/adevcontainer")
        try PluginTestSupport.writeExecutable(at: source)
        let other = root.appendingPathComponent("old-target")
        try PluginTestSupport.writeExecutable(at: other, contents: Data("do-not-delete\n".utf8))
        let binaryPath = ContainerPluginLayout.binaryPath(installRoot: root.path)
        try FileManager.default.createDirectory(
            at: URL(fileURLWithPath: binaryPath).deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try FileManager.default.createSymbolicLink(atPath: binaryPath, withDestinationPath: other.path)
        try PluginTestSupport.installPlugin(installRoot: root, currentExecutablePath: source.path)
        try PluginTestSupport.expectSymlink(at: binaryPath, target: source.path, "replaces the wrong absolute symlink")
        try MiniTest.expectEqual(
            try String(contentsOfFile: other.path, encoding: .utf8),
            "do-not-delete\n",
            "old symlink target still exists"
        )
    }),

    ("pluginInstallReplacesRelativeSymlinkWithoutDeletingTarget", {
        let root = try PluginTestSupport.makeInstallRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let source = root.appendingPathComponent("adevcontainer-src")
        try PluginTestSupport.writeExecutable(at: source, contents: Data("same-file\n".utf8))
        let binaryPath = ContainerPluginLayout.binaryPath(installRoot: root.path)
        try FileManager.default.createDirectory(
            at: URL(fileURLWithPath: binaryPath).deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        let relative = "../../../../adevcontainer-src"
        try FileManager.default.createSymbolicLink(atPath: binaryPath, withDestinationPath: relative)
        try MiniTest.expectEqual(
            URL(fileURLWithPath: binaryPath).resolvingSymlinksInPath().path,
            URL(fileURLWithPath: source.path).resolvingSymlinksInPath().path,
            "relative symlink would resolve to the required file"
        )
        try PluginTestSupport.installPlugin(installRoot: root, currentExecutablePath: source.path)
        try PluginTestSupport.expectSymlink(
            at: binaryPath,
            target: source.path,
            "replaces a relative symlink even when it resolves to the same file"
        )
        try MiniTest.expect(FileManager.default.fileExists(atPath: source.path), "old target still exists")
    }),

    ("pluginInstallKeepsAlreadyCorrectSymlink", {
        let root = try PluginTestSupport.makeInstallRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let source = root.appendingPathComponent("installed/adevcontainer")
        try PluginTestSupport.writeExecutable(at: source)
        let binaryPath = ContainerPluginLayout.binaryPath(installRoot: root.path)
        try FileManager.default.createDirectory(
            at: URL(fileURLWithPath: binaryPath).deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try FileManager.default.createSymbolicLink(atPath: binaryPath, withDestinationPath: source.path)
        let recorder = RemoveRecordingFileManager()
        try PluginTestSupport.installPlugin(
            installRoot: root,
            currentExecutablePath: source.path,
            fileManager: recorder
        )
        try MiniTest.expect(
            !recorder.removedPaths.contains(binaryPath),
            "already-correct absolute symlink is not removed"
        )
        try MiniTest.expect(
            !recorder.createdLinks.contains { $0.path == binaryPath },
            "already-correct absolute symlink is not replaced"
        )
        try PluginTestSupport.expectSymlink(at: binaryPath, target: source.path, "symlink target unchanged")
        try PluginTestSupport.expectRegularCLIConfig(installRoot: root.path)
    }),

    ("pluginInstallReplacesSymlinkedConfigWithoutWritingThrough", {
        let root = try PluginTestSupport.makeInstallRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let source = root.appendingPathComponent("installed/adevcontainer")
        try PluginTestSupport.writeExecutable(at: source)
        let secret = root.appendingPathComponent("secret-config.toml")
        try Data("SECRET-TARGET\n".utf8).write(to: secret)
        let configPath = ContainerPluginLayout.configPath(installRoot: root.path)
        try FileManager.default.createDirectory(
            at: URL(fileURLWithPath: configPath).deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try FileManager.default.createSymbolicLink(atPath: configPath, withDestinationPath: secret.path)
        try PluginTestSupport.installPlugin(installRoot: root, currentExecutablePath: source.path)
        try PluginTestSupport.expectRegularCLIConfig(installRoot: root.path)
        try MiniTest.expectEqual(
            try String(contentsOfFile: secret.path, encoding: .utf8),
            "SECRET-TARGET\n",
            "previous config.toml symlink target is unchanged"
        )
    }),

    ("pluginInstallHomebrewLinksOptPath", {
        let root = try PluginTestSupport.makeInstallRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let prefix = root.appendingPathComponent("homebrew")
        let bytes = Data("keg-bytes-\(UUID().uuidString)\n".utf8)
        let formula = try PluginTestSupport.makeHomebrewCellar(prefix: prefix, contents: bytes)
        try FileManager.default.setAttributes([.posixPermissions: 0o754], ofItemAtPath: formula.real)
        let modeBefore = try PluginTestSupport.posixMode(formula.real)
        try PluginTestSupport.installPlugin(installRoot: root, currentExecutablePath: formula.cellar)
        let binaryPath = ContainerPluginLayout.binaryPath(installRoot: root.path)
        try PluginTestSupport.expectSymlink(at: binaryPath, target: formula.opt, "Cellar path links the opt path")
        try MiniTest.expect(!formula.opt.contains("/Cellar/"), "opt path is not a Cellar path")
        try MiniTest.expect(formula.opt != formula.real, "opt path is not the realpath of the keg")
        try MiniTest.expectEqual(try Data(contentsOf: URL(fileURLWithPath: formula.real)), bytes)
        try MiniTest.expectEqual(try PluginTestSupport.posixMode(formula.real), modeBefore, "does not chmod the keg")
        try PluginTestSupport.expectRegularCLIConfig(installRoot: root.path)
    }),

    ("pluginInstallHomebrewBareArgv0LinksOptPath", {
        let root = try PluginTestSupport.makeInstallRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let cwd = FileManager.default.temporaryDirectory
            .appendingPathComponent("adev-sudo-argv0-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: cwd, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: cwd) }
        let previousCwd = FileManager.default.currentDirectoryPath
        try MiniTest.expect(FileManager.default.changeCurrentDirectoryPath(cwd.path))
        defer { FileManager.default.changeCurrentDirectoryPath(previousCwd) }
        try MiniTest.expect(!FileManager.default.fileExists(atPath: cwd.appendingPathComponent("adevcontainer").path))
        let prefix = root.appendingPathComponent("homebrew")
        let formula = try PluginTestSupport.makeHomebrewCellar(
            prefix: prefix,
            contents: Data("sudo-keg\n".utf8)
        )
        try PluginTestSupport.installPlugin(
            installRoot: root,
            currentExecutablePath: "adevcontainer",
            runningExecutablePath: formula.cellar,
            pathEnvironment: ""
        )
        let binaryPath = ContainerPluginLayout.binaryPath(installRoot: root.path)
        try PluginTestSupport.expectSymlink(
            at: binaryPath,
            target: formula.opt,
            "sudo bare argv0 of a Cellar binary links the opt path"
        )
        try MiniTest.expect(
            try FileManager.default.destinationOfSymbolicLink(atPath: binaryPath) != "adevcontainer",
            "bare argv0 is not the symlink target"
        )
    }),

    ("pluginInstallHomebrewBinSymlinkLinksOptPath", {
        let root = try PluginTestSupport.makeInstallRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let prefix = root.appendingPathComponent("homebrew")
        let formula = try PluginTestSupport.makeHomebrewCellar(prefix: prefix, contents: Data("bin-link\n".utf8))
        let binLink = prefix.appendingPathComponent("bin/adevcontainer")
        try FileManager.default.createDirectory(at: binLink.deletingLastPathComponent(), withIntermediateDirectories: true)
        try FileManager.default.createSymbolicLink(
            atPath: binLink.path,
            withDestinationPath: "../Cellar/adevcontainer/1.2.3/bin/adevcontainer"
        )
        try PluginTestSupport.installPlugin(installRoot: root, currentExecutablePath: binLink.path)
        let binaryPath = ContainerPluginLayout.binaryPath(installRoot: root.path)
        try PluginTestSupport.expectSymlink(at: binaryPath, target: formula.opt, "brew bin symlink links the opt path")
        try MiniTest.expect(
            try FileManager.default.destinationOfSymbolicLink(atPath: binaryPath) != formula.cellar,
            "does not link the Cellar path"
        )
        try MiniTest.expect(
            try FileManager.default.destinationOfSymbolicLink(atPath: binaryPath) != formula.real,
            "does not link the realpath of the keg"
        )
    }),

    ("pluginInstallFailsClosedWhenOptPathCannotBeFormed", {
        let root = try PluginTestSupport.makeInstallRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let unformable = "/Cellar/adevcontainer/1.0.0/bin/adevcontainer"
        try MiniTest.expectThrows({
            try PluginTestSupport.installPlugin(installRoot: root, currentExecutablePath: unformable)
        }) { error in
            let err = error as! CLIError
            try MiniTest.expect(
                err.message.contains("opt/adevcontainer/bin/adevcontainer"),
                "names the opt path that could not be formed"
            )
            try MiniTest.expect(!err.message.contains("linked \(unformable)"), "does not offer the Cellar path as the link")
        }
        let binaryPath = ContainerPluginLayout.binaryPath(installRoot: root.path)
        try MiniTest.expect(!FileManager.default.fileExists(atPath: binaryPath), "does not create a Cellar-path symlink")
        try MiniTest.expect(
            (try? FileManager.default.destinationOfSymbolicLink(atPath: binaryPath)) == nil,
            "does not create a realpath-resolved symlink"
        )
    }),

    ("pluginInstallNonHomebrewDoesNotRealpath", {
        let root = try PluginTestSupport.makeInstallRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let real = root.appendingPathComponent("real/adevcontainer")
        try PluginTestSupport.writeExecutable(at: real, contents: Data("real-bytes\n".utf8))
        let link = root.appendingPathComponent("linked/adevcontainer")
        try FileManager.default.createDirectory(at: link.deletingLastPathComponent(), withIntermediateDirectories: true)
        try FileManager.default.createSymbolicLink(atPath: link.path, withDestinationPath: real.path)
        try PluginTestSupport.installPlugin(installRoot: root, currentExecutablePath: link.path)
        let binaryPath = ContainerPluginLayout.binaryPath(installRoot: root.path)
        try PluginTestSupport.expectSymlink(at: binaryPath, target: link.path, "does not realpath the running executable")
        try MiniTest.expect(
            try FileManager.default.destinationOfSymbolicLink(atPath: binaryPath) != real.path,
            "symlink target is not the resolved path"
        )
    }),

    ("pluginInstallBareArgv0IsNotRelativeSourcePath", {
        let root = try PluginTestSupport.makeInstallRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let cwd = FileManager.default.temporaryDirectory
            .appendingPathComponent("adev-bare-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: cwd, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: cwd) }
        let previousCwd = FileManager.default.currentDirectoryPath
        try MiniTest.expect(FileManager.default.changeCurrentDirectoryPath(cwd.path))
        defer { FileManager.default.changeCurrentDirectoryPath(previousCwd) }
        try MiniTest.expect(!FileManager.default.fileExists(atPath: cwd.appendingPathComponent("adevcontainer").path))
        let running = root.appendingPathComponent("running/adevcontainer")
        try PluginTestSupport.writeExecutable(at: running, contents: Data("running-abs\n".utf8))
        try PluginTestSupport.installPlugin(
            installRoot: root,
            currentExecutablePath: "adevcontainer",
            runningExecutablePath: running.path,
            pathEnvironment: ""
        )
        let binaryPath = ContainerPluginLayout.binaryPath(installRoot: root.path)
        try PluginTestSupport.expectSymlink(at: binaryPath, target: running.path, "bare argv0 uses the absolute running path")
        try MiniTest.expect(
            try FileManager.default.destinationOfSymbolicLink(atPath: binaryPath) != "adevcontainer"
        )
        try MiniTest.expect(
            !FileManager.default.fileExists(atPath: cwd.appendingPathComponent("adevcontainer").path),
            "does not create a relative argv0 file in cwd"
        )
    }),

    ("pluginInstallBareArgv0UsesPathCandidateWithoutRealpath", {
        let root = try PluginTestSupport.makeInstallRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let real = root.appendingPathComponent("real/adevcontainer")
        try PluginTestSupport.writeExecutable(at: real)
        let pathDir = root.appendingPathComponent("path-bin", isDirectory: true)
        try FileManager.default.createDirectory(at: pathDir, withIntermediateDirectories: true)
        let onPath = pathDir.appendingPathComponent("adevcontainer")
        try FileManager.default.createSymbolicLink(atPath: onPath.path, withDestinationPath: real.path)
        try PluginTestSupport.installPlugin(
            installRoot: root,
            currentExecutablePath: "adevcontainer",
            runningExecutablePath: root.appendingPathComponent("no-such-running").path,
            pathEnvironment: pathDir.path
        )
        let binaryPath = ContainerPluginLayout.binaryPath(installRoot: root.path)
        try PluginTestSupport.expectSymlink(at: binaryPath, target: onPath.path, "PATH hit is not realpath-resolved")
    }),

    ("pluginInstallArgv0PluginPathDoesNotSelfLink", {
        let root = try PluginTestSupport.makeInstallRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let real = root.appendingPathComponent("real/adevcontainer")
        try PluginTestSupport.writeExecutable(at: real, contents: Data("installed-exec\n".utf8))
        let installed = root.appendingPathComponent("linked/adevcontainer")
        try FileManager.default.createDirectory(at: installed.deletingLastPathComponent(), withIntermediateDirectories: true)
        try FileManager.default.createSymbolicLink(atPath: installed.path, withDestinationPath: real.path)
        let binaryPath = ContainerPluginLayout.binaryPath(installRoot: root.path)
        try FileManager.default.createDirectory(
            at: URL(fileURLWithPath: binaryPath).deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try FileManager.default.createSymbolicLink(atPath: binaryPath, withDestinationPath: installed.path)
        let recorder = RemoveRecordingFileManager()
        try PluginTestSupport.installPlugin(
            installRoot: root,
            currentExecutablePath: binaryPath,
            runningExecutablePath: real.path,
            pathEnvironment: "",
            fileManager: recorder
        )
        try PluginTestSupport.expectSymlink(
            at: binaryPath,
            target: installed.path,
            "plugin argv0 keeps the existing absolute link text"
        )
        try MiniTest.expect(
            try FileManager.default.destinationOfSymbolicLink(atPath: binaryPath) != binaryPath,
            "does not symlink bin/dev to itself"
        )
        try MiniTest.expect(
            try FileManager.default.destinationOfSymbolicLink(atPath: binaryPath) != real.path,
            "does not realpath the existing link text"
        )
        try MiniTest.expect(!recorder.removedPaths.contains(binaryPath), "already-correct link is not replaced")
    }),

    ("pluginInstallProcessNameDevDoesNotSelfLink", {
        let root = try PluginTestSupport.makeInstallRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let installed = root.appendingPathComponent("installed/adevcontainer")
        try PluginTestSupport.writeExecutable(at: installed, contents: Data("from-dev-argv0\n".utf8))
        let binaryPath = ContainerPluginLayout.binaryPath(installRoot: root.path)
        try FileManager.default.createDirectory(
            at: URL(fileURLWithPath: binaryPath).deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try FileManager.default.createSymbolicLink(atPath: binaryPath, withDestinationPath: installed.path)
        try PluginTestSupport.installPlugin(
            installRoot: root,
            currentExecutablePath: "dev",
            runningExecutablePath: binaryPath,
            pathEnvironment: ""
        )
        try PluginTestSupport.expectSymlink(
            at: binaryPath,
            target: installed.path,
            "process name dev uses the existing absolute link text"
        )
        try MiniTest.expect(
            try FileManager.default.destinationOfSymbolicLink(atPath: binaryPath) != binaryPath,
            "process name dev does not symlink bin/dev to itself"
        )
    }),

    ("pluginInstallArgv0PluginPathCellarLinkBecomesOptPath", {
        let root = try PluginTestSupport.makeInstallRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let prefix = root.appendingPathComponent("homebrew")
        let bytes = Data("cellar-via-plugin-argv0\n".utf8)
        let formula = try PluginTestSupport.makeHomebrewCellar(prefix: prefix, contents: bytes)
        let binaryPath = ContainerPluginLayout.binaryPath(installRoot: root.path)
        try FileManager.default.createDirectory(
            at: URL(fileURLWithPath: binaryPath).deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try FileManager.default.createSymbolicLink(atPath: binaryPath, withDestinationPath: formula.cellar)
        try PluginTestSupport.installPlugin(
            installRoot: root,
            currentExecutablePath: binaryPath,
            runningExecutablePath: formula.real,
            pathEnvironment: ""
        )
        try PluginTestSupport.expectSymlink(
            at: binaryPath,
            target: formula.opt,
            "Cellar link text becomes the opt path"
        )
        try MiniTest.expect(
            try FileManager.default.destinationOfSymbolicLink(atPath: binaryPath) != formula.cellar
        )
        try MiniTest.expect(
            try FileManager.default.destinationOfSymbolicLink(atPath: binaryPath) != formula.real,
            "does not realpath the keg"
        )
        try MiniTest.expect(
            try FileManager.default.destinationOfSymbolicLink(atPath: binaryPath) != binaryPath
        )
        try MiniTest.expectEqual(try Data(contentsOf: URL(fileURLWithPath: formula.real)), bytes)
        try MiniTest.expect(
            FileManager.default.fileExists(atPath: formula.cellar),
            "Cellar target still exists"
        )
    }),

    ("pluginInstallArgv0PluginPathKeepsOptLink", {
        let root = try PluginTestSupport.makeInstallRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let prefix = root.appendingPathComponent("homebrew")
        let formula = try PluginTestSupport.makeHomebrewCellar(prefix: prefix, contents: Data("opt-kept\n".utf8))
        let optURL = URL(fileURLWithPath: formula.opt)
        try FileManager.default.createDirectory(at: optURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        try FileManager.default.createSymbolicLink(atPath: formula.opt, withDestinationPath: formula.real)
        let binaryPath = ContainerPluginLayout.binaryPath(installRoot: root.path)
        try FileManager.default.createDirectory(
            at: URL(fileURLWithPath: binaryPath).deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try FileManager.default.createSymbolicLink(atPath: binaryPath, withDestinationPath: formula.opt)
        let recorder = RemoveRecordingFileManager()
        try PluginTestSupport.installPlugin(
            installRoot: root,
            currentExecutablePath: binaryPath,
            runningExecutablePath: formula.real,
            pathEnvironment: "",
            fileManager: recorder
        )
        try PluginTestSupport.expectSymlink(at: binaryPath, target: formula.opt, "already-correct opt link is kept")
        try MiniTest.expect(!recorder.removedPaths.contains(binaryPath), "opt link is not replaced")
        try MiniTest.expect(
            try FileManager.default.destinationOfSymbolicLink(atPath: binaryPath) != formula.real
        )
    }),

    ("pluginInstallArgv0PluginPathRegularFileUsesPathAdevcontainer", {
        let root = try PluginTestSupport.makeInstallRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let onPath = root.appendingPathComponent("path-bin/adevcontainer")
        try PluginTestSupport.writeExecutable(at: onPath, contents: Data("path-install\n".utf8))
        try PluginTestSupport.stagePluginLayout(installRoot: root, executableContents: Data("leftover-copy\n".utf8))
        let binaryPath = ContainerPluginLayout.binaryPath(installRoot: root.path)
        try PluginTestSupport.installPlugin(
            installRoot: root,
            currentExecutablePath: binaryPath,
            pathEnvironment: onPath.deletingLastPathComponent().path
        )
        try PluginTestSupport.expectSymlink(
            at: binaryPath,
            target: onPath.path,
            "regular-file plugin binary falls back to PATH adevcontainer"
        )
        try MiniTest.expect(
            try FileManager.default.destinationOfSymbolicLink(atPath: binaryPath) != binaryPath
        )
    }),

    ("pluginInstallArgv0PluginPathSelfSymlinkUsesPathAdevcontainer", {
        let root = try PluginTestSupport.makeInstallRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let onPath = root.appendingPathComponent("path-bin/adevcontainer")
        try PluginTestSupport.writeExecutable(at: onPath, contents: Data("not-self\n".utf8))
        let binaryPath = ContainerPluginLayout.binaryPath(installRoot: root.path)
        try FileManager.default.createDirectory(
            at: URL(fileURLWithPath: binaryPath).deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try FileManager.default.createSymbolicLink(atPath: binaryPath, withDestinationPath: binaryPath)
        try PluginTestSupport.installPlugin(
            installRoot: root,
            currentExecutablePath: binaryPath,
            pathEnvironment: onPath.deletingLastPathComponent().path
        )
        try PluginTestSupport.expectSymlink(
            at: binaryPath,
            target: onPath.path,
            "self-symlink falls back to PATH adevcontainer"
        )
        try MiniTest.expect(
            try FileManager.default.destinationOfSymbolicLink(atPath: binaryPath) != binaryPath
        )
    }),

    ("pluginInstallArgv0PluginPathUsesHomebrewOptBinary", {
        let root = try PluginTestSupport.makeInstallRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let prefix = root.appendingPathComponent("homebrew")
        let formula = try PluginTestSupport.makeHomebrewCellar(prefix: prefix, contents: Data("opt-fallback\n".utf8))
        let optURL = URL(fileURLWithPath: formula.opt)
        try FileManager.default.createDirectory(at: optURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        try FileManager.default.createSymbolicLink(atPath: formula.opt, withDestinationPath: formula.real)
        try PluginTestSupport.stagePluginLayout(installRoot: root, executableContents: Data("leftover\n".utf8))
        let binaryPath = ContainerPluginLayout.binaryPath(installRoot: root.path)
        let brewBin = prefix.appendingPathComponent("bin").path
        try FileManager.default.createDirectory(at: URL(fileURLWithPath: brewBin), withIntermediateDirectories: true)
        try PluginTestSupport.installPlugin(
            installRoot: root,
            currentExecutablePath: binaryPath,
            pathEnvironment: brewBin
        )
        try PluginTestSupport.expectSymlink(
            at: binaryPath,
            target: formula.opt,
            "regular-file plugin binary falls back to the Homebrew opt binary"
        )
        try MiniTest.expect(
            try FileManager.default.destinationOfSymbolicLink(atPath: binaryPath) != formula.real,
            "opt fallback is not the realpath of the keg"
        )
        try MiniTest.expect(
            try FileManager.default.destinationOfSymbolicLink(atPath: binaryPath) != binaryPath
        )
    }),

    ("pluginInstallArgv0PluginPathFailsInsteadOfSelfLink", {
        let root = try PluginTestSupport.makeInstallRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        try PluginTestSupport.stagePluginLayout(installRoot: root, executableContents: Data("only-copy\n".utf8))
        let binaryPath = ContainerPluginLayout.binaryPath(installRoot: root.path)
        try MiniTest.expectThrows({
            try PluginTestSupport.installPlugin(
                installRoot: root,
                currentExecutablePath: binaryPath,
                runningExecutablePath: binaryPath,
                pathEnvironment: ""
            )
        }) { error in
            let err = error as! CLIError
            let hint = err.hint ?? ""
            try MiniTest.expect(err.message.contains(binaryPath), "names the plugin path it refuses to self-link")
            try MiniTest.expect(hint.contains("adevcontainer plugin --install"))
            try MiniTest.expect(!hint.contains("container dev plugin --install"))
        }
        try MiniTest.expect(
            (try? FileManager.default.destinationOfSymbolicLink(atPath: binaryPath)) == nil,
            "does not create a self-symlink"
        )
        try MiniTest.expectEqual(
            try String(contentsOfFile: binaryPath, encoding: .utf8),
            "only-copy\n",
            "leftover copy remains when no other executable can be identified"
        )
    }),

    ("pluginInstallDoesNotMutateSymlinkTarget", {
        let root = try PluginTestSupport.makeInstallRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let source = root.appendingPathComponent("installed/adevcontainer")
        let bytes = Data("immutable-\(UUID().uuidString)\n".utf8)
        try PluginTestSupport.writeExecutable(at: source, contents: bytes)
        try FileManager.default.setAttributes([.posixPermissions: 0o754], ofItemAtPath: source.path)
        let modeBefore = try PluginTestSupport.posixMode(source.path)
        try PluginTestSupport.installPlugin(installRoot: root, currentExecutablePath: source.path)
        let binaryPath = ContainerPluginLayout.binaryPath(installRoot: root.path)
        try PluginTestSupport.expectSymlink(at: binaryPath, target: source.path, "plugin binary is a symlink, not a copy")
        try MiniTest.expectEqual(try Data(contentsOf: source), bytes, "target contents unchanged")
        try MiniTest.expectEqual(try PluginTestSupport.posixMode(source.path), modeBefore, "target mode unchanged")
    }),

    ("pluginInstallElevationHintWhenDestinationNotWritable", {
        let root = try PluginTestSupport.makeInstallRoot()
        defer {
            try? FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: root.path)
            try? FileManager.default.removeItem(at: root)
        }
        try FileManager.default.setAttributes([.posixPermissions: 0o555], ofItemAtPath: root.path)
        let source = PluginTestSupport.containerBinary(in: root)
        try MiniTest.expectThrows({
            try PluginTestSupport.installPlugin(installRoot: root, currentExecutablePath: source)
        }) { error in
            let hint = (error as! CLIError).hint ?? ""
            try MiniTest.expect(hint.contains("sudo"), "names elevated privileges")
            try MiniTest.expect(
                hint.contains("adevcontainer plugin --install"),
                "elevated remediation names PATH adevcontainer plugin --install"
            )
            try MiniTest.expect(!hint.contains("container dev plugin --install"))
            try MiniTest.expect(!hint.contains("install-plugin"))
        }
    }),

    ("doctorMissingPluginElevationHintWhenDestinationNotWritable", {
        let root = try PluginTestSupport.makeInstallRoot()
        defer {
            try? FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: root.path)
            try? FileManager.default.removeItem(at: root)
        }
        try FileManager.default.setAttributes([.posixPermissions: 0o555], ofItemAtPath: root.path)
        let runtime = try PluginTestSupport.readyRuntime(
            executablePath: PluginTestSupport.containerBinary(in: root)
        )
        try MiniTest.expectThrows({
            _ = try DoctorCommand.run(runtime: runtime)
        }) { error in
            let hint = (error as! CLIError).hint ?? ""
            try MiniTest.expect(hint.contains("sudo"), "missing plugin names elevation when required")
            try MiniTest.expect(hint.contains("adevcontainer plugin --install"))
            try MiniTest.expect(!hint.contains("container dev plugin --install"))
            try MiniTest.expect(!hint.contains("install-plugin"))
        }
    }),

    ("pluginInstallMissingSourceDoesNotHintSudo", {
        let root = try PluginTestSupport.makeInstallRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let missing = root.appendingPathComponent("no-such-adevcontainer-\(UUID().uuidString)")
        try MiniTest.expectThrows({
            try PluginTestSupport.installPlugin(installRoot: root, currentExecutablePath: missing.path)
        }) { error in
            let err = error as! CLIError
            let hint = err.hint ?? ""
            try MiniTest.expect(err.message.contains(missing.path), "names the resolved source path")
            try MiniTest.expect(!err.message.contains("couldn't open"), "does not claim a basename-only open error")
            try MiniTest.expect(!hint.contains("sudo"), "missing source is not an elevation failure")
            try MiniTest.expect(!hint.contains("plugin --install"), "missing source is not fixed by restaging")
            try MiniTest.expect(!hint.contains("install-plugin"))
        }
    }),

    ("pluginInstallUnresolvableBareArgv0NamesUsablePath", {
        let root = try PluginTestSupport.makeInstallRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let cwd = FileManager.default.temporaryDirectory
            .appendingPathComponent("adev-missing-argv0-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: cwd, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: cwd) }
        let previousCwd = FileManager.default.currentDirectoryPath
        try MiniTest.expect(FileManager.default.changeCurrentDirectoryPath(cwd.path))
        defer { FileManager.default.changeCurrentDirectoryPath(previousCwd) }
        let missingRunning = root.appendingPathComponent("no-such-running-\(UUID().uuidString)")
        try MiniTest.expectThrows({
            try PluginTestSupport.installPlugin(
                installRoot: root,
                currentExecutablePath: "adevcontainer",
                runningExecutablePath: missingRunning.path,
                pathEnvironment: ""
            )
        }) { error in
            let err = error as! CLIError
            let hint = err.hint ?? ""
            try MiniTest.expect(err.message.contains(missingRunning.path), "names a usable resolved path, not the bare argv0")
            try MiniTest.expect(!err.message.contains("not found at adevcontainer"), "does not use the bare name as the path")
            try MiniTest.expect(!err.message.contains("couldn't open"))
            try MiniTest.expect(!hint.contains("install-plugin"))
        }
        let binaryPath = ContainerPluginLayout.binaryPath(installRoot: root.path)
        try MiniTest.expect(
            (try? FileManager.default.destinationOfSymbolicLink(atPath: binaryPath)) == nil,
            "does not create a relative symlink"
        )
    }),

    ("pluginUninstallRemovesLayoutEntriesOnly", {
        let root = try PluginTestSupport.makeInstallRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let target = root.appendingPathComponent("installed/adevcontainer")
        try PluginTestSupport.writeExecutable(at: target, contents: Data("survives-uninstall\n".utf8))
        let pluginDir = root.appendingPathComponent("libexec/container-plugins/dev")
        let binDir = pluginDir.appendingPathComponent("bin", isDirectory: true)
        try FileManager.default.createDirectory(at: binDir, withIntermediateDirectories: true)
        let binaryPath = ContainerPluginLayout.binaryPath(installRoot: root.path)
        try FileManager.default.createSymbolicLink(atPath: binaryPath, withDestinationPath: target.path)
        try ContainerPluginLayout.configTOML.write(
            to: pluginDir.appendingPathComponent("config.toml"),
            atomically: true,
            encoding: .utf8
        )
        let other = pluginDir.appendingPathComponent("notes.txt")
        try Data("keep-me\n".utf8).write(to: other)
        try PluginTestSupport.uninstallPlugin(installRoot: root)
        try MiniTest.expect(!FileManager.default.fileExists(atPath: binaryPath), "bin/dev removed")
        try MiniTest.expect(
            (try? FileManager.default.destinationOfSymbolicLink(atPath: binaryPath)) == nil,
            "bin/dev symlink removed"
        )
        try MiniTest.expect(
            !FileManager.default.fileExists(atPath: ContainerPluginLayout.configPath(installRoot: root.path)),
            "config.toml removed"
        )
        try MiniTest.expectEqual(
            try String(contentsOfFile: target.path, encoding: .utf8),
            "survives-uninstall\n",
            "symlink target still exists"
        )
        try MiniTest.expectEqual(try String(contentsOfFile: other.path, encoding: .utf8), "keep-me\n")
        try MiniTest.expect(FileManager.default.fileExists(atPath: pluginDir.path), "plugin directory remains")
    }),

    ("pluginUninstallRemovesLeftoverCopyWithoutDeletingKeg", {
        let root = try PluginTestSupport.makeInstallRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let prefix = root.appendingPathComponent("homebrew")
        let formula = try PluginTestSupport.makeHomebrewCellar(prefix: prefix, contents: Data("keg-stays\n".utf8))
        let optURL = URL(fileURLWithPath: formula.opt)
        try PluginTestSupport.writeExecutable(at: optURL, contents: Data("opt-stays\n".utf8))
        try PluginTestSupport.stagePluginLayout(installRoot: root, executableContents: Data("leftover-copy\n".utf8))
        try PluginTestSupport.uninstallPlugin(installRoot: root)
        let binaryPath = ContainerPluginLayout.binaryPath(installRoot: root.path)
        try MiniTest.expect(!FileManager.default.fileExists(atPath: binaryPath), "leftover copy removed")
        try MiniTest.expect(
            !FileManager.default.fileExists(atPath: ContainerPluginLayout.configPath(installRoot: root.path))
        )
        try MiniTest.expectEqual(try Data(contentsOf: URL(fileURLWithPath: formula.real)), Data("keg-stays\n".utf8))
        try MiniTest.expectEqual(try Data(contentsOf: optURL), Data("opt-stays\n".utf8))
    }),

    ("pluginUninstallSucceedsWhenLayoutMissing", {
        let root = try PluginTestSupport.makeInstallRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let pluginDir = ContainerPluginLayout.pluginDirectory(installRoot: root.path)
        try MiniTest.expect(!FileManager.default.fileExists(atPath: pluginDir))
        try PluginTestSupport.uninstallPlugin(installRoot: root)
        try MiniTest.expect(!FileManager.default.fileExists(atPath: pluginDir), "uninstall does not create the layout")
    }),

    ("pluginUninstallRemovesConfigSymlinkWithoutDeletingTarget", {
        let root = try PluginTestSupport.makeInstallRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let secret = root.appendingPathComponent("secret-config.toml")
        try Data("SECRET-CONFIG\n".utf8).write(to: secret)
        let configPath = ContainerPluginLayout.configPath(installRoot: root.path)
        try FileManager.default.createDirectory(
            at: URL(fileURLWithPath: configPath).deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try FileManager.default.createSymbolicLink(atPath: configPath, withDestinationPath: secret.path)
        try PluginTestSupport.uninstallPlugin(installRoot: root)
        try MiniTest.expect(
            (try? FileManager.default.destinationOfSymbolicLink(atPath: configPath)) == nil,
            "config.toml symlink unlinked"
        )
        try MiniTest.expect(!FileManager.default.fileExists(atPath: configPath))
        try MiniTest.expectEqual(try String(contentsOfFile: secret.path, encoding: .utf8), "SECRET-CONFIG\n")
    }),

    ("pluginUninstallElevationHintWhenDestinationNotWritable", {
        let root = try PluginTestSupport.makeInstallRoot()
        let pluginDir = root.appendingPathComponent("libexec/container-plugins/dev").path
        let binDir = (pluginDir as NSString).appendingPathComponent("bin")
        defer {
            try? FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: binDir)
            try? FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: pluginDir)
            try? FileManager.default.removeItem(at: root)
        }
        try PluginTestSupport.stagePluginLayout(installRoot: root)
        try FileManager.default.setAttributes([.posixPermissions: 0o555], ofItemAtPath: binDir)
        try FileManager.default.setAttributes([.posixPermissions: 0o555], ofItemAtPath: pluginDir)
        try MiniTest.expectThrows({
            try PluginTestSupport.uninstallPlugin(installRoot: root)
        }) { error in
            let hint = (error as! CLIError).hint ?? ""
            try MiniTest.expect(hint.contains("sudo"))
            try MiniTest.expect(
                hint.contains("adevcontainer plugin --uninstall"),
                "elevated remediation names PATH adevcontainer plugin --uninstall"
            )
            try MiniTest.expect(!hint.contains("container dev plugin --uninstall"))
            try MiniTest.expect(!hint.contains("install-plugin"))
        }
    }),

    ("doctorAcceptsSymlinkLayoutAsPresent", {
        let root = try PluginTestSupport.makeInstallRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let target = root.appendingPathComponent("installed/adevcontainer")
        try PluginTestSupport.writeExecutable(at: target)
        let pluginDir = root.appendingPathComponent("libexec/container-plugins/dev")
        let binDir = pluginDir.appendingPathComponent("bin", isDirectory: true)
        try FileManager.default.createDirectory(at: binDir, withIntermediateDirectories: true)
        try ContainerPluginLayout.configTOML.write(
            to: pluginDir.appendingPathComponent("config.toml"),
            atomically: true,
            encoding: .utf8
        )
        let binaryPath = ContainerPluginLayout.binaryPath(installRoot: root.path)
        try FileManager.default.createSymbolicLink(atPath: binaryPath, withDestinationPath: target.path)
        let runtime = try PluginTestSupport.readyRuntime(
            executablePath: PluginTestSupport.containerBinary(in: root)
        )
        let report = try DoctorCommand.run(runtime: runtime)
        try MiniTest.expect(report.ok)
        try PluginTestSupport.expectSymlink(at: binaryPath, target: target.path, "doctor does not replace a symlink layout")
    }),

    ("doctorWithoutWorkspaceConfigStillRunsWhenPluginPresent", {
        let root = try PluginTestSupport.makeInstallRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        try PluginTestSupport.stagePluginLayout(installRoot: root)
        let empty = FileManager.default.temporaryDirectory
            .appendingPathComponent("adev-noconfig-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: empty, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: empty) }
        try MiniTest.expect(
            !FileManager.default.fileExists(atPath: empty.appendingPathComponent("devcontainer.json").path)
        )
        try MiniTest.expect(
            !FileManager.default.fileExists(
                atPath: empty.appendingPathComponent(".devcontainer/devcontainer.json").path
            )
        )
        let runtime = try PluginTestSupport.readyRuntime(
            executablePath: PluginTestSupport.containerBinary(in: root)
        )
        let report = try DoctorCommand.run(runtime: runtime)
        try MiniTest.expect(report.ok)
        try MiniTest.expectEqual(report.binaryPath, PluginTestSupport.containerBinary(in: root))
        try MiniTest.expect(report.version?.contains("1.2.1") == true)
    }),

    ("lifecycleUpDoesNotRestageMissingPlugin", {
        let root = try PluginTestSupport.makeInstallRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let workspace = try TestRepo.makeTempWorkspace(configJSON: #"{ "image": "alpine:3.20" }"#)
        defer { try? FileManager.default.removeItem(at: workspace) }
        let resolved = try ConfigResolver.resolve(workspacePath: workspace.path, localEnv: [:])
        let mock = MockProcessRunner()
        mock.handlers = [
            { args in
                if args.starts(with: ["list"]) {
                    return ProcessResult(exitCode: 0, stdout: Data("[]".utf8), stderr: Data())
                }
                return nil
            },
            MockProcessRunner.imageInspectHandler(baseUser: nil),
            { args in
                if args.first == "create" {
                    return ProcessResult(
                        exitCode: 0,
                        stdout: Data("\(resolved.containerName)\n".utf8),
                        stderr: Data()
                    )
                }
                if args.first == "start" || args.first == "delete" || args.first == "exec" {
                    return ProcessResult(exitCode: 0, stdout: Data(), stderr: Data())
                }
                return nil
            }
        ]
        let runtime = AppleContainerRuntime(
            executablePath: PluginTestSupport.containerBinary(in: root),
            runner: mock
        )
        _ = try UpCommand.run(
            options: UpOptions(workspacePath: workspace.path, skipPull: true),
            runtime: runtime,
            localEnv: [:],
            credentials: SeedMockCredential()
        )
        let configPath = ContainerPluginLayout.configPath(installRoot: root.path)
        let binaryPath = ContainerPluginLayout.binaryPath(installRoot: root.path)
        try MiniTest.expect(!FileManager.default.fileExists(atPath: configPath), "up does not write config.toml")
        try MiniTest.expect(!FileManager.default.fileExists(atPath: binaryPath), "up does not create a plugin symlink")
    }),

    ("connectionHintsFollowInvocationPrefix", {
        let previousEnabled = StatusPrinter.enabled
        let previousWrite = StatusPrinter.writeStderr
        defer {
            StatusPrinter.enabled = previousEnabled
            StatusPrinter.writeStderr = previousWrite
            CommandSurface.commandPrefix = CommandSurface.pathBinaryName
        }
        var buffer = Data()
        StatusPrinter.writeStderr = { buffer.append($0) }
        StatusPrinter.enabled = true
        CommandSurface.commandPrefix = CommandSurface.pluginInvocationPrefix
        StatusPrinter.connectionHint(nameOrId: "ctr")
        let out = String(data: buffer, encoding: .utf8) ?? ""
        try MiniTest.expect(out.contains("container dev exec -it --name ctr"))
        try MiniTest.expect(out.contains("container dev start --name ctr --vscode"))
        try MiniTest.expect(!out.contains("adevcontainer exec"))
    })
]
