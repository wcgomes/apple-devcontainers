import Foundation
#if canImport(Darwin)
import Darwin
#endif

/// Post-success human presentation: outcome digest (stdout) then connection hints (stderr).
///
/// Terminal order for human `up`/`rebuild`:
/// ```
/// ==> Ready
/// outcome: success
/// …
///
/// Connect with: …
/// Open in VS Code with: …
/// ```
public enum SuccessPresentation {
    /// Human key/value digest on stdout (not used for `--json` / clone JSON).
    public static func emitHumanDigest(
        outcome: String,
        containerId: String,
        remoteUser: String,
        remoteWorkspaceFolder: String,
        containerName: String?
    ) {
        // Nested under `==> Ready` (same indent as connection hints).
        let pad = TerminalStyle.nestIndent
        // Label plain; `success` value green when color is on.
        let outcomeValue =
            outcome == "success"
            ? TerminalStyle.styleSuccess(outcome)
            : outcome
        print("\(pad)outcome: \(outcomeValue)")
        print("\(pad)containerId: \(containerId)")
        print("\(pad)remoteUser: \(remoteUser)")
        print("\(pad)remoteWorkspaceFolder: \(remoteWorkspaceFolder)")
        if let containerName {
            print("\(pad)containerName: \(containerName)")
        }
    }

    public static func emitHumanDigest(_ result: UpResult) {
        emitHumanDigest(
            outcome: result.outcome,
            containerId: result.containerId,
            remoteUser: result.remoteUser,
            remoteWorkspaceFolder: result.remoteWorkspaceFolder,
            containerName: result.containerName
        )
    }

    public static func emitHumanDigest(_ result: RebuildResult) {
        emitHumanDigest(
            outcome: result.outcome,
            containerId: result.containerId,
            remoteUser: result.remoteUser,
            remoteWorkspaceFolder: result.remoteWorkspaceFolder,
            containerName: result.containerName
        )
    }

    /// Flush stdout then emit connection hints on stderr with a leading blank line.
    /// Skipped when `--vscode` opened the editor (hints are redundant).
    public static func emitConnectionHintsIfNeeded(openVSCode: Bool, nameOrId: String) {
        guard !openVSCode else { return }
        // Prefer libc fflush — FileHandle.synchronizeFile throws on non-seekable pipes (tests).
        #if canImport(Darwin)
        fflush(stdout)
        #endif
        StatusPrinter.connectionHint(nameOrId: nameOrId, leadingBlank: true)
    }
}
