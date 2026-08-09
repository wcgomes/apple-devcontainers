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
        try MiniTest.expect(help.contains("force"), "help describes forced recreate")
        try MiniTest.expect(help.contains("volume"), "help describes volume preservation")
    }),

    ("commandHelpUnknownSubcommandNil", {
        try MiniTest.expect(CommandSurface.commandHelpText("nope") == nil)
    })
]
