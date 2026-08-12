import Foundation
#if canImport(Darwin)
import Darwin
#elseif canImport(Glibc)
import Glibc
#endif
@testable import ADevContainerLib

private func withStatusPrinterCapture(_ body: () throws -> Void) throws -> String {
    let previousEnabled = StatusPrinter.enabled
    let previousSuppress = StatusPrinter.suppressWarningStderr
    let previousOn = StatusPrinter.onWarning
    let previousWrite = StatusPrinter.writeStderr
    let previousPhase = StatusPrinter.hasEmittedPhase
    let previousColor = TerminalStyle.colorOverride
    defer {
        StatusPrinter.enabled = previousEnabled
        StatusPrinter.suppressWarningStderr = previousSuppress
        StatusPrinter.onWarning = previousOn
        StatusPrinter.writeStderr = previousWrite
        StatusPrinter.hasEmittedPhase = previousPhase
        TerminalStyle.colorOverride = previousColor
    }
    TerminalStyle.colorOverride = false
    StatusPrinter.resetSectionState()
    var buffer = Data()
    StatusPrinter.writeStderr = { buffer.append($0) }
    try body()
    return String(data: buffer, encoding: .utf8) ?? ""
}

nonisolated(unsafe) let statusPrinterTests: [(String, () throws -> Void)] = [
    ("statusPrinterPhaseUsesMonochromePrefix", {
        let out = try withStatusPrinterCapture {
            StatusPrinter.enabled = true
            StatusPrinter.status("Resolving configuration")
        }
        try MiniTest.expect(out.contains("==> Resolving configuration\n"))
        try MiniTest.expect(out.hasPrefix("==> "))
        try MiniTest.expect(!out.contains("\u{001B}"))
    }),
    ("statusPrinterQuietSilencesPhaseAndInfo", {
        let out = try withStatusPrinterCapture {
            StatusPrinter.enabled = false
            StatusPrinter.status("should-be-silent")
            StatusPrinter.info("info silent")
            StatusPrinter.detail("detail silent")
            StatusPrinter.connectionHint(nameOrId: "ctr")
        }
        try MiniTest.expectEqual(out, "")
        try MiniTest.expect(!out.contains("==>"))
        try MiniTest.expect(!out.contains("Connect with"))
    }),
    ("statusPrinterWarningAlwaysEmitsUnderQuiet", {
        var warnings: [String] = []
        let out = try withStatusPrinterCapture {
            StatusPrinter.enabled = false
            StatusPrinter.suppressWarningStderr = false
            StatusPrinter.onWarning = { warnings.append($0) }
            StatusPrinter.warning("skipped docker-outside-of-docker")
        }
        try MiniTest.expectEqual(warnings, ["skipped docker-outside-of-docker"])
        try MiniTest.expect(out.contains("warning: skipped docker-outside-of-docker\n"))
    }),
    ("statusPrinterSuppressWarningStderrPreserved", {
        var warnings: [String] = []
        let out = try withStatusPrinterCapture {
            StatusPrinter.enabled = true
            StatusPrinter.suppressWarningStderr = true
            StatusPrinter.onWarning = { warnings.append($0) }
            StatusPrinter.warning("still-callback")
        }
        try MiniTest.expectEqual(warnings, ["still-callback"])
        try MiniTest.expectEqual(out, "")
    }),
    ("statusPrinterSectionSpacingBlankBeforeNonFirstPhase", {
        let out = try withStatusPrinterCapture {
            StatusPrinter.enabled = true
            StatusPrinter.status("First")
            StatusPrinter.status("Second")
            StatusPrinter.status("Third")
        }
        // First phase: no leading blank from section rule.
        try MiniTest.expect(out.hasPrefix("==> First\n"))
        try MiniTest.expect(out.contains("==> First\n\n==> Second\n"))
        try MiniTest.expect(out.contains("==> Second\n\n==> Third\n"))
    }),
    ("statusPrinterQuietNoBlankPlaceholdersForSuppressedPhases", {
        let out = try withStatusPrinterCapture {
            StatusPrinter.enabled = false
            StatusPrinter.status("A")
            StatusPrinter.status("B")
            StatusPrinter.enabled = true
            StatusPrinter.status("Only")
        }
        try MiniTest.expectEqual(out, "==> Only\n")
        try MiniTest.expect(!out.hasPrefix("\n"))
    }),
    ("statusPrinterConnectionHintIsInfoNotPhase", {
        let out = try withStatusPrinterCapture {
            StatusPrinter.enabled = true
            StatusPrinter.connectionHint(nameOrId: "my-ctr")
        }
        try MiniTest.expect(out.contains("Connect with: adevcontainer exec -it --name my-ctr\n"))
        try MiniTest.expect(out.contains("Open in VS Code with: adevcontainer start --name my-ctr --vscode\n"))
        try MiniTest.expect(!out.contains("==> Connect with"))
        try MiniTest.expect(!out.contains("==> Open in VS Code"))
        // Indented info form.
        try MiniTest.expect(out.contains("    Connect with:"))
    }),
    ("statusPrinterConnectionHintSilencedUnderQuiet", {
        let out = try withStatusPrinterCapture {
            StatusPrinter.enabled = false
            StatusPrinter.connectionHint(nameOrId: "x")
        }
        try MiniTest.expect(!out.contains("Connect with"))
        try MiniTest.expect(!out.contains("Open in VS Code"))
    }),
    ("statusPrinterConnectionHintCommandEmphasizedWhenColorEnabled", {
        let previousEnabled = StatusPrinter.enabled
        let previousWrite = StatusPrinter.writeStderr
        let previousColor = TerminalStyle.colorOverride
        defer {
            StatusPrinter.enabled = previousEnabled
            StatusPrinter.writeStderr = previousWrite
            TerminalStyle.colorOverride = previousColor
        }
        TerminalStyle.colorOverride = true
        var buffer = Data()
        StatusPrinter.writeStderr = { buffer.append($0) }
        StatusPrinter.enabled = true
        StatusPrinter.connectionHint(nameOrId: "ctr")
        let out = String(data: buffer, encoding: .utf8) ?? ""
        try MiniTest.expect(out.contains(TerminalStyle.ansiDim))
        try MiniTest.expect(out.contains(TerminalStyle.ansiBold))
        try MiniTest.expect(TerminalStyle.stripANSI(out).contains("Connect with: adevcontainer exec -it --name ctr"))
        // Label dim, command bold.
        try MiniTest.expect(out.contains(TerminalStyle.styleInfo("Connect with: ", color: true)))
        try MiniTest.expect(out.contains(TerminalStyle.styleCommand("adevcontainer exec -it --name ctr", color: true)))
        try MiniTest.expect(out.contains(TerminalStyle.styleInfo("Open in VS Code with: ", color: true)))
        try MiniTest.expect(out.contains(TerminalStyle.styleCommand("adevcontainer start --name ctr --vscode", color: true)))
    }),
    ("statusPrinterStatusItemWhiteWhenColorEnabled", {
        let previousEnabled = StatusPrinter.enabled
        let previousWrite = StatusPrinter.writeStderr
        let previousColor = TerminalStyle.colorOverride
        let previousPhase = StatusPrinter.hasEmittedPhase
        defer {
            StatusPrinter.enabled = previousEnabled
            StatusPrinter.writeStderr = previousWrite
            TerminalStyle.colorOverride = previousColor
            StatusPrinter.hasEmittedPhase = previousPhase
        }
        TerminalStyle.colorOverride = true
        StatusPrinter.hasEmittedPhase = false
        var buffer = Data()
        StatusPrinter.writeStderr = { buffer.append($0) }
        StatusPrinter.enabled = true
        StatusPrinter.status("Deleting container", item: "adev-app-deadbeef")
        let out = String(data: buffer, encoding: .utf8) ?? ""
        try MiniTest.expectEqual(
            TerminalStyle.stripANSI(out),
            "==> Deleting container adev-app-deadbeef\n"
        )
        try MiniTest.expect(out.contains(TerminalStyle.ansiPhaseCyan))
        try MiniTest.expect(
            out.contains(TerminalStyle.styleCommand("adev-app-deadbeef", color: true))
        )
        try MiniTest.expect(
            out.contains(TerminalStyle.stylePhaseHead("==> Deleting container ", color: true))
        )
    }),
    ("statusPrinterConnectionHintLeadingBlank", {
        let out = try withStatusPrinterCapture {
            StatusPrinter.enabled = true
            StatusPrinter.connectionHint(nameOrId: "x", leadingBlank: true)
        }
        try MiniTest.expect(out.hasPrefix("\n"))
        try MiniTest.expect(out.contains("Connect with: adevcontainer exec -it --name x\n"))
    }),
    ("statusPrinterWarningDoesNotDoublePrefix", {
        let out = try withStatusPrinterCapture {
            StatusPrinter.enabled = true
            StatusPrinter.suppressWarningStderr = false
            StatusPrinter.warning("warning: already-prefixed")
        }
        try MiniTest.expect(out.contains("warning: already-prefixed\n"))
        try MiniTest.expect(!out.contains("warning: warning:"))
    }),
    ("statusPrinterWarningUsesYellowWhenColorEnabled", {
        let previousEnabled = StatusPrinter.enabled
        let previousSuppress = StatusPrinter.suppressWarningStderr
        let previousWrite = StatusPrinter.writeStderr
        let previousColor = TerminalStyle.colorOverride
        defer {
            StatusPrinter.enabled = previousEnabled
            StatusPrinter.suppressWarningStderr = previousSuppress
            StatusPrinter.writeStderr = previousWrite
            TerminalStyle.colorOverride = previousColor
        }
        TerminalStyle.colorOverride = true
        var buffer = Data()
        StatusPrinter.writeStderr = { buffer.append($0) }
        StatusPrinter.enabled = true
        StatusPrinter.suppressWarningStderr = false
        StatusPrinter.warning("colored-warn")
        let out = String(data: buffer, encoding: .utf8) ?? ""
        let hasYellow =
            out.contains(TerminalStyle.ansiWarningYellow)
            || out.contains(TerminalStyle.ansiBrightYellow)
            || out.contains(TerminalStyle.ansiYellow)
        try MiniTest.expect(hasYellow)
        try MiniTest.expect(out.contains(TerminalStyle.ansiDim))
        try MiniTest.expect(TerminalStyle.stripANSI(out).contains("warning: colored-warn\n"))
        // Body text is dim, not yellow-wrapped as a whole line.
        let stripped = TerminalStyle.stripANSI(out)
        try MiniTest.expect(stripped.hasPrefix("warning: "))
        try MiniTest.expect(out.contains(TerminalStyle.styleWarningBody("colored-warn", color: true).trimmingCharacters(in: .newlines)) || out.contains(TerminalStyle.ansiDim + "colored-warn"))
    }),
    ("successPresentationCloneHumanDigestIncludesCloneFields", {
        let previousColor = TerminalStyle.colorOverride
        defer { TerminalStyle.colorOverride = previousColor }
        TerminalStyle.colorOverride = false
        let result = CloneResult(
            outcome: "success",
            containerId: "ctr-1",
            remoteUser: "vscode",
            remoteWorkspaceFolder: "/workspaces/app",
            containerName: "adev-app-deadbeef",
            gitUrl: "https://github.com/org/app",
            workspaceVolume: "adev-app-deadbeef-ws"
        )
        var captured = ""
        try withCapturedStdout({
            SuccessPresentation.emitHumanDigest(result)
            // print() may fully-buffer when fd 1 is a pipe; flush before capture closes.
            #if canImport(Darwin) || canImport(Glibc)
            fflush(nil)
            #endif
        }, capture: &captured)
        let pad = TerminalStyle.nestIndent
        try MiniTest.expect(captured.contains("\(pad)outcome: success\n"), "stdout was: \(captured)")
        try MiniTest.expect(captured.contains("\(pad)containerId: ctr-1\n"))
        try MiniTest.expect(captured.contains("\(pad)remoteUser: vscode\n"))
        try MiniTest.expect(captured.contains("\(pad)remoteWorkspaceFolder: /workspaces/app\n"))
        try MiniTest.expect(captured.contains("\(pad)containerName: adev-app-deadbeef\n"))
        try MiniTest.expect(captured.contains("\(pad)gitUrl: https://github.com/org/app\n"))
        try MiniTest.expect(captured.contains("\(pad)workspaceVolume: adev-app-deadbeef-ws\n"))
        try MiniTest.expect(!captured.contains("{"), "human digest is not JSON")
    }),
    ("successPresentationCloneJsonShapeUnchanged", {
        let result = CloneResult(
            outcome: "success",
            containerId: "ctr-1",
            remoteUser: "root",
            remoteWorkspaceFolder: "/workspaces/app",
            containerName: "adev-app-deadbeef",
            gitUrl: "https://github.com/org/app",
            workspaceVolume: "adev-app-deadbeef-ws"
        )
        let obj = try JSONSerialization.jsonObject(with: try result.jsonData()) as! [String: Any]
        try MiniTest.expectEqual(obj["outcome"] as? String, "success")
        try MiniTest.expectEqual(obj["containerId"] as? String, "ctr-1")
        try MiniTest.expectEqual(obj["remoteUser"] as? String, "root")
        try MiniTest.expectEqual(obj["remoteWorkspaceFolder"] as? String, "/workspaces/app")
        try MiniTest.expectEqual(obj["containerName"] as? String, "adev-app-deadbeef")
        try MiniTest.expectEqual(obj["gitUrl"] as? String, "https://github.com/org/app")
        try MiniTest.expectEqual(obj["workspaceVolume"] as? String, "adev-app-deadbeef-ws")
    }),
    ("successPresentationConnectionHintsSuppressedWithVSCode", {
        let previousEnabled = StatusPrinter.enabled
        defer { StatusPrinter.enabled = previousEnabled }
        StatusPrinter.enabled = true
        var stderr = ""
        try withCapturedStderr({
            SuccessPresentation.emitConnectionHintsIfNeeded(openVSCode: true, nameOrId: "ctr")
        }, capture: &stderr)
        try MiniTest.expectEqual(stderr, "")
        try withCapturedStderr({
            SuccessPresentation.emitConnectionHintsIfNeeded(openVSCode: false, nameOrId: "ctr")
        }, capture: &stderr)
        try MiniTest.expect(stderr.contains("Connect with:"))
    }),
]
