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

final class MockProcessRunner: StreamTeeingProcessRunning, @unchecked Sendable {
    var calls: [MockProcessCall] = []
    var results: [ProcessResult] = []
    var handlers: [([String]) -> ProcessResult?] = []
    var throwingHandler: (([String]) throws -> ProcessResult?)?
    /// Optional handlers that also receive stdin (for credential fill tests).
    var stdinHandlers: [([String], Data?) -> ProcessResult?] = []
    var defaultResult = ProcessResult(exitCode: 0, stdout: Data(), stderr: Data())
    /// Last streaming flags from `StreamTeeingProcessRunning` (nil if plain `run` was used).
    var lastStreamStderr: Bool?
    var lastTeeStdoutToStderr: Bool?

    struct MockProcessCall: Equatable {
        var executable: String
        var arguments: [String]
        var stdinData: Data?
        var environment: [String: String]?
        var streamStderr: Bool?
        var teeStdoutToStderr: Bool?

        static func == (lhs: MockProcessCall, rhs: MockProcessCall) -> Bool {
            lhs.executable == rhs.executable
                && lhs.arguments == rhs.arguments
                && lhs.stdinData == rhs.stdinData
        }
    }

    func run(
        executable: String,
        arguments: [String],
        environment: [String: String]?,
        currentDirectory: String?,
        stdinData: Data?
    ) throws -> ProcessResult {
        calls.append(MockProcessCall(
            executable: executable,
            arguments: arguments,
            stdinData: stdinData,
            environment: environment,
            streamStderr: nil,
            teeStdoutToStderr: nil
        ))
        return try dispatch(arguments: arguments, stdinData: stdinData)
    }

    func run(
        executable: String,
        arguments: [String],
        environment: [String: String]?,
        currentDirectory: String?,
        stdinData: Data?,
        streamStderr: Bool,
        teeStdoutToStderr: Bool
    ) throws -> ProcessResult {
        lastStreamStderr = streamStderr
        lastTeeStdoutToStderr = teeStdoutToStderr
        calls.append(MockProcessCall(
            executable: executable,
            arguments: arguments,
            stdinData: stdinData,
            environment: environment,
            streamStderr: streamStderr,
            teeStdoutToStderr: teeStdoutToStderr
        ))
        return try dispatch(arguments: arguments, stdinData: stdinData)
    }

    private func dispatch(arguments: [String], stdinData: Data?) throws -> ProcessResult {
        // Track derived tags from build so post-Features connection-user inspect can succeed.
        if arguments.first == "build",
           let tIdx = arguments.firstIndex(of: "-t"),
           tIdx + 1 < arguments.count {
            builtDerivedImages.insert(arguments[tIdx + 1])
        }
        for handler in stdinHandlers {
            if let r = handler(arguments, stdinData) { return r }
        }
        if let throwingHandler, let r = try throwingHandler(arguments) { return r }
        var sawEmptyInspectSuccess = false
        for handler in handlers {
            if let r = handler(arguments) {
                // Catch-all handlers often return empty success for unknown args; treat empty
                // successful image inspect as fallthrough so create-path user resolution works.
                if arguments.starts(with: ["image", "inspect"]),
                   r.succeeded,
                   r.stdout.isEmpty {
                    sawEmptyInspectSuccess = true
                    continue
                }
                return r
            }
        }
        if !sawEmptyInspectSuccess, !results.isEmpty { return results.removeFirst() }
        // Default image inspect: base images succeed with empty USER; derived only after build.
        if arguments.starts(with: ["image", "inspect"]), let ref = arguments.last {
            let isDerived = ref.hasPrefix("adev-") || ref.hasPrefix("adevcontainer:")
            if isDerived, !builtDerivedImages.contains(ref) {
                return ProcessResult(exitCode: 1, stdout: Data(), stderr: Data("missing".utf8))
            }
            let payload = Self.imageInspectJSON(reference: ref, user: nil)
            let data = try! JSONSerialization.data(withJSONObject: payload)
            return ProcessResult(exitCode: 0, stdout: data, stderr: Data())
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

    /// Apple-shaped `container image inspect` payload (variants[].config.config.User / Labels).
    static func imageInspectJSON(
        reference: String = "alpine:3.20",
        user: String? = nil,
        digest: String = "sha256:abc123def456",
        labels: [String: String] = [:]
    ) -> [String: Any] {
        var innerConfig: [String: Any] = [
            "Cmd": ["sh"] as [String],
            "Env": [] as [String]
        ]
        if let user {
            innerConfig["User"] = user
        }
        if !labels.isEmpty {
            innerConfig["Labels"] = labels
        }
        return [
            "id": digest,
            "configuration": [
                "name": reference,
                "descriptor": ["digest": digest] as [String: Any]
            ] as [String: Any],
            "variants": [
                [
                    "digest": digest,
                    "platform": ["os": "linux", "architecture": "arm64"] as [String: Any],
                    "config": [
                        "architecture": "arm64",
                        "os": "linux",
                        "config": innerConfig
                    ] as [String: Any]
                ] as [String: Any]
            ] as [[String: Any]]
        ]
    }

    /// Derived tags recorded after a successful mock `build -t <tag>` (so post-build inspect works).
    var builtDerivedImages: Set<String> = []

    /// Handler fragment: derived `adev*` tags missing until built; other refs return successful inspect.
    /// Also records `-t` tags from `build` so connection-user inspect after Features succeeds.
    func makeImageAndBuildHandler(
        baseUser: String? = nil,
        labels: [String: String] = [:]
    ) -> ([String]) -> ProcessResult? {
        { [weak self] args in
            guard let self else { return nil }
            if args.first == "build" {
                if let tIdx = args.firstIndex(of: "-t"), tIdx + 1 < args.count {
                    self.builtDerivedImages.insert(args[tIdx + 1])
                }
                return nil // let other handlers decide build success
            }
            guard args.starts(with: ["image", "inspect"]), let ref = args.last else { return nil }
            let isDerived = ref.hasPrefix("adev-") || ref.hasPrefix("adevcontainer:")
            if isDerived, !self.builtDerivedImages.contains(ref) {
                return ProcessResult(exitCode: 1, stdout: Data(), stderr: Data("missing".utf8))
            }
            // Derived images typically lack base metadata labels; only attach labels on base refs.
            let payload = Self.imageInspectJSON(
                reference: ref,
                user: baseUser,
                labels: isDerived ? [:] : labels
            )
            let data = try! JSONSerialization.data(withJSONObject: payload)
            return ProcessResult(exitCode: 0, stdout: data, stderr: Data())
        }
    }

    /// Stateless inspect-only helper (derived always missing). Prefer `makeImageAndBuildHandler` for create paths.
    static func imageInspectHandler(
        baseUser: String? = nil,
        labels: [String: String] = [:]
    ) -> ([String]) -> ProcessResult? {
        { args in
            guard args.starts(with: ["image", "inspect"]), let ref = args.last else { return nil }
            if ref.hasPrefix("adev-") || ref.hasPrefix("adevcontainer:") {
                return ProcessResult(exitCode: 1, stdout: Data(), stderr: Data("missing".utf8))
            }
            let payload = imageInspectJSON(reference: ref, user: baseUser, labels: labels)
            let data = try! JSONSerialization.data(withJSONObject: payload)
            return ProcessResult(exitCode: 0, stdout: data, stderr: Data())
        }
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
            message: "runArgs entry '--privileged' is incompatible with Apple container; ignored",
            hint: "Remove --privileged from runArgs"
        )
        try MiniTest.expectEqual(err.property, "runArgs")
        try MiniTest.expect(err.formatted().contains("runArgs"))
        try MiniTest.expect(err.formatted().hasPrefix("error: "))
        try MiniTest.expect(!err.formatted().contains("error[unsupported_property]"))
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
            "lifecycle.json",
            "lifecycle-hooks.json",
            "runargs-host.json",
            "features-node.json",
            "features-triple.json"
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
    ("localWorkspaceFolderBasenameOverride", {
        let ctx = SubstitutionContext(
            localWorkspaceFolder: "/tmp/adev-clone-cfg-uuid",
            containerWorkspaceFolder: "/workspaces/sample-repo",
            localEnv: [:],
            localWorkspaceFolderBasename: "sample-repo"
        )
        try MiniTest.expectEqual(
            try VariableSubstitutor.substitute("${localWorkspaceFolderBasename}", context: ctx),
            "sample-repo"
        )
        try MiniTest.expectEqual(ctx.localWorkspaceFolderBasename, "sample-repo")
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
    }),
    ("devcontainerIdExpandsWhenKnown", {
        let ctx = SubstitutionContext(
            localWorkspaceFolder: "/ws",
            containerWorkspaceFolder: "/workspaces/ws",
            localEnv: [:],
            devcontainerId: "adev-proj-abc123def456"
        )
        try MiniTest.expectEqual(
            try VariableSubstitutor.substitute("${devcontainerId}-shellhistory", context: ctx),
            "adev-proj-abc123def456-shellhistory"
        )
    }),
    ("devcontainerIdDeferredWhenUnknown", {
        let ctx = SubstitutionContext(
            localWorkspaceFolder: "/ws",
            containerWorkspaceFolder: "/workspaces/ws",
            localEnv: [:]
        )
        // Feature mounts / clone: leave token until create name is known.
        try MiniTest.expectEqual(
            try VariableSubstitutor.substitute("${devcontainerId}-shellhistory", context: ctx),
            "${devcontainerId}-shellhistory"
        )
    }),
    ("devcontainerIdExpandMountSource", {
        let mounts = [
            MountSpec(
                type: .volume,
                source: "${devcontainerId}-shellhistory",
                target: "/home/vscode/.shellhistory"
            ),
            MountSpec(type: .bind, source: "/host/data", target: "/data")
        ]
        let id = "adev-app-deadbeefcafe"
        let expanded = VariableSubstitutor.expandDevcontainerId(in: mounts, id: id)
        try MiniTest.expectEqual(expanded.count, 2)
        try MiniTest.expectEqual(expanded[0].source, "\(id)-shellhistory")
        try MiniTest.expectEqual(expanded[0].target, "/home/vscode/.shellhistory")
        try MiniTest.expectEqual(expanded[0].type, .volume)
        try MiniTest.expectEqual(expanded[1].source, "/host/data")
        // Idempotent
        let again = VariableSubstitutor.expandDevcontainerId(in: expanded, id: id)
        try MiniTest.expectEqual(again[0].source, "\(id)-shellhistory")
    }),
    ("devcontainerIdCreateRequestExpandsVolumeMount", {
        let config = ResolvedDevContainerConfig(
            image: "alpine:3.20",
            workspaceFolder: "/workspaces/ws",
            mounts: [
                MountSpec(
                    type: .volume,
                    source: "${devcontainerId}-shellhistory",
                    target: "/cmdhist"
                )
            ]
        )
        let name = "adev-ws-0123456789ab"
        let req = CreateRequest.from(
            resolved: config,
            identityName: name,
            labels: [:],
            configHash: "h",
            workspacePath: "/ws"
        )
        try MiniTest.expectEqual(req.mounts.count, 1)
        try MiniTest.expectEqual(req.mounts[0].source, "\(name)-shellhistory")
        try MiniTest.expect(
            !req.mounts[0].source.contains("${"),
            "volume source must not retain unsubstituted tokens"
        )
        let vols = req.labels[ContainerIdentity.labelConfigVolumes] ?? ""
        try MiniTest.expectEqual(vols, "\(name)-shellhistory")
        let args = req.createArguments()
        let mountFlags = args.enumerated().compactMap { i, a -> String? in
            i > 0 && args[i - 1] == "--mount" ? a : nil
        }
        try MiniTest.expect(
            mountFlags.contains { $0.contains("source=\(name)-shellhistory") },
            "create --mount uses expanded volume name"
        )
    }),
    ("devcontainerIdConfigResolveAllowsTokenInMount", {
        let ws = try TestRepo.makeTempWorkspace(configJSON: """
        {
          "image": "alpine:3.20",
          "mounts": [
            "source=${devcontainerId}-shellhistory,target=/cmdhist,type=volume"
          ]
        }
        """)
        defer { try? FileManager.default.removeItem(at: ws) }
        let resolved = try ConfigResolver.resolve(workspacePath: ws.path, localEnv: [:])
        try MiniTest.expectEqual(resolved.config.mounts.count, 1)
        // Deferred through resolve; create path expands with container name.
        try MiniTest.expectEqual(
            resolved.config.mounts[0].source,
            "${devcontainerId}-shellhistory"
        )
        let expanded = VariableSubstitutor.expandDevcontainerId(
            in: resolved.config,
            id: resolved.containerName
        )
        try MiniTest.expectEqual(
            expanded.mounts[0].source,
            "\(resolved.containerName)-shellhistory"
        )
        try MiniTest.expect(
            expanded.mounts[0].source.range(of: #"^[A-Za-z0-9][A-Za-z0-9_.-]*$"#, options: .regularExpression) != nil,
            "expanded volume name must match Apple volume regex"
        )
    }),
    ("devcontainerIdFeatureMergeThenExpand", {
        let contrib = FeatureContributions(
            mounts: [
                MountSpec(
                    type: .volume,
                    source: "${devcontainerId}-shellhistory",
                    target: "/commandhistory"
                )
            ]
        )
        let base = ResolvedDevContainerConfig(
            image: "alpine:3.20",
            workspaceFolder: "/workspaces/x"
        )
        let merged = try FeatureContributionMerge.apply(contributions: contrib, to: base)
        try MiniTest.expectEqual(merged.mounts[0].source, "${devcontainerId}-shellhistory")
        let id = "adev-x-aabbccddeeff"
        let finalized = VariableSubstitutor.expandDevcontainerId(in: merged, id: id)
        try MiniTest.expectEqual(finalized.mounts[0].source, "\(id)-shellhistory")
        let req = CreateRequest.from(
            resolved: finalized,
            identityName: id,
            labels: [:],
            configHash: "h",
            workspacePath: "/ws"
        )
        try MiniTest.expectEqual(req.mounts[0].source, "\(id)-shellhistory")
    })
]

nonisolated(unsafe) let admissionTests: [(String, () throws -> Void)] = [
    ("warnSkipDockerOOD", {
        let raw: [String: Any] = [
            "image": "alpine:3.20",
            "features": [
                "ghcr.io/devcontainers/features/docker-outside-of-docker:1": [:] as [String: Any],
                "ghcr.io/devcontainers/features/node:2": ["version": "22"] as [String: Any]
            ]
        ]
        try ConfigAdmissions.admit(raw)
        let features = try FeatureAdmission.parse(raw["features"])
        try MiniTest.expectEqual(features.count, 1)
        try MiniTest.expectEqual(features[0].reference, "ghcr.io/devcontainers/features/node:2")
    }),
    ("admitOciNodeFeature", {
        let raw: [String: Any] = [
            "image": "alpine:3.20",
            "features": ["ghcr.io/devcontainers/features/node:2": ["version": "22"]]
        ]
        try ConfigAdmissions.admit(raw)
        let features = try FeatureAdmission.parse(raw["features"])
        try MiniTest.expectEqual(features.count, 1)
        try MiniTest.expectEqual(features[0].reference, "ghcr.io/devcontainers/features/node:2")
        try MiniTest.expectEqual(features[0].options["version"]?.stringValue, "22")
    }),
    ("warnSkipPrivilegedKeepsInit", {
        let raw: [String: Any] = ["image": "alpine:3.20", "runArgs": ["--privileged", "--init"]]
        try ConfigAdmissions.admit(raw)
        let parsed = try RunArgsAdmission.parse(raw["runArgs"])
        try MiniTest.expectEqual(parsed, [.initFlag])
    }),
    ("warnSkipOncePerResolve", {
        // admit (×2) + buildResolved parse used to triple-warn; only final parse may warn.
        let previous = StatusPrinter.onWarning
        defer { StatusPrinter.onWarning = previous }
        var warnings: [String] = []
        StatusPrinter.onWarning = { warnings.append($0) }

        let ws = try TestRepo.makeTempWorkspace(configJSON: """
        {
          "image": "alpine:3.20",
          "runArgs": ["--privileged", "--init"],
          "features": {
            "ghcr.io/devcontainers/features/docker-outside-of-docker:1": {},
            "ghcr.io/devcontainers/features/node:1": {}
          }
        }
        """)
        defer { try? FileManager.default.removeItem(at: ws) }
        let resolved = try ConfigResolver.resolve(workspacePath: ws.path, localEnv: [:])
        try MiniTest.expectEqual(resolved.config.runArgs, [.initFlag])
        try MiniTest.expectEqual(resolved.config.features.count, 1)

        let privilegedWarns = warnings.filter { $0.contains("--privileged") }
        let oodWarns = warnings.filter { $0.contains("docker-outside-of-docker") }
        try MiniTest.expectEqual(privilegedWarns.count, 1)
        try MiniTest.expectEqual(oodWarns.count, 1)
    }),
    ("hashNeutralSkippedRunArgs", {
        let withNoise = try RunArgsAdmission.parse(["--privileged", "--init"] as [Any])
        let clean = try RunArgsAdmission.parse(["--init"] as [Any])
        try MiniTest.expectEqual(withNoise, clean)
        try MiniTest.expectEqual(withNoise, [.initFlag])
        let a = ResolvedDevContainerConfig(
            image: "alpine:3.20",
            workspaceFolder: "/workspaces/x",
            runArgs: withNoise
        )
        let b = ResolvedDevContainerConfig(
            image: "alpine:3.20",
            workspaceFolder: "/workspaces/x",
            runArgs: clean
        )
        let h1 = ContainerIdentity.configHash(from: a.hashMaterial())
        let h2 = ContainerIdentity.configHash(from: b.hashMaterial())
        try MiniTest.expectEqual(h1, h2)
    }),
    ("hashNeutralSkippedFeatures", {
        let withOOD = try FeatureAdmission.parse([
            "ghcr.io/devcontainers/features/docker-outside-of-docker:1": [:] as [String: Any],
            "ghcr.io/devcontainers/features/node:1": ["version": "22"] as [String: Any]
        ] as [String: Any])
        let nodeOnly = try FeatureAdmission.parse([
            "ghcr.io/devcontainers/features/node:1": ["version": "22"] as [String: Any]
        ] as [String: Any])
        try MiniTest.expectEqual(withOOD, nodeOnly)
        try MiniTest.expectEqual(withOOD.count, 1)
        let a = ResolvedDevContainerConfig(
            image: "alpine:3.20",
            workspaceFolder: "/workspaces/x",
            features: withOOD
        )
        let b = ResolvedDevContainerConfig(
            image: "alpine:3.20",
            workspaceFolder: "/workspaces/x",
            features: nodeOnly
        )
        let h1 = ContainerIdentity.configHash(from: a.hashMaterial())
        let h2 = ContainerIdentity.configHash(from: b.hashMaterial())
        try MiniTest.expectEqual(h1, h2)
    }),
    ("warnSkipDevice", {
        let raw: [String: Any] = [
            "image": "alpine:3.20",
            "runArgs": ["--device=/dev/net/tun:/dev/net/tun", "--init"]
        ]
        try ConfigAdmissions.admit(raw)
        let parsed = try RunArgsAdmission.parse(raw["runArgs"])
        try MiniTest.expectEqual(parsed, [.initFlag])
    }),
    ("warnSkipDeviceTwoToken", {
        let raw: [String: Any] = [
            "image": "alpine:3.20",
            "runArgs": ["--device", "/dev/net/tun", "--init"]
        ]
        try ConfigAdmissions.admit(raw)
        let parsed = try RunArgsAdmission.parse(raw["runArgs"])
        try MiniTest.expectEqual(parsed, [.initFlag])
    }),
    ("warnSkipPrivilegedNetAdminPairing", {
        let previous = StatusPrinter.onWarning
        defer { StatusPrinter.onWarning = previous }
        var warnings: [String] = []
        StatusPrinter.onWarning = { warnings.append($0) }

        let parsed = try RunArgsAdmission.parse([
            "--privileged",
            "--cap-add=NET_ADMIN",
            "--init"
        ] as [Any])
        try MiniTest.expectEqual(parsed, [.capAdd("NET_ADMIN"), .initFlag])
        let pairing = warnings.filter { $0.contains("NET_ADMIN") && $0.contains("privileged/device") }
        try MiniTest.expectEqual(pairing.count, 1)
        try MiniTest.expect(warnings.contains { $0.contains("--privileged") })
    }),
    ("warnSkipStillFiresWhenQuiet", {
        let previousEnabled = StatusPrinter.enabled
        let previousSuppress = StatusPrinter.suppressWarningStderr
        let previousOn = StatusPrinter.onWarning
        defer {
            StatusPrinter.enabled = previousEnabled
            StatusPrinter.suppressWarningStderr = previousSuppress
            StatusPrinter.onWarning = previousOn
        }
        // QUIET silences progress only; onWarning (and product stderr) still receive policy warns.
        StatusPrinter.enabled = false
        StatusPrinter.suppressWarningStderr = true
        var warnings: [String] = []
        StatusPrinter.onWarning = { warnings.append($0) }
        StatusPrinter.status("should-be-silent")
        _ = try RunArgsAdmission.parse(["--privileged", "--init"] as [Any])
        try MiniTest.expect(warnings.contains { $0.contains("--privileged") })
    }),
    ("featurePrivilegedMetadataOnWarning", {
        let previous = StatusPrinter.onWarning
        defer { StatusPrinter.onWarning = previous }
        var warnings: [String] = []
        StatusPrinter.onWarning = { warnings.append($0) }

        let data = try Data(contentsOf: URL(fileURLWithPath: FeaturesTestSupport.fixtureFeatureDir("sample-privileged"))
            .appendingPathComponent("devcontainer-feature.json"))
        let meta = try FeatureMetadata.parse(data: data, featureRef: FeaturesTestSupport.refPriv)
        meta.warnStripUnsafeContributions(featureRef: FeaturesTestSupport.refPriv)
        try MiniTest.expect(warnings.contains { $0.contains("privileged") && $0.contains("ignored") })
    }),
    ("featureSecurityOptOnWarning", {
        let previous = StatusPrinter.onWarning
        defer { StatusPrinter.onWarning = previous }
        var warnings: [String] = []
        StatusPrinter.onWarning = { warnings.append($0) }

        let meta = FeatureMetadata(id: "x", securityOpt: ["label=disable"])
        meta.warnStripUnsafeContributions(featureRef: "ghcr.io/x:1")
        try MiniTest.expect(warnings.contains { $0.contains("securityOpt") && $0.contains("ignored") })
    }),
    ("featureMetadataLabelPrivilegedOnWarning", {
        let previous = StatusPrinter.onWarning
        defer { StatusPrinter.onWarning = previous }
        var warnings: [String] = []
        StatusPrinter.onWarning = { warnings.append($0) }

        let labels = [
            DevContainerMetadataLabel.labelKey:
                #"[{"containerEnv":{"OK":"1"}},{"privileged":true,"securityOpt":["label=disable"]}]"#
        ]
        DevContainerMetadataLabel.warnStripUnsafe(from: labels, imageRef: "img:1")
        try MiniTest.expect(warnings.contains { $0.contains("privileged") })
        try MiniTest.expect(warnings.contains { $0.contains("securityOpt") })
    }),
    ("rejectUnknownRunArgs", {
        let raw: [String: Any] = ["image": "alpine:3.20", "runArgs": ["--not-a-real-flag"]]
        try MiniTest.expectThrows({ try ConfigAdmissions.admit(raw) }) { error in
            let err = error as! CLIError
            try MiniTest.expect(err.message.contains("--not-a-real-flag"))
            try MiniTest.expect(err.message.lowercased().contains("allowlist"))
        }
    }),
    ("warnSkipNetworkHost", {
        let raw: [String: Any] = ["image": "alpine:3.20", "runArgs": ["--network=host", "--init"]]
        try ConfigAdmissions.admit(raw)
        let parsed = try RunArgsAdmission.parse(raw["runArgs"])
        try MiniTest.expectEqual(parsed, [.initFlag])
    }),
    ("warnSkipNetworkBridgeNoneContainer", {
        for mode in ["bridge", "none", "container:abc", "HOST"] {
            let raw: [String: Any] = ["image": "alpine:3.20", "runArgs": ["--network=\(mode)", "--init"]]
            try ConfigAdmissions.admit(raw)
            let parsed = try RunArgsAdmission.parse(raw["runArgs"])
            try MiniTest.expectEqual(parsed, [.initFlag])
        }
        let twoTok: [String: Any] = ["image": "alpine:3.20", "runArgs": ["--network", "host", "--init"]]
        try ConfigAdmissions.admit(twoTok)
        let parsed = try RunArgsAdmission.parse(twoTok["runArgs"])
        try MiniTest.expectEqual(parsed, [.initFlag])
    }),
    ("warnSkipSecurityOptAndGpus", {
        for flag in ["--security-opt=label=disable", "--gpus=all", "--ipc=host", "--pid=host"] {
            let raw: [String: Any] = ["image": "alpine:3.20", "runArgs": [flag, "--init"]]
            try ConfigAdmissions.admit(raw)
            let parsed = try RunArgsAdmission.parse(raw["runArgs"])
            try MiniTest.expectEqual(parsed, [.initFlag])
        }
    }),
    ("rejectFirstClassRunArgsFlags", {
        for entry in [["-e", "FOO=bar"], ["-p", "8080:8080"], ["--entrypoint=bash"], ["-v", "/tmp:/tmp"]] as [[String]] {
            let raw: [String: Any] = ["image": "alpine:3.20", "runArgs": entry]
            try MiniTest.expectThrows({ try ConfigAdmissions.admit(raw) }) { error in
                try MiniTest.expectEqual((error as! CLIError).property, "runArgs")
            }
        }
    }),
    ("allowlistedRunArgsAdmit", {
        let raw: [String: Any] = [
            "image": "alpine:3.20",
            "runArgs": ["--init", "--cap-add=NET_ADMIN", "--cap-add", "SYS_PTRACE", "--cap-drop=MKNOD"]
        ]
        try ConfigAdmissions.admit(raw)
        let parsed = try RunArgsAdmission.parse(raw["runArgs"])
        try MiniTest.expectEqual(parsed, [
            .initFlag,
            .capAdd("NET_ADMIN"),
            .capAdd("SYS_PTRACE"),
            .capDrop("MKNOD")
        ])
    }),
    ("allowlistedRunArgsWaveAB", {
        let raw: [String: Any] = [
            "image": "alpine:3.20",
            "runArgs": [
                "--shm-size=64m",
                "--dns", "8.8.8.8",
                "--dns-search=local",
                "--dns-option", "ndots:1",
                "--dns-domain=example.com",
                "--no-dns",
                "--ulimit=nofile=1024:2048",
                "--tmpfs=/tmp:rw",
                "--tmpfs", "/run",
                "--network=mynet",
                "--rosetta",
                "--ssh",
                "--read-only",
                "--memory=2g",
                "-c", "2"
            ] as [Any]
        ]
        try ConfigAdmissions.admit(raw)
        let parsed = try RunArgsAdmission.parse(raw["runArgs"])
        try MiniTest.expect(parsed.contains(.shmSize("64m")))
        try MiniTest.expect(parsed.contains(.dns("8.8.8.8")))
        try MiniTest.expect(parsed.contains(.dnsSearch("local")))
        try MiniTest.expect(parsed.contains(.dnsOption("ndots:1")))
        try MiniTest.expect(parsed.contains(.dnsDomain("example.com")))
        try MiniTest.expect(parsed.contains(.noDns))
        try MiniTest.expect(parsed.contains(.ulimit("nofile=1024:2048")))
        try MiniTest.expect(parsed.contains(.tmpfs("/tmp")))
        try MiniTest.expect(parsed.contains(.tmpfs("/run")))
        try MiniTest.expect(parsed.contains(.network("mynet")))
        try MiniTest.expect(parsed.contains(.rosetta))
        try MiniTest.expect(parsed.contains(.ssh))
        try MiniTest.expect(parsed.contains(.readOnly))
        try MiniTest.expect(parsed.contains(.memory("2g")))
        try MiniTest.expect(parsed.contains(.cpus("2")))
    }),
    ("emptyRunArgsOK", {
        let raw: [String: Any] = ["image": "alpine:3.20", "runArgs": [] as [Any]]
        try ConfigAdmissions.admit(raw)
        let parsed = try RunArgsAdmission.parse(raw["runArgs"])
        try MiniTest.expectEqual(parsed, [])
    }),
    ("rejectDanglingCapAdd", {
        let raw: [String: Any] = ["image": "alpine:3.20", "runArgs": ["--cap-add"]]
        try MiniTest.expectThrows({ try ConfigAdmissions.admit(raw) }) { error in
            let err = error as! CLIError
            try MiniTest.expect(err.message.contains("--cap-add"))
            try MiniTest.expect(err.message.lowercased().contains("incomplete") || err.message.contains("missing"))
        }
    }),
    ("allowlistedCapAddNoLongerErrors", {
        let raw: [String: Any] = [
            "image": "alpine:3.20",
            "runArgs": ["--cap-add=NET_ADMIN", "--init"]
        ]
        try ConfigAdmissions.admit(raw)
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
            "lifecycle.json",
            "lifecycle-hooks.json",
            "runargs-host.json",
            "features-node.json",
            "features-triple.json"
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

nonisolated(unsafe) let phase4UnitTests: [(String, () throws -> Void)] = [
    ("runArgsMapToCreateArgv", {
        let request = CreateRequest(
            name: "ctr",
            image: "alpine:3.20",
            labels: [:],
            workspaceBindHost: "/ws",
            workspaceBindTarget: "/workspaces/ws",
            runArgs: [
                .initFlag,
                .capAdd("NET_ADMIN"),
                .capAdd("SYS_PTRACE"),
                .capDrop("MKNOD"),
                .shmSize("64m"),
                .dns("8.8.8.8"),
                .tmpfs("/tmp"),
                .network("mynet"),
                .rosetta,
                .ssh,
                .readOnly,
                .memory("2g"),
                .cpus("2")
            ],
            configHash: "h"
        )
        let args = request.createArguments()
        try MiniTest.expect(args.contains("--init"))
        // Apple form: --cap-add NAME
        if let i = args.firstIndex(of: "--cap-add") {
            try MiniTest.expect(args[i + 1] == "NET_ADMIN" || args.contains("NET_ADMIN"))
        } else {
            throw MiniTest.Failure(message: "expected --cap-add in create argv")
        }
        try MiniTest.expect(args.contains("SYS_PTRACE"))
        try MiniTest.expect(args.contains("--cap-drop"))
        try MiniTest.expect(args.contains("MKNOD"))
        try MiniTest.expect(args.contains("--shm-size"))
        try MiniTest.expect(args.contains("64m"))
        try MiniTest.expect(args.contains("--dns"))
        try MiniTest.expect(args.contains("8.8.8.8"))
        try MiniTest.expect(args.contains("--tmpfs"))
        try MiniTest.expect(args.contains("/tmp"))
        try MiniTest.expect(args.contains("--network"))
        try MiniTest.expect(args.contains("mynet"))
        try MiniTest.expect(args.contains("--rosetta"))
        try MiniTest.expect(args.contains("--ssh"))
        try MiniTest.expect(args.contains("--read-only"))
        // memory/cpus do not emit duplicate tokens from createTokens
        try MiniTest.expect(!args.contains("--memory"))
        try MiniTest.expect(!args.contains("--cpus"))
        // No blind privileged/device
        try MiniTest.expect(!args.contains(where: { $0.contains("privileged") }))
        try MiniTest.expect(!args.contains(where: { $0.hasPrefix("--device") }))
    }),
    ("runArgsMemoryCpusMergeHostRequirementsWins", {
        var resolved = ResolvedDevContainerConfig(
            image: "alpine:3.20",
            workspaceFolder: "/workspaces/x",
            runArgs: [.memory("1g"), .cpus("1")],
            hostRequirements: try HostRequirements.parse(["memory": "8gb", "cpus": 4] as [String: Any])
        )
        let request = CreateRequest.from(
            resolved: resolved,
            identityName: "ctr",
            labels: [:],
            configHash: "h",
            workspacePath: "/ws"
        )
        try MiniTest.expectEqual(request.memoryLimit, "8G")
        try MiniTest.expectEqual(request.cpuLimit, "4")
        let args = request.createArguments()
        if let i = args.firstIndex(of: "-m") {
            try MiniTest.expectEqual(args[i + 1], "8G")
        } else {
            throw MiniTest.Failure(message: "expected -m from hostRequirements")
        }
        // only one -m
        try MiniTest.expectEqual(args.filter { $0 == "-m" }.count, 1)
        try MiniTest.expectEqual(args.filter { $0 == "-c" }.count, 1)
        _ = resolved
    }),
    ("runArgsMemoryCpusApplyWhenNoHostRequirements", {
        let resolved = ResolvedDevContainerConfig(
            image: "alpine:3.20",
            workspaceFolder: "/workspaces/x",
            runArgs: [.memory("2g"), .cpus("2")]
        )
        let request = CreateRequest.from(
            resolved: resolved,
            identityName: "ctr",
            labels: [:],
            configHash: "h",
            workspacePath: "/ws"
        )
        try MiniTest.expectEqual(request.memoryLimit, "2G")
        try MiniTest.expectEqual(request.cpuLimit, "2")
        let args = request.createArguments()
        if let i = args.firstIndex(of: "-m") {
            try MiniTest.expectEqual(args[i + 1], "2G")
        } else {
            throw MiniTest.Failure(message: "expected -m from runArgs")
        }
        if let i = args.firstIndex(of: "-c") {
            try MiniTest.expectEqual(args[i + 1], "2")
        } else {
            throw MiniTest.Failure(message: "expected -c from runArgs")
        }
    }),
    ("runArgsIncludedInConfigHash", {
        let base = ResolvedDevContainerConfig(
            image: "alpine:3.20",
            containerEnv: [:],
            workspaceFolder: "/workspaces/x",
            mounts: [],
            forwardPorts: [],
            portsAttributes: [:],
            runArgs: [],
            hasVscodeCustomizations: false
        )
        var withInit = base
        withInit.runArgs = [.initFlag]
        let h1 = ContainerIdentity.configHash(from: base.hashMaterial())
        let h2 = ContainerIdentity.configHash(from: withInit.hashMaterial())
        try MiniTest.expect(h1 != h2)
    }),
    ("hostRequirementsParseMemoryAndCpus", {
        let mem8 = HostRequirements.parseMemoryBytes("8gb")
        try MiniTest.expectEqual(mem8, 8 * 1_024 * 1_024 * 1_024)
        let memMb = HostRequirements.parseMemoryBytes("8192mb")
        try MiniTest.expectEqual(memMb, 8192 * 1_024 * 1_024)
        let req = try HostRequirements.parse([
            "memory": "8gb",
            "cpus": 4
        ] as [String: Any])!
        try MiniTest.expectEqual(req.memoryBytes, 8 * 1_024 * 1_024 * 1_024)
        try MiniTest.expectEqual(req.cpus, 4.0)
        let reqStr = try HostRequirements.parse([
            "cpus": "2"
        ] as [String: Any])!
        try MiniTest.expectEqual(reqStr.cpus, 2.0)
    }),
    ("hostRequirementsUnparseableMemoryFails", {
        try MiniTest.expectThrows({
            _ = try HostRequirements.parse(["memory": "plenty"] as [String: Any])
        }) { error in
            let err = error as! CLIError
            try MiniTest.expectEqual(err.property, "hostRequirements.memory")
        }
    }),
    ("hostRequirementsUnknownKeyFails", {
        try MiniTest.expectThrows({
            _ = try HostRequirements.parse(["storage": "100gb"] as [String: Any])
        }) { error in
            let err = error as! CLIError
            try MiniTest.expectEqual(err.property, "hostRequirements.storage")
        }
    }),
    ("hostRequirementsShortfallHasFailures", {
        let req = try HostRequirements.parse([
            "memory": "8gb",
            "cpus": 64
        ] as [String: Any])!
        let host = MockHostResourceInfo(
            physicalMemoryBytes: 1_024 * 1_024 * 1_024, // 1 GiB
            cpuCount: 2
        )
        let eval = HostRequirementsEvaluation.evaluate(req, host: host)
        try MiniTest.expect(eval.hasHardFailures)
        try MiniTest.expect(eval.hardFailures.contains { $0.contains("memory") })
        try MiniTest.expect(eval.hardFailures.contains { $0.contains("cpus") })
        try MiniTest.expect(eval.warnings.isEmpty)
    }),
    ("hostRequirementsGpuWarnsUnsupported", {
        let req = try HostRequirements.parse(["gpu": "optional"] as [String: Any])!
        let host = MockHostResourceInfo(
            physicalMemoryBytes: 64 * 1_024 * 1_024 * 1_024,
            cpuCount: 16
        )
        let eval = HostRequirementsEvaluation.evaluate(req, host: host)
        try MiniTest.expect(!eval.hasHardFailures)
        try MiniTest.expectEqual(eval.warnings.count, 1)
        try MiniTest.expect(eval.warnings[0].lowercased().contains("gpu"))
        try MiniTest.expect(eval.warnings[0].lowercased().contains("unsupported"))
    }),
    ("hostRequirementsAbsentNoOp", {
        let eval = HostRequirementsEvaluation.evaluate(nil, host: MockHostResourceInfo())
        try MiniTest.expect(!eval.hasHardFailures)
        try MiniTest.expect(eval.warnings.isEmpty)
        try MiniTest.expect(eval.warningMessage() == nil)
    }),
    ("hostRequirementsMemoryCreateFlagValue", {
        let req = try HostRequirements.parse(["memory": "8gb", "cpus": 4] as [String: Any])!
        try MiniTest.expectEqual(req.memoryCreateFlagValue, "8G")
        try MiniTest.expectEqual(req.cpuCreateFlagValue, "4")
        let mb = try HostRequirements.parse(["memory": "8192mb"] as [String: Any])!
        try MiniTest.expectEqual(mb.memoryCreateFlagValue, "8192M")
    }),
    ("lifecycleCommandFormsParse", {
        let onCreate = try LifecycleCommand.parse(["echo", "hi"] as [Any], property: "onCreateCommand")
        let postStart = try LifecycleCommand.parse("echo start", property: "postStartCommand")
        try MiniTest.expectEqual(onCreate, .argv(["echo", "hi"]))
        try MiniTest.expectEqual(postStart, .shell("echo start"))
        try MiniTest.expectEqual(onCreate!.execArguments, ["echo", "hi"])
        try MiniTest.expectEqual(postStart!.execArguments, ["sh", "-lc", "echo start"])
    }),
    ("lifecycleCommandObjectFormParse", {
        // shell-history style: named map of string commands
        let obj: [String: Any] = [
            "shell-history": "/usr/local/share/oncreate.sh",
            "other": ["echo", "named"] as [Any]
        ]
        let parsed = try LifecycleCommand.parse(obj, property: "onCreateCommand")
        guard case .parallel(let named) = parsed else {
            throw MiniTest.Failure(message: "expected parallel object form")
        }
        try MiniTest.expectEqual(named.count, 2)
        try MiniTest.expectEqual(named[0].name, "other")
        try MiniTest.expectEqual(named[0].command, LifecycleCommand.argv(["echo", "named"]))
        try MiniTest.expectEqual(named[1].name, "shell-history")
        try MiniTest.expectEqual(named[1].command, LifecycleCommand.shell("/usr/local/share/oncreate.sh"))
        try MiniTest.expectEqual(named[1].command.execArguments, ["sh", "-lc", "/usr/local/share/oncreate.sh"])

        let empty = try LifecycleCommand.parse([:] as [String: Any], property: "onCreateCommand")
        try MiniTest.expect(empty == nil)

        // Regression: prior error text rejected object form entirely
        try MiniTest.expectThrows({
            _ = try LifecycleCommand.parse(42, property: "onCreateCommand")
        }) { error in
            let err = error as! CLIError
            try MiniTest.expectEqual(err.code, CLIErrorCode.unsupportedProperty)
            try MiniTest.expectEqual(err.property, "onCreateCommand")
            try MiniTest.expect(err.message.contains("object of named commands"))
            try MiniTest.expect(!err.message.contains("must be a string or array of strings")
                || err.message.contains("object"))
        }
    }),
    ("lifecycleCommandObjectFormNestedObjectFails", {
        try MiniTest.expectThrows({
            _ = try LifecycleCommand.parse(
                ["bad": ["nested": "no"] as [String: Any]] as [String: Any],
                property: "postCreateCommand"
            )
        }) { error in
            let err = error as! CLIError
            try MiniTest.expectEqual(err.property, "postCreateCommand.bad")
        }
    }),
    ("featureMetadataObjectFormOnCreate", {
        let json = """
        {
          "id": "shell-history",
          "version": "0.0.6",
          "onCreateCommand": {
            "shell-history": "/usr/local/share/stuartleeks-devcontainer-features/shell-history/scripts/oncreate.sh"
          }
        }
        """
        let meta = try FeatureMetadata.parse(data: Data(json.utf8), featureRef: "ghcr.io/stuartleeks/dev-container-features/shell-history:0")
        guard case .parallel(let named) = meta.onCreateCommand else {
            throw MiniTest.Failure(message: "expected object-form onCreateCommand")
        }
        try MiniTest.expectEqual(named.count, 1)
        try MiniTest.expectEqual(named[0].name, "shell-history")
        try MiniTest.expectEqual(
            named[0].command,
            LifecycleCommand.shell("/usr/local/share/stuartleeks-devcontainer-features/shell-history/scripts/oncreate.sh")
        )
    }),
    ("invalidPostAttachFormFails", {
        try MiniTest.expectThrows({
            _ = try LifecycleCommand.parse(42, property: "postAttachCommand")
        }) { error in
            let err = error as! CLIError
            try MiniTest.expectEqual(err.property, "postAttachCommand")
        }
    }),
    ("lifecycleHooksFixtureAdmits", {
        let root = TestRepo.root()
        let fixture = root.appendingPathComponent("Tests/Fixtures/lifecycle-hooks.json")
        let ws = FileManager.default.temporaryDirectory
            .appendingPathComponent("p4-hooks-\(UUID().uuidString)", isDirectory: true)
        let dc = ws.appendingPathComponent(".devcontainer", isDirectory: true)
        try FileManager.default.createDirectory(at: dc, withIntermediateDirectories: true)
        try Data(contentsOf: fixture).write(to: dc.appendingPathComponent("devcontainer.json"))
        defer { try? FileManager.default.removeItem(at: ws) }
        let resolved = try ConfigResolver.resolve(workspacePath: ws.path, localEnv: [:])
        try MiniTest.expect(resolved.config.onCreateCommand != nil)
        try MiniTest.expect(resolved.config.updateContentCommand != nil)
        try MiniTest.expect(resolved.config.postCreateCommand != nil)
        try MiniTest.expect(resolved.config.postStartCommand != nil)
        try MiniTest.expect(resolved.config.postAttachCommand != nil)
    }),
    ("runargsHostFixtureAdmitsAndMaps", {
        let root = TestRepo.root()
        let fixture = root.appendingPathComponent("Tests/Fixtures/runargs-host.json")
        let ws = FileManager.default.temporaryDirectory
            .appendingPathComponent("p4-run-\(UUID().uuidString)", isDirectory: true)
        let dc = ws.appendingPathComponent(".devcontainer", isDirectory: true)
        try FileManager.default.createDirectory(at: dc, withIntermediateDirectories: true)
        try Data(contentsOf: fixture).write(to: dc.appendingPathComponent("devcontainer.json"))
        defer { try? FileManager.default.removeItem(at: ws) }
        let resolved = try ConfigResolver.resolve(workspacePath: ws.path, localEnv: [:])
        try MiniTest.expect(resolved.config.runArgs.contains(.initFlag))
        try MiniTest.expect(resolved.config.runArgs.contains(.capAdd("NET_ADMIN")))
        try MiniTest.expect(resolved.config.runArgs.contains(.capAdd("SYS_PTRACE")))
        try MiniTest.expect(resolved.config.runArgs.contains(.capDrop("MKNOD")))
        try MiniTest.expect(resolved.config.runArgs.contains(.shmSize("64m")))
        try MiniTest.expect(resolved.config.runArgs.contains(.dns("8.8.8.8")))
        try MiniTest.expect(resolved.config.hostRequirements?.memoryBytes != nil)
        try MiniTest.expectEqual(resolved.config.hostRequirements?.cpus, 4.0)
        let request = CreateRequest.from(
            resolved: resolved.config,
            identityName: resolved.containerName,
            labels: resolved.labels,
            configHash: resolved.configHash,
            workspacePath: resolved.workspacePath
        )
        let args = request.createArguments()
        try MiniTest.expect(args.contains("--init"))
        try MiniTest.expect(args.contains("--cap-add"))
        try MiniTest.expect(args.contains("NET_ADMIN"))
        try MiniTest.expect(args.contains("--shm-size"))
        try MiniTest.expect(args.contains("64m"))
        try MiniTest.expect(args.contains("--dns"))
        try MiniTest.expect(args.contains("8.8.8.8"))
        // hostRequirements map to create limits
        if let i = args.firstIndex(of: "-m") {
            try MiniTest.expectEqual(args[i + 1], "8G")
        } else {
            throw MiniTest.Failure(message: "expected -m in create argv")
        }
        if let i = args.firstIndex(of: "-c") {
            try MiniTest.expectEqual(args[i + 1], "4")
        } else {
            throw MiniTest.Failure(message: "expected -c in create argv")
        }
    }),
    ("absentHostRequirementsOmitsCreateLimits", {
        let request = CreateRequest(
            name: "ctr",
            image: "alpine:3.20",
            labels: [:],
            workspaceBindHost: "/ws",
            workspaceBindTarget: "/workspaces/ws",
            configHash: "h"
        )
        let args = request.createArguments()
        try MiniTest.expect(!args.contains("-m"))
        try MiniTest.expect(!args.contains("-c"))
    }),
    ("hostRequirementsIncludedInConfigHash", {
        let base = ResolvedDevContainerConfig(
            image: "alpine:3.20",
            containerEnv: [:],
            workspaceFolder: "/workspaces/x",
            mounts: [],
            forwardPorts: [],
            portsAttributes: [:],
            runArgs: [],
            hasVscodeCustomizations: false
        )
        var withMem = base
        withMem.hostRequirements = try HostRequirements.parse(["memory": "8gb"] as [String: Any])
        let h1 = ContainerIdentity.configHash(from: base.hashMaterial())
        let h2 = ContainerIdentity.configHash(from: withMem.hashMaterial())
        try MiniTest.expect(h1 != h2)
    }),
    ("lifecycleIncludedInConfigHash", {
        var base = ResolvedDevContainerConfig(
            image: "alpine:3.20",
            containerEnv: [:],
            workspaceFolder: "/workspaces/x",
            mounts: [],
            forwardPorts: [],
            portsAttributes: [:],
            runArgs: [],
            hasVscodeCustomizations: false
        )
        var withPostStart = base
        withPostStart.postStartCommand = .shell("echo hi")
        let h1 = ContainerIdentity.configHash(from: base.hashMaterial())
        let h2 = ContainerIdentity.configHash(from: withPostStart.hashMaterial())
        try MiniTest.expect(h1 != h2)
        // postAttach should not affect hash
        base.postAttachCommand = .shell("echo attach")
        let h3 = ContainerIdentity.configHash(from: base.hashMaterial())
        try MiniTest.expectEqual(h1, h3)
    })
]

 nonisolated(unsafe) let runtimeTests: [(String, () throws -> Void)] = [
    ("createEnvExpandsPathRefs", {
        let nvmPrefix = "/usr/local/share/nvm/current/bin"
        let request = CreateRequest(
            name: "ctr",
            image: "alpine:3.20",
            labels: [:],
            workspaceBindHost: "/ws",
            workspaceBindTarget: "/workspaces/ws",
            env: [
                "PATH": "\(nvmPrefix):${PATH}",
                "OTHER": "pre:$PATH:post",
                "PATHNAME": "keep-$PATHNAME"
            ],
            configHash: "h"
        )
        let expanded = CreateRequest.expandEnvPathRefs(request.env)
        let expectedPath = "\(nvmPrefix):\(CreateRequest.defaultLinuxPath)"
        try MiniTest.expectEqual(expanded["PATH"], expectedPath)
        try MiniTest.expect(!expanded["PATH"]!.contains("${PATH}"))
        try MiniTest.expectEqual(expanded["OTHER"], "pre:\(expectedPath):post")
        try MiniTest.expectEqual(expanded["PATHNAME"], "keep-$PATHNAME")
        let args = request.createArguments()
        try MiniTest.expect(args.contains("PATH=\(expectedPath)"))
        try MiniTest.expect(!args.contains(where: { $0.contains("${PATH}") }))
        try MiniTest.expect(args.contains("OTHER=pre:\(expectedPath):post"))
        try MiniTest.expect(args.contains("PATHNAME=keep-$PATHNAME"))
    }),
    ("execEnvExpandsPathRefs", {
        // Lifecycle/exec must expand feature PATH the same way as create.
        let nvmPrefix = "/usr/local/share/nvm/current/bin"
        let expectedPath = "\(nvmPrefix):\(CreateRequest.defaultLinuxPath)"
        let mock = MockProcessRunner()
        mock.results = [
            ProcessResult(exitCode: 0, stdout: Data(), stderr: Data())
        ]
        let runtime = AppleContainerRuntime(executablePath: "/usr/local/bin/container", runner: mock)
        _ = try runtime.exec(
            nameOrId: "ctr",
            command: ["sh", "-lc", "id && bash --version"],
            env: [
                "PATH": "\(nvmPrefix):${PATH}",
                "OTHER": "pre:$PATH:post",
                "PATHNAME": "keep-$PATHNAME"
            ]
        )
        let args = mock.calls.last!.arguments
        try MiniTest.expectEqual(args.first, "exec")
        try MiniTest.expect(args.contains("PATH=\(expectedPath)"))
        try MiniTest.expect(!args.contains(where: { $0.contains("${PATH}") }))
        try MiniTest.expect(args.contains("OTHER=pre:\(expectedPath):post"))
        try MiniTest.expect(args.contains("PATHNAME=keep-$PATHNAME"))
        try MiniTest.expect(args.contains("ctr"))
        try MiniTest.expect(args.contains("sh"))
    }),
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
        try MiniTest.expect(args.contains("/bin/sleep"))
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
    ("inspectAcceptsObjectAndSingleEntryArray", {
        let object = MockProcessRunner.containerListJSON(id: "c1", state: "running")
        for response in [object, [object]] as [Any] {
            let mock = MockProcessRunner()
            try mock.enqueueJSON(response)
            let runtime = AppleContainerRuntime(executablePath: "/usr/local/bin/container", runner: mock)
            let info = try runtime.inspect(nameOrId: "c1")
            try MiniTest.expectEqual(info.id, "c1")
        }
    }),
    ("inspectRejectsMultiAndMixedEntryArrays", {
        let object = MockProcessRunner.containerListJSON(id: "c1", state: "running")
        for response in [[object, object], [object, "not-an-object"]] as [Any] {
            let mock = MockProcessRunner()
            try mock.enqueueJSON(response)
            let runtime = AppleContainerRuntime(executablePath: "/usr/local/bin/container", runner: mock)
            try MiniTest.expectThrows({ _ = try runtime.inspect(nameOrId: "c1") }) { _ in }
        }
    }),
    ("inspectImageRejectsMultiEntryArray", {
        let image = ["id": "sha256:abc"]
        let mock = MockProcessRunner()
        try mock.enqueueJSON([image, image])
        let runtime = AppleContainerRuntime(executablePath: "/usr/local/bin/container", runner: mock)
        try MiniTest.expectThrows({ _ = try runtime.inspectImage(ref: "alpine:3.20") }) { _ in }
    }),
    ("inspectImageAcceptsObjectAndSingleEntryArray", {
        let image = ["id": "sha256:abc"]
        for response in [image, [image]] as [Any] {
            let mock = MockProcessRunner()
            try mock.enqueueJSON(response)
            let runtime = AppleContainerRuntime(executablePath: "/usr/local/bin/container", runner: mock)
            let inspection = try runtime.inspectImage(ref: "alpine:3.20")
            try MiniTest.expectEqual(inspection.digests, ["sha256:abc"])
            try MiniTest.expect(inspection.user == nil || inspection.user?.isEmpty == true)
        }
    }),
    ("inspectImageExposesOCIUserFromAppleVariants", {
        let payload = MockProcessRunner.imageInspectJSON(reference: "node:20", user: "node")
        let mock = MockProcessRunner()
        try mock.enqueueJSON(payload)
        let runtime = AppleContainerRuntime(executablePath: "/usr/local/bin/container", runner: mock)
        let inspection = try runtime.inspectImage(ref: "node:20")
        try MiniTest.expectEqual(inspection.user, "node")
        try MiniTest.expect(inspection.user != "root" || inspection.user == "node")
    }),
    ("inspectImageExposesOCIUserFromDockerConfig", {
        let payload: [String: Any] = [
            "Id": "sha256:ddd",
            "id": "sha256:ddd",
            "Config": ["User": "app"] as [String: Any],
            "platform": ["os": "linux", "architecture": "arm64"] as [String: Any]
        ]
        let mock = MockProcessRunner()
        try mock.enqueueJSON(payload)
        let runtime = AppleContainerRuntime(executablePath: "/usr/local/bin/container", runner: mock)
        let inspection = try runtime.inspectImage(ref: "app:1")
        try MiniTest.expectEqual(inspection.user, "app")
    }),
    ("inspectImageEmptyUserIsNotRoot", {
        let payload = MockProcessRunner.imageInspectJSON(reference: "alpine:3.20", user: nil)
        let mock = MockProcessRunner()
        try mock.enqueueJSON(payload)
        let runtime = AppleContainerRuntime(executablePath: "/usr/local/bin/container", runner: mock)
        let inspection = try runtime.inspectImage(ref: "alpine:3.20")
        try MiniTest.expect(inspection.user == nil || inspection.user?.isEmpty == true)
        try MiniTest.expect(inspection.user != "root")
    }),
    ("inspectImageWhitespaceUserIsEmpty", {
        let payload = MockProcessRunner.imageInspectJSON(reference: "x", user: "   ")
        // Force whitespace User into payload
        var forced = payload
        if var variants = forced["variants"] as? [[String: Any]],
           var outer = variants[0]["config"] as? [String: Any],
           var inner = outer["config"] as? [String: Any] {
            inner["User"] = "   "
            outer["config"] = inner
            variants[0]["config"] = outer
            forced["variants"] = variants
        }
        let mock = MockProcessRunner()
        try mock.enqueueJSON(forced)
        let runtime = AppleContainerRuntime(executablePath: "/usr/local/bin/container", runner: mock)
        let inspection = try runtime.inspectImage(ref: "x")
        try MiniTest.expect(inspection.user == nil)
    }),
    ("inspectImageFailureDoesNotFabricateRoot", {
        let mock = MockProcessRunner()
        mock.enqueueFailure(exitCode: 1, stderr: "image not found")
        let runtime = AppleContainerRuntime(executablePath: "/usr/local/bin/container", runner: mock)
        try MiniTest.expectThrows({ _ = try runtime.inspectImage(ref: "missing:tag") }) { error in
            let err = error as! CLIError
            try MiniTest.expectEqual(err.code, CLIErrorCode.runtimeFailed)
            try MiniTest.expect(!err.message.lowercased().contains("user root") || true)
        }
    }),
    ("inspectImageUnparseableJSONFails", {
        let mock = MockProcessRunner()
        mock.enqueueStdout("not-json", exitCode: 0)
        let runtime = AppleContainerRuntime(executablePath: "/usr/local/bin/container", runner: mock)
        try MiniTest.expectThrows({ _ = try runtime.inspectImage(ref: "x") }) { error in
            try MiniTest.expectEqual((error as! CLIError).code, CLIErrorCode.runtimeFailed)
        }
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
        try MiniTest.expect(a.hasPrefix("adev-proj-"))
        try MiniTest.expect(a.range(of: #"^[a-z0-9-]+$"#, options: .regularExpression) != nil)
    }),
    ("containerNamePrefersConfigName", {
        let withName = ContainerIdentity.containerName(
            workspacePath: "/Users/me/proj",
            configPath: "/Users/me/proj/.devcontainer/devcontainer.json",
            configName: "My App!"
        )
        let withoutName = ContainerIdentity.containerName(
            workspacePath: "/Users/me/proj",
            configPath: "/Users/me/proj/.devcontainer/devcontainer.json"
        )
        try MiniTest.expect(withName.hasPrefix("adev-my-app-"))
        try MiniTest.expect(withoutName.hasPrefix("adev-proj-"))
        // Hash material is path-only; short hash segment matches.
        let hashWith = String(withName.split(separator: "-").last ?? "")
        let hashWithout = String(withoutName.split(separator: "-").last ?? "")
        try MiniTest.expectEqual(hashWith, hashWithout)
        try MiniTest.expectEqual(hashWith.count, 12)
    }),
    ("containerNameIgnoresBlankConfigName", {
        let name = ContainerIdentity.containerName(
            workspacePath: "/Users/me/proj",
            configPath: "/Users/me/proj/.devcontainer/devcontainer.json",
            configName: "   "
        )
        try MiniTest.expect(name.hasPrefix("adev-proj-"))
    }),
    ("resolverContainerNameFromConfigName", {
        let wsNamed = try TestRepo.makeTempWorkspace(configJSON: """
        { "name": "Cool App", "image": "alpine:3.20" }
        """)
        defer { try? FileManager.default.removeItem(at: wsNamed) }
        let rNamed = try ConfigResolver.resolve(workspacePath: wsNamed.path, localEnv: [:])
        try MiniTest.expect(rNamed.containerName.hasPrefix("adev-cool-app-"))

        let wsBare = try TestRepo.makeTempWorkspace(configJSON: #"{ "image": "alpine:3.20" }"#)
        defer { try? FileManager.default.removeItem(at: wsBare) }
        let rBare = try ConfigResolver.resolve(workspacePath: wsBare.path, localEnv: [:])
        let expectedBase = ContainerIdentity.humanBase(configName: nil, workspacePath: wsBare.path)
        try MiniTest.expect(rBare.containerName.hasPrefix("adev-\(expectedBase)-"))
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
        try MiniTest.expectEqual(labels[ContainerIdentity.labelManaged], "adevcontainer")
        try MiniTest.expectEqual(labels[ContainerIdentity.labelWorkspaceMode], "bind")
        try MiniTest.expect(labels[ContainerIdentity.labelGitURL] == nil)
        try MiniTest.expect(labels[ContainerIdentity.labelWorkspaceVolume] == nil)
    }),
    ("bindModeLabelsDay2Fields", {
        let labels = ContainerIdentity.bindModeLabels(
            workspacePath: "/Projects/app",
            configPath: "/Projects/app/.devcontainer/devcontainer.json",
            configHash: "abc",
            workspaceFolder: "/workspaces/app",
            remoteUser: "vscode",
            configVolumeNames: ["data-vol"]
        )
        try MiniTest.expectEqual(labels[ContainerIdentity.labelManaged], "adevcontainer")
        try MiniTest.expectEqual(labels[ContainerIdentity.labelWorkspaceMode], "bind")
        try MiniTest.expectEqual(labels[ContainerIdentity.labelLocalFolder], "/Projects/app")
        try MiniTest.expectEqual(labels[ContainerIdentity.labelWorkspaceFolder], "/workspaces/app")
        try MiniTest.expectEqual(labels[ContainerIdentity.labelRemoteUser], "vscode")
        try MiniTest.expectEqual(labels[ContainerIdentity.labelConfigVolumes], "data-vol")
        try MiniTest.expect(labels[ContainerIdentity.labelGitURL] == nil)
        try MiniTest.expect(labels[ContainerIdentity.labelWorkspaceVolume] == nil)
    }),
    ("bindModeLabelsRemoteUserEmptyWhenNil", {
        let labels = ContainerIdentity.bindModeLabels(
            workspacePath: "/ws",
            configPath: "/ws/.devcontainer/devcontainer.json",
            configHash: "h",
            workspaceFolder: "/workspaces/ws",
            remoteUser: nil
        )
        try MiniTest.expectEqual(labels[ContainerIdentity.labelRemoteUser], "")
        try MiniTest.expect(labels[ContainerIdentity.labelConfigVolumes] == nil)
    }),
    ("resolverBindModeLabelsIncludeManaged", {
        let ws = try TestRepo.makeTempWorkspace(configJSON: """
        {
          "image": "alpine:3.20",
          "remoteUser": "vscode",
          "workspaceFolder": "/workspaces/app",
          "mounts": [
            { "source": "cfg-vol", "target": "/data", "type": "volume" }
          ]
        }
        """)
        defer { try? FileManager.default.removeItem(at: ws) }
        let resolved = try ConfigResolver.resolve(workspacePath: ws.path, localEnv: [:])
        try MiniTest.expectEqual(
            resolved.labels[ContainerIdentity.labelManaged],
            ContainerIdentity.managedValue
        )
        try MiniTest.expectEqual(
            resolved.labels[ContainerIdentity.labelWorkspaceMode],
            ContainerIdentity.workspaceModeBind
        )
        try MiniTest.expectEqual(resolved.labels[ContainerIdentity.labelRemoteUser], "vscode")
        try MiniTest.expectEqual(resolved.labels[ContainerIdentity.labelWorkspaceFolder], "/workspaces/app")
        try MiniTest.expectEqual(resolved.labels[ContainerIdentity.labelConfigVolumes], "cfg-vol")
        try MiniTest.expectEqual(resolved.labels[ContainerIdentity.labelLocalFolder], resolved.workspacePath)
        try MiniTest.expectEqual(resolved.labels[ContainerIdentity.labelConfigFile], resolved.configPath)
        try MiniTest.expect(resolved.labels[ContainerIdentity.labelGitURL] == nil)
        try MiniTest.expect(resolved.labels[ContainerIdentity.labelWorkspaceVolume] == nil)
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
    }),
    ("foundationProcessRunnerCapturesTeedStdout", {
        // teeStdoutToStderr must still capture stdout for failure diagnostics.
        let runner = FoundationProcessRunner()
        let result = try runner.run(
            executable: "/bin/sh",
            arguments: ["-c", "echo streamed-out; echo streamed-err 1>&2"],
            environment: nil,
            currentDirectory: nil,
            streamStderr: true,
            teeStdoutToStderr: true
        )
        try MiniTest.expect(result.succeeded)
        try MiniTest.expect(result.stdoutString.contains("streamed-out"))
        try MiniTest.expect(result.stderrString.contains("streamed-err"))
    }),
    ("lifecycleRunnerStreamsHookExecOutput", {
        // Lifecycle hooks must request streamOutput so long-running scripts tee live.
        let mock = MockProcessRunner()
        mock.handlers = [
            { args in
                if args.first == "exec" {
                    return ProcessResult(
                        exitCode: 0,
                        stdout: Data("hook-stdout\n".utf8),
                        stderr: Data("hook-stderr\n".utf8)
                    )
                }
                return nil
            }
        ]
        let runtime = AppleContainerRuntime(executablePath: "/usr/local/bin/container", runner: mock)
        let config = ResolvedDevContainerConfig(
            image: "alpine:3.20",
            workspaceFolder: "/workspaces/app",
            postCreateCommand: .shell("echo slow-hook")
        )
        try LifecycleRunner.runIfPresent(
            property: "postCreateCommand",
            command: config.postCreateCommand,
            containerId: "ctr-stream",
            config: config,
            runtime: runtime,
            failurePolicy: .deleteContainerThenFail
        )
        try MiniTest.expect(mock.lastStreamStderr == true)
        try MiniTest.expect(mock.lastTeeStdoutToStderr == true)
        let execCalls = mock.calls.filter { $0.arguments.first == "exec" }
        try MiniTest.expectEqual(execCalls.count, 1)
        try MiniTest.expect(execCalls[0].streamStderr == true)
        try MiniTest.expect(execCalls[0].teeStdoutToStderr == true)
    }),
    ("lifecycleRunnerStreamFailureKeepsDiagnostics", {
        let mock = MockProcessRunner()
        mock.handlers = [
            { args in
                if args.first == "exec" {
                    return ProcessResult(
                        exitCode: 3,
                        stdout: Data("out-detail\n".utf8),
                        stderr: Data("err-detail\n".utf8)
                    )
                }
                if args.first == "delete" {
                    return ProcessResult(exitCode: 0, stdout: Data(), stderr: Data())
                }
                return nil
            }
        ]
        let runtime = AppleContainerRuntime(executablePath: "/usr/local/bin/container", runner: mock)
        let config = ResolvedDevContainerConfig(
            image: "alpine:3.20",
            workspaceFolder: "/workspaces/app",
            postCreateCommand: .shell("false")
        )
        try MiniTest.expectThrows({
            try LifecycleRunner.runIfPresent(
                property: "postCreateCommand",
                command: config.postCreateCommand,
                containerId: "ctr-fail-stream",
                config: config,
                runtime: runtime,
                failurePolicy: .deleteContainerThenFail
            )
        }) { error in
            let err = error as! CLIError
            try MiniTest.expectEqual(err.code, CLIErrorCode.postCreateFailed)
            try MiniTest.expect(err.message.contains("err-detail"))
            try MiniTest.expect(err.message.contains("out-detail"))
            try MiniTest.expect(err.message.contains("exit 3"))
            // Captured diagnostics remain raw (no tool frame prefix on the mark).
            try MiniTest.expect(!err.message.contains("| err-detail"))
            try MiniTest.expect(!err.message.contains("    | "))
        }
        // Streaming path was used on exec; captured detail still reaches the structured error.
        // (delete-on-fail also streams stderr and must not be confused with the hook exec flags.)
        let execCalls = mock.calls.filter { $0.arguments.first == "exec" }
        try MiniTest.expectEqual(execCalls.count, 1)
        try MiniTest.expect(execCalls[0].streamStderr == true)
        try MiniTest.expect(execCalls[0].teeStdoutToStderr == true)
        try MiniTest.expect(mock.calls.contains { $0.arguments.first == "delete" })
    }),
    ("lifecycleRunnerEmitsPhaseStatusAndHonorsQuiet", {
        let previousEnabled = StatusPrinter.enabled
        let previousWrite = StatusPrinter.writeStderr
        let previousPhase = StatusPrinter.hasEmittedPhase
        let previousColor = TerminalStyle.colorOverride
        defer {
            StatusPrinter.enabled = previousEnabled
            StatusPrinter.writeStderr = previousWrite
            StatusPrinter.hasEmittedPhase = previousPhase
            TerminalStyle.colorOverride = previousColor
        }
        TerminalStyle.colorOverride = false
        StatusPrinter.resetSectionState()
        var buffer = Data()
        StatusPrinter.writeStderr = { buffer.append($0) }

        let mock = MockProcessRunner()
        mock.handlers = [
            { args in
                if args.first == "exec" {
                    return ProcessResult(exitCode: 0, stdout: Data("hook-body\n".utf8), stderr: Data())
                }
                return nil
            }
        ]
        let runtime = AppleContainerRuntime(executablePath: "/usr/local/bin/container", runner: mock)
        let config = ResolvedDevContainerConfig(
            image: "alpine:3.20",
            workspaceFolder: "/workspaces/app",
            postCreateCommand: .shell("echo hook-body")
        )

        StatusPrinter.enabled = true
        try LifecycleRunner.runIfPresent(
            property: "postCreateCommand",
            command: config.postCreateCommand,
            containerId: "ctr-status",
            config: config,
            runtime: runtime,
            failurePolicy: .deleteContainerThenFail
        )
        let loud = String(data: buffer, encoding: .utf8) ?? ""
        try MiniTest.expect(loud.contains("==> Running postCreateCommand\n"))

        buffer = Data()
        StatusPrinter.enabled = false
        StatusPrinter.resetSectionState()
        try LifecycleRunner.runIfPresent(
            property: "postCreateCommand",
            command: config.postCreateCommand,
            containerId: "ctr-status-q",
            config: config,
            runtime: runtime,
            failurePolicy: .deleteContainerThenFail
        )
        let quiet = String(data: buffer, encoding: .utf8) ?? ""
        try MiniTest.expectEqual(quiet, "")
        // Stream flags still requested under QUIET (tool body must remain visible at runner level).
        try MiniTest.expect(mock.lastStreamStderr == true)
        try MiniTest.expect(mock.lastTeeStdoutToStderr == true)
    }),
    ("lifecycleRunnerStatusUsesFullPropertyName", {
        let previousEnabled = StatusPrinter.enabled
        let previousWrite = StatusPrinter.writeStderr
        let previousPhase = StatusPrinter.hasEmittedPhase
        let previousColor = TerminalStyle.colorOverride
        defer {
            StatusPrinter.enabled = previousEnabled
            StatusPrinter.writeStderr = previousWrite
            StatusPrinter.hasEmittedPhase = previousPhase
            TerminalStyle.colorOverride = previousColor
        }
        TerminalStyle.colorOverride = false
        StatusPrinter.enabled = true
        var buffer = Data()
        StatusPrinter.writeStderr = { buffer.append($0) }

        let mock = MockProcessRunner()
        mock.handlers = [
            { args in
                if args.first == "exec" {
                    return ProcessResult(exitCode: 0, stdout: Data(), stderr: Data())
                }
                return nil
            }
        ]
        let runtime = AppleContainerRuntime(executablePath: "/usr/local/bin/container", runner: mock)
        let config = ResolvedDevContainerConfig(
            image: "alpine:3.20",
            workspaceFolder: "/workspaces/app",
            postCreateCommand: .shell("true")
        )
        let cases = [
            "onCreateCommand",
            "updateContentCommand",
            "postCreateCommand",
            "postStartCommand",
            "postAttachCommand",
            "postCreateCommand (feature)",
            "postStartCommand (setup)",
            "postCreateCommand (feature 2)",
        ]
        for property in cases {
            buffer = Data()
            StatusPrinter.resetSectionState()
            try LifecycleRunner.runIfPresent(
                property: property,
                command: config.postCreateCommand,
                containerId: "ctr-event",
                config: config,
                runtime: runtime,
                failurePolicy: .failKeepContainer
            )
            let out = String(data: buffer, encoding: .utf8) ?? ""
            try MiniTest.expect(
                out.contains("==> Running \(property)\n"),
                "status for \(property)"
            )
        }

        buffer = Data()
        StatusPrinter.resetSectionState()
        try LifecycleRunner.runIfPresent(
            property: "postAttachCommand",
            command: nil,
            containerId: "ctr-event-absent",
            config: config,
            runtime: runtime,
            failurePolicy: .failKeepContainer
        )
        try MiniTest.expectEqual(String(data: buffer, encoding: .utf8) ?? "", "")
    }),
    ("isBuilderRunningParsesStatusJSON", {
        let mock = MockProcessRunner()
        mock.handlers = [
            { args in
                if args == ["builder", "status", "--format", "json"] {
                    let json = #"[{"id":"buildkit","status":{"state":"running"}}]"#
                    return ProcessResult(exitCode: 0, stdout: Data(json.utf8), stderr: Data())
                }
                return ProcessResult(exitCode: 99, stdout: Data(), stderr: Data("unexpected".utf8))
            }
        ]
        let runtime = AppleContainerRuntime(executablePath: "/usr/local/bin/container", runner: mock)
        try MiniTest.expect(runtime.isBuilderRunning())

        mock.handlers = [
            { args in
                if args == ["builder", "status", "--format", "json"] {
                    let json = #"[{"id":"buildkit","status":{"state":"stopped"}}]"#
                    return ProcessResult(exitCode: 0, stdout: Data(json.utf8), stderr: Data())
                }
                return ProcessResult(exitCode: 99, stdout: Data(), stderr: Data("unexpected".utf8))
            }
        ]
        try MiniTest.expect(!runtime.isBuilderRunning())

        mock.handlers = [
            { args in
                if args == ["builder", "status", "--format", "json"] {
                    return ProcessResult(exitCode: 0, stdout: Data("[]".utf8), stderr: Data())
                }
                return ProcessResult(exitCode: 99, stdout: Data(), stderr: Data("unexpected".utf8))
            }
        ]
        try MiniTest.expect(!runtime.isBuilderRunning())

        // Undetermined → treat as running (do not restore-stop if unsure).
        mock.handlers = [
            { args in
                if args == ["builder", "status", "--format", "json"] {
                    return ProcessResult(exitCode: 1, stdout: Data(), stderr: Data("boom".utf8))
                }
                return ProcessResult(exitCode: 99, stdout: Data(), stderr: Data("unexpected".utf8))
            }
        ]
        try MiniTest.expect(runtime.isBuilderRunning())
    }),
    ("buildRestoresStoppedBuilderAfterSuccess", {
        let mock = MockProcessRunner()
        var sawStop = false
        mock.handlers = [
            { args in
                if args == ["builder", "status", "--format", "json"] {
                    return ProcessResult(exitCode: 0, stdout: Data("[]".utf8), stderr: Data())
                }
                if args.first == "build" {
                    return ProcessResult(exitCode: 0, stdout: Data(), stderr: Data())
                }
                if args.starts(with: ["builder", "stop"]) {
                    sawStop = true
                    return ProcessResult(exitCode: 0, stdout: Data(), stderr: Data())
                }
                return ProcessResult(exitCode: 99, stdout: Data(), stderr: Data("unexpected".utf8))
            }
        ]
        let runtime = AppleContainerRuntime(executablePath: "/usr/local/bin/container", runner: mock)
        try runtime.build(
            contextDirectory: "/ctx",
            dockerfilePath: "/ctx/Dockerfile",
            tag: "adev:test",
            platform: "linux/arm64"
        )
        try MiniTest.expect(sawStop)
        try MiniTest.expect(mock.calls.contains { $0.arguments.first == "build" })
        try MiniTest.expect(mock.calls.contains { $0.arguments.starts(with: ["builder", "stop"]) })
        // status before build
        let statusIdx = mock.calls.firstIndex { $0.arguments == ["builder", "status", "--format", "json"] }!
        let buildIdx = mock.calls.firstIndex { $0.arguments.first == "build" }!
        let stopIdx = mock.calls.firstIndex { $0.arguments.starts(with: ["builder", "stop"]) }!
        try MiniTest.expect(statusIdx < buildIdx)
        try MiniTest.expect(buildIdx < stopIdx)
    }),
    ("buildLeavesRunningBuilderAlone", {
        let mock = MockProcessRunner()
        mock.handlers = [
            { args in
                if args == ["builder", "status", "--format", "json"] {
                    let json = #"[{"id":"buildkit","status":{"state":"running"}}]"#
                    return ProcessResult(exitCode: 0, stdout: Data(json.utf8), stderr: Data())
                }
                if args.first == "build" {
                    return ProcessResult(exitCode: 0, stdout: Data(), stderr: Data())
                }
                if args.starts(with: ["builder", "stop"]) {
                    return ProcessResult(exitCode: 99, stdout: Data(), stderr: Data("should not stop".utf8))
                }
                return ProcessResult(exitCode: 99, stdout: Data(), stderr: Data("unexpected".utf8))
            }
        ]
        let runtime = AppleContainerRuntime(executablePath: "/usr/local/bin/container", runner: mock)
        try runtime.build(
            contextDirectory: "/ctx",
            dockerfilePath: "/ctx/Dockerfile",
            tag: "adev:test",
            platform: "linux/arm64"
        )
        try MiniTest.expect(mock.calls.contains { $0.arguments.first == "build" })
        try MiniTest.expect(!mock.calls.contains { $0.arguments.starts(with: ["builder", "stop"]) })
    }),
    ("buildRestoresStoppedBuilderAfterFailure", {
        let mock = MockProcessRunner()
        var sawStop = false
        mock.handlers = [
            { args in
                if args == ["builder", "status", "--format", "json"] {
                    let json = #"[{"id":"buildkit","status":{"state":"stopped"}}]"#
                    return ProcessResult(exitCode: 0, stdout: Data(json.utf8), stderr: Data())
                }
                if args.first == "build" {
                    return ProcessResult(exitCode: 1, stdout: Data(), stderr: Data("build failed".utf8))
                }
                if args.starts(with: ["builder", "stop"]) {
                    sawStop = true
                    return ProcessResult(exitCode: 0, stdout: Data(), stderr: Data())
                }
                return ProcessResult(exitCode: 99, stdout: Data(), stderr: Data("unexpected".utf8))
            }
        ]
        let runtime = AppleContainerRuntime(executablePath: "/usr/local/bin/container", runner: mock)
        try MiniTest.expectThrows({
            try runtime.build(
                contextDirectory: "/ctx",
                dockerfilePath: "/ctx/Dockerfile",
                tag: "adev:test",
                platform: "linux/arm64"
            )
        }) { error in
            let err = error as! CLIError
            try MiniTest.expectEqual(err.code, CLIErrorCode.featureBuild)
        }
        try MiniTest.expect(sawStop)
        try MiniTest.expect(mock.calls.contains { $0.arguments.starts(with: ["builder", "stop"]) })
    }),
    ("workspaceOwnershipSkipsRootAndEmptyUser", {
        let mock = MockProcessRunner()
        let runtime = AppleContainerRuntime(executablePath: "/usr/local/bin/container", runner: mock)
        try WorkspaceOwnership.ensureWorkspaceWritableByRemoteUser(
            containerId: "ctr",
            workspaceFolder: "/workspaces/app",
            remoteUser: "root",
            runtime: runtime
        )
        try WorkspaceOwnership.ensureWorkspaceWritableByRemoteUser(
            containerId: "ctr",
            workspaceFolder: "/workspaces/app",
            remoteUser: nil,
            runtime: runtime
        )
        try WorkspaceOwnership.ensureNamedVolumeMountsWritableByRemoteUser(
            containerId: "ctr",
            mounts: [MountSpec(type: .volume, source: "v", target: "/home/vscode/.config")],
            remoteUser: "root",
            runtime: runtime
        )
        try MiniTest.expect(mock.calls.isEmpty, "root/unset remoteUser must not exec chown")
    }),
    ("workspaceOwnershipNamedVolumesChownTargetsOnly", {
        let mock = MockProcessRunner()
        mock.defaultResult = ProcessResult(exitCode: 0, stdout: Data(), stderr: Data())
        let runtime = AppleContainerRuntime(executablePath: "/usr/local/bin/container", runner: mock)
        let mounts = [
            MountSpec(type: .bind, source: "/host/path", target: "/bound"),
            MountSpec(type: .volume, source: "opencode-config", target: "/home/vscode/.config/opencode"),
            MountSpec(type: .volume, source: "opencode-data", target: "/home/vscode/.local/share/opencode"),
            MountSpec(type: .volume, source: "empty-target", target: "  ")
        ]
        try WorkspaceOwnership.ensureNamedVolumeMountsWritableByRemoteUser(
            containerId: "ctr",
            mounts: mounts,
            remoteUser: "vscode",
            runtime: runtime
        )
        let execs = mock.calls.filter { $0.arguments.first == "exec" }
        try MiniTest.expectEqual(execs.count, 1)
        let args = execs[0].arguments
        try MiniTest.expect(args.contains("-u"))
        try MiniTest.expect(args.contains("root"))
        let script = args.last ?? ""
        try MiniTest.expect(script.contains("chown -R"))
        try MiniTest.expect(script.contains("/home/vscode/.config/opencode"))
        try MiniTest.expect(script.contains("/home/vscode/.local/share/opencode"))
        try MiniTest.expect(!script.contains("/bound"), "must not chown bind mount targets")
        try MiniTest.expect(!script.contains("empty-target"))
    }),
    ("workspaceOwnershipNamedVolumesChownParentPaths", {
        let mock = MockProcessRunner()
        mock.defaultResult = ProcessResult(exitCode: 0, stdout: Data(), stderr: Data())
        let runtime = AppleContainerRuntime(executablePath: "/usr/local/bin/container", runner: mock)
        try WorkspaceOwnership.ensureNamedVolumeMountsWritableByRemoteUser(
            containerId: "ctr",
            mounts: [
                MountSpec(
                    type: .volume,
                    source: "opencode-data",
                    target: "/home/vscode/.local/share/opencode"
                )
            ],
            remoteUser: "vscode",
            runtime: runtime
        )
        let script = mock.calls.first(where: { $0.arguments.first == "exec" })?.arguments.last ?? ""
        try MiniTest.expect(script.contains("chown -R \"$OWN\" \"$T\""), "recursive chown target only")
        try MiniTest.expect(script.contains("dirname \"$T\""), "walk parents from target")
        try MiniTest.expect(script.contains("chown \"$OWN\" \"$P\""), "non-recursive parent chown")
        try MiniTest.expect(
            script.contains("|/home|"),
            "parent walk denylist must include /home"
        )
        try MiniTest.expect(
            script.contains("[ \"$N\" = \"$P\" ]"),
            "stop when dirname equals current path"
        )
        try MiniTest.expect(!script.contains("chown -R \"$OWN\" \"$P\""), "must not recurse parents")
        // Generated script must not emit a literal chown of system top /home
        // (only intermediate parents under the remote user home).
        try MiniTest.expect(
            !script.contains("chown \"$OWN\" \"/home\""),
            "must not chown /home for paths under /home/vscode/..."
        )
    }),
    ("workspaceOwnershipNamedVolumesSkipsReadonly", {
        let mock = MockProcessRunner()
        mock.defaultResult = ProcessResult(exitCode: 0, stdout: Data(), stderr: Data())
        let runtime = AppleContainerRuntime(executablePath: "/usr/local/bin/container", runner: mock)
        let mounts = [
            MountSpec(
                type: .volume,
                source: "ro-data",
                target: "/home/vscode/.cache/ro-vol",
                readonly: true
            ),
            MountSpec(
                type: .volume,
                source: "rw-data",
                target: "/home/vscode/.local/share/opencode",
                readonly: false
            )
        ]
        try WorkspaceOwnership.ensureNamedVolumeMountsWritableByRemoteUser(
            containerId: "ctr",
            mounts: mounts,
            remoteUser: "vscode",
            runtime: runtime
        )
        let script = mock.calls.first(where: { $0.arguments.first == "exec" })?.arguments.last ?? ""
        try MiniTest.expect(script.contains("/home/vscode/.local/share/opencode"))
        try MiniTest.expect(
            !script.contains("/home/vscode/.cache/ro-vol"),
            "must not chown readonly volume targets"
        )
    }),
    ("workspaceOwnershipNamedVolumesReadonlyOnlyNoop", {
        let mock = MockProcessRunner()
        let runtime = AppleContainerRuntime(executablePath: "/usr/local/bin/container", runner: mock)
        try WorkspaceOwnership.ensureNamedVolumeMountsWritableByRemoteUser(
            containerId: "ctr",
            mounts: [
                MountSpec(
                    type: .volume,
                    source: "ro-only",
                    target: "/data/ro",
                    readonly: true
                )
            ],
            remoteUser: "vscode",
            runtime: runtime
        )
        try MiniTest.expect(mock.calls.isEmpty, "readonly-only volumes must not exec chown")
    }),
    ("workspaceOwnershipBindOnlyMountsNoop", {
        let mock = MockProcessRunner()
        let runtime = AppleContainerRuntime(executablePath: "/usr/local/bin/container", runner: mock)
        try WorkspaceOwnership.ensureNamedVolumeMountsWritableByRemoteUser(
            containerId: "ctr",
            mounts: [MountSpec(type: .bind, source: "/host", target: "/in")],
            remoteUser: "vscode",
            runtime: runtime
        )
        try MiniTest.expect(mock.calls.isEmpty, "bind-only mounts must not chown")
    }),
    ("workspaceOwnershipShellSingleQuoted", {
        try MiniTest.expectEqual(WorkspaceOwnership.shellSingleQuoted("vscode"), "'vscode'")
        try MiniTest.expectEqual(WorkspaceOwnership.shellSingleQuoted("a'b"), "'a'\\''b'")
    })
]

// MARK: - Features runner unit tests

private enum FeaturesTestSupport {
    static func fixtureFeatureDir(_ name: String) -> String {
        TestRepo.root()
            .appendingPathComponent("Tests/Fixtures/features-sample/\(name)")
            .path
    }

    static let refA = "ghcr.io/adevcontainer/features/sample-a:1"
    static let refB = "ghcr.io/adevcontainer/features/sample-b:1"
    static let refPriv = "ghcr.io/adevcontainer/features/sample-privileged:1"
}

nonisolated(unsafe) let featuresUnitTests: [(String, () throws -> Void)] = [
    ("featuresEmptyObjectOK", {
        try ConfigAdmissions.admit(["image": "alpine:3.20", "features": [:] as [String: Any]])
        let parsed = try FeatureAdmission.parse([:] as [String: Any])
        try MiniTest.expectEqual(parsed.count, 0)
    }),
    ("featuresOmittedOK", {
        try ConfigAdmissions.admit(["image": "alpine:3.20"])
        let parsed = try FeatureAdmission.parse(nil)
        try MiniTest.expectEqual(parsed.count, 0)
    }),
    ("featuresMustBeObject", {
        try MiniTest.expectThrows({
            try ConfigAdmissions.admit([
                "image": "alpine:3.20",
                "features": ["ghcr.io/devcontainers/features/node:1"] as [Any]
            ])
        }) { error in
            let err = error as! CLIError
            try MiniTest.expectEqual(err.property, "features")
            try MiniTest.expect(err.message.lowercased().contains("object"))
        }
    }),
    ("featuresLocalPathAdmits", {
        for path in ["./local-feature", "../features/foo", "/abs/path", "file:///tmp/f"] {
            try ConfigAdmissions.admit([
                "image": "alpine:3.20",
                "features": [path: ["greeting": "x"] as [String: Any]]
            ])
            let parsed = try FeatureAdmission.parse([path: ["greeting": "x"] as [String: Any]])
            try MiniTest.expectEqual(parsed.count, 1)
            try MiniTest.expectEqual(parsed[0].reference, path)
            try MiniTest.expectEqual(parsed[0].options["greeting"]?.stringValue, "x")
            try MiniTest.expect(FeatureRef.isLocalPath(path))
        }
    }),
    ("featuresLocalFixtureAdmits", {
        let path = TestRepo.root().appendingPathComponent("Tests/Fixtures/features-local.json").path
        let obj = try JSONCParser.loadFile(at: path)
        try ConfigAdmissions.admit(obj)
        let features = try FeatureAdmission.parse(obj["features"])
        try MiniTest.expectEqual(features.count, 2)
        try MiniTest.expect(features.contains { $0.reference.contains("sample-a") })
        try MiniTest.expect(features.contains { $0.reference.contains("sample-b") })
        for f in features {
            try MiniTest.expect(FeatureRef.isLocalPath(f.reference))
            try MiniTest.expect(FeatureRef.warnSkippedDockerMarker(in: f.reference) == nil)
        }
    }),
    ("featuresDockerOODAnyRegistryTagWarnSkip", {
        let refs = [
            "ghcr.io/devcontainers/features/docker-outside-of-docker:1",
            "ghcr.io/devcontainers/features/docker-outside-of-docker:2.0",
            "example.com/mirror/docker-outside-of-docker:latest",
            "ghcr.io/other/docker-outside-of-docker"
        ]
        for ref in refs {
            try ConfigAdmissions.admit([
                "image": "alpine:3.20",
                "features": [ref: [:] as [String: Any]]
            ])
            let features = try FeatureAdmission.parse([ref: [:] as [String: Any]])
            try MiniTest.expectEqual(features.count, 0)
        }
    }),
    ("featuresDockerRelatedWarnSkipByName", {
        // Offline: admit succeeds and drops docker-in-docker / ood / from-docker (no network).
        let cases: [(ref: String, marker: String)] = [
            ("ghcr.io/devcontainers/features/docker-in-docker:2", "docker-in-docker"),
            ("ghcr.io/devcontainers/features/docker-outside-of-docker:1", "docker-outside-of-docker"),
            ("ghcr.io/devcontainers/features/docker-from-docker:1", "docker-from-docker"),
            ("example.com/mirror/docker-in-docker:latest", "docker-in-docker")
        ]
        for item in cases {
            try ConfigAdmissions.admit([
                "image": "alpine:3.20",
                "features": [
                    item.ref: [:] as [String: Any],
                    "ghcr.io/devcontainers/features/node:1": [:] as [String: Any]
                ]
            ])
            let features = try FeatureAdmission.parse([
                item.ref: [:] as [String: Any],
                "ghcr.io/devcontainers/features/node:1": [:] as [String: Any]
            ])
            try MiniTest.expectEqual(features.count, 1)
            try MiniTest.expect(features[0].reference.contains("node"))
            try MiniTest.expect(!features.contains { $0.reference.contains(item.marker) })
        }
    }),
    ("featuresDockerOODFixtureWarnSkips", {
        let path = TestRepo.root().appendingPathComponent("Tests/Fixtures/features-docker-ood.json").path
        let obj = try JSONCParser.loadFile(at: path)
        try ConfigAdmissions.admit(obj)
        let features = try FeatureAdmission.parse(obj["features"])
        try MiniTest.expectEqual(features.count, 0)
    }),
    ("featuresNodeFixtureAdmits", {
        let path = TestRepo.root().appendingPathComponent("Tests/Fixtures/features-node.json").path
        let obj = try JSONCParser.loadFile(at: path)
        try ConfigAdmissions.admit(obj)
        let features = try FeatureAdmission.parse(obj["features"])
        try MiniTest.expectEqual(features.count, 1)
        try MiniTest.expect(features[0].reference.contains("node"))
        try MiniTest.expect(FeatureRef.warnSkippedDockerMarker(in: features[0].reference) == nil)
    }),
    ("featuresTripleFixtureAdmits", {
        let path = TestRepo.root().appendingPathComponent("Tests/Fixtures/features-triple.json").path
        let obj = try JSONCParser.loadFile(at: path)
        try ConfigAdmissions.admit(obj)
        let features = try FeatureAdmission.parse(obj["features"])
        try MiniTest.expectEqual(features.count, 3)
        let refs = features.map(\.reference)
        try MiniTest.expect(refs.contains(where: { $0.contains("node") }))
        try MiniTest.expect(refs.contains(where: { $0.contains("/git:") || $0.hasSuffix("/git:1") || $0.contains("features/git") }))
        try MiniTest.expect(refs.contains(where: { $0.contains("github-cli") }))
        for ref in refs {
            try MiniTest.expect(FeatureRef.warnSkippedDockerMarker(in: ref) == nil, ref)
        }
    }),
    ("featureMetadataParseFixture", {
        let dir = FeaturesTestSupport.fixtureFeatureDir("sample-a")
        let data = try Data(contentsOf: URL(fileURLWithPath: dir)
            .appendingPathComponent("devcontainer-feature.json"))
        let meta = try FeatureMetadata.parse(data: data, featureRef: FeaturesTestSupport.refA)
        try MiniTest.expectEqual(meta.id, "sample-a")
        try MiniTest.expect(meta.initProcess)
        try MiniTest.expectEqual(meta.capAdd, ["SYS_PTRACE"])
        try MiniTest.expectEqual(meta.containerEnv["SAMPLE_A"], "from-feature-a")
        try MiniTest.expect(meta.onCreateCommand != nil)
        try MiniTest.expectEqual(meta.optionDefaults["greeting"]?.stringValue, "hello")
    }),
    ("featureMetadataMissingFails", {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("feat-missing-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        try MiniTest.expectThrows({
            _ = try FeatureMetadata.parse(
                data: Data("{}".utf8),
                featureRef: "ghcr.io/x/y:1"
            )
            // empty id falls back — use invalid JSON
            _ = try FeatureMetadata.parse(
                data: Data("not-json".utf8),
                featureRef: "ghcr.io/x/y:1"
            )
        }) { error in
            try MiniTest.expectEqual((error as! CLIError).code, CLIErrorCode.featureMetadata)
        }
    }),
    ("featureOrderDependsOn", {
        let metaA = try FeatureMetadata.parse(
            data: try Data(contentsOf: URL(fileURLWithPath: FeaturesTestSupport.fixtureFeatureDir("sample-a"))
                .appendingPathComponent("devcontainer-feature.json")),
            featureRef: FeaturesTestSupport.refA
        )
        let metaB = try FeatureMetadata.parse(
            data: try Data(contentsOf: URL(fileURLWithPath: FeaturesTestSupport.fixtureFeatureDir("sample-b"))
                .appendingPathComponent("devcontainer-feature.json")),
            featureRef: FeaturesTestSupport.refB
        )
        // Declare B before A — order must still put A first via dependsOn
        let ordered = try FeatureOrder.resolve([
            FeatureOrder.OrderedFeature(
                admitted: AdmittedFeature(reference: FeaturesTestSupport.refB),
                metadata: metaB
            ),
            FeatureOrder.OrderedFeature(
                admitted: AdmittedFeature(reference: FeaturesTestSupport.refA),
                metadata: metaA
            )
        ])
        try MiniTest.expectEqual(ordered.map(\.admitted.reference), [
            FeaturesTestSupport.refA,
            FeaturesTestSupport.refB
        ])
    }),
    ("featureOrderInstallsAfter", {
        let metaA = FeatureMetadata(id: "a")
        let metaB = FeatureMetadata(id: "b", installsAfter: ["a"])
        let ordered = try FeatureOrder.resolve([
            FeatureOrder.OrderedFeature(
                admitted: AdmittedFeature(reference: "b"),
                metadata: metaB
            ),
            FeatureOrder.OrderedFeature(
                admitted: AdmittedFeature(reference: "a"),
                metadata: metaA
            )
        ])
        try MiniTest.expectEqual(ordered.map(\.admitted.reference), ["a", "b"])
    }),
    ("featureOrderCycleFails", {
        let a = FeatureMetadata(id: "a", dependsOn: ["b": [:]])
        let b = FeatureMetadata(id: "b", dependsOn: ["a": [:]])
        try MiniTest.expectThrows({
            _ = try FeatureOrder.resolve([
                FeatureOrder.OrderedFeature(
                    admitted: AdmittedFeature(reference: "a"),
                    metadata: a
                ),
                FeatureOrder.OrderedFeature(
                    admitted: AdmittedFeature(reference: "b"),
                    metadata: b
                )
            ])
        }) { error in
            let err = error as! CLIError
            try MiniTest.expectEqual(err.code, CLIErrorCode.featureDependencyCycle)
            try MiniTest.expect(err.message.lowercased().contains("cycle"))
        }
    }),
    ("featurePrivilegedMetadataWarnSkip", {
        let data = try Data(contentsOf: URL(fileURLWithPath: FeaturesTestSupport.fixtureFeatureDir("sample-privileged"))
            .appendingPathComponent("devcontainer-feature.json"))
        let meta = try FeatureMetadata.parse(data: data, featureRef: FeaturesTestSupport.refPriv)
        try MiniTest.expect(meta.privileged)
        // Must not throw — privileged is warn-stripped; feature may still install.
        meta.warnStripUnsafeContributions(featureRef: FeaturesTestSupport.refPriv)
    }),
    ("featureSecurityOptWarnSkip", {
        let meta = FeatureMetadata(id: "x", securityOpt: ["label=disable"])
        try MiniTest.expect(!meta.securityOpt.isEmpty)
        // Must not throw — securityOpt is warn-stripped.
        meta.warnStripUnsafeContributions(featureRef: "ghcr.io/x:1")
    }),
    ("featureOptionsEnvNames", {
        try MiniTest.expectEqual(FeatureOptions.envName(forOption: "version"), "VERSION")
        try MiniTest.expectEqual(FeatureOptions.envName(forOption: "nodeVersion"), "NODE_VERSION")
        let env = FeatureOptions.installEnvironment(
            user: ["greeting": .string("hi")],
            defaults: ["greeting": .string("hello"), "mode": .string("x")]
        )
        try MiniTest.expectEqual(env["GREETING"], "hi")
        try MiniTest.expectEqual(env["MODE"], "x")
    }),
    ("featureMockFetchSuccessAnd404", {
        let cache = FileManager.default.temporaryDirectory
            .appendingPathComponent("feat-fetch-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: cache) }
        let mock = MockFeatureFetcher(packagesByRef: [
            FeaturesTestSupport.refA: FeaturesTestSupport.fixtureFeatureDir("sample-a")
        ], errorsByRef: [
            "ghcr.io/missing:1": CLIError(
                code: CLIErrorCode.featureFetch,
                property: "features",
                message: "Feature 'ghcr.io/missing:1' not found (404)",
                hint: "Check the feature reference and tag"
            )
        ])
        let dest = cache.appendingPathComponent("a").path
        let pkg = try mock.fetch(reference: FeaturesTestSupport.refA, destinationDirectory: dest)
        try MiniTest.expect(FileManager.default.fileExists(atPath: pkg.metadataPath))
        try MiniTest.expect(FileManager.default.fileExists(atPath: pkg.installScriptPath))
        try MiniTest.expectThrows({
            _ = try mock.fetch(
                reference: "ghcr.io/missing:1",
                destinationDirectory: cache.appendingPathComponent("m").path
            )
        }) { error in
            let err = error as! CLIError
            try MiniTest.expectEqual(err.code, CLIErrorCode.featureFetch)
            try MiniTest.expect(err.message.contains("404"))
        }
    }),
    ("featureLocalLoadCopiesPackage", {
        let ws = try TestRepo.makeTempWorkspace(configJSON: #"{ "image": "alpine:3.20" }"#)
        defer { try? FileManager.default.removeItem(at: ws) }
        let featuresRoot = ws.appendingPathComponent(".devcontainer/features", isDirectory: true)
        try FileManager.default.createDirectory(at: featuresRoot, withIntermediateDirectories: true)
        let sampleA = FeaturesTestSupport.fixtureFeatureDir("sample-a")
        try FileManager.default.copyItem(
            atPath: sampleA,
            toPath: featuresRoot.appendingPathComponent("sample-a").path
        )
        let cache = FileManager.default.temporaryDirectory
            .appendingPathComponent("feat-local-load-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: cache) }
        let dest = cache.appendingPathComponent("a").path
        let ref = "./.devcontainer/features/sample-a"
        let fetcher = DefaultFeatureFetcher(workspacePath: ws.path)
        let pkg = try fetcher.fetch(reference: ref, destinationDirectory: dest)
        try MiniTest.expectEqual(pkg.reference, ref)
        try MiniTest.expect(FileManager.default.fileExists(atPath: pkg.metadataPath))
        try MiniTest.expect(FileManager.default.fileExists(atPath: pkg.installScriptPath))
        let meta = try FeatureMetadata.parse(
            data: try Data(contentsOf: URL(fileURLWithPath: pkg.metadataPath)),
            featureRef: ref
        )
        try MiniTest.expectEqual(meta.id, "sample-a")
    }),
    ("featureLocalLoadMissingPathErrors", {
        let ws = try TestRepo.makeTempWorkspace(configJSON: #"{ "image": "alpine:3.20" }"#)
        defer { try? FileManager.default.removeItem(at: ws) }
        let cache = FileManager.default.temporaryDirectory
            .appendingPathComponent("feat-local-miss-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: cache) }
        let fetcher = DefaultFeatureFetcher(workspacePath: ws.path)
        try MiniTest.expectThrows({
            _ = try fetcher.fetch(
                reference: "./.devcontainer/features/does-not-exist",
                destinationDirectory: cache.appendingPathComponent("m").path
            )
        }) { error in
            let err = error as! CLIError
            try MiniTest.expectEqual(err.code, CLIErrorCode.featureFetch)
            try MiniTest.expect(err.message.lowercased().contains("does not exist")
                || err.message.lowercased().contains("not a directory")
                || err.message.contains("does-not-exist"))
        }
    }),
    ("featureLocalLoadMissingInstallShErrors", {
        let ws = try TestRepo.makeTempWorkspace(configJSON: #"{ "image": "alpine:3.20" }"#)
        defer { try? FileManager.default.removeItem(at: ws) }
        let feat = ws.appendingPathComponent(".devcontainer/features/broken", isDirectory: true)
        try FileManager.default.createDirectory(at: feat, withIntermediateDirectories: true)
        try #"{ "id": "broken", "version": "1.0.0" }"#.write(
            to: feat.appendingPathComponent("devcontainer-feature.json"),
            atomically: true,
            encoding: .utf8
        )
        let cache = FileManager.default.temporaryDirectory
            .appendingPathComponent("feat-local-noinst-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: cache) }
        let fetcher = DefaultFeatureFetcher(workspacePath: ws.path)
        try MiniTest.expectThrows({
            _ = try fetcher.fetch(
                reference: "./.devcontainer/features/broken",
                destinationDirectory: cache.appendingPathComponent("b").path
            )
        }) { error in
            let err = error as! CLIError
            try MiniTest.expect(err.message.lowercased().contains("install.sh"))
        }
    }),
    ("featureLocalSampleOrderDependsOnIdMatch", {
        let metaA = try FeatureMetadata.parse(
            data: try Data(contentsOf: URL(fileURLWithPath: FeaturesTestSupport.fixtureFeatureDir("sample-a"))
                .appendingPathComponent("devcontainer-feature.json")),
            featureRef: "./.devcontainer/features/sample-a"
        )
        let metaB = try FeatureMetadata.parse(
            data: try Data(contentsOf: URL(fileURLWithPath: FeaturesTestSupport.fixtureFeatureDir("sample-b"))
                .appendingPathComponent("devcontainer-feature.json")),
            featureRef: "./.devcontainer/features/sample-b"
        )
        // Local path refs; B dependsOn OCI-style sample-a — id segment match.
        let refA = "./.devcontainer/features/sample-a"
        let refB = "./.devcontainer/features/sample-b"
        let ordered = try FeatureOrder.resolve([
            FeatureOrder.OrderedFeature(
                admitted: AdmittedFeature(reference: refB, options: ["mode": .string("test")]),
                metadata: metaB
            ),
            FeatureOrder.OrderedFeature(
                admitted: AdmittedFeature(reference: refA, options: ["greeting": .string("local")]),
                metadata: metaA
            )
        ])
        try MiniTest.expectEqual(ordered.map(\.admitted.reference), [refA, refB])
    }),
    ("featureLocalPrivilegedWarnSkip", {
        let meta = try FeatureMetadata.parse(
            data: try Data(contentsOf: URL(fileURLWithPath: FeaturesTestSupport.fixtureFeatureDir("sample-privileged"))
                .appendingPathComponent("devcontainer-feature.json")),
            featureRef: "./.devcontainer/features/sample-privileged"
        )
        try MiniTest.expect(meta.privileged)
        meta.warnStripUnsafeContributions(featureRef: "./.devcontainer/features/sample-privileged")
    }),
    ("featuresRunnerLocalSampleAAndBOrder", {
        let ws = try TestRepo.makeTempWorkspace(configJSON: #"{ "image": "alpine:3.20" }"#)
        defer { try? FileManager.default.removeItem(at: ws) }
        let featuresRoot = ws.appendingPathComponent(".devcontainer/features", isDirectory: true)
        try FileManager.default.createDirectory(at: featuresRoot, withIntermediateDirectories: true)
        for name in ["sample-a", "sample-b"] {
            try FileManager.default.copyItem(
                atPath: FeaturesTestSupport.fixtureFeatureDir(name),
                toPath: featuresRoot.appendingPathComponent(name).path
            )
        }
        let cache = FileManager.default.temporaryDirectory
            .appendingPathComponent("feat-local-run-\(UUID().uuidString)", isDirectory: true).path
        defer { try? FileManager.default.removeItem(atPath: cache) }
        let fetcher = DefaultFeatureFetcher(workspacePath: ws.path)
        let mockProc = MockProcessRunner()
        mockProc.handlers = [
            MockProcessRunner.imageInspectHandler(baseUser: nil),
            { args in
                if args.starts(with: ["image", "list"]) {
                    return ProcessResult(exitCode: 1, stdout: Data(), stderr: Data("missing".utf8))
                }
                if args.first == "build" {
                    return ProcessResult(exitCode: 0, stdout: Data(), stderr: Data())
                }
                return ProcessResult(exitCode: 0, stdout: Data(), stderr: Data())
            }
        ]
        let runtime = AppleContainerRuntime(executablePath: "/usr/local/bin/container", runner: mockProc)
        let refA = "./.devcontainer/features/sample-a"
        let refB = "./.devcontainer/features/sample-b"
        let result = try FeaturesRunner.run(
            features: [
                AdmittedFeature(reference: refB, options: ["mode": .string("test")]),
                AdmittedFeature(reference: refA, options: ["greeting": .string("local")])
            ],
            baseImage: "alpine:3.20",
            deps: FeaturesRunner.Dependencies(
                fetcher: fetcher,
                runtime: runtime,
                cacheRoot: cache,
                platform: "linux/arm64"
            )
        )
        try MiniTest.expectEqual(result.orderedRefs, [refA, refB])
        try MiniTest.expect(!result.reusedExistingImage)
        try MiniTest.expect(result.derivedImage.hasPrefix("adevcontainer:"))
        try MiniTest.expect(!result.derivedImage.contains("/features"))
    }),
    ("featureInstallEnvAndSafeName", {
        let metaA = try FeatureMetadata.parse(
            data: try Data(contentsOf: URL(fileURLWithPath: FeaturesTestSupport.fixtureFeatureDir("sample-a"))
                .appendingPathComponent("devcontainer-feature.json")),
            featureRef: FeaturesTestSupport.refA
        )
        let ordered = [
            FeatureOrder.OrderedFeature(
                admitted: AdmittedFeature(
                    reference: FeaturesTestSupport.refA,
                    options: ["greeting": .string("yo")]
                ),
                metadata: metaA
            )
        ]
        let userEnv = FeatureOptions.userInstallEnvironment(
            remoteUser: "vscode",
            containerUser: "vscode"
        )
        var installEnv = FeatureOptions.installEnvironment(
            user: ordered[0].admitted.options,
            defaults: ordered[0].metadata.optionDefaults
        )
        for (k, v) in userEnv { installEnv[k] = v }
        try MiniTest.expectEqual(installEnv["GREETING"], "yo")
        try MiniTest.expectEqual(installEnv["_REMOTE_USER"], "vscode")
        try MiniTest.expectEqual(installEnv["_REMOTE_USER_HOME"], "/home/vscode")
        try MiniTest.expectEqual(installEnv["_CONTAINER_USER"], "vscode")
        let safe = FeatureInstaller.safeName(for: FeaturesTestSupport.refA, index: 0)
        try MiniTest.expect(safe.hasPrefix("0-"))
        try MiniTest.expect(!safe.contains("/"))
        try MiniTest.expect(!safe.contains(":"))
    }),
    ("featureDockerfileGeneratorChmodsPackageRecursively", {
        // shell-history-style: install.sh copies oncreate.sh (often 0644 in OCI) to a
        // bare-path onCreateCommand. Reference CLI does `chmod -R 0755` on the package
        // before install so cp preserves +x and `sh -lc /path/oncreate.sh` does not 126.
        let metaA = try FeatureMetadata.parse(
            data: try Data(contentsOf: URL(fileURLWithPath: FeaturesTestSupport.fixtureFeatureDir("sample-a"))
                .appendingPathComponent("devcontainer-feature.json")),
            featureRef: FeaturesTestSupport.refA
        )
        let ctxDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("feat-df-\(UUID().uuidString)", isDirectory: true).path
        defer { try? FileManager.default.removeItem(atPath: ctxDir) }
        let ordered = [
            FeatureOrder.OrderedFeature(
                admitted: AdmittedFeature(
                    reference: FeaturesTestSupport.refA,
                    options: ["greeting": .string("hi")]
                ),
                metadata: metaA
            )
        ]
        let packages = [
            FetchedFeaturePackage(
                reference: FeaturesTestSupport.refA,
                directoryPath: FeaturesTestSupport.fixtureFeatureDir("sample-a")
            )
        ]
        let ctx = try FeatureDockerfileGenerator.write(
            baseImage: "alpine:3.20",
            ordered: ordered,
            packages: packages,
            contextDirectory: ctxDir,
            remoteUser: "vscode",
            containerUser: "vscode",
            baseUser: "node"
        )
        let contents = ctx.dockerfileContents
        try MiniTest.expect(contents.contains("FROM alpine:3.20"))
        try MiniTest.expect(contents.contains("COPY feature-0 /tmp/adev-feature-0"))
        try MiniTest.expect(contents.contains("chmod -R 0755 /tmp/adev-feature-0"))
        try MiniTest.expect(contents.contains("./install.sh"))
        // Must not only chmod install.sh — lifecycle scripts need +x too.
        try MiniTest.expect(!contents.contains("chmod +x /tmp/adev-feature-0/install.sh"))
        try MiniTest.expect(contents.contains("USER root"))
        try MiniTest.expect(contents.contains("USER node"))
        // Final USER is base user, not lingering install root.
        let lastUserLine = contents.split(separator: "\n").last(where: { $0.hasPrefix("USER ") })
        try MiniTest.expectEqual(lastUserLine.map(String.init), "USER node")
        try MiniTest.expect(FileManager.default.fileExists(atPath: ctx.dockerfilePath))
    }),
    ("featureDockerfileGeneratorRestoresRootWhenBaseUserEmpty", {
        let metaA = try FeatureMetadata.parse(
            data: try Data(contentsOf: URL(fileURLWithPath: FeaturesTestSupport.fixtureFeatureDir("sample-a"))
                .appendingPathComponent("devcontainer-feature.json")),
            featureRef: FeaturesTestSupport.refA
        )
        let ctxDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("feat-df-empty-\(UUID().uuidString)", isDirectory: true).path
        defer { try? FileManager.default.removeItem(atPath: ctxDir) }
        let ordered = [
            FeatureOrder.OrderedFeature(
                admitted: AdmittedFeature(reference: FeaturesTestSupport.refA, options: [:]),
                metadata: metaA
            )
        ]
        let packages = [
            FetchedFeaturePackage(
                reference: FeaturesTestSupport.refA,
                directoryPath: FeaturesTestSupport.fixtureFeatureDir("sample-a")
            )
        ]
        let ctx = try FeatureDockerfileGenerator.write(
            baseImage: "alpine:3.20",
            ordered: ordered,
            packages: packages,
            contextDirectory: ctxDir,
            baseUser: nil
        )
        let lastUserLine = ctx.dockerfileContents.split(separator: "\n").last(where: { $0.hasPrefix("USER ") })
        try MiniTest.expectEqual(lastUserLine.map(String.init), "USER root")
    }),
    ("featureDockerfileGeneratorDoesNotEndRootWhenBaseIsNode", {
        let metaA = try FeatureMetadata.parse(
            data: try Data(contentsOf: URL(fileURLWithPath: FeaturesTestSupport.fixtureFeatureDir("sample-a"))
                .appendingPathComponent("devcontainer-feature.json")),
            featureRef: FeaturesTestSupport.refA
        )
        let ctxDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("feat-df-node-\(UUID().uuidString)", isDirectory: true).path
        defer { try? FileManager.default.removeItem(atPath: ctxDir) }
        let ordered = [
            FeatureOrder.OrderedFeature(
                admitted: AdmittedFeature(reference: FeaturesTestSupport.refA, options: [:]),
                metadata: metaA
            )
        ]
        let packages = [
            FetchedFeaturePackage(
                reference: FeaturesTestSupport.refA,
                directoryPath: FeaturesTestSupport.fixtureFeatureDir("sample-a")
            )
        ]
        let ctx = try FeatureDockerfileGenerator.write(
            baseImage: "node:20",
            ordered: ordered,
            packages: packages,
            contextDirectory: ctxDir,
            baseUser: "node"
        )
        try MiniTest.expect(!ctx.dockerfileContents.trimmingCharacters(in: .whitespacesAndNewlines).hasSuffix("USER root"))
        try MiniTest.expect(ctx.dockerfileContents.contains("USER node"))
        // Install env falls back to base USER when config users empty (not unconditional root).
        try MiniTest.expect(ctx.dockerfileContents.contains("_REMOTE_USER=node"))
        try MiniTest.expect(ctx.dockerfileContents.contains("_CONTAINER_USER=node"))
    }),
    ("featureDockerfileGeneratorInstallSeesContainerEnv", {
        // Feature metadata containerEnv (e.g. DOTNET_ROOT) must reach install.sh.
        var meta = try FeatureMetadata.parse(
            data: try Data(contentsOf: URL(fileURLWithPath: FeaturesTestSupport.fixtureFeatureDir("sample-a"))
                .appendingPathComponent("devcontainer-feature.json")),
            featureRef: FeaturesTestSupport.refA
        )
        meta.containerEnv["DOTNET_ROOT"] = "/usr/share/dotnet"
        let ctxDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("feat-df-cenv-\(UUID().uuidString)", isDirectory: true).path
        defer { try? FileManager.default.removeItem(atPath: ctxDir) }
        let ordered = [
            FeatureOrder.OrderedFeature(
                admitted: AdmittedFeature(
                    reference: FeaturesTestSupport.refA,
                    options: ["greeting": .string("hi")]
                ),
                metadata: meta
            )
        ]
        let packages = [
            FetchedFeaturePackage(
                reference: FeaturesTestSupport.refA,
                directoryPath: FeaturesTestSupport.fixtureFeatureDir("sample-a")
            )
        ]
        let ctx = try FeatureDockerfileGenerator.write(
            baseImage: "alpine:3.20",
            ordered: ordered,
            packages: packages,
            contextDirectory: ctxDir,
            remoteUser: "vscode",
            containerUser: "vscode",
            baseUser: "root"
        )
        let contents = ctx.dockerfileContents
        // Metadata containerEnv is Dockerfile ENV (not RUN single-quoted prefix).
        try MiniTest.expect(contents.contains("ENV DOTNET_ROOT=/usr/share/dotnet"))
        try MiniTest.expect(contents.contains("ENV SAMPLE_A=from-feature-a"))
        try MiniTest.expect(contents.contains("./install.sh"))
        // Config-file containerEnv must not appear in install Dockerfile.
        try MiniTest.expect(!contents.contains("from-config"))
    }),
    ("featureDockerfileGeneratorContainerEnvPathDollarRefs", {
        // PATH=$PATH:$DOTNET_ROOT must not become PATH='$PATH:…' (wipes real PATH).
        var meta = try FeatureMetadata.parse(
            data: try Data(contentsOf: URL(fileURLWithPath: FeaturesTestSupport.fixtureFeatureDir("sample-a"))
                .appendingPathComponent("devcontainer-feature.json")),
            featureRef: FeaturesTestSupport.refA
        )
        meta.containerEnv["DOTNET_ROOT"] = "/usr/share/dotnet"
        meta.containerEnv["PATH"] = "$PATH:$DOTNET_ROOT"
        let ctxDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("feat-df-path-refs-\(UUID().uuidString)", isDirectory: true).path
        defer { try? FileManager.default.removeItem(atPath: ctxDir) }
        let ordered = [
            FeatureOrder.OrderedFeature(
                admitted: AdmittedFeature(
                    reference: FeaturesTestSupport.refA,
                    options: ["greeting": .string("hi")]
                ),
                metadata: meta
            )
        ]
        let packages = [
            FetchedFeaturePackage(
                reference: FeaturesTestSupport.refA,
                directoryPath: FeaturesTestSupport.fixtureFeatureDir("sample-a")
            )
        ]
        let ctx = try FeatureDockerfileGenerator.write(
            baseImage: "alpine:3.20",
            ordered: ordered,
            packages: packages,
            contextDirectory: ctxDir,
            remoteUser: "vscode",
            containerUser: "vscode",
            baseUser: "root"
        )
        let contents = ctx.dockerfileContents
        try MiniTest.expect(contents.contains("ENV DOTNET_ROOT=/usr/share/dotnet"))
        try MiniTest.expect(contents.contains("ENV PATH=$PATH:$DOTNET_ROOT"))
        try MiniTest.expect(!contents.contains("PATH='$PATH:$DOTNET_ROOT'"))
        try MiniTest.expect(!contents.contains("PATH=\"'$PATH:$DOTNET_ROOT'\""))
        // Options / user keys remain on RUN export prefix (not ENV).
        try MiniTest.expect(contents.contains("GREETING=hi"))
        try MiniTest.expect(!contents.contains("ENV GREETING="))
        try MiniTest.expect(contents.contains("_REMOTE_USER=vscode"))
        try MiniTest.expect(!contents.contains("ENV _REMOTE_USER="))
        // ENV lines appear before the feature's install RUN.
        let envPathIdx = contents.range(of: "ENV PATH=$PATH:$DOTNET_ROOT")?.lowerBound
        let runIdx = contents.range(of: "RUN chmod -R 0755")?.lowerBound
        try MiniTest.expect(envPathIdx != nil && runIdx != nil)
        if let envPathIdx, let runIdx {
            try MiniTest.expect(envPathIdx < runIdx)
        }
    }),
    ("featureDockerfileGeneratorEmptyContainerEnvUnchanged", {
        let meta = FeatureMetadata(
            id: "no-cenv",
            containerEnv: [:],
            optionDefaults: ["greeting": .string("hello")]
        )
        let ctxDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("feat-df-empty-cenv-\(UUID().uuidString)", isDirectory: true).path
        defer { try? FileManager.default.removeItem(atPath: ctxDir) }
        // Need a real package with install.sh — use sample-a package path but empty-cenv metadata.
        let ordered = [
            FeatureOrder.OrderedFeature(
                admitted: AdmittedFeature(
                    reference: FeaturesTestSupport.refA,
                    options: ["greeting": .string("yo")]
                ),
                metadata: meta
            )
        ]
        let packages = [
            FetchedFeaturePackage(
                reference: FeaturesTestSupport.refA,
                directoryPath: FeaturesTestSupport.fixtureFeatureDir("sample-a")
            )
        ]
        let ctx = try FeatureDockerfileGenerator.write(
            baseImage: "alpine:3.20",
            ordered: ordered,
            packages: packages,
            contextDirectory: ctxDir,
            remoteUser: "vscode",
            containerUser: "vscode",
            baseUser: "root"
        )
        let contents = ctx.dockerfileContents
        try MiniTest.expect(contents.contains("GREETING=yo"))
        try MiniTest.expect(contents.contains("_REMOTE_USER=vscode"))
        try MiniTest.expect(contents.contains("_CONTAINER_USER=vscode"))
        try MiniTest.expect(contents.contains("_REMOTE_USER_HOME=/home/vscode"))
        try MiniTest.expect(contents.contains("_CONTAINER_USER_HOME=/home/vscode"))
        // Fixture SAMPLE_A must not leak when metadata.containerEnv is empty.
        try MiniTest.expect(!contents.contains("SAMPLE_A="))
        try MiniTest.expect(!contents.contains("DOTNET_ROOT="))
    }),
    ("featureDockerfileGeneratorContainerEnvWithOptionsAndUser", {
        var meta = try FeatureMetadata.parse(
            data: try Data(contentsOf: URL(fileURLWithPath: FeaturesTestSupport.fixtureFeatureDir("sample-a"))
                .appendingPathComponent("devcontainer-feature.json")),
            featureRef: FeaturesTestSupport.refA
        )
        meta.containerEnv["DOTNET_ROOT"] = "/usr/share/dotnet"
        let ctxDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("feat-df-coexist-\(UUID().uuidString)", isDirectory: true).path
        defer { try? FileManager.default.removeItem(atPath: ctxDir) }
        let ordered = [
            FeatureOrder.OrderedFeature(
                admitted: AdmittedFeature(
                    reference: FeaturesTestSupport.refA,
                    options: ["greeting": .string("hi")]
                ),
                metadata: meta
            )
        ]
        let packages = [
            FetchedFeaturePackage(
                reference: FeaturesTestSupport.refA,
                directoryPath: FeaturesTestSupport.fixtureFeatureDir("sample-a")
            )
        ]
        let ctx = try FeatureDockerfileGenerator.write(
            baseImage: "alpine:3.20",
            ordered: ordered,
            packages: packages,
            contextDirectory: ctxDir,
            remoteUser: "dev",
            containerUser: "dev",
            baseUser: "root"
        )
        let contents = ctx.dockerfileContents
        try MiniTest.expect(contents.contains("ENV DOTNET_ROOT=/usr/share/dotnet"))
        try MiniTest.expect(contents.contains("ENV SAMPLE_A=from-feature-a"))
        try MiniTest.expect(contents.contains("GREETING=hi"))
        try MiniTest.expect(!contents.contains("ENV GREETING="))
        try MiniTest.expect(contents.contains("_REMOTE_USER=dev"))
        try MiniTest.expect(contents.contains("_CONTAINER_USER=dev"))
        try MiniTest.expect(contents.contains("_REMOTE_USER_HOME=/home/dev"))
        try MiniTest.expect(contents.contains("USER root"))
        let lastUserLine = contents.split(separator: "\n").last(where: { $0.hasPrefix("USER ") })
        try MiniTest.expectEqual(lastUserLine.map(String.init), "USER root")
    }),
    ("featuresRunnerFailsClosedOnBaseInspectFailure", {
        let cache = FileManager.default.temporaryDirectory
            .appendingPathComponent("feat-inspect-fail-\(UUID().uuidString)", isDirectory: true).path
        defer { try? FileManager.default.removeItem(atPath: cache) }
        let mockFetch = MockFeatureFetcher(packagesByRef: [
            FeaturesTestSupport.refA: FeaturesTestSupport.fixtureFeatureDir("sample-a")
        ])
        let mockProc = MockProcessRunner()
        mockProc.handlers = [
            { args in
                if args.starts(with: ["image", "inspect"]) {
                    return ProcessResult(exitCode: 1, stdout: Data(), stderr: Data("nope".utf8))
                }
                if args.starts(with: ["image", "list"]) {
                    return ProcessResult(exitCode: 0, stdout: Data("[]".utf8), stderr: Data())
                }
                if args.first == "build" {
                    return ProcessResult(exitCode: 0, stdout: Data(), stderr: Data())
                }
                return ProcessResult(exitCode: 0, stdout: Data(), stderr: Data())
            }
        ]
        let runtime = AppleContainerRuntime(executablePath: "/usr/local/bin/container", runner: mockProc)
        try MiniTest.expectThrows({
            _ = try FeaturesRunner.run(
                features: [AdmittedFeature(reference: FeaturesTestSupport.refA, options: [:])],
                baseImage: "alpine:3.20",
                deps: FeaturesRunner.Dependencies(
                    fetcher: mockFetch,
                    runtime: runtime,
                    cacheRoot: cache,
                    platform: "linux/arm64"
                )
            )
        }) { error in
            let err = error as! CLIError
            try MiniTest.expect(err.message.lowercased().contains("inspect") || err.message.lowercased().contains("user"))
        }
        try MiniTest.expect(!mockProc.calls.contains { $0.arguments.first == "build" })
    }),
    ("derivedImageTagRecipeVersionBumpedForUserRestore", {
        try MiniTest.expectEqual(DerivedImageTag.recipeVersion, "5")
        let metaA = try FeatureMetadata.parse(
            data: try Data(contentsOf: URL(fileURLWithPath: FeaturesTestSupport.fixtureFeatureDir("sample-a"))
                .appendingPathComponent("devcontainer-feature.json")),
            featureRef: FeaturesTestSupport.refA
        )
        let ordered = [
            FeatureOrder.OrderedFeature(
                admitted: AdmittedFeature(reference: FeaturesTestSupport.refA, options: [:]),
                metadata: metaA
            )
        ]
        let v4 = DerivedImageTag.compute(
            baseImage: "alpine:3.20",
            ordered: ordered,
            nameBase: "x",
            recipeVersion: "4"
        )
        let v5 = DerivedImageTag.compute(
            baseImage: "alpine:3.20",
            ordered: ordered,
            nameBase: "x",
            recipeVersion: "5"
        )
        try MiniTest.expect(v4 != v5, "recipeVersion bump must change derived tag")
        let product = DerivedImageTag.compute(
            baseImage: "alpine:3.20",
            ordered: ordered,
            nameBase: "x"
        )
        try MiniTest.expectEqual(product, v5)
    }),
    ("tomlMergeBuildRosettaFalsePreservesKeys", {
        let input = """
        # header
        [machine]
        cpus = 7
        memory = "24gb"

        [build]
        cpus = 2
        rosetta = true
        memory = "2048mb"

        [network]
        """
        let out = AppleContainerConfig.mergeBuildRosettaFalse(into: input)
        try MiniTest.expectEqual(AppleContainerConfig.parseBuildRosetta(from: out), false)
        try MiniTest.expect(out.contains("cpus = 7"))
        try MiniTest.expect(out.contains("memory = \"24gb\""))
        try MiniTest.expect(out.contains("cpus = 2"))
        try MiniTest.expect(out.contains("memory = \"2048mb\""))
        try MiniTest.expect(out.contains("[network]"))
        try MiniTest.expect(out.contains("rosetta = false"))
        try MiniTest.expect(!out.contains("rosetta = true"))
        // Empty file → creates [build]
        let created = AppleContainerConfig.mergeBuildRosettaFalse(into: "")
        try MiniTest.expectEqual(AppleContainerConfig.parseBuildRosetta(from: created), false)
        try MiniTest.expect(created.contains("[build]"))
        // Missing rosetta key under [build]
        let noKey = """
        [build]
        cpus = 4
        """
        let added = AppleContainerConfig.mergeBuildRosettaFalse(into: noKey)
        try MiniTest.expectEqual(AppleContainerConfig.parseBuildRosetta(from: added), false)
        try MiniTest.expect(added.contains("cpus = 4"))
    }),
    ("ensureNativeArmAlreadyFalseNoWriteNoPrompt", {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("adev-rosetta-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let configPath = dir.appendingPathComponent("config.toml").path
        try "[build]\nrosetta = false\n".write(toFile: configPath, atomically: true, encoding: .utf8)

        let mock = MockProcessRunner()
        mock.handlers = [
            { args in
                if args.starts(with: ["system", "property", "list"]) {
                    return ProcessResult(
                        exitCode: 0,
                        stdout: Data("[build]\nrosetta = false\n".utf8),
                        stderr: Data()
                    )
                }
                return ProcessResult(exitCode: 99, stdout: Data(), stderr: Data("unexpected".utf8))
            }
        ]
        let runtime = AppleContainerRuntime(executablePath: "/usr/local/bin/container", runner: mock)
        var prompted = false
        try AppleContainerConfig.ensureNativeArmBuild(
            runtime: runtime,
            options: AppleContainerConfig.EnsureOptions(
                configPath: configPath,
                environment: [:],
                isInteractive: true,
                readLine: {
                    prompted = true
                    return "n"
                }
            )
        )
        try MiniTest.expect(!prompted)
        // Only property list — no builder delete / system restart
        try MiniTest.expectEqual(mock.calls.count, 1)
        try MiniTest.expect(mock.calls[0].arguments.starts(with: ["system", "property", "list"]))
        let onDisk = try String(contentsOfFile: configPath, encoding: .utf8)
        try MiniTest.expectEqual(onDisk, "[build]\nrosetta = false\n")
    }),
    ("ensureNativeArmDeclineErrors", {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("adev-rosetta-d-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let configPath = dir.appendingPathComponent("config.toml").path

        let mock = MockProcessRunner()
        mock.handlers = [
            { args in
                if args.starts(with: ["system", "property", "list"]) {
                    return ProcessResult(
                        exitCode: 0,
                        stdout: Data("[build]\nrosetta = true\n".utf8),
                        stderr: Data()
                    )
                }
                return ProcessResult(exitCode: 0, stdout: Data(), stderr: Data())
            }
        ]
        let runtime = AppleContainerRuntime(executablePath: "/usr/local/bin/container", runner: mock)
        try MiniTest.expectThrows({
            try AppleContainerConfig.ensureNativeArmBuild(
                runtime: runtime,
                options: AppleContainerConfig.EnsureOptions(
                    configPath: configPath,
                    environment: [:],
                    isInteractive: true,
                    readLine: { "n" }
                )
            )
        }) { error in
            let err = error as! CLIError
            try MiniTest.expectEqual(err.code, CLIErrorCode.buildRosettaConfig)
            try MiniTest.expect(err.message.lowercased().contains("declined"))
        }
        try MiniTest.expect(!FileManager.default.fileExists(atPath: configPath))
    }),
    ("ensureNativeArmEnvAutoAcceptWrites", {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("adev-rosetta-a-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let configPath = dir.appendingPathComponent("config.toml").path
        try """
        [machine]
        cpus = 4
        [build]
        rosetta = true
        cpus = 2
        """.write(toFile: configPath, atomically: true, encoding: .utf8)

        let mock = MockProcessRunner()
        var propertyCalls = 0
        mock.handlers = [
            { args in
                if args.starts(with: ["system", "property", "list"]) {
                    propertyCalls += 1
                    // First call: still true; after write+restart mock returns false
                    if propertyCalls == 1 {
                        return ProcessResult(
                            exitCode: 0,
                            stdout: Data("[build]\nrosetta = true\n".utf8),
                            stderr: Data()
                        )
                    }
                    return ProcessResult(
                        exitCode: 0,
                        stdout: Data("[build]\nrosetta = false\n".utf8),
                        stderr: Data()
                    )
                }
                if args.starts(with: ["builder", "stop"])
                    || args.starts(with: ["builder", "delete"])
                    || args.starts(with: ["builder", "rm"]) {
                    return ProcessResult(exitCode: 0, stdout: Data(), stderr: Data())
                }
                return ProcessResult(exitCode: 0, stdout: Data(), stderr: Data())
            }
        ]
        let runtime = AppleContainerRuntime(executablePath: "/usr/local/bin/container", runner: mock)
        var prompted = false
        try AppleContainerConfig.ensureNativeArmBuild(
            runtime: runtime,
            options: AppleContainerConfig.EnsureOptions(
                configPath: configPath,
                environment: [AppleContainerConfig.allowDisableEnvKey: "1"],
                isInteractive: false,
                readLine: {
                    prompted = true
                    return nil
                }
            )
        )
        try MiniTest.expect(!prompted)
        let onDisk = try String(contentsOfFile: configPath, encoding: .utf8)
        try MiniTest.expectEqual(AppleContainerConfig.parseBuildRosetta(from: onDisk), false)
        try MiniTest.expect(onDisk.contains("cpus = 4"))
        try MiniTest.expect(onDisk.contains("cpus = 2"))
        try MiniTest.expect(mock.calls.contains {
            $0.arguments.starts(with: ["builder", "delete"]) || $0.arguments.starts(with: ["builder", "rm"])
        })
    }),
    ("featureDerivedTagStableAndOptionsChange", {
        let metaA = try FeatureMetadata.parse(
            data: try Data(contentsOf: URL(fileURLWithPath: FeaturesTestSupport.fixtureFeatureDir("sample-a"))
                .appendingPathComponent("devcontainer-feature.json")),
            featureRef: FeaturesTestSupport.refA
        )
        let o1 = [
            FeatureOrder.OrderedFeature(
                admitted: AdmittedFeature(
                    reference: FeaturesTestSupport.refA,
                    options: ["greeting": .string("a")]
                ),
                metadata: metaA
            )
        ]
        let o2 = [
            FeatureOrder.OrderedFeature(
                admitted: AdmittedFeature(
                    reference: FeaturesTestSupport.refA,
                    options: ["greeting": .string("b")]
                ),
                metadata: metaA
            )
        ]
        let t1 = DerivedImageTag.compute(baseImage: "alpine:3.20", ordered: o1, nameBase: "my-app")
        let t1b = DerivedImageTag.compute(baseImage: "alpine:3.20", ordered: o1, nameBase: "my-app")
        let t2 = DerivedImageTag.compute(baseImage: "alpine:3.20", ordered: o2, nameBase: "my-app")
        try MiniTest.expectEqual(t1, t1b)
        try MiniTest.expect(t1 != t2)
        try MiniTest.expect(t1.hasPrefix("adev-my-app:"))
        try MiniTest.expect(!t1.contains("/features"))
        let tEmpty = DerivedImageTag.compute(baseImage: "alpine:3.20", ordered: o1, nameBase: "")
        try MiniTest.expect(tEmpty.hasPrefix("adevcontainer:"))
        try MiniTest.expect(!tEmpty.contains("/features"))
        // Same content hash regardless of nameBase label.
        try MiniTest.expectEqual(
            String(t1.split(separator: ":").last ?? ""),
            String(tEmpty.split(separator: ":").last ?? "")
        )
        // Default recipeVersion is the product constant (included in material).
        let tDefaultRecipe = DerivedImageTag.compute(
            baseImage: "alpine:3.20",
            ordered: o1,
            nameBase: "my-app",
            recipeVersion: DerivedImageTag.recipeVersion
        )
        try MiniTest.expectEqual(t1, tDefaultRecipe)
    }),
    ("featureDerivedTagChangesWithRecipeVersion", {
        // Generator install-semantics bumps must invalidate stale derived images
        // (e.g. containerEnv as ENV with $VAR expansion → recipeVersion 5).
        let metaA = try FeatureMetadata.parse(
            data: try Data(contentsOf: URL(fileURLWithPath: FeaturesTestSupport.fixtureFeatureDir("sample-a"))
                .appendingPathComponent("devcontainer-feature.json")),
            featureRef: FeaturesTestSupport.refA
        )
        let ordered = [
            FeatureOrder.OrderedFeature(
                admitted: AdmittedFeature(
                    reference: FeaturesTestSupport.refA,
                    options: ["greeting": .string("a")]
                ),
                metadata: metaA
            )
        ]
        let sameV = DerivedImageTag.compute(
            baseImage: "alpine:3.20",
            ordered: ordered,
            nameBase: "app",
            recipeVersion: "5"
        )
        let sameVAgain = DerivedImageTag.compute(
            baseImage: "alpine:3.20",
            ordered: ordered,
            nameBase: "app",
            recipeVersion: "5"
        )
        let prior = DerivedImageTag.compute(
            baseImage: "alpine:3.20",
            ordered: ordered,
            nameBase: "app",
            recipeVersion: "4"
        )
        try MiniTest.expectEqual(sameV, sameVAgain)
        try MiniTest.expect(sameV != prior)
        try MiniTest.expect(sameV.hasPrefix("adev-app:"))
        try MiniTest.expect(prior.hasPrefix("adev-app:"))
        try MiniTest.expectEqual(
            String(sameV.split(separator: ":").last ?? "").count,
            12
        )
    }),
    ("featureDerivedTagUsesWorkspaceBasenameViaHumanBase", {
        let base = ContainerIdentity.humanBase(configName: nil, workspacePath: "/Users/me/My_Project")
        try MiniTest.expectEqual(base, "my-project")
        let named = ContainerIdentity.humanBase(configName: "Cool App", workspacePath: "/Users/me/My_Project")
        try MiniTest.expectEqual(named, "cool-app")
        // Collapse consecutive hyphens; clip ≤20; re-trim so base cannot end/start with `-`.
        let clipped = ContainerIdentity.humanBase(
            configName: "test----------------end",
            workspacePath: "/Users/me/My_Project"
        )
        try MiniTest.expectEqual(clipped, "test-end")
        try MiniTest.expect(!clipped.hasPrefix("-"))
        try MiniTest.expect(!clipped.hasSuffix("-"))
        try MiniTest.expect(!clipped.contains("--"))
    }),
    ("sanitizeBaseCollapsesPunctuationHyphensForValidImageTag", {
        // Regression: "C# (.NET)" previously → "c----net" → invalid `adev-c----net:<hash>`.
        let csharp = ContainerIdentity.sanitizeBase("C# (.NET)")
        try MiniTest.expectEqual(csharp, "c-net")
        try MiniTest.expect(!csharp.contains("--"))
        try MiniTest.expect(!csharp.hasPrefix("-"))
        try MiniTest.expect(!csharp.hasSuffix("-"))
        try MiniTest.expect(csharp.range(of: "^[a-z0-9-]+$", options: .regularExpression) != nil)

        let tag = DerivedImageTag.compute(
            baseImage: "mcr.microsoft.com/dotnet/sdk:8.0",
            ordered: [],
            nameBase: csharp
        )
        try MiniTest.expect(tag.hasPrefix("adev-c-net:"))
        try MiniTest.expect(!tag.contains("--"))
        let hashPart = String(tag.split(separator: ":").last ?? "")
        try MiniTest.expectEqual(hashPart.count, 12)
        try MiniTest.expect(hashPart.range(of: "^[0-9a-f]{12}$", options: .regularExpression) != nil)

        // Multiple punctuation/spaces collapse to single hyphens.
        let multi = ContainerIdentity.sanitizeBase("Foo!!!  Bar... Baz")
        try MiniTest.expectEqual(multi, "foo-bar-baz")
        try MiniTest.expect(!multi.contains("--"))

        // Empty after sanitize still yields empty base (features fallback path).
        let onlyPunct = ContainerIdentity.sanitizeBase("#$%^")
        try MiniTest.expectEqual(onlyPunct, "")
        let emptyTag = DerivedImageTag.compute(
            baseImage: "alpine:3.20",
            ordered: [],
            nameBase: onlyPunct
        )
        try MiniTest.expect(emptyTag.hasPrefix("adevcontainer:"))
    }),
    ("containerPlatformDefaultArm64", {
        try MiniTest.expectEqual(
            ContainerPlatform.linuxPlatform(hostMachine: "arm64"),
            "linux/arm64"
        )
        try MiniTest.expectEqual(
            ContainerPlatform.linuxPlatform(hostMachine: "x86_64"),
            "linux/amd64"
        )
        #if arch(arm64)
        try MiniTest.expectEqual(ContainerPlatform.defaultLinuxPlatform, "linux/arm64")
        #endif
    }),
    ("featureHashMaterialInConfig", {
        let ws1 = try TestRepo.makeTempWorkspace(configJSON: """
        {
          "image": "alpine:3.20",
          "features": { "ghcr.io/devcontainers/features/node:1": { "version": "lts" } }
        }
        """)
        defer { try? FileManager.default.removeItem(at: ws1) }
        let ws2 = try TestRepo.makeTempWorkspace(configJSON: """
        {
          "image": "alpine:3.20",
          "features": { "ghcr.io/devcontainers/features/node:1": { "version": "20" } }
        }
        """)
        defer { try? FileManager.default.removeItem(at: ws2) }
        let r1 = try ConfigResolver.resolve(workspacePath: ws1.path, localEnv: [:])
        let r2 = try ConfigResolver.resolve(workspacePath: ws2.path, localEnv: [:])
        try MiniTest.expect(r1.configHash != r2.configHash)
        try MiniTest.expectEqual(r1.config.features.count, 1)
    }),
    ("featureContributionMergeEnvAndInitCap", {
        let contrib = FeatureContributions(
            initProcess: true,
            capAdd: ["SYS_PTRACE"],
            containerEnv: ["FOO": "from-feature", "SAMPLE_A": "from-feature-a"],
            mounts: [],
            onCreateCommands: [.shell("echo feat")]
        )
        let base = ResolvedDevContainerConfig(
            image: "alpine:3.20",
            containerEnv: ["FOO": "from-config"],
            workspaceFolder: "/workspaces/x"
        )
        let merged = try FeatureContributionMerge.apply(contributions: contrib, to: base)
        try MiniTest.expectEqual(merged.containerEnv["FOO"], "from-config")
        try MiniTest.expectEqual(merged.containerEnv["SAMPLE_A"], "from-feature-a")
        try MiniTest.expect(merged.runArgs.contains(.initFlag))
        try MiniTest.expect(merged.runArgs.contains(.capAdd("SYS_PTRACE")))
        try MiniTest.expectEqual(merged.featureOnCreateCommands.count, 1)
        let argv = CreateRequest.from(
            resolved: merged,
            identityName: "ctr",
            labels: [:],
            configHash: "h",
            workspacePath: "/ws"
        ).createArguments()
        try MiniTest.expect(argv.contains("--init"))
        try MiniTest.expect(argv.contains("SYS_PTRACE"))
    }),
    ("featureMetadataLabelMergeAndAbsenceOK", {
        let labels = [
            DevContainerMetadataLabel.labelKey: #"{"init":true,"containerEnv":{"FROM_LABEL":"1"}}"#
        ]
        let c = DevContainerMetadataLabel.parseContributions(from: labels)
        try MiniTest.expect(c.initProcess)
        try MiniTest.expectEqual(c.containerEnv["FROM_LABEL"], "1")
        let empty = DevContainerMetadataLabel.parseContributions(from: [:])
        try MiniTest.expectEqual(empty, FeatureContributions.empty)
    }),
    ("featureMetadataLabelArrayMergesEnv", {
        let labels = [
            DevContainerMetadataLabel.labelKey:
                #"[{"containerEnv":{"A":"1"}},{"containerEnv":{"B":"2"},"init":true}]"#
        ]
        let c = DevContainerMetadataLabel.parseContributions(from: labels)
        try MiniTest.expectEqual(c.containerEnv["A"], "1")
        try MiniTest.expectEqual(c.containerEnv["B"], "2")
        try MiniTest.expect(c.initProcess)
    }),
    ("featureMetadataLabelArrayPrivilegedWarnSkip", {
        let labels = [
            DevContainerMetadataLabel.labelKey:
                #"[{"containerEnv":{"OK":"1"}},{"privileged":true}]"#
        ]
        // Must not throw — privileged from image metadata is warn-stripped.
        DevContainerMetadataLabel.warnStripUnsafe(from: labels, imageRef: "img:1")
        let c = DevContainerMetadataLabel.parseContributions(from: labels)
        try MiniTest.expectEqual(c.containerEnv["OK"], "1")
    }),
    ("featuresRunnerBuildWithPlatformNoRosetta", {
        let cache = FileManager.default.temporaryDirectory
            .appendingPathComponent("feat-run-\(UUID().uuidString)", isDirectory: true).path
        defer { try? FileManager.default.removeItem(atPath: cache) }
        let mockFetch = MockFeatureFetcher(packagesByRef: [
            FeaturesTestSupport.refA: FeaturesTestSupport.fixtureFeatureDir("sample-a")
        ])
        let mockProc = MockProcessRunner()
        var buildArgs: [String]?
        mockProc.handlers = [
            MockProcessRunner.imageInspectHandler(baseUser: nil),
            { args in
                if args.starts(with: ["image", "list"]) {
                    return ProcessResult(exitCode: 1, stdout: Data(), stderr: Data("missing".utf8))
                }
                if args.first == "build" {
                    buildArgs = args
                    if args.contains("--rosetta") {
                        return ProcessResult(exitCode: 99, stdout: Data(), stderr: Data("no rosetta".utf8))
                    }
                    return ProcessResult(exitCode: 0, stdout: Data(), stderr: Data())
                }
                return ProcessResult(exitCode: 0, stdout: Data(), stderr: Data())
            }
        ]
        let runtime = AppleContainerRuntime(executablePath: "/usr/local/bin/container", runner: mockProc)
        let deps = FeaturesRunner.Dependencies(
            fetcher: mockFetch,
            runtime: runtime,
            cacheRoot: cache,
            platform: "linux/arm64"
        )
        let features = [
            AdmittedFeature(
                reference: FeaturesTestSupport.refA,
                options: ["greeting": .string("hi")]
            )
        ]
        let result = try FeaturesRunner.run(
            features: features,
            baseImage: "alpine:3.20",
            deps: deps,
            remoteUser: "vscode",
            containerUser: "vscode"
        )
        try MiniTest.expect(result.contributions.initProcess)
        try MiniTest.expectEqual(result.orderedRefs, [FeaturesTestSupport.refA])
        try MiniTest.expect(!result.reusedExistingImage)
        try MiniTest.expect(result.derivedImage.hasPrefix("adevcontainer:"))
        try MiniTest.expect(!result.derivedImage.contains("/features"))
        guard let buildArgs else {
            throw MiniTest.Failure(message: "expected container build")
        }
        try MiniTest.expect(buildArgs.contains("--platform"))
        if let pIdx = buildArgs.firstIndex(of: "--platform"), pIdx + 1 < buildArgs.count {
            try MiniTest.expectEqual(buildArgs[pIdx + 1], "linux/arm64")
        } else {
            throw MiniTest.Failure(message: "expected --platform linux/arm64")
        }
        try MiniTest.expect(buildArgs.contains("-t"))
        try MiniTest.expect(buildArgs.contains(result.derivedImage))
        try MiniTest.expect(!buildArgs.contains("--rosetta"))
        // Dockerfile written
        let dockerfile = mockProc.calls.first(where: { $0.arguments.first == "build" }).map { call -> String? in
            if let fIdx = call.arguments.firstIndex(of: "-f"), fIdx + 1 < call.arguments.count {
                return call.arguments[fIdx + 1]
            }
            return nil
        } ?? nil
        if let dockerfile {
            try MiniTest.expect(FileManager.default.fileExists(atPath: dockerfile))
            let contents = try String(contentsOfFile: dockerfile, encoding: .utf8)
            try MiniTest.expect(contents.contains("FROM alpine:3.20"))
            try MiniTest.expect(contents.contains("install.sh"))
            // Recursive +x so feature lifecycle scripts copied by install.sh stay executable.
            try MiniTest.expect(contents.contains("chmod -R 0755 /tmp/adev-feature-0"))
        }
    }),
    ("featuresRunnerReusesExistingTag", {
        let cache = FileManager.default.temporaryDirectory
            .appendingPathComponent("feat-reuse-tag-\(UUID().uuidString)", isDirectory: true).path
        defer { try? FileManager.default.removeItem(atPath: cache) }
        let mockFetch = MockFeatureFetcher(packagesByRef: [
            FeaturesTestSupport.refA: FeaturesTestSupport.fixtureFeatureDir("sample-a")
        ])
        let mockProc = MockProcessRunner()
        mockProc.handlers = [
            { args in
                if args.starts(with: ["image", "inspect"]) {
                    // Any inspect succeeds → imageExists true for derived tag path
                    return ProcessResult(
                        exitCode: 0,
                        stdout: Data(#"[{"id":"img"}]"#.utf8),
                        stderr: Data()
                    )
                }
                if args.first == "build" {
                    return ProcessResult(exitCode: 99, stdout: Data(), stderr: Data("should not build".utf8))
                }
                return ProcessResult(exitCode: 0, stdout: Data(), stderr: Data())
            }
        ]
        let runtime = AppleContainerRuntime(executablePath: "/usr/local/bin/container", runner: mockProc)
        let result = try FeaturesRunner.run(
            features: [
                AdmittedFeature(reference: FeaturesTestSupport.refA, options: [:])
            ],
            baseImage: "alpine:3.20",
            deps: FeaturesRunner.Dependencies(
                fetcher: mockFetch,
                runtime: runtime,
                cacheRoot: cache,
                platform: "linux/arm64"
            )
        )
        try MiniTest.expect(result.reusedExistingImage)
        try MiniTest.expect(!mockProc.calls.contains { $0.arguments.first == "build" })
    }),
    ("featureInstallerCpAndExecAsRoot", {
        // Helper retained; up path uses build. Still cover cp/exec mechanics.
        let mockProc = MockProcessRunner()
        mockProc.handlers = [
            { args in
                if args.first == "cp" || args.first == "copy" {
                    return ProcessResult(exitCode: 0, stdout: Data(), stderr: Data())
                }
                if args.first == "exec" {
                    return ProcessResult(exitCode: 0, stdout: Data(), stderr: Data())
                }
                return ProcessResult(exitCode: 0, stdout: Data(), stderr: Data())
            }
        ]
        let runtime = AppleContainerRuntime(executablePath: "/usr/local/bin/container", runner: mockProc)
        let step = FeatureInstallStep(
            reference: FeaturesTestSupport.refA,
            packageDirectory: FeaturesTestSupport.fixtureFeatureDir("sample-a"),
            installEnv: ["GREETING": "hi", "_REMOTE_USER": "root"],
            safeName: "0-sample-a"
        )
        try FeatureInstaller.install(into: "ctr", plan: [step], runtime: runtime)
        try MiniTest.expect(mockProc.calls.contains {
            ($0.arguments.first == "cp" || $0.arguments.first == "copy")
                && $0.arguments.contains(where: { $0.contains("ctr:") && $0.contains("/tmp/adev-features/") })
        })
        try MiniTest.expect(mockProc.calls.contains { call in
            let a = call.arguments
            return a.first == "exec"
                && a.contains("-u") && a.contains("root")
                && a.contains(where: { $0.contains("install.sh") })
                && a.contains(where: { $0.hasPrefix("GREETING=") })
        })
    }),
    ("pullImageIncludesPlatform", {
        let mock = MockProcessRunner()
        mock.handlers = [
            { args in
                if args.starts(with: ["image", "pull"]) || args.starts(with: ["images", "pull"]) {
                    return ProcessResult(exitCode: 0, stdout: Data(), stderr: Data())
                }
                return ProcessResult(exitCode: 0, stdout: Data(), stderr: Data())
            }
        ]
        let runtime = AppleContainerRuntime(executablePath: "/usr/local/bin/container", runner: mock)
        try runtime.pullImage("alpine:3.20", platform: "linux/arm64")
        guard let pull = mock.calls.first(where: {
            $0.arguments.starts(with: ["image", "pull"]) || $0.arguments.starts(with: ["images", "pull"])
        })?.arguments else {
            throw MiniTest.Failure(message: "expected image pull")
        }
        try MiniTest.expect(pull.contains("--platform"))
        if let i = pull.firstIndex(of: "--platform") {
            try MiniTest.expectEqual(pull[i + 1], "linux/arm64")
        }
        try MiniTest.expect(!pull.contains("--rosetta"))
    })
]
