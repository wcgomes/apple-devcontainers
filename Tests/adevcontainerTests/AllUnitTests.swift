import Foundation
@testable import ADevContainerLib

// MARK: - Shared helpers

enum TestRepo {
    static func root(file: String = #filePath) -> URL {
        var url = URL(fileURLWithPath: file)
        for _ in 0..<12 {
            if FileManager.default.fileExists(atPath: url.appendingPathComponent("Package.swift").path) {
                return url
            }
            url.deleteLastPathComponent()
        }
        return URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
    }

    static func makeTempWorkspace(configJSON: String, prefix: String = "adev") throws -> URL {
        let ws = FileManager.default.temporaryDirectory
            .appendingPathComponent("\(prefix)-\(UUID().uuidString)", isDirectory: true)
        let dc = ws.appendingPathComponent(".devcontainer", isDirectory: true)
        try FileManager.default.createDirectory(at: dc, withIntermediateDirectories: true)
        try configJSON.write(
            to: dc.appendingPathComponent("devcontainer.json"),
            atomically: true,
            encoding: .utf8
        )
        return ws
    }
}

final class MockProcessRunner: ProcessRunning, @unchecked Sendable {
    var calls: [MockProcessCall] = []
    var results: [ProcessResult] = []
    var handlers: [([String]) -> ProcessResult?] = []
    var defaultResult = ProcessResult(exitCode: 0, stdout: Data(), stderr: Data())

    struct MockProcessCall: Equatable {
        var executable: String
        var arguments: [String]
    }

    func run(
        executable: String,
        arguments: [String],
        environment: [String: String]?,
        currentDirectory: String?
    ) throws -> ProcessResult {
        calls.append(MockProcessCall(executable: executable, arguments: arguments))
        for handler in handlers {
            if let r = handler(arguments) { return r }
        }
        if !results.isEmpty { return results.removeFirst() }
        return defaultResult
    }

    func enqueueJSON(_ object: Any, exitCode: Int32 = 0) throws {
        let data = try JSONSerialization.data(withJSONObject: object)
        results.append(ProcessResult(exitCode: exitCode, stdout: data, stderr: Data()))
    }

    func enqueueStdout(_ text: String, exitCode: Int32 = 0) {
        results.append(ProcessResult(exitCode: exitCode, stdout: Data(text.utf8), stderr: Data()))
    }

    func enqueueFailure(exitCode: Int32 = 1, stderr: String) {
        results.append(ProcessResult(exitCode: exitCode, stdout: Data(), stderr: Data(stderr.utf8)))
    }

    static func containerListJSON(
        id: String,
        state: String,
        labels: [String: String] = [:],
        image: String = "alpine:3.20"
    ) -> [String: Any] {
        [
            "id": id,
            "configuration": [
                "id": id,
                "labels": labels,
                "image": ["reference": image]
            ] as [String: Any],
            "status": ["state": state] as [String: Any]
        ]
    }
}

// MARK: - Suites

nonisolated(unsafe) let errorModelTests: [(String, () throws -> Void)] = [
    ("structuredErrorEncodesProperty", {
        let err = CLIError(
            code: CLIErrorCode.unsupportedProperty,
            property: "runArgs",
            message: "runArgs entry '--privileged' is forever-rejected",
            hint: "Remove --privileged from runArgs"
        )
        try MiniTest.expectEqual(err.property, "runArgs")
        try MiniTest.expect(err.formatted().contains("runArgs"))
        try MiniTest.expect(err.formatted().contains("unsupported_property"))
        let json = err.jsonObject()
        try MiniTest.expectEqual(json["property"] as? String, "runArgs")
        try MiniTest.expectEqual(json["code"] as? String, "unsupported_property")
        try MiniTest.expectEqual(json["outcome"] as? String, "error")
    }),
    ("upResultJSONEncodesRequiredFields", {
        let result = UpResult(
            outcome: "success",
            containerId: "abc123",
            remoteUser: "vscode",
            remoteWorkspaceFolder: "/workspaces/app",
            containerName: "adev-app-deadbeef"
        )
        let data = try result.jsonData()
        let obj = try JSONSerialization.jsonObject(with: data) as! [String: Any]
        try MiniTest.expectEqual(obj["outcome"] as? String, "success")
        try MiniTest.expectEqual(obj["containerId"] as? String, "abc123")
        try MiniTest.expectEqual(obj["remoteUser"] as? String, "vscode")
        try MiniTest.expectEqual(obj["remoteWorkspaceFolder"] as? String, "/workspaces/app")
        try MiniTest.expectEqual(obj["containerName"] as? String, "adev-app-deadbeef")
    }),
    ("packageLoads", {
        try MiniTest.expectEqual(CLIErrorCode.configNotFound, "config_not_found")
    })
]

nonisolated(unsafe) let discoveryTests: [(String, () throws -> Void)] = [
    ("preferNestedOverRoot", {
        let tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("adev-discovery-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: tempDir) }
        let nestedDir = tempDir.appendingPathComponent(".devcontainer", isDirectory: true)
        try FileManager.default.createDirectory(at: nestedDir, withIntermediateDirectories: true)
        let nested = nestedDir.appendingPathComponent("devcontainer.json")
        let root = tempDir.appendingPathComponent(".devcontainer.json")
        try #"{"image":"nested"}"#.write(to: nested, atomically: true, encoding: .utf8)
        try #"{"image":"root"}"#.write(to: root, atomically: true, encoding: .utf8)
        let found = try ConfigDiscovery.discover(workspacePath: tempDir.path)
        try MiniTest.expectEqual(found, nested.path)
    }),
    ("fallbackToRoot", {
        let tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("adev-discovery-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: tempDir) }
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        let root = tempDir.appendingPathComponent(".devcontainer.json")
        try #"{"image":"root"}"#.write(to: root, atomically: true, encoding: .utf8)
        let found = try ConfigDiscovery.discover(workspacePath: tempDir.path)
        try MiniTest.expectEqual(found, root.path)
    }),
    ("missingConfig", {
        let tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("adev-discovery-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: tempDir) }
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        try MiniTest.expectThrows({
            _ = try ConfigDiscovery.discover(workspacePath: tempDir.path)
        }) { error in
            let err = error as! CLIError
            try MiniTest.expectEqual(err.code, CLIErrorCode.configNotFound)
            try MiniTest.expect(err.hint?.contains(".devcontainer/devcontainer.json") == true)
            try MiniTest.expect(err.hint?.contains(".devcontainer.json") == true)
        }
    })
]

nonisolated(unsafe) let parserTests: [(String, () throws -> Void)] = [
    ("lineAndBlockComments", {
        let text = """
        // header comment
        {
          /* block
             comment */
          "name": "demo", // trailing
          "image": "alpine:3.20"
        }
        """
        let obj = try JSONCParser.parseObject(text)
        try MiniTest.expectEqual(obj["name"] as? String, "demo")
        try MiniTest.expectEqual(obj["image"] as? String, "alpine:3.20")
        try MiniTest.expect(obj["commented"] == nil)
    }),
    ("trailingCommas", {
        let text = """
        {
          "image": "alpine:3.20",
          "forwardPorts": [8080, 9090,],
        }
        """
        let obj = try JSONCParser.parseObject(text)
        try MiniTest.expectEqual(obj["image"] as? String, "alpine:3.20")
        try MiniTest.expectEqual((obj["forwardPorts"] as? [Any])?.count, 2)
    }),
    ("commentsInsideStringsPreserved", {
        let text = #"{"image": "alpine:3.20", "name": "has // not comment"}"#
        let obj = try JSONCParser.parseObject(text)
        try MiniTest.expectEqual(obj["name"] as? String, "has // not comment")
    }),
    ("phaseFixturesParse", {
        let root = TestRepo.root()
        for name in [
            "smoke.json",
            "env-user.json",
            "mounts-ports.json",
            "lifecycle.json"
        ] {
            let path = root.appendingPathComponent("Tests/Fixtures/\(name)").path
            let obj = try JSONCParser.loadFile(at: path)
            try MiniTest.expect(obj["image"] as? String != nil, "fixture \(name)")
        }
    })
]

nonisolated(unsafe) let substitutionTests: [(String, () throws -> Void)] = [
    ("localWorkspaceTokens", {
        let ctx = SubstitutionContext(
            localWorkspaceFolder: "/Users/me/proj",
            containerWorkspaceFolder: "/workspaces/proj",
            localEnv: ["HOME": "/Users/me"]
        )
        try MiniTest.expectEqual(
            try VariableSubstitutor.substitute("${localWorkspaceFolder}/src", context: ctx),
            "/Users/me/proj/src"
        )
        try MiniTest.expectEqual(
            try VariableSubstitutor.substitute("${localWorkspaceFolderBasename}", context: ctx),
            "proj"
        )
        try MiniTest.expectEqual(
            try VariableSubstitutor.substitute("${containerWorkspaceFolder}", context: ctx),
            "/workspaces/proj"
        )
    }),
    ("localEnvSubstitution", {
        let ctx = SubstitutionContext(
            localWorkspaceFolder: "/ws",
            containerWorkspaceFolder: "/workspaces/ws",
            localEnv: ["HOME": "/Users/me"]
        )
        let result = try VariableSubstitutor.substitute("${localEnv:HOME}/.kube/config", context: ctx)
        try MiniTest.expectEqual(result, "/Users/me/.kube/config")
    }),
    ("localEnvUnsetIsEmpty", {
        let ctx = SubstitutionContext(
            localWorkspaceFolder: "/ws",
            containerWorkspaceFolder: "/workspaces/ws",
            localEnv: [:]
        )
        let result = try VariableSubstitutor.substitute("${localEnv:MISSING}/x", context: ctx)
        try MiniTest.expectEqual(result, "/x")
    }),
    ("unknownTokenErrors", {
        let ctx = SubstitutionContext(
            localWorkspaceFolder: "/ws",
            containerWorkspaceFolder: "/workspaces/ws",
            localEnv: [:]
        )
        try MiniTest.expectThrows({
            _ = try VariableSubstitutor.substitute("${unknownToken}", context: ctx)
        }) { error in
            let err = error as! CLIError
            try MiniTest.expectEqual(err.code, CLIErrorCode.unsupportedSubstitution)
            try MiniTest.expectEqual(err.property, "unknownToken")
        }
    })
]

nonisolated(unsafe) let admissionTests: [(String, () throws -> Void)] = [
    ("rejectDockerOOD", {
        let raw: [String: Any] = [
            "image": "alpine:3.20",
            "features": [
                "ghcr.io/devcontainers/features/docker-outside-of-docker:1": [:] as [String: Any]
            ]
        ]
        try MiniTest.expectThrows({ try ConfigAdmissions.admit(raw) }) { error in
            let err = error as! CLIError
            try MiniTest.expectEqual(err.code, CLIErrorCode.unsupportedFeature)
            try MiniTest.expect(err.message.contains("docker-outside-of-docker"))
        }
    }),
    ("rejectAnyFeatures", {
        let raw: [String: Any] = [
            "image": "alpine:3.20",
            "features": ["ghcr.io/devcontainers/features/node:2": ["version": "22"]]
        ]
        try MiniTest.expectThrows({ try ConfigAdmissions.admit(raw) }) { error in
            try MiniTest.expectEqual((error as! CLIError).code, CLIErrorCode.unsupportedFeature)
        }
    }),
    ("rejectPrivileged", {
        let raw: [String: Any] = ["image": "alpine:3.20", "runArgs": ["--privileged"]]
        try MiniTest.expectThrows({ try ConfigAdmissions.admit(raw) }) { error in
            let err = error as! CLIError
            try MiniTest.expectEqual(err.property, "runArgs")
            try MiniTest.expect(err.message.contains("--privileged"))
        }
    }),
    ("rejectDevice", {
        let raw: [String: Any] = [
            "image": "alpine:3.20",
            "runArgs": ["--device=/dev/net/tun:/dev/net/tun"]
        ]
        try MiniTest.expectThrows({ try ConfigAdmissions.admit(raw) }) { error in
            try MiniTest.expect((error as! CLIError).message.contains("--device"))
        }
    }),
    ("rejectUnknownRunArgs", {
        let raw: [String: Any] = ["image": "alpine:3.20", "runArgs": ["--cap-add=NET_ADMIN"]]
        try MiniTest.expectThrows({ try ConfigAdmissions.admit(raw) }) { error in
            try MiniTest.expect((error as! CLIError).message.contains("--cap-add=NET_ADMIN"))
        }
    }),
    ("rejectComposeKeys", {
        let raw: [String: Any] = [
            "image": "alpine:3.20",
            "dockerComposeFile": "docker-compose.yml",
            "service": "app"
        ]
        try MiniTest.expectThrows({ try ConfigAdmissions.admit(raw) }) { error in
            let err = error as! CLIError
            try MiniTest.expectEqual(err.code, CLIErrorCode.unsupportedProperty)
            try MiniTest.expect(err.message.lowercased().contains("compose"))
        }
    }),
    ("customizationsVscodeDoesNotFail", {
        let raw: [String: Any] = [
            "image": "alpine:3.20",
            "customizations": ["vscode": ["extensions": ["ms-dotnettools.csdevkit"]]]
        ]
        try ConfigAdmissions.admit(raw)
    }),
    ("unknownPropertyFails", {
        let raw: [String: Any] = ["image": "alpine:3.20", "shutdownAction": "none"]
        try MiniTest.expectThrows({ try ConfigAdmissions.admit(raw) }) { error in
            try MiniTest.expectEqual((error as! CLIError).property, "shutdownAction")
        }
    }),
    ("phaseFixturesAdmit", {
        let root = TestRepo.root()
        let env = ["HOME": "/Users/test", "USERPROFILE": ""]
        for name in [
            "smoke.json",
            "env-user.json",
            "mounts-ports.json",
            "lifecycle.json"
        ] {
            let path = root.appendingPathComponent("Tests/Fixtures/\(name)").path
            let ws = FileManager.default.temporaryDirectory
                .appendingPathComponent("admit-\(UUID().uuidString)", isDirectory: true)
            let dc = ws.appendingPathComponent(".devcontainer", isDirectory: true)
            try FileManager.default.createDirectory(at: dc, withIntermediateDirectories: true)
            try Data(contentsOf: URL(fileURLWithPath: path))
                .write(to: dc.appendingPathComponent("devcontainer.json"))
            defer { try? FileManager.default.removeItem(at: ws) }
            let resolved = try ConfigResolver.resolve(workspacePath: ws.path, localEnv: env)
            try MiniTest.expect(!resolved.config.image.isEmpty, name)
        }
    })
]

nonisolated(unsafe) let runtimeTests: [(String, () throws -> Void)] = [
    ("createArgvMapping", {
        let mock = MockProcessRunner()
        let runtime = AppleContainerRuntime(executablePath: "/usr/local/bin/container", runner: mock)
        let request = CreateRequest(
            name: "my-ctr",
            image: "alpine:3.20",
            labels: [
                ContainerIdentity.labelLocalFolder: "/ws",
                ContainerIdentity.labelConfigFile: "/ws/.devcontainer/devcontainer.json",
                ContainerIdentity.labelConfigHash: "abc"
            ],
            workspaceBindHost: "/ws",
            workspaceBindTarget: "/workspaces/ws",
            env: ["FOO": "bar"],
            user: "vscode",
            workdir: "/workspaces/ws",
            mounts: [MountSpec(type: .volume, source: "data", target: "/data")],
            publishPorts: [5000, 4200],
            portsAttributes: [:],
            configHash: "abc"
        )
        mock.results = [
            ProcessResult(exitCode: 0, stdout: Data("[]".utf8), stderr: Data()),
            ProcessResult(exitCode: 0, stdout: Data(), stderr: Data()),
            ProcessResult(exitCode: 0, stdout: Data("my-ctr\n".utf8), stderr: Data())
        ]
        let id = try runtime.create(request: request)
        try MiniTest.expectEqual(id, "my-ctr")
        try MiniTest.expect(mock.calls.contains { $0.arguments == ["volume", "list", "--format", "json"] })
        try MiniTest.expect(mock.calls.contains { $0.arguments == ["volume", "create", "data"] })
        let args = mock.calls.last!.arguments
        try MiniTest.expectEqual(args[0], "create")
        try MiniTest.expect(args.contains("my-ctr"))
        try MiniTest.expect(args.contains(where: { $0.hasPrefix("devcontainer.local_folder=") }))
        try MiniTest.expect(args.contains("FOO=bar"))
        try MiniTest.expect(args.contains("vscode"))
        try MiniTest.expect(args.contains("/workspaces/ws"))
        try MiniTest.expect(args.contains("4200:4200"))
        try MiniTest.expect(args.contains("5000:5000"))
        try MiniTest.expect(args.contains("sleep"))
        try MiniTest.expect(args.contains("alpine:3.20"))
        try MiniTest.expect(args.contains("infinity"))
        try MiniTest.expect(args.contains(where: { $0.contains("type=bind") && $0.contains("source=/ws") }))
        try MiniTest.expect(args.contains(where: { $0.contains("type=volume") && $0.contains("source=data") }))
    }),
    ("ensureVolumeReusesWhenListHasVolume", {
        let previous = StatusPrinter.enabled
        StatusPrinter.enabled = false
        defer { StatusPrinter.enabled = previous }
        let mock = MockProcessRunner()
        let volumeJSON: [[String: Any]] = [
            [
                "id": "data-vol",
                "configuration": ["name": "data-vol"] as [String: Any]
            ]
        ]
        let listData = try JSONSerialization.data(withJSONObject: volumeJSON)
        mock.handlers = [
            { args in
                if args == ["volume", "list", "--format", "json"] {
                    return ProcessResult(exitCode: 0, stdout: listData, stderr: Data())
                }
                return nil
            }
        ]
        let runtime = AppleContainerRuntime(executablePath: "/usr/local/bin/container", runner: mock)
        try runtime.ensureVolume(name: "data-vol")
        try MiniTest.expect(!mock.calls.contains { $0.arguments.first == "volume" && $0.arguments.dropFirst().first == "create" })
        try MiniTest.expect(mock.calls.contains { $0.arguments == ["volume", "list", "--format", "json"] })
    }),
    ("ensureVolumeSucceedsWhenCreateAlreadyExists", {
        let previous = StatusPrinter.enabled
        StatusPrinter.enabled = false
        defer { StatusPrinter.enabled = previous }
        let mock = MockProcessRunner()
        mock.handlers = [
            { args in
                if args == ["volume", "list", "--format", "json"] {
                    return ProcessResult(exitCode: 0, stdout: Data("[]".utf8), stderr: Data())
                }
                if args == ["volume", "create", "data-vol"] {
                    return ProcessResult(
                        exitCode: 1,
                        stdout: Data(),
                        stderr: Data("Error: volume 'data-vol' already exists".utf8)
                    )
                }
                return nil
            }
        ]
        let runtime = AppleContainerRuntime(executablePath: "/usr/local/bin/container", runner: mock)
        try runtime.ensureVolume(name: "data-vol")
        try MiniTest.expect(mock.calls.contains { $0.arguments == ["volume", "create", "data-vol"] })
    }),
    ("deleteVolumeAndImageArgv", {
        let mock = MockProcessRunner()
        mock.handlers = [
            { args in
                if args == ["volume", "delete", "data-vol"] {
                    return ProcessResult(exitCode: 0, stdout: Data(), stderr: Data())
                }
                if args == ["image", "delete", "alpine:3.20"] {
                    return ProcessResult(exitCode: 0, stdout: Data(), stderr: Data())
                }
                return nil
            }
        ]
        let runtime = AppleContainerRuntime(executablePath: "/usr/local/bin/container", runner: mock)
        try runtime.deleteVolume(name: "data-vol")
        try runtime.deleteImage(reference: "alpine:3.20")
        try MiniTest.expectEqual(mock.calls.map(\.arguments), [
            ["volume", "delete", "data-vol"],
            ["image", "delete", "alpine:3.20"]
        ])
    }),
    ("listJSONParse", {
        let mock = MockProcessRunner()
        try mock.enqueueJSON([
            MockProcessRunner.containerListJSON(
                id: "c1",
                state: "running",
                labels: [ContainerIdentity.labelConfigHash: "h1"]
            )
        ])
        let runtime = AppleContainerRuntime(executablePath: "/usr/local/bin/container", runner: mock)
        let list = try runtime.listAll()
        try MiniTest.expectEqual(list.count, 1)
        try MiniTest.expectEqual(list[0].id, "c1")
        try MiniTest.expect(list[0].isRunning)
        try MiniTest.expectEqual(list[0].labels[ContainerIdentity.labelConfigHash], "h1")
    }),
    ("nonZeroMapsToError", {
        let mock = MockProcessRunner()
        mock.enqueueFailure(exitCode: 2, stderr: "boom")
        let runtime = AppleContainerRuntime(executablePath: "/usr/local/bin/container", runner: mock)
        try MiniTest.expectThrows({ try runtime.stop(nameOrId: "x") }) { error in
            let err = error as! CLIError
            try MiniTest.expectEqual(err.code, CLIErrorCode.runtimeFailed)
            try MiniTest.expect(err.message.contains("boom") || err.message.contains("exit 2"))
        }
    }),
    ("deterministicIdentityStable", {
        let a = ContainerIdentity.containerName(
            workspacePath: "/Users/me/proj",
            configPath: "/Users/me/proj/.devcontainer/devcontainer.json"
        )
        let b = ContainerIdentity.containerName(
            workspacePath: "/Users/me/proj",
            configPath: "/Users/me/proj/.devcontainer/devcontainer.json"
        )
        try MiniTest.expectEqual(a, b)
        try MiniTest.expect(a.count <= 63)
        try MiniTest.expect(a.hasPrefix("adev-"))
        try MiniTest.expect(a.range(of: #"^[a-z0-9-]+$"#, options: .regularExpression) != nil)
    }),
    ("labelsKeys", {
        let labels = ContainerIdentity.labels(
            workspacePath: "/ws",
            configPath: "/ws/.devcontainer/devcontainer.json",
            configHash: "deadbeef"
        )
        try MiniTest.expectEqual(labels[ContainerIdentity.labelLocalFolder], "/ws")
        try MiniTest.expectEqual(
            labels[ContainerIdentity.labelConfigFile],
            "/ws/.devcontainer/devcontainer.json"
        )
        try MiniTest.expectEqual(labels[ContainerIdentity.labelConfigHash], "deadbeef")
    }),
    ("foundationProcessRunnerDrainsLargeStdout", {
        // >64KiB would deadlock if waitUntilExit ran before draining pipes.
        let runner = FoundationProcessRunner()
        let result = try runner.run(
            executable: "/bin/sh",
            arguments: ["-c", "dd if=/dev/zero bs=1024 count=128 2>/dev/null"],
            environment: nil,
            currentDirectory: nil
        )
        try MiniTest.expect(result.succeeded)
        try MiniTest.expectEqual(result.stdout.count, 128 * 1024)
    }),
    ("statusPrinterRespectsEnabledFlag", {
        let previous = StatusPrinter.enabled
        defer { StatusPrinter.enabled = previous }
        StatusPrinter.enabled = false
        StatusPrinter.status("must-not-throw-when-disabled")
        StatusPrinter.enabled = true
        try MiniTest.expect(StatusPrinter.enabled)
        StatusPrinter.enabled = false
        try MiniTest.expect(!StatusPrinter.enabled)
    }),
    ("foundationProcessRunnerCapturesStreamedStderr", {
        let runner = FoundationProcessRunner()
        let result = try runner.run(
            executable: "/bin/sh",
            arguments: ["-c", "echo streamed-err 1>&2"],
            environment: nil,
            currentDirectory: nil,
            streamStderr: true
        )
        try MiniTest.expect(result.succeeded)
        try MiniTest.expect(result.stderrString.contains("streamed-err"))
    })
]
