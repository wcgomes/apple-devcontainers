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
    }),

    ("commandHelpUnknownSubcommandNil", {
        try MiniTest.expect(CommandSurface.commandHelpText("nope") == nil)
    }),

    ("helpRoutesCommandSpecificHelp", {
        // `help <command>` MUST print the same command-specific help as `<command> --help`
        // (regression: `help rebuild` printed the main usage text instead).
        for cmd in ["up", "clone", "rebuild", "list", "start", "exec", "stop", "delete", "prune", "inspect"] {
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
