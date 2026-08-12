import Crypto
import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

// MARK: - Payload / outcome

/// Normalized config-file `customizations.vscode` payload for hash + apply.
public struct VSCodeCustomizationsPayload: Equatable, Sendable {
    /// Sorted unique trimmed extension IDs.
    public var extensions: [String]
    /// Canonical JSON object bytes (always a JSON object; `{}` when empty).
    public var settingsJSON: Data

    public init(extensions: [String] = [], settingsJSON: Data = Data("{}".utf8)) {
        self.extensions = extensions
        self.settingsJSON = settingsJSON.isEmpty ? Data("{}".utf8) : settingsJSON
    }

    public var hasExtensions: Bool { !extensions.isEmpty }

    public var hasSettings: Bool {
        ResolvedDevContainerConfig.settingsObjectHasKeys(settingsJSON)
    }

    public var isEmpty: Bool { !hasExtensions && !hasSettings }

    /// Stable content hash (SHA-256 hex) of normalized extensions + settings.
    public var contentHash: String {
        VSCodeCustomizationsApply.contentHash(self)
    }

    public static func from(config: ResolvedDevContainerConfig) -> VSCodeCustomizationsPayload {
        VSCodeCustomizationsApply.normalize(
            extensions: config.vscodeExtensions,
            settingsJSON: config.vscodeSettingsJSON
        )
    }
}

public enum VSCodeCustomizationsApplyOutcome: Equatable, Sendable {
    case skippedEmpty
    case skippedMatchingMarker
    case applied
    case softFailed(message: String)

    public var isSoftFail: Bool {
        if case .softFailed = self { return true }
        return false
    }
}

// MARK: - Guest / download seams (mockable)

/// Guest filesystem + unpack operations under the effective remote user.
public protocol VSCodeGuestOperating: Sendable {
    func resolveHome(containerId: String, user: String?) throws -> String
    func readTextFile(containerId: String, path: String, user: String?) throws -> String?
    func writeTextFile(containerId: String, path: String, contents: String, user: String?) throws
    func ensureDirectory(containerId: String, path: String, user: String?) throws
    func listDirectoryNames(containerId: String, path: String, user: String?) throws -> [String]
    /// Best-effort remove; missing path is not an error.
    func removeFile(containerId: String, path: String, user: String?) throws
    /// Unpack zip/VSIX bytes into `destDir` (created if needed).
    func unpackZip(containerId: String, zipData: Data, destDir: String, user: String?) throws
    /// VS Marketplace `targetPlatform` for this guest (e.g. `linux-arm64`). Throws when unknown.
    func resolveMarketplaceTargetPlatform(containerId: String, user: String?) throws -> String
}

/// Marketplace (or test) VSIX fetch.
public protocol VSCodeVSIXDownloading: Sendable {
    /// Fetch VSIX for `publisher.name` or `publisher.name@version` targeting guest `targetPlatform`.
    func fetchVSIX(extensionId: String, targetPlatform: String) throws -> VSCodeVSIXArtifact
}

public struct VSCodeVSIXArtifact: Equatable, Sendable {
    public var data: Data
    /// Folder name under extensions dir, e.g. `publisher.name-1.2.3`.
    public var installFolderName: String

    public init(data: Data, installFolderName: String) {
        self.data = data
        self.installFolderName = installFolderName
    }
}

/// Default guest ops via `container exec` + base64 file transfer.
public struct ExecVSCodeGuestOps: VSCodeGuestOperating {
    public var runtime: AppleContainerRuntime

    public init(runtime: AppleContainerRuntime) {
        self.runtime = runtime
    }

    public func resolveHome(containerId: String, user: String?) throws -> String {
        let script: String
        if let user, !user.isEmpty {
            // Prefer getent; fall back to eval echo ~user.
            script = """
            u=\(shellSingleQuoted(user)); \
            h=$(getent passwd "$u" 2>/dev/null | cut -d: -f6); \
            if [ -z "$h" ]; then h=$(eval echo "~$u"); fi; \
            printf '%s' "$h"
            """
        } else {
            script = #"printf '%s' "$HOME""#
        }
        let result = try runtime.exec(
            nameOrId: containerId,
            command: ["sh", "-lc", script],
            user: user
        )
        guard result.succeeded else {
            throw CLIError(
                code: CLIErrorCode.runtimeFailed,
                message: "Failed to resolve home directory in container"
            )
        }
        let home = result.stdoutString.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !home.isEmpty, home != "~" else {
            throw CLIError(
                code: CLIErrorCode.runtimeFailed,
                message: "Empty home directory in container"
            )
        }
        return home
    }

    public func readTextFile(containerId: String, path: String, user: String?) throws -> String? {
        let result = try runtime.exec(
            nameOrId: containerId,
            command: ["sh", "-lc", "if [ -f \(shellSingleQuoted(path)) ]; then cat \(shellSingleQuoted(path)); else exit 2; fi"],
            user: user
        )
        if result.exitCode == 2 { return nil }
        guard result.succeeded else {
            throw CLIError(
                code: CLIErrorCode.runtimeFailed,
                message: "Failed to read \(path) in container (exit \(result.exitCode))"
            )
        }
        return result.stdoutString
    }

    public func writeTextFile(containerId: String, path: String, contents: String, user: String?) throws {
        let parent = (path as NSString).deletingLastPathComponent
        try ensureDirectory(containerId: containerId, path: parent, user: user)
        let b64 = Data(contents.utf8).base64EncodedString()
        // Write via base64 to avoid shell metachar issues; atomic via temp + mv.
        let script = """
        f=\(shellSingleQuoted(path)); \
        t="$f.tmp.$$"; \
        printf '%s' \(shellSingleQuoted(b64)) | base64 -d > "$t" && mv "$t" "$f"
        """
        let result = try runtime.exec(
            nameOrId: containerId,
            command: ["sh", "-lc", script],
            user: user
        )
        guard result.succeeded else {
            throw CLIError(
                code: CLIErrorCode.runtimeFailed,
                message: "Failed to write \(path) in container (exit \(result.exitCode))"
            )
        }
    }

    public func ensureDirectory(containerId: String, path: String, user: String?) throws {
        let result = try runtime.exec(
            nameOrId: containerId,
            command: ["sh", "-lc", "mkdir -p \(shellSingleQuoted(path))"],
            user: user
        )
        guard result.succeeded else {
            throw CLIError(
                code: CLIErrorCode.runtimeFailed,
                message: "Failed to mkdir \(path) in container (exit \(result.exitCode))"
            )
        }
    }

    public func listDirectoryNames(containerId: String, path: String, user: String?) throws -> [String] {
        let script = """
        d=\(shellSingleQuoted(path)); \
        if [ ! -d "$d" ]; then exit 0; fi; \
        ls -1A "$d" 2>/dev/null || true
        """
        let result = try runtime.exec(
            nameOrId: containerId,
            command: ["sh", "-lc", script],
            user: user
        )
        guard result.succeeded else {
            throw CLIError(
                code: CLIErrorCode.runtimeFailed,
                message: "Failed to list \(path) in container (exit \(result.exitCode))"
            )
        }
        return result.stdoutString
            .split(separator: "\n", omittingEmptySubsequences: true)
            .map(String.init)
    }

    public func removeFile(containerId: String, path: String, user: String?) throws {
        let result = try runtime.exec(
            nameOrId: containerId,
            command: ["sh", "-lc", "rm -f \(shellSingleQuoted(path))"],
            user: user
        )
        guard result.succeeded else {
            throw CLIError(
                code: CLIErrorCode.runtimeFailed,
                message: "Failed to remove \(path) in container (exit \(result.exitCode))"
            )
        }
    }

    public func unpackZip(containerId: String, zipData: Data, destDir: String, user: String?) throws {
        try ensureDirectory(containerId: containerId, path: destDir, user: user)

        // Host temp → tar-pipe into guest /tmp (avoids ARG_MAX from embedding multi-MB base64 in exec argv).
        let fm = FileManager.default
        let hostDir = fm.temporaryDirectory
            .appendingPathComponent("adevcontainer-vsix-\(UUID().uuidString)", isDirectory: true)
        defer { try? fm.removeItem(at: hostDir) }
        try fm.createDirectory(at: hostDir, withIntermediateDirectories: true)
        try zipData.write(to: hostDir.appendingPathComponent("ext.vsix"))

        let guestStage = "/tmp/adevcontainer-vsix-\(UUID().uuidString)"
        defer {
            _ = try? runtime.exec(
                nameOrId: containerId,
                command: ["sh", "-lc", "rm -rf \(shellSingleQuoted(guestStage))"],
                user: nil
            )
        }
        try runtime.copyTreeIntoContainer(
            hostDir: hostDir.path,
            containerId: containerId,
            destPath: guestStage
        )

        // VSIX is a zip; extension layout is extension/* inside the archive.
        // Unpack to a temp dir then move extension contents into destDir.
        let script = """
        set -e
        dest=\(shellSingleQuoted(destDir))
        vsix=\(shellSingleQuoted(guestStage + "/ext.vsix"))
        tmp=$(mktemp -d)
        mkdir -p "$tmp/unpacked"
        if command -v unzip >/dev/null 2>&1; then
          unzip -q -o "$vsix" -d "$tmp/unpacked"
        else
          # busybox/bsdtar fallback
          tar -xf "$vsix" -C "$tmp/unpacked" 2>/dev/null || \
            python3 -c "import zipfile,sys; zipfile.ZipFile(sys.argv[1]).extractall(sys.argv[2])" \
              "$vsix" "$tmp/unpacked"
        fi
        mkdir -p "$dest"
        if [ -d "$tmp/unpacked/extension" ]; then
          # Prefer contents of extension/ as the install root (VS Code layout).
          cp -a "$tmp/unpacked/extension"/. "$dest"/
        else
          cp -a "$tmp/unpacked"/. "$dest"/
        fi
        rm -rf "$tmp"
        """
        let result = try runtime.exec(
            nameOrId: containerId,
            command: ["sh", "-lc", script],
            user: user
        )
        guard result.succeeded else {
            let detail = result.stderrString.trimmingCharacters(in: .whitespacesAndNewlines)
            throw CLIError(
                code: CLIErrorCode.runtimeFailed,
                message: "Failed to unpack extension into \(destDir)"
                    + (detail.isEmpty ? "" : ": \(detail)")
            )
        }
    }

    public func resolveMarketplaceTargetPlatform(containerId: String, user: String?) throws -> String {
        let result = try runtime.exec(
            nameOrId: containerId,
            command: ["sh", "-lc", #"printf '%s' "$(uname -m)""#],
            user: user
        )
        guard result.succeeded else {
            throw CLIError(
                code: CLIErrorCode.runtimeFailed,
                message: "Failed to detect guest architecture (uname -m)"
            )
        }
        let machine = result.stdoutString.trimmingCharacters(in: .whitespacesAndNewlines)
        // os-release is typically world-readable; ignore read failures (non-alpine linux).
        let osRelease = try? readTextFile(containerId: containerId, path: "/etc/os-release", user: user)
        guard let platform = VSCodeCustomizationsApply.marketplaceTargetPlatform(
            unameMachine: machine,
            osReleaseText: osRelease
        ) else {
            throw CLIError(
                code: CLIErrorCode.runtimeFailed,
                message:
                    "Unsupported guest architecture '\(machine)' for marketplace VSIX "
                    + "(need aarch64/arm64 or x86_64/amd64); refusing host-platform download"
            )
        }
        return platform
    }

    private func shellSingleQuoted(_ value: String) -> String {
        "'" + value.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }
}

/// Host-side marketplace VSIX download (latest or pinned `publisher.name@version`) for guest platform.
public struct MarketplaceVSCodeVSIXDownloader: VSCodeVSIXDownloading {
    public var session: URLSession
    public var queryURL: URL
    /// Build asset URL: publisher, name, version, targetPlatform → VSIXPackage URL.
    /// Pass empty `targetPlatform` for universal builds (omit `?targetPlatform=`; marketplace 404s otherwise).
    public var assetURLBuilder: @Sendable (String, String, String, String) -> URL

    public init(
        session: URLSession = .shared,
        queryURL: URL = URL(string: "https://marketplace.visualstudio.com/_apis/public/gallery/extensionquery")!,
        assetURLBuilder: @escaping @Sendable (String, String, String, String) -> URL = {
            publisher, name, version, targetPlatform in
            MarketplaceVSCodeVSIXDownloader.defaultAssetURL(
                publisher: publisher,
                name: name,
                version: version,
                targetPlatform: targetPlatform
            )
        }
    ) {
        self.session = session
        self.queryURL = queryURL
        self.assetURLBuilder = assetURLBuilder
    }

    /// Marketplace asset URL. Non-empty `targetPlatform` adds `?targetPlatform=` (multi-arch).
    /// Empty/whitespace `targetPlatform` omits the query — required for universal-only packages
    /// (gallery returns HTTP 404 when a platform query is applied to a universal VSIX).
    public static func defaultAssetURL(
        publisher: String,
        name: String,
        version: String,
        targetPlatform: String
    ) -> URL {
        var components = URLComponents(string:
            "https://\(publisher).gallery.vsassets.io/_apis/public/gallery/publisher/\(publisher)/extension/\(name)/\(version)/assetbyname/Microsoft.VisualStudio.Services.VSIXPackage"
        )!
        let tp = targetPlatform.trimmingCharacters(in: .whitespacesAndNewlines)
        if !tp.isEmpty {
            components.queryItems = [URLQueryItem(name: "targetPlatform", value: tp)]
        }
        return components.url!
    }

    public func fetchVSIX(extensionId: String, targetPlatform: String) throws -> VSCodeVSIXArtifact {
        let parsed = VSCodeCustomizationsApply.parseExtensionId(extensionId)
        // Always gallery-resolve (including pins) so we know whether the VSIX is
        // platform-specific (`?targetPlatform=`) or universal (no query).
        let pick = try resolveMarketplaceVersion(
            publisher: parsed.publisher,
            name: parsed.name,
            targetPlatform: targetPlatform,
            pinnedVersion: parsed.version
        )
        // Empty string → universal URL (builder omits query). Guest platform → platform asset.
        let assetTP = pick.assetTargetPlatform ?? ""
        let url = assetURLBuilder(parsed.publisher, parsed.name, pick.version, assetTP)
        let data = try download(url: url)
        let folder = "\(parsed.publisher).\(parsed.name)-\(pick.version)"
        return VSCodeVSIXArtifact(data: data, installFolderName: folder)
    }

    private func resolveMarketplaceVersion(
        publisher: String,
        name: String,
        targetPlatform: String,
        pinnedVersion: String?
    ) throws -> VSCodeCustomizationsApply.MarketplaceVersionPick {
        // Minimal extensionquery body for public gallery.
        let body: [String: Any] = [
            "filters": [
                [
                    "criteria": [
                        ["filterType": 7, "value": "\(publisher).\(name)"]
                    ] as [[String: Any]],
                    "pageNumber": 1,
                    "pageSize": 1,
                    "sortBy": 0,
                    "sortOrder": 0
                ] as [String: Any]
            ],
            "assetTypes": [] as [Any],
            "flags": 914
        ]
        let bodyData = try JSONSerialization.data(withJSONObject: body)
        var request = URLRequest(url: queryURL)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("application/json;api-version=7.2-preview.1", forHTTPHeaderField: "Accept")
        request.httpBody = bodyData

        let data = try download(request: request)
        guard
            let obj = try JSONSerialization.jsonObject(with: data) as? [String: Any],
            let results = obj["results"] as? [[String: Any]],
            let first = results.first,
            let extensions = first["extensions"] as? [[String: Any]],
            let ext = extensions.first,
            let versions = ext["versions"] as? [[String: Any]],
            !versions.isEmpty
        else {
            throw CLIError(
                code: CLIErrorCode.runtimeFailed,
                message: "Could not resolve marketplace version for \(publisher).\(name)"
            )
        }
        guard let pick = VSCodeCustomizationsApply.pickMarketplaceVersion(
            versions: versions,
            targetPlatform: targetPlatform,
            pinnedVersion: pinnedVersion
        ) else {
            let pinNote: String
            if let pinnedVersion, !pinnedVersion.isEmpty {
                pinNote = " version \(pinnedVersion)"
            } else {
                pinNote = ""
            }
            throw CLIError(
                code: CLIErrorCode.runtimeFailed,
                message:
                    "No marketplace version of \(publisher).\(name)\(pinNote) for targetPlatform=\(targetPlatform) "
                    + "(and no universal build)"
            )
        }
        return pick
    }

    private func download(url: URL) throws -> Data {
        var request = URLRequest(url: url)
        request.httpMethod = "GET"
        return try download(request: request)
    }

    private func download(request: URLRequest) throws -> Data {
        let sem = DispatchSemaphore(value: 0)
        final class Box: @unchecked Sendable {
            var data: Data?
            var error: Error?
            var status: Int?
        }
        let box = Box()
        let task = session.dataTask(with: request) { data, response, error in
            box.data = data
            box.error = error
            box.status = (response as? HTTPURLResponse)?.statusCode
            sem.signal()
        }
        task.resume()
        sem.wait()
        if let error = box.error {
            throw CLIError(
                code: CLIErrorCode.runtimeFailed,
                message: "VSIX download failed: \(error.localizedDescription)"
            )
        }
        guard let data = box.data else {
            throw CLIError(code: CLIErrorCode.runtimeFailed, message: "VSIX download returned no data")
        }
        if let status = box.status, !(200...299).contains(status) {
            let urlNote = request.url.map { " for \($0.absoluteString)" } ?? ""
            throw CLIError(
                code: CLIErrorCode.runtimeFailed,
                message: "VSIX download HTTP \(status)\(urlNote)"
            )
        }
        return data
    }
}

// MARK: - Apply orchestration

public enum VSCodeCustomizationsApply {
    public static let markerRelativePath = ".adevcontainer/vscode-customizations.applied"
    public static let settingsRelativePath = ".vscode-server/data/Machine/settings.json"
    public static let extensionsRelativeDir = ".vscode-server/extensions"
    public static let extensionsRegistryRelativePath = ".vscode-server/extensions/extensions.json"
    public static let extensionsUserCacheRelativePath =
        ".vscode-server/data/CachedProfilesData/__default__profile__/extensions.user.cache"

    /// Test override for guest ops.
    nonisolated(unsafe) public static var guestOverride: (any VSCodeGuestOperating)?
    /// Test override for VSIX download.
    nonisolated(unsafe) public static var downloaderOverride: (any VSCodeVSIXDownloading)?

    // MARK: Normalize / hash

    public static func normalize(
        extensions: [String],
        settingsJSON: Data
    ) -> VSCodeCustomizationsPayload {
        var seen = Set<String>()
        var ids: [String] = []
        for raw in extensions {
            let t = raw.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !t.isEmpty else { continue }
            let key = t.lowercased()
            if seen.insert(key).inserted {
                ids.append(t)
            }
        }
        ids.sort { $0.lowercased() < $1.lowercased() }

        let settings: Data
        if let obj = try? JSONSerialization.jsonObject(with: settingsJSON) as? [String: Any],
           let data = try? JSONSerialization.data(withJSONObject: obj, options: [.sortedKeys])
        {
            settings = data
        } else {
            settings = Data("{}".utf8)
        }
        return VSCodeCustomizationsPayload(extensions: ids, settingsJSON: settings)
    }

    public static func contentHash(_ payload: VSCodeCustomizationsPayload) -> String {
        // Stable encoding: extensions joined by \n, then NUL, then settings JSON UTF-8.
        var material = Data()
        material.append(contentsOf: payload.extensions.joined(separator: "\n").utf8)
        material.append(0)
        material.append(payload.settingsJSON)
        let digest = SHA256.hash(data: material)
        return digest.map { String(format: "%02x", $0) }.joined()
    }

    public static func parseExtensionId(_ id: String) -> (publisher: String, name: String, version: String?) {
        let trimmed = id.trimmingCharacters(in: .whitespacesAndNewlines)
        let atParts = trimmed.split(separator: "@", maxSplits: 1, omittingEmptySubsequences: false)
        let base = String(atParts[0])
        let version = atParts.count > 1 ? String(atParts[1]) : nil
        let dot = base.split(separator: ".", maxSplits: 1, omittingEmptySubsequences: false)
        if dot.count == 2 {
            return (String(dot[0]), String(dot[1]), version)
        }
        return (base, base, version)
    }

    // MARK: Guest marketplace targetPlatform

    /// Map guest `uname -m` + optional `/etc/os-release` → VS Marketplace `targetPlatform`.
    /// Returns nil when arch is unrecognized (caller MUST soft-fail rather than download host VSIX).
    public static func marketplaceTargetPlatform(unameMachine: String, osReleaseText: String?) -> String? {
        let machine = unameMachine.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        let arch: String
        switch machine {
        case "aarch64", "arm64":
            arch = "arm64"
        case "x86_64", "amd64":
            arch = "x64"
        default:
            return nil
        }
        if osReleaseIsAlpine(osReleaseText) {
            return "alpine-\(arch)"
        }
        return "linux-\(arch)"
    }

    /// Result of picking a gallery version row for guest download.
    public struct MarketplaceVersionPick: Equatable, Sendable {
        public var version: String
        /// Guest platform for the asset URL query, or `nil` when the row is universal
        /// (caller MUST omit `?targetPlatform=` — marketplace 404s universal + query).
        public var assetTargetPlatform: String?

        public init(version: String, assetTargetPlatform: String?) {
            self.version = version
            self.assetTargetPlatform = assetTargetPlatform
        }
    }

    /// Prefer a version row matching `targetPlatform`; else universal (missing/empty/undefined platform).
    /// Gallery order is newest-first; first match wins. Optional `pinnedVersion` filters rows first.
    /// `assetTargetPlatform` is non-nil only for a platform-specific row (include query on asset URL).
    public static func pickMarketplaceVersion(
        versions: [[String: Any]],
        targetPlatform: String,
        pinnedVersion: String? = nil
    ) -> MarketplaceVersionPick? {
        let rows: [[String: Any]]
        if let pinned = pinnedVersion, !pinned.isEmpty {
            rows = versions.filter { ($0["version"] as? String) == pinned }
        } else {
            rows = versions
        }
        for row in rows {
            guard let version = row["version"] as? String, !version.isEmpty else { continue }
            if let tp = row["targetPlatform"] as? String, tp == targetPlatform {
                return MarketplaceVersionPick(version: version, assetTargetPlatform: targetPlatform)
            }
        }
        for row in rows {
            guard let version = row["version"] as? String, !version.isEmpty else { continue }
            if isUniversalMarketplaceTargetPlatform(row["targetPlatform"] as? String) {
                return MarketplaceVersionPick(version: version, assetTargetPlatform: nil)
            }
        }
        return nil
    }

    /// True when the gallery row is platform-agnostic (no natives / universal build).
    public static func isUniversalMarketplaceTargetPlatform(_ targetPlatform: String?) -> Bool {
        guard let targetPlatform else { return true }
        let t = targetPlatform.trimmingCharacters(in: .whitespacesAndNewlines)
        if t.isEmpty { return true }
        switch t.lowercased() {
        case "undefined", "universal", "unknown":
            return true
        default:
            return false
        }
    }

    private static func osReleaseIsAlpine(_ text: String?) -> Bool {
        guard let text else { return false }
        for line in text.split(whereSeparator: \.isNewline) {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            guard trimmed.lowercased().hasPrefix("id=") else { continue }
            var value = String(trimmed.dropFirst(3))
            if (value.hasPrefix("\"") && value.hasSuffix("\""))
                || (value.hasPrefix("'") && value.hasSuffix("'"))
            {
                value = String(value.dropFirst().dropLast())
            }
            return value.lowercased() == "alpine"
        }
        return false
    }

    /// Bare `publisher.name` (no version) for cycle / visited keys.
    public static func bareExtensionId(_ id: String) -> String {
        let p = parseExtensionId(id)
        return "\(p.publisher).\(p.name)"
    }

    /// `extensionDependencies` string IDs from an unpacked extension `package.json`.
    /// Missing/invalid JSON or non-array → empty (soft).
    public static func parseExtensionDependencies(_ packageJSON: String?) -> [String] {
        parsePackageJSONExtensionIDArray(packageJSON, key: "extensionDependencies")
    }

    /// `extensionPack` string IDs from an unpacked extension `package.json`.
    /// Missing/invalid JSON or non-array → empty (soft).
    public static func parseExtensionPack(_ packageJSON: String?) -> [String] {
        parsePackageJSONExtensionIDArray(packageJSON, key: "extensionPack")
    }

    /// `extensionDependencies` ∪ `extensionPack` (deps first, then pack; bare-id de-duped).
    /// BFS enqueue source after each installed/present extension folder is processed.
    public static func parseTransitiveExtensionIDs(_ packageJSON: String?) -> [String] {
        var ids: [String] = []
        var seen = Set<String>()
        for id in parseExtensionDependencies(packageJSON) + parseExtensionPack(packageJSON) {
            let key = bareExtensionId(id).lowercased()
            if seen.insert(key).inserted {
                ids.append(id)
            }
        }
        return ids
    }

    /// String IDs from a package.json array field. Missing/invalid/non-array → empty (soft).
    private static func parsePackageJSONExtensionIDArray(_ packageJSON: String?, key: String) -> [String] {
        guard let packageJSON, !packageJSON.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              let data = packageJSON.data(using: .utf8),
              let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let raw = obj[key] as? [Any]
        else {
            return []
        }
        var ids: [String] = []
        var seen = Set<String>()
        for item in raw {
            guard let s = item as? String else { continue }
            let t = s.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !t.isEmpty else { continue }
            let bareKey = bareExtensionId(t).lowercased()
            if seen.insert(bareKey).inserted {
                ids.append(t)
            }
        }
        return ids
    }

    // MARK: Marker

    public static func markerPath(home: String) -> String {
        (home as NSString).appendingPathComponent(markerRelativePath)
    }

    public static func settingsPath(home: String) -> String {
        (home as NSString).appendingPathComponent(settingsRelativePath)
    }

    public static func extensionsDir(home: String) -> String {
        (home as NSString).appendingPathComponent(extensionsRelativeDir)
    }

    public static func extensionsRegistryPath(home: String) -> String {
        (home as NSString).appendingPathComponent(extensionsRegistryRelativePath)
    }

    public static func extensionsUserCachePath(home: String) -> String {
        (home as NSString).appendingPathComponent(extensionsUserCacheRelativePath)
    }

    public static func readMarker(
        guest: any VSCodeGuestOperating,
        containerId: String,
        home: String,
        user: String?
    ) throws -> String? {
        let path = markerPath(home: home)
        guard let text = try guest.readTextFile(containerId: containerId, path: path, user: user)
        else { return nil }
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }

    public static func writeMarker(
        guest: any VSCodeGuestOperating,
        containerId: String,
        home: String,
        user: String?,
        hash: String
    ) throws {
        let path = markerPath(home: home)
        let parent = (path as NSString).deletingLastPathComponent
        try guest.ensureDirectory(containerId: containerId, path: parent, user: user)
        try guest.writeTextFile(containerId: containerId, path: path, contents: hash + "\n", user: user)
    }

    // MARK: Settings merge

    /// Merge config settings into Machine settings.json. Config keys win.
    public static func mergeSettingsJSON(existing: String?, configSettings: Data) throws -> String {
        var base: [String: Any] = [:]
        if let existing, !existing.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            guard let parsed = try JSONSerialization.jsonObject(with: Data(existing.utf8)) as? [String: Any]
            else {
                throw CLIError(
                    code: CLIErrorCode.runtimeFailed,
                    message: "Existing Machine settings.json is not a JSON object"
                )
            }
            base = parsed
        }
        guard let overlay = try JSONSerialization.jsonObject(with: configSettings) as? [String: Any]
        else {
            throw CLIError(
                code: CLIErrorCode.runtimeFailed,
                message: "Config vscode settings is not a JSON object"
            )
        }
        for (k, v) in overlay {
            base[k] = v
        }
        let data = try JSONSerialization.data(withJSONObject: base, options: [.prettyPrinted, .sortedKeys])
        return String(data: data, encoding: .utf8) ?? "{}"
    }

    // MARK: Public soft-fail entry points

    /// Create-path / drift-repair: settings merge when payload pending. Never throws for lifecycle.
    /// Does **not** finalize full-hash marker when extensions remain pending.
    @discardableResult
    public static func applySettingsIfNeeded(
        containerId: String,
        config: ResolvedDevContainerConfig,
        runtime: AppleContainerRuntime
    ) -> VSCodeCustomizationsApplyOutcome {
        let payload = VSCodeCustomizationsPayload.from(config: config)
        guard !payload.isEmpty else { return .skippedEmpty }

        let guest = guestOverride ?? ExecVSCodeGuestOps(runtime: runtime)
        let user = config.connectionUser

        do {
            let home = try guest.resolveHome(containerId: containerId, user: user)
            let hash = payload.contentHash
            if let marker = try readMarker(guest: guest, containerId: containerId, home: home, user: user),
               marker == hash
            {
                return .skippedMatchingMarker
            }

            if payload.hasSettings {
                StatusPrinter.status("Applying vscode settings")
                let path = settingsPath(home: home)
                let parent = (path as NSString).deletingLastPathComponent
                try guest.ensureDirectory(containerId: containerId, path: parent, user: user)
                let existing = try guest.readTextFile(containerId: containerId, path: path, user: user)
                let merged = try mergeSettingsJSON(existing: existing, configSettings: payload.settingsJSON)
                try guest.writeTextFile(containerId: containerId, path: path, contents: merged, user: user)
            }

            // Finalize marker only when no extensions remain (full payload done).
            if !payload.hasExtensions {
                try writeMarker(
                    guest: guest,
                    containerId: containerId,
                    home: home,
                    user: user,
                    hash: hash
                )
            }
            return .applied
        } catch {
            let msg = error.localizedDescription
            warnSettings(msg)
            return .softFailed(message: msg)
        }
    }

    /// With `--vscode`: install missing extensions (before open); finalize marker on full success.
    @discardableResult
    public static func applyExtensionsIfNeeded(
        containerId: String,
        config: ResolvedDevContainerConfig,
        runtime: AppleContainerRuntime
    ) -> VSCodeCustomizationsApplyOutcome {
        let payload = VSCodeCustomizationsPayload.from(config: config)
        guard payload.hasExtensions else {
            // Settings-only or empty: nothing open-gated.
            return payload.isEmpty ? .skippedEmpty : .skippedEmpty
        }

        let guest = guestOverride ?? ExecVSCodeGuestOps(runtime: runtime)
        let downloader = downloaderOverride ?? MarketplaceVSCodeVSIXDownloader()
        let user = config.connectionUser

        do {
            let home = try guest.resolveHome(containerId: containerId, user: user)
            let hash = payload.contentHash
            if let marker = try readMarker(guest: guest, containerId: containerId, home: home, user: user),
               marker == hash
            {
                return .skippedMatchingMarker
            }

            StatusPrinter.status("Applying vscode extensions")
            let extDir = extensionsDir(home: home)
            try guest.ensureDirectory(containerId: containerId, path: extDir, user: user)
            var installed = try guest.listDirectoryNames(
                containerId: containerId,
                path: extDir,
                user: user
            )
            // extensions.json itself may appear in the listing; ignore non-extension names later.

            let registryPath = extensionsRegistryPath(home: home)
            let existingRegistryText = try guest.readTextFile(
                containerId: containerId,
                path: registryPath,
                user: user
            )
            var registryEntries = parseExtensionsRegistry(existingRegistryText)

            var anyFailed = false
            var failMessages: [String] = []
            var registryDirty = false
            // Resolve once on first download need — refuse silent host-arch VSIX when unknown.
            var cachedTargetPlatform: String?

            // BFS: config IDs first (depth 0), then each package.json deps ∪ pack.
            var queue: [(id: String, depth: Int)] = payload.extensions.map { ($0, 0) }
            var visitedBareIDs = Set<String>()

            while !queue.isEmpty {
                let item = queue.removeFirst()
                let id = item.id
                let bareKey = bareExtensionId(id).lowercased()
                if visitedBareIDs.contains(bareKey) { continue }
                visitedBareIDs.insert(bareKey)

                let installedFolder: String?
                if let folder = matchingInstalledFolder(id: id, installedFolderNames: installed) {
                    if !extensionRegistered(id: id, folderName: folder, entries: registryEntries) {
                        // Folder present but unregistered — reconcile registry only.
                        let entry = makeRegistryEntry(
                            extensionId: id,
                            folderName: folder,
                            extensionsDir: extDir
                        )
                        registryEntries = upsertExtensionsRegistry(entries: registryEntries, entry: entry)
                        registryDirty = true
                    }
                    installedFolder = folder
                } else {
                    let label = item.depth > 0
                        ? "Installing \(id) (dependency)"
                        : "Installing \(id)"
                    StatusPrinter.detail(label, level: item.depth + 1)
                    do {
                        let targetPlatform: String
                        if let cached = cachedTargetPlatform {
                            targetPlatform = cached
                        } else {
                            do {
                                let resolved = try guest.resolveMarketplaceTargetPlatform(
                                    containerId: containerId,
                                    user: user
                                )
                                cachedTargetPlatform = resolved
                                targetPlatform = resolved
                            } catch {
                                let msg =
                                    "guest marketplace targetPlatform: \(error.localizedDescription)"
                                warnExtensions(msg)
                                return .softFailed(message: msg)
                            }
                        }
                        let artifact = try downloader.fetchVSIX(
                            extensionId: id,
                            targetPlatform: targetPlatform
                        )
                        let dest = (extDir as NSString).appendingPathComponent(artifact.installFolderName)
                        try guest.unpackZip(
                            containerId: containerId,
                            zipData: artifact.data,
                            destDir: dest,
                            user: user
                        )
                        installed.append(artifact.installFolderName)
                        let entry = makeRegistryEntry(
                            extensionId: id,
                            folderName: artifact.installFolderName,
                            extensionsDir: extDir
                        )
                        registryEntries = upsertExtensionsRegistry(entries: registryEntries, entry: entry)
                        registryDirty = true
                        installedFolder = artifact.installFolderName
                    } catch {
                        anyFailed = true
                        failMessages.append("\(id): \(error.localizedDescription)")
                        installedFolder = nil
                    }
                }

                // Expand extensionDependencies ∪ extensionPack (soft if missing/unreadable).
                guard let folder = installedFolder else { continue }
                let folderPath = (extDir as NSString).appendingPathComponent(folder)
                let pkgPath = (folderPath as NSString).appendingPathComponent("package.json")
                let pkgText = try? guest.readTextFile(
                    containerId: containerId,
                    path: pkgPath,
                    user: user
                )
                for related in parseTransitiveExtensionIDs(pkgText) {
                    let relatedKey = bareExtensionId(related).lowercased()
                    if !visitedBareIDs.contains(relatedKey) {
                        queue.append((related, item.depth + 1))
                    }
                }
            }

            if anyFailed {
                let msg = failMessages.joined(separator: "; ")
                warnExtensions(msg)
                return .softFailed(message: msg)
            }

            // Registry must be written before marker (VS Code Server source of truth).
            if registryDirty {
                let json = try serializeExtensionsRegistry(registryEntries)
                try guest.writeTextFile(
                    containerId: containerId,
                    path: registryPath,
                    contents: json,
                    user: user
                )
                // Best-effort cache invalidate so Server reloads registry.
                let cachePath = extensionsUserCachePath(home: home)
                do {
                    try guest.removeFile(containerId: containerId, path: cachePath, user: user)
                } catch {
                    // soft: cache may be absent or locked
                }
            }

            // Full payload success: also ensure settings present if any (idempotent overlay).
            if payload.hasSettings {
                let path = settingsPath(home: home)
                let parent = (path as NSString).deletingLastPathComponent
                try guest.ensureDirectory(containerId: containerId, path: parent, user: user)
                let existing = try guest.readTextFile(containerId: containerId, path: path, user: user)
                let merged = try mergeSettingsJSON(existing: existing, configSettings: payload.settingsJSON)
                try guest.writeTextFile(containerId: containerId, path: path, contents: merged, user: user)
            }

            try writeMarker(
                guest: guest,
                containerId: containerId,
                home: home,
                user: user,
                hash: hash
            )
            return .applied
        } catch {
            let msg = error.localizedDescription
            warnExtensions(msg)
            return .softFailed(message: msg)
        }
    }

    // MARK: Extensions registry (extensions.json)

    /// Parse VS Code Server `extensions.json` array; invalid/missing → empty.
    public static func parseExtensionsRegistry(_ text: String?) -> [[String: Any]] {
        guard let text, !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            return []
        }
        guard let data = text.data(using: .utf8),
              let arr = try? JSONSerialization.jsonObject(with: data) as? [[String: Any]]
        else {
            return []
        }
        return arr
    }

    public static func serializeExtensionsRegistry(_ entries: [[String: Any]]) throws -> String {
        let data = try JSONSerialization.data(withJSONObject: entries, options: [.prettyPrinted, .sortedKeys])
        return String(data: data, encoding: .utf8) ?? "[]"
    }

    /// Build one registry entry matching VS Code Server shape.
    public static func makeRegistryEntry(
        extensionId: String,
        folderName: String,
        extensionsDir: String,
        installedTimestampMs: Int64? = nil
    ) -> [String: Any] {
        let parsed = parseExtensionId(extensionId)
        let bareId = "\(parsed.publisher).\(parsed.name)"
        let version: String
        if let pinned = parsed.version, !pinned.isEmpty {
            version = pinned
        } else if let fromFolder = versionFromInstallFolder(folderName, publisher: parsed.publisher, name: parsed.name) {
            version = fromFolder
        } else {
            version = "0.0.0"
        }
        let absPath = (extensionsDir as NSString).appendingPathComponent(folderName)
        let ts = installedTimestampMs ?? Int64(Date().timeIntervalSince1970 * 1000)
        // Bare IDs unpinned (updates allowed); `publisher.name@version` pins.
        let pinned = parsed.version.map { !$0.isEmpty } ?? false
        return [
            "identifier": ["id": bareId.lowercased()] as [String: Any],
            "version": version,
            "location": [
                "$mid": 1,
                "path": absPath,
                "scheme": "file"
            ] as [String: Any],
            "relativeLocation": folderName,
            "metadata": [
                "installedTimestamp": ts,
                "pinned": pinned,
                "source": "vsix"
            ] as [String: Any]
        ]
    }

    /// Upsert by identifier.id (case-insensitive). Replaces matching entry or appends.
    public static func upsertExtensionsRegistry(
        entries: [[String: Any]],
        entry: [String: Any]
    ) -> [[String: Any]] {
        let newId = registryEntryId(entry)?.lowercased()
        var result: [[String: Any]] = []
        var replaced = false
        for e in entries {
            if let id = registryEntryId(e)?.lowercased(), id == newId {
                result.append(entry)
                replaced = true
            } else {
                result.append(e)
            }
        }
        if !replaced {
            result.append(entry)
        }
        return result
    }

    public static func registryEntryId(_ entry: [String: Any]) -> String? {
        guard let ident = entry["identifier"] as? [String: Any],
              let id = ident["id"] as? String
        else { return nil }
        return id
    }

    public static func extensionRegistered(
        id: String,
        folderName: String,
        entries: [[String: Any]]
    ) -> Bool {
        let parsed = parseExtensionId(id)
        let bare = "\(parsed.publisher).\(parsed.name)".lowercased()
        for e in entries {
            guard let eid = registryEntryId(e)?.lowercased(), eid == bare else { continue }
            if let rel = e["relativeLocation"] as? String, rel == folderName {
                return true
            }
            // Also accept path ending with folder
            if let loc = e["location"] as? [String: Any],
               let path = loc["path"] as? String,
               (path as NSString).lastPathComponent == folderName
            {
                return true
            }
        }
        return false
    }

    public static func versionFromInstallFolder(
        _ folderName: String,
        publisher: String,
        name: String
    ) -> String? {
        let prefix = "\(publisher).\(name)-"
        if folderName.hasPrefix(prefix) {
            let v = String(folderName.dropFirst(prefix.count))
            return v.isEmpty ? nil : v
        }
        let lowerPrefix = prefix.lowercased()
        let lower = folderName.lowercased()
        guard lower.hasPrefix(lowerPrefix) else { return nil }
        let v = String(folderName.dropFirst(lowerPrefix.count))
        return v.isEmpty ? nil : v
    }

    /// Matching install folder for ID, if any.
    public static func matchingInstalledFolder(id: String, installedFolderNames: [String]) -> String? {
        let parsed = parseExtensionId(id)
        let bare = "\(parsed.publisher).\(parsed.name)".lowercased()
        if let ver = parsed.version, !ver.isEmpty {
            let exact = "\(bare)-\(ver.lowercased())"
            return installedFolderNames.first { $0.lowercased() == exact }
        }
        let prefix = "\(bare)-"
        for name in installedFolderNames {
            let lower = name.lowercased()
            if lower == bare { return name }
            if lower.hasPrefix(prefix) { return name }
        }
        return nil
    }

    /// True when an installed folder matches the ID **and** is present in the registry.
    /// Unpinned `publisher.name` matches any `publisher.name-*` (or bare name).
    /// Pinned `publisher.name@version` requires exact `publisher.name-version`.
    /// When `registryEntries` is nil, only the folder check is applied (legacy/tests).
    public static func extensionAlreadyInstalled(
        id: String,
        installedFolderNames: [String],
        registryEntries: [[String: Any]]? = nil
    ) -> Bool {
        guard let folder = matchingInstalledFolder(id: id, installedFolderNames: installedFolderNames)
        else { return false }
        guard let entries = registryEntries else { return true }
        return extensionRegistered(id: id, folderName: folder, entries: entries)
    }

    // MARK: Warnings

    public static func warnSettings(_ detail: String) {
        StatusPrinter.warning("vscode settings apply failed: \(detail)")
    }

    public static func warnExtensions(_ detail: String) {
        StatusPrinter.warning("vscode extensions apply failed: \(detail)")
    }
}
