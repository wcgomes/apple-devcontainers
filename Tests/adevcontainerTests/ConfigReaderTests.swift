import Foundation
@testable import ADevContainerLib

// MARK: - Shared helpers

private func mockRuntime(_ mock: MockProcessRunner) -> AppleContainerRuntime {
    AppleContainerRuntime(executablePath: "container", runner: mock, interactiveRunner: mock)
}

private func bindLabels(localFolder: String, configFile: String) -> [String: String] {
    [
        ContainerIdentity.labelWorkspaceMode: ContainerIdentity.workspaceModeBind,
        ContainerIdentity.labelLocalFolder: localFolder,
        ContainerIdentity.labelConfigFile: configFile
    ]
}

private func volumeLabels(
    configFile: String,
    workspaceFolder: String? = nil,
    remoteUser: String = ""
) -> [String: String] {
    var labels: [String: String] = [
        ContainerIdentity.labelWorkspaceMode: ContainerIdentity.workspaceModeVolume,
        ContainerIdentity.labelConfigFile: configFile
    ]
    if let workspaceFolder {
        labels[ContainerIdentity.labelWorkspaceFolder] = workspaceFolder
    }
    labels[ContainerIdentity.labelRemoteUser] = remoteUser
    return labels
}

private func errorCode(_ error: Error) -> String? {
    (error as? CLIError)?.code
}

/// Recorded `exec` argument list for the cat of the config (or nil when absent).
private func catArgs(in mock: MockProcessRunner) -> [String]? {
    for call in mock.calls where call.arguments.first == "exec" {
        if call.arguments.dropFirst(2).first == "cat" {
            return call.arguments
        }
    }
    return nil
}

// MARK: - Suite

nonisolated(unsafe) let configReaderTests: [(String, () throws -> Void)] = [
    // ---- 1.1 strict bind-mode ----

    ("strictBindResolvesFromLabels", {
        let ws = try TestRepo.makeTempWorkspace(configJSON: #"{"image":"alpine:3.20"}"#)
        let configFile = ws.appendingPathComponent(".devcontainer/devcontainer.json").path
        let mock = MockProcessRunner()
        let config = try ConfigReader.read(
            labels: bindLabels(localFolder: ws.path, configFile: configFile),
            containerId: "c1",
            runtime: mockRuntime(mock),
            mode: .strict
        )
        try MiniTest.expect(config != nil, "strict bind read should resolve")
        try MiniTest.expectEqual(config?.image, "alpine:3.20")
        try MiniTest.expectEqual(config?.workspaceFolder, "/workspaces/\(ws.lastPathComponent)")
    }),

    ("strictBindMissingLocalFolderIsConfigNotFound", {
        let ws = try TestRepo.makeTempWorkspace(configJSON: #"{"image":"alpine:3.20"}"#)
        let configFile = ws.appendingPathComponent(".devcontainer/devcontainer.json").path
        var labels = bindLabels(localFolder: ws.path, configFile: configFile)
        labels.removeValue(forKey: ContainerIdentity.labelLocalFolder)
        try MiniTest.expectThrows({
            _ = try ConfigReader.read(labels: labels, containerId: "c1", runtime: mockRuntime(MockProcessRunner()), mode: .strict)
        }, validate: { err in
            try MiniTest.expectEqual(errorCode(err), CLIErrorCode.configNotFound, "missing local_folder label")
        })
        // Empty (whitespace-only) value is the same miss.
        var empty = labels
        empty[ContainerIdentity.labelLocalFolder] = "   "
        try MiniTest.expectThrows({
            _ = try ConfigReader.read(labels: empty, containerId: "c1", runtime: mockRuntime(MockProcessRunner()), mode: .strict)
        }, validate: { err in
            try MiniTest.expectEqual(errorCode(err), CLIErrorCode.configNotFound, "empty local_folder label")
        })
    }),

    ("strictBindMissingConfigFileLabelIsConfigNotFound", {
        let ws = try TestRepo.makeTempWorkspace(configJSON: #"{"image":"alpine:3.20"}"#)
        var labels = bindLabels(localFolder: ws.path, configFile: ws.appendingPathComponent(".devcontainer/devcontainer.json").path)
        labels.removeValue(forKey: ContainerIdentity.labelConfigFile)
        try MiniTest.expectThrows({
            _ = try ConfigReader.read(labels: labels, containerId: "c1", runtime: mockRuntime(MockProcessRunner()), mode: .strict)
        }, validate: { err in
            try MiniTest.expectEqual(errorCode(err), CLIErrorCode.configNotFound, "missing config_file label")
        })
    }),

    ("strictBindMissingHostFileIsConfigNotFound", {
        let ws = try TestRepo.makeTempWorkspace(configJSON: #"{"image":"alpine:3.20"}"#)
        let missing = ws.appendingPathComponent(".devcontainer/does-not-exist.json").path
        try MiniTest.expectThrows({
            _ = try ConfigReader.read(
                labels: bindLabels(localFolder: ws.path, configFile: missing),
                containerId: "c1",
                runtime: mockRuntime(MockProcessRunner()),
                mode: .strict
            )
        }, validate: { err in
            try MiniTest.expectEqual(errorCode(err), CLIErrorCode.configNotFound, "missing host file")
            try MiniTest.expect((err as? CLIError)?.message.contains(missing) == true, "error names the missing path")
        })
    }),

    ("strictBindUnparseableConfigIsConfigParse", {
        let ws = try TestRepo.makeTempWorkspace(configJSON: #"{"image":"alpine:3.20"}"#, prefix: "adev-bad-json")
        let configFile = ws.appendingPathComponent(".devcontainer/devcontainer.json").path
        try Data(#"{ not valid json"#.utf8).write(to: URL(fileURLWithPath: configFile))
        try MiniTest.expectThrows({
            _ = try ConfigReader.read(
                labels: bindLabels(localFolder: ws.path, configFile: configFile),
                containerId: "c1",
                runtime: mockRuntime(MockProcessRunner()),
                mode: .strict
            )
        }, validate: { err in
            try MiniTest.expectEqual(errorCode(err), CLIErrorCode.configParse, "unparseable config")
        })
    }),

    ("strictBindAdmissionFailurePassesThroughItsCode", {
        // Forever-rejected runArgs are admission failures: passthrough code, never config_not_found.
        let ws = try TestRepo.makeTempWorkspace(configJSON: #"{"image":"alpine:3.20","runArgs":["--privileged"]}"#)
        let configFile = ws.appendingPathComponent(".devcontainer/devcontainer.json").path
        try MiniTest.expectThrows({
            _ = try ConfigReader.read(
                labels: bindLabels(localFolder: ws.path, configFile: configFile),
                containerId: "c1",
                runtime: mockRuntime(MockProcessRunner()),
                mode: .strict
            )
        }, validate: { err in
            try MiniTest.expectEqual(errorCode(err), CLIErrorCode.unsupportedProperty, "admission passthrough")
        })
    }),

    // ---- 1.2 strict volume-mode ----

    ("strictVolumeCatSuccessResolvesFromStampedFolder", {
        let configText = #"{"image":"alpine:3.20"}"#
        let mock = MockProcessRunner()
        mock.handlers.append { args in
            if args.first == "exec", args.dropFirst(2).first == "cat" {
                return ProcessResult(exitCode: 0, stdout: Data(configText.utf8), stderr: Data())
            }
            return nil
        }
        let config = try ConfigReader.read(
            labels: volumeLabels(configFile: ".devcontainer/devcontainer.json", workspaceFolder: "/workspaces/edge"),
            containerId: "c1",
            runtime: mockRuntime(mock),
            mode: .strict
        )
        try MiniTest.expect(config != nil, "strict volume read should resolve")
        try MiniTest.expectEqual(config?.image, "alpine:3.20")
        try MiniTest.expectEqual(config?.workspaceFolder, "/workspaces/edge")
        let cat = catArgs(in: mock)
        try MiniTest.expect(cat != nil, "exec cat must be invoked")
        try MiniTest.expectEqual(cat![3], "/workspaces/edge/.devcontainer/devcontainer.json", "cat path from stamped folder")
    }),

    ("strictVolumeAbsoluteConfigPathUsedVerbatim", {
        let configText = #"{"image":"alpine:3.20"}"#
        let mock = MockProcessRunner()
        mock.handlers.append { args in
            if args.first == "exec", args.dropFirst(2).first == "cat" {
                return ProcessResult(exitCode: 0, stdout: Data(configText.utf8), stderr: Data())
            }
            return nil
        }
        _ = try ConfigReader.read(
            labels: volumeLabels(configFile: "/cfg/devcontainer.json", workspaceFolder: "/workspaces/edge"),
            containerId: "c1",
            runtime: mockRuntime(mock),
            mode: .strict
        )
        let cat = catArgs(in: mock)
        try MiniTest.expect(cat != nil, "exec cat must be invoked")
        try MiniTest.expectEqual(cat![3], "/cfg/devcontainer.json", "absolute path used verbatim")
    }),

    ("strictVolumeFallbackWorkspaceFolderMatchesLoader", {
        // No stamped workspace_folder → today's loader falls back to /workspaces
        // (basename "workspaces" → default folder /workspaces/workspaces). Lock parity.
        let configText = #"{"image":"alpine:3.20"}"#
        let mock = MockProcessRunner()
        mock.handlers.append { args in
            if args.first == "exec", args.dropFirst(2).first == "cat" {
                return ProcessResult(exitCode: 0, stdout: Data(configText.utf8), stderr: Data())
            }
            return nil
        }
        let config = try ConfigReader.read(
            labels: volumeLabels(configFile: ".devcontainer/devcontainer.json"),
            containerId: "c1",
            runtime: mockRuntime(mock),
            mode: .strict
        )
        try MiniTest.expect(config != nil, "fallback volume read should resolve")
        try MiniTest.expectEqual(config?.workspaceFolder, "/workspaces/workspaces", "loader fallback parity")
        let cat = catArgs(in: mock)
        try MiniTest.expect(cat != nil, "exec cat must be invoked")
        try MiniTest.expectEqual(cat![3], "/workspaces/.devcontainer/devcontainer.json", "fallback cat path")
    }),

    ("strictVolumeCatFailureIsConfigNotFound", {
        let mock = MockProcessRunner()
        mock.handlers.append { args in
            if args.first == "exec", args.dropFirst(2).first == "cat" {
                return ProcessResult(exitCode: 1, stdout: Data(), stderr: Data("cat: no such file".utf8))
            }
            return nil
        }
        try MiniTest.expectThrows({
            _ = try ConfigReader.read(
                labels: volumeLabels(configFile: ".devcontainer/devcontainer.json", workspaceFolder: "/workspaces/edge"),
                containerId: "c1",
                runtime: mockRuntime(mock),
                mode: .strict
            )
        }, validate: { err in
            try MiniTest.expectEqual(errorCode(err), CLIErrorCode.configNotFound, "cat failure")
        })
    }),

    ("strictVolumeEmptyConfigTextIsConfigNotFound", {
        // Default mock result: exit 0 with empty stdout → whitespace-only text.
        try MiniTest.expectThrows({
            _ = try ConfigReader.read(
                labels: volumeLabels(configFile: "devcontainer.json", workspaceFolder: "/workspaces/edge"),
                containerId: "c1",
                runtime: mockRuntime(MockProcessRunner()),
                mode: .strict
            )
        }, validate: { err in
            try MiniTest.expectEqual(errorCode(err), CLIErrorCode.configNotFound, "empty config text")
        })
    }),

    ("strictVolumeUnparseableConfigIsConfigParse", {
        let mock = MockProcessRunner()
        mock.handlers.append { args in
            if args.first == "exec", args.dropFirst(2).first == "cat" {
                return ProcessResult(exitCode: 0, stdout: Data("{ nope".utf8), stderr: Data())
            }
            return nil
        }
        try MiniTest.expectThrows({
            _ = try ConfigReader.read(
                labels: volumeLabels(configFile: "devcontainer.json", workspaceFolder: "/workspaces/edge"),
                containerId: "c1",
                runtime: mockRuntime(mock),
                mode: .strict
            )
        }, validate: { err in
            try MiniTest.expectEqual(errorCode(err), CLIErrorCode.configParse, "unparseable in-volume config")
        })
    }),

    ("strictVolumeMissingConfigFileLabelIsConfigNotFound", {
        let mock = MockProcessRunner()
        try MiniTest.expectThrows({
            _ = try ConfigReader.read(
                labels: volumeLabels(configFile: "   "),
                containerId: "c1",
                runtime: mockRuntime(mock),
                mode: .strict
            )
        }, validate: { err in
            try MiniTest.expectEqual(errorCode(err), CLIErrorCode.configNotFound, "missing config_file label (volume)")
        })
        try MiniTest.expect(mock.calls.isEmpty, "no exec before label check")
    }),

    // ---- 1.3 best-effort mode ----

    ("bestEffortBindMissingInputsReturnsNil", {
        let ws = try TestRepo.makeTempWorkspace(configJSON: #"{"image":"alpine:3.20"}"#)
        // Missing host file → nil (not throws).
        let missing = ws.appendingPathComponent(".devcontainer/absent.json").path
        let config = try ConfigReader.read(
            labels: bindLabels(localFolder: ws.path, configFile: missing),
            containerId: "c1",
            runtime: mockRuntime(MockProcessRunner()),
            mode: .bestEffort
        )
        try MiniTest.expect(config == nil, "missing host file → nil in best-effort")
        // Missing label → nil (not throws).
        var labels = bindLabels(localFolder: ws.path, configFile: ws.path)
        labels.removeValue(forKey: ContainerIdentity.labelConfigFile)
        let nilOnMissingLabel = try ConfigReader.read(
            labels: labels,
            containerId: "c1",
            runtime: mockRuntime(MockProcessRunner()),
            mode: .bestEffort
        )
        try MiniTest.expect(nilOnMissingLabel == nil, "missing label → nil in best-effort")
    }),

    ("bestEffortBindResolvesFromLabels", {
        let ws = try TestRepo.makeTempWorkspace(configJSON: #"{"image":"alpine:3.20"}"#)
        let configFile = ws.appendingPathComponent(".devcontainer/devcontainer.json").path
        let config = try ConfigReader.read(
            labels: bindLabels(localFolder: ws.path, configFile: configFile),
            containerId: "c1",
            runtime: mockRuntime(MockProcessRunner()),
            mode: .bestEffort
        )
        try MiniTest.expect(config != nil, "best-effort bind resolves")
        try MiniTest.expectEqual(config?.image, "alpine:3.20")
    }),

    ("bestEffortVolumeSoftFailuresReturnNil", {
        // Cat failure → nil.
        let failMock = MockProcessRunner()
        failMock.handlers.append { args in
            if args.first == "exec", args.dropFirst(2).first == "cat" {
                return ProcessResult(exitCode: 1, stdout: Data(), stderr: Data())
            }
            return nil
        }
        let labels = volumeLabels(configFile: "devcontainer.json", workspaceFolder: "/workspaces/edge")
        let nilOnFailure = try ConfigReader.read(
            labels: labels,
            containerId: "c1",
            runtime: mockRuntime(failMock),
            mode: .bestEffort
        )
        try MiniTest.expect(nilOnFailure == nil, "cat failure → nil in best-effort")

        // Empty text → nil (default mock result). No exec handler registered.
        let nilOnEmpty = try ConfigReader.read(
            labels: labels,
            containerId: "c1",
            runtime: mockRuntime(MockProcessRunner()),
            mode: .bestEffort
        )
        try MiniTest.expect(nilOnEmpty == nil, "empty text → nil in best-effort")
    }),

    ("bestEffortVolumeResolvesFromStampedFolder", {
        let configText = #"{"image":"alpine:3.20"}"#
        let mock = MockProcessRunner()
        mock.handlers.append { args in
            if args.first == "exec", args.dropFirst(2).first == "cat" {
                return ProcessResult(exitCode: 0, stdout: Data(configText.utf8), stderr: Data())
            }
            return nil
        }
        let config = try ConfigReader.read(
            labels: volumeLabels(configFile: ".devcontainer/devcontainer.json", workspaceFolder: "/workspaces/repo"),
            containerId: "c1",
            runtime: mockRuntime(mock),
            mode: .bestEffort
        )
        try MiniTest.expect(config != nil, "best-effort volume resolves")
        try MiniTest.expectEqual(config?.workspaceFolder, "/workspaces/repo")
    }),

    ("bestEffortParseErrorsStillThrow", {
        // Today's PostAttachConfigLoader propagates parse errors (it does not nil them);
        // best-effort must keep that. Returns nil only for the missing-input family.
        let ws = try TestRepo.makeTempWorkspace(configJSON: #"{"image":"alpine:3.20"}"#, prefix: "adev-bad-json2")
        let configFile = ws.appendingPathComponent(".devcontainer/devcontainer.json").path
        try Data(#"{ also not json"#.utf8).write(to: URL(fileURLWithPath: configFile))
        try MiniTest.expectThrows({
            _ = try ConfigReader.read(
                labels: bindLabels(localFolder: ws.path, configFile: configFile),
                containerId: "c1",
                runtime: mockRuntime(MockProcessRunner()),
                mode: .bestEffort
            )
        }, validate: { err in
            try MiniTest.expectEqual(errorCode(err), CLIErrorCode.configParse, "parse errors propagate in best-effort")
        })
    }),

    // ---- PostAttachConfigLoader parity regression (1.6/1.7) ----

    ("loaderParityStampedOverridesApplyOnBind", {
        let ws = try TestRepo.makeTempWorkspace(configJSON: #"{"image":"alpine:3.20","remoteUser":"alpine"}"#)
        let configFile = ws.appendingPathComponent(".devcontainer/devcontainer.json").path
        var labels = bindLabels(localFolder: ws.path, configFile: configFile)
        labels[ContainerIdentity.labelWorkspaceFolder] = "/custom/ws"
        labels[ContainerIdentity.labelRemoteUser] = "dev"
        let config = try PostAttachConfigLoader.load(
            labels: labels,
            containerId: "c1",
            imageRef: nil,
            runtime: mockRuntime(MockProcessRunner())
        )
        try MiniTest.expect(config != nil, "loader resolves bind")
        try MiniTest.expectEqual(config?.workspaceFolder, "/custom/ws", "stamped folder wins")
        try MiniTest.expectEqual(config?.effectiveUser, "dev", "stamped user wins")
    }),

    ("loaderParityStampedOverridesApplyOnVolume", {
        let configText = #"{"image":"alpine:3.20"}"#
        let mock = MockProcessRunner()
        mock.handlers.append { args in
            if args.first == "exec", args.dropFirst(2).first == "cat" {
                return ProcessResult(exitCode: 0, stdout: Data(configText.utf8), stderr: Data())
            }
            return nil
        }
        var labels = volumeLabels(configFile: ".devcontainer/devcontainer.json", workspaceFolder: "/workspaces/edge", remoteUser: "dev")
        labels[ContainerIdentity.labelRemoteUser] = "dev"
        let config = try PostAttachConfigLoader.load(
            labels: labels,
            containerId: "c1",
            imageRef: nil,
            runtime: mockRuntime(mock)
        )
        try MiniTest.expect(config != nil, "loader resolves volume")
        try MiniTest.expectEqual(config?.workspaceFolder, "/workspaces/edge", "stamped folder wins")
        try MiniTest.expectEqual(config?.effectiveUser, "dev", "stamped user wins")
    }),

    ("loaderParityBestEffortNilSemantics", {
        // Missing host file → nil.
        let ws = try TestRepo.makeTempWorkspace(configJSON: #"{"image":"alpine:3.20"}"#)
        let missing = ws.appendingPathComponent(".devcontainer/absent.json").path
        let nilOnMissing = try PostAttachConfigLoader.load(
            labels: bindLabels(localFolder: ws.path, configFile: missing),
            containerId: "c1",
            imageRef: nil,
            runtime: mockRuntime(MockProcessRunner())
        )
        try MiniTest.expect(nilOnMissing == nil, "missing file → nil")

        // Cat failure → nil.
        let failMock = MockProcessRunner()
        failMock.handlers.append { args in
            if args.first == "exec", args.dropFirst(2).first == "cat" {
                return ProcessResult(exitCode: 1, stdout: Data(), stderr: Data())
            }
            return nil
        }
        let nilOnCatFailure = try PostAttachConfigLoader.load(
            labels: volumeLabels(configFile: "devcontainer.json", workspaceFolder: "/workspaces/edge"),
            containerId: "c1",
            imageRef: nil,
            runtime: mockRuntime(failMock)
        )
        try MiniTest.expect(nilOnCatFailure == nil, "cat failure → nil")
    }),

    ("loaderParityMergeFeaturePostAttachFromLabel", {
        let ws = try TestRepo.makeTempWorkspace(configJSON: #"{"image":"alpine:3.20"}"#)
        let configFile = ws.appendingPathComponent(".devcontainer/devcontainer.json").path
        var labels = bindLabels(localFolder: ws.path, configFile: configFile)
        labels[DevContainerMetadataLabel.labelKey] = #"{"postAttachCommand":"echo meta-attach"}"#
        let config = try PostAttachConfigLoader.load(
            labels: labels,
            containerId: "c1",
            imageRef: nil,
            runtime: mockRuntime(MockProcessRunner())
        )
        try MiniTest.expect(config != nil, "loader resolves with metadata label")
        try MiniTest.expectEqual(config?.featurePostAttachCommands.count, 1, "metadata postAttach merged")
        try MiniTest.expectEqual(config?.featurePostAttachCommands.first?.execArguments, ["sh", "-lc", "echo meta-attach"])
    })
]