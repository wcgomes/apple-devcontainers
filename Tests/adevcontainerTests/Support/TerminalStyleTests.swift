import Foundation
@testable import ADevContainerLib

nonisolated(unsafe) let terminalStyleTests: [(String, () throws -> Void)] = [
    ("terminalStyleColorEnabledWhenTTYNoNOCOLOR", {
        try MiniTest.expect(
            TerminalStyle.colorEnabled(stderrIsTTY: true, env: [:])
        )
    }),
    ("terminalStyleColorDisabledWhenNOCOLORSet", {
        try MiniTest.expect(
            !TerminalStyle.colorEnabled(stderrIsTTY: true, env: ["NO_COLOR": ""])
        )
        try MiniTest.expect(
            !TerminalStyle.colorEnabled(stderrIsTTY: true, env: ["NO_COLOR": "1"])
        )
        try MiniTest.expect(
            !TerminalStyle.colorEnabled(stderrIsTTY: true, env: ["NO_COLOR": "0"])
        )
    }),
    ("terminalStyleFORCECOLOREnablesWithoutTTY", {
        try MiniTest.expect(
            TerminalStyle.colorEnabled(
                stderrIsTTY: false,
                env: ["FORCE_COLOR": "1"]
            )
        )
        // Other FORCE_COLOR values do not force on.
        try MiniTest.expect(
            !TerminalStyle.colorEnabled(
                stderrIsTTY: false,
                env: ["FORCE_COLOR": "0"]
            )
        )
    }),
    ("terminalStyleNOCOLORWinsOverFORCECOLOR", {
        try MiniTest.expect(
            !TerminalStyle.colorEnabled(
                stderrIsTTY: false,
                env: ["NO_COLOR": "1", "FORCE_COLOR": "1"]
            )
        )
        try MiniTest.expect(
            !TerminalStyle.colorEnabled(
                stderrIsTTY: true,
                env: ["NO_COLOR": "", "FORCE_COLOR": "1"]
            )
        )
    }),
    ("terminalStyleColorOffWithoutTTY", {
        try MiniTest.expect(
            !TerminalStyle.colorEnabled(stderrIsTTY: false, env: [:])
        )
    }),
    ("terminalStylePhaseWarningErrorStripANSIKeepsPrefixes", {
        let phase = TerminalStyle.stylePhase("==> Resolving configuration", color: true)
        let warning = TerminalStyle.styleWarning("warning: skipped feature", color: true)
        let error = TerminalStyle.styleError("error: boom", color: true)
        try MiniTest.expect(phase.contains("\u{001B}"))
        try MiniTest.expect(warning.contains("\u{001B}"))
        try MiniTest.expect(error.contains("\u{001B}"))
        try MiniTest.expect(TerminalStyle.stripANSI(phase).hasPrefix("==> "))
        try MiniTest.expect(TerminalStyle.stripANSI(phase).contains("Resolving configuration"))
        try MiniTest.expect(TerminalStyle.stripANSI(warning).hasPrefix("warning: "))
        try MiniTest.expect(TerminalStyle.stripANSI(error).hasPrefix("error: "))
    }),
    ("terminalStyleWarningUsesYellowDistinctFromPhaseAndInfo", {
        let warning = TerminalStyle.styleWarning("warning: skipped feature", color: true)
        let phase = TerminalStyle.stylePhase("==> Ready", color: true)
        let info = TerminalStyle.styleInfo("    quiet info", color: true)
        let hasYellow =
            warning.contains(TerminalStyle.ansiWarningYellow)
            || warning.contains(TerminalStyle.ansiBrightYellow)
            || warning.contains(TerminalStyle.ansiYellow)
        try MiniTest.expect(hasYellow)
        try MiniTest.expect(warning.contains(TerminalStyle.ansiBold))
        try MiniTest.expect(warning.contains(TerminalStyle.ansiReset))
        try MiniTest.expect(warning.contains(TerminalStyle.ansiDim))
        try MiniTest.expect(!warning.contains(TerminalStyle.ansiPhaseCyan))
        try MiniTest.expect(!warning.contains(TerminalStyle.ansiCyan))
        try MiniTest.expect(!phase.contains(TerminalStyle.ansiWarningYellow))
        try MiniTest.expect(!phase.contains(TerminalStyle.ansiBrightYellow))
        try MiniTest.expect(!phase.contains(TerminalStyle.ansiYellow))
        try MiniTest.expect(phase.contains(TerminalStyle.ansiPhaseCyan))
        try MiniTest.expect(!info.contains(TerminalStyle.ansiWarningYellow))
        try MiniTest.expect(!info.contains(TerminalStyle.ansiBrightYellow))
        try MiniTest.expect(!info.contains(TerminalStyle.ansiYellow))
        try MiniTest.expectEqual(
            TerminalStyle.stripANSI(warning),
            "warning: skipped feature"
        )
        // Label yellow, body dim — yellow must not wrap the whole message.
        let labelPart = TerminalStyle.styleWarningLabel("warning: ", color: true)
        let bodyPart = TerminalStyle.styleWarningBody("skipped feature", color: true)
        try MiniTest.expect(warning.hasPrefix(labelPart) || warning.contains(labelPart))
        try MiniTest.expect(bodyPart.contains(TerminalStyle.ansiDim))
        try MiniTest.expect(!bodyPart.contains(TerminalStyle.ansiWarningYellow))
    }),
    ("terminalStyleErrorUsesRed", {
        let error = TerminalStyle.styleError("error: bad args", color: true)
        let hasRed =
            error.contains(TerminalStyle.ansiErrorRed)
            || error.contains(TerminalStyle.ansiBrightRed)
            || error.contains(TerminalStyle.ansiRed)
        try MiniTest.expect(hasRed)
        try MiniTest.expect(error.contains(TerminalStyle.ansiBold))
        try MiniTest.expect(error.contains(TerminalStyle.ansiReset))
        try MiniTest.expect(error.contains(TerminalStyle.ansiDim))
        try MiniTest.expect(!error.contains(TerminalStyle.ansiWarningYellow))
        try MiniTest.expect(!error.contains(TerminalStyle.ansiBrightYellow))
        try MiniTest.expect(!error.contains(TerminalStyle.ansiYellow))
        try MiniTest.expect(!error.contains(TerminalStyle.ansiPhaseCyan))
        try MiniTest.expect(!error.contains(TerminalStyle.ansiCyan))
        try MiniTest.expectEqual(
            TerminalStyle.stripANSI(error),
            "error: bad args"
        )
        let bodyPart = TerminalStyle.styleErrorBody("bad args", color: true)
        try MiniTest.expect(bodyPart.contains(TerminalStyle.ansiDim))
        try MiniTest.expect(!bodyPart.contains(TerminalStyle.ansiErrorRed))
    }),
    ("terminalStyleFrameToolLineIndentAndPipe", {
        let framed = TerminalStyle.frameToolLine("npm install", color: false)
        try MiniTest.expectEqual(framed, "    | npm install")
        let mono = TerminalStyle.frameToolLine("line\r", color: false)
        try MiniTest.expectEqual(mono, "    | line")
    }),
    ("terminalStyleMonochromeWhenColorFalse", {
        let phase = TerminalStyle.stylePhase("==> Ready", color: false)
        try MiniTest.expectEqual(phase, "==> Ready")
        try MiniTest.expect(!phase.contains("\u{001B}"))
        let warning = TerminalStyle.styleWarning("warning: x", color: false)
        try MiniTest.expectEqual(warning, "warning: x")
        try MiniTest.expect(!warning.contains("\u{001B}"))
        let error = TerminalStyle.styleError("error: y", color: false)
        try MiniTest.expectEqual(error, "error: y")
        try MiniTest.expect(!error.contains("\u{001B}"))
        let success = TerminalStyle.styleSuccess("success", color: false)
        try MiniTest.expectEqual(success, "success")
        try MiniTest.expect(!success.contains("\u{001B}"))
    }),
    ("terminalStyleSuccessUsesGreen", {
        let success = TerminalStyle.styleSuccess("success", color: true)
        try MiniTest.expect(success.contains(TerminalStyle.ansiSuccessGreen))
        try MiniTest.expect(success.contains(TerminalStyle.ansiBold))
        try MiniTest.expectEqual(TerminalStyle.stripANSI(success), "success")
        try MiniTest.expect(!success.contains(TerminalStyle.ansiErrorRed))
        try MiniTest.expect(!success.contains(TerminalStyle.ansiWarningYellow))
    }),
    ("terminalStyleMutedDistinctFromInfoDim", {
        let muted = TerminalStyle.styleMuted("stopped", color: true)
        let info = TerminalStyle.styleInfo("stopped", color: true)
        try MiniTest.expect(muted.contains(TerminalStyle.ansiMutedGray))
        try MiniTest.expect(muted.contains(TerminalStyle.ansiBold))
        try MiniTest.expect(!muted.contains(TerminalStyle.ansiDim))
        try MiniTest.expect(info.contains(TerminalStyle.ansiDim))
        try MiniTest.expect(!info.contains(TerminalStyle.ansiMutedGray))
        try MiniTest.expect(muted != info)
        try MiniTest.expectEqual(TerminalStyle.stripANSI(muted), "stopped")
        try MiniTest.expectEqual(TerminalStyle.styleMuted("stopped", color: false), "stopped")
    }),
    ("terminalStylePhaseItemParentheticalWhite", {
        let line = TerminalStyle.stylePhase(
            "==> Running postStartCommand (feature 1)",
            color: true
        )
        try MiniTest.expectEqual(
            TerminalStyle.stripANSI(line),
            "==> Running postStartCommand (feature 1)"
        )
        try MiniTest.expect(line.contains(TerminalStyle.ansiPhaseCyan))
        try MiniTest.expect(line.contains(TerminalStyle.ansiBold))
        // Item is white (bold default), not blue-wrapped alone as full line.
        let item = TerminalStyle.styleCommand("(feature 1)", color: true)
        try MiniTest.expect(line.contains(item))
        let head = TerminalStyle.stylePhaseHead("==> Running postStartCommand ", color: true)
        try MiniTest.expect(line.hasPrefix(head) || line.contains(head))
    }),
    ("terminalStylePhaseItemResourceTokenWhite", {
        let line = TerminalStyle.stylePhase("==> Pulling image alpine:3.20", color: true)
        try MiniTest.expectEqual(TerminalStyle.stripANSI(line), "==> Pulling image alpine:3.20")
        try MiniTest.expect(line.contains(TerminalStyle.styleCommand("alpine:3.20", color: true)))
        try MiniTest.expect(line.contains(TerminalStyle.ansiPhaseCyan))
    }),
    ("terminalStylePhaseNoItemAllBlue", {
        let line = TerminalStyle.stylePhase("==> Ready", color: true)
        try MiniTest.expectEqual(TerminalStyle.stripANSI(line), "==> Ready")
        try MiniTest.expect(line.contains(TerminalStyle.ansiPhaseCyan))
        // No separate command-styled segment beyond the solid phase head.
        try MiniTest.expectEqual(
            line,
            TerminalStyle.stylePhaseHead("==> Ready", color: true)
        )
    }),
    ("terminalStylePhaseItemShortCreateNameWhite", {
        try MiniTest.expect(TerminalStyle.looksLikePhaseItem("my-app"))
        try MiniTest.expect(TerminalStyle.looksLikePhaseItem("adev-myapp-abc123def456"))
        try MiniTest.expect(!TerminalStyle.looksLikePhaseItem("Ready"))
        let line = TerminalStyle.stylePhase("==> Reusing running container my-app", color: true)
        try MiniTest.expectEqual(
            TerminalStyle.stripANSI(line),
            "==> Reusing running container my-app"
        )
        try MiniTest.expect(line.contains(TerminalStyle.styleCommand("my-app", color: true)))
    }),
    ("terminalStylePhaseItemMonochromeUnchanged", {
        let line = TerminalStyle.stylePhase(
            "==> Running postStartCommand (feature 1)",
            color: false
        )
        try MiniTest.expectEqual(line, "==> Running postStartCommand (feature 1)")
        try MiniTest.expect(!line.contains("\u{001B}"))
    }),
]
