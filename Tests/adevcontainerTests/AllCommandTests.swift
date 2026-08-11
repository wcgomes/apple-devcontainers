import Foundation
@testable import ADevContainerLib

nonisolated(unsafe) let doctorTests: [(String, () throws -> Void)] = [
    ("doctorPass", {
        let path = "/usr/local/bin/container"
        guard FileManager.default.isExecutableFile(atPath: path) else {
            try MiniTest.skip("container binary not present")
        }
        let mock = MockProcessRunner()
        try mock.enqueueJSON([["appName": "container", "version": "1.2.1"]])
        try mock.enqueueJSON(["status": "running", "apiServerVersion": "1.2.1"] as [String: Any])
        let runtime = AppleContainerRuntime(executablePath: path, runner: mock)
        let report = try DoctorCommand.run(runtime: runtime)
        try MiniTest.expect(report.ok)
        try MiniTest.expectEqual(report.binaryPath, path)
        try MiniTest.expect(report.version?.contains("1.2.1") == true)
        try MiniTest.expectEqual(report.status, "running")
    }),
    ("doctorMissingBinary", {
        let mock = MockProcessRunner()
        let runtime = AppleContainerRuntime(
            executablePath: "/tmp/definitely-missing-container-binary-\(UUID().uuidString)",
            runner: mock
        )
        try MiniTest.expectThrows({ _ = try DoctorCommand.run(runtime: runtime) }) { error in
            try MiniTest.expectEqual((error as! CLIError).code, CLIErrorCode.runtimeMissing)
        }
    })
]

nonisolated(unsafe) let upTests: [(String, () throws -> Void)] = [
    ("upCreateReturnsJSONShape", {
        let workspace = try TestRepo.makeTempWorkspace(configJSON: """
        { "name": "Up Test", "image": "alpine:3.20" }
        """)
        defer { try? FileManager.default.removeItem(at: workspace) }
        let mock = MockProcessRunner()
        let resolved = try ConfigResolver.resolve(workspacePath: workspace.path, localEnv: [:])
        mock.handlers = [
            { args in
                if args.starts(with: ["list"]) {
                    let data = try! JSONSerialization.data(withJSONObject: [] as [Any])
                    return ProcessResult(exitCode: 0, stdout: data, stderr: Data())
                }
                return nil
            },
            { args in
                if args.first == "create" {
                    return ProcessResult(
                        exitCode: 0,
                        stdout: Data("\(resolved.containerName)\n".utf8),
                        stderr: Data()
                    )
                }
                return nil
            },
            { args in
                if args.first == "start" {
                    return ProcessResult(exitCode: 0, stdout: Data(), stderr: Data())
                }
                return nil
            }
        ]
        let runtime = AppleContainerRuntime(executablePath: "/usr/local/bin/container", runner: mock)
        let result = try UpCommand.run(
            options: UpOptions(workspacePath: workspace.path, jsonOutput: true, skipPull: true),
            runtime: runtime,
            localEnv: [:]
        )
        try MiniTest.expectEqual(result.outcome, "success")
        try MiniTest.expectEqual(result.containerId, resolved.containerName)
        try MiniTest.expectEqual(
            result.remoteWorkspaceFolder,
            "/workspaces/\(workspace.lastPathComponent)"
        )
        let obj = try JSONSerialization.jsonObject(with: try result.jsonData()) as! [String: Any]
        try MiniTest.expect(obj["outcome"] != nil)
        try MiniTest.expect(obj["containerId"] != nil)
        try MiniTest.expect(obj["remoteUser"] != nil)
        try MiniTest.expect(obj["remoteWorkspaceFolder"] != nil)
    }),
    ("upReusesRunning", {
        let workspace = try TestRepo.makeTempWorkspace(configJSON: #"{ "image": "alpine:3.20" }"#)
        defer { try? FileManager.default.removeItem(at: workspace) }
        let mock = MockProcessRunner()
        let resolved = try ConfigResolver.resolve(workspacePath: workspace.path, localEnv: [:])
        let entry = MockProcessRunner.containerListJSON(
            id: resolved.containerName,
            state: "running",
            labels: resolved.labels
        )
        mock.handlers = [
            { args in
                if args.starts(with: ["list"]) {
                    let data = try! JSONSerialization.data(withJSONObject: [entry])
                    return ProcessResult(exitCode: 0, stdout: data, stderr: Data())
                }
                return nil
            }
        ]
        let runtime = AppleContainerRuntime(executablePath: "/usr/local/bin/container", runner: mock)
        let result = try UpCommand.run(
            options: UpOptions(workspacePath: workspace.path, skipPull: true),
            runtime: runtime,
            localEnv: [:]
        )
        try MiniTest.expectEqual(result.containerId, resolved.containerName)
        try MiniTest.expect(!mock.calls.contains { $0.arguments.first == "create" })
    }),
    ("upStartsStopped", {
        let workspace = try TestRepo.makeTempWorkspace(configJSON: #"{ "image": "alpine:3.20" }"#)
        defer { try? FileManager.default.removeItem(at: workspace) }
        let mock = MockProcessRunner()
        let resolved = try ConfigResolver.resolve(workspacePath: workspace.path, localEnv: [:])
        let entry = MockProcessRunner.containerListJSON(
            id: resolved.containerName,
            state: "stopped",
            labels: resolved.labels
        )
        mock.handlers = [
            { args in
                if args.starts(with: ["list"]) {
                    let data = try! JSONSerialization.data(withJSONObject: [entry])
                    return ProcessResult(exitCode: 0, stdout: data, stderr: Data())
                }
                if args.first == "start" {
                    return ProcessResult(exitCode: 0, stdout: Data(), stderr: Data())
                }
                return nil
            }
        ]
        let runtime = AppleContainerRuntime(executablePath: "/usr/local/bin/container", runner: mock)
        let result = try UpCommand.run(
            options: UpOptions(workspacePath: workspace.path, skipPull: true),
            runtime: runtime,
            localEnv: [:]
        )
        try MiniTest.expectEqual(result.outcome, "success")
        try MiniTest.expect(mock.calls.contains { $0.arguments.first == "start" })
    }),
    ("hashMismatchErrorsHintsRebuild", {
        let workspace = try TestRepo.makeTempWorkspace(configJSON: #"{ "image": "alpine:3.20" }"#)
        defer { try? FileManager.default.removeItem(at: workspace) }
        let mock = MockProcessRunner()
        let resolved = try ConfigResolver.resolve(workspacePath: workspace.path, localEnv: [:])
        var labels = resolved.labels
        labels[ContainerIdentity.labelConfigHash] = "old-hash"
        let entry = MockProcessRunner.containerListJSON(
            id: resolved.containerName,
            state: "running",
            labels: labels
        )
        mock.handlers = [
            { args in
                if args.starts(with: ["list"]) {
                    let data = try! JSONSerialization.data(withJSONObject: [entry])
                    return ProcessResult(exitCode: 0, stdout: data, stderr: Data())
                }
                return nil
            }
        ]
        let runtime = AppleContainerRuntime(executablePath: "/usr/local/bin/container", runner: mock)
        try MiniTest.expectThrows({
            _ = try UpCommand.run(
                options: UpOptions(workspacePath: workspace.path, skipPull: true),
                runtime: runtime,
                localEnv: [:]
            )
        }) { error in
            let err = error as! CLIError
            try MiniTest.expectEqual(err.code, CLIErrorCode.configHashMismatch)
            let hint = err.hint ?? ""
            try MiniTest.expect(hint.contains("adevcontainer rebuild"), "hint points to rebuild")
            try MiniTest.expect(hint.contains("--name") || hint.contains("auto"), "hint mentions managed selection")
        }
    })
]

nonisolated(unsafe) let execTests: [(String, () throws -> Void)] = [
    ("execRunning", {
        let workspace = try TestRepo.makeTempWorkspace(configJSON: """
        { "image": "alpine:3.20", "remoteUser": "vscode", "workspaceFolder": "/workspaces/app" }
        """)
        defer { try? FileManager.default.removeItem(at: workspace) }
        let mock = MockProcessRunner()
        let resolved = try ConfigResolver.resolve(workspacePath: workspace.path, localEnv: [:])
        let entry = MockProcessRunner.containerListJSON(
            id: resolved.containerName,
            state: "running",
            labels: resolved.labels
        )
        mock.handlers = [
            { args in
                if args.starts(with: ["list"]) {
                    let data = try! JSONSerialization.data(withJSONObject: [entry])
                    return ProcessResult(exitCode: 0, stdout: data, stderr: Data())
                }
                if args.first == "exec" {
                    return ProcessResult(exitCode: 0, stdout: Data("ok\n".utf8), stderr: Data())
                }
                return nil
            }
        ]
        let runtime = AppleContainerRuntime(executablePath: "/usr/local/bin/container", runner: mock)
        let code = try ExecCommand.run(
            options: ExecOptions(command: ["echo", "ok"], name: resolved.containerName),
            runtime: runtime
        )
        try MiniTest.expectEqual(code, 0)
        let execCall = mock.calls.first { $0.arguments.first == "exec" }!
        try MiniTest.expect(execCall.arguments.contains("vscode"))
        try MiniTest.expect(execCall.arguments.contains("/workspaces/app"))
        try MiniTest.expect(execCall.arguments.contains("echo"))
        try MiniTest.expect(!execCall.arguments.contains("-i"))
        try MiniTest.expect(!execCall.arguments.contains("-t"))
    }),
    ("execInteractiveAddsITAndUsesInteractiveRunner", {
        let workspace = try TestRepo.makeTempWorkspace(configJSON: """
        { "image": "alpine:3.20", "remoteUser": "vscode", "workspaceFolder": "/workspaces/app" }
        """)
        defer { try? FileManager.default.removeItem(at: workspace) }
        let listMock = MockProcessRunner()
        let interactiveMock = MockProcessRunner()
        let resolved = try ConfigResolver.resolve(workspacePath: workspace.path, localEnv: [:])
        let entry = MockProcessRunner.containerListJSON(
            id: resolved.containerName,
            state: "running",
            labels: resolved.labels
        )
        listMock.handlers = [
            { args in
                if args.starts(with: ["list"]) {
                    let data = try! JSONSerialization.data(withJSONObject: [entry])
                    return ProcessResult(exitCode: 0, stdout: data, stderr: Data())
                }
                return nil
            }
        ]
        interactiveMock.handlers = [
            { args in
                if args.first == "exec" {
                    // Inherited stdio: no captured output required
                    return ProcessResult(exitCode: 0, stdout: Data(), stderr: Data())
                }
                return nil
            }
        ]
        let runtime = AppleContainerRuntime(
            executablePath: "/usr/local/bin/container",
            runner: listMock,
            interactiveRunner: interactiveMock
        )
        let code = try ExecCommand.run(
            options: ExecOptions(
                command: ["bash", "-lc", "true"],
                interactive: true,
                name: resolved.containerName
            ),
            runtime: runtime
        )
        try MiniTest.expectEqual(code, 0)
        try MiniTest.expect(listMock.calls.contains { $0.arguments.first == "list" })
        try MiniTest.expect(!listMock.calls.contains { $0.arguments.first == "exec" })
        let execCall = interactiveMock.calls.first { $0.arguments.first == "exec" }!
        try MiniTest.expect(execCall.arguments.contains("-i"))
        try MiniTest.expect(execCall.arguments.contains("-t"))
        try MiniTest.expect(execCall.arguments.contains("bash"))
    }),
    ("execEmptyCommandDefaultsToBash", {
        let workspace = try TestRepo.makeTempWorkspace(configJSON: #"{ "image": "alpine:3.20" }"#)
        defer { try? FileManager.default.removeItem(at: workspace) }
        let listMock = MockProcessRunner()
        let interactiveMock = MockProcessRunner()
        let resolved = try ConfigResolver.resolve(workspacePath: workspace.path, localEnv: [:])
        let entry = MockProcessRunner.containerListJSON(
            id: resolved.containerName,
            state: "running",
            labels: resolved.labels
        )
        listMock.handlers = [
            { args in
                if args.starts(with: ["list"]) {
                    let data = try! JSONSerialization.data(withJSONObject: [entry])
                    return ProcessResult(exitCode: 0, stdout: data, stderr: Data())
                }
                return nil
            }
        ]
        interactiveMock.handlers = [
            { args in
                if args.first == "exec" {
                    return ProcessResult(exitCode: 0, stdout: Data(), stderr: Data())
                }
                return nil
            }
        ]
        let runtime = AppleContainerRuntime(
            executablePath: "/usr/local/bin/container",
            runner: listMock,
            interactiveRunner: interactiveMock
        )
        let code = try ExecCommand.run(
            options: ExecOptions(command: [], interactive: true, name: resolved.containerName),
            runtime: runtime
        )
        try MiniTest.expectEqual(code, 0)
        let execCall = interactiveMock.calls.first { $0.arguments.first == "exec" }!
        try MiniTest.expect(execCall.arguments.contains("-i"))
        try MiniTest.expect(execCall.arguments.contains("-t"))
        try MiniTest.expect(execCall.arguments.last == "bash")
    }),
    ("execNotRunningMissing", {
        let mock = MockProcessRunner()
        mock.handlers = [
            { args in
                if args.starts(with: ["list"]) {
                    let data = try! JSONSerialization.data(withJSONObject: [] as [Any])
                    return ProcessResult(exitCode: 0, stdout: data, stderr: Data())
                }
                return nil
            }
        ]
        let runtime = AppleContainerRuntime(executablePath: "/usr/local/bin/container", runner: mock)
        try MiniTest.expectThrows({
            _ = try ExecCommand.run(
                options: ExecOptions(command: ["true"], name: "adev-missing"),
                runtime: runtime
            )
        }) { error in
            try MiniTest.expectEqual((error as! CLIError).code, CLIErrorCode.containerNotFound)
        }
    }),
    ("execStoppedContainer", {
        let workspace = try TestRepo.makeTempWorkspace(configJSON: #"{ "image": "alpine:3.20" }"#)
        defer { try? FileManager.default.removeItem(at: workspace) }
        let mock = MockProcessRunner()
        let resolved = try ConfigResolver.resolve(workspacePath: workspace.path, localEnv: [:])
        let entry = MockProcessRunner.containerListJSON(
            id: resolved.containerName,
            state: "stopped",
            labels: resolved.labels
        )
        mock.handlers = [
            { args in
                if args.starts(with: ["list"]) {
                    let data = try! JSONSerialization.data(withJSONObject: [entry])
                    return ProcessResult(exitCode: 0, stdout: data, stderr: Data())
                }
                return nil
            }
        ]
        let runtime = AppleContainerRuntime(executablePath: "/usr/local/bin/container", runner: mock)
        try MiniTest.expectThrows({
            _ = try ExecCommand.run(
                options: ExecOptions(command: ["true"], name: resolved.containerName),
                runtime: runtime
            )
        }) { error in
            try MiniTest.expectEqual((error as! CLIError).code, CLIErrorCode.containerNotRunning)
        }
    })
]

nonisolated(unsafe) let lifecycleTests: [(String, () throws -> Void)] = [
    ("stopRunning", {
        let workspace = try TestRepo.makeTempWorkspace(configJSON: #"{ "image": "alpine:3.20" }"#)
        defer { try? FileManager.default.removeItem(at: workspace) }
        let mock = MockProcessRunner()
        let resolved = try ConfigResolver.resolve(workspacePath: workspace.path, localEnv: [:])
        let entry = MockProcessRunner.containerListJSON(
            id: resolved.containerName, state: "running", labels: resolved.labels
        )
        mock.handlers = [
            { args in
                if args.starts(with: ["list"]) {
                    let data = try! JSONSerialization.data(withJSONObject: [entry])
                    return ProcessResult(exitCode: 0, stdout: data, stderr: Data())
                }
                if args.first == "stop" {
                    return ProcessResult(exitCode: 0, stdout: Data(), stderr: Data())
                }
                return nil
            }
        ]
        let runtime = AppleContainerRuntime(executablePath: "/usr/local/bin/container", runner: mock)
        try StopCommand.run(name: resolved.containerName, runtime: runtime)
        try MiniTest.expect(mock.calls.contains { $0.arguments == ["stop", resolved.containerName] })
    }),
    ("deleteContainer", {
        let workspace = try TestRepo.makeTempWorkspace(configJSON: #"{ "image": "alpine:3.20" }"#)
        defer { try? FileManager.default.removeItem(at: workspace) }
        let mock = MockProcessRunner()
        let resolved = try ConfigResolver.resolve(workspacePath: workspace.path, localEnv: [:])
        let entry = MockProcessRunner.containerListJSON(
            id: resolved.containerName, state: "stopped", labels: resolved.labels
        )
        mock.handlers = [
            { args in
                if args.starts(with: ["list"]) {
                    let data = try! JSONSerialization.data(withJSONObject: [entry])
                    return ProcessResult(exitCode: 0, stdout: data, stderr: Data())
                }
                if args.first == "delete" {
                    return ProcessResult(exitCode: 0, stdout: Data(), stderr: Data())
                }
                return nil
            }
        ]
        let runtime = AppleContainerRuntime(executablePath: "/usr/local/bin/container", runner: mock)
        try DeleteCommand.run(name: resolved.containerName, runtime: runtime)
        try MiniTest.expect(mock.calls.contains {
            $0.arguments.starts(with: ["delete"]) && $0.arguments.contains(resolved.containerName)
        })
    }),
    ("inspectAfterUpShape", {
        let workspace = try TestRepo.makeTempWorkspace(configJSON: #"{ "image": "alpine:3.20" }"#)
        defer { try? FileManager.default.removeItem(at: workspace) }
        let mock = MockProcessRunner()
        let resolved = try ConfigResolver.resolve(workspacePath: workspace.path, localEnv: [:])
        let entry = MockProcessRunner.containerListJSON(
            id: resolved.containerName, state: "running", labels: resolved.labels
        )
        mock.handlers = [
            { args in
                if args.starts(with: ["list"]) || args.first == "inspect" {
                    let data = try! JSONSerialization.data(withJSONObject: [entry])
                    return ProcessResult(exitCode: 0, stdout: data, stderr: Data())
                }
                return nil
            }
        ]
        let runtime = AppleContainerRuntime(executablePath: "/usr/local/bin/container", runner: mock)
        let payload = try InspectCommand.run(name: resolved.containerName, runtime: runtime)
        try MiniTest.expectEqual(payload.containerId, resolved.containerName)
        try MiniTest.expectEqual(payload.state, "running")
        try MiniTest.expectEqual(payload.labels[ContainerIdentity.labelConfigHash], resolved.configHash)
        try MiniTest.expectEqual(payload.remoteWorkspaceFolder, resolved.config.workspaceFolder)
        try MiniTest.expectEqual(payload.workspacePath, resolved.workspacePath)
        try MiniTest.expectEqual(payload.configPath, resolved.configPath)
        try MiniTest.expect(payload.portsAttributes.isEmpty)
    }),
    ("deleteMissingErrors", {
        let mock = MockProcessRunner()
        mock.handlers = [
            { args in
                if args.starts(with: ["list"]) {
                    let data = try! JSONSerialization.data(withJSONObject: [] as [Any])
                    return ProcessResult(exitCode: 0, stdout: data, stderr: Data())
                }
                return nil
            }
        ]
        let runtime = AppleContainerRuntime(executablePath: "/usr/local/bin/container", runner: mock)
        try MiniTest.expectThrows({
            try DeleteCommand.run(name: "adev-missing", runtime: runtime)
        }) { error in
            try MiniTest.expectEqual((error as! CLIError).code, CLIErrorCode.containerNotFound)
        }
    }),
    ("pruneDeletesContainerVolumesImageInOrder", {
        let workspace = try TestRepo.makeTempWorkspace(configJSON: """
        {
          "image": "alpine:3.20",
          "mounts": [
            { "source": "vol-a", "target": "/a", "type": "volume" },
            { "source": "/tmp", "target": "/host-tmp", "type": "bind" },
            { "source": "vol-b", "target": "/b", "type": "volume" }
          ]
        }
        """)
        defer { try? FileManager.default.removeItem(at: workspace) }
        let mock = MockProcessRunner()
        let resolved = try ConfigResolver.resolve(workspacePath: workspace.path, localEnv: [:])
        try MiniTest.expectEqual(
            resolved.labels[ContainerIdentity.labelConfigVolumes],
            "vol-a,vol-b"
        )
        let entry = MockProcessRunner.containerListJSON(
            id: resolved.containerName, state: "stopped", labels: resolved.labels,
            image: "alpine:3.20"
        )
        let volumeList: [[String: Any]] = [
            ["id": "vol-a"],
            ["id": "vol-b"]
        ]
        let volumeListData = try JSONSerialization.data(withJSONObject: volumeList)
        mock.handlers = [
            { args in
                if args.starts(with: ["list"]) {
                    let data = try! JSONSerialization.data(withJSONObject: [entry])
                    return ProcessResult(exitCode: 0, stdout: data, stderr: Data())
                }
                if args.first == "delete" {
                    return ProcessResult(exitCode: 0, stdout: Data(), stderr: Data())
                }
                if args == ["volume", "list", "--format", "json"] {
                    return ProcessResult(exitCode: 0, stdout: volumeListData, stderr: Data())
                }
                if args.starts(with: ["volume", "delete"]) {
                    return ProcessResult(exitCode: 0, stdout: Data(), stderr: Data())
                }
                if args.starts(with: ["image", "delete"]) || args.starts(with: ["image", "rm"]) {
                    return ProcessResult(exitCode: 0, stdout: Data(), stderr: Data())
                }
                return nil
            }
        ]
        let runtime = AppleContainerRuntime(executablePath: "/usr/local/bin/container", runner: mock)
        let code = try PruneCommand.run(name: resolved.containerName, runtime: runtime)
        try MiniTest.expect(code == 0)

        let argSeq = mock.calls.map(\.arguments)
        let deleteIdx = argSeq.firstIndex { $0.first == "delete" && $0.contains(resolved.containerName) }
        let volAIdx = argSeq.firstIndex { $0 == ["volume", "delete", "vol-a"] }
        let volBIdx = argSeq.firstIndex { $0 == ["volume", "delete", "vol-b"] }
        let imageIdx = argSeq.firstIndex {
            $0 == ["image", "delete", "alpine:3.20"] || $0 == ["image", "rm", "alpine:3.20"]
        }
        try MiniTest.expect(deleteIdx != nil)
        try MiniTest.expect(volAIdx != nil)
        try MiniTest.expect(volBIdx != nil)
        try MiniTest.expect(imageIdx != nil)
        try MiniTest.expect(deleteIdx! < volAIdx!)
        try MiniTest.expect(volAIdx! < volBIdx!)
        try MiniTest.expect(volBIdx! < imageIdx!)
        // Bind mounts must not trigger volume delete
        try MiniTest.expect(!argSeq.contains { $0.starts(with: ["volume", "delete"]) && $0.contains("/tmp") })
    }),
    ("pruneSkipsRecoveryHelperAndReferencedResources", {
        let labels: [String: String] = [
            ContainerIdentity.labelManaged: ContainerIdentity.managedValue,
            ContainerIdentity.labelWorkspaceMode: ContainerIdentity.workspaceModeVolume,
            ContainerIdentity.labelWorkspaceVolume: "adev-repo-ws",
            ContainerIdentity.labelConfigVolumes: "config-a,config-b",
            RecoveryHelper.recoveryMarkerLabel: RecoveryHelper.recoveryMarkerValue,
            RecoveryHelper.recoverySessionLabel: "prune-session"
        ]
        let entry = MockProcessRunner.containerListJSON(
            id: "recovery-helper",
            state: "running",
            labels: labels,
            image: RecoveryHelper.helperImageReference
        )
        let mock = MockProcessRunner()
        mock.handlers = [{ args in
            guard args.starts(with: ["list"]) else { return nil }
            return ProcessResult(
                exitCode: 0,
                stdout: try! JSONSerialization.data(withJSONObject: [entry]),
                stderr: Data()
            )
        }]
        let runtime = AppleContainerRuntime(executablePath: "/usr/local/bin/container", runner: mock)
        try MiniTest.expectEqual(
            try PruneCommand.run(name: "recovery-helper", runtime: runtime),
            0
        )
        try MiniTest.expect(
            !mock.calls.contains { call in
                ["delete", "volume", "image"].contains(call.arguments.first ?? "")
            },
            "prune does not delete the helper, referenced volumes, or image"
        )

        let deleteMock = MockProcessRunner()
        deleteMock.handlers = [{ args in
            if args.starts(with: ["list"]) {
                return ProcessResult(
                    exitCode: 0,
                    stdout: try! JSONSerialization.data(withJSONObject: [entry]),
                    stderr: Data()
                )
            }
            return nil
        }]
        let deleteRuntime = AppleContainerRuntime(executablePath: "/usr/local/bin/container", runner: deleteMock)
        try DeleteCommand.run(name: "recovery-helper", runtime: deleteRuntime)
        try MiniTest.expect(deleteMock.calls.contains { $0.arguments.first == "delete" })
    }),
    ("pruneMissingManagedErrors", {
        let mock = MockProcessRunner()
        mock.handlers = [
            { args in
                if args.starts(with: ["list"]) {
                    let data = try! JSONSerialization.data(withJSONObject: [] as [Any])
                    return ProcessResult(exitCode: 0, stdout: data, stderr: Data())
                }
                return nil
            }
        ]
        let runtime = AppleContainerRuntime(executablePath: "/usr/local/bin/container", runner: mock)
        try MiniTest.expectThrows({
            _ = try PruneCommand.run(name: "adev-missing", runtime: runtime)
        }) { error in
            try MiniTest.expectEqual((error as! CLIError).code, CLIErrorCode.containerNotFound)
        }
    })
]

nonisolated(unsafe) let phase1Tests: [(String, () throws -> Void)] = [
    ("envUserWorkspaceFolderOnCreateRequest", {
        let root = TestRepo.root()
        let fixture = root.appendingPathComponent("Tests/Fixtures/env-user.json")
        let ws = FileManager.default.temporaryDirectory
            .appendingPathComponent("p1-\(UUID().uuidString)", isDirectory: true)
        let dc = ws.appendingPathComponent(".devcontainer", isDirectory: true)
        try FileManager.default.createDirectory(at: dc, withIntermediateDirectories: true)
        try Data(contentsOf: fixture).write(to: dc.appendingPathComponent("devcontainer.json"))
        defer { try? FileManager.default.removeItem(at: ws) }
        let resolved = try ConfigResolver.resolve(
            workspacePath: ws.path, localEnv: ["HOME": "/Users/test"]
        )
        try MiniTest.expectEqual(resolved.config.remoteUser, "vscode")
        try MiniTest.expectEqual(resolved.config.effectiveUser, "vscode")
        try MiniTest.expectEqual(
            resolved.config.workspaceFolder,
            "/workspaces/\(ws.lastPathComponent)"
        )
        try MiniTest.expectEqual(resolved.config.containerEnv["ENVIRONMENT"], "Development")
        try MiniTest.expectEqual(
            resolved.config.containerEnv["WORKSPACE_BASENAME"],
            ws.lastPathComponent
        )
        let request = CreateRequest.from(
            resolved: resolved.config,
            identityName: resolved.containerName,
            labels: resolved.labels,
            configHash: resolved.configHash,
            workspacePath: resolved.workspacePath
        )
        let args = request.createArguments()
        try MiniTest.expect(args.contains("ENVIRONMENT=Development"))
        try MiniTest.expect(args.contains("vscode"))
        try MiniTest.expect(args.contains(resolved.config.workspaceFolder))
    })
]

nonisolated(unsafe) let phase2Tests: [(String, () throws -> Void)] = [
    ("mountStringAndObjectForms", {
        let stringMount = try MountParser.parseOne(
            "source=/Users/me/.kube/config,target=/home/vscode/.kube/config,type=bind,readonly"
        )
        try MiniTest.expectEqual(stringMount.type, .bind)
        try MiniTest.expectEqual(stringMount.source, "/Users/me/.kube/config")
        try MiniTest.expect(stringMount.readonly)
        let vol = try MountParser.parseOne([
            "source": "opencode-config",
            "target": "/home/vscode/.config/opencode",
            "type": "volume"
        ] as [String: Any])
        try MiniTest.expectEqual(vol.type, .volume)
        try MiniTest.expectEqual(vol.source, "opencode-config")
    }),
    ("phase2FixtureMountsAndPorts", {
        let root = TestRepo.root()
        let fixture = root.appendingPathComponent("Tests/Fixtures/mounts-ports.json")
        let ws = FileManager.default.temporaryDirectory
            .appendingPathComponent("p2-\(UUID().uuidString)", isDirectory: true)
        let home = FileManager.default.temporaryDirectory
            .appendingPathComponent("p2-home-\(UUID().uuidString)", isDirectory: true)
        let kube = home.appendingPathComponent(".kube", isDirectory: true)
        let dc = ws.appendingPathComponent(".devcontainer", isDirectory: true)
        try FileManager.default.createDirectory(at: dc, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: kube, withIntermediateDirectories: true)
        try Data(contentsOf: fixture).write(to: dc.appendingPathComponent("devcontainer.json"))
        defer {
            try? FileManager.default.removeItem(at: ws)
            try? FileManager.default.removeItem(at: home)
        }
        let resolved = try ConfigResolver.resolve(
            workspacePath: ws.path, localEnv: ["HOME": home.path]
        )
        try MiniTest.expectEqual(resolved.config.mounts.count, 4)
        try MiniTest.expect(resolved.config.mounts.contains { $0.type == .bind && $0.readonly })
        try MiniTest.expect(resolved.config.forwardPorts.contains(14200))
        try MiniTest.expectEqual(
            resolved.config.portsAttributes["14200"]?["label"],
            "PlantSuite Portal"
        )
        let request = CreateRequest.from(
            resolved: resolved.config,
            identityName: resolved.containerName,
            labels: resolved.labels,
            configHash: resolved.configHash,
            workspacePath: resolved.workspacePath
        )
        let args = request.createArguments()
        try MiniTest.expect(args.contains("14200:14200"))
        try MiniTest.expect(args.contains(where: {
            $0.contains("type=bind") && $0.contains("source=\(kube.path)")
                && $0.contains("target=/home/vscode/.kube")
        }))
        try MiniTest.expect(resolved.mountPromotions.isEmpty)
    }),
    ("fileBindPromotesToParentDirectory", {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("bind-\(UUID().uuidString)", isDirectory: true)
        let kubeDir = root.appendingPathComponent(".kube", isDirectory: true)
        try FileManager.default.createDirectory(at: kubeDir, withIntermediateDirectories: true)
        let configFile = kubeDir.appendingPathComponent("config")
        try Data("k".utf8).write(to: configFile)
        defer { try? FileManager.default.removeItem(at: root) }

        let fileMount = MountSpec(
            type: .bind,
            source: configFile.path,
            target: "/home/vscode/.kube/config",
            readonly: true
        )
        let dirMount = MountSpec(
            type: .bind,
            source: kubeDir.path,
            target: "/home/vscode/.kube",
            readonly: false
        )
        let volume = MountSpec(type: .volume, source: "data", target: "/data")
        let missingFile = MountSpec(
            type: .bind,
            source: kubeDir.appendingPathComponent("missing-config").path,
            target: "/home/vscode/.kube/missing-config",
            readonly: false
        )

        let (normalized, promotions) = MountNormalizer.normalize(
            mounts: [fileMount, dirMount, volume, missingFile],
            fileManager: .default
        )
        try MiniTest.expectEqual(normalized.count, 4)
        try MiniTest.expectEqual(normalized[0].source, kubeDir.path)
        try MiniTest.expectEqual(normalized[0].target, "/home/vscode/.kube")
        try MiniTest.expect(normalized[0].readonly)
        try MiniTest.expectEqual(normalized[1], dirMount)
        try MiniTest.expectEqual(normalized[2], volume)
        try MiniTest.expectEqual(normalized[3].source, kubeDir.path)
        try MiniTest.expectEqual(normalized[3].target, "/home/vscode/.kube")
        try MiniTest.expectEqual(promotions.count, 2)
        try MiniTest.expectEqual(promotions[0].from, fileMount)
        try MiniTest.expectEqual(promotions[1].from, missingFile)
        let warning = MountNormalizer.warningMessage(promotions: promotions)
        try MiniTest.expect(warning.contains("binding parent directories"))
        try MiniTest.expect(warning.contains(configFile.path))
        try MiniTest.expect(warning.contains("became:"))
    }),
    ("inspectFromLabelsEmptyPortsAttributes", {
        let ws = try TestRepo.makeTempWorkspace(configJSON: """
        {
          "image": "alpine:3.20",
          "remoteUser": "vscode",
          "workspaceFolder": "/workspaces/app",
          "forwardPorts": [8080],
          "portsAttributes": { "8080": { "label": "Web" } }
        }
        """)
        defer { try? FileManager.default.removeItem(at: ws) }
        let resolved = try ConfigResolver.resolve(workspacePath: ws.path, localEnv: [:])
        let mock = MockProcessRunner()
        let entry = MockProcessRunner.containerListJSON(
            id: resolved.containerName, state: "running", labels: resolved.labels
        )
        mock.handlers = [
            { args in
                if args.starts(with: ["list"]) || args.first == "inspect" {
                    let data = try! JSONSerialization.data(withJSONObject: [entry])
                    return ProcessResult(exitCode: 0, stdout: data, stderr: Data())
                }
                return nil
            }
        ]
        let runtime = AppleContainerRuntime(executablePath: "/usr/local/bin/container", runner: mock)
        let payload = try InspectCommand.run(name: resolved.containerName, runtime: runtime)
        // v1: portsAttributes not stored on labels
        try MiniTest.expect(payload.portsAttributes.isEmpty)
        try MiniTest.expectEqual(payload.remoteUser, "vscode")
        try MiniTest.expectEqual(payload.remoteWorkspaceFolder, "/workspaces/app")
        try MiniTest.expectEqual(
            payload.labels[ContainerIdentity.labelManaged],
            ContainerIdentity.managedValue
        )
        try MiniTest.expectEqual(
            payload.labels[ContainerIdentity.labelWorkspaceMode],
            ContainerIdentity.workspaceModeBind
        )
    })
]

nonisolated(unsafe) let phase3Tests: [(String, () throws -> Void)] = [
    ("postCreateSuccess", {
        let ws = try TestRepo.makeTempWorkspace(configJSON: """
        { "image": "alpine:3.20", "postCreateCommand": "echo ok" }
        """)
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
                    return ProcessResult(exitCode: 0, stdout: Data("ok\n".utf8), stderr: Data())
                }
                return ProcessResult(exitCode: 0, stdout: Data(), stderr: Data())
            }
        ]
        let runtime = AppleContainerRuntime(executablePath: "/usr/local/bin/container", runner: mock)
        let result = try UpCommand.run(
            options: UpOptions(workspacePath: ws.path, skipPull: true),
            runtime: runtime,
            localEnv: [:]
        )
        try MiniTest.expectEqual(result.outcome, "success")
        try MiniTest.expect(mock.calls.contains { $0.arguments.first == "exec" })
    }),
    ("postCreateFailureFailsUp", {
        let ws = try TestRepo.makeTempWorkspace(configJSON: """
        { "image": "alpine:3.20", "postCreateCommand": "exit 7" }
        """)
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
                    return ProcessResult(exitCode: 7, stdout: Data(), stderr: Data("failed\n".utf8))
                }
                return ProcessResult(exitCode: 0, stdout: Data(), stderr: Data())
            }
        ]
        let runtime = AppleContainerRuntime(executablePath: "/usr/local/bin/container", runner: mock)
        try MiniTest.expectThrows({
            _ = try UpCommand.run(
                options: UpOptions(workspacePath: ws.path, skipPull: true),
                runtime: runtime,
                localEnv: [:]
            )
        }) { error in
            let err = error as! CLIError
            try MiniTest.expectEqual(err.code, CLIErrorCode.postCreateFailed)
            try MiniTest.expect(err.message.contains("7"))
        }
        try MiniTest.expect(mock.calls.contains {
            $0.arguments.first == "delete" && $0.arguments.contains(resolved.containerName)
        })
    }),
    ("postCreateFailureDoesNotReuseOnSecondUp", {
        let ws = try TestRepo.makeTempWorkspace(configJSON: """
        { "image": "alpine:3.20", "postCreateCommand": "exit 7" }
        """)
        defer { try? FileManager.default.removeItem(at: ws) }
        let resolved = try ConfigResolver.resolve(workspacePath: ws.path, localEnv: [:])
        let mock = MockProcessRunner()
        // Simulates: container exists only between create and delete-on-postCreate-fail.
        var alive = false
        let entry = MockProcessRunner.containerListJSON(
            id: resolved.containerName, state: "running", labels: resolved.labels
        )
        mock.handlers = [
            { args in
                if args.starts(with: ["list"]) {
                    let payload: [Any] = alive ? [entry] : []
                    let data = try! JSONSerialization.data(withJSONObject: payload)
                    return ProcessResult(exitCode: 0, stdout: data, stderr: Data())
                }
                if args.first == "create" {
                    alive = true
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
                    return ProcessResult(exitCode: 7, stdout: Data(), stderr: Data("failed\n".utf8))
                }
                if args.first == "delete" {
                    alive = false
                    return ProcessResult(exitCode: 0, stdout: Data(), stderr: Data())
                }
                return ProcessResult(exitCode: 0, stdout: Data(), stderr: Data())
            }
        ]
        let runtime = AppleContainerRuntime(executablePath: "/usr/local/bin/container", runner: mock)
        try MiniTest.expectThrows({
            _ = try UpCommand.run(
                options: UpOptions(workspacePath: ws.path, skipPull: true),
                runtime: runtime,
                localEnv: [:]
            )
        }) { error in
            try MiniTest.expectEqual((error as! CLIError).code, CLIErrorCode.postCreateFailed)
        }
        try MiniTest.expect(!alive)

        // Second up must not return success-via-reuse; it re-enters create and fails postCreate again.
        let createCountBefore = mock.calls.filter { $0.arguments.first == "create" }.count
        try MiniTest.expectThrows({
            _ = try UpCommand.run(
                options: UpOptions(workspacePath: ws.path, skipPull: true),
                runtime: runtime,
                localEnv: [:]
            )
        }) { error in
            try MiniTest.expectEqual((error as! CLIError).code, CLIErrorCode.postCreateFailed)
        }
        let createCountAfter = mock.calls.filter { $0.arguments.first == "create" }.count
        try MiniTest.expectEqual(createCountAfter, createCountBefore + 1)
    }),
    ("postCreateArgvForm", {
        let cmd: LifecycleCommand = .argv(["echo", "hi"])
        try MiniTest.expectEqual(cmd.execArguments, ["echo", "hi"])
        let shell: LifecycleCommand = .shell("echo hi")
        try MiniTest.expectEqual(shell.execArguments, ["sh", "-lc", "echo hi"])
    }),
    ("phase3FixtureParses", {
        let root = TestRepo.root()
        let fixture = root.appendingPathComponent("Tests/Fixtures/lifecycle.json")
        let ws = FileManager.default.temporaryDirectory
            .appendingPathComponent("p3-\(UUID().uuidString)", isDirectory: true)
        let dc = ws.appendingPathComponent(".devcontainer", isDirectory: true)
        try FileManager.default.createDirectory(at: dc, withIntermediateDirectories: true)
        try Data(contentsOf: fixture).write(to: dc.appendingPathComponent("devcontainer.json"))
        defer { try? FileManager.default.removeItem(at: ws) }
        let resolved = try ConfigResolver.resolve(
            workspacePath: ws.path, localEnv: ["HOME": "/Users/test"]
        )
        guard case .shell(let s) = resolved.config.postCreateCommand else {
            throw MiniTest.Failure(message: "expected shell postCreate")
        }
        try MiniTest.expect(s.contains("postCreate-ok"))
    })
]

// MARK: - up lifecycle matrix

private enum LifecycleUpSupport {
    static let fullHooksJSON = """
    {
      "image": "alpine:3.20",
      "onCreateCommand": "echo onCreate",
      "updateContentCommand": "echo updateContent",
      "postCreateCommand": "echo postCreate",
      "postStartCommand": "echo postStart"
    }
    """

    static func execBodies(_ args: [String]) -> [String] {
        // exec argv: exec [flags...] containerId cmd...
        // Find sh -lc <body> or bare tokens after container id.
        if let lc = args.firstIndex(of: "-lc"), lc + 1 < args.count {
            return [args[lc + 1]]
        }
        // argv form: last non-flag tokens after container name — return joined for matching
        return args
    }

    static func mockFreshCreate(
        resolved: ResolvedWorkspace,
        execHandler: @escaping ([String]) -> ProcessResult = { _ in
            ProcessResult(exitCode: 0, stdout: Data(), stderr: Data())
        }
    ) -> MockProcessRunner {
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
                    return execHandler(args)
                }
                if args.first == "delete" {
                    return ProcessResult(exitCode: 0, stdout: Data(), stderr: Data())
                }
                return ProcessResult(exitCode: 0, stdout: Data(), stderr: Data())
            }
        ]
        return mock
    }
}

nonisolated(unsafe) let phase4CommandTests: [(String, () throws -> Void)] = [
    ("freshCreateRunsFullHookOrder", {
        let ws = try TestRepo.makeTempWorkspace(configJSON: LifecycleUpSupport.fullHooksJSON)
        defer { try? FileManager.default.removeItem(at: ws) }
        let resolved = try ConfigResolver.resolve(workspacePath: ws.path, localEnv: [:])
        var execBodies: [String] = []
        let mock = LifecycleUpSupport.mockFreshCreate(resolved: resolved) { args in
            if let lc = args.firstIndex(of: "-lc"), lc + 1 < args.count {
                execBodies.append(args[lc + 1])
            }
            return ProcessResult(exitCode: 0, stdout: Data(), stderr: Data())
        }
        let runtime = AppleContainerRuntime(executablePath: "/usr/local/bin/container", runner: mock)
        let result = try UpCommand.run(
            options: UpOptions(workspacePath: ws.path, skipPull: true),
            runtime: runtime,
            localEnv: [:],
            hostResources: MockHostResourceInfo(physicalMemoryBytes: 64 << 30, cpuCount: 16)
        )
        try MiniTest.expectEqual(result.outcome, "success")
        try MiniTest.expectEqual(execBodies, [
            "echo onCreate",
            "echo updateContent",
            "echo postCreate",
            "echo postStart"
        ])
    }),
    ("reuseRunningSkipsLifecycle", {
        let ws = try TestRepo.makeTempWorkspace(configJSON: LifecycleUpSupport.fullHooksJSON)
        defer { try? FileManager.default.removeItem(at: ws) }
        let resolved = try ConfigResolver.resolve(workspacePath: ws.path, localEnv: [:])
        let entry = MockProcessRunner.containerListJSON(
            id: resolved.containerName, state: "running", labels: resolved.labels
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
        let runtime = AppleContainerRuntime(executablePath: "/usr/local/bin/container", runner: mock)
        let result = try UpCommand.run(
            options: UpOptions(workspacePath: ws.path, skipPull: true),
            runtime: runtime,
            localEnv: [:]
        )
        try MiniTest.expectEqual(result.outcome, "success")
        try MiniTest.expect(!mock.calls.contains { $0.arguments.first == "exec" })
        try MiniTest.expect(!mock.calls.contains { $0.arguments.first == "create" })
    }),
    ("startStoppedRunsPostStartOnly", {
        let ws = try TestRepo.makeTempWorkspace(configJSON: LifecycleUpSupport.fullHooksJSON)
        defer { try? FileManager.default.removeItem(at: ws) }
        let resolved = try ConfigResolver.resolve(workspacePath: ws.path, localEnv: [:])
        let entry = MockProcessRunner.containerListJSON(
            id: resolved.containerName, state: "stopped", labels: resolved.labels
        )
        var execBodies: [String] = []
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
                    if let lc = args.firstIndex(of: "-lc"), lc + 1 < args.count {
                        execBodies.append(args[lc + 1])
                    }
                    return ProcessResult(exitCode: 0, stdout: Data(), stderr: Data())
                }
                return nil
            }
        ]
        let runtime = AppleContainerRuntime(executablePath: "/usr/local/bin/container", runner: mock)
        let result = try UpCommand.run(
            options: UpOptions(workspacePath: ws.path, skipPull: true),
            runtime: runtime,
            localEnv: [:]
        )
        try MiniTest.expectEqual(result.outcome, "success")
        try MiniTest.expectEqual(execBodies, ["echo postStart"])
        try MiniTest.expect(!mock.calls.contains { $0.arguments.first == "create" })
    }),
    ("createPathHookFailureDeletesContainer", {
        let ws = try TestRepo.makeTempWorkspace(configJSON: """
        {
          "image": "alpine:3.20",
          "onCreateCommand": "exit 9",
          "postCreateCommand": "echo should-not-run"
        }
        """)
        defer { try? FileManager.default.removeItem(at: ws) }
        let resolved = try ConfigResolver.resolve(workspacePath: ws.path, localEnv: [:])
        let mock = LifecycleUpSupport.mockFreshCreate(resolved: resolved) { _ in
            ProcessResult(exitCode: 9, stdout: Data(), stderr: Data("boom\n".utf8))
        }
        let runtime = AppleContainerRuntime(executablePath: "/usr/local/bin/container", runner: mock)
        try MiniTest.expectThrows({
            _ = try UpCommand.run(
                options: UpOptions(workspacePath: ws.path, skipPull: true),
                runtime: runtime,
                localEnv: [:]
            )
        }) { error in
            let err = error as! CLIError
            try MiniTest.expectEqual(err.code, CLIErrorCode.lifecycleFailed)
            try MiniTest.expectEqual(err.property, "onCreateCommand")
            try MiniTest.expect(err.message.contains("9"))
        }
        try MiniTest.expect(mock.calls.contains {
            $0.arguments.first == "delete" && $0.arguments.contains(resolved.containerName)
        })
    }),
    ("createPathPostStartFailureDeletesContainer", {
        let ws = try TestRepo.makeTempWorkspace(configJSON: """
        {
          "image": "alpine:3.20",
          "postStartCommand": "exit 3"
        }
        """)
        defer { try? FileManager.default.removeItem(at: ws) }
        let resolved = try ConfigResolver.resolve(workspacePath: ws.path, localEnv: [:])
        let mock = LifecycleUpSupport.mockFreshCreate(resolved: resolved) { _ in
            ProcessResult(exitCode: 3, stdout: Data(), stderr: Data())
        }
        let runtime = AppleContainerRuntime(executablePath: "/usr/local/bin/container", runner: mock)
        try MiniTest.expectThrows({
            _ = try UpCommand.run(
                options: UpOptions(workspacePath: ws.path, skipPull: true),
                runtime: runtime,
                localEnv: [:]
            )
        }) { error in
            let err = error as! CLIError
            try MiniTest.expectEqual(err.code, CLIErrorCode.lifecycleFailed)
            try MiniTest.expectEqual(err.property, "postStartCommand")
        }
        try MiniTest.expect(mock.calls.contains {
            $0.arguments.first == "delete" && $0.arguments.contains(resolved.containerName)
        })
    }),
    ("restartPostStartFailureDoesNotDelete", {
        let ws = try TestRepo.makeTempWorkspace(configJSON: """
        {
          "image": "alpine:3.20",
          "postStartCommand": "exit 5"
        }
        """)
        defer { try? FileManager.default.removeItem(at: ws) }
        let resolved = try ConfigResolver.resolve(workspacePath: ws.path, localEnv: [:])
        let entry = MockProcessRunner.containerListJSON(
            id: resolved.containerName, state: "stopped", labels: resolved.labels
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
                    return ProcessResult(exitCode: 5, stdout: Data(), stderr: Data("fail\n".utf8))
                }
                if args.first == "delete" {
                    return ProcessResult(exitCode: 0, stdout: Data(), stderr: Data())
                }
                return nil
            }
        ]
        let runtime = AppleContainerRuntime(executablePath: "/usr/local/bin/container", runner: mock)
        try MiniTest.expectThrows({
            _ = try UpCommand.run(
                options: UpOptions(workspacePath: ws.path, skipPull: true),
                runtime: runtime,
                localEnv: [:]
            )
        }) { error in
            let err = error as! CLIError
            try MiniTest.expectEqual(err.code, CLIErrorCode.lifecycleFailed)
            try MiniTest.expectEqual(err.property, "postStartCommand")
        }
        try MiniTest.expect(!mock.calls.contains { $0.arguments.first == "delete" })
    }),
    ("postAttachAdmittedButNotRunOnUp", {
        // Capture StatusPrinter by temporarily enabling and... we can't easily capture stderr.
        // Verify: postAttach body never appears in exec; up succeeds even if postAttach would fail.
        let ws = try TestRepo.makeTempWorkspace(configJSON: """
        {
          "image": "alpine:3.20",
          "postAttachCommand": "exit 99",
          "postCreateCommand": "echo postCreate"
        }
        """)
        defer { try? FileManager.default.removeItem(at: ws) }
        let resolved = try ConfigResolver.resolve(workspacePath: ws.path, localEnv: [:])
        try MiniTest.expect(resolved.config.postAttachCommand != nil)
        var execBodies: [String] = []
        let mock = LifecycleUpSupport.mockFreshCreate(resolved: resolved) { args in
            if let lc = args.firstIndex(of: "-lc"), lc + 1 < args.count {
                execBodies.append(args[lc + 1])
            }
            return ProcessResult(exitCode: 0, stdout: Data(), stderr: Data())
        }
        let runtime = AppleContainerRuntime(executablePath: "/usr/local/bin/container", runner: mock)
        let result = try UpCommand.run(
            options: UpOptions(workspacePath: ws.path, skipPull: true),
            runtime: runtime,
            localEnv: [:]
        )
        try MiniTest.expectEqual(result.outcome, "success")
        try MiniTest.expectEqual(execBodies, ["echo postCreate"])
        try MiniTest.expect(!execBodies.contains(where: { $0.contains("exit 99") }))
        // postAttach skip goes through StatusPrinter (enabled=false in suite); property admitted
        // and not executed is the behavioral contract under test.
        try MiniTest.expect(resolved.config.postAttachCommand != nil)
    }),
    ("createThenReuseStableWithHooks", {
        let ws = try TestRepo.makeTempWorkspace(configJSON: LifecycleUpSupport.fullHooksJSON)
        defer { try? FileManager.default.removeItem(at: ws) }
        let resolved = try ConfigResolver.resolve(workspacePath: ws.path, localEnv: [:])
        var alive = false
        let entry = MockProcessRunner.containerListJSON(
            id: resolved.containerName, state: "running", labels: resolved.labels
        )
        var execCount = 0
        let mock = MockProcessRunner()
        mock.handlers = [
            { args in
                if args.starts(with: ["list"]) {
                    let payload: [Any] = alive ? [entry] : []
                    let data = try! JSONSerialization.data(withJSONObject: payload)
                    return ProcessResult(exitCode: 0, stdout: data, stderr: Data())
                }
                if args.first == "create" {
                    alive = true
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
                    execCount += 1
                    return ProcessResult(exitCode: 0, stdout: Data(), stderr: Data())
                }
                return ProcessResult(exitCode: 0, stdout: Data(), stderr: Data())
            }
        ]
        let runtime = AppleContainerRuntime(executablePath: "/usr/local/bin/container", runner: mock)
        let first = try UpCommand.run(
            options: UpOptions(workspacePath: ws.path, skipPull: true),
            runtime: runtime,
            localEnv: [:]
        )
        try MiniTest.expectEqual(first.outcome, "success")
        try MiniTest.expectEqual(execCount, 4) // full hook order
        let second = try UpCommand.run(
            options: UpOptions(workspacePath: ws.path, skipPull: true),
            runtime: runtime,
            localEnv: [:]
        )
        try MiniTest.expectEqual(second.outcome, "success")
        try MiniTest.expectEqual(execCount, 4) // no additional hooks on reuse
    }),
    ("hostRequirementsShortfallFailsUp", {
        let ws = try TestRepo.makeTempWorkspace(configJSON: """
        {
          "image": "alpine:3.20",
          "hostRequirements": { "memory": "512gb", "cpus": 999 }
        }
        """)
        defer { try? FileManager.default.removeItem(at: ws) }
        let resolved = try ConfigResolver.resolve(workspacePath: ws.path, localEnv: [:])
        let mock = LifecycleUpSupport.mockFreshCreate(resolved: resolved)
        let runtime = AppleContainerRuntime(executablePath: "/usr/local/bin/container", runner: mock)
        try MiniTest.expectThrows({
            _ = try UpCommand.run(
                options: UpOptions(workspacePath: ws.path, skipPull: true),
                runtime: runtime,
                localEnv: [:],
                hostResources: MockHostResourceInfo(physicalMemoryBytes: 1 << 30, cpuCount: 1)
            )
        }) { error in
            let err = error as! CLIError
            try MiniTest.expectEqual(err.code, CLIErrorCode.hostRequirements)
            try MiniTest.expect(err.message.contains("memory") || err.message.contains("cpus"))
        }
        try MiniTest.expect(!mock.calls.contains { $0.arguments.first == "create" })
    }),
    ("hostRequirementsEnoughSucceedsWithCreateLimits", {
        let ws = try TestRepo.makeTempWorkspace(configJSON: """
        {
          "image": "alpine:3.20",
          "hostRequirements": { "memory": "8gb", "cpus": 2 }
        }
        """)
        defer { try? FileManager.default.removeItem(at: ws) }
        let resolved = try ConfigResolver.resolve(workspacePath: ws.path, localEnv: [:])
        let mock = LifecycleUpSupport.mockFreshCreate(resolved: resolved)
        let runtime = AppleContainerRuntime(executablePath: "/usr/local/bin/container", runner: mock)
        let result = try UpCommand.run(
            options: UpOptions(workspacePath: ws.path, skipPull: true),
            runtime: runtime,
            localEnv: [:],
            hostResources: MockHostResourceInfo(physicalMemoryBytes: 64 << 30, cpuCount: 16)
        )
        try MiniTest.expectEqual(result.outcome, "success")
        guard let createArgs = mock.calls.first(where: { $0.arguments.first == "create" })?.arguments else {
            throw MiniTest.Failure(message: "expected create call")
        }
        if let i = createArgs.firstIndex(of: "-m") {
            try MiniTest.expectEqual(createArgs[i + 1], "8G")
        } else {
            throw MiniTest.Failure(message: "expected -m in create argv")
        }
        if let i = createArgs.firstIndex(of: "-c") {
            try MiniTest.expectEqual(createArgs[i + 1], "2")
        } else {
            throw MiniTest.Failure(message: "expected -c in create argv")
        }
    }),
    ("hostRequirementsNoLongerSilentlyIgnored", {
        let req = try HostRequirements.parse(["memory": "8gb"] as [String: Any])!
        let host = MockHostResourceInfo(physicalMemoryBytes: 1 << 30, cpuCount: 8)
        let eval = HostRequirementsEvaluation.evaluate(req, host: host)
        try MiniTest.expect(eval.hasHardFailures)
        try MiniTest.expect(eval.hardFailures.contains { $0.contains("memory") })
    })
]

// MARK: - Features up path

/// Shared mock plumbing for Features create-path tests (build succeeds, no real Rosetta config).
private enum FeaturesUpTestSupport {
    static func installOverrides(fetcher: MockFeatureFetcher, cache: String) -> () -> Void {
        let previousFetcher = UpCommand.featuresFetcherOverride
        let previousCache = UpCommand.featuresCacheRootOverride
        let previousEnsure = UpCommand.ensureNativeArmBuildOverride
        UpCommand.featuresFetcherOverride = fetcher
        UpCommand.featuresCacheRootOverride = cache
        UpCommand.ensureNativeArmBuildOverride = { /* no-op: already native in tests */ }
        return {
            UpCommand.featuresFetcherOverride = previousFetcher
            UpCommand.featuresCacheRootOverride = previousCache
            UpCommand.ensureNativeArmBuildOverride = previousEnsure
        }
    }

    static func mockHandler(
        createId: String = "ctr",
        onBuild: (([String]) -> ProcessResult)? = nil,
        onExec: (([String]) -> ProcessResult)? = nil
    ) -> ([String]) -> ProcessResult? {
        { args in
            if args.starts(with: ["list"]) {
                let data = try! JSONSerialization.data(withJSONObject: [] as [Any])
                return ProcessResult(exitCode: 0, stdout: data, stderr: Data())
            }
            if args.starts(with: ["image", "inspect"]) || args.starts(with: ["image", "list"]) {
                return ProcessResult(exitCode: 1, stdout: Data(), stderr: Data("missing".utf8))
            }
            if args.first == "build" {
                if let onBuild { return onBuild(args) }
                if args.contains("--rosetta") {
                    return ProcessResult(exitCode: 99, stdout: Data(), stderr: Data("unexpected rosetta".utf8))
                }
                return ProcessResult(exitCode: 0, stdout: Data(), stderr: Data())
            }
            if args.first == "create" {
                if args.contains("--rosetta") {
                    return ProcessResult(exitCode: 99, stdout: Data(), stderr: Data("unexpected rosetta".utf8))
                }
                return ProcessResult(exitCode: 0, stdout: Data("\(createId)\n".utf8), stderr: Data())
            }
            if args.first == "start" || args.first == "delete" {
                return ProcessResult(exitCode: 0, stdout: Data(), stderr: Data())
            }
            if args.first == "exec" {
                if let onExec { return onExec(args) }
                return ProcessResult(exitCode: 0, stdout: Data(), stderr: Data())
            }
            return ProcessResult(exitCode: 0, stdout: Data(), stderr: Data())
        }
    }
}

nonisolated(unsafe) let featuresCommandTests: [(String, () throws -> Void)] = [
    ("upWithFeaturesBuildsThenHooks", {
        let ref = "ghcr.io/adevcontainer/features/sample-a:1"
        let fixture = TestRepo.root()
            .appendingPathComponent("Tests/Fixtures/features-sample/sample-a").path
        let cache = FileManager.default.temporaryDirectory
            .appendingPathComponent("feat-up-\(UUID().uuidString)", isDirectory: true).path
        defer { try? FileManager.default.removeItem(atPath: cache) }

        let ws = try TestRepo.makeTempWorkspace(configJSON: """
        {
          "image": "alpine:3.20",
          "features": {
            "\(ref)": { "greeting": "hi" }
          },
          "onCreateCommand": "echo config-onCreate"
        }
        """)
        defer { try? FileManager.default.removeItem(at: ws) }

        let restore = FeaturesUpTestSupport.installOverrides(
            fetcher: MockFeatureFetcher(packagesByRef: [ref: fixture]),
            cache: cache
        )
        defer { restore() }

        let mock = MockProcessRunner()
        var imageInCreate: String?
        var createHadPlatform = false
        var buildHadPlatform = false
        mock.handlers = [
            FeaturesUpTestSupport.mockHandler(
                onBuild: { args in
                    if let pIdx = args.firstIndex(of: "--platform"), pIdx + 1 < args.count {
                        buildHadPlatform = args[pIdx + 1].hasPrefix("linux/")
                    }
                    if args.contains("--rosetta") {
                        return ProcessResult(exitCode: 99, stdout: Data(), stderr: Data("no rosetta".utf8))
                    }
                    return ProcessResult(exitCode: 0, stdout: Data(), stderr: Data())
                }
            )
        ]
        // Wrap create capture
        let baseHandler = mock.handlers[0]
        mock.handlers = [
            { args in
                if args.first == "create" {
                    if let pIdx = args.firstIndex(of: "--platform"), pIdx + 1 < args.count {
                        createHadPlatform = args[pIdx + 1].hasPrefix("linux/")
                    }
                    if let sleepIdx = args.firstIndex(of: "/bin/sleep"), sleepIdx + 1 < args.count {
                        imageInCreate = args[sleepIdx + 1]
                    }
                }
                return baseHandler(args)
            }
        ]
        let runtime = AppleContainerRuntime(executablePath: "/usr/local/bin/container", runner: mock)
        let result = try UpCommand.run(
            options: UpOptions(workspacePath: ws.path, skipPull: true),
            runtime: runtime,
            localEnv: [:]
        )
        try MiniTest.expectEqual(result.outcome, "success")
        try MiniTest.expect(mock.calls.contains { $0.arguments.first == "build" })
        try MiniTest.expect(buildHadPlatform)
        try MiniTest.expect(mock.calls.contains { $0.arguments.first == "create" })
        try MiniTest.expect(createHadPlatform)
        // Create uses derived features image, not raw base.
        let expectedBase = ContainerIdentity.humanBase(configName: nil, workspacePath: ws.path)
        try MiniTest.expect(imageInCreate?.hasPrefix("adev-\(expectedBase):") == true)
        try MiniTest.expect(imageInCreate?.contains("/features") != true)
        // No in-container feature install on up path.
        try MiniTest.expect(!mock.calls.contains {
            ($0.arguments.first == "cp" || $0.arguments.first == "copy")
                && $0.arguments.contains(where: { $0.contains("/tmp/adev-features/") })
        })
        // Feature onCreate runs after config onCreate
        let execBodies = mock.calls.filter { $0.arguments.first == "exec" }.compactMap { call -> String? in
            let args = call.arguments
            if let lc = args.firstIndex(of: "-lc"), lc + 1 < args.count {
                return args[lc + 1]
            }
            return nil
        }
        try MiniTest.expect(execBodies.contains("echo config-onCreate"))
        try MiniTest.expect(execBodies.contains("echo feature-a-onCreate"))
    }),
    ("upWithoutFeaturesNoBuild", {
        let ws = try TestRepo.makeTempWorkspace(configJSON: #"{ "image": "alpine:3.20" }"#)
        defer { try? FileManager.default.removeItem(at: ws) }
        let resolved = try ConfigResolver.resolve(workspacePath: ws.path, localEnv: [:])
        let mock = LifecycleUpSupport.mockFreshCreate(resolved: resolved)
        let runtime = AppleContainerRuntime(executablePath: "/usr/local/bin/container", runner: mock)
        let result = try UpCommand.run(
            options: UpOptions(workspacePath: ws.path, skipPull: true),
            runtime: runtime,
            localEnv: [:]
        )
        try MiniTest.expectEqual(result.outcome, "success")
        try MiniTest.expect(!mock.calls.contains { $0.arguments.first == "build" })
        guard let createArgs = mock.calls.first(where: { $0.arguments.first == "create" })?.arguments else {
            throw MiniTest.Failure(message: "expected create")
        }
        try MiniTest.expect(createArgs.contains("alpine:3.20"))
    }),
    ("upReuseRunningNoFeatureFetch", {
        let ref = "ghcr.io/adevcontainer/features/sample-a:1"
        let fixture = TestRepo.root()
            .appendingPathComponent("Tests/Fixtures/features-sample/sample-a").path
        let cache = FileManager.default.temporaryDirectory
            .appendingPathComponent("feat-reuse-\(UUID().uuidString)", isDirectory: true).path
        defer { try? FileManager.default.removeItem(atPath: cache) }

        let ws = try TestRepo.makeTempWorkspace(configJSON: """
        {
          "image": "alpine:3.20",
          "features": { "\(ref)": {} }
        }
        """)
        defer { try? FileManager.default.removeItem(at: ws) }
        let resolved = try ConfigResolver.resolve(workspacePath: ws.path, localEnv: [:])
        let entry = MockProcessRunner.containerListJSON(
            id: resolved.containerName, state: "running", labels: resolved.labels
        )
        let mockFetch = MockFeatureFetcher(packagesByRef: [ref: fixture])
        let restore = FeaturesUpTestSupport.installOverrides(fetcher: mockFetch, cache: cache)
        defer { restore() }

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
        let runtime = AppleContainerRuntime(executablePath: "/usr/local/bin/container", runner: mock)
        let result = try UpCommand.run(
            options: UpOptions(workspacePath: ws.path, skipPull: true),
            runtime: runtime,
            localEnv: [:]
        )
        try MiniTest.expectEqual(result.outcome, "success")
        try MiniTest.expectEqual(mockFetch.fetchCalls.count, 0)
        try MiniTest.expect(!mock.calls.contains { $0.arguments.first == "build" })
        try MiniTest.expect(!mock.calls.contains { $0.arguments.first == "create" })
    }),
    ("featuresProgressLinesAndQuiet", {
        let ref = "ghcr.io/adevcontainer/features/sample-a:1"
        let fixture = TestRepo.root()
            .appendingPathComponent("Tests/Fixtures/features-sample/sample-a").path
        let cache = FileManager.default.temporaryDirectory
            .appendingPathComponent("feat-prog-\(UUID().uuidString)", isDirectory: true).path
        defer { try? FileManager.default.removeItem(atPath: cache) }

        let ws = try TestRepo.makeTempWorkspace(configJSON: """
        { "image": "alpine:3.20", "features": { "\(ref)": {} } }
        """)
        defer { try? FileManager.default.removeItem(at: ws) }

        let previousEnabled = StatusPrinter.enabled
        let restore = FeaturesUpTestSupport.installOverrides(
            fetcher: MockFeatureFetcher(packagesByRef: [ref: fixture]),
            cache: cache
        )
        defer {
            restore()
            StatusPrinter.enabled = previousEnabled
        }

        let mock = MockProcessRunner()
        mock.handlers = [FeaturesUpTestSupport.mockHandler()]
        let runtime = AppleContainerRuntime(executablePath: "/usr/local/bin/container", runner: mock)

        StatusPrinter.enabled = false
        _ = try UpCommand.run(
            options: UpOptions(workspacePath: ws.path, skipPull: true),
            runtime: runtime,
            localEnv: [:]
        )
        try MiniTest.expect(!StatusPrinter.enabled)
        try MiniTest.expect(mock.calls.contains { $0.arguments.first == "build" })

        StatusPrinter.enabled = true
        mock.handlers = [FeaturesUpTestSupport.mockHandler()]
        let ws2 = try TestRepo.makeTempWorkspace(configJSON: """
        { "image": "alpine:3.20", "features": { "\(ref)": {} } }
        """)
        defer { try? FileManager.default.removeItem(at: ws2) }
        _ = try UpCommand.run(
            options: UpOptions(workspacePath: ws2.path, skipPull: true),
            runtime: runtime,
            localEnv: [:]
        )
        try MiniTest.expect(StatusPrinter.enabled)
    }),
    ("featureBuildFailureNoCreate", {
        let ref = "ghcr.io/adevcontainer/features/sample-a:1"
        let fixture = TestRepo.root()
            .appendingPathComponent("Tests/Fixtures/features-sample/sample-a").path
        let cache = FileManager.default.temporaryDirectory
            .appendingPathComponent("feat-build-fail-\(UUID().uuidString)", isDirectory: true).path
        defer { try? FileManager.default.removeItem(atPath: cache) }

        let ws = try TestRepo.makeTempWorkspace(configJSON: """
        { "image": "alpine:3.20", "features": { "\(ref)": {} } }
        """)
        defer { try? FileManager.default.removeItem(at: ws) }

        let restore = FeaturesUpTestSupport.installOverrides(
            fetcher: MockFeatureFetcher(packagesByRef: [ref: fixture]),
            cache: cache
        )
        defer { restore() }

        let mock = MockProcessRunner()
        mock.handlers = [
            FeaturesUpTestSupport.mockHandler(
                onBuild: { _ in
                    ProcessResult(exitCode: 9, stdout: Data(), stderr: Data("build boom".utf8))
                }
            )
        ]
        let runtime = AppleContainerRuntime(executablePath: "/usr/local/bin/container", runner: mock)
        try MiniTest.expectThrows({
            _ = try UpCommand.run(
                options: UpOptions(workspacePath: ws.path, skipPull: true),
                runtime: runtime,
                localEnv: [:]
            )
        }) { error in
            let err = error as! CLIError
            try MiniTest.expectEqual(err.code, CLIErrorCode.featureBuild)
        }
        try MiniTest.expect(mock.calls.contains { $0.arguments.first == "build" })
        try MiniTest.expect(!mock.calls.contains { $0.arguments.first == "create" })
    }),
    ("upFeaturesDeclineRosettaConfigFails", {
        let ref = "ghcr.io/adevcontainer/features/sample-a:1"
        let fixture = TestRepo.root()
            .appendingPathComponent("Tests/Fixtures/features-sample/sample-a").path
        let cache = FileManager.default.temporaryDirectory
            .appendingPathComponent("feat-decline-\(UUID().uuidString)", isDirectory: true).path
        defer { try? FileManager.default.removeItem(atPath: cache) }

        let ws = try TestRepo.makeTempWorkspace(configJSON: """
        { "image": "alpine:3.20", "features": { "\(ref)": {} } }
        """)
        defer { try? FileManager.default.removeItem(at: ws) }

        let previousFetcher = UpCommand.featuresFetcherOverride
        let previousCache = UpCommand.featuresCacheRootOverride
        let previousEnsure = UpCommand.ensureNativeArmBuildOverride
        defer {
            UpCommand.featuresFetcherOverride = previousFetcher
            UpCommand.featuresCacheRootOverride = previousCache
            UpCommand.ensureNativeArmBuildOverride = previousEnsure
        }
        UpCommand.featuresFetcherOverride = MockFeatureFetcher(packagesByRef: [ref: fixture])
        UpCommand.featuresCacheRootOverride = cache
        UpCommand.ensureNativeArmBuildOverride = {
            throw CLIError(
                code: CLIErrorCode.buildRosettaConfig,
                property: "build.rosetta",
                message: "User declined setting build.rosetta=false",
                hint: "Re-run and accept"
            )
        }

        let mock = MockProcessRunner()
        mock.handlers = [{ _ in ProcessResult(exitCode: 0, stdout: Data("[]".utf8), stderr: Data()) }]
        let runtime = AppleContainerRuntime(executablePath: "/usr/local/bin/container", runner: mock)
        try MiniTest.expectThrows({
            _ = try UpCommand.run(
                options: UpOptions(workspacePath: ws.path, skipPull: true),
                runtime: runtime,
                localEnv: [:]
            )
        }) { error in
            try MiniTest.expectEqual((error as! CLIError).code, CLIErrorCode.buildRosettaConfig)
        }
        try MiniTest.expect(!mock.calls.contains { $0.arguments.first == "build" })
        try MiniTest.expect(!mock.calls.contains { $0.arguments.first == "create" })
    }),
    ("featureLifecycleHookFailureDeletesContainer", {
        let ref = "ghcr.io/adevcontainer/features/sample-a:1"
        let fixture = TestRepo.root()
            .appendingPathComponent("Tests/Fixtures/features-sample/sample-a").path
        let cache = FileManager.default.temporaryDirectory
            .appendingPathComponent("feat-fail-\(UUID().uuidString)", isDirectory: true).path
        defer { try? FileManager.default.removeItem(atPath: cache) }

        let ws = try TestRepo.makeTempWorkspace(configJSON: """
        { "image": "alpine:3.20", "features": { "\(ref)": {} } }
        """)
        defer { try? FileManager.default.removeItem(at: ws) }
        let resolved = try ConfigResolver.resolve(workspacePath: ws.path, localEnv: [:])

        let restore = FeaturesUpTestSupport.installOverrides(
            fetcher: MockFeatureFetcher(packagesByRef: [ref: fixture]),
            cache: cache
        )
        defer { restore() }

        let mock = MockProcessRunner()
        mock.handlers = [
            FeaturesUpTestSupport.mockHandler(
                createId: resolved.containerName,
                onExec: { args in
                    // Lifecycle hook fails (feature install is in image, not exec).
                    ProcessResult(exitCode: 7, stdout: Data(), stderr: Data("feat fail".utf8))
                }
            )
        ]
        let runtime = AppleContainerRuntime(executablePath: "/usr/local/bin/container", runner: mock)
        try MiniTest.expectThrows({
            _ = try UpCommand.run(
                options: UpOptions(workspacePath: ws.path, skipPull: true),
                runtime: runtime,
                localEnv: [:]
            )
        }) { error in
            let err = error as! CLIError
            try MiniTest.expect(
                err.code == CLIErrorCode.lifecycleFailed || err.code == CLIErrorCode.postCreateFailed
            )
        }
        try MiniTest.expect(mock.calls.contains {
            $0.arguments.first == "delete" && $0.arguments.contains(resolved.containerName)
        })
    }),
    ("upWithLocalFeaturesDefaultFetcher", {
        let cache = FileManager.default.temporaryDirectory
            .appendingPathComponent("feat-up-local-\(UUID().uuidString)", isDirectory: true).path
        defer { try? FileManager.default.removeItem(atPath: cache) }

        let ws = try TestRepo.makeTempWorkspace(configJSON: """
        {
          "image": "alpine:3.20",
          "features": {
            "./.devcontainer/features/sample-a": { "greeting": "local" },
            "./.devcontainer/features/sample-b": { "mode": "test" }
          }
        }
        """)
        defer { try? FileManager.default.removeItem(at: ws) }

        let featuresRoot = ws.appendingPathComponent(".devcontainer/features", isDirectory: true)
        try FileManager.default.createDirectory(at: featuresRoot, withIntermediateDirectories: true)
        for name in ["sample-a", "sample-b"] {
            let src = TestRepo.root()
                .appendingPathComponent("Tests/Fixtures/features-sample/\(name)").path
            try FileManager.default.copyItem(
                atPath: src,
                toPath: featuresRoot.appendingPathComponent(name).path
            )
        }

        // Use DefaultFeatureFetcher (no fetcher override) + local packages on disk.
        let previousFetcher = UpCommand.featuresFetcherOverride
        let previousCache = UpCommand.featuresCacheRootOverride
        let previousEnsure = UpCommand.ensureNativeArmBuildOverride
        defer {
            UpCommand.featuresFetcherOverride = previousFetcher
            UpCommand.featuresCacheRootOverride = previousCache
            UpCommand.ensureNativeArmBuildOverride = previousEnsure
        }
        UpCommand.featuresFetcherOverride = nil
        UpCommand.featuresCacheRootOverride = cache
        UpCommand.ensureNativeArmBuildOverride = { /* no-op */ }

        let mock = MockProcessRunner()
        var imageInCreate: String?
        mock.handlers = [
            { args in
                if args.first == "create" {
                    if let sleepIdx = args.firstIndex(of: "/bin/sleep"), sleepIdx + 1 < args.count {
                        imageInCreate = args[sleepIdx + 1]
                    }
                }
                return FeaturesUpTestSupport.mockHandler()(args)
            }
        ]
        let runtime = AppleContainerRuntime(executablePath: "/usr/local/bin/container", runner: mock)
        let result = try UpCommand.run(
            options: UpOptions(workspacePath: ws.path, skipPull: true),
            runtime: runtime,
            localEnv: [:]
        )
        try MiniTest.expectEqual(result.outcome, "success")
        try MiniTest.expect(mock.calls.contains { $0.arguments.first == "build" })
        let expectedBase = ContainerIdentity.humanBase(configName: nil, workspacePath: ws.path)
        try MiniTest.expect(imageInCreate?.hasPrefix("adev-\(expectedBase):") == true)
        try MiniTest.expect(imageInCreate?.contains("/features") != true)
        // Dockerfile should install sample-a before sample-b
        if let buildCall = mock.calls.first(where: { $0.arguments.first == "build" }),
           let fIdx = buildCall.arguments.firstIndex(of: "-f"),
           fIdx + 1 < buildCall.arguments.count {
            let dockerfile = try String(contentsOfFile: buildCall.arguments[fIdx + 1], encoding: .utf8)
            let idxA = dockerfile.range(of: "sample-a")?.lowerBound
            let idxB = dockerfile.range(of: "sample-b")?.lowerBound
            if let idxA, let idxB {
                try MiniTest.expect(idxA < idxB)
            }
        }
    })
]
