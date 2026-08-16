import Foundation
@testable import ADevContainerLib

/// Human `list` table color / monochrome / JSON contracts (InteractivePicker-aligned cells).
nonisolated(unsafe) let listCommandTests: [(String, () throws -> Void)] = [
    ("listHumanTableColorsNameStateModeSource", {
        let previousColor = TerminalStyle.colorOverride
        defer { TerminalStyle.colorOverride = previousColor }
        TerminalStyle.colorOverride = true

        let runtime = try listTestRuntime(
            entries: [
                listManagedEntry(
                    id: "adev-run-aaaabbbbcccc",
                    state: "running",
                    mode: "volume",
                    git: "https://github.com/org/app"
                ),
                listManagedEntry(
                    id: "adev-stop-ddddeeeeffff",
                    state: "stopped",
                    mode: "bind",
                    git: "",
                    localFolder: "/host/workspace/app"
                ),
            ]
        )
        let table = try ListCommand.run(options: ListOptions(jsonOutput: false), runtime: runtime)
        let plain = TerminalStyle.stripANSI(table)

        // Pad-then-style: trailing pad spaces live inside the SGR wrap.
        let nameWidth = max("adev-run-aaaabbbbcccc".count, "adev-stop-ddddeeeeffff".count)
        let runName = "adev-run-aaaabbbbcccc" + String(repeating: " ", count: nameWidth - "adev-run-aaaabbbbcccc".count)
        let stopName = "adev-stop-ddddeeeeffff" + String(repeating: " ", count: nameWidth - "adev-stop-ddddeeeeffff".count)
        try MiniTest.expect(table.contains(TerminalStyle.stylePhaseHead(runName, color: true)))
        try MiniTest.expect(table.contains(TerminalStyle.stylePhaseHead(stopName, color: true)))
        try MiniTest.expect(table.contains(TerminalStyle.styleSuccess("running", color: true)))
        try MiniTest.expect(table.contains(TerminalStyle.styleMuted("stopped", color: true)))
        try MiniTest.expect(table.contains(TerminalStyle.styleCommand("volume", color: true)))
        try MiniTest.expect(table.contains(TerminalStyle.styleCommand("bind  ", color: true)))
        // SOURCE: default fg, normal weight (unstyled when color on).
        try MiniTest.expect(table.contains("https://github.com/org/app"))
        try MiniTest.expect(!table.contains(TerminalStyle.styleInfo("https://github.com/org/app", color: true)))
        try MiniTest.expect(!table.contains(TerminalStyle.styleCommand("https://github.com/org/app", color: true)))
        // SOURCE cell is mode-dependent: bind row shows local_folder path.
        try MiniTest.expect(table.contains("/host/workspace/app"))
        // Header is dim chrome; stopped STATE uses muted gray (not the same SGR as dim).
        let headerLine = plain.split(separator: "\n", omittingEmptySubsequences: false).first.map(String.init) ?? ""
        try MiniTest.expect(headerLine.contains("NAME") && headerLine.contains("STATE") && headerLine.contains("MODE"))
        try MiniTest.expect(table.contains(TerminalStyle.styleInfo(headerLine, color: true)))
        try MiniTest.expect(
            TerminalStyle.styleMuted("stopped", color: true)
                != TerminalStyle.styleInfo("stopped", color: true)
        )
        try MiniTest.expect(plain.contains("adev-run-aaaabbbbcccc"))
        try MiniTest.expect(plain.contains("adev-stop-ddddeeeeffff"))
    }),
    ("managedContainerTableAbbreviatePathRules", {
        let home = "/home/dev"
        // Equal to home → "~".
        try MiniTest.expectEqual(
            ManagedContainerTable.abbreviatePath(home, homeDirectory: home),
            "~"
        )
        // Home with a trailing slash → "~" (collapse, not "~/").
        try MiniTest.expectEqual(
            ManagedContainerTable.abbreviatePath(home + "/", homeDirectory: home),
            "~"
        )
        // Under home → "~/…", remainder preserved (including deeper nesting).
        try MiniTest.expectEqual(
            ManagedContainerTable.abbreviatePath(home + "/workspace/app", homeDirectory: home),
            "~/workspace/app"
        )
        try MiniTest.expectEqual(
            ManagedContainerTable.abbreviatePath(home + "/a/b/c", homeDirectory: home),
            "~/a/b/c"
        )
        // Outside home → unchanged.
        try MiniTest.expectEqual(
            ManagedContainerTable.abbreviatePath("/host/workspace/app", homeDirectory: home),
            "/host/workspace/app"
        )
        // Home-prefix sibling ("/home/dev2") is not under home.
        try MiniTest.expectEqual(
            ManagedContainerTable.abbreviatePath("/home/dev2/app", homeDirectory: home),
            "/home/dev2/app"
        )
        // Empty path → unchanged.
        try MiniTest.expectEqual(
            ManagedContainerTable.abbreviatePath("", homeDirectory: home),
            ""
        )
    }),
    ("listHumanTableAbbreviatesHomeUnderBindPath", {
        let previousColor = TerminalStyle.colorOverride
        defer { TerminalStyle.colorOverride = previousColor }
        TerminalStyle.colorOverride = false

        let home = FileManager.default.homeDirectoryForCurrentUser.path
        let bindPath = home + "/workspace/app"
        let runtime = try listTestRuntime(
            entries: [
                listManagedEntry(
                    id: "adev-bind-hhhhhhhh",
                    state: "running",
                    mode: "bind",
                    git: "",
                    localFolder: bindPath
                ),
                listManagedEntry(
                    id: "adev-vol-gggggggg",
                    state: "running",
                    mode: "volume",
                    git: "https://github.com/org/app"
                ),
            ]
        )
        let table = try ListCommand.run(options: ListOptions(jsonOutput: false), runtime: runtime)
        // Bind-mode SOURCE under the real home renders ~/… (display-only).
        try MiniTest.expect(table.contains("~/workspace/app"))
        try MiniTest.expect(!table.contains(bindPath))
        // Volume-mode SOURCE (git URL) is never abbreviated.
        try MiniTest.expect(table.contains("https://github.com/org/app"))
        // Label stays unchanged: list JSON still carries the full local_folder path
        // (JSONSerialization pretty-printed output escapes "/" as "\/").
        let json = try ListCommand.run(options: ListOptions(jsonOutput: true), runtime: runtime)
        try MiniTest.expect(json.contains(bindPath.replacingOccurrences(of: "/", with: "\\/")))
    }),
    ("listHumanTableMonochromeWhenColorDisabled", {
        let previousColor = TerminalStyle.colorOverride
        defer { TerminalStyle.colorOverride = previousColor }
        TerminalStyle.colorOverride = false

        let runtime = try listTestRuntime(
            entries: [
                listManagedEntry(
                    id: "adev-run-aaaabbbbcccc",
                    state: "running",
                    mode: "volume",
                    git: "https://github.com/org/app"
                ),
            ]
        )
        let table = try ListCommand.run(options: ListOptions(jsonOutput: false), runtime: runtime)

        try MiniTest.expect(!table.contains(TerminalStyle.ansiPhaseCyan))
        try MiniTest.expect(!table.contains(TerminalStyle.ansiSuccessGreen))
        try MiniTest.expect(!table.contains(TerminalStyle.ansiBold))
        try MiniTest.expect(!table.contains(TerminalStyle.ansiDim))
        try MiniTest.expect(!table.contains("\u{001B}"))
        try MiniTest.expect(table.contains("adev-run-aaaabbbbcccc"))
        try MiniTest.expect(table.contains("running"))
        try MiniTest.expect(table.contains("volume"))
        try MiniTest.expect(table.contains("https://github.com/org/app"))
        try MiniTest.expect(table.contains("NAME"))
        try MiniTest.expect(table.contains("STATE"))
        try MiniTest.expect(table.contains("MODE"))
        try MiniTest.expect(table.contains("SOURCE"))
    }),
    ("listJSONUnchangedMonochromeEvenWhenColorEnabled", {
        let previousColor = TerminalStyle.colorOverride
        defer { TerminalStyle.colorOverride = previousColor }
        TerminalStyle.colorOverride = true

        let runtime = try listTestRuntime(
            entries: [
                listManagedEntry(
                    id: "adev-run-aaaabbbbcccc",
                    state: "running",
                    mode: "volume",
                    git: "https://github.com/org/app"
                ),
            ]
        )
        let json = try ListCommand.run(options: ListOptions(jsonOutput: true), runtime: runtime)
        try MiniTest.expect(!json.contains("\u{001B}"))
        let arr = try JSONSerialization.jsonObject(with: Data(json.utf8)) as! [[String: Any]]
        try MiniTest.expectEqual(arr.count, 1)
        try MiniTest.expectEqual(arr[0]["id"] as? String, "adev-run-aaaabbbbcccc")
        try MiniTest.expectEqual(arr[0]["state"] as? String, "running")
        try MiniTest.expectEqual(arr[0]["gitUrl"] as? String, "https://github.com/org/app")
        try MiniTest.expectEqual(arr[0]["workspaceMode"] as? String, "volume")
    }),
    ("listEmptyMessageStaysPlain", {
        let previousColor = TerminalStyle.colorOverride
        defer { TerminalStyle.colorOverride = previousColor }
        TerminalStyle.colorOverride = true

        let runtime = try listTestRuntime(entries: [])
        let table = try ListCommand.run(options: ListOptions(jsonOutput: false), runtime: runtime)
        try MiniTest.expectEqual(table, "No managed containers")
        try MiniTest.expect(!table.contains("\u{001B}"))
    }),
    ("listRecoverySuffixVisibleWithColoredName", {
        let previousColor = TerminalStyle.colorOverride
        defer { TerminalStyle.colorOverride = previousColor }
        TerminalStyle.colorOverride = true

        let helper = MockProcessRunner.containerListJSON(
            id: "adev-recovery-helper",
            state: "running",
            labels: [
                ContainerIdentity.labelManaged: ContainerIdentity.managedValue,
                ContainerIdentity.labelWorkspaceMode: ContainerIdentity.workspaceModeVolume,
                RecoveryHelper.recoveryMarkerLabel: RecoveryHelper.recoveryMarkerValue,
                RecoveryHelper.recoverySessionLabel: "list-color-session",
            ],
            image: RecoveryHelper.helperImageReference
        )
        let runtime = try listTestRuntime(entries: [helper])
        let table = try ListCommand.run(options: ListOptions(jsonOutput: false), runtime: runtime)
        let plain = TerminalStyle.stripANSI(table)
        try MiniTest.expect(plain.contains("adev-recovery-helper [RECOVERY]"))
        try MiniTest.expect(table.contains(
            TerminalStyle.stylePhaseHead("adev-recovery-helper [RECOVERY]", color: true)
        ))
    }),
    ("listColumnPaddingUsesVisibleWidthNotANSILength", {
        let previousColor = TerminalStyle.colorOverride
        defer { TerminalStyle.colorOverride = previousColor }

        let runtime = try listTestRuntime(
            entries: [
                listManagedEntry(
                    id: "short",
                    state: "running",
                    mode: "bind",
                    git: "",
                    localFolder: "/host/workspace/app"
                ),
                listManagedEntry(
                    id: "longer-name-here",
                    state: "stopped",
                    mode: "volume",
                    git: "https://example.com/b.git"
                ),
            ]
        )

        TerminalStyle.colorOverride = true
        let colored = try ListCommand.run(options: ListOptions(jsonOutput: false), runtime: runtime)
        TerminalStyle.colorOverride = false
        let mono = try ListCommand.run(options: ListOptions(jsonOutput: false), runtime: runtime)

        // Visible layout must match monochrome table (pad-then-style, not style-then-pad).
        try MiniTest.expectEqual(TerminalStyle.stripANSI(colored), mono)

        let monoLines = mono.split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
        try MiniTest.expect(monoLines.count >= 3)
        // STATE column starts at the same character index on every data row.
        let stateIdx = monoLines[0].range(of: "STATE")!.lowerBound
        for row in monoLines.dropFirst() {
            let idx = monoLines[0].distance(from: monoLines[0].startIndex, to: stateIdx)
            let rowIdx = row.index(row.startIndex, offsetBy: idx)
            let slice = row[rowIdx...]
            try MiniTest.expect(
                slice.hasPrefix("running") || slice.hasPrefix("stopped"),
                "STATE column misaligned in: \(row)"
            )
        }
    }),
]

// MARK: - Fixtures

private func listManagedEntry(
    id: String,
    state: String,
    mode: String,
    git: String,
    localFolder: String = ""
) -> [String: Any] {
    var labels: [String: String] = [
        ContainerIdentity.labelManaged: ContainerIdentity.managedValue,
        ContainerIdentity.labelWorkspaceMode: mode,
    ]
    if !git.isEmpty {
        labels[ContainerIdentity.labelGitURL] = git
    }
    if !localFolder.isEmpty {
        labels[ContainerIdentity.labelLocalFolder] = localFolder
    }
    return MockProcessRunner.containerListJSON(id: id, state: state, labels: labels)
}

private func listTestRuntime(entries: [[String: Any]]) throws -> AppleContainerRuntime {
    let mock = MockProcessRunner()
    mock.handlers = [
        { args in
            if args.starts(with: ["list"]) {
                let data = try! JSONSerialization.data(withJSONObject: entries)
                return ProcessResult(exitCode: 0, stdout: data, stderr: Data())
            }
            return nil
        }
    ]
    return AppleContainerRuntime(executablePath: "/usr/local/bin/container", runner: mock)
}
