import Foundation

// MARK: - Target / outcome

/// Inputs for a best-effort VS Code remote open (already product-resolved folder).
public struct VSCodeOpenTarget: Equatable, Sendable {
    public var containerId: String
    public var image: String
    public var remoteWorkspaceFolder: String
    public var containerName: String?
    public var remoteUser: String?

    public init(
        containerId: String,
        image: String,
        remoteWorkspaceFolder: String,
        containerName: String? = nil,
        remoteUser: String? = nil
    ) {
        self.containerId = containerId
        self.image = image
        self.remoteWorkspaceFolder = remoteWorkspaceFolder
        self.containerName = containerName
        self.remoteUser = remoteUser
    }
}

public enum VSCodeOpenOutcome: Equatable, Sendable {
    case notRequested
    case opened(uri: String)
    case skippedMissingCode
    case skippedEmptyFolder
    case skippedMissingImage
    case skippedMissingId
    case launchFailed(message: String)

    /// Host `code` launch succeeded — CLI attach hook for postAttach gating.
    public var isOpenSuccess: Bool {
        if case .opened = self { return true }
        return false
    }

    /// `--vscode` was set but open soft-failed or skipped (not a lifecycle failure by itself).
    public var isOpenSoftFail: Bool {
        switch self {
        case .notRequested, .opened:
            return false
        case .skippedMissingCode, .skippedEmptyFolder, .skippedMissingImage, .skippedMissingId, .launchFailed:
            return true
        }
    }
}

// MARK: - URI builder

public enum VSCodeRemoteURI {
    /// Compact JSON authority payload keys in stable order: `id`, `image`.
    public static func authorityJSON(id: String, image: String) -> String {
        // Manual compact encode keeps key order stable for tests (JSONSerialization does not).
        let idEsc = escapeJSONString(id)
        let imageEsc = escapeJSONString(image)
        return #"{"id":"\#(idEsc)","image":"\#(imageEsc)"}"#
    }

    /// Lowercase hex of UTF-8 bytes of compact `{"id","image"}` JSON.
    public static func authorityHex(id: String, image: String) -> String {
        let json = authorityJSON(id: id, image: image)
        return Data(json.utf8).map { String(format: "%02x", $0) }.joined()
    }

    /// `vscode-remote://apple-container+<hex><folder>` (folder appended after hex; not re-encoded).
    public static func folderURI(id: String, image: String, folder: String) -> String {
        let hex = authorityHex(id: id, image: image)
        return "vscode-remote://apple-container+\(hex)\(folder)"
    }

    private static func escapeJSONString(_ value: String) -> String {
        var out = ""
        out.reserveCapacity(value.count)
        for ch in value {
            switch ch {
            case "\\": out += "\\\\"
            case "\"": out += "\\\""
            case "\n": out += "\\n"
            case "\r": out += "\\r"
            case "\t": out += "\\t"
            default: out.append(ch)
            }
        }
        return out
    }
}

// MARK: - Launcher / discovery (mockable)

public protocol VSCodeCodeLaunching: Sendable {
    func launch(executable: String, arguments: [String]) throws -> ProcessResult
}

public struct ProcessVSCodeCodeLauncher: VSCodeCodeLaunching {
    public var runner: any ProcessRunning

    public init(runner: any ProcessRunning = FoundationProcessRunner()) {
        self.runner = runner
    }

    public func launch(executable: String, arguments: [String]) throws -> ProcessResult {
        try runner.run(
            executable: executable,
            arguments: arguments,
            environment: nil,
            currentDirectory: nil,
            stdinData: nil
        )
    }
}

public protocol VSCodeCodeResolving: Sendable {
    /// Resolve a usable `code` CLI path, or nil if none found.
    func resolveCodeExecutable() -> String?
}

public struct DefaultVSCodeCodeResolver: VSCodeCodeResolving {
    public static let standardMacAppPath =
        "/Applications/Visual Studio Code.app/Contents/Resources/app/bin/code"
    public static let insidersMacAppPath =
        "/Applications/Visual Studio Code - Insiders.app/Contents/Resources/app/bin/code"

    public var pathEnv: String?
    public var isExecutable: @Sendable (String) -> Bool
    public var tryInsiders: Bool

    public init(
        pathEnv: String? = ProcessInfo.processInfo.environment["PATH"],
        isExecutable: @escaping @Sendable (String) -> Bool = { path in
            FileManager.default.isExecutableFile(atPath: path)
        },
        tryInsiders: Bool = true
    ) {
        self.pathEnv = pathEnv
        self.isExecutable = isExecutable
        self.tryInsiders = tryInsiders
    }

    public func resolveCodeExecutable() -> String? {
        if let pathEnv {
            for dir in pathEnv.split(separator: ":") {
                let candidate = "\(dir)/code"
                if isExecutable(candidate) {
                    return candidate
                }
            }
        }
        if isExecutable(Self.standardMacAppPath) {
            return Self.standardMacAppPath
        }
        if tryInsiders, isExecutable(Self.insidersMacAppPath) {
            return Self.insidersMacAppPath
        }
        return nil
    }
}

// MARK: - Open orchestration

public enum VSCodeOpen {
    /// Test override for process launch.
    nonisolated(unsafe) public static var launcherOverride: (any VSCodeCodeLaunching)?
    /// Test override for `code` discovery.
    nonisolated(unsafe) public static var resolverOverride: (any VSCodeCodeResolving)?
    /// Test override for nameConfig write root (Application Support equivalent).
    nonisolated(unsafe) public static var nameConfigRootOverride: String?
    /// When false, skip optional nameConfig write (default true).
    nonisolated(unsafe) public static var writeNameConfigEnabled: Bool = true

    /// Best-effort open. Never throws; lifecycle callers ignore outcome for exit code.
    @discardableResult
    public static func bestEffortOpen(target: VSCodeOpenTarget) -> VSCodeOpenOutcome {
        let folder = target.remoteWorkspaceFolder.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !folder.isEmpty else {
            StatusPrinter.warning(
                "VS Code open skipped: remote workspace folder is empty (use resolved product folder, not raw config)"
            )
            return .skippedEmptyFolder
        }
        let image = target.image.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !image.isEmpty else {
            StatusPrinter.warning("VS Code open skipped: container image ref is unavailable")
            return .skippedMissingImage
        }
        let id = target.containerId.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !id.isEmpty else {
            StatusPrinter.warning("VS Code open skipped: container id is empty")
            return .skippedMissingId
        }

        let resolver = resolverOverride ?? DefaultVSCodeCodeResolver()
        guard let codePath = resolver.resolveCodeExecutable() else {
            StatusPrinter.warning(
                "VS Code open skipped: `code` CLI not found (install VS Code and ensure `code` is on PATH, or use the standard app location)"
            )
            return .skippedMissingCode
        }

        let uri = VSCodeRemoteURI.folderURI(id: id, image: image, folder: folder)
        let args = ["--new-window", "--folder-uri", uri]
        let launcher = launcherOverride ?? ProcessVSCodeCodeLauncher()

        // nameConfig before launch so Remote - Containers can observe attach defaults on open.
        // Soft-fail: write failure must not block the subsequent open attempt.
        if writeNameConfigEnabled {
            writeNameConfigSoft(
                containerName: target.containerName ?? id,
                workspaceFolder: folder,
                remoteUser: target.remoteUser
            )
        }

        do {
            let result = try launcher.launch(executable: codePath, arguments: args)
            if !result.succeeded {
                let detail = result.stderrString.trimmingCharacters(in: .whitespacesAndNewlines)
                let msg = detail.isEmpty
                    ? "code exited \(result.exitCode)"
                    : detail
                StatusPrinter.warning("VS Code open failed: \(msg)")
                return .launchFailed(message: msg)
            }
        } catch {
            let msg = error.localizedDescription
            StatusPrinter.warning("VS Code open failed: \(msg)")
            return .launchFailed(message: msg)
        }

        return .opened(uri: uri)
    }

    /// When `openVSCode` is false, no-op. Otherwise best-effort open.
    @discardableResult
    public static func openIfRequested(_ openVSCode: Bool, target: VSCodeOpenTarget) -> VSCodeOpenOutcome {
        guard openVSCode else { return .notRequested }
        return bestEffortOpen(target: target)
    }

    // MARK: - Optional nameConfig

    /// Soft-fail write of Remote - Containers nameConfig JSON.
    public static func writeNameConfigSoft(
        containerName: String,
        workspaceFolder: String,
        remoteUser: String?
    ) {
        let trimmed = containerName.trimmingCharacters(in: .whitespacesAndNewlines)
        // Basename-only so `/` and `..` cannot escape the nameConfigs directory.
        let name = (trimmed as NSString).lastPathComponent
        guard !name.isEmpty, name != ".", name != ".." else { return }

        let root: String
        if let override = nameConfigRootOverride {
            root = override
        } else {
            let home = FileManager.default.homeDirectoryForCurrentUser.path
            root = (home as NSString).appendingPathComponent(
                "Library/Application Support/Code/User/globalStorage/ms-vscode-remote.remote-containers/nameConfigs"
            )
        }

        do {
            try FileManager.default.createDirectory(
                atPath: root,
                withIntermediateDirectories: true
            )
            var obj: [String: Any] = ["workspaceFolder": workspaceFolder]
            if let user = remoteUser?.trimmingCharacters(in: .whitespacesAndNewlines), !user.isEmpty {
                obj["remoteUser"] = user
            }
            let data = try JSONSerialization.data(withJSONObject: obj, options: [.prettyPrinted, .sortedKeys])
            let path = (root as NSString).appendingPathComponent("\(name).json")
            try data.write(to: URL(fileURLWithPath: path), options: .atomic)
        } catch {
            StatusPrinter.warning(
                "VS Code nameConfig write failed (open still attempted): \(error.localizedDescription)"
            )
        }
    }
}
