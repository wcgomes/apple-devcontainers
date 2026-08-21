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
    ("upFreshCreateDoesNotSynchronizeAuthorIdentity", {
        let workspace = try TestRepo.makeTempWorkspace(configJSON: #"{ "image": "alpine:3.20" }"#)
        defer { try? FileManager.default.removeItem(at: workspace) }
        let resolved = try ConfigResolver.resolve(workspacePath: workspace.path, localEnv: [:])
        let mock = LifecycleUpSupport.mockFreshCreate(resolved: resolved)
        let runtime = AppleContainerRuntime(executablePath: "/usr/local/bin/container", runner: mock)
        _ = try UpCommand.run(
            options: UpOptions(workspacePath: workspace.path, skipPull: true),
            runtime: runtime,
            localEnv: [:],
            credentials: SeedMockCredential()
        )
        try MiniTest.expect(
            !mock.calls.contains { $0.arguments.last?.contains("git config --global --replace-all user.name") == true },
            "up fresh-create does not synchronize author identity"
        )
    }),
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
            MockProcessRunner.imageInspectHandler(baseUser: nil),
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
        // Neither config user set + empty OCI USER → connection user `root`.
        try MiniTest.expectEqual(result.remoteUser, "root")
        let obj = try JSONSerialization.jsonObject(with: try result.jsonData()) as! [String: Any]
        try MiniTest.expect(obj["outcome"] != nil)
        try MiniTest.expect(obj["containerId"] != nil)
        try MiniTest.expectEqual(obj["remoteUser"] as? String, "root")
        try MiniTest.expect(obj["remoteWorkspaceFolder"] != nil)
        let createArgs = mock.calls.first { $0.arguments.first == "create" }!.arguments
        try MiniTest.expect(!createArgs.contains("-u"), "connection root → omit create -u")
        try MiniTest.expect(createArgs.contains("devcontainer.remote_user=root"))
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
        try MiniTest.expect(
            !mock.calls.contains { $0.arguments.first == "exec" && $0.arguments.last?.contains("chown") == true },
            "reuse must not run the parent fix-up"
        )
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
        try MiniTest.expect(
            !mock.calls.contains { $0.arguments.first == "exec" && $0.arguments.last?.contains("chown") == true },
            "start-stopped must not run the parent fix-up"
        )
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
    }),
    ("upChownsNamedVolumeMountsForNonRoot", {
        let bindDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("adev-up-bind-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: bindDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: bindDir) }
        let workspace = try TestRepo.makeTempWorkspace(configJSON: """
        {
          "image": "alpine:3.20",
          "remoteUser": "vscode",
          "mounts": [
            "source=opencode-config,target=/home/vscode/.config/opencode,type=volume",
            "source=\(bindDir.path),target=/bound-host,type=bind"
          ]
        }
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
                if args == ["volume", "list", "--format", "json"] {
                    return ProcessResult(exitCode: 0, stdout: Data("[]".utf8), stderr: Data())
                }
                if args.starts(with: ["volume", "create"]) {
                    return ProcessResult(exitCode: 0, stdout: Data(), stderr: Data())
                }
                return nil
            },
            MockProcessRunner.imageInspectHandler(baseUser: nil),
            { args in
                if args.first == "create" {
                    return ProcessResult(
                        exitCode: 0,
                        stdout: Data("\(resolved.containerName)\n".utf8),
                        stderr: Data()
                    )
                }
                if args.first == "start" || args.first == "exec" || args.first == "delete" {
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
        try MiniTest.expectEqual(result.remoteUser, "vscode")
        let chownExecs = mock.calls.filter { call in
            call.arguments.first == "exec"
                && (call.arguments.last?.contains("chown -R") == true)
        }
        try MiniTest.expectEqual(chownExecs.count, 1, "exactly one named-volume chown exec")
        let script = chownExecs[0].arguments.last ?? ""
        try MiniTest.expect(script.contains("/home/vscode/.config/opencode"))
        try MiniTest.expect(!script.contains("/bound-host"), "must not chown bind targets")
        try MiniTest.expect(chownExecs[0].arguments.contains("root"))
        // Parents-only fix-up: second chown exec, no -R, ancestors only.
        let parentsExecs = mock.calls.filter { call in
            call.arguments.first == "exec"
                && (call.arguments.last?.contains("chown") == true)
                && (call.arguments.last?.contains("chown -R") == false)
        }
        try MiniTest.expectEqual(parentsExecs.count, 1, "exactly one parents-only exec")
        let parentsScript = parentsExecs[0].arguments.last ?? ""
        try MiniTest.expect(parentsScript.contains("/workspaces"), "parents exec targets workspace ancestors")
        try MiniTest.expect(!parentsScript.contains("chown -R"), "parents exec must not chown -R")
        try MiniTest.expect(!parentsScript.contains("/bound-host"), "parents exec must not touch the bind target")
    }),
    ("upSkipsNamedVolumeChownForRoot", {
        let workspace = try TestRepo.makeTempWorkspace(configJSON: """
        {
          "image": "alpine:3.20",
          "remoteUser": "root",
          "mounts": [
            "source=opencode-config,target=/root/.config/opencode,type=volume"
          ]
        }
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
                if args == ["volume", "list", "--format", "json"] {
                    return ProcessResult(exitCode: 0, stdout: Data("[]".utf8), stderr: Data())
                }
                if args.starts(with: ["volume", "create"]) {
                    return ProcessResult(exitCode: 0, stdout: Data(), stderr: Data())
                }
                return nil
            },
            MockProcessRunner.imageInspectHandler(baseUser: nil),
            { args in
                if args.first == "create" {
                    return ProcessResult(
                        exitCode: 0,
                        stdout: Data("\(resolved.containerName)\n".utf8),
                        stderr: Data()
                    )
                }
                if args.first == "start" || args.first == "exec" {
                    return ProcessResult(exitCode: 0, stdout: Data(), stderr: Data())
                }
                return nil
            }
        ]
        let runtime = AppleContainerRuntime(executablePath: "/usr/local/bin/container", runner: mock)
        _ = try UpCommand.run(
            options: UpOptions(workspacePath: workspace.path, skipPull: true),
            runtime: runtime,
            localEnv: [:]
        )
        let chownExecs = mock.calls.filter { call in
            call.arguments.first == "exec"
                && (call.arguments.last?.contains("chown") == true)
        }
        try MiniTest.expect(chownExecs.isEmpty, "root connection user skips named-volume chown")
    }),
    ("upBindFreshCreateFixesParentsBeforeHooks", {
        let workspace = try TestRepo.makeTempWorkspace(configJSON: """
        {
          "image": "alpine:3.20",
          "remoteUser": "vscode",
          "postCreateCommand": "echo postCreateCustom"
        }
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
            MockProcessRunner.imageInspectHandler(baseUser: nil),
            { args in
                if args.first == "create" {
                    return ProcessResult(
                        exitCode: 0,
                        stdout: Data("\(resolved.containerName)\n".utf8),
                        stderr: Data()
                    )
                }
                if args.first == "start" || args.first == "exec" {
                    return ProcessResult(exitCode: 0, stdout: Data(), stderr: Data())
                }
                return nil
            }
        ]
        let runtime = AppleContainerRuntime(executablePath: "/usr/local/bin/container", runner: mock)
        _ = try UpCommand.run(
            options: UpOptions(workspacePath: workspace.path, skipPull: true),
            runtime: runtime,
            localEnv: [:]
        )
        let parentsExecs = mock.calls.filter { call in
            call.arguments.first == "exec"
                && (call.arguments.last?.contains("chown") == true)
                && (call.arguments.last?.contains("chown -R") == false)
        }
        try MiniTest.expectEqual(parentsExecs.count, 1, "exactly one parents-only exec on fresh bind create")
        let script = parentsExecs[0].arguments.last ?? ""
        try MiniTest.expect(script.contains("T='/workspaces/\(workspace.lastPathComponent)'"), "workspace folder path")
        try MiniTest.expect(script.contains("mkdir -p \"$T\""), "mkdir -p of the workspace folder path")
        try MiniTest.expect(!script.contains("chown -R"), "no recursive chown of the bind target")
        try MiniTest.expect(!script.contains("chown \"$OWN\" \"$T\""), "workspace folder (bind target) never chowned")
        try MiniTest.expect(script.contains("chown \"$OWN\" \"$P\""), "non-recursive ancestor chown")
        try MiniTest.expect(
            !mock.calls.contains { $0.arguments.first == "exec" && $0.arguments.last?.contains("chown -R") == true },
            "no recursive chown exec at all on the create path"
        )
        let parentsIdx = mock.calls.firstIndex { call in
            call.arguments.first == "exec" && call.arguments.last?.contains("chown") == true
        }!
        let hookIdx = mock.calls.firstIndex { call in
            call.arguments.first == "exec" && call.arguments.last?.contains("postCreateCustom") == true
        }!
        try MiniTest.expect(parentsIdx < hookIdx, "parent fix-up runs before create-path hooks")
    }),
    ("upBindCreateRootUserRunsNoParentFixup", {
        let workspace = try TestRepo.makeTempWorkspace(configJSON: """
        {
          "image": "alpine:3.20",
          "remoteUser": "root",
          "postCreateCommand": "echo postCreateCustom"
        }
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
            MockProcessRunner.imageInspectHandler(baseUser: nil),
            { args in
                if args.first == "create" {
                    return ProcessResult(
                        exitCode: 0,
                        stdout: Data("\(resolved.containerName)\n".utf8),
                        stderr: Data()
                    )
                }
                if args.first == "start" || args.first == "exec" {
                    return ProcessResult(exitCode: 0, stdout: Data(), stderr: Data())
                }
                return nil
            }
        ]
        let runtime = AppleContainerRuntime(executablePath: "/usr/local/bin/container", runner: mock)
        _ = try UpCommand.run(
            options: UpOptions(workspacePath: workspace.path, skipPull: true),
            runtime: runtime,
            localEnv: [:]
        )
        try MiniTest.expect(
            !mock.calls.contains { $0.arguments.first == "exec" && $0.arguments.last?.contains("chown") == true },
            "root connection user runs no parent fix-up"
        )
    }),
    ("upFreshCreateSeedsCredentialsAfterOwnershipBeforeHooks", {
        let workspace = try TestRepo.makeTempWorkspace(configJSON: """
        {
          "image": "alpine:3.20",
          "remoteUser": "vscode",
          "postCreateCommand": "echo postCreateCustom"
        }
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
            MockProcessRunner.imageInspectHandler(baseUser: nil),
            { args in
                if args.first == "create" {
                    return ProcessResult(
                        exitCode: 0,
                        stdout: Data("\(resolved.containerName)\n".utf8),
                        stderr: Data()
                    )
                }
                if args.first == "start" || args.first == "exec" {
                    return ProcessResult(exitCode: 0, stdout: Data(), stderr: Data())
                }
                return nil
            }
        ]
        // Deterministic host git enumeration (real git would miss the mock remotes).
        let hostRunner = RecordingHostProcessRunner()
        hostRunner.handler = { call in
            if call.arguments == ["-C", workspace.path, "remote", "-v"] {
                return ProcessResult(
                    exitCode: 0,
                    stdout: Data("origin\thttps://github.com/wcgomes/repo.git (fetch)\n".utf8),
                    stderr: Data()
                )
            }
            return ProcessResult(exitCode: 0, stdout: Data(), stderr: Data())
        }
        let restore = RecordingHostProcessRunner.install(hostRunner)
        defer { restore() }
        let creds = SeedMockCredential()
        creds.results["https://github.com/wcgomes/repo.git"] = .success(
            GitHTTPSCredentials(username: "x-access-token", password: "ghp_secret")
        )
        let runtime = AppleContainerRuntime(executablePath: "/usr/local/bin/container", runner: mock)
        let result = try UpCommand.run(
            options: UpOptions(workspacePath: workspace.path, skipPull: true),
            runtime: runtime,
            localEnv: [:],
            credentials: creds
        )
        try MiniTest.expectEqual(result.outcome, "success")
        let calls = mock.calls.map(\.arguments)
        let createIdx = calls.firstIndex { $0.first == "create" }!
        let startIdx = calls.firstIndex { $0.first == "start" }!
        let chownIdx = calls.firstIndex { $0.first == "exec" && $0.last?.contains("chown") == true }!
        let seedIdx = calls.firstIndex { $0.first == "exec" && $0.last?.contains("credential.helper") == true }!
        let hookIdx = calls.firstIndex { $0.first == "exec" && $0.last?.contains("postCreateCustom") == true }!
        try MiniTest.expect(createIdx < startIdx, "create before start")
        try MiniTest.expect(startIdx < chownIdx, "ownership after start")
        try MiniTest.expect(chownIdx < seedIdx, "seeding after ownership block")
        try MiniTest.expect(seedIdx < hookIdx, "seeding before first hook exec")
        let seedCall = mock.calls[seedIdx]
        let seedArgs = seedCall.arguments
        try MiniTest.expect(seedArgs.contains("-u") && seedArgs.contains("vscode"), "seeds as connection user")
        try MiniTest.expectEqual(
            String(data: seedCall.stdinData ?? Data(), encoding: .utf8) ?? "",
            "protocol=https\nhost=github.com\nusername=x-access-token\npassword=ghp_secret\n\n"
        )
        try MiniTest.expect(!seedArgs.contains(where: { $0.contains("ghp_secret") }))
        try MiniTest.expect(seedCall.environment?.values.contains("ghp_secret") != true)
        let script = seedArgs.last ?? ""
        try MiniTest.expect(script.contains("git config --global --add credential.helper"))
        try MiniTest.expect(!script.contains("ghp_secret"), "secrets never in the exec command")
        try MiniTest.expect(!script.contains("github.com"), "no host/path in the script")
    }),
    ("upFreshCreateSeedingFailureWarnsAndContinues", {
        let workspace = try TestRepo.makeTempWorkspace(configJSON: """
        {
          "image": "alpine:3.20",
          "remoteUser": "vscode",
          "postCreateCommand": "echo postCreateCustom"
        }
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
            MockProcessRunner.imageInspectHandler(baseUser: nil),
            { args in
                if args.first == "create" {
                    return ProcessResult(
                        exitCode: 0,
                        stdout: Data("\(resolved.containerName)\n".utf8),
                        stderr: Data()
                    )
                }
                if args.first == "exec" {
                    let script = args.last ?? ""
                    if script.contains("git-credential-adev") {
                        return ProcessResult(
                            exitCode: 1,
                            stdout: Data(),
                            stderr: Data("fatal: unable to reach 'https://github.com/wcgomes/repo.git': remote error\n".utf8)
                        )
                    }
                    return ProcessResult(exitCode: 0, stdout: Data(), stderr: Data())
                }
                return nil
            }
        ]
        let hostRunner = RecordingHostProcessRunner()
        hostRunner.handler = { call in
            if call.arguments == ["-C", workspace.path, "remote", "-v"] {
                return ProcessResult(
                    exitCode: 0,
                    stdout: Data("origin\thttps://github.com/wcgomes/repo.git (fetch)\n".utf8),
                    stderr: Data()
                )
            }
            return ProcessResult(exitCode: 0, stdout: Data(), stderr: Data())
        }
        let restore = RecordingHostProcessRunner.install(hostRunner)
        defer { restore() }
        let creds = SeedMockCredential()
        creds.results["https://github.com/wcgomes/repo.git"] = .success(
            GitHTTPSCredentials(username: "x-access-token", password: "ghp_secret")
        )
        var warnings: [String] = []
        let prevWarning = StatusPrinter.onWarning
        StatusPrinter.onWarning = { warnings.append($0) }
        defer { StatusPrinter.onWarning = prevWarning }
        let runtime = AppleContainerRuntime(executablePath: "/usr/local/bin/container", runner: mock)
        let result = try UpCommand.run(
            options: UpOptions(workspacePath: workspace.path, skipPull: true),
            runtime: runtime,
            localEnv: [:],
            credentials: creds
        )
        try MiniTest.expectEqual(result.outcome, "success", "seeding failure is soft-fail")
        try MiniTest.expectEqual(warnings.count, 1, "exactly one seeding warning")
        try MiniTest.expect(!warnings[0].contains("ghp_secret"), "warning redacts credential material")
        try MiniTest.expect(!warnings[0].contains("x-access-token"), "warning redacts username")
        try MiniTest.expect(mock.calls.contains { $0.arguments.first == "exec" && $0.arguments.last?.contains("postCreateCustom") == true },
            "hooks still run after seeding failure")
        try MiniTest.expect(!mock.calls.contains { $0.arguments.first == "delete" }, "seeding failure never deletes")
    }),
    ("upFreshCreateNonRepoWorkspaceSkipsSeedingSilently", {
        let workspace = try TestRepo.makeTempWorkspace(configJSON: """
        {
          "image": "alpine:3.20",
          "remoteUser": "vscode",
          "postCreateCommand": "echo postCreateCustom"
        }
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
            MockProcessRunner.imageInspectHandler(baseUser: nil),
            { args in
                if args.first == "create" {
                    return ProcessResult(
                        exitCode: 0,
                        stdout: Data("\(resolved.containerName)\n".utf8),
                        stderr: Data()
                    )
                }
                if args.first == "start" || args.first == "exec" {
                    return ProcessResult(exitCode: 0, stdout: Data(), stderr: Data())
                }
                return nil
            }
        ]
        // Host git answers: workspace is not a repository (non-zero, no remotes).
        let hostRunner = RecordingHostProcessRunner()
        hostRunner.handler = { call in
            if call.arguments == ["-C", workspace.path, "remote", "-v"] {
                return ProcessResult(exitCode: 128, stdout: Data(), stderr: Data("fatal: not a git repository".utf8))
            }
            return ProcessResult(exitCode: 0, stdout: Data(), stderr: Data())
        }
        let restore = RecordingHostProcessRunner.install(hostRunner)
        defer { restore() }
        let creds = SeedMockCredential()
        creds.defaultResult = .success(GitHTTPSCredentials(username: "u", password: "p"))
        var warnings: [String] = []
        let prevWarning = StatusPrinter.onWarning
        StatusPrinter.onWarning = { warnings.append($0) }
        defer { StatusPrinter.onWarning = prevWarning }
        let runtime = AppleContainerRuntime(executablePath: "/usr/local/bin/container", runner: mock)
        let result = try UpCommand.run(
            options: UpOptions(workspacePath: workspace.path, skipPull: true),
            runtime: runtime,
            localEnv: [:],
            credentials: creds
        )
        try MiniTest.expectEqual(result.outcome, "success")
        try MiniTest.expect(creds.fillCalls.isEmpty, "non-repo workspace never fills")
        try MiniTest.expect(
            !mock.calls.contains { $0.arguments.first == "exec" && $0.arguments.last?.contains("git config --global --add credential.helper") == true },
            "no seeding exec for a non-repo workspace"
        )
        try MiniTest.expect(warnings.isEmpty, "silent skip emits no warning")
        try MiniTest.expect(mock.calls.contains { $0.arguments.first == "exec" && $0.arguments.last?.contains("postCreateCustom") == true },
            "hooks still run")
    }),
    ("upReuseRunningSeedsNothing", {
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
        let creds = SeedMockCredential()
        creds.defaultResult = .success(GitHTTPSCredentials(username: "u", password: "p"))
        let runtime = AppleContainerRuntime(executablePath: "/usr/local/bin/container", runner: mock)
        let result = try UpCommand.run(
            options: UpOptions(workspacePath: workspace.path, skipPull: true),
            runtime: runtime,
            localEnv: [:],
            credentials: creds
        )
        try MiniTest.expectEqual(result.outcome, "success")
        try MiniTest.expect(creds.fillCalls.isEmpty, "reuse must not fill")
        try MiniTest.expect(
            !mock.calls.contains { $0.arguments.first == "exec" && $0.arguments.last?.contains("credential.helper") == true },
            "reuse must not run a seeding exec"
        )
    }),
    ("upStartStoppedSeedsNothing", {
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
        let creds = SeedMockCredential()
        creds.defaultResult = .success(GitHTTPSCredentials(username: "u", password: "p"))
        let runtime = AppleContainerRuntime(executablePath: "/usr/local/bin/container", runner: mock)
        let result = try UpCommand.run(
            options: UpOptions(workspacePath: workspace.path, skipPull: true),
            runtime: runtime,
            localEnv: [:],
            credentials: creds
        )
        try MiniTest.expectEqual(result.outcome, "success")
        try MiniTest.expect(creds.fillCalls.isEmpty, "start-stopped must not fill")
        try MiniTest.expect(
            !mock.calls.contains { $0.arguments.first == "exec" && $0.arguments.last?.contains("credential.helper") == true },
            "start-stopped must not run a seeding exec"
        )
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
        let execCall = mock.calls.first {
            $0.arguments.first == "exec" && $0.arguments.contains("echo")
        }!
        try MiniTest.expect(execCall.arguments.contains("vscode"))
        try MiniTest.expect(execCall.arguments.contains("/workspaces/app"))
        try MiniTest.expect(execCall.arguments.contains("echo"))
        try MiniTest.expect(!execCall.arguments.contains("-i"))
        try MiniTest.expect(!execCall.arguments.contains("-t"))
        // User exec is capture-then-print passthrough — not internal tool framing stream.
        try MiniTest.expect(execCall.streamStderr == nil || execCall.streamStderr == false)
        try MiniTest.expect(execCall.teeStdoutToStderr == nil || execCall.teeStdoutToStderr == false)
    }),
    ("execUserOutputNotStreamFramed", {
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
                    return ProcessResult(
                        exitCode: 0,
                        stdout: Data("USER_EXEC_MARK\n".utf8),
                        stderr: Data()
                    )
                }
                return nil
            }
        ]
        let runtime = AppleContainerRuntime(executablePath: "/usr/local/bin/container", runner: mock)
        let code = try ExecCommand.run(
            options: ExecOptions(command: ["echo", "USER_EXEC_MARK"], name: resolved.containerName),
            runtime: runtime
        )
        try MiniTest.expectEqual(code, 0)
        let execCall = mock.calls.first {
            $0.arguments.first == "exec" && $0.arguments.contains("USER_EXEC_MARK")
        }!
        // No streamOutput framing path for user exec.
        try MiniTest.expect(execCall.streamStderr != true)
        try MiniTest.expect(execCall.teeStdoutToStderr != true)
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
        try MiniTest.expect(
            listMock.calls.filter { $0.arguments.first == "exec" }.allSatisfy {
                $0.arguments.contains(LifecycleRunner.userEnvProbeScript)
            },
            "non-interactive runner may probe; user exec stays on the interactive runner"
        )
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
        // Ordinary delete remains container-only (no volume deletes / no force-volumes).
        try MiniTest.expect(!mock.calls.contains { $0.arguments.starts(with: ["volume", "delete"]) })
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
    ("purgeDeletesContainerVolumesImageInOrder", {
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
        var containerDeleted = false
        mock.handlers = [
            { args in
                if args.starts(with: ["list"]) {
                    // After target delete, attachment inspection must not see the target.
                    let payload: [Any] = containerDeleted ? [] : [entry]
                    let data = try! JSONSerialization.data(withJSONObject: payload)
                    return ProcessResult(exitCode: 0, stdout: data, stderr: Data())
                }
                if args.first == "delete" {
                    containerDeleted = true
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
        let code = try PurgeCommand.run(name: resolved.containerName, runtime: runtime)
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
    ("purgeSkipsRecoveryHelperAndReferencedResources", {
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
            try PurgeCommand.run(name: "recovery-helper", runtime: runtime),
            0
        )
        try MiniTest.expect(
            !mock.calls.contains { call in
                ["delete", "volume", "image"].contains(call.arguments.first ?? "")
            },
            "purge does not delete the helper, referenced volumes, or image"
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
    ("purgeMissingManagedErrors", {
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
            _ = try PurgeCommand.run(name: "adev-missing", runtime: runtime)
        }) { error in
            try MiniTest.expectEqual((error as! CLIError).code, CLIErrorCode.containerNotFound)
        }
    }),
    ("purgePreservesVolumeMountedByAnotherRunningContainer", {
        let targetID = "adev-target-prune"
        let otherID = "other"
        let labels: [String: String] = [
            ContainerIdentity.labelManaged: ContainerIdentity.managedValue,
            ContainerIdentity.labelConfigVolumes: "shared-data"
        ]
        let target = MockProcessRunner.containerListJSON(
            id: targetID, state: "stopped", labels: labels, image: "alpine:3.20"
        )
        let other = purgeAttachedContainerJSON(
            id: otherID, state: "running", volumes: ["shared-data"]
        )
        let volumeListData = try JSONSerialization.data(withJSONObject: [["id": "shared-data"]] as [[String: Any]])
        var containerDeleted = false
        let mock = MockProcessRunner()
        mock.handlers = [
            { args in
                if args.starts(with: ["list"]) {
                    let payload: [Any] = containerDeleted ? [other] : [target]
                    let data = try! JSONSerialization.data(withJSONObject: payload)
                    return ProcessResult(exitCode: 0, stdout: data, stderr: Data())
                }
                if args.first == "delete" {
                    containerDeleted = true
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
        let previous = StatusPrinter.onWarning
        defer { StatusPrinter.onWarning = previous }
        var warnings: [String] = []
        StatusPrinter.onWarning = { warnings.append($0) }

        let runtime = AppleContainerRuntime(executablePath: "/usr/local/bin/container", runner: mock)
        let code = try PurgeCommand.run(name: targetID, runtime: runtime)
        try MiniTest.expectEqual(code, 0)
        try MiniTest.expect(mock.calls.contains { $0.arguments.first == "delete" })
        try MiniTest.expect(
            !mock.calls.contains { $0.arguments == ["volume", "delete", "shared-data"] },
            "shared volume must not be deleted while another container mounts it"
        )
        let preserve = warnings.first { $0.contains("Preserving volume 'shared-data'") }
        try MiniTest.expect(preserve != nil, "expected preserve-because-referenced warning")
        try MiniTest.expect(preserve!.contains("referenced by containers:"))
        try MiniTest.expect(preserve!.contains(otherID))
    }),
    ("purgePreservesVolumeMountedByStoppedContainer", {
        let targetID = "adev-target-stopped-share"
        let otherID = "stopped-other"
        let labels: [String: String] = [
            ContainerIdentity.labelManaged: ContainerIdentity.managedValue,
            ContainerIdentity.labelConfigVolumes: "v1"
        ]
        let target = MockProcessRunner.containerListJSON(
            id: targetID, state: "stopped", labels: labels, image: "alpine:3.20"
        )
        let other = purgeAttachedContainerJSON(
            id: otherID, state: "stopped", volumes: ["v1"]
        )
        let volumeListData = try JSONSerialization.data(withJSONObject: [["id": "v1"]] as [[String: Any]])
        var containerDeleted = false
        let mock = MockProcessRunner()
        mock.handlers = [
            { args in
                if args.starts(with: ["list"]) {
                    let payload: [Any] = containerDeleted ? [other] : [target]
                    let data = try! JSONSerialization.data(withJSONObject: payload)
                    return ProcessResult(exitCode: 0, stdout: data, stderr: Data())
                }
                if args.first == "delete" {
                    containerDeleted = true
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
        let previous = StatusPrinter.onWarning
        defer { StatusPrinter.onWarning = previous }
        var warnings: [String] = []
        StatusPrinter.onWarning = { warnings.append($0) }

        let runtime = AppleContainerRuntime(executablePath: "/usr/local/bin/container", runner: mock)
        let code = try PurgeCommand.run(name: targetID, runtime: runtime)
        try MiniTest.expectEqual(code, 0)
        try MiniTest.expect(
            !mock.calls.contains { $0.arguments == ["volume", "delete", "v1"] },
            "stopped attachments still protect the volume"
        )
        try MiniTest.expect(warnings.contains { $0.contains("Preserving volume 'v1'") && $0.contains(otherID) })
    }),
    ("purgeDeletesUnreferencedAmongMixedAttachments", {
        let targetID = "adev-target-mixed"
        let otherID = "peer"
        let labels: [String: String] = [
            ContainerIdentity.labelManaged: ContainerIdentity.managedValue,
            ContainerIdentity.labelConfigVolumes: "vol-shared,vol-only"
        ]
        let target = MockProcessRunner.containerListJSON(
            id: targetID, state: "stopped", labels: labels, image: "alpine:3.20"
        )
        let other = purgeAttachedContainerJSON(
            id: otherID, state: "running", volumes: ["vol-shared"]
        )
        let volumeListData = try JSONSerialization.data(withJSONObject: [
            ["id": "vol-shared"],
            ["id": "vol-only"]
        ] as [[String: Any]])
        var containerDeleted = false
        let mock = MockProcessRunner()
        mock.handlers = [
            { args in
                if args.starts(with: ["list"]) {
                    let payload: [Any] = containerDeleted ? [other] : [target]
                    let data = try! JSONSerialization.data(withJSONObject: payload)
                    return ProcessResult(exitCode: 0, stdout: data, stderr: Data())
                }
                if args.first == "delete" {
                    containerDeleted = true
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
        let previous = StatusPrinter.onWarning
        defer { StatusPrinter.onWarning = previous }
        var warnings: [String] = []
        StatusPrinter.onWarning = { warnings.append($0) }

        let runtime = AppleContainerRuntime(executablePath: "/usr/local/bin/container", runner: mock)
        let code = try PurgeCommand.run(name: targetID, runtime: runtime)
        try MiniTest.expectEqual(code, 0)
        try MiniTest.expect(mock.calls.contains { $0.arguments == ["volume", "delete", "vol-only"] })
        try MiniTest.expect(
            !mock.calls.contains { $0.arguments == ["volume", "delete", "vol-shared"] }
        )
        try MiniTest.expect(warnings.contains {
            $0.contains("Preserving volume 'vol-shared'") && $0.contains(otherID)
        })
    }),
    ("purgePreservesSharedWorkspaceVolumeAndRemovesUnreferenced", {
        let targetID = "adev-ws-share-target"
        let otherID = "ws-peer"
        let wsVol = "adev-app-sharetest-ws"
        let labels: [String: String] = [
            ContainerIdentity.labelManaged: ContainerIdentity.managedValue,
            ContainerIdentity.labelWorkspaceMode: ContainerIdentity.workspaceModeVolume,
            ContainerIdentity.labelWorkspaceVolume: wsVol
        ]
        let target = MockProcessRunner.containerListJSON(
            id: targetID, state: "stopped", labels: labels, image: "alpine:3.20"
        )
        let other = purgeAttachedContainerJSON(
            id: otherID, state: "running", volumes: [wsVol]
        )
        let volumeListData = try JSONSerialization.data(withJSONObject: [["id": wsVol]] as [[String: Any]])
        var containerDeleted = false
        let mock = MockProcessRunner()
        mock.handlers = [
            { args in
                if args.starts(with: ["list"]) {
                    let payload: [Any] = containerDeleted ? [other] : [target]
                    let data = try! JSONSerialization.data(withJSONObject: payload)
                    return ProcessResult(exitCode: 0, stdout: data, stderr: Data())
                }
                if args.first == "delete" {
                    containerDeleted = true
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
        let previous = StatusPrinter.onWarning
        defer { StatusPrinter.onWarning = previous }
        var warnings: [String] = []
        StatusPrinter.onWarning = { warnings.append($0) }

        let runtime = AppleContainerRuntime(executablePath: "/usr/local/bin/container", runner: mock)
        let code = try PurgeCommand.run(name: targetID, runtime: runtime)
        try MiniTest.expectEqual(code, 0)
        try MiniTest.expect(
            !mock.calls.contains { $0.arguments == ["volume", "delete", wsVol] },
            "shared workspace volume must be preserved"
        )
        try MiniTest.expect(warnings.contains {
            $0.contains("Preserving volume '\(wsVol)'") && $0.contains(otherID)
        })
    }),
    ("purgeContainerDeleteFailureBlocksAllVolumeDeletes", {
        let targetID = "adev-target-delete-fail"
        let labels: [String: String] = [
            ContainerIdentity.labelManaged: ContainerIdentity.managedValue,
            ContainerIdentity.labelConfigVolumes: "vol-a,vol-b"
        ]
        let target = MockProcessRunner.containerListJSON(
            id: targetID, state: "stopped", labels: labels, image: "alpine:3.20"
        )
        let volumeListData = try JSONSerialization.data(withJSONObject: [
            ["id": "vol-a"],
            ["id": "vol-b"]
        ] as [[String: Any]])
        let mock = MockProcessRunner()
        mock.handlers = [
            { args in
                if args.starts(with: ["list"]) {
                    let data = try! JSONSerialization.data(withJSONObject: [target])
                    return ProcessResult(exitCode: 0, stdout: data, stderr: Data())
                }
                if args.first == "delete" {
                    return ProcessResult(
                        exitCode: 1,
                        stdout: Data(),
                        stderr: Data("delete refused".utf8)
                    )
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
        let code = try PurgeCommand.run(name: targetID, runtime: runtime)
        try MiniTest.expect(code != 0)
        try MiniTest.expect(
            !mock.calls.contains { $0.arguments.starts(with: ["volume", "delete"]) },
            "container delete failure must skip the entire volume-delete loop"
        )
    }),
    ("purgeAttachmentInspectionFailurePreservesVolumeAndFails", {
        let targetID = "adev-target-attach-fail"
        let labels: [String: String] = [
            ContainerIdentity.labelManaged: ContainerIdentity.managedValue,
            ContainerIdentity.labelConfigVolumes: "risky-vol"
        ]
        let target = MockProcessRunner.containerListJSON(
            id: targetID, state: "stopped", labels: labels, image: "alpine:3.20"
        )
        // Missing mounts metadata → containersAttached fails closed.
        let brokenOther: [String: Any] = [
            "id": "broken-peer",
            "configuration": [
                "id": "broken-peer",
                "labels": [:] as [String: String]
            ] as [String: Any],
            "status": ["state": "running"] as [String: Any]
        ]
        let volumeListData = try JSONSerialization.data(withJSONObject: [["id": "risky-vol"]] as [[String: Any]])
        var containerDeleted = false
        let mock = MockProcessRunner()
        mock.handlers = [
            { args in
                if args.starts(with: ["list"]) {
                    let payload: [Any] = containerDeleted ? [brokenOther] : [target]
                    let data = try! JSONSerialization.data(withJSONObject: payload)
                    return ProcessResult(exitCode: 0, stdout: data, stderr: Data())
                }
                if args.first == "delete" {
                    containerDeleted = true
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
        let code = try PurgeCommand.run(name: targetID, runtime: runtime)
        try MiniTest.expect(code != 0)
        try MiniTest.expect(
            !mock.calls.contains { $0.arguments == ["volume", "delete", "risky-vol"] },
            "must not delete volume when attachment inspection fails"
        )
    }),
    ("purgeVolumeDeleteRejectionIsHardFailure", {
        let targetID = "adev-target-vol-reject"
        let labels: [String: String] = [
            ContainerIdentity.labelManaged: ContainerIdentity.managedValue,
            ContainerIdentity.labelConfigVolumes: "doomed-vol"
        ]
        let target = MockProcessRunner.containerListJSON(
            id: targetID, state: "stopped", labels: labels, image: "alpine:3.20"
        )
        let volumeListData = try JSONSerialization.data(withJSONObject: [["id": "doomed-vol"]] as [[String: Any]])
        var containerDeleted = false
        let mock = MockProcessRunner()
        mock.handlers = [
            { args in
                if args.starts(with: ["list"]) {
                    let payload: [Any] = containerDeleted ? [] : [target]
                    let data = try! JSONSerialization.data(withJSONObject: payload)
                    return ProcessResult(exitCode: 0, stdout: data, stderr: Data())
                }
                if args.first == "delete" {
                    containerDeleted = true
                    return ProcessResult(exitCode: 0, stdout: Data(), stderr: Data())
                }
                if args == ["volume", "list", "--format", "json"] {
                    return ProcessResult(exitCode: 0, stdout: volumeListData, stderr: Data())
                }
                if args.starts(with: ["volume", "delete"]) {
                    return ProcessResult(
                        exitCode: 1,
                        stdout: Data(),
                        stderr: Data("volume in use".utf8)
                    )
                }
                if args.starts(with: ["image", "delete"]) || args.starts(with: ["image", "rm"]) {
                    return ProcessResult(exitCode: 0, stdout: Data(), stderr: Data())
                }
                return nil
            }
        ]
        let runtime = AppleContainerRuntime(executablePath: "/usr/local/bin/container", runner: mock)
        let code = try PurgeCommand.run(name: targetID, runtime: runtime)
        try MiniTest.expect(code != 0)
        try MiniTest.expect(mock.calls.contains { $0.arguments == ["volume", "delete", "doomed-vol"] })
    }),
    ("purgeOnlyDeletesLabeledCandidatesNotHostExtras", {
        let targetID = "adev-target-labels-only"
        let labels: [String: String] = [
            ContainerIdentity.labelManaged: ContainerIdentity.managedValue,
            ContainerIdentity.labelConfigVolumes: "from-label"
        ]
        let target = MockProcessRunner.containerListJSON(
            id: targetID, state: "stopped", labels: labels, image: "alpine:3.20"
        )
        // Host has both the labeled volume and an unlabeled extra.
        let volumeListData = try JSONSerialization.data(withJSONObject: [
            ["id": "from-label"],
            ["id": "other-vol"]
        ] as [[String: Any]])
        var containerDeleted = false
        let mock = MockProcessRunner()
        mock.handlers = [
            { args in
                if args.starts(with: ["list"]) {
                    let payload: [Any] = containerDeleted ? [] : [target]
                    let data = try! JSONSerialization.data(withJSONObject: payload)
                    return ProcessResult(exitCode: 0, stdout: data, stderr: Data())
                }
                if args.first == "delete" {
                    containerDeleted = true
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
        let code = try PurgeCommand.run(name: targetID, runtime: runtime)
        try MiniTest.expectEqual(code, 0)
        try MiniTest.expect(mock.calls.contains { $0.arguments == ["volume", "delete", "from-label"] })
        try MiniTest.expect(
            !mock.calls.contains { $0.arguments == ["volume", "delete", "other-vol"] },
            "volumes not in labels must never be deleted"
        )
    })
]

/// Container list JSON with real volume mounts (RecoveryHelperTests shape) for purge attachment mocks.
private func purgeAttachedContainerJSON(
    id: String,
    state: String,
    volumes: [String],
    destinationPrefix: String = "/data"
) -> [String: Any] {
    let mounts: [[String: Any]] = volumes.enumerated().map { index, volume in
        [
            "source": "/var/lib/container/volumes/\(volume).img",
            "destination": "\(destinationPrefix)/\(index)",
            "options": [] as [String],
            "type": ["volume": ["name": volume]] as [String: Any]
        ]
    }
    return [
        "id": id,
        "configuration": [
            "id": id,
            "labels": [:] as [String: String],
            "mounts": mounts
        ] as [String: Any],
        "status": ["state": state] as [String: Any]
    ]
}

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
        try MiniTest.expectEqual(resolved.config.containerUser, "vscode")
        try MiniTest.expectEqual(resolved.config.effectiveUser, "vscode")
        try MiniTest.expectEqual(resolved.config.createProcessUser, "vscode")
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
        // Both users vscode → create -u vscode and stamp remote_user=vscode
        try MiniTest.expect(args.contains("-u"))
        if let i = args.firstIndex(of: "-u") {
            try MiniTest.expectEqual(args[i + 1], "vscode")
        }
        try MiniTest.expect(args.contains(resolved.config.workspaceFolder))
        try MiniTest.expectEqual(resolved.labels[ContainerIdentity.labelRemoteUser], "vscode")
    }),
    ("remoteUserWithoutContainerUserSetsCreateU", {
        // Apple attach uses container default user; non-root connection becomes create -u.
        let config = ResolvedDevContainerConfig(
            image: "alpine:3.20",
            remoteUser: "alice",
            workspaceFolder: "/workspaces/app"
        )
        let request = CreateRequest.from(
            resolved: config,
            identityName: "ctr",
            labels: ContainerIdentity.bindModeLabels(
                workspacePath: "/ws",
                configPath: "/ws/.devcontainer/devcontainer.json",
                configHash: "h",
                workspaceFolder: config.workspaceFolder,
                remoteUser: "alice"
            ),
            configHash: "h",
            workspacePath: "/ws"
        )
        try MiniTest.expectEqual(request.user, "alice")
        let args = request.createArguments()
        try MiniTest.expect(args.contains("-u"))
        if let i = args.firstIndex(of: "-u") {
            try MiniTest.expectEqual(args[i + 1], "alice")
        }
        try MiniTest.expectEqual(
            request.labels[ContainerIdentity.labelRemoteUser],
            "alice"
        )
    }),
    ("remoteUserAndContainerUserCreateUIsContainerUser", {
        let config = ResolvedDevContainerConfig(
            image: "alpine:3.20",
            remoteUser: "alice",
            containerUser: "bob",
            workspaceFolder: "/workspaces/app"
        )
        let request = CreateRequest.from(
            resolved: config,
            identityName: "ctr",
            labels: ContainerIdentity.bindModeLabels(
                workspacePath: "/ws",
                configPath: "/ws/.devcontainer/devcontainer.json",
                configHash: "h",
                workspaceFolder: config.workspaceFolder,
                remoteUser: "alice"
            ),
            configHash: "h",
            workspacePath: "/ws"
        )
        try MiniTest.expectEqual(request.user, "bob")
        let args = request.createArguments()
        if let i = args.firstIndex(of: "-u") {
            try MiniTest.expectEqual(args[i + 1], "bob")
        }
        try MiniTest.expectEqual(
            request.labels[ContainerIdentity.labelRemoteUser],
            "alice"
        )
    }),
    ("upCreateStampsOCIFallbackRemoteUser", {
        let workspace = try TestRepo.makeTempWorkspace(configJSON: """
        { "image": "alpine:3.20" }
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
            MockProcessRunner.imageInspectHandler(baseUser: "node"),
            { args in
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
                return nil
            }
        ]
        let runtime = AppleContainerRuntime(executablePath: "/usr/local/bin/container", runner: mock)
        let result = try UpCommand.run(
            options: UpOptions(workspacePath: workspace.path, jsonOutput: true, skipPull: true),
            runtime: runtime,
            localEnv: [:]
        )
        try MiniTest.expectEqual(result.remoteUser, "node")
        let createArgs = mock.calls.first { $0.arguments.first == "create" }!.arguments
        // Non-root OCI connection user applied as create -u (Apple attach default user).
        try MiniTest.expect(createArgs.contains("-u"))
        if let i = createArgs.firstIndex(of: "-u") {
            try MiniTest.expectEqual(createArgs[i + 1], "node")
        }
        try MiniTest.expect(createArgs.contains("devcontainer.remote_user=node"))
    }),
    ("upCreateStampsMetadataRemoteUserOverOCIRoot", {
        // Official base image pattern: OCI USER=root + metadata remoteUser=vscode
        // Create must -u vscode so Apple attach terminal is not root.
        let workspace = try TestRepo.makeTempWorkspace(configJSON: """
        { "image": "mcr.microsoft.com/devcontainers/base:ubuntu" }
        """)
        defer { try? FileManager.default.removeItem(at: workspace) }
        let mock = MockProcessRunner()
        let resolved = try ConfigResolver.resolve(workspacePath: workspace.path, localEnv: [:])
        let metaLabels = [
            DevContainerMetadataLabel.labelKey: #"{"remoteUser":"vscode"}"#
        ]
        mock.handlers = [
            { args in
                if args.starts(with: ["list"]) {
                    let data = try! JSONSerialization.data(withJSONObject: [] as [Any])
                    return ProcessResult(exitCode: 0, stdout: data, stderr: Data())
                }
                return nil
            },
            MockProcessRunner.imageInspectHandler(baseUser: "root", labels: metaLabels),
            { args in
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
                return nil
            }
        ]
        let runtime = AppleContainerRuntime(executablePath: "/usr/local/bin/container", runner: mock)
        let result = try UpCommand.run(
            options: UpOptions(workspacePath: workspace.path, jsonOutput: true, skipPull: true),
            runtime: runtime,
            localEnv: [:]
        )
        try MiniTest.expectEqual(result.remoteUser, "vscode")
        let createArgs = mock.calls.first { $0.arguments.first == "create" }!.arguments
        try MiniTest.expect(createArgs.contains("-u"), "metadata vscode → create -u for Apple attach")
        if let i = createArgs.firstIndex(of: "-u") {
            try MiniTest.expectEqual(createArgs[i + 1], "vscode")
        }
        try MiniTest.expect(createArgs.contains("devcontainer.remote_user=vscode"))
    }),
    ("upCreateFailsWhenInspectFailsAndNoConfigUsers", {
        let workspace = try TestRepo.makeTempWorkspace(configJSON: #"{ "image": "alpine:3.20" }"#)
        defer { try? FileManager.default.removeItem(at: workspace) }
        let mock = MockProcessRunner()
        mock.handlers = [
            { args in
                if args.starts(with: ["list"]) {
                    let data = try! JSONSerialization.data(withJSONObject: [] as [Any])
                    return ProcessResult(exitCode: 0, stdout: data, stderr: Data())
                }
                if args.starts(with: ["image", "inspect"]) {
                    return ProcessResult(exitCode: 1, stdout: Data(), stderr: Data("missing".utf8))
                }
                if args.first == "create" {
                    return ProcessResult(exitCode: 0, stdout: Data("should-not\n".utf8), stderr: Data())
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
            try MiniTest.expect(err.message.lowercased().contains("resolve") || err.message.lowercased().contains("inspect"))
        }
        try MiniTest.expect(!mock.calls.contains { $0.arguments.first == "create" })
    }),
    ("execUsesStampedRemoteUserLabel", {
        let mock = MockProcessRunner()
        let labels: [String: String] = [
            ContainerIdentity.labelManaged: ContainerIdentity.managedValue,
            ContainerIdentity.labelRemoteUser: "alice",
            ContainerIdentity.labelWorkspaceFolder: "/workspaces/app"
        ]
        let entry = MockProcessRunner.containerListJSON(
            id: "ctr-alice",
            state: "running",
            labels: labels
        )
        mock.handlers = [
            { args in
                if args.starts(with: ["list"]) {
                    let data = try! JSONSerialization.data(withJSONObject: [entry])
                    return ProcessResult(exitCode: 0, stdout: data, stderr: Data())
                }
                if args.first == "exec" {
                    return ProcessResult(exitCode: 0, stdout: Data("alice\n".utf8), stderr: Data())
                }
                return nil
            }
        ]
        let runtime = AppleContainerRuntime(executablePath: "/usr/local/bin/container", runner: mock)
        let code = try ExecCommand.run(
            options: ExecOptions(command: ["id", "-un"], name: "ctr-alice"),
            runtime: runtime
        )
        try MiniTest.expectEqual(code, 0)
        let execCall = mock.calls.first { $0.arguments.first == "exec" }!
        try MiniTest.expect(execCall.arguments.contains("-u"))
        if let i = execCall.arguments.firstIndex(of: "-u") {
            try MiniTest.expectEqual(execCall.arguments[i + 1], "alice")
        }
    }),
    ("execOmitsUWhenRemoteUserLabelEmpty", {
        let mock = MockProcessRunner()
        let labels: [String: String] = [
            ContainerIdentity.labelManaged: ContainerIdentity.managedValue,
            ContainerIdentity.labelRemoteUser: "",
            ContainerIdentity.labelWorkspaceFolder: "/workspaces/app"
        ]
        let entry = MockProcessRunner.containerListJSON(
            id: "ctr-legacy",
            state: "running",
            labels: labels
        )
        mock.handlers = [
            { args in
                if args.starts(with: ["list"]) {
                    let data = try! JSONSerialization.data(withJSONObject: [entry])
                    return ProcessResult(exitCode: 0, stdout: data, stderr: Data())
                }
                if args.first == "exec" {
                    return ProcessResult(exitCode: 0, stdout: Data(), stderr: Data())
                }
                return nil
            }
        ]
        let runtime = AppleContainerRuntime(executablePath: "/usr/local/bin/container", runner: mock)
        _ = try ExecCommand.run(
            options: ExecOptions(command: ["true"], name: "ctr-legacy"),
            runtime: runtime
        )
        let execCall = mock.calls.first { $0.arguments.first == "exec" }!
        try MiniTest.expect(!execCall.arguments.contains("-u"))
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
                    if LifecycleUpSupport.isUserEnvProbeExec(args) {
                        return ProcessResult(exitCode: 0, stdout: Data(), stderr: Data())
                    }
                    return ProcessResult(exitCode: 7, stdout: Data(), stderr: Data("failed\n".utf8))
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
                    if LifecycleUpSupport.isUserEnvProbeExec(args) {
                        return ProcessResult(exitCode: 0, stdout: Data(), stderr: Data())
                    }
                    return ProcessResult(exitCode: 7, stdout: Data(), stderr: Data("failed\n".utf8))
                }
                if args.first == "delete" {
                    alive = false
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

    static func execBody(_ args: [String]) -> String? {
        if let lc = args.firstIndex(of: "-lc"), lc + 1 < args.count {
            return args[lc + 1]
        }
        return nil
    }

    static func isUserEnvProbeExec(_ args: [String]) -> Bool {
        args.contains("cat /proc/self/environ")
    }

    static func execEnv(_ args: [String]) -> [String: String] {
        var env: [String: String] = [:]
        var index = 0
        while index < args.count {
            if args[index] == "-e", index + 1 < args.count {
                let pair = args[index + 1]
                if let eq = pair.firstIndex(of: "=") {
                    env[String(pair[..<eq])] = String(pair[pair.index(after: eq)...])
                }
                index += 2
            } else {
                index += 1
            }
        }
        return env
    }

    static func execUser(_ args: [String]) -> String? {
        guard let index = args.firstIndex(of: "-u"), index + 1 < args.count else { return nil }
        return args[index + 1]
    }

    static let probedVariableName = "ADEV_PROBE_VAR"
    static let probedVariableValue = "from-login-interactive"
    static let probedEnvironStdout = "\(probedVariableName)=\(probedVariableValue)\n"

    static func mockFreshCreateThenRunning(
        resolved: ResolvedWorkspace,
        execHandler: @escaping ([String]) -> ProcessResult = { _ in
            ProcessResult(exitCode: 0, stdout: Data(), stderr: Data())
        }
    ) -> MockProcessRunner {
        let mock = MockProcessRunner()
        let entry = MockProcessRunner.containerListJSON(
            id: resolved.containerName,
            state: "running",
            labels: resolved.labels
        )
        var created = false
        mock.handlers = [
            { args in
                if args.starts(with: ["list"]) {
                    let payload: [Any] = created ? [entry] : []
                    let data = try! JSONSerialization.data(withJSONObject: payload)
                    return ProcessResult(exitCode: 0, stdout: data, stderr: Data())
                }
                if args.first == "create" {
                    created = true
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
                    created = false
                    return ProcessResult(exitCode: 0, stdout: Data(), stderr: Data())
                }
                return nil
            }
        ]
        return mock
    }

    /// Capture Ready (stderr) and success JSON (stdout) while a hook is latched.
    final class WaitForIO: @unchecked Sendable {
        private let lock = NSLock()
        private var stderrText = ""
        private var stdoutText = ""

        var stderr: String {
            lock.lock()
            defer { lock.unlock() }
            return stderrText
        }

        var stdout: String {
            lock.lock()
            defer { lock.unlock() }
            return stdoutText
        }

        var sawReady: Bool { stderr.contains("Ready") }

        var sawSuccessJSON: Bool {
            let out = stdout
            return out.contains("\"outcome\"")
                && out.contains("\"containerId\"")
                && out.contains("\"remoteWorkspaceFolder\"")
        }

        func install() -> () -> Void {
            let previousEnabled = StatusPrinter.enabled
            let previousWrite = StatusPrinter.writeStderr
            let previousPhase = StatusPrinter.hasEmittedPhase
            let previousStdout = SuccessPresentation.writeStdout
            let previousEmitted = SuccessPresentation.didEmitSuccessJSON
            StatusPrinter.enabled = true
            StatusPrinter.hasEmittedPhase = false
            StatusPrinter.writeStderr = { [weak self] data in
                guard let self else { return }
                self.lock.lock()
                self.stderrText += String(data: data, encoding: .utf8) ?? ""
                self.lock.unlock()
            }
            SuccessPresentation.writeStdout = { [weak self] data in
                guard let self else { return }
                self.lock.lock()
                self.stdoutText += String(data: data, encoding: .utf8) ?? ""
                self.lock.unlock()
            }
            SuccessPresentation.didEmitSuccessJSON = false
            return {
                StatusPrinter.enabled = previousEnabled
                StatusPrinter.writeStderr = previousWrite
                StatusPrinter.hasEmittedPhase = previousPhase
                SuccessPresentation.writeStdout = previousStdout
                SuccessPresentation.didEmitSuccessJSON = previousEmitted
            }
        }
    }

    final class RunBox<Value>: @unchecked Sendable {
        let lock = NSLock()
        var value: Value?
        var error: Error?

        func succeed(_ value: Value) {
            lock.lock()
            self.value = value
            lock.unlock()
        }

        func fail(_ error: Error) {
            lock.lock()
            self.error = error
            lock.unlock()
        }
    }

    static func mockFreshCreate(
        resolved: ResolvedWorkspace,
        succeedUserEnvProbe: Bool = true,
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
                    if succeedUserEnvProbe, isUserEnvProbeExec(args) {
                        return ProcessResult(exitCode: 0, stdout: Data(), stderr: Data())
                    }
                    return execHandler(args)
                }
                if args.first == "delete" {
                    return ProcessResult(exitCode: 0, stdout: Data(), stderr: Data())
                }
                // Let MockProcessRunner default image inspect / other fallthroughs apply.
                return nil
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
    ("upStartStoppedRemeltsFeaturePostStart", {
        let ws = try TestRepo.makeTempWorkspace(configJSON: """
        {
          "image": "alpine:3.20",
          "onCreateCommand": "echo onCreate",
          "updateContentCommand": "echo updateContent",
          "postCreateCommand": "echo postCreate",
          "postStartCommand": "echo config-postStart"
        }
        """)
        defer { try? FileManager.default.removeItem(at: ws) }
        let resolved = try ConfigResolver.resolve(workspacePath: ws.path, localEnv: [:])
        let entry = MockProcessRunner.containerListJSON(
            id: resolved.containerName,
            state: "stopped",
            labels: resolved.labels,
            image: "alpine:3.20"
        )
        let metaJSON = #"[{"postStartCommand":"echo feature-from-image"}]"#
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
                if args.starts(with: ["image", "inspect"]) {
                    let obj: [String: Any] = [
                        "labels": [DevContainerMetadataLabel.labelKey: metaJSON]
                    ]
                    let data = try! JSONSerialization.data(withJSONObject: obj)
                    return ProcessResult(exitCode: 0, stdout: data, stderr: Data())
                }
                if args.first == "exec" {
                    if LifecycleUpSupport.isUserEnvProbeExec(args) {
                        return ProcessResult(exitCode: 0, stdout: Data(), stderr: Data())
                    }
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
        try MiniTest.expectEqual(execBodies, ["echo config-postStart", "echo feature-from-image"])
        try MiniTest.expect(!execBodies.contains("echo onCreate"))
        try MiniTest.expect(!execBodies.contains("echo updateContent"))
        try MiniTest.expect(!execBodies.contains("echo postCreate"))
        try MiniTest.expect(!mock.calls.contains { $0.arguments.first == "create" })
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
                    if LifecycleUpSupport.isUserEnvProbeExec(args) {
                        return ProcessResult(exitCode: 0, stdout: Data(), stderr: Data())
                    }
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
    ("upRunsInitializeCommandOnHostBeforeCreate", {
        let ws = try TestRepo.makeTempWorkspace(configJSON: """
        {
          "image": "alpine:3.20",
          "initializeCommand": "echo init-host",
          "onCreateCommand": "echo onCreate",
          "updateContentCommand": "echo updateContent",
          "postCreateCommand": "echo postCreate",
          "postStartCommand": "echo postStart"
        }
        """)
        defer { try? FileManager.default.removeItem(at: ws) }
        let resolved = try ConfigResolver.resolve(workspacePath: ws.path, localEnv: [:])
        var events: [String] = []
        let host = RecordingHostProcessRunner()
        host.handler = { call in
            // Non-repo temp workspace: the credential-seeding remote probe reports no remotes.
            if call.arguments.contains("remote") {
                return ProcessResult(exitCode: 128, stdout: Data(), stderr: Data("fatal: not a git repository".utf8))
            }
            events.append("initialize")
            return ProcessResult(exitCode: 0, stdout: Data(), stderr: Data())
        }
        let restoreHost = RecordingHostProcessRunner.install(host)
        defer { restoreHost() }
        var execBodies: [String] = []
        let mock = LifecycleUpSupport.mockFreshCreate(resolved: resolved) { args in
            if let lc = args.firstIndex(of: "-lc"), lc + 1 < args.count {
                execBodies.append(args[lc + 1])
            }
            return ProcessResult(exitCode: 0, stdout: Data(), stderr: Data())
        }
        let previousCreate = mock.handlers
        mock.handlers = [
            { args in
                if args.first == "create" {
                    events.append("create")
                }
                return nil
            }
        ] + previousCreate
        let runtime = AppleContainerRuntime(executablePath: "/usr/local/bin/container", runner: mock)
        let result = try UpCommand.run(
            options: UpOptions(workspacePath: ws.path, skipPull: true),
            runtime: runtime,
            localEnv: [:],
            hostResources: MockHostResourceInfo(physicalMemoryBytes: 64 << 30, cpuCount: 16)
        )
        try MiniTest.expectEqual(result.outcome, "success")
        try MiniTest.expectEqual(events, ["initialize", "create"])
        try MiniTest.expectEqual(host.calls.filter { $0.arguments.contains("echo init-host") }.count, 1)
        try MiniTest.expectEqual(
            (host.calls[0].currentDirectory as NSString?)?.standardizingPath,
            (ws.path as NSString).standardizingPath
        )
        try MiniTest.expect(host.calls[0].arguments.contains("echo init-host"))
        try MiniTest.expectEqual(execBodies, [
            "echo onCreate",
            "echo updateContent",
            "echo postCreate",
            "echo postStart"
        ])
    }),
    ("upReuseStillRunsInitializeCommandOnHost", {
        let ws = try TestRepo.makeTempWorkspace(configJSON: """
        {
          "image": "alpine:3.20",
          "initializeCommand": "echo init-reuse",
          "onCreateCommand": "echo onCreate",
          "updateContentCommand": "echo updateContent",
          "postCreateCommand": "echo postCreate",
          "postStartCommand": "echo postStart"
        }
        """)
        defer { try? FileManager.default.removeItem(at: ws) }
        let resolved = try ConfigResolver.resolve(workspacePath: ws.path, localEnv: [:])
        let host = RecordingHostProcessRunner()
        let restoreHost = RecordingHostProcessRunner.install(host)
        defer { restoreHost() }
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
        try MiniTest.expectEqual(host.calls.count, 1)
        try MiniTest.expect(host.calls[0].arguments.contains("echo init-reuse"))
        try MiniTest.expectEqual(
            (host.calls[0].currentDirectory as NSString?)?.standardizingPath,
            (ws.path as NSString).standardizingPath
        )
        try MiniTest.expect(!mock.calls.contains { $0.arguments.first == "exec" })
        try MiniTest.expect(!mock.calls.contains { $0.arguments.first == "create" })
        try MiniTest.expect(!mock.calls.contains { $0.arguments.first == "delete" })
        try MiniTest.expect(!mock.calls.contains { $0.arguments.first == "stop" })
    }),
    ("upStartStoppedRunsHostInitializeThenPostStart", {
        let ws = try TestRepo.makeTempWorkspace(configJSON: """
        {
          "image": "alpine:3.20",
          "initializeCommand": "echo init-start",
          "onCreateCommand": "echo onCreate",
          "updateContentCommand": "echo updateContent",
          "postCreateCommand": "echo postCreate",
          "postStartCommand": "echo postStart"
        }
        """)
        defer { try? FileManager.default.removeItem(at: ws) }
        let resolved = try ConfigResolver.resolve(workspacePath: ws.path, localEnv: [:])
        var events: [String] = []
        let host = RecordingHostProcessRunner()
        host.handler = { _ in
            events.append("initialize")
            return ProcessResult(exitCode: 0, stdout: Data(), stderr: Data())
        }
        let restoreHost = RecordingHostProcessRunner.install(host)
        defer { restoreHost() }
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
                    events.append("start")
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
        try MiniTest.expectEqual(events, ["initialize", "start"])
        try MiniTest.expectEqual(execBodies, ["echo postStart"])
        try MiniTest.expect(!mock.calls.contains { $0.arguments.first == "create" })
    }),
    ("initializeCommandFailureBlocksCreate", {
        let ws = try TestRepo.makeTempWorkspace(configJSON: """
        {
          "image": "alpine:3.20",
          "initializeCommand": "exit 7",
          "onCreateCommand": "echo should-not-run"
        }
        """)
        defer { try? FileManager.default.removeItem(at: ws) }
        let host = RecordingHostProcessRunner()
        host.exitCode = 7
        let restoreHost = RecordingHostProcessRunner.install(host)
        defer { restoreHost() }
        let resolved = try ConfigResolver.resolve(workspacePath: ws.path, localEnv: [:])
        let mock = LifecycleUpSupport.mockFreshCreate(resolved: resolved)
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
            try MiniTest.expectEqual(err.property, "initializeCommand")
        }
        try MiniTest.expectEqual(host.calls.count, 1)
        try MiniTest.expect(!mock.calls.contains { $0.arguments.first == "create" })
        try MiniTest.expect(!mock.calls.contains { $0.arguments.first == "delete" })
    }),
    ("postAttachRunsOnUpWithoutVSCode", {
        let ws = try TestRepo.makeTempWorkspace(configJSON: """
        {
          "image": "alpine:3.20",
          "postAttachCommand": "echo postAttach-up",
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
        try MiniTest.expect(execBodies.contains("echo postAttach-up"))
        try MiniTest.expect(execBodies.contains("echo postCreate"))
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
                    if !LifecycleUpSupport.isUserEnvProbeExec(args) {
                        execCount += 1
                    }
                    return ProcessResult(exitCode: 0, stdout: Data(), stderr: Data())
                }
                return nil
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
    }),
    ("defaultWaitForAllowsReadyBeforePostCreate", {
        let ws = try TestRepo.makeTempWorkspace(configJSON: """
        {
          "image": "alpine:3.20",
          "updateContentCommand": "echo updateContent",
          "postCreateCommand": "echo postCreate",
          "postStartCommand": "echo postStart"
        }
        """)
        defer { try? FileManager.default.removeItem(at: ws) }
        let resolved = try ConfigResolver.resolve(workspacePath: ws.path, localEnv: [:])
        try MiniTest.expectEqual(resolved.config.waitFor, .updateContentCommand)

        let io = LifecycleUpSupport.WaitForIO()
        let restoreIO = io.install()
        defer { restoreIO() }

        let postCreateStarted = DispatchSemaphore(value: 0)
        let postCreateRelease = DispatchSemaphore(value: 0)
        let runDone = DispatchSemaphore(value: 0)
        let lock = NSLock()
        var execBodies: [String] = []
        let box = LifecycleUpSupport.RunBox<UpResult>()

        let mock = LifecycleUpSupport.mockFreshCreate(resolved: resolved) { args in
            if let body = LifecycleUpSupport.execBody(args) {
                lock.lock()
                execBodies.append(body)
                lock.unlock()
                if body == "echo postCreate" {
                    postCreateStarted.signal()
                    _ = postCreateRelease.wait(timeout: .now() + 5)
                }
            }
            return ProcessResult(exitCode: 0, stdout: Data(), stderr: Data())
        }
        let runtime = AppleContainerRuntime(executablePath: "/usr/local/bin/container", runner: mock)
        DispatchQueue.global(qos: .userInitiated).async {
            do {
                box.succeed(try UpCommand.run(
                    options: UpOptions(workspacePath: ws.path, skipPull: true),
                    runtime: runtime,
                    localEnv: [:]
                ))
            } catch {
                box.fail(error)
            }
            runDone.signal()
        }
        defer { postCreateRelease.signal() }
        try MiniTest.expect(
            postCreateStarted.wait(timeout: .now() + 5) == .success,
            "postCreate must start so Ready can be observed before it returns"
        )
        try MiniTest.expect(io.sawReady, "Ready must appear after updateContent and before postCreate returns")
        postCreateRelease.signal()
        try MiniTest.expect(runDone.wait(timeout: .now() + 5) == .success, "up must finish after remaining hooks")
        if let runError = box.error {
            throw MiniTest.Failure(message: "up failed: \(runError)")
        }
        try MiniTest.expectEqual(box.value?.outcome, "success")
        lock.lock()
        let bodies = execBodies
        lock.unlock()
        try MiniTest.expectEqual(bodies, [
            "echo updateContent",
            "echo postCreate",
            "echo postStart"
        ])
    }),
    ("waitForPostCreateDelaysReadyUntilPostCreate", {
        let ws = try TestRepo.makeTempWorkspace(configJSON: """
        {
          "image": "alpine:3.20",
          "waitFor": "postCreateCommand",
          "postCreateCommand": "echo postCreate",
          "postStartCommand": "echo postStart"
        }
        """)
        defer { try? FileManager.default.removeItem(at: ws) }
        let resolved = try ConfigResolver.resolve(workspacePath: ws.path, localEnv: [:])
        try MiniTest.expectEqual(resolved.config.waitFor, .postCreateCommand)

        let io = LifecycleUpSupport.WaitForIO()
        let restoreIO = io.install()
        defer { restoreIO() }

        let postCreateStarted = DispatchSemaphore(value: 0)
        let postCreateRelease = DispatchSemaphore(value: 0)
        let runDone = DispatchSemaphore(value: 0)
        let lock = NSLock()
        var execBodies: [String] = []
        let box = LifecycleUpSupport.RunBox<UpResult>()

        let mock = LifecycleUpSupport.mockFreshCreate(resolved: resolved) { args in
            if let body = LifecycleUpSupport.execBody(args) {
                lock.lock()
                execBodies.append(body)
                lock.unlock()
                if body == "echo postCreate" {
                    postCreateStarted.signal()
                    _ = postCreateRelease.wait(timeout: .now() + 5)
                }
            }
            return ProcessResult(exitCode: 0, stdout: Data(), stderr: Data())
        }
        let runtime = AppleContainerRuntime(executablePath: "/usr/local/bin/container", runner: mock)
        DispatchQueue.global(qos: .userInitiated).async {
            do {
                box.succeed(try UpCommand.run(
                    options: UpOptions(workspacePath: ws.path, skipPull: true),
                    runtime: runtime,
                    localEnv: [:]
                ))
            } catch {
                box.fail(error)
            }
            runDone.signal()
        }
        defer { postCreateRelease.signal() }
        try MiniTest.expect(
            postCreateStarted.wait(timeout: .now() + 5) == .success,
            "postCreate must start"
        )
        try MiniTest.expect(
            !io.sawReady,
            "Ready / open / postAttach must wait until postCreate finishes"
        )
        postCreateRelease.signal()
        try MiniTest.expect(runDone.wait(timeout: .now() + 5) == .success, "up must finish")
        if let runError = box.error {
            throw MiniTest.Failure(message: "up failed: \(runError)")
        }
        try MiniTest.expectEqual(box.value?.outcome, "success")
        try MiniTest.expect(io.sawReady, "Ready must emit after postCreate")
        lock.lock()
        let bodies = execBodies
        lock.unlock()
        try MiniTest.expectEqual(bodies, [
            "echo postCreate",
            "echo postStart"
        ])
    }),
    ("successJSONWaitsForWaitForNotLaterHooks", {
        let ws = try TestRepo.makeTempWorkspace(configJSON: """
        {
          "image": "alpine:3.20",
          "updateContentCommand": "echo updateContent",
          "postCreateCommand": "echo postCreate"
        }
        """)
        defer { try? FileManager.default.removeItem(at: ws) }
        let resolved = try ConfigResolver.resolve(workspacePath: ws.path, localEnv: [:])

        let io = LifecycleUpSupport.WaitForIO()
        let restoreIO = io.install()
        defer { restoreIO() }

        let postCreateStarted = DispatchSemaphore(value: 0)
        let postCreateRelease = DispatchSemaphore(value: 0)
        let runDone = DispatchSemaphore(value: 0)
        var jsonBeforeUpdateContent = false
        let box = LifecycleUpSupport.RunBox<UpResult>()

        let mock = LifecycleUpSupport.mockFreshCreate(resolved: resolved) { args in
            guard let body = LifecycleUpSupport.execBody(args) else {
                return ProcessResult(exitCode: 0, stdout: Data(), stderr: Data())
            }
            if body == "echo updateContent" {
                jsonBeforeUpdateContent = io.sawSuccessJSON
            }
            if body == "echo postCreate" {
                postCreateStarted.signal()
                _ = postCreateRelease.wait(timeout: .now() + 5)
            }
            return ProcessResult(exitCode: 0, stdout: Data(), stderr: Data())
        }
        let runtime = AppleContainerRuntime(executablePath: "/usr/local/bin/container", runner: mock)
        DispatchQueue.global(qos: .userInitiated).async {
            do {
                box.succeed(try UpCommand.run(
                    options: UpOptions(workspacePath: ws.path, jsonOutput: true, skipPull: true),
                    runtime: runtime,
                    localEnv: [:]
                ))
            } catch {
                box.fail(error)
            }
            runDone.signal()
        }
        defer { postCreateRelease.signal() }
        try MiniTest.expect(
            postCreateStarted.wait(timeout: .now() + 5) == .success,
            "postCreate must start so JSON can be observed before it finishes"
        )
        try MiniTest.expect(!jsonBeforeUpdateContent, "success JSON must not appear before updateContent")
        try MiniTest.expect(io.sawSuccessJSON, "success JSON may appear before postCreate finishes")
        postCreateRelease.signal()
        try MiniTest.expect(runDone.wait(timeout: .now() + 5) == .success, "process must wait for remaining hooks")
        if let runError = box.error {
            throw MiniTest.Failure(message: "up failed: \(runError)")
        }
        try MiniTest.expectEqual(box.value?.outcome, "success")
        try MiniTest.expect(io.sawSuccessJSON)
        try MiniTest.expect(io.stdout.contains(resolved.containerName))
    }),
    ("backgroundCreatePathHookFailureStillDeletes", {
        let ws = try TestRepo.makeTempWorkspace(configJSON: """
        {
          "image": "alpine:3.20",
          "updateContentCommand": "echo updateContent",
          "postCreateCommand": "exit 7"
        }
        """)
        defer { try? FileManager.default.removeItem(at: ws) }
        let resolved = try ConfigResolver.resolve(workspacePath: ws.path, localEnv: [:])

        let io = LifecycleUpSupport.WaitForIO()
        let restoreIO = io.install()
        defer { restoreIO() }

        var readyBeforePostCreateFail = false
        let mock = LifecycleUpSupport.mockFreshCreate(resolved: resolved) { args in
            if let body = LifecycleUpSupport.execBody(args), body == "exit 7" {
                readyBeforePostCreateFail = io.sawReady
                return ProcessResult(exitCode: 7, stdout: Data(), stderr: Data("boom\n".utf8))
            }
            return ProcessResult(exitCode: 0, stdout: Data(), stderr: Data())
        }
        let runtime = AppleContainerRuntime(executablePath: "/usr/local/bin/container", runner: mock)
        try MiniTest.expectThrows({
            _ = try UpCommand.run(
                options: UpOptions(workspacePath: ws.path, jsonOutput: true, skipPull: true),
                runtime: runtime,
                localEnv: [:]
            )
        }) { error in
            let err = error as! CLIError
            try MiniTest.expectEqual(err.code, CLIErrorCode.postCreateFailed)
            try MiniTest.expectEqual(err.property, "postCreateCommand")
        }
        try MiniTest.expect(readyBeforePostCreateFail, "Ready may already be emitted when postCreate fails")
        try MiniTest.expect(io.sawSuccessJSON, "success JSON may already be emitted at waitFor")
        try MiniTest.expect(mock.calls.contains {
            $0.arguments.first == "delete" && $0.arguments.contains(resolved.containerName)
        })
    }),
    ("resumeDoesNotReWaitCreatePathWaitFor", {
        let ws = try TestRepo.makeTempWorkspace(configJSON: LifecycleUpSupport.fullHooksJSON)
        defer { try? FileManager.default.removeItem(at: ws) }
        let resolved = try ConfigResolver.resolve(workspacePath: ws.path, localEnv: [:])

        let io = LifecycleUpSupport.WaitForIO()
        let restoreIO = io.install()
        defer { restoreIO() }

        let postStartStarted = DispatchSemaphore(value: 0)
        let postStartRelease = DispatchSemaphore(value: 0)
        let runDone = DispatchSemaphore(value: 0)
        let lock = NSLock()
        var execBodies: [String] = []
        let box = LifecycleUpSupport.RunBox<UpResult>()

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
                    if let body = LifecycleUpSupport.execBody(args) {
                        lock.lock()
                        execBodies.append(body)
                        lock.unlock()
                        if body == "echo postStart" {
                            postStartStarted.signal()
                            _ = postStartRelease.wait(timeout: .now() + 5)
                        }
                    }
                    return ProcessResult(exitCode: 0, stdout: Data(), stderr: Data())
                }
                return nil
            }
        ]
        let runtime = AppleContainerRuntime(executablePath: "/usr/local/bin/container", runner: mock)
        DispatchQueue.global(qos: .userInitiated).async {
            do {
                box.succeed(try UpCommand.run(
                    options: UpOptions(workspacePath: ws.path, skipPull: true),
                    runtime: runtime,
                    localEnv: [:]
                ))
            } catch {
                box.fail(error)
            }
            runDone.signal()
        }
        defer { postStartRelease.signal() }
        try MiniTest.expect(
            postStartStarted.wait(timeout: .now() + 5) == .success,
            "resume postStart must still run"
        )
        try MiniTest.expect(
            io.sawReady,
            "default waitFor must not block Ready on create-path stages during resume"
        )
        postStartRelease.signal()
        try MiniTest.expect(runDone.wait(timeout: .now() + 5) == .success, "up start-stopped must finish")
        if let runError = box.error {
            throw MiniTest.Failure(message: "up start-stopped failed: \(runError)")
        }
        try MiniTest.expectEqual(box.value?.outcome, "success")
        lock.lock()
        let upBodies = execBodies
        lock.unlock()
        try MiniTest.expectEqual(upBodies, ["echo postStart"])

        // Bare start: create-path waitFor is already satisfied; do not re-exec those stages.
        let startLabels: [String: String] = [
            ContainerIdentity.labelManaged: ContainerIdentity.managedValue,
            ContainerIdentity.labelWorkspaceMode: ContainerIdentity.workspaceModeBind,
            ContainerIdentity.labelLocalFolder: ws.path,
            ContainerIdentity.labelConfigFile: ws.appendingPathComponent(".devcontainer/devcontainer.json").path,
            ContainerIdentity.labelWorkspaceFolder: "/workspaces/app"
        ]
        let startEntry = MockProcessRunner.containerListJSON(
            id: "adev-app-waitfor-start",
            state: "stopped",
            labels: startLabels
        )
        var startBodies: [String] = []
        let startMock = MockProcessRunner()
        startMock.handlers = [
            { args in
                if args.starts(with: ["list"]) {
                    let data = try! JSONSerialization.data(withJSONObject: [startEntry])
                    return ProcessResult(exitCode: 0, stdout: data, stderr: Data())
                }
                if args.first == "start" {
                    return ProcessResult(exitCode: 0, stdout: Data(), stderr: Data())
                }
                if args.first == "inspect" {
                    let data = try! JSONSerialization.data(withJSONObject: startEntry)
                    return ProcessResult(exitCode: 0, stdout: data, stderr: Data())
                }
                if args.first == "exec" {
                    if let body = LifecycleUpSupport.execBody(args) {
                        startBodies.append(body)
                    }
                    return ProcessResult(exitCode: 0, stdout: Data(), stderr: Data())
                }
                return nil
            }
        ]
        let startRuntime = AppleContainerRuntime(
            executablePath: "/usr/local/bin/container",
            runner: startMock
        )
        try StartCommand.run(
            options: StartOptions(name: "adev-app-waitfor-start"),
            runtime: startRuntime
        )
        try MiniTest.expect(startMock.calls.contains { $0.arguments.first == "start" })
        try MiniTest.expect(startBodies.contains("echo postStart"))
        try MiniTest.expect(!startBodies.contains("echo onCreate"))
        try MiniTest.expect(!startBodies.contains("echo updateContent"))
        try MiniTest.expect(!startBodies.contains("echo postCreate"))
    }),
    ("defaultProbeMergesIntoPostCreateAndExec", {
        let ws = try TestRepo.makeTempWorkspace(configJSON: """
        {
          "image": "alpine:3.20",
          "postCreateCommand": "echo postCreate"
        }
        """)
        defer { try? FileManager.default.removeItem(at: ws) }
        let resolved = try ConfigResolver.resolve(workspacePath: ws.path, localEnv: [:])
        try MiniTest.expectEqual(resolved.config.userEnvProbe, .loginInteractiveShell)

        var probeExecs = 0
        let mock = LifecycleUpSupport.mockFreshCreateThenRunning(resolved: resolved) { args in
            if LifecycleUpSupport.isUserEnvProbeExec(args) {
                probeExecs += 1
                return ProcessResult(
                    exitCode: 0,
                    stdout: Data(LifecycleUpSupport.probedEnvironStdout.utf8),
                    stderr: Data()
                )
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
        try MiniTest.expect(probeExecs > 0, "omitted userEnvProbe must probe login-interactive env")

        let postCreateExec = mock.calls.first { call in
            call.arguments.first == "exec"
                && LifecycleUpSupport.execBody(call.arguments) == "echo postCreate"
        }
        guard let postCreateExec else {
            throw MiniTest.Failure(message: "expected postCreate exec")
        }
        try MiniTest.expectEqual(
            LifecycleUpSupport.execEnv(postCreateExec.arguments)[LifecycleUpSupport.probedVariableName],
            LifecycleUpSupport.probedVariableValue,
            "postCreate must see probed login-interactive env"
        )

        let code = try ExecCommand.run(
            options: ExecOptions(command: ["echo", "ok"], name: resolved.containerName),
            runtime: runtime
        )
        try MiniTest.expectEqual(code, 0)
        let userExec = mock.calls.last { call in
            call.arguments.first == "exec" && call.arguments.contains("echo") && call.arguments.contains("ok")
        }
        guard let userExec else {
            throw MiniTest.Failure(message: "expected adevcontainer exec injection")
        }
        try MiniTest.expectEqual(
            LifecycleUpSupport.execEnv(userExec.arguments)[LifecycleUpSupport.probedVariableName],
            LifecycleUpSupport.probedVariableValue,
            "exec must see probed login-interactive env"
        )
    }),
    ("noneSkipsProbe", {
        let ws = try TestRepo.makeTempWorkspace(configJSON: """
        {
          "image": "alpine:3.20",
          "userEnvProbe": "none",
          "postCreateCommand": "echo postCreate"
        }
        """)
        defer { try? FileManager.default.removeItem(at: ws) }
        let resolved = try ConfigResolver.resolve(workspacePath: ws.path, localEnv: [:])
        try MiniTest.expectEqual(resolved.config.userEnvProbe, .none)

        var probeExecs = 0
        let mock = LifecycleUpSupport.mockFreshCreateThenRunning(resolved: resolved) { args in
            if LifecycleUpSupport.isUserEnvProbeExec(args) {
                probeExecs += 1
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
        try MiniTest.expectEqual(probeExecs, 0, "userEnvProbe none must not probe")

        let code = try ExecCommand.run(
            options: ExecOptions(command: ["echo", "ok"], name: resolved.containerName),
            runtime: runtime
        )
        try MiniTest.expectEqual(code, 0)
        try MiniTest.expectEqual(probeExecs, 0, "exec must not probe when userEnvProbe is none")
        try MiniTest.expect(mock.calls.contains {
            $0.arguments.first == "exec" && LifecycleUpSupport.execBody($0.arguments) == "echo postCreate"
        })
    }),
    ("probeUsesRemoteConnectionUserNotContainerUser", {
        let ws = try TestRepo.makeTempWorkspace(configJSON: """
        {
          "image": "alpine:3.20",
          "remoteUser": "alice",
          "containerUser": "bob",
          "postCreateCommand": "echo postCreate"
        }
        """)
        defer { try? FileManager.default.removeItem(at: ws) }
        let resolved = try ConfigResolver.resolve(workspacePath: ws.path, localEnv: [:])

        var probeUsers: [String?] = []
        let mock = LifecycleUpSupport.mockFreshCreate(resolved: resolved, succeedUserEnvProbe: false) { args in
            if LifecycleUpSupport.isUserEnvProbeExec(args) {
                probeUsers.append(LifecycleUpSupport.execUser(args))
                return ProcessResult(
                    exitCode: 0,
                    stdout: Data(LifecycleUpSupport.probedEnvironStdout.utf8),
                    stderr: Data()
                )
            }
            return ProcessResult(exitCode: 0, stdout: Data(), stderr: Data())
        }
        let runtime = AppleContainerRuntime(executablePath: "/usr/local/bin/container", runner: mock)
        _ = try UpCommand.run(
            options: UpOptions(workspacePath: ws.path, skipPull: true),
            runtime: runtime,
            localEnv: [:]
        )
        try MiniTest.expect(!probeUsers.isEmpty, "probe must run when userEnvProbe is not none")
        try MiniTest.expect(probeUsers.allSatisfy { $0 == "alice" }, "probe must use remoteUser alice")
        try MiniTest.expect(!probeUsers.contains { $0 == "bob" }, "probe must not use containerUser bob")
    }),
    ("probeFailureKeepsTheContainer", {
        let ws = try TestRepo.makeTempWorkspace(configJSON: """
        {
          "image": "alpine:3.20",
          "postCreateCommand": "echo postCreate"
        }
        """)
        defer { try? FileManager.default.removeItem(at: ws) }
        let resolved = try ConfigResolver.resolve(workspacePath: ws.path, localEnv: [:])
        var sawPostCreate = false
        let mock = LifecycleUpSupport.mockFreshCreate(resolved: resolved, succeedUserEnvProbe: false) { args in
            if LifecycleUpSupport.isUserEnvProbeExec(args) {
                return ProcessResult(exitCode: 3, stdout: Data(), stderr: Data("probe-boom\n".utf8))
            }
            if LifecycleUpSupport.execBody(args) == "echo postCreate" {
                sawPostCreate = true
            }
            return ProcessResult(exitCode: 0, stdout: Data(), stderr: Data())
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
            try MiniTest.expectEqual(err.property, "userEnvProbe")
            try MiniTest.expect(err.message.contains("userEnvProbe"))
        }
        try MiniTest.expect(!sawPostCreate, "probe failure must block later lifecycle execs")
        try MiniTest.expect(!mock.calls.contains {
            $0.arguments.first == "delete" && $0.arguments.contains(resolved.containerName)
        }, "probe failure must keep the container")
    }),
    ("execIsNotAttach", {
        let ws = try TestRepo.makeTempWorkspace(configJSON: """
        {
          "image": "alpine:3.20",
          "userEnvProbe": "none",
          "postAttachCommand": "exit 99"
        }
        """)
        defer { try? FileManager.default.removeItem(at: ws) }
        let resolved = try ConfigResolver.resolve(workspacePath: ws.path, localEnv: [:])
        try MiniTest.expect(resolved.config.postAttachCommand != nil)
        let entry = MockProcessRunner.containerListJSON(
            id: resolved.containerName,
            state: "running",
            labels: resolved.labels
        )
        let mock = MockProcessRunner()
        mock.handlers = [
            { args in
                if args.starts(with: ["list"]) {
                    let data = try! JSONSerialization.data(withJSONObject: [entry])
                    return ProcessResult(exitCode: 0, stdout: data, stderr: Data())
                }
                if args.first == "exec" {
                    if LifecycleUpSupport.execBody(args) == "exit 99" {
                        return ProcessResult(exitCode: 99, stdout: Data(), stderr: Data("attach\n".utf8))
                    }
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
        try MiniTest.expect(!mock.calls.contains {
            $0.arguments.first == "exec" && LifecycleUpSupport.execBody($0.arguments) == "exit 99"
        }, "exec must not run postAttachCommand")
    }),
    ("stopContainerConfigStillStopsOnStop", {
        for actionJSON in [#" "shutdownAction": "stopContainer" "#, ""] {
            let fields = actionJSON.isEmpty
                ? #"{ "image": "alpine:3.20" }"#
                : """
                { "image": "alpine:3.20", \(actionJSON) }
                """
            let ws = try TestRepo.makeTempWorkspace(configJSON: fields)
            defer { try? FileManager.default.removeItem(at: ws) }
            let resolved = try ConfigResolver.resolve(workspacePath: ws.path, localEnv: [:])
            if actionJSON.isEmpty {
                try MiniTest.expectEqual(resolved.config.shutdownAction, .stopContainer)
            } else {
                try MiniTest.expectEqual(resolved.config.shutdownAction, .stopContainer)
            }
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
                    if args.first == "stop" {
                        return ProcessResult(exitCode: 0, stdout: Data(), stderr: Data())
                    }
                    return nil
                }
            ]
            let runtime = AppleContainerRuntime(executablePath: "/usr/local/bin/container", runner: mock)
            try StopCommand.run(name: resolved.containerName, runtime: runtime)
            try MiniTest.expect(
                mock.calls.contains { $0.arguments == ["stop", resolved.containerName] },
                "explicit stop must stop when shutdownAction is stopContainer or omitted"
            )
        }
    }),
    ("noneDoesNotDisableExplicitStop", {
        let ws = try TestRepo.makeTempWorkspace(configJSON: """
        { "image": "alpine:3.20", "shutdownAction": "none" }
        """)
        defer { try? FileManager.default.removeItem(at: ws) }
        let resolved = try ConfigResolver.resolve(workspacePath: ws.path, localEnv: [:])
        try MiniTest.expectEqual(resolved.config.shutdownAction, .none)
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
                if args.first == "stop" {
                    return ProcessResult(exitCode: 0, stdout: Data(), stderr: Data())
                }
                return nil
            }
        ]
        let runtime = AppleContainerRuntime(executablePath: "/usr/local/bin/container", runner: mock)
        try StopCommand.run(name: resolved.containerName, runtime: runtime)
        try MiniTest.expect(
            mock.calls.contains { $0.arguments == ["stop", resolved.containerName] },
            "shutdownAction none must not disable explicit stop"
        )
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
        onExec: (([String]) -> ProcessResult)? = nil,
        baseUser: String? = nil
    ) -> ([String]) -> ProcessResult? {
        { args in
            if args.starts(with: ["list"]) {
                let data = try! JSONSerialization.data(withJSONObject: [] as [Any])
                return ProcessResult(exitCode: 0, stdout: data, stderr: Data())
            }
            if let inspect = MockProcessRunner.imageInspectHandler(baseUser: baseUser)(args) {
                return inspect
            }
            if args.starts(with: ["image", "list"]) {
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
                if LifecycleUpSupport.isUserEnvProbeExec(args) {
                    return ProcessResult(exitCode: 0, stdout: Data(), stderr: Data())
                }
                if let onExec { return onExec(args) }
                return ProcessResult(exitCode: 0, stdout: Data(), stderr: Data())
            }
            return nil
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
        let expectedBase = ContainerIdentity.humanBase(workspacePath: ws.path)
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
    ("upNoFeaturesRunsImageMetadataCreatePathHooks", {
        let ws = try TestRepo.makeTempWorkspace(configJSON: #"{ "image": "alpine:3.20" }"#)
        defer { try? FileManager.default.removeItem(at: ws) }
        let resolved = try ConfigResolver.resolve(workspacePath: ws.path, localEnv: [:])
        try MiniTest.expect(resolved.config.features.isEmpty)
        let metaJSON = #"[{"onCreateCommand":"echo image-onCreate"},{"updateContentCommand":"echo image-updateContent"},{"postCreateCommand":"echo image-postCreate"},{"postStartCommand":"echo image-postStart"},{"postAttachCommand":"echo image-postAttach"}]"#
        var execBodies: [String] = []
        let mock = MockProcessRunner()
        mock.handlers = [
            { args in
                if args.starts(with: ["list"]) {
                    let data = try! JSONSerialization.data(withJSONObject: [] as [Any])
                    return ProcessResult(exitCode: 0, stdout: data, stderr: Data())
                }
                if args.starts(with: ["image", "inspect"]) {
                    return MockProcessRunner.imageInspectHandler(
                        baseUser: nil,
                        labels: [DevContainerMetadataLabel.labelKey: metaJSON]
                    )(args)
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
                    if LifecycleUpSupport.isUserEnvProbeExec(args) {
                        return ProcessResult(exitCode: 0, stdout: Data(), stderr: Data())
                    }
                    if let lc = args.firstIndex(of: "-lc"), lc + 1 < args.count {
                        execBodies.append(args[lc + 1])
                    }
                    return ProcessResult(exitCode: 0, stdout: Data(), stderr: Data())
                }
                if args.first == "delete" {
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
        try MiniTest.expect(!mock.calls.contains { $0.arguments.first == "build" })
        try MiniTest.expect(execBodies.contains("echo image-onCreate"))
        try MiniTest.expect(execBodies.contains("echo image-updateContent"))
        try MiniTest.expect(execBodies.contains("echo image-postCreate"))
        try MiniTest.expect(execBodies.contains("echo image-postStart"))
        try MiniTest.expect(execBodies.contains("echo image-postAttach"))
    }),
    ("upFinishKeepsBaseImagePostAttachAfterRemelt", {
        // Apply already unioned base-image postAttach; finish remelt from a
        // features-only image LABEL must not replace it away.
        let ref = "ghcr.io/adevcontainer/features/sample-a:1"
        let fixture = TestRepo.root()
            .appendingPathComponent("Tests/Fixtures/features-sample/sample-a").path
        let cache = FileManager.default.temporaryDirectory
            .appendingPathComponent("feat-finish-union-\(UUID().uuidString)", isDirectory: true).path
        defer { try? FileManager.default.removeItem(atPath: cache) }
        let hookDir = (cache as NSString).appendingPathComponent("hook-feature")
        try FileManager.default.createDirectory(atPath: hookDir, withIntermediateDirectories: true)
        try """
        {"id":"hook-feature","postAttachCommand":"echo feature-attach"}
        """.write(
            toFile: (hookDir as NSString).appendingPathComponent("devcontainer-feature.json"),
            atomically: true,
            encoding: .utf8
        )
        try "#!/bin/sh\n".write(
            toFile: (hookDir as NSString).appendingPathComponent("install.sh"),
            atomically: true,
            encoding: .utf8
        )
        let hookRef = "./.devcontainer/features/hook-feature"
        let ws = try TestRepo.makeTempWorkspace(configJSON: """
        {
          "image": "alpine:3.20",
          "features": { "\(hookRef)": {} }
        }
        """)
        defer { try? FileManager.default.removeItem(at: ws) }
        let dest = ws.appendingPathComponent(".devcontainer/features/hook-feature", isDirectory: true)
        try FileManager.default.createDirectory(at: dest.deletingLastPathComponent(), withIntermediateDirectories: true)
        try FileManager.default.copyItem(atPath: hookDir, toPath: dest.path)
        let restore = FeaturesUpTestSupport.installOverrides(
            fetcher: MockFeatureFetcher(packagesByRef: [hookRef: hookDir, ref: fixture]),
            cache: cache
        )
        defer { restore() }
        let baseMeta = #"[{"postAttachCommand":"echo base-attach"}]"#
        let featureOnlyMeta = #"[{"postAttachCommand":"echo feature-attach"}]"#
        var execBodies: [String] = []
        let mock = MockProcessRunner()
        mock.handlers = [
            { args in
                if args.starts(with: ["list"]) {
                    let data = try! JSONSerialization.data(withJSONObject: [] as [Any])
                    return ProcessResult(exitCode: 0, stdout: data, stderr: Data())
                }
                if args.starts(with: ["image", "inspect"]), let inspected = args.last {
                    let isDerived = inspected.hasPrefix("adev-") || inspected.hasPrefix("adevcontainer:")
                    let payload = MockProcessRunner.imageInspectJSON(
                        reference: inspected,
                        user: "root",
                        labels: [
                            DevContainerMetadataLabel.labelKey: isDerived ? featureOnlyMeta : baseMeta
                        ]
                    )
                    let data = try! JSONSerialization.data(withJSONObject: payload)
                    return ProcessResult(exitCode: 0, stdout: data, stderr: Data())
                }
                if args.starts(with: ["image", "list"]) {
                    return ProcessResult(exitCode: 1, stdout: Data(), stderr: Data("missing".utf8))
                }
                if args.first == "build" {
                    return ProcessResult(exitCode: 0, stdout: Data(), stderr: Data())
                }
                if args.first == "create" {
                    return ProcessResult(exitCode: 0, stdout: Data("ctr\n".utf8), stderr: Data())
                }
                if args.first == "start" || args.first == "delete" {
                    return ProcessResult(exitCode: 0, stdout: Data(), stderr: Data())
                }
                if args.first == "exec" {
                    if LifecycleUpSupport.isUserEnvProbeExec(args) {
                        return ProcessResult(exitCode: 0, stdout: Data(), stderr: Data())
                    }
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
        try MiniTest.expect(
            execBodies.contains("echo base-attach"),
            "up finish remelt must keep base-image postAttach that apply already unioned"
        )
        try MiniTest.expect(execBodies.contains("echo feature-attach"))
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
        let expectedBase = ContainerIdentity.humanBase(workspacePath: ws.path)
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
    }),
    ("upWithLocalFeaturesConfigDirRef", {
        let cache = FileManager.default.temporaryDirectory
            .appendingPathComponent("feat-up-cfgdir-\(UUID().uuidString)", isDirectory: true).path
        defer { try? FileManager.default.removeItem(atPath: cache) }

        let ws = try TestRepo.makeTempWorkspace(configJSON: """
        {
          "image": "alpine:3.20",
          "features": {
            "./features/sample-a": { "greeting": "local" }
          }
        }
        """)
        defer { try? FileManager.default.removeItem(at: ws) }

        let featuresRoot = ws.appendingPathComponent(".devcontainer/features", isDirectory: true)
        try FileManager.default.createDirectory(at: featuresRoot, withIntermediateDirectories: true)
        try FileManager.default.copyItem(
            atPath: TestRepo.root()
                .appendingPathComponent("Tests/Fixtures/features-sample/sample-a").path,
            toPath: featuresRoot.appendingPathComponent("sample-a").path
        )

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
        mock.handlers = [FeaturesUpTestSupport.mockHandler()]
        let runtime = AppleContainerRuntime(executablePath: "/usr/local/bin/container", runner: mock)
        let result = try UpCommand.run(
            options: UpOptions(workspacePath: ws.path, skipPull: true),
            runtime: runtime,
            localEnv: [:]
        )
        try MiniTest.expectEqual(result.outcome, "success")
        try MiniTest.expect(mock.calls.contains { $0.arguments.first == "build" })
    }),
    ("upReusesSameWorkspaceSameNameOccupant", {
        let workspace = try TestRepo.makeTempWorkspace(configJSON: """
        { "name": "My App", "image": "alpine:3.20" }
        """)
        defer { try? FileManager.default.removeItem(at: workspace) }
        let mock = MockProcessRunner()
        let resolved = try ConfigResolver.resolve(workspacePath: workspace.path, localEnv: [:])
        try MiniTest.expectEqual(resolved.containerName, "my-app")
        let entry = MockProcessRunner.containerListJSON(
            id: "my-app",
            state: "running",
            labels: resolved.labels
        )
        mock.handlers = [
            { args in
                if args.starts(with: ["list"]) {
                    return ProcessResult(
                        exitCode: 0,
                        stdout: try! JSONSerialization.data(withJSONObject: [entry]),
                        stderr: Data()
                    )
                }
                return nil
            }
        ]
        let runtime = AppleContainerRuntime(executablePath: "/usr/local/bin/container", runner: mock)
        final class Writes: @unchecked Sendable { var lines: [String] = [] }
        let writes = Writes()
        let result = try UpCommand.run(
            options: UpOptions(workspacePath: workspace.path, skipPull: true),
            runtime: runtime,
            localEnv: [:],
            isTTY: true,
            openEditorPrompt: RecoveryOpenEditorPrompt(
                readLine: { "y" },
                writeError: { writes.lines.append($0) }
            )
        )
        try MiniTest.expectEqual(result.containerId, "my-app")
        try MiniTest.expect(!mock.calls.contains { $0.arguments.first == "create" })
        try MiniTest.expect(!mock.calls.contains { $0.arguments.first == "delete" })
        try MiniTest.expect(
            !writes.lines.joined().contains(BringUpRecovery.changeNamePromptText),
            "same-workspace reuse must not offer rename"
        )
    }),
    ("upHashMismatchOnSameWorkspaceSameNameNoPicker", {
        let workspace = try TestRepo.makeTempWorkspace(configJSON: """
        { "name": "My App", "image": "alpine:3.20" }
        """)
        defer { try? FileManager.default.removeItem(at: workspace) }
        let mock = MockProcessRunner()
        let resolved = try ConfigResolver.resolve(workspacePath: workspace.path, localEnv: [:])
        var labels = resolved.labels
        labels[ContainerIdentity.labelConfigHash] = "old-hash"
        let entry = MockProcessRunner.containerListJSON(
            id: "my-app",
            state: "running",
            labels: labels
        )
        mock.handlers = [
            { args in
                if args.starts(with: ["list"]) {
                    return ProcessResult(
                        exitCode: 0,
                        stdout: try! JSONSerialization.data(withJSONObject: [entry]),
                        stderr: Data()
                    )
                }
                return nil
            }
        ]
        let runtime = AppleContainerRuntime(executablePath: "/usr/local/bin/container", runner: mock)
        final class Writes: @unchecked Sendable { var lines: [String] = [] }
        let writes = Writes()
        try MiniTest.expectThrows({
            _ = try UpCommand.run(
                options: UpOptions(workspacePath: workspace.path, skipPull: true),
                runtime: runtime,
                localEnv: [:],
                isTTY: true,
                openEditorPrompt: RecoveryOpenEditorPrompt(
                    readLine: { "y" },
                    writeError: { writes.lines.append($0) }
                )
            )
        }) { error in
            try MiniTest.expectEqual((error as? CLIError)?.code, CLIErrorCode.configHashMismatch)
        }
        try MiniTest.expect(!mock.calls.contains { $0.arguments.first == "delete" })
        try MiniTest.expect(!writes.lines.joined().contains(BringUpRecovery.changeNamePromptText))
    }),
    ("upSameWorkspaceDifferentNameIsDeleteHint", {
        let workspace = try TestRepo.makeTempWorkspace(configJSON: """
        { "name": "My App", "image": "alpine:3.20" }
        """)
        defer { try? FileManager.default.removeItem(at: workspace) }
        let mock = MockProcessRunner()
        let resolved = try ConfigResolver.resolve(workspacePath: workspace.path, localEnv: [:])
        let leftover = MockProcessRunner.containerListJSON(
            id: "adev-my-app-abc123def456",
            state: "running",
            labels: resolved.labels
        )
        mock.handlers = [
            { args in
                if args.starts(with: ["list"]) {
                    return ProcessResult(
                        exitCode: 0,
                        stdout: try! JSONSerialization.data(withJSONObject: [leftover]),
                        stderr: Data()
                    )
                }
                return nil
            }
        ]
        let runtime = AppleContainerRuntime(executablePath: "/usr/local/bin/container", runner: mock)
        final class Writes: @unchecked Sendable { var lines: [String] = [] }
        let writes = Writes()
        try MiniTest.expectThrows({
            _ = try UpCommand.run(
                options: UpOptions(workspacePath: workspace.path, skipPull: true),
                runtime: runtime,
                localEnv: [:],
                isTTY: true,
                openEditorPrompt: RecoveryOpenEditorPrompt(
                    readLine: { "y" },
                    writeError: { writes.lines.append($0) }
                )
            )
        }) { error in
            let err = error as! CLIError
            try MiniTest.expectEqual(err.code, CLIErrorCode.workspaceContainerExists)
            try MiniTest.expect(err.message.contains("adev-my-app-abc123def456"))
            try MiniTest.expect(err.hint?.contains("delete") == true)
        }
        try MiniTest.expect(!mock.calls.contains { $0.arguments.first == "create" })
        try MiniTest.expect(!mock.calls.contains { $0.arguments.first == "delete" })
        try MiniTest.expect(!writes.lines.joined().contains(BringUpRecovery.changeNamePromptText))
    })
]
