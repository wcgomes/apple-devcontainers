import Foundation
@testable import ADevContainerLib

// MARK: - Shared helpers (also used by later rebuild sections)

func rebuildErrorCode(_ error: Error) -> String? {
    (error as? CLIError)?.code
}

/// Executed `container` CLI argument lists (executable excluded).
func rebuildCalls(in mock: MockProcessRunner) -> [[String]] {
    mock.calls.map(\.arguments)
}

func rebuildAssertUsageError(_ error: Error) throws {
    try MiniTest.expectEqual(rebuildErrorCode(error), CLIErrorCode.usage)
}

nonisolated(unsafe) let rebuildCommandTests: [(String, () throws -> Void)] = [
    // ---- 2.1 flag parsing ----

    ("rebuildFlagsParseWithDefaults", {
        let parsed = try CommandSurface.parseArgs([])
        let opts = parsed.rebuildOptions()
        try MiniTest.expectEqual(opts.name, nil)
        try MiniTest.expectEqual(opts.skipPull, false)
        try MiniTest.expectEqual(opts.openVSCode, false)
        try MiniTest.expectEqual(opts.jsonOutput, false)
    }),

    ("rebuildFlagsParseAllFlags", {
        let parsed = try CommandSurface.parseArgs(["--name", "c1", "--skip-pull", "--vscode", "--json"])
        let opts = parsed.rebuildOptions()
        try MiniTest.expectEqual(opts.name, "c1")
        try MiniTest.expectEqual(opts.skipPull, true)
        try MiniTest.expectEqual(opts.openVSCode, true)
        try MiniTest.expectEqual(opts.jsonOutput, true)
    }),

    ("rebuildFlagsParseNameEqualsForm", {
        let parsed = try CommandSurface.parseArgs(["--name=abc", "--json"])
        let opts = parsed.rebuildOptions()
        try MiniTest.expectEqual(opts.name, "abc")
        try MiniTest.expectEqual(opts.jsonOutput, true)
    }),

    // ---- 2.2 -w gate + unknown flags ----

    ("rebuildRejectsWorkspaceFlagViaGlobalGate", {
        let parsed = try CommandSurface.parseArgs(["-w", "/tmp/x"])
        try MiniTest.expectThrows({
            try CommandSurface.enforceWorkspaceGate(subcommand: "rebuild", parsed: parsed)
        }, validate: { err in
            try rebuildAssertUsageError(err)
            try MiniTest.expect((err as? CLIError)?.message.contains("only valid for up") == true, "gate wording")
        })
    }),

    ("rebuildRejectsUnknownFlagFailsClosed", {
        try MiniTest.expectThrows({
            _ = try CommandSurface.parseArgs(["--bogus"])
        }, validate: { err in
            try rebuildAssertUsageError(err)
        })
    }),

    ("workspaceGateAllowsUpOnly", {
        let up = try CommandSurface.parseArgs(["-w", "/tmp/x"])
        try CommandSurface.enforceWorkspaceGate(subcommand: "up", parsed: up) // no throw
        let start = try CommandSurface.parseArgs(["-w", "/tmp/x"])
        try MiniTest.expectThrows({
            try CommandSurface.enforceWorkspaceGate(subcommand: "start", parsed: start)
        }, validate: { err in
            try rebuildAssertUsageError(err)
        })
    }),

    // ---- 2.3 usage + help ----

    ("rebuildAfterEditingNameUsesNewCreateName", {
        let ws = try TestRepo.makeTempWorkspace(configJSON: """
        {
          "name": "Other App",
          "image": "alpine:3.20",
          "remoteUser": "vscode",
          "mounts": ["source=team-cache,target=/cache,type=volume"]
        }
        """)
        defer { try? FileManager.default.removeItem(at: ws) }
        let s = RebuildScenario()
        let oldName = "my-app"
        let selected = RebuildScenario.container(
            id: oldName,
            labels: s.bindLabels(
                localFolder: ws.path,
                configFile: ws.appendingPathComponent(".devcontainer/devcontainer.json").path
            )
        )
        s.containers = [selected]
        s.volumes = ["team-cache"]
        s.newContainerId = "other-app"
        s.install()
        let result = try RebuildCommand.run(
            options: RebuildOptions(name: oldName, skipPull: true),
            runtime: s.runtime
        )
        try MiniTest.expectEqual(result.containerName, "other-app")
        let createArgs = s.mock.calls.first { $0.arguments.first == "create" }?.arguments ?? []
        if let idx = createArgs.firstIndex(of: "--name"), idx + 1 < createArgs.count {
            try MiniTest.expectEqual(createArgs[idx + 1], "other-app")
        } else {
            try MiniTest.expect(false, "expected create --name other-app")
        }
        try MiniTest.expect(createArgs.contains { $0.contains("source=team-cache") })
        try MiniTest.expect(s.mock.calls.contains { $0.arguments.first == "delete" && $0.arguments.contains(oldName) })
        try MiniTest.expect(!s.mock.calls.contains { $0.arguments.starts(with: ["volume", "delete"]) })
        let deleteIdx = s.mock.calls.firstIndex { $0.arguments.first == "delete" && $0.arguments.contains(oldName) }
        let createIdx = s.mock.calls.firstIndex { $0.arguments.first == "create" }
        try MiniTest.expect(deleteIdx != nil && createIdx != nil && deleteIdx! < createIdx!)
    }),

    ("rebuildMigratesAdevNameToShortComputedName", {
        let ws = try TestRepo.makeTempWorkspace(configJSON: """
        { "name": "My App", "image": "alpine:3.20", "remoteUser": "vscode" }
        """)
        defer { try? FileManager.default.removeItem(at: ws) }
        let s = RebuildScenario()
        let oldName = "adev-myapp-abc123def456"
        let selected = RebuildScenario.container(
            id: oldName,
            labels: s.bindLabels(
                localFolder: ws.path,
                configFile: ws.appendingPathComponent(".devcontainer/devcontainer.json").path
            )
        )
        s.containers = [selected]
        s.newContainerId = "my-app"
        s.install()
        let result = try RebuildCommand.run(
            options: RebuildOptions(name: oldName, skipPull: true),
            runtime: s.runtime
        )
        try MiniTest.expectEqual(result.containerName, "my-app")
        let createArgs = s.mock.calls.first { $0.arguments.first == "create" }?.arguments ?? []
        if let idx = createArgs.firstIndex(of: "--name"), idx + 1 < createArgs.count {
            try MiniTest.expectEqual(createArgs[idx + 1], "my-app")
        } else {
            try MiniTest.expect(false, "expected create --name my-app")
        }
        try MiniTest.expect(s.mock.calls.contains { $0.arguments.first == "delete" && $0.arguments.contains(oldName) })
        try MiniTest.expect(!createArgs.contains(oldName) || createArgs.contains("my-app"))
    }),

    ("rebuildSameComputedNameIsUnchanged", {
        let ws = try TestRepo.makeTempWorkspace(configJSON: """
        { "name": "My App", "image": "alpine:3.20", "remoteUser": "vscode" }
        """)
        defer { try? FileManager.default.removeItem(at: ws) }
        let s = RebuildScenario()
        let selected = RebuildScenario.container(
            id: "my-app",
            labels: s.bindLabels(
                localFolder: ws.path,
                configFile: ws.appendingPathComponent(".devcontainer/devcontainer.json").path
            )
        )
        s.containers = [selected]
        s.newContainerId = "my-app"
        s.install()
        let result = try RebuildCommand.run(
            options: RebuildOptions(name: "my-app", skipPull: true),
            runtime: s.runtime
        )
        try MiniTest.expectEqual(result.containerName, "my-app")
        let createArgs = s.mock.calls.first { $0.arguments.first == "create" }?.arguments ?? []
        if let idx = createArgs.firstIndex(of: "--name"), idx + 1 < createArgs.count {
            try MiniTest.expectEqual(createArgs[idx + 1], "my-app")
        } else {
            try MiniTest.expect(false, "expected same-name rebuild")
        }
        try MiniTest.expect(s.mock.calls.contains { $0.arguments.first == "delete" && $0.arguments.contains("my-app") })
    }),

    ("rebuildForeignOccupantDoesNotDeleteSelected", {
        let ws = try TestRepo.makeTempWorkspace(configJSON: """
        { "name": "My App", "image": "alpine:3.20", "remoteUser": "vscode" }
        """)
        defer { try? FileManager.default.removeItem(at: ws) }
        let s = RebuildScenario()
        let oldName = "adev-myapp-abc123def456"
        let selected = RebuildScenario.container(
            id: oldName,
            labels: s.bindLabels(
                localFolder: ws.path,
                configFile: ws.appendingPathComponent(".devcontainer/devcontainer.json").path
            )
        )
        let occupant = RebuildScenario.container(
            id: "my-app",
            labels: [
                ContainerIdentity.labelManaged: ContainerIdentity.managedValue,
                ContainerIdentity.labelWorkspaceMode: ContainerIdentity.workspaceModeBind,
                ContainerIdentity.labelLocalFolder: "/other/ws",
                ContainerIdentity.labelConfigFile: "/other/ws/.devcontainer/devcontainer.json"
            ]
        )
        s.containers = [selected, occupant]
        s.install()
        try MiniTest.expectThrows({
            _ = try RebuildCommand.run(
                options: RebuildOptions(name: oldName, skipPull: true, jsonOutput: true),
                runtime: s.runtime,
                isTTY: true
            )
        }) { error in
            let err = error as! CLIError
            try MiniTest.expectEqual(err.code, CLIErrorCode.containerNameInUse)
            try MiniTest.expect(err.hint?.contains("rebuild") == true)
        }
        try MiniTest.expect(!s.mock.calls.contains { $0.arguments.first == "delete" })
        try MiniTest.expect(!s.mock.calls.contains { $0.arguments.first == "create" })
        try MiniTest.expect(s.containers.contains { $0.id == oldName })
        try MiniTest.expect(s.containers.contains { $0.id == "my-app" })
    }),

    ("rebuildTTYForeignOccupantRenamesWithoutDeletingSelectedUntilOccupiable", {
        let ws = try TestRepo.makeTempWorkspace(configJSON: """
        { "name": "My App", "image": "alpine:3.20", "remoteUser": "vscode" }
        """)
        defer { try? FileManager.default.removeItem(at: ws) }
        let s = RebuildScenario()
        let oldName = "adev-myapp-abc123def456"
        let cfg = ws.appendingPathComponent(".devcontainer/devcontainer.json").path
        let selected = RebuildScenario.container(
            id: oldName,
            labels: s.bindLabels(localFolder: ws.path, configFile: cfg)
        )
        let occupant = RebuildScenario.container(
            id: "my-app",
            labels: [
                ContainerIdentity.labelLocalFolder: "/other/ws",
                ContainerIdentity.labelConfigFile: "/other/ws/.devcontainer/devcontainer.json"
            ]
        )
        s.containers = [selected, occupant]
        s.newContainerId = "free-name"
        s.install()
        final class Box: @unchecked Sendable {
            var remaining: [String] = ["y", "free-name"]
            var lines: [String] = []
        }
        let box = Box()
        let result = try RebuildCommand.run(
            options: RebuildOptions(name: oldName, skipPull: true),
            runtime: s.runtime,
            isTTY: true,
            openEditorPrompt: RecoveryOpenEditorPrompt(
                readLine: {
                    if box.remaining.isEmpty { return nil }
                    return box.remaining.removeFirst()
                },
                writeError: { box.lines.append($0) }
            )
        )
        try MiniTest.expectEqual(result.containerName, "free-name")
        let joined = box.lines.joined()
        try MiniTest.expect(joined.contains("not this workspace"))
        try MiniTest.expect(joined.contains(BringUpRecovery.changeNamePromptText))
        try MiniTest.expect(!s.mock.calls.contains { $0.arguments.first == "delete" && $0.arguments.contains("my-app") })
        try MiniTest.expect(s.mock.calls.contains { $0.arguments.first == "delete" && $0.arguments.contains(oldName) })
        let host = try String(contentsOfFile: cfg, encoding: .utf8)
        try MiniTest.expect(host.contains("free-name"))
        let createArgs = s.mock.calls.first { $0.arguments.first == "create" }?.arguments ?? []
        if let idx = createArgs.firstIndex(of: "--name"), idx + 1 < createArgs.count {
            try MiniTest.expectEqual(createArgs[idx + 1], "free-name")
        } else {
            try MiniTest.expect(false, "expected create --name free-name")
        }
    }),

    ("rebuildKeepsDevcontainerIdStemWhenCreateNameChanges", {
        let ws = try TestRepo.makeTempWorkspace(configJSON: """
        {
          "name": "My App",
          "image": "alpine:3.20",
          "remoteUser": "vscode",
          "mounts": ["source=${devcontainerId}-shellhistory,target=/cmdhist,type=volume"]
        }
        """)
        defer { try? FileManager.default.removeItem(at: ws) }
        let cfg = ws.appendingPathComponent(".devcontainer/devcontainer.json").path
        let stem = ContainerIdentity.bindResourceIdentityStem(
            workspacePath: ws.path,
            configPath: cfg
        )
        let s = RebuildScenario()
        let oldName = "adev-myapp-abc123def456"
        s.containers = [
            RebuildScenario.container(
                id: oldName,
                labels: s.bindLabels(localFolder: ws.path, configFile: cfg)
            )
        ]
        s.newContainerId = "my-app"
        s.install()
        _ = try RebuildCommand.run(
            options: RebuildOptions(name: oldName, skipPull: true),
            runtime: s.runtime
        )
        let createArgs = s.mock.calls.first { $0.arguments.first == "create" }?.arguments ?? []
        if let idx = createArgs.firstIndex(of: "--name"), idx + 1 < createArgs.count {
            try MiniTest.expectEqual(createArgs[idx + 1], "my-app")
        }
        try MiniTest.expect(createArgs.contains { $0.contains("source=\(stem)-shellhistory") })
        try MiniTest.expect(!createArgs.contains { $0.contains("source=my-app-shellhistory") })
        try MiniTest.expect(!createArgs.contains { $0.contains("source=\(oldName)-shellhistory") })
        try MiniTest.expect(!createArgs.contains { $0.contains("${devcontainerId}") })
        try MiniTest.expect(stem.hasPrefix("adev-"))
        try MiniTest.expect(!stem.contains("my-app"))
    }),

    ("rebuildVolumeRenameKeepsStampedWorkspaceStem", {
        let s = RebuildScenario()
        s.volumeConfigText = """
        { "name": "Other App", "image": "alpine:3.20", "remoteUser": "vscode",
          "mounts": ["source=${devcontainerId}-shellhistory,target=/cmdhist,type=volume"] }
        """
        let wsVol = "adev-foo-abcdef123456-ws"
        let oldName = "old-vol"
        s.containers = [
            RebuildScenario.container(
                id: oldName,
                labels: s.volumeLabels(
                    gitURL: "https://github.com/org/foo.git",
                    workspaceVolume: wsVol
                )
            )
        ]
        s.volumes = [wsVol]
        s.newContainerId = "other-app"
        s.install()
        var result: RebuildResult?
        try withRebuildVolumeOverrides {
            result = try RebuildCommand.run(
                options: RebuildOptions(name: oldName, skipPull: true),
                runtime: s.runtime
            )
        }
        try MiniTest.expectEqual(result?.containerName, "other-app")
        try MiniTest.expectEqual(result?.workspaceVolume, wsVol)
        let createArgs = s.mock.calls.first { $0.arguments.first == "create" }?.arguments ?? []
        try MiniTest.expect(createArgs.contains { $0.contains("source=adev-foo-abcdef123456-shellhistory") })
        try MiniTest.expect(!createArgs.contains { $0.contains("source=other-app-shellhistory") })
        try MiniTest.expect(!s.mock.calls.contains { $0.arguments.starts(with: ["volume", "delete"]) })
    }),
    ("rebuildDoesNotMigrateExistingAdevName", {
        let ws = try TestRepo.makeTempWorkspace(configJSON: #"{"image":"alpine:3.20","remoteUser":"vscode"}"#)
        defer { try? FileManager.default.removeItem(at: ws) }
        let s = RebuildScenario()
        let oldName = "adev-proj-0123456789ab"
        s.containers = [
            RebuildScenario.container(
                id: oldName,
                labels: s.bindLabels(
                    localFolder: ws.path,
                    configFile: ws.appendingPathComponent(".devcontainer/devcontainer.json").path
                )
            )
        ]
        s.install()
        // No rebuild invoked — leftover name stays. Classification is not a rename pass.
        try MiniTest.expectEqual(s.containers[0].id, oldName)
        try MiniTest.expect(s.containers[0].id.hasPrefix("adev-"))
    }),
    ("usageTextListsRebuildWithFlags", {
        let text = CommandSurface.usageText()
        try MiniTest.expect(text.contains("rebuild"), "usage lists rebuild")
        try MiniTest.expect(text.contains("--skip-pull"), "usage mentions --skip-pull")
        try MiniTest.expect(text.contains("--vscode"), "usage mentions --vscode")
        try MiniTest.expect(text.contains("--json"), "usage mentions --json")
        try MiniTest.expect(text.contains("--name"), "usage mentions --name")
    }),

    ("commandHelpRebuildPresent", {
        let help = CommandSurface.commandHelpText("rebuild")
        try MiniTest.expect(help != nil, "rebuild help present")
        guard let help else { return }
        try MiniTest.expect(help.contains("rebuild"), "help names the command")
        try MiniTest.expect(help.contains("--skip-pull"), "help lists --skip-pull")
        try MiniTest.expect(help.contains("--vscode"), "help lists --vscode")
        try MiniTest.expect(help.contains("force"), "help describes forced rebuild")
        try MiniTest.expect(help.contains("volume"), "help describes volume preservation")
        try MiniTest.expect(
            !help.lowercased().contains("unsupported"),
            "volume rebuild help must not claim local-path Features are unsupported"
        )
        try MiniTest.expect(
            help.contains("Local-path") || help.contains("local-path"),
            "rebuild help describes local-path Features on bind and volume"
        )
    }),

    ("commandHelpUnknownSubcommandNil", {
        try MiniTest.expect(CommandSurface.commandHelpText("nope") == nil)
    }),

    ("helpRoutesCommandSpecificHelp", {
        // `help <command>` MUST print the same command-specific help as `<command> --help`
        // (regression: `help rebuild` printed the main usage text instead).
        for cmd in ["up", "clone", "rebuild", "list", "start", "exec", "stop", "delete", "purge", "inspect"] {
            try MiniTest.expectEqual(
                CommandSurface.resolveHelpSubcommand(args: ["help", cmd]),
                cmd,
                "help \(cmd) routes to \(cmd) command help"
            )
            try MiniTest.expect(CommandSurface.commandHelpText(cmd) != nil, "\(cmd) has command-specific help")
        }
        try MiniTest.expect(CommandSurface.resolveHelpSubcommand(args: ["help"]) == nil, "bare help is main usage")
        try MiniTest.expect(CommandSurface.resolveHelpSubcommand(args: ["-h"]) == nil, "-h is main usage")
        try MiniTest.expect(CommandSurface.resolveHelpSubcommand(args: ["--help"]) == nil, "--help is main usage")
        try MiniTest.expect(
            CommandSurface.resolveHelpSubcommand(args: ["rebuild", "--help"]) == nil,
            "command-side --help stays command-side"
        )
    }),

    ("helpRebuildMatchesRebuildHelpOutput", {
        // `help rebuild` and `rebuild --help` MUST both print printCommandHelp("rebuild")
        // content (selection, forced rebuild, volume preservation, --vscode gate) —
        // never the main usage text.
        try MiniTest.expectEqual(CommandSurface.resolveHelpSubcommand(args: ["help", "rebuild"]), "rebuild")
        let usage = CommandSurface.usageText()
        let help = CommandSurface.commandHelpText("rebuild")
        try MiniTest.expect(help != nil, "rebuild help present")
        guard let help else { return }
        try MiniTest.expect(help != usage, "command help differs from main usage")
        try MiniTest.expect(help.contains("rebuild"), "help names the command")
        try MiniTest.expect(help.contains("--skip-pull"), "help lists --skip-pull")
        try MiniTest.expect(help.contains("--vscode"), "help lists --vscode")
        try MiniTest.expect(help.contains("Force-rebuild"), "help describes forced rebuild")
        try MiniTest.expect(help.contains("volume"), "help describes volume preservation")
        try MiniTest.expect(!usage.contains("preflight"), "main usage stays the overview, not rebuild specifics")
    })
]
