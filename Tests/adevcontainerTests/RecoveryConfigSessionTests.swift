import Foundation
@testable import ADevContainerLib

private func recoverySessionConfig(_ workspaceName: String = "repository") -> Data {
    Data("""
    {
      "image": "alpine:3.20",
      "name": "secret-name",
      "workspaceFolder": "/workspaces/${localWorkspaceFolderBasename}"
    }
    """.utf8)
}

private func makeRecoverySession(
    raw: Data = recoverySessionConfig(),
    workspaceFolder: String = "/workspaces/repository",
    fileManager: FileManager = .default,
    sessionID: String = "session-opaque-\(UUID().uuidString.lowercased())"
) throws -> RecoveryConfigSession {
    try RecoveryConfigSession(
        rawBytes: raw,
        targetContainerID: "old-id",
        targetContainerName: "adev-repository-hash",
        workspaceVolume: "adev-repository-ws",
        configFile: "/workspaces/repository/.devcontainer/devcontainer.json",
        workspaceFolder: workspaceFolder,
        fileManager: fileManager,
        sessionID: sessionID
    )
}

private func sessionConfigLabels(
    workspaceFolder: String = "/workspaces/repository",
    configFile: String = "/workspaces/repository/.devcontainer/devcontainer.json"
) -> [String: String] {
    [
        ContainerIdentity.labelWorkspaceMode: ContainerIdentity.workspaceModeVolume,
        ContainerIdentity.labelWorkspaceFolder: workspaceFolder,
        ContainerIdentity.labelConfigFile: configFile
    ]
}

private func sessionCurrentReadRunner(
    current: Data,
    edited: Data? = nil
) -> (MockProcessRunner, () -> Int) {
    let mock = MockProcessRunner()
    var readCount = 0
    mock.handlers = [{ args in
        guard args.first == "exec", args.contains("cat") else { return nil }
        readCount += 1
        let payload = readCount == 1 ? current : (edited ?? current)
        return ProcessResult(exitCode: 0, stdout: payload, stderr: Data())
    }]
    return (mock, { readCount })
}

nonisolated(unsafe) let recoveryConfigSessionTests: [(String, () throws -> Void)] = [
    ("foundationRunnerStreamsLargeRecoveryPayloadAfterLaunch", {
        let payload = Data(repeating: 0x61, count: 128 * 1024)
        let result = try FoundationProcessRunner().run(
            executable: "/usr/bin/wc",
            arguments: ["-c"],
            environment: nil,
            currentDirectory: nil,
            stdinData: payload
        )
        try MiniTest.expect(result.succeeded)
        try MiniTest.expectEqual(result.stdoutString.trimmingCharacters(in: .whitespacesAndNewlines), "131072")
    }),

    ("configReaderRawCaptureRetainsExactRuntimeBytes", {
        let raw = Data("// keep this exact\n{ \"image\": \"alpine:3.20\" }\n".utf8)
        let mock = MockProcessRunner()
        mock.handlers = [{ args in
            guard args.first == "exec", args.contains("cat") else { return nil }
            return ProcessResult(exitCode: 0, stdout: raw, stderr: Data())
        }]
        let labels: [String: String] = [
            ContainerIdentity.labelWorkspaceMode: ContainerIdentity.workspaceModeVolume,
            ContainerIdentity.labelWorkspaceFolder: "/workspaces/repository",
            ContainerIdentity.labelConfigFile: ".devcontainer/devcontainer.json"
        ]
        let runtime = AppleContainerRuntime(executablePath: "container", runner: mock)
        let retained = try ConfigReader.retainRawVolumeConfig(
            labels: labels,
            containerId: "old",
            runtime: runtime
        )
        try MiniTest.expectEqual(retained.bytes, raw)
        try MiniTest.expectEqual(retained.pathInContainer, "/workspaces/repository/.devcontainer/devcontainer.json")
        try MiniTest.expectEqual(retained.workspaceFolderBasename, "repository")

        let resolveMock = MockProcessRunner()
        resolveMock.handlers = [{ args in
            guard args.first == "exec", args.contains("cat") else { return nil }
            return ProcessResult(exitCode: 0, stdout: raw, stderr: Data())
        }]
        let resolved = try ConfigReader.readVolumeWithRaw(
            labels: labels,
            containerId: "old",
            runtime: AppleContainerRuntime(executablePath: "container", runner: resolveMock)
        )
        try MiniTest.expectEqual(resolved.raw.bytes, raw)
        try MiniTest.expectEqual(resolved.config.image, "alpine:3.20")
    }),

    ("recoverySessionRetainsExactBytesAndSecurePermissions", {
        let raw = Data(#"{ "image": "alpine:3.20", "secret": "do-not-leak" }"#.utf8)
        let session = try makeRecoverySession(raw: raw)
        defer { try? session.cleanup() }
        try MiniTest.expectEqual(try session.readTempBytes(), raw)
        try MiniTest.expectEqual(session.originalHash, RecoveryConfigSession.sha256Hex(raw))
        try MiniTest.expectEqual(session.baselineHash, RecoveryConfigSession.sha256Hex(raw))
        try MiniTest.expectEqual(session.lastAppliedHash, nil)

        let dirAttrs = try FileManager.default.attributesOfItem(atPath: session.directoryURL.path)
        let fileAttrs = try FileManager.default.attributesOfItem(atPath: session.tempFileURL.path)
        try MiniTest.expectEqual((dirAttrs[.posixPermissions] as? NSNumber)?.intValue, 0o700)
        try MiniTest.expectEqual((fileAttrs[.posixPermissions] as? NSNumber)?.intValue, 0o600)
        let metadataText = String(data: try Data(contentsOf: session.metadataURL), encoding: .utf8) ?? ""
        try MiniTest.expect(!metadataText.contains("do-not-leak"), "raw config is absent from metadata")
        try MiniTest.expect(!session.summary.tempFile.isEmpty)
    }),

    ("recoverySessionUsesStampedWorkspaceBasenameForValidation", {
        let raw = Data(#"{ "image": "alpine:3.20", "workspaceFolder": "/workspaces/${localWorkspaceFolderBasename}" }"#.utf8)
        let session = try RecoveryConfigSession(
            rawBytes: raw,
            targetContainerID: "old-id",
            targetContainerName: "adev-repository-hash",
            workspaceVolume: "adev-repository-ws",
            configFile: "/workspaces/repository/.devcontainer/devcontainer.json",
            workspaceFolder: "/workspaces/repository",
            sessionID: "session-basename"
        )
        defer { try? session.cleanup() }
        let resolved = try session.validateEditedConfig()
        try MiniTest.expectEqual(resolved.config.workspaceFolder, "/workspaces/repository")
        try MiniTest.expect(!resolved.workspacePath.hasSuffix("repository"), "private temp basename is not used")
    }),

    ("recoverySessionRejectsConfigPathOutsideWorkspace", {
        for path in ["../../etc/passwd", "/etc/passwd"] {
            try MiniTest.expectThrows({
                _ = try RecoveryConfigSession(
                    rawBytes: recoverySessionConfig(),
                    targetContainerID: "old-id",
                    targetContainerName: "adev-repository-hash",
                    workspaceVolume: "adev-repository-ws",
                    configFile: path,
                    workspaceFolder: "/workspaces/repository",
                    sessionID: "session-path"
                )
            }, validate: { error in
                try MiniTest.expectEqual((error as? CLIError)?.code, CLIErrorCode.recoveryUnavailable)
            })
        }
    }),

    ("recoverySessionRejectsInsecureModeAndSymlink", {
        let insecure = try makeRecoverySession()
        defer { try? FileManager.default.removeItem(at: insecure.directoryURL) }
        try FileManager.default.setAttributes(
            [.posixPermissions: NSNumber(value: 0o644)],
            ofItemAtPath: insecure.tempFileURL.path
        )
        try MiniTest.expectThrows({ _ = try insecure.readTempBytes() }, validate: { error in
            try MiniTest.expectEqual((error as? CLIError)?.code, CLIErrorCode.recoveryUnavailable)
        })

        let symlinkSession = try makeRecoverySession(sessionID: "session-symlink")
        defer { try? FileManager.default.removeItem(at: symlinkSession.directoryURL) }
        let replacement = symlinkSession.directoryURL.appendingPathComponent("outside.json")
        try Data("outside".utf8).write(to: replacement)
        try FileManager.default.removeItem(at: symlinkSession.tempFileURL)
        try FileManager.default.createSymbolicLink(
            atPath: symlinkSession.tempFileURL.path,
            withDestinationPath: replacement.path
        )
        try MiniTest.expectThrows({ _ = try symlinkSession.readTempBytes() }, validate: { error in
            try MiniTest.expectEqual((error as? CLIError)?.code, CLIErrorCode.recoveryUnavailable)
        })
    }),

    ("recoverySessionOpenRejectsSymlinkedMetadata", {
        let session = try makeRecoverySession()
        let directory = session.directoryURL
        defer { try? FileManager.default.removeItem(at: directory) }
        let outside = directory.deletingLastPathComponent().appendingPathComponent("outside-metadata.json")
        try Data("{}".utf8).write(to: outside)
        try FileManager.default.removeItem(at: session.metadataURL)
        try FileManager.default.createSymbolicLink(
            atPath: session.metadataURL.path,
            withDestinationPath: outside.path
        )
        try MiniTest.expectThrows({
            _ = try RecoveryConfigSession.open(directoryURL: directory)
        }, validate: { error in
            try MiniTest.expectEqual((error as? CLIError)?.code, CLIErrorCode.recoveryUnavailable)
        })
        try? FileManager.default.removeItem(at: outside)
    }),

    ("recoverySessionRejectsTraversalAndSymlinkedDirectory", {
        for id in ["../escape", "../../escape", "/absolute", "contains.dot", "contains_under"] {
            try MiniTest.expectThrows({
                _ = try makeRecoverySession(sessionID: id)
            }, validate: { error in
                try MiniTest.expectEqual((error as? CLIError)?.code, CLIErrorCode.recoveryUnavailable)
            })
        }

        let target = try makeRecoverySession(sessionID: "symlink-target")
        defer { try? FileManager.default.removeItem(at: target.directoryURL) }
        let link = target.directoryURL.deletingLastPathComponent()
            .appendingPathComponent("\(RecoveryConfigSession.directoryPrefix)symlink-link", isDirectory: true)
        try? FileManager.default.removeItem(at: link)
        try FileManager.default.createSymbolicLink(
            atPath: link.path,
            withDestinationPath: target.directoryURL.path
        )
        defer { try? FileManager.default.removeItem(at: link) }
        try MiniTest.expectThrows({
            _ = try RecoveryConfigSession.open(directoryURL: link)
        }, validate: { error in
            try MiniTest.expectEqual((error as? CLIError)?.code, CLIErrorCode.recoveryUnavailable)
        })

        let outside = target.directoryURL.deletingLastPathComponent()
            .deletingLastPathComponent()
            .appendingPathComponent("\(RecoveryConfigSession.directoryPrefix)outside", isDirectory: true)
        try? FileManager.default.removeItem(at: outside)
        try FileManager.default.createDirectory(at: outside, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: outside) }
        try MiniTest.expectThrows({
            _ = try RecoveryConfigSession.open(directoryURL: outside)
        }, validate: { error in
            try MiniTest.expectEqual((error as? CLIError)?.code, CLIErrorCode.recoveryUnavailable)
        })
    }),

    ("recoverySessionConflictPreservesEditAndDoesNotOverwrite", {
        let original = recoverySessionConfig()
        let edited = Data(#"{ "image": "alpine:3.20", "workspaceFolder": "/workspaces/changed" }"#.utf8)
        let current = Data(#"{ "image": "alpine:3.20", "workspaceFolder": "/workspaces/external" }"#.utf8)
        let session = try makeRecoverySession(raw: original)
        defer { try? session.cleanup() }
        try edited.write(to: session.tempFileURL, options: .atomic)
        try FileManager.default.setAttributes(
            [.posixPermissions: NSNumber(value: 0o600)],
            ofItemAtPath: session.tempFileURL.path
        )
        let (mock, _) = sessionCurrentReadRunner(current: current)
        let runtime = AppleContainerRuntime(executablePath: "container", runner: mock)
        try MiniTest.expectThrows({
            _ = try session.applyEdit(helperContainerID: "helper", runtime: runtime)
        }, validate: { error in
            try MiniTest.expectEqual((error as? CLIError)?.code, CLIErrorCode.recoveryConflict)
        })
        try MiniTest.expectEqual(try session.readTempBytes(), edited)
        try MiniTest.expectEqual(try Data(contentsOf: session.conflictFileURL!), current)
        try MiniTest.expectEqual(session.baselineHash, RecoveryConfigSession.sha256Hex(original))
        try MiniTest.expectEqual(session.conflictHash, RecoveryConfigSession.sha256Hex(current))
        try MiniTest.expect(!mock.calls.contains { $0.arguments.contains("sh") }, "conflict is detected before write")
        try MiniTest.expect(!mock.calls.contains { $0.arguments.first == "cp" || $0.arguments.first == "copy" })
    }),

    ("recoverySessionConflictRequiresExplicitBaselineAcknowledgement", {
        let original = recoverySessionConfig()
        let edited = Data(#"{ "image": "alpine:3.20", "workspaceFolder": "/workspaces/edited" }"#.utf8)
        let current = Data(#"{ "image": "alpine:3.20", "workspaceFolder": "/workspaces/external" }"#.utf8)
        let session = try makeRecoverySession(raw: original)
        defer { try? session.cleanup() }
        try edited.write(to: session.tempFileURL, options: .atomic)
        try FileManager.default.setAttributes(
            [.posixPermissions: NSNumber(value: 0o600)],
            ofItemAtPath: session.tempFileURL.path
        )
        let editedHash = RecoveryConfigSession.sha256Hex(edited)
        var readCount = 0
        let mock = MockProcessRunner()
        mock.handlers = [{ args in
            if args.first == "exec", args.contains("cat") {
                readCount += 1
                return ProcessResult(
                    exitCode: 0,
                    stdout: readCount <= 3 ? current : edited,
                    stderr: Data()
                )
            }
            if args.first == "exec", args.contains("adevcontainer-recovery-write") {
                return ProcessResult(
                    exitCode: 0,
                    stdout: Data("RECOVERY_APPLIED:\(editedHash)\n".utf8),
                    stderr: Data()
                )
            }
            return nil
        }]
        let runtime = AppleContainerRuntime(executablePath: "container", runner: mock)
        try MiniTest.expectThrows({
            _ = try session.applyEdit(helperContainerID: "helper", runtime: runtime)
        }) { error in
            try MiniTest.expectEqual((error as? CLIError)?.code, CLIErrorCode.recoveryConflict)
        }
        try MiniTest.expect(!mock.calls.contains { $0.arguments.contains("adevcontainer-recovery-write") })
        try session.acknowledgeConflict(helperContainerID: "helper", runtime: runtime)
        _ = try session.applyEdit(helperContainerID: "helper", runtime: runtime)
        try MiniTest.expectEqual(session.baselineHash, editedHash)
        try MiniTest.expectEqual(session.lastAppliedHash, editedHash)
        try MiniTest.expectEqual(session.conflictHash, nil)
    }),

    ("recoverySessionRejectsMutatedConflictArtifact", {
        let session = try makeRecoverySession(raw: recoverySessionConfig())
        defer { try? FileManager.default.removeItem(at: session.directoryURL) }
        let current = Data(#"{ "image": "alpine:3.20", "workspaceFolder": "/workspaces/external" }"#.utf8)
        let mock = MockProcessRunner()
        mock.handlers = [{ args in
            guard args.first == "exec", args.contains("cat") else { return nil }
            return ProcessResult(exitCode: 0, stdout: current, stderr: Data())
        }]
        let runtime = AppleContainerRuntime(executablePath: "container", runner: mock)
        do {
            _ = try session.applyEdit(helperContainerID: "helper", runtime: runtime)
        } catch {
            // The expected baseline conflict creates the retained artifact.
        }
        guard let conflict = session.conflictFileURL else {
            throw MiniTest.Failure(message: "conflict file was not retained")
        }
        try Data("tampered".utf8).write(to: conflict, options: .atomic)
        try FileManager.default.setAttributes(
            [.posixPermissions: NSNumber(value: 0o600)],
            ofItemAtPath: conflict.path
        )
        try MiniTest.expectThrows({
            _ = try session.applyEdit(helperContainerID: "helper", runtime: runtime)
        }, validate: { error in
            try MiniTest.expectEqual((error as? CLIError)?.code, CLIErrorCode.recoveryUnavailable)
        })
    }),

    ("recoverySessionAtomicWriteUsesStdinAndReadbackWithoutCopy", {
        let original = recoverySessionConfig()
        let edited = Data(#"{ "image": "alpine:3.20", "workspaceFolder": "/workspaces/edited" }"#.utf8)
        let session = try makeRecoverySession(raw: original)
        defer { try? session.cleanup() }
        try edited.write(to: session.tempFileURL, options: .atomic)
        try FileManager.default.setAttributes(
            [.posixPermissions: NSNumber(value: 0o600)],
            ofItemAtPath: session.tempFileURL.path
        )
        let expectedHash = RecoveryConfigSession.sha256Hex(edited)
        let mock = MockProcessRunner()
        var atomicCall: MockProcessRunner.MockProcessCall?
        var readCount = 0
        mock.handlers = [{ args in
            if args.first == "exec", args.contains("cat") {
                readCount += 1
                return ProcessResult(
                    exitCode: 0,
                    stdout: readCount == 1 ? original : edited,
                    stderr: Data()
                )
            }
            if args.first == "exec", args.contains("sh") {
                atomicCall = mock.calls.last
                return ProcessResult(
                    exitCode: 0,
                    stdout: Data("RECOVERY_APPLIED:\(expectedHash)\n".utf8),
                    stderr: Data()
                )
            }
            return nil
        }]
        let runtime = AppleContainerRuntime(executablePath: "container", runner: mock)
        let applied = try session.applyEdit(helperContainerID: "helper", runtime: runtime)
        try MiniTest.expectEqual(applied, expectedHash)
        try MiniTest.expectEqual(session.lastAppliedHash, expectedHash)
        try MiniTest.expectEqual(atomicCall?.stdinData, edited)
        try MiniTest.expect(atomicCall?.arguments.contains { $0.contains("mktemp") } == true)
        try MiniTest.expect(atomicCall?.arguments.contains("cp") != true)
        try MiniTest.expect(!mock.calls.contains { $0.arguments.first == "cp" || $0.arguments.first == "copy" })
    }),

    ("recoverySessionApplyEditBouncesZombieHelperBeforeRead", {
        // Regression: TTY editor exits successfully, then baseline cat fails because Apple
        // container still lists the helper as running while rejecting exec. applyEdit must
        // bounce the helper and complete write/readback rather than recovery_verification_failed.
        let original = recoverySessionConfig()
        let edited = Data(#"{ "image": "alpine:3.20", "workspaceFolder": "/workspaces/edited" }"#.utf8)
        let session = try makeRecoverySession(raw: original)
        defer { try? session.cleanup() }
        try edited.write(to: session.tempFileURL, options: .atomic)
        try FileManager.default.setAttributes(
            [.posixPermissions: NSNumber(value: 0o600)],
            ofItemAtPath: session.tempFileURL.path
        )
        let expectedHash = RecoveryConfigSession.sha256Hex(edited)
        var helperReady = false
        var readCount = 0
        let mock = MockProcessRunner()
        mock.handlers = [{ args in
            if args.first == "exec", args.contains("true") {
                return ProcessResult(
                    exitCode: helperReady ? 0 : 1,
                    stdout: Data(),
                    stderr: helperReady
                        ? Data()
                        : Data("cannot exec: container is not running".utf8)
                )
            }
            if args.first == "start" {
                if mock.calls.contains(where: { $0.arguments.first == "stop" }) {
                    helperReady = true
                }
                return ProcessResult(exitCode: 0, stdout: Data(), stderr: Data())
            }
            if args.first == "stop" {
                return ProcessResult(exitCode: 0, stdout: Data(), stderr: Data())
            }
            if args.first == "exec", args.contains("cat") {
                guard helperReady else {
                    return ProcessResult(
                        exitCode: 1,
                        stdout: Data(),
                        stderr: Data("cannot exec: container is not running".utf8)
                    )
                }
                readCount += 1
                return ProcessResult(
                    exitCode: 0,
                    stdout: readCount == 1 ? original : edited,
                    stderr: Data()
                )
            }
            if args.first == "exec", args.contains("adevcontainer-recovery-write") {
                guard helperReady else {
                    return ProcessResult(exitCode: 1, stdout: Data(), stderr: Data())
                }
                return ProcessResult(
                    exitCode: 0,
                    stdout: Data("RECOVERY_APPLIED:\(expectedHash)\n".utf8),
                    stderr: Data()
                )
            }
            return nil
        }]
        let runtime = AppleContainerRuntime(executablePath: "container", runner: mock)
        let applied = try session.applyEdit(helperContainerID: "helper", runtime: runtime)
        try MiniTest.expectEqual(applied, expectedHash)
        try MiniTest.expect(mock.calls.contains { $0.arguments.first == "stop" })
        try MiniTest.expect(mock.calls.contains { $0.arguments.first == "start" })
        try MiniTest.expectEqual(session.lastAppliedHash, expectedHash)
    }),

    ("recoverySessionValidationFailureDoesNotWrite", {
        let invalid = Data("{ invalid".utf8)
        let session = try makeRecoverySession(raw: recoverySessionConfig())
        defer { try? session.cleanup() }
        try invalid.write(to: session.tempFileURL, options: .atomic)
        try FileManager.default.setAttributes(
            [.posixPermissions: NSNumber(value: 0o600)],
            ofItemAtPath: session.tempFileURL.path
        )
        let mock = MockProcessRunner()
        let runtime = AppleContainerRuntime(executablePath: "container", runner: mock)
        try MiniTest.expectThrows({
            _ = try session.applyValidatedEdit(helperContainerID: "helper", runtime: runtime)
        }, validate: { error in
            try MiniTest.expectEqual((error as? CLIError)?.code, CLIErrorCode.configParse)
        })
        try MiniTest.expect(mock.calls.isEmpty, "invalid bytes never reach the helper")
    })
]
