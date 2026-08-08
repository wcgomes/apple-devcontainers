import Foundation
@testable import ADevContainerLib

// MARK: - Mocks

final class MockVSCodeGuest: VSCodeGuestOperating, @unchecked Sendable {
    var home: String = "/home/vscode"
    var files: [String: String] = [:]
    var dirs: Set<String> = []
    var failResolveHome = false
    var failWritePaths: Set<String> = []
    var failReadPaths: Set<String> = []
    var unpackCalls: [(dest: String, bytes: Int)] = []
    var failUnpack = false
    var removedPaths: [String] = []

    func resolveHome(containerId: String, user: String?) throws -> String {
        if failResolveHome {
            throw CLIError(code: CLIErrorCode.runtimeFailed, message: "no home")
        }
        return home
    }

    func readTextFile(containerId: String, path: String, user: String?) throws -> String? {
        if failReadPaths.contains(path) {
            throw CLIError(code: CLIErrorCode.runtimeFailed, message: "read fail \(path)")
        }
        return files[path]
    }

    func writeTextFile(containerId: String, path: String, contents: String, user: String?) throws {
        if failWritePaths.contains(path) {
            throw CLIError(code: CLIErrorCode.runtimeFailed, message: "write fail \(path)")
        }
        let parent = (path as NSString).deletingLastPathComponent
        dirs.insert(parent)
        files[path] = contents
    }

    func ensureDirectory(containerId: String, path: String, user: String?) throws {
        dirs.insert(path)
    }

    func listDirectoryNames(containerId: String, path: String, user: String?) throws -> [String] {
        let prefix = path.hasSuffix("/") ? path : path + "/"
        var names: [String] = []
        for key in files.keys {
            if key.hasPrefix(prefix) {
                let rest = String(key.dropFirst(prefix.count))
                let first = rest.split(separator: "/").first.map(String.init) ?? ""
                if !first.isEmpty { names.append(first) }
            }
        }
        // Also treat dirs under path as entries
        for d in dirs {
            if d.hasPrefix(prefix) {
                let rest = String(d.dropFirst(prefix.count))
                let first = rest.split(separator: "/").first.map(String.init) ?? ""
                if !first.isEmpty { names.append(first) }
            }
        }
        return Array(Set(names)).sorted()
    }

    func removeFile(containerId: String, path: String, user: String?) throws {
        removedPaths.append(path)
        files.removeValue(forKey: path)
    }

    /// Optional package.json body keyed by install folder name (last path component of destDir).
    var packageJSONByInstallFolder: [String: String] = [:]

    func unpackZip(containerId: String, zipData: Data, destDir: String, user: String?) throws {
        unpackCalls.append((destDir, zipData.count))
        if failUnpack {
            throw CLIError(code: CLIErrorCode.runtimeFailed, message: "unpack failed")
        }
        dirs.insert(destDir)
        let folderName = (destDir as NSString).lastPathComponent
        let pkg = packageJSONByInstallFolder[folderName] ?? #"{ "name": "ext" }"#
        files[(destDir as NSString).appendingPathComponent("package.json")] = pkg
    }
}

final class MockVSCodeDownloader: VSCodeVSIXDownloading, @unchecked Sendable {
    var artifacts: [String: VSCodeVSIXArtifact] = [:]
    var failIDs: Set<String> = []
    var calls: [String] = []

    func fetchVSIX(extensionId: String) throws -> VSCodeVSIXArtifact {
        calls.append(extensionId)
        if failIDs.contains(extensionId) {
            throw CLIError(code: CLIErrorCode.runtimeFailed, message: "download \(extensionId)")
        }
        if let a = artifacts[extensionId] { return a }
        let parsed = VSCodeCustomizationsApply.parseExtensionId(extensionId)
        return VSCodeVSIXArtifact(
            data: Data("fake-vsix-\(extensionId)".utf8),
            installFolderName: "\(parsed.publisher).\(parsed.name)-1.0.0"
        )
    }
}

private enum VSCodeApplyTestSupport {
    static func install(
        guest: MockVSCodeGuest? = nil,
        downloader: MockVSCodeDownloader? = nil
    ) -> () -> Void {
        let prevG = VSCodeCustomizationsApply.guestOverride
        let prevD = VSCodeCustomizationsApply.downloaderOverride
        if let guest { VSCodeCustomizationsApply.guestOverride = guest }
        if let downloader { VSCodeCustomizationsApply.downloaderOverride = downloader }
        return {
            VSCodeCustomizationsApply.guestOverride = prevG
            VSCodeCustomizationsApply.downloaderOverride = prevD
        }
    }

    static func config(
        extensions: [String] = [],
        settings: [String: Any] = [:],
        remoteUser: String? = "vscode"
    ) throws -> ResolvedDevContainerConfig {
        let data = try JSONSerialization.data(withJSONObject: settings, options: [.sortedKeys])
        return ResolvedDevContainerConfig(
            image: "alpine:3.20",
            remoteUser: remoteUser,
            workspaceFolder: "/workspaces/app",
            hasVscodeCustomizations: !extensions.isEmpty || !settings.isEmpty,
            vscodeExtensions: extensions,
            vscodeSettingsJSON: data
        )
    }

    static func dummyRuntime() -> AppleContainerRuntime {
        AppleContainerRuntime(
            executablePath: "/usr/local/bin/container",
            runner: MockProcessRunner()
        )
    }
}

// MARK: - Unit tests

nonisolated(unsafe) let vscodeCustomizationsApplyTests: [(String, () throws -> Void)] = [
    ("vscodeNormalizeAndHashStable", {
        let a = VSCodeCustomizationsApply.normalize(
            extensions: [" ms-python.python ", "swiftlang.swift-vscode", "ms-python.python"],
            settingsJSON: try JSONSerialization.data(
                withJSONObject: ["z": 1, "a": true] as [String: Any],
                options: []
            )
        )
        let b = VSCodeCustomizationsApply.normalize(
            extensions: ["swiftlang.swift-vscode", "ms-python.python"],
            settingsJSON: try JSONSerialization.data(
                withJSONObject: ["a": true, "z": 1] as [String: Any],
                options: [.sortedKeys]
            )
        )
        try MiniTest.expectEqual(a.extensions, ["ms-python.python", "swiftlang.swift-vscode"])
        try MiniTest.expectEqual(a.contentHash, b.contentHash)
        try MiniTest.expectEqual(a.contentHash.count, 64)
        try MiniTest.expectEqual(a.contentHash, a.contentHash.lowercased())

        let different = VSCodeCustomizationsApply.normalize(
            extensions: ["other.ext"],
            settingsJSON: a.settingsJSON
        )
        try MiniTest.expect(a.contentHash != different.contentHash)
    }),

    ("vscodeMarkerMatchSkipsApply", {
        let guest = MockVSCodeGuest()
        let dl = MockVSCodeDownloader()
        let restore = VSCodeApplyTestSupport.install(guest: guest, downloader: dl)
        defer { restore() }
        let config = try VSCodeApplyTestSupport.config(
            extensions: ["a.b"],
            settings: ["x": 1]
        )
        let payload = VSCodeCustomizationsPayload.from(config: config)
        let markerPath = VSCodeCustomizationsApply.markerPath(home: guest.home)
        guest.files[markerPath] = payload.contentHash + "\n"

        let s = VSCodeCustomizationsApply.applySettingsIfNeeded(
            containerId: "c1",
            config: config,
            runtime: VSCodeApplyTestSupport.dummyRuntime()
        )
        try MiniTest.expectEqual(s, .skippedMatchingMarker)

        let e = VSCodeCustomizationsApply.applyExtensionsIfNeeded(
            containerId: "c1",
            config: config,
            runtime: VSCodeApplyTestSupport.dummyRuntime()
        )
        try MiniTest.expectEqual(e, .skippedMatchingMarker)
        try MiniTest.expectEqual(dl.calls.count, 0)
        try MiniTest.expectEqual(guest.unpackCalls.count, 0)
    }),

    ("vscodeMarkerMissingRunsApplyAndWritesOnFullSuccess", {
        let guest = MockVSCodeGuest()
        let dl = MockVSCodeDownloader()
        let restore = VSCodeApplyTestSupport.install(guest: guest, downloader: dl)
        defer { restore() }
        let config = try VSCodeApplyTestSupport.config(
            extensions: ["pub.name"],
            settings: ["editor.tabSize": 4]
        )
        let payload = VSCodeCustomizationsPayload.from(config: config)

        let s = VSCodeCustomizationsApply.applySettingsIfNeeded(
            containerId: "c1",
            config: config,
            runtime: VSCodeApplyTestSupport.dummyRuntime()
        )
        try MiniTest.expectEqual(s, .applied)
        let settingsPath = VSCodeCustomizationsApply.settingsPath(home: guest.home)
        try MiniTest.expect(guest.files[settingsPath] != nil)
        // Extensions still pending → marker not full hash yet
        let markerPath = VSCodeCustomizationsApply.markerPath(home: guest.home)
        try MiniTest.expect(guest.files[markerPath] == nil)

        let e = VSCodeCustomizationsApply.applyExtensionsIfNeeded(
            containerId: "c1",
            config: config,
            runtime: VSCodeApplyTestSupport.dummyRuntime()
        )
        try MiniTest.expectEqual(e, .applied)
        try MiniTest.expectEqual(dl.calls, ["pub.name"])
        try MiniTest.expectEqual(guest.unpackCalls.count, 1)
        let marker = guest.files[markerPath]?.trimmingCharacters(in: .whitespacesAndNewlines)
        try MiniTest.expectEqual(marker, payload.contentHash)
    }),

    ("vscodeMarkerDriftReapplies", {
        let guest = MockVSCodeGuest()
        let dl = MockVSCodeDownloader()
        let restore = VSCodeApplyTestSupport.install(guest: guest, downloader: dl)
        defer { restore() }
        let markerPath = VSCodeCustomizationsApply.markerPath(home: guest.home)
        guest.files[markerPath] = "oldhash"

        let config = try VSCodeApplyTestSupport.config(settings: ["a": 1])
        let s = VSCodeCustomizationsApply.applySettingsIfNeeded(
            containerId: "c1",
            config: config,
            runtime: VSCodeApplyTestSupport.dummyRuntime()
        )
        try MiniTest.expectEqual(s, .applied)
        let newHash = VSCodeCustomizationsPayload.from(config: config).contentHash
        try MiniTest.expectEqual(
            guest.files[markerPath]?.trimmingCharacters(in: .whitespacesAndNewlines),
            newHash
        )
    }),

    ("vscodeSettingsOnlyWritesMarker", {
        let guest = MockVSCodeGuest()
        let restore = VSCodeApplyTestSupport.install(guest: guest)
        defer { restore() }
        let config = try VSCodeApplyTestSupport.config(settings: ["k": "v"])
        let outcome = VSCodeCustomizationsApply.applySettingsIfNeeded(
            containerId: "c1",
            config: config,
            runtime: VSCodeApplyTestSupport.dummyRuntime()
        )
        try MiniTest.expectEqual(outcome, .applied)
        let markerPath = VSCodeCustomizationsApply.markerPath(home: guest.home)
        try MiniTest.expectEqual(
            guest.files[markerPath]?.trimmingCharacters(in: .whitespacesAndNewlines),
            VSCodeCustomizationsPayload.from(config: config).contentHash
        )
    }),

    ("vscodeSettingsMergeOverlaysAndPreserves", {
        let existing = """
        {
          "editor.fontSize" : 14,
          "files.eol" : "\\n"
        }
        """
        let overlay = try JSONSerialization.data(
            withJSONObject: ["editor.formatOnSave": true, "files.eol": "\r\n"] as [String: Any],
            options: [.sortedKeys]
        )
        let merged = try VSCodeCustomizationsApply.mergeSettingsJSON(
            existing: existing,
            configSettings: overlay
        )
        let obj = try JSONSerialization.jsonObject(with: Data(merged.utf8)) as! [String: Any]
        try MiniTest.expectEqual(obj["editor.fontSize"] as? Int, 14)
        try MiniTest.expectEqual(obj["editor.formatOnSave"] as? Bool, true)
        try MiniTest.expectEqual(obj["files.eol"] as? String, "\r\n")
    }),

    ("vscodeSettingsMergeCreatesWhenMissing", {
        let overlay = try JSONSerialization.data(
            withJSONObject: ["a": 1] as [String: Any],
            options: [.sortedKeys]
        )
        let merged = try VSCodeCustomizationsApply.mergeSettingsJSON(
            existing: nil,
            configSettings: overlay
        )
        let obj = try JSONSerialization.jsonObject(with: Data(merged.utf8)) as! [String: Any]
        try MiniTest.expectEqual(obj["a"] as? Int, 1)
    }),

    ("vscodeSettingsInvalidExistingSoftFails", {
        let guest = MockVSCodeGuest()
        let restore = VSCodeApplyTestSupport.install(guest: guest)
        defer { restore() }
        let settingsPath = VSCodeCustomizationsApply.settingsPath(home: guest.home)
        guest.files[settingsPath] = "not-json{{{"
        let config = try VSCodeApplyTestSupport.config(settings: ["a": 1])
        let outcome = VSCodeCustomizationsApply.applySettingsIfNeeded(
            containerId: "c1",
            config: config,
            runtime: VSCodeApplyTestSupport.dummyRuntime()
        )
        try MiniTest.expect(outcome.isSoftFail)
        // Must not throw / not write full marker on soft-fail mid-merge
    }),

    ("vscodeExtensionsSkipAlreadyPresent", {
        let guest = MockVSCodeGuest()
        let dl = MockVSCodeDownloader()
        let restore = VSCodeApplyTestSupport.install(guest: guest, downloader: dl)
        defer { restore() }
        let extDir = VSCodeCustomizationsApply.extensionsDir(home: guest.home)
        let folder = "pub.name-2.0.0"
        guest.dirs.insert(extDir)
        guest.dirs.insert((extDir as NSString).appendingPathComponent(folder))
        let entry = VSCodeCustomizationsApply.makeRegistryEntry(
            extensionId: "pub.name",
            folderName: folder,
            extensionsDir: extDir,
            installedTimestampMs: 1
        )
        let regJSON = try VSCodeCustomizationsApply.serializeExtensionsRegistry([entry])
        guest.files[VSCodeCustomizationsApply.extensionsRegistryPath(home: guest.home)] = regJSON
        let config = try VSCodeApplyTestSupport.config(extensions: ["pub.name"])
        let outcome = VSCodeCustomizationsApply.applyExtensionsIfNeeded(
            containerId: "c1",
            config: config,
            runtime: VSCodeApplyTestSupport.dummyRuntime()
        )
        try MiniTest.expectEqual(outcome, .applied)
        try MiniTest.expectEqual(dl.calls.count, 0)
        try MiniTest.expectEqual(guest.unpackCalls.count, 0)
        let markerPath = VSCodeCustomizationsApply.markerPath(home: guest.home)
        try MiniTest.expect(guest.files[markerPath] != nil)
    }),

    ("vscodeExtensionsReconcileRegistryWhenFolderExists", {
        let guest = MockVSCodeGuest()
        let dl = MockVSCodeDownloader()
        let restore = VSCodeApplyTestSupport.install(guest: guest, downloader: dl)
        defer { restore() }
        let extDir = VSCodeCustomizationsApply.extensionsDir(home: guest.home)
        let folder = "pub.name-2.0.0"
        guest.dirs.insert(extDir)
        guest.dirs.insert((extDir as NSString).appendingPathComponent(folder))
        guest.files[VSCodeCustomizationsApply.extensionsRegistryPath(home: guest.home)] = "[]"
        let cachePath = VSCodeCustomizationsApply.extensionsUserCachePath(home: guest.home)
        guest.files[cachePath] = "stale-cache"
        let config = try VSCodeApplyTestSupport.config(extensions: ["pub.name"])
        let outcome = VSCodeCustomizationsApply.applyExtensionsIfNeeded(
            containerId: "c1",
            config: config,
            runtime: VSCodeApplyTestSupport.dummyRuntime()
        )
        try MiniTest.expectEqual(outcome, .applied)
        try MiniTest.expectEqual(dl.calls.count, 0)
        try MiniTest.expectEqual(guest.unpackCalls.count, 0)
        let regPath = VSCodeCustomizationsApply.extensionsRegistryPath(home: guest.home)
        let regText = guest.files[regPath] ?? ""
        let entries = VSCodeCustomizationsApply.parseExtensionsRegistry(regText)
        try MiniTest.expectEqual(entries.count, 1)
        try MiniTest.expectEqual(
            VSCodeCustomizationsApply.registryEntryId(entries[0])?.lowercased(),
            "pub.name"
        )
        try MiniTest.expectEqual(entries[0]["relativeLocation"] as? String, folder)
        try MiniTest.expectEqual(entries[0]["version"] as? String, "2.0.0")
        try MiniTest.expect(guest.removedPaths.contains(cachePath))
        try MiniTest.expect(guest.files[cachePath] == nil)
    }),

    ("vscodeExtensionsOneFailureDoesNotFinalizeMarker", {
        let guest = MockVSCodeGuest()
        let dl = MockVSCodeDownloader()
        dl.failIDs = ["bad.ext"]
        let restore = VSCodeApplyTestSupport.install(guest: guest, downloader: dl)
        defer { restore() }
        let config = try VSCodeApplyTestSupport.config(extensions: ["good.ext", "bad.ext"])
        let outcome = VSCodeCustomizationsApply.applyExtensionsIfNeeded(
            containerId: "c1",
            config: config,
            runtime: VSCodeApplyTestSupport.dummyRuntime()
        )
        try MiniTest.expect(outcome.isSoftFail)
        try MiniTest.expectEqual(guest.unpackCalls.count, 1)
        let markerPath = VSCodeCustomizationsApply.markerPath(home: guest.home)
        try MiniTest.expect(guest.files[markerPath] == nil)
    }),

    ("vscodeApplyFailuresNeverThrow", {
        let guest = MockVSCodeGuest()
        guest.failResolveHome = true
        let restore = VSCodeApplyTestSupport.install(guest: guest, downloader: MockVSCodeDownloader())
        defer { restore() }
        let config = try VSCodeApplyTestSupport.config(
            extensions: ["a.b"],
            settings: ["x": 1]
        )
        let s = VSCodeCustomizationsApply.applySettingsIfNeeded(
            containerId: "c1",
            config: config,
            runtime: VSCodeApplyTestSupport.dummyRuntime()
        )
        try MiniTest.expect(s.isSoftFail)
        let e = VSCodeCustomizationsApply.applyExtensionsIfNeeded(
            containerId: "c1",
            config: config,
            runtime: VSCodeApplyTestSupport.dummyRuntime()
        )
        try MiniTest.expect(e.isSoftFail)
    }),

    ("vscodeEmptyPayloadSkipped", {
        let guest = MockVSCodeGuest()
        let restore = VSCodeApplyTestSupport.install(guest: guest)
        defer { restore() }
        let config = try VSCodeApplyTestSupport.config()
        let s = VSCodeCustomizationsApply.applySettingsIfNeeded(
            containerId: "c1",
            config: config,
            runtime: VSCodeApplyTestSupport.dummyRuntime()
        )
        try MiniTest.expectEqual(s, .skippedEmpty)
        try MiniTest.expectEqual(guest.files.count, 0)
    }),

    ("vscodeExtensionAlreadyInstalledHelper", {
        try MiniTest.expect(
            VSCodeCustomizationsApply.extensionAlreadyInstalled(
                id: "pub.name",
                installedFolderNames: ["pub.name-1.2.3"]
            )
        )
        try MiniTest.expect(
            !VSCodeCustomizationsApply.extensionAlreadyInstalled(
                id: "pub.other",
                installedFolderNames: ["pub.name-1.2.3"]
            )
        )
        // Pinned version requires exact folder match, not any publisher.name-*.
        try MiniTest.expect(
            !VSCodeCustomizationsApply.extensionAlreadyInstalled(
                id: "pub.name@2.0.0",
                installedFolderNames: ["pub.name-1.2.3"]
            )
        )
        try MiniTest.expect(
            VSCodeCustomizationsApply.extensionAlreadyInstalled(
                id: "pub.name@2.0.0",
                installedFolderNames: ["pub.name-2.0.0"]
            )
        )
        // With registry: folder alone is not enough.
        let entry = VSCodeCustomizationsApply.makeRegistryEntry(
            extensionId: "pub.name",
            folderName: "pub.name-1.2.3",
            extensionsDir: "/ext",
            installedTimestampMs: 1
        )
        try MiniTest.expect(
            !VSCodeCustomizationsApply.extensionAlreadyInstalled(
                id: "pub.name",
                installedFolderNames: ["pub.name-1.2.3"],
                registryEntries: []
            )
        )
        try MiniTest.expect(
            VSCodeCustomizationsApply.extensionAlreadyInstalled(
                id: "pub.name",
                installedFolderNames: ["pub.name-1.2.3"],
                registryEntries: [entry]
            )
        )
    }),

    ("vscodeExtensionsRegistryUpsertMerge", {
        let dir = "/root/.vscode-server/extensions"
        let a = VSCodeCustomizationsApply.makeRegistryEntry(
            extensionId: "swiftlang.swift-vscode",
            folderName: "swiftlang.swift-vscode-2.17.20260702",
            extensionsDir: dir,
            installedTimestampMs: 100
        )
        let b = VSCodeCustomizationsApply.makeRegistryEntry(
            extensionId: "ms-python.python",
            folderName: "ms-python.python-2024.1.0",
            extensionsDir: dir,
            installedTimestampMs: 200
        )
        var entries = VSCodeCustomizationsApply.upsertExtensionsRegistry(entries: [], entry: a)
        entries = VSCodeCustomizationsApply.upsertExtensionsRegistry(entries: entries, entry: b)
        try MiniTest.expectEqual(entries.count, 2)

        // Replace same id with new version/folder
        let a2 = VSCodeCustomizationsApply.makeRegistryEntry(
            extensionId: "swiftlang.swift-vscode",
            folderName: "swiftlang.swift-vscode-3.0.0",
            extensionsDir: dir,
            installedTimestampMs: 300
        )
        entries = VSCodeCustomizationsApply.upsertExtensionsRegistry(entries: entries, entry: a2)
        try MiniTest.expectEqual(entries.count, 2)
        let swift = entries.first { VSCodeCustomizationsApply.registryEntryId($0)?.lowercased() == "swiftlang.swift-vscode" }!
        try MiniTest.expectEqual(swift["version"] as? String, "3.0.0")
        try MiniTest.expectEqual(swift["relativeLocation"] as? String, "swiftlang.swift-vscode-3.0.0")
        let loc = swift["location"] as! [String: Any]
        try MiniTest.expectEqual(loc["scheme"] as? String, "file")
        try MiniTest.expectEqual(
            loc["path"] as? String,
            "\(dir)/swiftlang.swift-vscode-3.0.0"
        )
        try MiniTest.expectEqual(loc["$mid"] as? Int, 1)
        let meta = swift["metadata"] as! [String: Any]
        try MiniTest.expectEqual(meta["source"] as? String, "vsix")
        try MiniTest.expectEqual(meta["pinned"] as? Bool, true)
        try MiniTest.expectEqual(meta["installedTimestamp"] as? Int64, 300)

        // Round-trip serialize/parse
        let json = try VSCodeCustomizationsApply.serializeExtensionsRegistry(entries)
        let parsed = VSCodeCustomizationsApply.parseExtensionsRegistry(json)
        try MiniTest.expectEqual(parsed.count, 2)
        try MiniTest.expectEqual(VSCodeCustomizationsApply.parseExtensionsRegistry(nil).count, 0)
        try MiniTest.expectEqual(VSCodeCustomizationsApply.parseExtensionsRegistry("not-json").count, 0)
    }),

    ("vscodeExtensionsInstallWritesRegistryAndClearsCache", {
        let guest = MockVSCodeGuest()
        let dl = MockVSCodeDownloader()
        let restore = VSCodeApplyTestSupport.install(guest: guest, downloader: dl)
        defer { restore() }
        let cachePath = VSCodeCustomizationsApply.extensionsUserCachePath(home: guest.home)
        guest.files[cachePath] = "stale"
        let config = try VSCodeApplyTestSupport.config(extensions: ["pub.name"])
        let outcome = VSCodeCustomizationsApply.applyExtensionsIfNeeded(
            containerId: "c1",
            config: config,
            runtime: VSCodeApplyTestSupport.dummyRuntime()
        )
        try MiniTest.expectEqual(outcome, .applied)
        let regPath = VSCodeCustomizationsApply.extensionsRegistryPath(home: guest.home)
        let entries = VSCodeCustomizationsApply.parseExtensionsRegistry(guest.files[regPath])
        try MiniTest.expectEqual(entries.count, 1)
        try MiniTest.expectEqual(
            VSCodeCustomizationsApply.registryEntryId(entries[0])?.lowercased(),
            "pub.name"
        )
        try MiniTest.expectEqual(entries[0]["relativeLocation"] as? String, "pub.name-1.0.0")
        try MiniTest.expectEqual(entries[0]["version"] as? String, "1.0.0")
        try MiniTest.expect(guest.removedPaths.contains(cachePath))
        // Marker only after registry write
        let markerPath = VSCodeCustomizationsApply.markerPath(home: guest.home)
        try MiniTest.expect(guest.files[markerPath] != nil)
        try MiniTest.expect(guest.files[regPath] != nil)
    }),

    ("vscodeExtensionsRegistryWriteFailureSkipsMarker", {
        let guest = MockVSCodeGuest()
        let dl = MockVSCodeDownloader()
        let restore = VSCodeApplyTestSupport.install(guest: guest, downloader: dl)
        defer { restore() }
        let regPath = VSCodeCustomizationsApply.extensionsRegistryPath(home: guest.home)
        guest.failWritePaths.insert(regPath)
        let config = try VSCodeApplyTestSupport.config(extensions: ["pub.name"])
        let outcome = VSCodeCustomizationsApply.applyExtensionsIfNeeded(
            containerId: "c1",
            config: config,
            runtime: VSCodeApplyTestSupport.dummyRuntime()
        )
        try MiniTest.expect(outcome.isSoftFail)
        let markerPath = VSCodeCustomizationsApply.markerPath(home: guest.home)
        try MiniTest.expect(guest.files[markerPath] == nil)
    }),

    ("vscodePinnedExtensionInstallsWhenOtherVersionPresent", {
        let guest = MockVSCodeGuest()
        let dl = MockVSCodeDownloader()
        dl.artifacts["pub.name@2.0.0"] = VSCodeVSIXArtifact(
            data: Data("pinned-vsix".utf8),
            installFolderName: "pub.name-2.0.0"
        )
        let restore = VSCodeApplyTestSupport.install(guest: guest, downloader: dl)
        defer { restore() }
        let extDir = VSCodeCustomizationsApply.extensionsDir(home: guest.home)
        guest.dirs.insert(extDir)
        guest.dirs.insert((extDir as NSString).appendingPathComponent("pub.name-1.0.0"))
        let config = try VSCodeApplyTestSupport.config(extensions: ["pub.name@2.0.0"])
        let outcome = VSCodeCustomizationsApply.applyExtensionsIfNeeded(
            containerId: "c1",
            config: config,
            runtime: VSCodeApplyTestSupport.dummyRuntime()
        )
        try MiniTest.expectEqual(outcome, .applied)
        try MiniTest.expectEqual(dl.calls, ["pub.name@2.0.0"])
        try MiniTest.expectEqual(guest.unpackCalls.count, 1)
        try MiniTest.expectEqual(
            guest.unpackCalls[0].dest,
            (extDir as NSString).appendingPathComponent("pub.name-2.0.0")
        )
    }),

    ("vscodeUnpackZipDoesNotEmbedPayloadInArgv", {
        let mock = MockProcessRunner()
        let runtime = AppleContainerRuntime(
            executablePath: "/usr/local/bin/container",
            runner: mock
        )
        let guest = ExecVSCodeGuestOps(runtime: runtime)
        // Multi-MB payload would blow ARG_MAX if base64-embedded in sh -lc.
        let payload = Data(repeating: 0x41, count: 2 * 1024 * 1024)
        try guest.unpackZip(
            containerId: "c1",
            zipData: payload,
            destDir: "/home/vscode/.vscode-server/extensions/pub.name-1.0.0",
            user: "vscode"
        )
        let b64Prefix = String(payload.base64EncodedString().prefix(64))
        var sawHostTar = false
        var maxArgLen = 0
        for call in mock.calls {
            if call.executable == "/usr/bin/tar" { sawHostTar = true }
            for arg in call.arguments {
                maxArgLen = max(maxArgLen, arg.count)
                try MiniTest.expect(!arg.contains(b64Prefix))
            }
        }
        try MiniTest.expect(sawHostTar)
        // Well under typical ARG_MAX (~1MB); payload itself is 2MB.
        try MiniTest.expect(maxArgLen < 64 * 1024)
    }),

    ("vscodeParseExtensionIdOptionalVersion", {
        let p = VSCodeCustomizationsApply.parseExtensionId("ms-python.python@2024.1.0")
        try MiniTest.expectEqual(p.publisher, "ms-python")
        try MiniTest.expectEqual(p.name, "python")
        try MiniTest.expectEqual(p.version, "2024.1.0")
    }),

    ("vscodeParseExtensionDependencies", {
        let json = """
        {
          "name": "swift-vscode",
          "extensionDependencies": [
            "llvm-vs-code-extensions.lldb-dap",
            "  llvm-vs-code-extensions.lldb-dap ",
            123,
            ""
          ]
        }
        """
        let deps = VSCodeCustomizationsApply.parseExtensionDependencies(json)
        try MiniTest.expectEqual(deps, ["llvm-vs-code-extensions.lldb-dap"])
        try MiniTest.expectEqual(VSCodeCustomizationsApply.parseExtensionDependencies(nil), [])
        try MiniTest.expectEqual(VSCodeCustomizationsApply.parseExtensionDependencies("not-json"), [])
        try MiniTest.expectEqual(
            VSCodeCustomizationsApply.parseExtensionDependencies(#"{ "extensionDependencies": "x" }"#),
            []
        )
    }),

    ("vscodeExtensionsInstallsExtensionDependencies", {
        let guest = MockVSCodeGuest()
        let dl = MockVSCodeDownloader()
        guest.packageJSONByInstallFolder["swiftlang.swift-vscode-1.0.0"] = """
        {"extensionDependencies":["llvm-vs-code-extensions.lldb-dap"]}
        """
        guest.packageJSONByInstallFolder["llvm-vs-code-extensions.lldb-dap-1.0.0"] = #"{ "name": "lldb-dap" }"#
        let restore = VSCodeApplyTestSupport.install(guest: guest, downloader: dl)
        defer { restore() }
        let config = try VSCodeApplyTestSupport.config(extensions: ["swiftlang.swift-vscode"])
        let outcome = VSCodeCustomizationsApply.applyExtensionsIfNeeded(
            containerId: "c1",
            config: config,
            runtime: VSCodeApplyTestSupport.dummyRuntime()
        )
        try MiniTest.expectEqual(outcome, .applied)
        try MiniTest.expectEqual(dl.calls, ["swiftlang.swift-vscode", "llvm-vs-code-extensions.lldb-dap"])
        try MiniTest.expectEqual(guest.unpackCalls.count, 2)
        let regPath = VSCodeCustomizationsApply.extensionsRegistryPath(home: guest.home)
        let entries = VSCodeCustomizationsApply.parseExtensionsRegistry(guest.files[regPath])
        try MiniTest.expectEqual(entries.count, 2)
        let ids = Set(entries.compactMap { VSCodeCustomizationsApply.registryEntryId($0)?.lowercased() })
        try MiniTest.expect(ids.contains("swiftlang.swift-vscode"))
        try MiniTest.expect(ids.contains("llvm-vs-code-extensions.lldb-dap"))
        // Marker hash stays config-only (primary list), not transitive deps.
        let markerPath = VSCodeCustomizationsApply.markerPath(home: guest.home)
        try MiniTest.expectEqual(
            guest.files[markerPath]?.trimmingCharacters(in: .whitespacesAndNewlines),
            VSCodeCustomizationsPayload.from(config: config).contentHash
        )
    }),

    ("vscodeExtensionsDependencyCycleDoesNotLoop", {
        let guest = MockVSCodeGuest()
        let dl = MockVSCodeDownloader()
        guest.packageJSONByInstallFolder["pub.a-1.0.0"] = """
        {"extensionDependencies":["pub.b"]}
        """
        guest.packageJSONByInstallFolder["pub.b-1.0.0"] = """
        {"extensionDependencies":["pub.a"]}
        """
        let restore = VSCodeApplyTestSupport.install(guest: guest, downloader: dl)
        defer { restore() }
        let config = try VSCodeApplyTestSupport.config(extensions: ["pub.a"])
        let outcome = VSCodeCustomizationsApply.applyExtensionsIfNeeded(
            containerId: "c1",
            config: config,
            runtime: VSCodeApplyTestSupport.dummyRuntime()
        )
        try MiniTest.expectEqual(outcome, .applied)
        try MiniTest.expectEqual(dl.calls, ["pub.a", "pub.b"])
        try MiniTest.expectEqual(guest.unpackCalls.count, 2)
        let regPath = VSCodeCustomizationsApply.extensionsRegistryPath(home: guest.home)
        let entries = VSCodeCustomizationsApply.parseExtensionsRegistry(guest.files[regPath])
        try MiniTest.expectEqual(entries.count, 2)
    }),

    ("vscodeExtensionsExpandsDepsWhenPrimaryAlreadyInstalled", {
        let guest = MockVSCodeGuest()
        let dl = MockVSCodeDownloader()
        let extDir = VSCodeCustomizationsApply.extensionsDir(home: guest.home)
        let primaryFolder = "swiftlang.swift-vscode-2.0.0"
        guest.dirs.insert(extDir)
        guest.dirs.insert((extDir as NSString).appendingPathComponent(primaryFolder))
        guest.files[
            ((extDir as NSString).appendingPathComponent(primaryFolder) as NSString)
                .appendingPathComponent("package.json")
        ] = """
        {"extensionDependencies":["llvm-vs-code-extensions.lldb-dap"]}
        """
        let primaryEntry = VSCodeCustomizationsApply.makeRegistryEntry(
            extensionId: "swiftlang.swift-vscode",
            folderName: primaryFolder,
            extensionsDir: extDir,
            installedTimestampMs: 1
        )
        guest.files[VSCodeCustomizationsApply.extensionsRegistryPath(home: guest.home)] =
            try VSCodeCustomizationsApply.serializeExtensionsRegistry([primaryEntry])
        guest.packageJSONByInstallFolder["llvm-vs-code-extensions.lldb-dap-1.0.0"] =
            #"{ "name": "lldb-dap" }"#
        let restore = VSCodeApplyTestSupport.install(guest: guest, downloader: dl)
        defer { restore() }
        let config = try VSCodeApplyTestSupport.config(extensions: ["swiftlang.swift-vscode"])
        let outcome = VSCodeCustomizationsApply.applyExtensionsIfNeeded(
            containerId: "c1",
            config: config,
            runtime: VSCodeApplyTestSupport.dummyRuntime()
        )
        try MiniTest.expectEqual(outcome, .applied)
        try MiniTest.expectEqual(dl.calls, ["llvm-vs-code-extensions.lldb-dap"])
        try MiniTest.expectEqual(guest.unpackCalls.count, 1)
        let entries = VSCodeCustomizationsApply.parseExtensionsRegistry(
            guest.files[VSCodeCustomizationsApply.extensionsRegistryPath(home: guest.home)]
        )
        try MiniTest.expectEqual(entries.count, 2)
        let ids = Set(entries.compactMap { VSCodeCustomizationsApply.registryEntryId($0)?.lowercased() })
        try MiniTest.expect(ids.contains("llvm-vs-code-extensions.lldb-dap"))
    }),

    ("vscodeExtensionsSkipsAlreadyInstalledDependency", {
        let guest = MockVSCodeGuest()
        let dl = MockVSCodeDownloader()
        let extDir = VSCodeCustomizationsApply.extensionsDir(home: guest.home)
        let depFolder = "llvm-vs-code-extensions.lldb-dap-0.2.0"
        guest.dirs.insert(extDir)
        guest.dirs.insert((extDir as NSString).appendingPathComponent(depFolder))
        // Pre-install dep folder + registry entry.
        let depEntry = VSCodeCustomizationsApply.makeRegistryEntry(
            extensionId: "llvm-vs-code-extensions.lldb-dap",
            folderName: depFolder,
            extensionsDir: extDir,
            installedTimestampMs: 1
        )
        guest.files[VSCodeCustomizationsApply.extensionsRegistryPath(home: guest.home)] =
            try VSCodeCustomizationsApply.serializeExtensionsRegistry([depEntry])
        guest.files[
            ((extDir as NSString).appendingPathComponent(depFolder) as NSString)
                .appendingPathComponent("package.json")
        ] = #"{ "name": "lldb-dap" }"#
        guest.packageJSONByInstallFolder["swiftlang.swift-vscode-1.0.0"] = """
        {"extensionDependencies":["llvm-vs-code-extensions.lldb-dap"]}
        """
        let restore = VSCodeApplyTestSupport.install(guest: guest, downloader: dl)
        defer { restore() }
        let config = try VSCodeApplyTestSupport.config(extensions: ["swiftlang.swift-vscode"])
        let outcome = VSCodeCustomizationsApply.applyExtensionsIfNeeded(
            containerId: "c1",
            config: config,
            runtime: VSCodeApplyTestSupport.dummyRuntime()
        )
        try MiniTest.expectEqual(outcome, .applied)
        try MiniTest.expectEqual(dl.calls, ["swiftlang.swift-vscode"])
        try MiniTest.expectEqual(guest.unpackCalls.count, 1)
        let entries = VSCodeCustomizationsApply.parseExtensionsRegistry(
            guest.files[VSCodeCustomizationsApply.extensionsRegistryPath(home: guest.home)]
        )
        try MiniTest.expectEqual(entries.count, 2)
    }),

    ("vscodeSettingsPathAndExtensionsDirLayout", {
        let home = "/home/vscode"
        try MiniTest.expectEqual(
            VSCodeCustomizationsApply.settingsPath(home: home),
            "/home/vscode/.vscode-server/data/Machine/settings.json"
        )
        try MiniTest.expectEqual(
            VSCodeCustomizationsApply.extensionsDir(home: home),
            "/home/vscode/.vscode-server/extensions"
        )
        try MiniTest.expectEqual(
            VSCodeCustomizationsApply.markerPath(home: home),
            "/home/vscode/.adevcontainer/vscode-customizations.applied"
        )
    })
]
