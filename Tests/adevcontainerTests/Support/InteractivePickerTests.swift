import Foundation
@testable import ADevContainerLib

private func pickerContainers() -> [ContainerInfo] {
    [
        ContainerInfo(id: "adev-a-111", name: "adev-a-111", state: "running", labels: [
            ContainerIdentity.labelManaged: ContainerIdentity.managedValue,
            ContainerIdentity.labelGitURL: "https://example.com/a.git",
            ContainerIdentity.labelWorkspaceMode: ContainerIdentity.workspaceModeBind,
        ], image: "alpine"),
        ContainerInfo(id: "adev-b-222", name: "adev-b-222", state: "stopped", labels: [
            ContainerIdentity.labelManaged: ContainerIdentity.managedValue,
            ContainerIdentity.labelWorkspaceMode: ContainerIdentity.workspaceModeVolume,
        ], image: "alpine"),
        ContainerInfo(id: "adev-c-333", name: "adev-c-333", state: "running", labels: [
            ContainerIdentity.labelManaged: ContainerIdentity.managedValue,
        ], image: "alpine"),
    ]
}

/// Queue-backed key source for navigable picker tests (thread-safe enough for serial MiniTest).
private final class PickerInputQueue: @unchecked Sendable {
    private var events: [InteractivePickerInput]
    init(_ events: [InteractivePickerInput]) { self.events = events }
    func next() -> InteractivePickerInput {
        if events.isEmpty { return .eof }
        return events.removeFirst()
    }
}

nonisolated(unsafe) let interactivePickerTests: [(String, () throws -> Void)] = [
    ("pickerNumberedReadLineSelectsIndex", {
        let containers = pickerContainers()
        let picker = InteractivePicker(
            isInteractive: true,
            readLine: { "2" },
            writeError: { _ in }
        )
        let picked = try picker.pick(from: containers)
        try MiniTest.expectEqual(picked.id, "adev-b-222")
    }),
    ("pickerNumberedInvalidThrowsUsage", {
        let containers = pickerContainers()
        let picker = InteractivePicker(
            isInteractive: true,
            readLine: { "99" },
            writeError: { _ in }
        )
        try MiniTest.expectThrows({
            _ = try picker.pick(from: containers)
        }) { error in
            let err = error as! CLIError
            try MiniTest.expectEqual(err.code, CLIErrorCode.usage)
            try MiniTest.expect(err.message.contains("Invalid selection"))
        }
    }),
    ("pickerNavigableEnterSelectsHighlight", {
        let containers = pickerContainers()
        let q = PickerInputQueue([.enter])
        let picker = InteractivePicker(
            isInteractive: true,
            readLine: { nil },
            writeError: { _ in },
            readInput: { q.next() }
        )
        let picked = try picker.pick(from: containers)
        try MiniTest.expectEqual(picked.id, "adev-a-111")
    }),
    ("pickerNavigableDownEnterSelectsSecond", {
        let containers = pickerContainers()
        let q = PickerInputQueue([.down, .enter])
        let picker = InteractivePicker(
            isInteractive: true,
            readLine: { nil },
            writeError: { _ in },
            readInput: { q.next() }
        )
        let picked = try picker.pick(from: containers)
        try MiniTest.expectEqual(picked.id, "adev-b-222")
    }),
    ("pickerNavigableUpWrapsToLast", {
        let containers = pickerContainers()
        let q = PickerInputQueue([.up, .enter])
        let picker = InteractivePicker(
            isInteractive: true,
            readLine: { nil },
            writeError: { _ in },
            readInput: { q.next() }
        )
        let picked = try picker.pick(from: containers)
        try MiniTest.expectEqual(picked.id, "adev-c-333")
    }),
    ("pickerNavigableDownWrapsToFirst", {
        let containers = pickerContainers()
        let q = PickerInputQueue([.down, .down, .down, .enter])
        let picker = InteractivePicker(
            isInteractive: true,
            readLine: { nil },
            writeError: { _ in },
            readInput: { q.next() }
        )
        let picked = try picker.pick(from: containers)
        try MiniTest.expectEqual(picked.id, "adev-a-111")
    }),
    ("pickerNavigableDigitSelects", {
        let containers = pickerContainers()
        let q = PickerInputQueue([.digit(3)])
        let picker = InteractivePicker(
            isInteractive: true,
            readLine: { nil },
            writeError: { _ in },
            readInput: { q.next() }
        )
        let picked = try picker.pick(from: containers)
        try MiniTest.expectEqual(picked.id, "adev-c-333")
    }),
    ("pickerNavigableEscapeCancelsUsage", {
        let containers = pickerContainers()
        let q = PickerInputQueue([.escape])
        let picker = InteractivePicker(
            isInteractive: true,
            readLine: { nil },
            writeError: { _ in },
            readInput: { q.next() }
        )
        try MiniTest.expectThrows({
            _ = try picker.pick(from: containers)
        }) { error in
            let err = error as! CLIError
            try MiniTest.expectEqual(err.code, CLIErrorCode.usage)
            try MiniTest.expect(err.message.contains("cancelled"))
        }
    }),
    ("pickerNavigableEofCancelsUsage", {
        let containers = pickerContainers()
        let q = PickerInputQueue([.eof])
        let picker = InteractivePicker(
            isInteractive: true,
            readLine: { nil },
            writeError: { _ in },
            readInput: { q.next() }
        )
        try MiniTest.expectThrows({
            _ = try picker.pick(from: containers)
        }) { error in
            try MiniTest.expectEqual((error as! CLIError).code, CLIErrorCode.usage)
        }
    }),
    ("pickerNavigableRendersHighlightAndHint", {
        let containers = pickerContainers()
        final class OutBox: @unchecked Sendable {
            var text = ""
        }
        let box = OutBox()
        let q = PickerInputQueue([.down, .enter])
        let picker = InteractivePicker(
            isInteractive: true,
            readLine: { nil },
            writeError: { box.text += $0 },
            readInput: { q.next() }
        )
        _ = try picker.pick(from: containers)
        let plain = TerminalStyle.stripANSI(box.text)
        try MiniTest.expect(plain.contains("Select a container:"))
        try MiniTest.expect(plain.contains("NAME") && plain.contains("STATE") && plain.contains("MODE"))
        try MiniTest.expect(plain.contains("GIT_URL"))
        try MiniTest.expect(plain.contains("adev-a-111"))
        try MiniTest.expect(plain.contains("adev-b-222"))
        // Table state cells are plain text (no [brackets]), matching list.
        try MiniTest.expect(plain.contains("running"))
        try MiniTest.expect(plain.contains("stopped"))
        try MiniTest.expect(!plain.contains("[running]"))
        try MiniTest.expect(!plain.contains("[stopped]"))
        try MiniTest.expect(plain.contains("Enter select") || plain.contains("Esc cancel"))
        // Cursor-up / clear-line used for redraw (not dumped as user-facing copy).
        try MiniTest.expect(box.text.contains("\u{001B}["))
        try MiniTest.expect(plain.contains(">"))
    }),
    ("pickerListLineColorsNameAndStatus", {
        let previousColor = TerminalStyle.colorOverride
        defer { TerminalStyle.colorOverride = previousColor }
        TerminalStyle.colorOverride = true

        let containers = pickerContainers()
        final class OutBox: @unchecked Sendable {
            var text = ""
        }
        let box = OutBox()
        let q = PickerInputQueue([.enter])
        let picker = InteractivePicker(
            isInteractive: true,
            readLine: { nil },
            writeError: { box.text += $0 },
            readInput: { q.next() }
        )
        _ = try picker.pick(from: containers)

        // Same cell styles as ListCommand: pad-then-style; state without brackets.
        let nameWidth = max(4, containers.map { ManagedContainerTable.displayName(for: $0).count }.max() ?? 4)
        let aName = ManagedContainerTable.pad("adev-a-111", nameWidth)
        try MiniTest.expect(box.text.contains(TerminalStyle.stylePhaseHead(aName, color: true)))
        try MiniTest.expect(box.text.contains(TerminalStyle.styleSuccess("running", color: true)))
        try MiniTest.expect(box.text.contains(TerminalStyle.styleMuted("stopped", color: true)))
        // GIT_URL: default fg, normal weight (unstyled when color on).
        try MiniTest.expect(box.text.contains("https://example.com/a.git"))
        try MiniTest.expect(!box.text.contains(TerminalStyle.styleInfo("https://example.com/a.git", color: true)))
        try MiniTest.expect(!box.text.contains(TerminalStyle.styleCommand("https://example.com/a.git", color: true)))
        try MiniTest.expect(box.text.contains(TerminalStyle.styleCommand("bind  ", color: true)))
        try MiniTest.expect(box.text.contains(TerminalStyle.styleCommand("volume", color: true)))
        // Missing mode shows "-" like list.
        try MiniTest.expect(box.text.contains(TerminalStyle.styleCommand("-     ", color: true)))
        try MiniTest.expect(box.text.contains(TerminalStyle.styleCommand(">", color: true)))
        let plainHeader = ManagedContainerTable.plainHeader(
            widths: ManagedContainerTable.Widths(
                containers: containers,
                lead: ManagedContainerTable.navigableLeadWidth
            )
        )
        try MiniTest.expect(box.text.contains(TerminalStyle.styleInfo(plainHeader, color: true)))
        // Stopped STATE muted gray ≠ header dim.
        try MiniTest.expect(
            TerminalStyle.styleMuted("stopped", color: true)
                != TerminalStyle.styleInfo("stopped", color: true)
        )
    }),
    ("pickerNumberedListLineColorsMatchNavigable", {
        let previousColor = TerminalStyle.colorOverride
        defer { TerminalStyle.colorOverride = previousColor }
        TerminalStyle.colorOverride = true

        let containers = pickerContainers()
        final class OutBox: @unchecked Sendable {
            var text = ""
        }
        let box = OutBox()
        let picker = InteractivePicker(
            isInteractive: true,
            readLine: { "1" },
            writeError: { box.text += $0 }
        )
        _ = try picker.pick(from: containers)

        let nameWidth = max(4, containers.map { ManagedContainerTable.displayName(for: $0).count }.max() ?? 4)
        let bName = ManagedContainerTable.pad("adev-b-222", nameWidth)
        try MiniTest.expect(box.text.contains(TerminalStyle.stylePhaseHead(bName, color: true)))
        try MiniTest.expect(box.text.contains(TerminalStyle.styleSuccess("running", color: true)))
        try MiniTest.expect(box.text.contains(TerminalStyle.styleMuted("stopped", color: true)))
        // GIT_URL: default fg, normal weight (unstyled when color on).
        try MiniTest.expect(box.text.contains("https://example.com/a.git"))
        try MiniTest.expect(!box.text.contains(TerminalStyle.styleInfo("https://example.com/a.git", color: true)))
        try MiniTest.expect(!box.text.contains(TerminalStyle.styleCommand("https://example.com/a.git", color: true)))
        try MiniTest.expect(box.text.contains(TerminalStyle.styleCommand("bind  ", color: true)))
        try MiniTest.expect(box.text.contains(TerminalStyle.styleCommand("volume", color: true)))
        let plain = TerminalStyle.stripANSI(box.text)
        try MiniTest.expect(plain.contains("NAME") && plain.contains("STATE") && plain.contains("MODE"))
        try MiniTest.expect(plain.contains("  1) "))
        try MiniTest.expect(plain.contains("  2) "))
        try MiniTest.expect(plain.contains("adev-a-111"))
        try MiniTest.expect(plain.contains("adev-b-222"))
        try MiniTest.expect(plain.contains("running"))
        try MiniTest.expect(plain.contains("stopped"))
        try MiniTest.expect(!plain.contains("[running]"))
        try MiniTest.expect(plain.contains("https://example.com/a.git"))
        try MiniTest.expect(plain.contains("volume"))
    }),
    ("pickerListLineMonochromeWhenColorDisabled", {
        let previousColor = TerminalStyle.colorOverride
        defer { TerminalStyle.colorOverride = previousColor }
        TerminalStyle.colorOverride = false

        let containers = pickerContainers()
        final class OutBox: @unchecked Sendable {
            var text = ""
        }
        let box = OutBox()
        let picker = InteractivePicker(
            isInteractive: true,
            readLine: { "1" },
            writeError: { box.text += $0 }
        )
        _ = try picker.pick(from: containers)

        // Numbered path has no CSI cursor codes; only SGR would appear if color leaked.
        try MiniTest.expect(!box.text.contains(TerminalStyle.ansiPhaseCyan))
        try MiniTest.expect(!box.text.contains(TerminalStyle.ansiSuccessGreen))
        try MiniTest.expect(!box.text.contains(TerminalStyle.ansiBold))
        try MiniTest.expect(!box.text.contains(TerminalStyle.ansiDim))
        try MiniTest.expect(!box.text.contains("\u{001B}"))
        try MiniTest.expect(box.text.contains("NAME"))
        try MiniTest.expect(box.text.contains("STATE"))
        try MiniTest.expect(box.text.contains("MODE"))
        try MiniTest.expect(box.text.contains("GIT_URL"))
        try MiniTest.expect(box.text.contains("  1) "))
        try MiniTest.expect(box.text.contains("adev-a-111"))
        try MiniTest.expect(box.text.contains("running"))
        try MiniTest.expect(box.text.contains("https://example.com/a.git"))
        try MiniTest.expect(box.text.contains("bind"))
        try MiniTest.expect(box.text.contains("  2) "))
        try MiniTest.expect(box.text.contains("adev-b-222"))
        try MiniTest.expect(box.text.contains("stopped"))
        try MiniTest.expect(box.text.contains("volume"))
        // Missing mode is "-" like list.
        try MiniTest.expect(box.text.contains("adev-c-333"))
        let plainLines = box.text.split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
        let cRow = plainLines.first { $0.contains("adev-c-333") } ?? ""
        try MiniTest.expect(cRow.contains("-"))
    }),
    ("pickerRecoverySuffixMatchesList", {
        let previousColor = TerminalStyle.colorOverride
        defer { TerminalStyle.colorOverride = previousColor }
        TerminalStyle.colorOverride = true

        let helper = ContainerInfo(
            id: "adev-recovery-helper",
            name: "adev-recovery-helper",
            state: "running",
            labels: [
                ContainerIdentity.labelManaged: ContainerIdentity.managedValue,
                ContainerIdentity.labelWorkspaceMode: ContainerIdentity.workspaceModeVolume,
                RecoveryHelper.recoveryMarkerLabel: RecoveryHelper.recoveryMarkerValue,
                RecoveryHelper.recoverySessionLabel: "picker-color-session",
            ],
            image: RecoveryHelper.helperImageReference
        )
        let other = ContainerInfo(
            id: "adev-normal-111",
            name: "adev-normal-111",
            state: "stopped",
            labels: [
                ContainerIdentity.labelManaged: ContainerIdentity.managedValue,
                ContainerIdentity.labelWorkspaceMode: ContainerIdentity.workspaceModeBind,
            ],
            image: "alpine"
        )
        final class OutBox: @unchecked Sendable {
            var text = ""
        }
        let box = OutBox()
        let q = PickerInputQueue([.enter])
        let picker = InteractivePicker(
            isInteractive: true,
            readLine: { nil },
            writeError: { box.text += $0 },
            readInput: { q.next() }
        )
        _ = try picker.pick(from: [helper, other])
        let plain = TerminalStyle.stripANSI(box.text)
        try MiniTest.expect(plain.contains("adev-recovery-helper [RECOVERY]"))
        let nameWidth = max(
            ManagedContainerTable.displayName(for: helper).count,
            ManagedContainerTable.displayName(for: other).count
        )
        let padded = ManagedContainerTable.pad("adev-recovery-helper [RECOVERY]", nameWidth)
        try MiniTest.expect(box.text.contains(TerminalStyle.stylePhaseHead(padded, color: true)))
    }),
    ("pickerTableAlignsLikeList", {
        let previousColor = TerminalStyle.colorOverride
        defer { TerminalStyle.colorOverride = previousColor }
        TerminalStyle.colorOverride = false

        let containers = pickerContainers()
        final class OutBox: @unchecked Sendable {
            var text = ""
        }
        let box = OutBox()
        let picker = InteractivePicker(
            isInteractive: true,
            readLine: { "1" },
            writeError: { box.text += $0 }
        )
        _ = try picker.pick(from: containers)

        let lines = box.text.split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
        let headerIdx = lines.firstIndex { $0.contains("NAME") && $0.contains("STATE") }!
        let header = lines[headerIdx]
        let stateIdx = header.range(of: "STATE")!.lowerBound
        let col = header.distance(from: header.startIndex, to: stateIdx)
        for row in lines[(headerIdx + 1)...].prefix(containers.count) {
            guard row.count > col else {
                throw MiniTest.Failure(message: "row too short: \(row)")
            }
            let rowIdx = row.index(row.startIndex, offsetBy: col)
            let slice = row[rowIdx...]
            try MiniTest.expect(
                slice.hasPrefix("running") || slice.hasPrefix("stopped"),
                "STATE column misaligned in: \(row)"
            )
        }
    }),

    ("resolveSelectionNonInteractiveMultipleRequiresName", {
        let mock = MockProcessRunner()
        let a = MockProcessRunner.containerListJSON(
            id: "adev-a-111111111111",
            state: "stopped",
            labels: [ContainerIdentity.labelManaged: ContainerIdentity.managedValue]
        )
        let b = MockProcessRunner.containerListJSON(
            id: "adev-b-222222222222",
            state: "stopped",
            labels: [ContainerIdentity.labelManaged: ContainerIdentity.managedValue]
        )
        mock.handlers = [
            { args in
                if args.starts(with: ["list"]) {
                    let data = try! JSONSerialization.data(withJSONObject: [a, b])
                    return ProcessResult(exitCode: 0, stdout: data, stderr: Data())
                }
                return nil
            }
        ]
        let runtime = AppleContainerRuntime(executablePath: "/usr/local/bin/container", runner: mock)
        let picker = InteractivePicker(isInteractive: false, readLine: { nil }, writeError: { _ in })
        try MiniTest.expectThrows({
            _ = try ManagedContainers.resolveSelection(name: nil, runtime: runtime, picker: picker)
        }) { error in
            try MiniTest.expectEqual((error as! CLIError).code, CLIErrorCode.selectionRequired)
        }
    }),
    ("pickerCustomReadLineNeverPrefersLiveRaw", {
        // Mocks must not enter raw mode even if a developer TTY is attached.
        let picker = InteractivePicker(
            isInteractive: true,
            readLine: { "1" },
            writeError: { _ in }
        )
        try MiniTest.expect(!picker.prefersLiveRawInput)
        try MiniTest.expect(InteractivePicker.default.prefersLiveRawInput)
    }),
    ("pickerNavigableCtrlCByteCancelsLikeEof", {
        let containers = pickerContainers()
        let q = PickerInputQueue([.eof]) // decodeSingleByte(0x03) → .eof
        let picker = InteractivePicker(
            isInteractive: true,
            readLine: { nil },
            writeError: { _ in },
            readInput: { q.next() }
        )
        try MiniTest.expectThrows({
            _ = try picker.pick(from: containers)
        }) { error in
            let err = error as! CLIError
            try MiniTest.expectEqual(err.code, CLIErrorCode.usage)
            try MiniTest.expect(err.message.contains("cancelled"))
        }
    }),
    ("rawInputDecodeSingleByteKeys", {
        try MiniTest.expectEqual(TerminalRawInput.decodeSingleByte(0x03), .eof)
        try MiniTest.expectEqual(TerminalRawInput.decodeSingleByte(0x0D), .enter)
        try MiniTest.expectEqual(TerminalRawInput.decodeSingleByte(0x0A), .enter)
        try MiniTest.expectEqual(TerminalRawInput.decodeSingleByte(UInt8(ascii: "j")), .down)
        try MiniTest.expectEqual(TerminalRawInput.decodeSingleByte(UInt8(ascii: "k")), .up)
        try MiniTest.expectEqual(TerminalRawInput.decodeSingleByte(UInt8(ascii: "2")), .digit(2))
        try MiniTest.expectEqual(TerminalRawInput.decodeSingleByte(UInt8(ascii: "x")), .other)
    }),
    ("rawInputDecodeEscapeSequences", {
        try MiniTest.expectEqual(TerminalRawInput.decodeAfterEscape([]), .escape)
        try MiniTest.expectEqual(
            TerminalRawInput.decodeAfterEscape([UInt8(ascii: "["), UInt8(ascii: "A")]),
            .up
        )
        try MiniTest.expectEqual(
            TerminalRawInput.decodeAfterEscape([UInt8(ascii: "["), UInt8(ascii: "B")]),
            .down
        )
        try MiniTest.expectEqual(
            TerminalRawInput.decodeAfterEscape([UInt8(ascii: "["), UInt8(ascii: "C")]),
            .other
        )
        try MiniTest.expectEqual(
            TerminalRawInput.decodeAfterEscape([UInt8(ascii: "x")]),
            .escape
        )
    }),
]
