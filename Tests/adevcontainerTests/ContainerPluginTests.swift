import Foundation
@testable import ADevContainerLib

final class PluginTestFileManager: FileManager, @unchecked Sendable {
    var executablePaths: Set<String> = []

    override func isExecutableFile(atPath path: String) -> Bool {
        executablePaths.contains(path)
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
            try MiniTest.expect(doctor.contains("--repair"), "doctor help documents --repair")
            let hint = ContainerIdentity.nameInUseError(name: "ctr").hint ?? ""
            try MiniTest.expect(hint.contains("container dev delete --name ctr"), "retry hint uses plugin prefix")
            try MiniTest.expect(
                !hint.contains("container dev doctor --repair"),
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
            try MiniTest.expect(doctor.contains("--repair"), "doctor help documents --repair")
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

    ("repairFlagParsesAndIsDoctorOnly", {
        let parsed = try CommandSurface.parseArgs(["--repair"])
        try MiniTest.expect(parsed.flags.contains("repair"))
        try CommandSurface.enforceWorkspaceGate(subcommand: "doctor", parsed: parsed)
        try MiniTest.expectThrows({
            try CommandSurface.enforceWorkspaceGate(subcommand: "up", parsed: parsed)
        }) { error in
            let err = error as! CLIError
            try MiniTest.expectEqual(err.code, CLIErrorCode.usage)
            try MiniTest.expectEqual(err.property, "--repair")
        }
        try MiniTest.expectThrows({
            try CommandSurface.enforceWorkspaceGate(subcommand: "clone", parsed: parsed)
        }) { error in
            try MiniTest.expectEqual((error as! CLIError).code, CLIErrorCode.usage)
        }
    }),

    ("doctorMissingPluginReportsPathRepairNotPluginRepair", {
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
                hint.contains("adevcontainer doctor --repair"),
                "PATH remediation for a missing plugin"
            )
            try MiniTest.expect(
                !hint.contains("container dev doctor --repair"),
                "must not suggest plugin invocation when the plugin is missing"
            )
        }
        let pluginDir = ContainerPluginLayout.pluginDirectory(installRoot: root.path)
        try MiniTest.expect(!FileManager.default.fileExists(atPath: pluginDir), "doctor without --repair does not restage")
    }),

    ("doctorRepairStagesPluginLayoutAndSameMachO", {
        let root = try PluginTestSupport.makeInstallRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let sourceBytes = Data("same-mach-o-\(UUID().uuidString)\n".utf8)
        let source = root.appendingPathComponent("adevcontainer-src")
        try sourceBytes.write(to: source)
        let runtime = try PluginTestSupport.readyRuntime(
            executablePath: PluginTestSupport.containerBinary(in: root)
        )
        let report = try DoctorCommand.run(
            runtime: runtime,
            repair: true,
            currentExecutablePath: source.path
        )
        try MiniTest.expect(report.ok)
        try MiniTest.expectEqual(report.binaryPath, PluginTestSupport.containerBinary(in: root))
        try MiniTest.expect(report.version?.contains("1.2.1") == true)

        let configPath = ContainerPluginLayout.configPath(installRoot: root.path)
        let binaryPath = ContainerPluginLayout.binaryPath(installRoot: root.path)
        try MiniTest.expect(FileManager.default.fileExists(atPath: configPath), "config.toml staged")
        try MiniTest.expect(FileManager.default.isExecutableFile(atPath: binaryPath), "plugin binary staged executable")
        let toml = try String(contentsOfFile: configPath, encoding: .utf8)
        try MiniTest.expect(toml.contains("abstract"), "config.toml includes abstract")
        try MiniTest.expect(!toml.contains("[servicesConfig]"), "config.toml omits [servicesConfig]")
        try MiniTest.expect(!toml.contains("servicesConfig"), "config.toml omits servicesConfig")
        let staged = try Data(contentsOf: URL(fileURLWithPath: binaryPath))
        try MiniTest.expectEqual(staged, sourceBytes)
    }),

    ("doctorRepairDoesNotUnlinkSelfWhenSourceIsDest", {
        let root = try PluginTestSupport.makeInstallRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let bytes = Data("plugin-self-\(UUID().uuidString)\n".utf8)
        try PluginTestSupport.stagePluginLayout(installRoot: root, executableContents: bytes)
        let dest = ContainerPluginLayout.binaryPath(installRoot: root.path)
        let configPath = ContainerPluginLayout.configPath(installRoot: root.path)
        try FileManager.default.removeItem(atPath: configPath)
        let runtime = try PluginTestSupport.readyRuntime(
            executablePath: PluginTestSupport.containerBinary(in: root)
        )
        let report = try DoctorCommand.run(
            runtime: runtime,
            repair: true,
            currentExecutablePath: dest
        )
        try MiniTest.expect(report.ok)
        try MiniTest.expect(
            FileManager.default.isExecutableFile(atPath: dest),
            "plugin binary still present after plugin-invoked --repair"
        )
        let staged = try Data(contentsOf: URL(fileURLWithPath: dest))
        try MiniTest.expectEqual(staged, bytes)
        try MiniTest.expect(
            FileManager.default.fileExists(atPath: configPath),
            "config.toml written without unlinking the running plugin"
        )
        let toml = try String(contentsOfFile: configPath, encoding: .utf8)
        try MiniTest.expect(toml.contains("abstract"))
        try MiniTest.expect(!toml.contains("[servicesConfig]"))
    }),

    ("doctorRepairElevationHintWhenDestinationNotWritable", {
        let root = try PluginTestSupport.makeInstallRoot()
        defer {
            try? FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: root.path)
            try? FileManager.default.removeItem(at: root)
        }
        try FileManager.default.setAttributes([.posixPermissions: 0o555], ofItemAtPath: root.path)
        let source = root.appendingPathComponent("bin/container")
        let runtime = try PluginTestSupport.readyRuntime(executablePath: source.path)
        try MiniTest.expectThrows({
            _ = try DoctorCommand.run(
                runtime: runtime,
                repair: true,
                currentExecutablePath: source.path
            )
        }) { error in
            let hint = (error as! CLIError).hint ?? ""
            try MiniTest.expect(hint.contains("sudo"), "names elevated privileges")
            try MiniTest.expect(
                hint.contains("adevcontainer doctor --repair"),
                "elevated remediation still names PATH doctor --repair"
            )
            try MiniTest.expect(!hint.contains("container dev doctor --repair"))
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
            try MiniTest.expect(hint.contains("adevcontainer doctor --repair"))
            try MiniTest.expect(!hint.contains("container dev doctor --repair"))
        }
    }),

    ("doctorRepairMissingSourceDoesNotHintSudo", {
        let root = try PluginTestSupport.makeInstallRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let runtime = try PluginTestSupport.readyRuntime(
            executablePath: PluginTestSupport.containerBinary(in: root)
        )
        let missing = root.appendingPathComponent("no-such-adevcontainer-\(UUID().uuidString)")
        try MiniTest.expectThrows({
            _ = try DoctorCommand.run(
                runtime: runtime,
                repair: true,
                currentExecutablePath: missing.path
            )
        }) { error in
            let hint = (error as! CLIError).hint ?? ""
            try MiniTest.expect(
                !hint.contains("sudo"),
                "missing source is not an elevation failure"
            )
            try MiniTest.expect(
                hint.contains("adevcontainer doctor --repair"),
                "still names PATH doctor --repair"
            )
            try MiniTest.expect(!hint.contains("container dev doctor --repair"))
        }
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
        try MiniTest.expect(!FileManager.default.fileExists(atPath: binaryPath), "up does not copy plugin binary")
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
