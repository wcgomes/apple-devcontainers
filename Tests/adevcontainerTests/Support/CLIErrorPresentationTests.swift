import Foundation
@testable import ADevContainerLib

nonisolated(unsafe) let cliErrorPresentationTests: [(String, () throws -> Void)] = [
    ("cliErrorFormattedStructuredMonochrome", {
        let err = CLIError(
            code: CLIErrorCode.lifecycleFailed,
            property: "postCreateCommand",
            message: "postCreateCommand exited 1",
            hint: "Check the hook script"
        )
        let text = err.formatted(color: false)
        try MiniTest.expect(text.hasPrefix("error: postCreateCommand exited 1"))
        try MiniTest.expect(!text.contains("error[lifecycle_failed]"))
        try MiniTest.expect(text.contains("\n  property: postCreateCommand\n"))
        try MiniTest.expect(text.contains("\n  hint: Check the hook script"))
        try MiniTest.expect(!text.contains("\u{001B}"))
    }),
    ("cliErrorFormattedColorStripKeepsStructure", {
        let err = CLIError(
            code: "populate_failed",
            message: "clone failed",
            hint: "check network"
        )
        let colored = err.formatted(color: true)
        try MiniTest.expect(colored.contains("\u{001B}"))
        let hasRed =
            colored.contains(TerminalStyle.ansiErrorRed)
            || colored.contains(TerminalStyle.ansiBrightRed)
            || colored.contains(TerminalStyle.ansiRed)
        try MiniTest.expect(hasRed)
        // Label red; body/property/hint dim (no yellow/cyan bleed).
        try MiniTest.expect(colored.contains(TerminalStyle.ansiDim))
        try MiniTest.expect(!colored.contains(TerminalStyle.ansiWarningYellow))
        try MiniTest.expect(!colored.contains(TerminalStyle.ansiBrightYellow))
        try MiniTest.expect(!colored.contains(TerminalStyle.ansiYellow))
        let stripped = TerminalStyle.stripANSI(colored)
        try MiniTest.expect(stripped.hasPrefix("error: clone failed"))
        try MiniTest.expect(!stripped.contains("error[populate_failed]"))
        try MiniTest.expect(stripped.contains("  hint: check network"))
        // Hint line is cyan, not red-labeled or dim body.
        let hintLine = colored.split(separator: "\n").first(where: { $0.contains("hint:") }).map(String.init) ?? ""
        try MiniTest.expect(hintLine.contains(TerminalStyle.ansiHintCyan))
        try MiniTest.expect(!hintLine.contains(TerminalStyle.ansiErrorRed))
        try MiniTest.expect(!hintLine.contains(TerminalStyle.ansiDim))
    }),
    ("cliErrorJSONOutputUncoloredParseable", {
        let err = CLIError(
            code: CLIErrorCode.runtimeFailed,
            property: "image",
            message: "pull failed",
            hint: "retry"
        )
        let data = CLIErrorOutput.data(for: err, json: true)
        let text = String(data: data, encoding: .utf8) ?? ""
        try MiniTest.expect(!text.contains("\u{001B}"))
        let obj = try JSONSerialization.jsonObject(with: data) as? [String: Any]
        try MiniTest.expectEqual(obj?["outcome"] as? String, "error")
        try MiniTest.expectEqual(obj?["code"] as? String, CLIErrorCode.runtimeFailed)
        try MiniTest.expectEqual(obj?["message"] as? String, "pull failed")
        try MiniTest.expectEqual(obj?["property"] as? String, "image")
        try MiniTest.expectEqual(obj?["hint"] as? String, "retry")
    }),
    ("cliErrorHumanOutputUsesFormatted", {
        let err = CLIError(code: "usage", message: "bad args")
        let data = CLIErrorOutput.data(for: err, json: false)
        let text = TerminalStyle.stripANSI(String(data: data, encoding: .utf8) ?? "")
        try MiniTest.expect(text.hasPrefix("error: bad args\n"))
    }),
    ("cliErrorDiagnosticSnippetStaysRawUnframed", {
        // Simulate attaching raw tool capture into the message (product pattern).
        let rawDiag = "TOOL_FAIL_MARK\nmore context"
        try MiniTest.expect(!rawDiag.contains("| "))
        let err = CLIError(
            code: CLIErrorCode.lifecycleFailed,
            property: "postCreateCommand",
            message: "hook failed: \(rawDiag)",
            hint: "see logs"
        )
        let text = err.formatted(color: false)
        try MiniTest.expect(text.contains("TOOL_FAIL_MARK"))
        try MiniTest.expect(!text.contains("| TOOL_FAIL_MARK"))
        // JSON path also keeps raw text.
        let data = CLIErrorOutput.data(for: err, json: true)
        let obj = try JSONSerialization.jsonObject(with: data) as? [String: Any]
        let msg = obj?["message"] as? String ?? ""
        try MiniTest.expect(msg.contains("TOOL_FAIL_MARK"))
        try MiniTest.expect(!msg.contains("| TOOL_FAIL_MARK"))
    }),
    ("cliErrorLocalizedDescriptionUsesMessage", {
        // Soft-fail paths use error.localizedDescription; without LocalizedError,
        // NSError bridges to opaque "ADevContainerLib.CLIError error 1".
        let err = CLIError(
            code: CLIErrorCode.runtimeFailed,
            message: "VSIX download HTTP 404 for https://example/vsix"
        )
        let asError: Error = err
        try MiniTest.expectEqual(asError.localizedDescription, err.message)
        try MiniTest.expect(!asError.localizedDescription.contains("CLIError error"))
        try MiniTest.expectEqual(err.errorDescription, err.message)
    }),
]
