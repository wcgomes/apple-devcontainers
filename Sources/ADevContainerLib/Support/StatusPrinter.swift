import Foundation

/// Progress lines on stderr (`==> …`). Disabled when `ADEVCONTAINER_QUIET=1`.
public enum StatusPrinter {
    /// Tests set this to `false`. Defaults from env at first use.
    nonisolated(unsafe) public static var enabled: Bool = ProcessInfo.processInfo.environment["ADEVCONTAINER_QUIET"] != "1"

    public static func status(_ message: String) {
        guard enabled else { return }
        FileHandle.standardError.write(Data("==> \(message)\n".utf8))
    }

    /// Volume-style warning line on stderr (`warning: …`). Honors `enabled`.
    public static func warning(_ message: String) {
        guard enabled else { return }
        FileHandle.standardError.write(Data("warning: \(message)\n".utf8))
    }
}

