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
        try MiniTest.expectEqual(dl.calls.count, 0)
        let settingsPath = VSCodeCustomizationsApply.settingsPath(home: guest.home)
        try MiniTest.expect(guest.files[settingsPath] != nil)
        let obj = try JSONSerialization.jsonObject(with: Data(guest.files[settingsPath]!.utf8)) as! [String: Any]
        try MiniTest.expectEqual(obj["editor.tabSize"] as? Int, 2)
        // Extensions pending → no full marker
        let markerPath = VSCodeCustomizationsApply.markerPath(home: guest.home)
        try MiniTest.expect(guest.files[markerPath] == nil)
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
            configJSON: VSCodeCustCmdSupport.configJSON(settings: true, extensions: false)
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
        let restoreApply = VSCodeCustCmdSupport.installApply(guest: guest)
        defer { restoreApply() }

        let runtime = AppleContainerRuntime(executablePath: "/usr/local/bin/container", runner: mock)
        let result = try UpCommand.run(
            options: UpOptions(workspacePath: ws.path, skipPull: true, openVSCode: false),
            runtime: runtime,
            localEnv: [:]
        )
        try MiniTest.expectEqual(result.outcome, "success")
        let settingsPath = VSCodeCustomizationsApply.settingsPath(home: guest.home)
        try MiniTest.expect(guest.files[settingsPath] != nil)
        let newHash = VSCodeCustomizationsPayload.from(config: resolved.config).contentHash
        try MiniTest.expectEqual(
            guest.files[VSCodeCustomizationsApply.markerPath(home: guest.home)]?
                .trimmingCharacters(in: .whitespacesAndNewlines),
            newHash
        )
    }),

    // MARK: Extensions wiring

    ("upExtensionsAfterOpenBeforePostAttach", {
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
                        bodies.append(args[lc + 1])
                    }
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

        // Track order: open call vs unpack vs postAttach body
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
        let marker = guest.files[VSCodeCustomizationsApply.markerPath(home: guest.home)]?
            .trimmingCharacters(in: .whitespacesAndNewlines)
        try MiniTest.expectEqual(marker, VSCodeCustomizationsPayload.from(config: resolved.config).contentHash)
    }),

    ("upExtensionsSkippedWithoutVSCode", {
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
        try MiniTest.expectEqual(dl.calls.count, 0)
        try MiniTest.expectEqual(guest.unpackCalls.count, 0)
    }),

    ("upExtensionsSkippedWhenOpenSoftFails", {
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
        try MiniTest.expectEqual(dl.calls.count, 0)
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

    ("startWithVSCodeAppliesPendingExtensions", {
        let ws = try TestRepo.makeTempWorkspace(
            configJSON: VSCodeCustCmdSupport.configJSON(settings: true, extensions: true)
        )
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
        try StartCommand.run(
            options: StartOptions(name: resolved.containerName, openVSCode: true),
            runtime: runtime
        )
        try MiniTest.expectEqual(dl.calls, ["pub.name"])
        try MiniTest.expectEqual(guest.unpackCalls.count, 1)
        // Settings repair also attempted
        try MiniTest.expect(
            guest.files[VSCodeCustomizationsApply.settingsPath(home: guest.home)] != nil
        )
    }),

    ("startWithoutVSCodeDoesNotInstallExtensions", {
        let ws = try TestRepo.makeTempWorkspace(
            configJSON: VSCodeCustCmdSupport.configJSON(settings: false, extensions: true)
        )
        defer { try? FileManager.default.removeItem(at: ws) }
        let resolved = try ConfigResolver.resolve(workspacePath: ws.path, localEnv: [:])
        var labels = resolved.labels
        labels[ContainerIdentity.labelManaged] = ContainerIdentity.managedValue
        labels[ContainerIdentity.labelLocalFolder] = resolved.workspacePath
        labels[ContainerIdentity.labelConfigFile] = resolved.configPath
        let entry = MockProcessRunner.containerListJSON(
            id: resolved.containerName,
            state: "running",
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
                if args.first == "inspect" {
                    let data = try! JSONSerialization.data(withJSONObject: entry)
                    return ProcessResult(exitCode: 0, stdout: data, stderr: Data())
                }
                return nil
            }
        ]
        let guest = MockVSCodeGuest()
        let dl = MockVSCodeDownloader()
        let restoreApply = VSCodeCustCmdSupport.installApply(guest: guest, downloader: dl)
        defer { restoreApply() }

        let runtime = AppleContainerRuntime(executablePath: "/usr/local/bin/container", runner: mock)
        try StartCommand.run(
            options: StartOptions(name: resolved.containerName, openVSCode: false),
            runtime: runtime
        )
        try MiniTest.expectEqual(dl.calls.count, 0)
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
