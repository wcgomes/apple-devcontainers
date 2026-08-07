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
    ("hashMismatchErrorsWithoutRecreate", {
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
            try MiniTest.expectEqual((error as! CLIError).code, CLIErrorCode.configHashMismatch)
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
            options: ExecOptions(workspacePath: workspace.path, command: ["echo", "ok"]),
            runtime: runtime,
            localEnv: [:]
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
                workspacePath: workspace.path,
                command: ["bash", "-lc", "true"],
                interactive: true
            ),
            runtime: runtime,
            localEnv: [:]
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
            options: ExecOptions(workspacePath: workspace.path, command: [], interactive: true),
            runtime: runtime,
            localEnv: [:]
        )
        try MiniTest.expectEqual(code, 0)
        let execCall = interactiveMock.calls.first { $0.arguments.first == "exec" }!
        try MiniTest.expect(execCall.arguments.contains("-i"))
        try MiniTest.expect(execCall.arguments.contains("-t"))
        try MiniTest.expect(execCall.arguments.last == "bash")
    }),
    ("execNotRunningMissing", {
        let workspace = try TestRepo.makeTempWorkspace(configJSON: #"{ "image": "alpine:3.20" }"#)
        defer { try? FileManager.default.removeItem(at: workspace) }
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
                options: ExecOptions(workspacePath: workspace.path, command: ["true"]),
                runtime: runtime,
                localEnv: [:]
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
                options: ExecOptions(workspacePath: workspace.path, command: ["true"]),
                runtime: runtime,
                localEnv: [:]
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
        try StopCommand.run(workspacePath: workspace.path, runtime: runtime, localEnv: [:])
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
        try DeleteCommand.run(workspacePath: workspace.path, runtime: runtime, localEnv: [:])
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
        let payload = try InspectCommand.run(
            workspacePath: workspace.path, runtime: runtime, localEnv: [:]
        )
        try MiniTest.expectEqual(payload.containerId, resolved.containerName)
        try MiniTest.expectEqual(payload.state, "running")
        try MiniTest.expectEqual(payload.labels[ContainerIdentity.labelConfigHash], resolved.configHash)
    }),
    ("deleteMissingErrors", {
        let workspace = try TestRepo.makeTempWorkspace(configJSON: #"{ "image": "alpine:3.20" }"#)
        defer { try? FileManager.default.removeItem(at: workspace) }
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
            try DeleteCommand.run(workspacePath: workspace.path, runtime: runtime, localEnv: [:])
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
        let entry = MockProcessRunner.containerListJSON(
            id: resolved.containerName, state: "stopped", labels: resolved.labels
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
        let code = try PruneCommand.run(workspacePath: workspace.path, runtime: runtime, localEnv: [:])
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
    ("pruneMissingContainerStillDeletesVolumesAndImage", {
        let workspace = try TestRepo.makeTempWorkspace(configJSON: """
        {
          "image": "alpine:3.20",
          "mounts": [
            { "source": "orphan-vol", "target": "/data", "type": "volume" }
          ]
        }
        """)
        defer { try? FileManager.default.removeItem(at: workspace) }
        let mock = MockProcessRunner()
        let volumeListData = try JSONSerialization.data(withJSONObject: [["id": "orphan-vol"]] as [[String: Any]])
        mock.handlers = [
            { args in
                if args.starts(with: ["list"]) {
                    let data = try! JSONSerialization.data(withJSONObject: [] as [Any])
                    return ProcessResult(exitCode: 0, stdout: data, stderr: Data())
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
        let code = try PruneCommand.run(workspacePath: workspace.path, runtime: runtime, localEnv: [:])
        try MiniTest.expect(code == 0)
        try MiniTest.expect(!mock.calls.contains { $0.arguments.first == "delete" })
        try MiniTest.expect(mock.calls.contains { $0.arguments == ["volume", "delete", "orphan-vol"] })
        try MiniTest.expect(mock.calls.contains {
            $0.arguments == ["image", "delete", "alpine:3.20"]
                || $0.arguments == ["image", "rm", "alpine:3.20"]
        })
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
    ("inspectSurfacesPortsAttributes", {
        let ws = try TestRepo.makeTempWorkspace(configJSON: """
        {
          "image": "alpine:3.20",
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
        let payload = try InspectCommand.run(workspacePath: ws.path, runtime: runtime, localEnv: [:])
        try MiniTest.expectEqual(payload.portsAttributes["8080"]?["label"], "Web")
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
