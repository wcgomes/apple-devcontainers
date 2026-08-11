import Foundation

/// Progress and policy warnings on stderr.
///
/// - Progress (`==> …`) honors `ADEVCONTAINER_QUIET=1` / `enabled`.
/// - Policy warnings always emit in product use (never silent under QUIET).
public enum StatusPrinter {
    /// Progress lines only. False when `ADEVCONTAINER_QUIET=1`. Tests may set false.
    nonisolated(unsafe) public static var enabled: Bool = ProcessInfo.processInfo.environment["ADEVCONTAINER_QUIET"] != "1"

    /// Test-only: suppress warning stderr (product never sets). `onWarning` still fires.
    nonisolated(unsafe) public static var suppressWarningStderr: Bool = false

    /// Test seam: invoked for every warning (even when stderr is suppressed).
    nonisolated(unsafe) public static var onWarning: ((String) -> Void)?

    public static func status(_ message: String) {
        guard enabled else { return }
        FileHandle.standardError.write(Data("==> \(message)\n".utf8))
    }

    /// Policy warning on stderr (`warning: …`). Ignores QUIET/`enabled`; always emits unless tests suppress.
    public static func warning(_ message: String) {
        onWarning?(message)
        guard !suppressWarningStderr else { return }
        FileHandle.standardError.write(Data("warning: \(message)\n".utf8))
    }
}

