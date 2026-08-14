import Foundation
#if canImport(Darwin)
import Darwin
#elseif canImport(Glibc)
import Glibc
#endif

/// Post-success human presentation: outcome digest (stdout) then connection hints (stderr).
///
/// Terminal order for human `up`/`clone`/`rebuild`:
/// ```
/// ==> Ready
/// outcome: success
/// …
///
/// Connect with: …
/// Open in VS Code with: …
/// ```
public enum SuccessPresentation {
    /// Test seam for success JSON (default: process stdout).
    nonisolated(unsafe) public static var writeStdout: ((Data) -> Void)?

    /// Set when a command writes success JSON at the `waitFor` point. The entry
    /// point must not print a second copy — including if a later hook then fails.
    nonisolated(unsafe) public static var didEmitSuccessJSON = false

    /// Machine-readable success JSON at the `waitFor` connection point (not at process exit).
    public static func emitSuccessJSON(_ json: String) {
        let payload = json.hasSuffix("\n") ? json : json + "\n"
        let data = Data(payload.utf8)
        if let writeStdout {
            writeStdout(data)
        } else {
            FileHandle.standardOutput.write(data)
        }
        #if canImport(Darwin) || canImport(Glibc)
        fflush(nil)
        #endif
        didEmitSuccessJSON = true
    }

    public static func emitSuccessJSONIfRequested(_ json: String, jsonOutput: Bool) {
        guard jsonOutput else { return }
        emitSuccessJSON(json)
    }

    /// Human key/value digest on stdout (not used for `--json`).
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

    /// Clone human digest: up-shape fields plus clone-only `gitUrl` / `workspaceVolume`.
    public static func emitHumanDigest(_ result: CloneResult) {
        emitHumanDigest(
            outcome: result.outcome,
            containerId: result.containerId,
            remoteUser: result.remoteUser,
            remoteWorkspaceFolder: result.remoteWorkspaceFolder,
            containerName: result.containerName
        )
        let pad = TerminalStyle.nestIndent
        print("\(pad)gitUrl: \(result.gitUrl)")
        print("\(pad)workspaceVolume: \(result.workspaceVolume)")
    }

    /// Flush stdout then emit connection hints on stderr with a leading blank line.
    /// Skipped when `--vscode` opened the editor (hints are redundant).
    public static func emitConnectionHintsIfNeeded(openVSCode: Bool, nameOrId: String) {
        guard !openVSCode else { return }
        // Prefer libc fflush — FileHandle.synchronizeFile throws on non-seekable pipes (tests).
        #if canImport(Darwin) || canImport(Glibc)
        fflush(nil)
        #endif
        StatusPrinter.connectionHint(nameOrId: nameOrId, leadingBlank: true)
    }
}
