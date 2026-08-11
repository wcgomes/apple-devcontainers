import Foundation

/// Progress, info, and policy warnings on stderr.
///
/// - Progress (`==> …`) and quieter `info` honor `ADEVCONTAINER_QUIET=1` / `enabled`.
/// - Policy warnings always emit in product use (never silent under QUIET).
/// - Framed tool body lines are written by ProcessRunner (not QUIET-gated).
/// - Section spacing: blank line before each top-level phase after the first emitted phase.
public enum StatusPrinter {
    /// Progress and info lines only. False when `ADEVCONTAINER_QUIET=1`. Tests may set false.
    nonisolated(unsafe) public static var enabled: Bool = ProcessInfo.processInfo.environment["ADEVCONTAINER_QUIET"] != "1"

    /// Test-only: suppress warning stderr (product never sets). `onWarning` still fires.
    nonisolated(unsafe) public static var suppressWarningStderr: Bool = false

    /// Test seam: invoked for every warning (even when stderr is suppressed).
    nonisolated(unsafe) public static var onWarning: ((String) -> Void)?

    /// Whether a top-level phase line has been emitted this process (section spacing).
    /// Resettable in tests via `resetSectionState()`.
    nonisolated(unsafe) public static var hasEmittedPhase: Bool = false

    /// Optional stderr sink for tests (default: `FileHandle.standardError`).
    nonisolated(unsafe) public static var writeStderr: ((Data) -> Void)?

    /// Reset section spacing state (tests / after a long suite).
    public static func resetSectionState() {
        hasEmittedPhase = false
    }

    // MARK: - Progress / phase

    /// Top-level phase: `==> message`. QUIET-gated. Blank line before non-first phase.
    ///
    /// When `item` is set, it is rendered bold white after the blue head:
    /// `==> Deleting container` + `adev-…` → blue head, white target.
    /// When `item` is nil, `stylePhase` still auto-highlights trailing parentheticals/resource tokens.
    public static func status(_ message: String, item: String? = nil) {
        guard enabled else { return }
        var payload = ""
        if hasEmittedPhase {
            payload += "\n"
        }
        if let item, !item.isEmpty {
            let head = TerminalStyle.phasePrefix + message
            let headWithSpace = head.hasSuffix(" ") ? head : head + " "
            payload += TerminalStyle.stylePhaseHead(headWithSpace)
                + TerminalStyle.styleCommand(item)
                + "\n"
        } else {
            let line = TerminalStyle.phasePrefix + message
            payload += TerminalStyle.stylePhase(line) + "\n"
        }
        write(payload)
        hasEmittedPhase = true
    }

    /// Nested progress under a phase line (`level` 1 → 4 spaces). Honors `enabled`/QUIET.
    public static func detail(_ message: String, level: Int = 1) {
        guard enabled else { return }
        let pad = String(repeating: " ", count: 2 + max(level, 1) * 2)
        let text = "\(pad)\(message)"
        write(TerminalStyle.styleInfo(text) + "\n")
    }

    /// Quieter informational line (indented, no `==>`). QUIET-gated.
    public static func info(_ message: String) {
        guard enabled else { return }
        let text = TerminalStyle.nestIndent + message
        write(TerminalStyle.styleInfo(text) + "\n")
    }

    /// Connection hints at info weight (not full phase). QUIET-gated with other info.
    /// Labels stay dim; command text is bold default (white on dark themes) for copy-paste emphasis.
    /// - Parameter leadingBlank: when true, emit a blank stderr line first (separates hints from a prior outcome digest on stdout).
    public static func connectionHint(nameOrId: String, leadingBlank: Bool = false) {
        guard enabled else { return }
        if leadingBlank {
            write("\n")
        }
        writeConnectionHint(
            label: "Connect with: ",
            command: "adevcontainer exec -it --name \(nameOrId)"
        )
        writeConnectionHint(
            label: "Open in VS Code with: ",
            command: "adevcontainer start --name \(nameOrId) --vscode"
        )
    }

    private static func writeConnectionHint(label: String, command: String) {
        let line = TerminalStyle.nestIndent
            + TerminalStyle.styleInfo(label)
            + TerminalStyle.styleCommand(command)
            + "\n"
        write(line)
    }

    // MARK: - Warnings

    /// Policy warning on stderr (`warning: …`). Ignores QUIET/`enabled`; always emits unless tests suppress.
    /// Multi-line messages: first line gets the `warning: ` prefix; subsequent lines pass through as-is.
    public static func warning(_ message: String) {
        onWarning?(message)
        guard !suppressWarningStderr else { return }
        let lines = message.split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
        var out = ""
        for (index, line) in lines.enumerated() {
            if index == 0 {
                // Avoid double-prefix if caller already included it.
                let body: String
                if line.hasPrefix(TerminalStyle.warningPrefix) {
                    body = String(line.dropFirst(TerminalStyle.warningPrefix.count))
                } else {
                    body = line
                }
                // Only the `warning: ` label is yellow; message body matches dim info gray.
                out += TerminalStyle.styleWarningLabel(TerminalStyle.warningPrefix)
                    + TerminalStyle.styleWarningBody(body)
                    + "\n"
            } else {
                // Continuations: dim body only (no repeated yellow label).
                out += TerminalStyle.styleWarningBody(line) + "\n"
            }
        }
        write(out)
    }

    // MARK: - Internals

    private static func write(_ string: String) {
        let data = Data(string.utf8)
        if let writeStderr {
            writeStderr(data)
        } else {
            FileHandle.standardError.write(data)
        }
    }
}
