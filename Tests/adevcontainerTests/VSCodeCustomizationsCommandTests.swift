import Foundation
@testable import ADevContainerLib

// MARK: - Shared helpers

private enum VSCodeCustCmdSupport {
    static func installOpen(
        launcher: MockVSCodeLauncher,
        resolverPath: String? = "/opt/code"
    ) -> () -> Void {
        let prevLauncher = VSCodeOpen.launcherOverride
        let prevResolver = VSCodeOpen.resolverOverride
        let prevWrite = VSCodeOpen.writeNameConfigEnabled
        VSCodeOpen.launcherOverride = launcher
        VSCodeOpen.resolverOverride = MockVSCodeResolver(path: resolverPath)
        VSCodeOpen.writeNameConfigEnabled = false
        return {
            VSCodeOpen.launcherOverride = prevLauncher
            VSCodeOpen.resolverOverride = prevResolver
            VSCodeOpen.writeNameConfigEnabled = prevWrite
        }
    }

    static func installApply(
        guest: MockVSCodeGuest,
        downloader: MockVSCodeDownloader = MockVSCodeDownloader()
    ) -> () -> Void {
        let prevG = VSCodeCustomizationsApply.guestOverride
        let prevD = VSCodeCustomizationsApply.downloaderOverride
        VSCodeCustomizationsApply.guestOverride = guest
        VSCodeCustomizationsApply.downloaderOverride = downloader
        return {
            VSCodeCustomizationsApply.guestOverride = prevG
            VSCodeCustomizationsApply.downloaderOverride = prevD
        }
    }

    static func freshUpMock(resolved: ResolvedWorkspace) -> MockProcessRunner {
        let mock = MockProcessRunner()
        mock.handlers = [
            { args in
                if args.starts(with: ["list"]) {
                    let data = try! JSONSerialization.data(withJSONObject: [] as [Any])
                    return ProcessResult(exitCode: 0, stdout: data, stderr: Data())
                }
                if args.first == "create" {
                    return ProcessResult(
                        exitCode: 0,
                        stdout: Data("\(resolved.containerName)\n".utf8),
                        stderr: Data()
                    )
                }
                if args.first == "start" {
                    return ProcessResult(exitCode: 0, stdout: Data(), stderr: Data())
                }
                if args.first == "exec" {
                    return ProcessResult(exitCode: 0, stdout: Data(), stderr: Data())
                }
                if args.first == "delete" {
                    return ProcessResult(exitCode: 0, stdout: Data(), stderr: Data())
                }
                return ProcessResult(exitCode: 0, stdout: Data(), stderr: Data())
            }
        ]
        return mock
    }

    static func configJSON(settings: Bool, extensions: Bool, postAttach: String? = nil) -> String {
        var vscode: [String] = []
        if extensions {
            vscode.append(#""extensions": ["pub.name"]"#)
        }
        if settings {
            vscode.append(#""settings": { "editor.tabSize": 2 }"#)
        }
        let vscodeBody = vscode.joined(separator: ", ")
        var parts = [
            #""image": "alpine:3.20""#,
            #""customizations": { "vscode": { \#(vscodeBody) } }"#
        ]
        if let postAttach {
            parts.append(#""postAttachCommand": "\#(postAttach)""#)
        }
        return "{ \(parts.joined(separator: ", ")) }"
    }

    static func shellBodies(from mock: MockProcessRunner) -> [String] {
        mock.calls.compactMap { call -> String? in
            guard call.arguments.first == "exec" else { return nil }
            if let lc = call.arguments.firstIndex(of: "-lc"), lc + 1 < call.arguments.count {
                return call.arguments[lc + 1]
            }
            return nil
        }
    }

    /// True when guest `extensions.json` lists `id` (case-insensitive identifier).
    static func registryLists(_ guest: MockVSCodeGuest, id: String) -> Bool {
        let path = VSCodeCustomizationsApply.extensionsRegistryPath(home: guest.home)
        guard let text = guest.files[path],
              let data = text.data(using: .utf8),
              let arr = try? JSONSerialization.jsonObject(with: data) as? [[String: Any]]
        else { return false }
        let want = id.lowercased()
        return arr.contains { entry in
            let ident = entry["identifier"] as? [String: Any]
            return (ident?["id"] as? String)?.lowercased() == want
        }
    }

    static func startRuntimeMock(
        resolved: ResolvedWorkspace,
        state: String,
        extraLabels: [String: String] = [:]
    ) -> MockProcessRunner {
        var labels = resolved.labels
        labels[ContainerIdentity.labelManaged] = ContainerIdentity.managedValue
        labels[ContainerIdentity.labelWorkspaceFolder] = resolved.config.workspaceFolder
        labels[ContainerIdentity.labelLocalFolder] = resolved.workspacePath
        labels[ContainerIdentity.labelConfigFile] = resolved.configPath
        for (k, v) in extraLabels { labels[k] = v }
        let entry = MockProcessRunner.containerListJSON(
            id: resolved.containerName,
            state: state,
            labels: labels,
            image: "alpine:3.20"
        )
        let mock = MockProcessRunner()
        mock.handlers = [
            { args in
                if args.starts(with: ["list"]) {
                    let data = try! JSONSerialization.data(withJSONObject: [entry])
                    return ProcessResult(exitCode: 0, stdout: data, stderr: Data())
                }
                if args.first == "start" {
                    return ProcessResult(exitCode: 0, stdout: Data(), stderr: Data())
                }
                if args.first == "inspect" {
                    let data = try! JSONSerialization.data(withJSONObject: entry)
                    return ProcessResult(exitCode: 0, stdout: data, stderr: Data())
                }
                if args.first == "exec" {
                    return ProcessResult(exitCode: 0, stdout: Data(), stderr: Data())
                }
                return ProcessResult(exitCode: 0, stdout: Data(), stderr: Data())
            }
        ]
        return mock
    }
}

nonisolated(unsafe) let vscodeCustomizationsCommandTests: [(String, () throws -> Void)] = [
    // MARK: Settings wiring

    ("upCreatePathAppliesSettingsWithoutVSCode", {
        let ws = try TestRepo.makeTempWorkspace(
            configJSON: VSCodeCustCmdSupport.configJSON(settings: true, extensions: true)
        )
        defer { try? FileManager.default.removeItem(at: ws) }
        let resolved = try ConfigResolver.resolve(workspacePath: ws.path, localEnv: [:])
        let mock = VSCodeCustCmdSupport.freshUpMock(resolved: resolved)
        let guest = MockVSCodeGuest()
        let dl = MockVSCodeDownloader()
        let restoreApply = VSCodeCustCmdSupport.installApply(guest: guest, downloader: dl)
        defer { restoreApply() }
        let launcher = MockVSCodeLauncher()
        let restoreOpen = VSCodeCustCmdSupport.installOpen(launcher: launcher)
        defer { restoreOpen() }

        let runtime = AppleContainerRuntime(executablePath: "/usr/local/bin/container", runner: mock)
        let result = try UpCommand.run(
            options: UpOptions(workspacePath: ws.path, skipPull: true, openVSCode: false),
            runtime: runtime,
            localEnv: [:]
        )
        try MiniTest.expectEqual(result.outcome, "success")
        try MiniTest.expectEqual(launcher.calls.count, 0)
        let settingsPath = VSCodeCustomizationsApply.settingsPath(home: guest.home)
        try MiniTest.expect(guest.files[settingsPath] != nil)
        let obj = try JSONSerialization.jsonObject(with: Data(guest.files[settingsPath]!.utf8)) as! [String: Any]
        try MiniTest.expectEqual(obj["editor.tabSize"] as? Int, 2)
        // Extensions also apply without --vscode; full payload finalizes the marker.
        try MiniTest.expectEqual(dl.calls, ["pub.name"])
        try MiniTest.expectEqual(guest.unpackCalls.count, 1)
        try MiniTest.expect(VSCodeCustCmdSupport.registryLists(guest, id: "pub.name"))
        let markerPath = VSCodeCustomizationsApply.markerPath(home: guest.home)
        try MiniTest.expectEqual(
            guest.files[markerPath]?.trimmingCharacters(in: .whitespacesAndNewlines),
            VSCodeCustomizationsPayload.from(config: resolved.config).contentHash
        )
        try MiniTest.expect(!mock.calls.contains { $0.arguments.first == "delete" })
    }),

    ("upSettingsSoftFailKeepsSuccessNoDelete", {
        let ws = try TestRepo.makeTempWorkspace(
            configJSON: VSCodeCustCmdSupport.configJSON(settings: true, extensions: false)
        )
        defer { try? FileManager.default.removeItem(at: ws) }
        let resolved = try ConfigResolver.resolve(workspacePath: ws.path, localEnv: [:])
        let mock = VSCodeCustCmdSupport.freshUpMock(resolved: resolved)
        let guest = MockVSCodeGuest()
        guest.failResolveHome = true
        let restoreApply = VSCodeCustCmdSupport.installApply(guest: guest)
        defer { restoreApply() }

        let runtime = AppleContainerRuntime(executablePath: "/usr/local/bin/container", runner: mock)
        let result = try UpCommand.run(
            options: UpOptions(workspacePath: ws.path, skipPull: true, openVSCode: false),
            runtime: runtime,
            localEnv: [:]
        )
        try MiniTest.expectEqual(result.outcome, "success")
        try MiniTest.expect(!mock.calls.contains { $0.arguments.first == "delete" })
    }),

    ("cloneCreatePathAppliesSettings", {
        let restoreFeatures = CloneGitFeatureTestSupport.installOverrides()
        defer { restoreFeatures() }
        let git = MockGitClient()
        git.configJSONToWrite = VSCodeCustCmdSupport.configJSON(settings: true, extensions: false)
        let mock = MockProcessRunner()
        mock.handlers = CloneRuntimeMock.handlers()
        let guest = MockVSCodeGuest()
        let restoreApply = VSCodeCustCmdSupport.installApply(guest: guest)
        defer { restoreApply() }
        let launcher = MockVSCodeLauncher()
        let restoreOpen = VSCodeCustCmdSupport.installOpen(launcher: launcher)
        defer { restoreOpen() }

        let runtime = AppleContainerRuntime(executablePath: "/usr/local/bin/container", runner: mock)
        let result = try CloneCommand.run(
            options: CloneOptions(
                gitURL: "https://github.com/org/clone-vsc-settings.git",
                skipPull: true,
                openVSCode: false
            ),
            runtime: runtime,
            git: git,
            credentials: MockGitCredential(),
            localEnv: [:]
        )
        try MiniTest.expectEqual(result.outcome, "success")
        let settingsPath = VSCodeCustomizationsApply.settingsPath(home: guest.home)
        try MiniTest.expect(guest.files[settingsPath] != nil)
        try MiniTest.expectEqual(launcher.calls.count, 0)
    }),

    ("upReuseRepairsSettingsOnMarkerDrift", {
        let ws = try TestRepo.makeTempWorkspace(
            configJSON: VSCodeCustCmdSupport.configJSON(settings: true, extensions: true)
        )
        defer { try? FileManager.default.removeItem(at: ws) }
        let resolved = try ConfigResolver.resolve(workspacePath: ws.path, localEnv: [:])
        let entry = MockProcessRunner.containerListJSON(
            id: resolved.containerName,
            state: "running",
            labels: resolved.labels,
            image: "alpine:3.20"
        )
        let mock = MockProcessRunner()
        mock.handlers = [
            { args in
                if args.starts(with: ["list"]) {
                    let data = try! JSONSerialization.data(withJSONObject: [entry])
                    return ProcessResult(exitCode: 0, stdout: data, stderr: Data())
                }
                return nil
            }
        ]
        let guest = MockVSCodeGuest()
        guest.files[VSCodeCustomizationsApply.markerPath(home: guest.home)] = "stale"
        let dl = MockVSCodeDownloader()
        let restoreApply = VSCodeCustCmdSupport.installApply(guest: guest, downloader: dl)
        defer { restoreApply() }
        let launcher = MockVSCodeLauncher()
        let restoreOpen = VSCodeCustCmdSupport.installOpen(launcher: launcher)
        defer { restoreOpen() }

        let runtime = AppleContainerRuntime(executablePath: "/usr/local/bin/container", runner: mock)
        let result = try UpCommand.run(
            options: UpOptions(workspacePath: ws.path, skipPull: true, openVSCode: false),
            runtime: runtime,
            localEnv: [:]
        )
        try MiniTest.expectEqual(result.outcome, "success")
        try MiniTest.expectEqual(launcher.calls.count, 0)
        let settingsPath = VSCodeCustomizationsApply.settingsPath(home: guest.home)
        try MiniTest.expect(guest.files[settingsPath] != nil)
        try MiniTest.expectEqual(dl.calls, ["pub.name"])
        try MiniTest.expectEqual(guest.unpackCalls.count, 1)
        try MiniTest.expect(VSCodeCustCmdSupport.registryLists(guest, id: "pub.name"))
        let newHash = VSCodeCustomizationsPayload.from(config: resolved.config).contentHash
        try MiniTest.expectEqual(
            guest.files[VSCodeCustomizationsApply.markerPath(home: guest.home)]?
                .trimmingCharacters(in: .whitespacesAndNewlines),
            newHash
        )
    }),

    ("upStartStoppedAppliesPendingCustomizationsWithoutVSCode", {
        let ws = try TestRepo.makeTempWorkspace(
            configJSON: VSCodeCustCmdSupport.configJSON(settings: true, extensions: true)
        )
        defer { try? FileManager.default.removeItem(at: ws) }
        let resolved = try ConfigResolver.resolve(workspacePath: ws.path, localEnv: [:])
        let entry = MockProcessRunner.containerListJSON(
            id: resolved.containerName,
            state: "stopped",
            labels: resolved.labels,
            image: "alpine:3.20"
        )
        let mock = MockProcessRunner()
        mock.handlers = [
            { args in
                if args.starts(with: ["list"]) {
                    let data = try! JSONSerialization.data(withJSONObject: [entry])
                    return ProcessResult(exitCode: 0, stdout: data, stderr: Data())
                }
                if args.first == "start" {
                    return ProcessResult(exitCode: 0, stdout: Data(), stderr: Data())
                }
                if args.first == "exec" {
                    return ProcessResult(exitCode: 0, stdout: Data(), stderr: Data())
                }
                return nil
            }
        ]
        let guest = MockVSCodeGuest()
        guest.files[VSCodeCustomizationsApply.markerPath(home: guest.home)] = "stale"
        let dl = MockVSCodeDownloader()
        let restoreApply = VSCodeCustCmdSupport.installApply(guest: guest, downloader: dl)
        defer { restoreApply() }
        let launcher = MockVSCodeLauncher()
        let restoreOpen = VSCodeCustCmdSupport.installOpen(launcher: launcher)
        defer { restoreOpen() }

        let runtime = AppleContainerRuntime(executablePath: "/usr/local/bin/container", runner: mock)
        let result = try UpCommand.run(
            options: UpOptions(workspacePath: ws.path, skipPull: true, openVSCode: false),
            runtime: runtime,
            localEnv: [:]
        )
        try MiniTest.expectEqual(result.outcome, "success")
        try MiniTest.expectEqual(launcher.calls.count, 0)
        try MiniTest.expect(mock.calls.contains { $0.arguments.first == "start" })
        try MiniTest.expect(!mock.calls.contains { $0.arguments.first == "create" })
        let settingsPath = VSCodeCustomizationsApply.settingsPath(home: guest.home)
        try MiniTest.expect(guest.files[settingsPath] != nil)
        try MiniTest.expectEqual(dl.calls, ["pub.name"])
        try MiniTest.expectEqual(guest.unpackCalls.count, 1)
        try MiniTest.expect(VSCodeCustCmdSupport.registryLists(guest, id: "pub.name"))
        let newHash = VSCodeCustomizationsPayload.from(config: resolved.config).contentHash
        try MiniTest.expectEqual(
            guest.files[VSCodeCustomizationsApply.markerPath(home: guest.home)]?
                .trimmingCharacters(in: .whitespacesAndNewlines),
            newHash
        )
    }),

    ("upReuseMatchingMarkerSkipsApplyWithoutVSCode", {
        let ws = try TestRepo.makeTempWorkspace(
            configJSON: VSCodeCustCmdSupport.configJSON(settings: true, extensions: true)
        )
        defer { try? FileManager.default.removeItem(at: ws) }
        let resolved = try ConfigResolver.resolve(workspacePath: ws.path, localEnv: [:])
        let entry = MockProcessRunner.containerListJSON(
            id: resolved.containerName,
            state: "running",
            labels: resolved.labels,
            image: "alpine:3.20"
        )
        let mock = MockProcessRunner()
        mock.handlers = [
            { args in
                if args.starts(with: ["list"]) {
                    let data = try! JSONSerialization.data(withJSONObject: [entry])
                    return ProcessResult(exitCode: 0, stdout: data, stderr: Data())
                }
                return nil
            }
        ]
        let guest = MockVSCodeGuest()
        let payload = VSCodeCustomizationsPayload.from(config: resolved.config)
        guest.files[VSCodeCustomizationsApply.markerPath(home: guest.home)] = payload.contentHash
        let dl = MockVSCodeDownloader()
        let restoreApply = VSCodeCustCmdSupport.installApply(guest: guest, downloader: dl)
        defer { restoreApply() }

        let runtime = AppleContainerRuntime(executablePath: "/usr/local/bin/container", runner: mock)
        let result = try UpCommand.run(
            options: UpOptions(workspacePath: ws.path, skipPull: true, openVSCode: false),
            runtime: runtime,
            localEnv: [:]
        )
        try MiniTest.expectEqual(result.outcome, "success")
        try MiniTest.expectEqual(dl.calls.count, 0)
        try MiniTest.expectEqual(guest.unpackCalls.count, 0)
        try MiniTest.expect(guest.files[VSCodeCustomizationsApply.settingsPath(home: guest.home)] == nil)
        try MiniTest.expectEqual(
            guest.files[VSCodeCustomizationsApply.markerPath(home: guest.home)]?
                .trimmingCharacters(in: .whitespacesAndNewlines),
            payload.contentHash
        )
    }),

    // MARK: Extensions wiring

    ("upExtensionsBeforeOpenBeforePostAttach", {
        let ws = try TestRepo.makeTempWorkspace(
            configJSON: VSCodeCustCmdSupport.configJSON(
                settings: true,
                extensions: true,
                postAttach: "echo postAttach-ran"
            )
        )
        defer { try? FileManager.default.removeItem(at: ws) }
        let resolved = try ConfigResolver.resolve(workspacePath: ws.path, localEnv: [:])
        var bodies: [String] = []
        var sequence: [String] = []
        let mock = MockProcessRunner()
        mock.handlers = [
            { args in
                if args.starts(with: ["list"]) {
                    let data = try! JSONSerialization.data(withJSONObject: [] as [Any])
                    return ProcessResult(exitCode: 0, stdout: data, stderr: Data())
                }
                if args.first == "create" {
                    return ProcessResult(
                        exitCode: 0,
                        stdout: Data("\(resolved.containerName)\n".utf8),
                        stderr: Data()
                    )
                }
                if args.first == "start" {
                    return ProcessResult(exitCode: 0, stdout: Data(), stderr: Data())
                }
                if args.first == "exec" {
                    if let lc = args.firstIndex(of: "-lc"), lc + 1 < args.count {
                        let body = args[lc + 1]
                        bodies.append(body)
                        if body.contains("echo postAttach-ran") {
                            sequence.append("postAttach")
                        }
                    }
                    return ProcessResult(exitCode: 0, stdout: Data(), stderr: Data())
                }
                return ProcessResult(exitCode: 0, stdout: Data(), stderr: Data())
            }
        ]
        let guest = MockVSCodeGuest()
        let dl = MockVSCodeDownloader()
        dl.onFetch = { sequence.append("extensions") }
        let restoreApply = VSCodeCustCmdSupport.installApply(guest: guest, downloader: dl)
        defer { restoreApply() }
        let launcher = MockVSCodeLauncher()
        launcher.onLaunch = { sequence.append("open") }
        let restoreOpen = VSCodeCustCmdSupport.installOpen(launcher: launcher)
        defer { restoreOpen() }

        let runtime = AppleContainerRuntime(executablePath: "/usr/local/bin/container", runner: mock)
        let result = try UpCommand.run(
            options: UpOptions(workspacePath: ws.path, skipPull: true, openVSCode: true),
            runtime: runtime,
            localEnv: [:]
        )
        try MiniTest.expectEqual(result.outcome, "success")
        try MiniTest.expectEqual(launcher.calls.count, 1)
        try MiniTest.expectEqual(dl.calls, ["pub.name"])
        try MiniTest.expectEqual(guest.unpackCalls.count, 1)
        try MiniTest.expect(bodies.contains("echo postAttach-ran"))
        try MiniTest.expectEqual(sequence, ["extensions", "open", "postAttach"])
        let marker = guest.files[VSCodeCustomizationsApply.markerPath(home: guest.home)]?
            .trimmingCharacters(in: .whitespacesAndNewlines)
        try MiniTest.expectEqual(marker, VSCodeCustomizationsPayload.from(config: resolved.config).contentHash)
    }),

    ("upExtensionsInstallWithoutVSCode", {
        let ws = try TestRepo.makeTempWorkspace(
            configJSON: VSCodeCustCmdSupport.configJSON(settings: false, extensions: true)
        )
        defer { try? FileManager.default.removeItem(at: ws) }
        let resolved = try ConfigResolver.resolve(workspacePath: ws.path, localEnv: [:])
        let mock = VSCodeCustCmdSupport.freshUpMock(resolved: resolved)
        let guest = MockVSCodeGuest()
        let dl = MockVSCodeDownloader()
        let restoreApply = VSCodeCustCmdSupport.installApply(guest: guest, downloader: dl)
        defer { restoreApply() }
        let launcher = MockVSCodeLauncher()
        let restoreOpen = VSCodeCustCmdSupport.installOpen(launcher: launcher)
        defer { restoreOpen() }

        let runtime = AppleContainerRuntime(executablePath: "/usr/local/bin/container", runner: mock)
        let result = try UpCommand.run(
            options: UpOptions(workspacePath: ws.path, skipPull: true, openVSCode: false),
            runtime: runtime,
            localEnv: [:]
        )
        try MiniTest.expectEqual(result.outcome, "success")
        try MiniTest.expectEqual(launcher.calls.count, 0)
        try MiniTest.expectEqual(dl.calls, ["pub.name"])
        try MiniTest.expectEqual(guest.unpackCalls.count, 1)
        try MiniTest.expect(VSCodeCustCmdSupport.registryLists(guest, id: "pub.name"))
        let marker = guest.files[VSCodeCustomizationsApply.markerPath(home: guest.home)]?
            .trimmingCharacters(in: .whitespacesAndNewlines)
        try MiniTest.expectEqual(marker, VSCodeCustomizationsPayload.from(config: resolved.config).contentHash)
        try MiniTest.expect(!VSCodeCustCmdSupport.shellBodies(from: mock).contains { $0.contains("postAttach") })
    }),

    ("upExtensionsApplyWhenOpenSoftFails", {
        let ws = try TestRepo.makeTempWorkspace(
            configJSON: VSCodeCustCmdSupport.configJSON(settings: false, extensions: true)
        )
        defer { try? FileManager.default.removeItem(at: ws) }
        let resolved = try ConfigResolver.resolve(workspacePath: ws.path, localEnv: [:])
        let mock = VSCodeCustCmdSupport.freshUpMock(resolved: resolved)
        let guest = MockVSCodeGuest()
        let dl = MockVSCodeDownloader()
        let restoreApply = VSCodeCustCmdSupport.installApply(guest: guest, downloader: dl)
        defer { restoreApply() }
        let launcher = MockVSCodeLauncher()
        let restoreOpen = VSCodeCustCmdSupport.installOpen(launcher: launcher, resolverPath: nil)
        defer { restoreOpen() }

        let runtime = AppleContainerRuntime(executablePath: "/usr/local/bin/container", runner: mock)
        let result = try UpCommand.run(
            options: UpOptions(workspacePath: ws.path, skipPull: true, openVSCode: true),
            runtime: runtime,
            localEnv: [:]
        )
        try MiniTest.expectEqual(result.outcome, "success")
        // Extensions apply is not gated on open success; open soft-fail must not block install.
        try MiniTest.expectEqual(dl.calls, ["pub.name"])
        try MiniTest.expectEqual(guest.unpackCalls.count, 1)
        let marker = guest.files[VSCodeCustomizationsApply.markerPath(home: guest.home)]?
            .trimmingCharacters(in: .whitespacesAndNewlines)
        try MiniTest.expectEqual(marker, VSCodeCustomizationsPayload.from(config: resolved.config).contentHash)
        try MiniTest.expectEqual(launcher.calls.count, 0)
    }),

    ("upExtensionsSoftFailKeepsSuccess", {
        let ws = try TestRepo.makeTempWorkspace(
            configJSON: VSCodeCustCmdSupport.configJSON(settings: false, extensions: true)
        )
        defer { try? FileManager.default.removeItem(at: ws) }
        let resolved = try ConfigResolver.resolve(workspacePath: ws.path, localEnv: [:])
        let mock = VSCodeCustCmdSupport.freshUpMock(resolved: resolved)
        let guest = MockVSCodeGuest()
        let dl = MockVSCodeDownloader()
        dl.failIDs = ["pub.name"]
        let restoreApply = VSCodeCustCmdSupport.installApply(guest: guest, downloader: dl)
        defer { restoreApply() }
        let launcher = MockVSCodeLauncher()
        let restoreOpen = VSCodeCustCmdSupport.installOpen(launcher: launcher)
        defer { restoreOpen() }

        let runtime = AppleContainerRuntime(executablePath: "/usr/local/bin/container", runner: mock)
        let result = try UpCommand.run(
            options: UpOptions(workspacePath: ws.path, skipPull: true, openVSCode: true),
            runtime: runtime,
            localEnv: [:]
        )
        try MiniTest.expectEqual(result.outcome, "success")
        try MiniTest.expect(!mock.calls.contains { $0.arguments.first == "delete" })
        try MiniTest.expect(
            guest.files[VSCodeCustomizationsApply.markerPath(home: guest.home)] == nil
        )
    }),

    ("upPostAttachFailKeepAfterExtensions", {
        let ws = try TestRepo.makeTempWorkspace(
            configJSON: VSCodeCustCmdSupport.configJSON(
                settings: false,
                extensions: true,
                postAttach: "exit 9"
            )
        )
        defer { try? FileManager.default.removeItem(at: ws) }
        let resolved = try ConfigResolver.resolve(workspacePath: ws.path, localEnv: [:])
        let mock = MockProcessRunner()
        mock.handlers = [
            { args in
                if args.starts(with: ["list"]) {
                    let data = try! JSONSerialization.data(withJSONObject: [] as [Any])
                    return ProcessResult(exitCode: 0, stdout: data, stderr: Data())
                }
                if args.first == "create" {
                    return ProcessResult(
                        exitCode: 0,
                        stdout: Data("\(resolved.containerName)\n".utf8),
                        stderr: Data()
                    )
                }
                if args.first == "start" {
                    return ProcessResult(exitCode: 0, stdout: Data(), stderr: Data())
                }
                if args.first == "exec" {
                    if let lc = args.firstIndex(of: "-lc"), lc + 1 < args.count,
                       args[lc + 1].contains("exit 9")
                    {
                        return ProcessResult(exitCode: 9, stdout: Data(), stderr: Data("pa".utf8))
                    }
                    return ProcessResult(exitCode: 0, stdout: Data(), stderr: Data())
                }
                if args.first == "delete" {
                    return ProcessResult(exitCode: 0, stdout: Data(), stderr: Data())
                }
                return ProcessResult(exitCode: 0, stdout: Data(), stderr: Data())
            }
        ]
        let guest = MockVSCodeGuest()
        let dl = MockVSCodeDownloader()
        let restoreApply = VSCodeCustCmdSupport.installApply(guest: guest, downloader: dl)
        defer { restoreApply() }
        let launcher = MockVSCodeLauncher()
        let restoreOpen = VSCodeCustCmdSupport.installOpen(launcher: launcher)
        defer { restoreOpen() }

        let runtime = AppleContainerRuntime(executablePath: "/usr/local/bin/container", runner: mock)
        try MiniTest.expectThrows({
            _ = try UpCommand.run(
                options: UpOptions(workspacePath: ws.path, skipPull: true, openVSCode: true),
                runtime: runtime,
                localEnv: [:]
            )
        }) { error in
            let err = error as! CLIError
            try MiniTest.expectEqual(err.property, "postAttachCommand")
        }
        // Extensions ran; container not deleted
        try MiniTest.expectEqual(dl.calls.count, 1)
        try MiniTest.expect(!mock.calls.contains { $0.arguments.first == "delete" })
    }),

    ("upMatchingMarkerSkipsExtensionsOnSubsequentOpen", {
        let ws = try TestRepo.makeTempWorkspace(
            configJSON: VSCodeCustCmdSupport.configJSON(settings: true, extensions: true)
        )
        defer { try? FileManager.default.removeItem(at: ws) }
        let resolved = try ConfigResolver.resolve(workspacePath: ws.path, localEnv: [:])
        let mock = VSCodeCustCmdSupport.freshUpMock(resolved: resolved)
        let guest = MockVSCodeGuest()
        let payload = VSCodeCustomizationsPayload.from(config: resolved.config)
        guest.files[VSCodeCustomizationsApply.markerPath(home: guest.home)] = payload.contentHash
        let dl = MockVSCodeDownloader()
        let restoreApply = VSCodeCustCmdSupport.installApply(guest: guest, downloader: dl)
        defer { restoreApply() }
        let launcher = MockVSCodeLauncher()
        let restoreOpen = VSCodeCustCmdSupport.installOpen(launcher: launcher)
        defer { restoreOpen() }

        let runtime = AppleContainerRuntime(executablePath: "/usr/local/bin/container", runner: mock)
        let result = try UpCommand.run(
            options: UpOptions(workspacePath: ws.path, skipPull: true, openVSCode: true),
            runtime: runtime,
            localEnv: [:]
        )
        try MiniTest.expectEqual(result.outcome, "success")
        try MiniTest.expectEqual(dl.calls.count, 0)
        try MiniTest.expectEqual(guest.unpackCalls.count, 0)
    }),

    ("startStoppedBindRunsPostStart", {
        let ws = try TestRepo.makeTempWorkspace(configJSON: """
        {
          "image": "alpine:3.20",
          "postStartCommand": "echo bind-postStart",
          "customizations": {
            "vscode": {
              "extensions": ["pub.name"],
              "settings": { "editor.tabSize": 2 }
            }
          }
        }
        """)
        defer { try? FileManager.default.removeItem(at: ws) }
        let resolved = try ConfigResolver.resolve(workspacePath: ws.path, localEnv: [:])
        let mock = VSCodeCustCmdSupport.startRuntimeMock(resolved: resolved, state: "stopped")
        let guest = MockVSCodeGuest()
        guest.files[VSCodeCustomizationsApply.markerPath(home: guest.home)] = "stale"
        let dl = MockVSCodeDownloader()
        let restoreApply = VSCodeCustCmdSupport.installApply(guest: guest, downloader: dl)
        defer { restoreApply() }
        let launcher = MockVSCodeLauncher()
        let restoreOpen = VSCodeCustCmdSupport.installOpen(launcher: launcher)
        defer { restoreOpen() }

        let runtime = AppleContainerRuntime(executablePath: "/usr/local/bin/container", runner: mock)
        try StartCommand.run(
            options: StartOptions(name: resolved.containerName, openVSCode: false),
            runtime: runtime
        )
        try MiniTest.expect(mock.calls.contains { $0.arguments.first == "start" })
        try MiniTest.expect(VSCodeCustCmdSupport.shellBodies(from: mock).contains("echo bind-postStart"))
        try MiniTest.expectEqual(dl.calls.count, 0)
        try MiniTest.expectEqual(guest.unpackCalls.count, 0)
        try MiniTest.expect(guest.files[VSCodeCustomizationsApply.settingsPath(home: guest.home)] == nil)
        try MiniTest.expectEqual(
            guest.files[VSCodeCustomizationsApply.markerPath(home: guest.home)]?
                .trimmingCharacters(in: .whitespacesAndNewlines),
            "stale"
        )
    }),

    ("startAlreadyRunningDoesNotRunPostStart", {
        let ws = try TestRepo.makeTempWorkspace(configJSON: """
        {
          "image": "alpine:3.20",
          "postStartCommand": "echo already-running-postStart",
          "customizations": {
            "vscode": {
              "extensions": ["pub.name"],
              "settings": { "editor.tabSize": 2 }
            }
          }
        }
        """)
        defer { try? FileManager.default.removeItem(at: ws) }
        let resolved = try ConfigResolver.resolve(workspacePath: ws.path, localEnv: [:])
        let mock = VSCodeCustCmdSupport.startRuntimeMock(resolved: resolved, state: "running")
        let guest = MockVSCodeGuest()
        guest.files[VSCodeCustomizationsApply.markerPath(home: guest.home)] = "stale"
        let dl = MockVSCodeDownloader()
        let restoreApply = VSCodeCustCmdSupport.installApply(guest: guest, downloader: dl)
        defer { restoreApply() }

        let runtime = AppleContainerRuntime(executablePath: "/usr/local/bin/container", runner: mock)
        try StartCommand.run(
            options: StartOptions(name: resolved.containerName, openVSCode: false),
            runtime: runtime
        )
        try MiniTest.expect(!mock.calls.contains { $0.arguments.first == "start" })
        try MiniTest.expect(
            !VSCodeCustCmdSupport.shellBodies(from: mock).contains("echo already-running-postStart")
        )
        try MiniTest.expectEqual(dl.calls.count, 0)
        try MiniTest.expect(guest.files[VSCodeCustomizationsApply.settingsPath(home: guest.home)] == nil)
    }),

    ("startRestartPostStartFailureDoesNotDelete", {
        let ws = try TestRepo.makeTempWorkspace(configJSON: """
        {
          "image": "alpine:3.20",
          "postStartCommand": "exit 5",
          "customizations": {
            "vscode": {
              "extensions": ["pub.name"],
              "settings": { "editor.tabSize": 2 }
            }
          }
        }
        """)
        defer { try? FileManager.default.removeItem(at: ws) }
        let resolved = try ConfigResolver.resolve(workspacePath: ws.path, localEnv: [:])
        var labels = resolved.labels
        labels[ContainerIdentity.labelManaged] = ContainerIdentity.managedValue
        labels[ContainerIdentity.labelWorkspaceFolder] = resolved.config.workspaceFolder
        labels[ContainerIdentity.labelLocalFolder] = resolved.workspacePath
        labels[ContainerIdentity.labelConfigFile] = resolved.configPath
        let entry = MockProcessRunner.containerListJSON(
            id: resolved.containerName,
            state: "stopped",
            labels: labels,
            image: "alpine:3.20"
        )
        let mock = MockProcessRunner()
        mock.handlers = [
            { args in
                if args.starts(with: ["list"]) {
                    let data = try! JSONSerialization.data(withJSONObject: [entry])
                    return ProcessResult(exitCode: 0, stdout: data, stderr: Data())
                }
                if args.first == "start" {
                    return ProcessResult(exitCode: 0, stdout: Data(), stderr: Data())
                }
                if args.first == "inspect" {
                    let data = try! JSONSerialization.data(withJSONObject: entry)
                    return ProcessResult(exitCode: 0, stdout: data, stderr: Data())
                }
                if args.first == "exec" {
                    if args.contains(LifecycleRunner.userEnvProbeScript) {
                        return ProcessResult(exitCode: 0, stdout: Data(), stderr: Data())
                    }
                    return ProcessResult(exitCode: 5, stdout: Data(), stderr: Data("fail\n".utf8))
                }
                if args.first == "delete" {
                    return ProcessResult(exitCode: 0, stdout: Data(), stderr: Data())
                }
                return ProcessResult(exitCode: 0, stdout: Data(), stderr: Data())
            }
        ]
        let guest = MockVSCodeGuest()
        guest.files[VSCodeCustomizationsApply.markerPath(home: guest.home)] = "stale"
        let dl = MockVSCodeDownloader()
        let restoreApply = VSCodeCustCmdSupport.installApply(guest: guest, downloader: dl)
        defer { restoreApply() }
        let runtime = AppleContainerRuntime(executablePath: "/usr/local/bin/container", runner: mock)
        try MiniTest.expectThrows({
            try StartCommand.run(
                options: StartOptions(name: resolved.containerName),
                runtime: runtime
            )
        }) { error in
            let err = error as! CLIError
            try MiniTest.expectEqual(err.code, CLIErrorCode.lifecycleFailed)
            try MiniTest.expectEqual(err.property, "postStartCommand")
        }
        try MiniTest.expect(mock.calls.contains { $0.arguments.first == "start" })
        try MiniTest.expect(!mock.calls.contains { $0.arguments.first == "delete" })
        try MiniTest.expectEqual(dl.calls.count, 0)
        try MiniTest.expect(guest.files[VSCodeCustomizationsApply.settingsPath(home: guest.home)] == nil)
    }),

    ("startWithVSCodeOpensWithoutApplyingCustomizations", {
        let ws = try TestRepo.makeTempWorkspace(
            configJSON: VSCodeCustCmdSupport.configJSON(
                settings: true,
                extensions: true,
                postAttach: "echo postAttach-ran"
            )
        )
        defer { try? FileManager.default.removeItem(at: ws) }
        let resolved = try ConfigResolver.resolve(workspacePath: ws.path, localEnv: [:])
        let mock = VSCodeCustCmdSupport.startRuntimeMock(resolved: resolved, state: "stopped")
        let guest = MockVSCodeGuest()
        guest.files[VSCodeCustomizationsApply.markerPath(home: guest.home)] = "stale"
        let dl = MockVSCodeDownloader()
        let restoreApply = VSCodeCustCmdSupport.installApply(guest: guest, downloader: dl)
        defer { restoreApply() }
        let launcher = MockVSCodeLauncher()
        let restoreOpen = VSCodeCustCmdSupport.installOpen(launcher: launcher)
        defer { restoreOpen() }

        let runtime = AppleContainerRuntime(executablePath: "/usr/local/bin/container", runner: mock)
        try StartCommand.run(
            options: StartOptions(name: resolved.containerName, openVSCode: true),
            runtime: runtime
        )
        try MiniTest.expectEqual(launcher.calls.count, 1)
        try MiniTest.expect(VSCodeCustCmdSupport.shellBodies(from: mock).contains("echo postAttach-ran"))
        try MiniTest.expectEqual(dl.calls.count, 0)
        try MiniTest.expectEqual(guest.unpackCalls.count, 0)
        try MiniTest.expect(guest.files[VSCodeCustomizationsApply.settingsPath(home: guest.home)] == nil)
        try MiniTest.expectEqual(
            guest.files[VSCodeCustomizationsApply.markerPath(home: guest.home)]?
                .trimmingCharacters(in: .whitespacesAndNewlines),
            "stale"
        )
    }),

    ("startWithoutVSCodeDoesNotInstallExtensions", {
        let ws = try TestRepo.makeTempWorkspace(
            configJSON: VSCodeCustCmdSupport.configJSON(settings: true, extensions: true)
        )
        defer { try? FileManager.default.removeItem(at: ws) }
        let resolved = try ConfigResolver.resolve(workspacePath: ws.path, localEnv: [:])
        let mock = VSCodeCustCmdSupport.startRuntimeMock(resolved: resolved, state: "running")
        let guest = MockVSCodeGuest()
        guest.files[VSCodeCustomizationsApply.markerPath(home: guest.home)] = "stale"
        let dl = MockVSCodeDownloader()
        let restoreApply = VSCodeCustCmdSupport.installApply(guest: guest, downloader: dl)
        defer { restoreApply() }
        let launcher = MockVSCodeLauncher()
        let restoreOpen = VSCodeCustCmdSupport.installOpen(launcher: launcher)
        defer { restoreOpen() }

        let runtime = AppleContainerRuntime(executablePath: "/usr/local/bin/container", runner: mock)
        try StartCommand.run(
            options: StartOptions(name: resolved.containerName, openVSCode: false),
            runtime: runtime
        )
        try MiniTest.expectEqual(launcher.calls.count, 0)
        try MiniTest.expectEqual(dl.calls.count, 0)
        try MiniTest.expectEqual(guest.unpackCalls.count, 0)
        try MiniTest.expect(guest.files[VSCodeCustomizationsApply.settingsPath(home: guest.home)] == nil)
        try MiniTest.expectEqual(
            guest.files[VSCodeCustomizationsApply.markerPath(home: guest.home)]?
                .trimmingCharacters(in: .whitespacesAndNewlines),
            "stale"
        )
        try MiniTest.expect(!VSCodeCustCmdSupport.shellBodies(from: mock).contains { $0.contains("postStart") })
        try MiniTest.expect(!VSCodeCustCmdSupport.shellBodies(from: mock).contains { $0.contains("postAttach") })
    }),

    ("startPostAttachRunsWithoutVSCode", {
        let ws = try TestRepo.makeTempWorkspace(
            configJSON: VSCodeCustCmdSupport.configJSON(
                settings: true,
                extensions: true,
                postAttach: "echo start-attach"
            )
        )
        defer { try? FileManager.default.removeItem(at: ws) }
        let resolved = try ConfigResolver.resolve(workspacePath: ws.path, localEnv: [:])
        let mock = VSCodeCustCmdSupport.startRuntimeMock(resolved: resolved, state: "stopped")
        let guest = MockVSCodeGuest()
        guest.files[VSCodeCustomizationsApply.markerPath(home: guest.home)] = "stale"
        let dl = MockVSCodeDownloader()
        let restoreApply = VSCodeCustCmdSupport.installApply(guest: guest, downloader: dl)
        defer { restoreApply() }
        let launcher = MockVSCodeLauncher()
        let restoreOpen = VSCodeCustCmdSupport.installOpen(launcher: launcher)
        defer { restoreOpen() }

        let runtime = AppleContainerRuntime(executablePath: "/usr/local/bin/container", runner: mock)
        try StartCommand.run(
            options: StartOptions(name: resolved.containerName, openVSCode: false),
            runtime: runtime
        )
        try MiniTest.expectEqual(launcher.calls.count, 0)
        try MiniTest.expect(VSCodeCustCmdSupport.shellBodies(from: mock).contains("echo start-attach"))
        try MiniTest.expectEqual(dl.calls.count, 0)
        try MiniTest.expectEqual(guest.unpackCalls.count, 0)
        try MiniTest.expect(guest.files[VSCodeCustomizationsApply.settingsPath(home: guest.home)] == nil)
        try MiniTest.expectEqual(
            guest.files[VSCodeCustomizationsApply.markerPath(home: guest.home)]?
                .trimmingCharacters(in: .whitespacesAndNewlines),
            "stale"
        )
    }),

    ("cloneWithVSCodeAppliesExtensions", {
        let restoreFeatures = CloneGitFeatureTestSupport.installOverrides()
        defer { restoreFeatures() }
        let git = MockGitClient()
        git.configJSONToWrite = VSCodeCustCmdSupport.configJSON(settings: true, extensions: true)
        let mock = MockProcessRunner()
        mock.handlers = CloneRuntimeMock.handlers()
        let guest = MockVSCodeGuest()
        let dl = MockVSCodeDownloader()
        let restoreApply = VSCodeCustCmdSupport.installApply(guest: guest, downloader: dl)
        defer { restoreApply() }
        let launcher = MockVSCodeLauncher()
        let restoreOpen = VSCodeCustCmdSupport.installOpen(launcher: launcher)
        defer { restoreOpen() }

        let runtime = AppleContainerRuntime(executablePath: "/usr/local/bin/container", runner: mock)
        let result = try CloneCommand.run(
            options: CloneOptions(
                gitURL: "https://github.com/org/clone-vsc-ext.git",
                skipPull: true,
                openVSCode: true
            ),
            runtime: runtime,
            git: git,
            credentials: MockGitCredential(),
            localEnv: [:]
        )
        try MiniTest.expectEqual(result.outcome, "success")
        try MiniTest.expectEqual(dl.calls, ["pub.name"])
        try MiniTest.expect(
            guest.files[VSCodeCustomizationsApply.settingsPath(home: guest.home)] != nil
        )
    }),

    ("cloneWithoutVSCodeAppliesExtensions", {
        let restoreFeatures = CloneGitFeatureTestSupport.installOverrides()
        defer { restoreFeatures() }
        let git = MockGitClient()
        git.configJSONToWrite = VSCodeCustCmdSupport.configJSON(settings: true, extensions: true)
        let mock = MockProcessRunner()
        mock.handlers = CloneRuntimeMock.handlers()
        let guest = MockVSCodeGuest()
        let dl = MockVSCodeDownloader()
        let restoreApply = VSCodeCustCmdSupport.installApply(guest: guest, downloader: dl)
        defer { restoreApply() }
        let launcher = MockVSCodeLauncher()
        let restoreOpen = VSCodeCustCmdSupport.installOpen(launcher: launcher)
        defer { restoreOpen() }

        let runtime = AppleContainerRuntime(executablePath: "/usr/local/bin/container", runner: mock)
        let result = try CloneCommand.run(
            options: CloneOptions(
                gitURL: "https://github.com/org/clone-vsc-ext-no-flag.git",
                skipPull: true,
                openVSCode: false
            ),
            runtime: runtime,
            git: git,
            credentials: MockGitCredential(),
            localEnv: [:]
        )
        try MiniTest.expectEqual(result.outcome, "success")
        try MiniTest.expectEqual(launcher.calls.count, 0)
        try MiniTest.expectEqual(dl.calls, ["pub.name"])
        try MiniTest.expectEqual(guest.unpackCalls.count, 1)
        try MiniTest.expect(VSCodeCustCmdSupport.registryLists(guest, id: "pub.name"))
        try MiniTest.expect(
            guest.files[VSCodeCustomizationsApply.settingsPath(home: guest.home)] != nil
        )
        let marker = guest.files[VSCodeCustomizationsApply.markerPath(home: guest.home)]?
            .trimmingCharacters(in: .whitespacesAndNewlines)
        try MiniTest.expect(marker != nil && !(marker ?? "").isEmpty)
        try MiniTest.expect(!VSCodeCustCmdSupport.shellBodies(from: mock).contains { $0.contains("postAttach") })
    }),

    ("usageAndCommandHelpDoNotGateApplyOnVSCode", {
        let usage = CommandSurface.usageText()
        let up = CommandSurface.commandHelpText("up") ?? ""
        let clone = CommandSurface.commandHelpText("clone") ?? ""
        let start = CommandSurface.commandHelpText("start") ?? ""
        let rebuild = CommandSurface.commandHelpText("rebuild") ?? ""

        for (label, text) in [
            ("usage", usage),
            ("up help", up),
            ("clone help", clone),
            ("start help", start),
            ("rebuild help", rebuild)
        ] {
            try MiniTest.expect(
                !text.contains("installed when --vscode is set"),
                "\(label) must not gate extensions on --vscode"
            )
            try MiniTest.expect(
                !text.contains("applies extensions + gates postAttach"),
                "\(label) must not claim --vscode applies extensions"
            )
            try MiniTest.expect(
                !text.contains("Extensions gate is the flag only"),
                "\(label) must not say the extensions gate is the flag"
            )
            try MiniTest.expect(
                !text.contains("Extensions run when the flag is set"),
                "\(label) must not say extensions run only when the flag is set"
            )
            try MiniTest.expect(
                !text.contains("pending extensions when the flag is set"),
                "\(label) must not say start applies pending extensions"
            )
            try MiniTest.expect(
                !text.contains("Settings repair on marker drift does not require the flag"),
                "\(label) must not say start repairs settings"
            )
        }

        try MiniTest.expect(
            usage.contains("apply by default on up") || usage.contains("apply by default on `up`"),
            "usage states apply-by-default on up/clone/rebuild"
        )
        try MiniTest.expect(
            usage.lowercased().contains("start does not apply")
                || usage.contains("start never applies"),
            "usage states start does not apply customizations"
        )
        try MiniTest.expect(
            up.contains("apply by default") || up.contains("apply on create-path"),
            "up help states apply is default"
        )
        try MiniTest.expect(
            up.contains("open") && up.contains("postAttach") && !up.contains("Extensions run when the flag is set"),
            "up help keeps --vscode as open + postAttach"
        )
        try MiniTest.expect(
            clone.contains("apply by default") || clone.contains("apply after create-path"),
            "clone help states apply is default"
        )
        try MiniTest.expect(
            start.contains("does not apply settings or extensions"),
            "start help MUST say start does not apply settings or extensions"
        )
        try MiniTest.expect(
            rebuild.contains("apply by default") || rebuild.contains("apply on the new"),
            "rebuild help states apply is default"
        )

        for (label, text) in [
            ("usage", usage),
            ("up help", up),
            ("clone help", clone),
            ("start help", start),
            ("rebuild help", rebuild)
        ] {
            try MiniTest.expect(
                !text.contains("does not run postStart"),
                "\(label) must not say start skips postStart"
            )
            try MiniTest.expect(
                !text.contains("gates postAttach"),
                "\(label) must not say --vscode gates postAttach"
            )
            try MiniTest.expect(
                !text.contains("postAttach only after successful open"),
                "\(label) must not say postAttach runs only after successful open"
            )
            try MiniTest.expect(
                !text.contains("postAttachCommand runs only after successful open"),
                "\(label) must not say postAttachCommand is open-gated"
            )
            try MiniTest.expect(
                !text.contains("skipped without flag or on open"),
                "\(label) must not say postAttach is skipped without --vscode"
            )
        }
    }),

    ("postAttachConfigLoaderRetainsVscodeFields", {
        let ws = try TestRepo.makeTempWorkspace(
            configJSON: VSCodeCustCmdSupport.configJSON(settings: true, extensions: true)
        )
        defer { try? FileManager.default.removeItem(at: ws) }
        let resolved = try ConfigResolver.resolve(workspacePath: ws.path, localEnv: [:])
        let mock = MockProcessRunner()
        let runtime = AppleContainerRuntime(executablePath: "/usr/local/bin/container", runner: mock)
        let loaded = try PostAttachConfigLoader.load(
            labels: resolved.labels,
            containerId: "ctr",
            imageRef: nil,
            runtime: runtime,
            localEnv: [:]
        )
        try MiniTest.expect(loaded != nil)
        try MiniTest.expectEqual(loaded!.vscodeExtensions, ["pub.name"])
        try MiniTest.expect(
            ResolvedDevContainerConfig.settingsObjectHasKeys(loaded!.vscodeSettingsJSON)
        )
    })
]
