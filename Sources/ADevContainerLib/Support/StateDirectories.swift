import Foundation

/// Single resolver for every host temp or retained-state root the CLI creates or reads
/// (recovery sessions, resume indexes, guest staging, clone recovery checkouts).
///
/// The test runner sets `isolatedRoot` to a per-run scratch directory at startup so the
/// suite never reads or deletes a developer's real recovery state. On macOS Foundation
/// ignores `TMPDIR`, so an environment override cannot provide that isolation. There is
/// deliberately no user-facing switch: production always uses the system locations.
enum StateDirectories {
    nonisolated(unsafe) static var isolatedRoot: URL?

    /// Process temporary directory (or `<isolatedRoot>/tmp` under the test runner).
    static func temporaryDirectory(_ fileManager: FileManager = .default) -> URL {
        if let isolatedRoot {
            return isolatedRoot.appendingPathComponent("tmp", isDirectory: true)
        }
        return fileManager.temporaryDirectory
    }

    /// `~/Library/Application Support` (or `<isolatedRoot>/application-support` under the
    /// test runner). Falls back to the temporary directory like the original callers.
    static func applicationSupportDirectory(_ fileManager: FileManager = .default) -> URL {
        if let isolatedRoot {
            return isolatedRoot.appendingPathComponent("application-support", isDirectory: true)
        }
        return fileManager.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? URL(fileURLWithPath: NSTemporaryDirectory())
    }
}
