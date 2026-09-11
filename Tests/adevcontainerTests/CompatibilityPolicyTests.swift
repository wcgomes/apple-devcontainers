import Foundation
@testable import ADevContainerLib

nonisolated(unsafe) let compatibilityPolicyTests: [(String, () throws -> Void)] = [
    ("schemaMetadataIsSilentAndHashNeutral", {
        let previous = StatusPrinter.onWarning
        defer { StatusPrinter.onWarning = previous }
        var warnings: [String] = []
        StatusPrinter.onWarning = { warnings.append($0) }
        let omitted = try TestRepo.resolveConfig(#"{ "image": "alpine:3.20", "workspaceFolder": "/workspaces/x" }"#)
        let withSchema = try TestRepo.resolveConfig("""
        {
          "image": "alpine:3.20",
          "workspaceFolder": "/workspaces/x",
          "$schema": "https://example.invalid/devcontainer.schema.json"
        }
        """)
        try MiniTest.expect(warnings.isEmpty)
        try MiniTest.expect(!withSchema.compatibilityReport.hasDegradation)
        try MiniTest.expectEqual(
            ContainerIdentity.configHash(from: omitted.hashMaterial()),
            ContainerIdentity.configHash(from: withSchema.hashMaterial())
        )
        try ConfigAdmissions.admit([
            "image": "alpine:3.20",
            "$schema": "https://example.invalid/devcontainer.schema.json"
        ])
    }),
    ("harmlessFalseAndEmptyFormsAreSilent", {
        let previous = StatusPrinter.onWarning
        defer { StatusPrinter.onWarning = previous }
        var warnings: [String] = []
        StatusPrinter.onWarning = { warnings.append($0) }
        let omitted = try TestRepo.resolveConfig(#"{ "image": "alpine:3.20", "workspaceFolder": "/workspaces/x" }"#)
        let harmless = try TestRepo.resolveConfig("""
        {
          "image": "alpine:3.20",
          "workspaceFolder": "/workspaces/x",
          "privileged": false,
          "otherPortsAttributes": {},
          "secrets": {},
          "overrideCommand": true
        }
        """)
        try MiniTest.expect(warnings.isEmpty)
        try MiniTest.expect(!harmless.compatibilityReport.hasDegradation)
        try MiniTest.expectEqual(
            ContainerIdentity.configHash(from: omitted.hashMaterial()),
            ContainerIdentity.configHash(from: harmless.hashMaterial())
        )
    }),
    ("nonEmptyOtherPortsAttributesDegradesVisibly", {
        let previous = StatusPrinter.onWarning
        defer { StatusPrinter.onWarning = previous }
        var warnings: [String] = []
        StatusPrinter.onWarning = { warnings.append($0) }
        let omitted = try TestRepo.resolveConfig(#"{ "image": "alpine:3.20", "workspaceFolder": "/workspaces/x" }"#)
        let noisy = try TestRepo.resolveConfig("""
        {
          "image": "alpine:3.20",
          "workspaceFolder": "/workspaces/x",
          "otherPortsAttributes": { "onAutoForward": "ignore" }
        }
        """)
        try MiniTest.expectEqual(warnings.count, 1)
        try MiniTest.expect(warnings[0].contains(CompatibilityCode.configOtherPortsAttributesIgnored))
        try MiniTest.expect(warnings[0].contains("otherPortsAttributes"))
        try MiniTest.expect(warnings[0].contains("ignored"))
        try MiniTest.expect(warnings[0].lowercased().contains("not applied") || warnings[0].contains("port"))
        try MiniTest.expectEqual(noisy.compatibilityReport.issues.count, 1)
        try MiniTest.expectEqual(
            noisy.compatibilityReport.issues[0].code,
            CompatibilityCode.configOtherPortsAttributesIgnored
        )
        try MiniTest.expectEqual(
            ContainerIdentity.configHash(from: omitted.hashMaterial()),
            ContainerIdentity.configHash(from: noisy.hashMaterial())
        )
    }),
    ("secretsRecommendationsAreNotExposed", {
        let previous = StatusPrinter.onWarning
        defer { StatusPrinter.onWarning = previous }
        var warnings: [String] = []
        StatusPrinter.onWarning = { warnings.append($0) }
        let resolved = try TestRepo.resolveConfig("""
        {
          "image": "alpine:3.20",
          "secrets": {
            "ghToken": { "description": "super-secret-value" }
          }
        }
        """)
        try MiniTest.expectEqual(warnings.count, 1)
        try MiniTest.expect(warnings[0].contains(CompatibilityCode.configSecretsIgnored))
        try MiniTest.expect(!warnings[0].contains("ghToken"))
        try MiniTest.expect(!warnings[0].contains("super-secret-value"))
        try MiniTest.expectEqual(
            resolved.compatibilityReport.issues[0].disposition,
            CompatibilityDisposition.ignored
        )
        try MiniTest.expectThrows({
            try resolved.compatibilityReport.enforce(mode: .strict)
        }) { error in
            let err = error as! CLIError
            try MiniTest.expectEqual(err.code, CLIErrorCode.compatibilityDegraded)
            try MiniTest.expect(!err.message.contains("ghToken"))
            try MiniTest.expect(!err.message.contains("super-secret-value"))
            try MiniTest.expect(!(err.hint?.contains("ghToken") ?? false))
        }
    }),
    ("privilegedTrueIsWarnStripped", {
        let previous = StatusPrinter.onWarning
        defer { StatusPrinter.onWarning = previous }
        var warnings: [String] = []
        StatusPrinter.onWarning = { warnings.append($0) }
        let resolved = try TestRepo.resolveConfig(#"{ "image": "alpine:3.20", "privileged": true }"#)
        try MiniTest.expectEqual(warnings.count, 1)
        try MiniTest.expect(warnings[0].contains(CompatibilityCode.configPrivilegedIgnored))
        try MiniTest.expect(warnings[0].contains("privileged"))
        try MiniTest.expect(!resolved.runArgs.contains { $0.hashEncoding.contains("privileged") })
        let args = CreateRequest.from(
            resolved: resolved,
            identityName: "ctr",
            labels: [:],
            configHash: "h",
            workspacePath: "/ws"
        ).createArguments()
        try MiniTest.expect(!args.contains { $0.contains("privileged") })
        try MiniTest.expect(!args.contains { $0.lowercased().contains("virtualiz") })
    }),
    ("overrideCommandFalseRemainsBlocking", {
        try MiniTest.expectThrows({
            try ConfigAdmissions.admit([
                "image": "alpine:3.20",
                "overrideCommand": false
            ])
        }) { error in
            let err = error as! CLIError
            try MiniTest.expectEqual(err.code, CLIErrorCode.unsupportedProperty)
            try MiniTest.expectEqual(err.property, "overrideCommand")
            try MiniTest.expect(err.message.lowercased().contains("image command") || err.message.contains("preserve"))
        }
    }),
    ("invalidMetadataShapesRemainBlocking", {
        let cases: [(String, Any)] = [
            ("$schema", 1),
            ("otherPortsAttributes", "nope"),
            ("secrets", "nope"),
            ("secrets", ["token": "not-an-object"] as [String: Any]),
            ("privileged", "true"),
            ("overrideCommand", 1)
        ]
        for (property, value) in cases {
            try MiniTest.expectThrows({
                try ConfigAdmissions.admit(["image": "alpine:3.20", property: value])
            }) { error in
                try MiniTest.expectEqual((error as! CLIError).property, property, property)
            }
        }
    }),
    ("unknownTopLevelPropertyRemainsBlocked", {
        try MiniTest.expectThrows({
            try ConfigAdmissions.admit(["image": "alpine:3.20", "notARealProperty": true])
        }) { error in
            let err = error as! CLIError
            try MiniTest.expectEqual(err.code, CLIErrorCode.unsupportedProperty)
            try MiniTest.expectEqual(err.property, "notARealProperty")
        }
    }),
    ("unrepresentableSourceSelectorRemainsBlocked", {
        for key in ["dockerFile", "dockerfile", "context", "dockerComposeFile"] {
            try MiniTest.expectThrows({
                try ConfigAdmissions.admit(["image": "alpine:3.20", key: ["context": "."] as [String: Any]])
            }) { error in
                let err = error as! CLIError
                try MiniTest.expectEqual(err.code, CLIErrorCode.unsupportedProperty)
                try MiniTest.expectEqual(err.property, key)
            }
        }
        try MiniTest.expectThrows({
            try ConfigAdmissions.admit([
                "dockerComposeFile": "compose.yaml",
                "build": ["dockerfile": "Dockerfile"] as [String: Any]
            ])
        }) { error in
            try MiniTest.expectEqual((error as! CLIError).property, "dockerComposeFile")
        }
    }),
    ("nestedBuildWithoutImageAdmits", {
        try ConfigAdmissions.admit([
            "build": ["dockerfile": "Dockerfile"] as [String: Any]
        ])
        let ws = try TestRepo.makeTempWorkspace(configJSON: """
        { "build": { "dockerfile": "Dockerfile", "target": "dev" } }
        """)
        defer { try? FileManager.default.removeItem(at: ws) }
        try TestRepo.writeFile("FROM alpine:3.20\n", relativePath: ".devcontainer/Dockerfile", in: ws)
        let resolved = try ConfigResolver.resolve(workspacePath: ws.path, localEnv: [:])
        let build = resolved.config.dockerfileBuild
        try MiniTest.expect(build != nil, "resolved model must carry nested build")
        try MiniTest.expectEqual(build?.dockerfile, "Dockerfile")
        try MiniTest.expectEqual(build?.context, ".")
        try MiniTest.expectEqual(build?.target, "dev")
        try MiniTest.expectEqual(build?.args ?? [:], [:])
        try MiniTest.expect(resolved.config.image.isEmpty)
    }),
    ("imageAndNestedBuildTogetherFail", {
        try MiniTest.expectThrows({
            try ConfigAdmissions.admit([
                "image": "alpine:3.20",
                "build": ["dockerfile": "Dockerfile"] as [String: Any]
            ])
        }) { error in
            let err = error as! CLIError
            try MiniTest.expectEqual(err.property, "build")
            try MiniTest.expect(err.message.lowercased().contains("image") || err.message.contains("both"))
        }
    }),
    ("neitherImageNorNestedBuildFails", {
        try MiniTest.expectThrows({
            try ConfigAdmissions.admit(["name": "empty"] as [String: Any])
        }) { error in
            let err = error as! CLIError
            try MiniTest.expect(err.property == "image" || err.property == "build")
        }
    }),
    ("topLevelDockerfileSelectorsRemainBlocked", {
        for key in ["dockerFile", "dockerfile", "context"] {
            try MiniTest.expectThrows({
                try ConfigAdmissions.admit([
                    "build": ["dockerfile": "Dockerfile"] as [String: Any],
                    key: key == "context" ? "." : "Dockerfile"
                ])
            }) { error in
                let err = error as! CLIError
                try MiniTest.expectEqual(err.code, CLIErrorCode.unsupportedProperty)
                try MiniTest.expectEqual(err.property, key)
            }
        }
    }),
    ("unknownNestedBuildKeyFailsClosed", {
        for key in ["options", "cacheFrom", "cacheTo", "argsFrom"] {
            try MiniTest.expectThrows({
                try ConfigAdmissions.admit([
                    "build": [
                        "dockerfile": "Dockerfile",
                        key: "nope"
                    ] as [String: Any]
                ])
            }) { error in
                let err = error as! CLIError
                try MiniTest.expectEqual(err.property, "build")
                try MiniTest.expect(err.message.contains(key), "unknown key \(key) must be named")
            }
        }
    }),
    ("missingBuildDockerfileFails", {
        try MiniTest.expectThrows({
            try ConfigAdmissions.admit(["build": ["context": "."] as [String: Any]])
        }) { error in
            try MiniTest.expectEqual((error as! CLIError).property, "build")
        }
        try MiniTest.expectThrows({
            try ConfigAdmissions.admit(["build": ["dockerfile": ""] as [String: Any]])
        }) { error in
            try MiniTest.expectEqual((error as! CLIError).property, "build")
        }
        try MiniTest.expectThrows({
            try ConfigAdmissions.admit(["build": "Dockerfile"])
        }) { error in
            try MiniTest.expectEqual((error as! CLIError).property, "build")
        }
    }),
    ("omittedBuildContextDefaultsToDot", {
        let ws = try TestRepo.makeTempWorkspace(configJSON: """
        { "build": { "dockerfile": "Dockerfile" } }
        """)
        defer { try? FileManager.default.removeItem(at: ws) }
        try TestRepo.writeFile("FROM alpine:3.20\n", relativePath: ".devcontainer/Dockerfile", in: ws)
        let resolved = try ConfigResolver.resolve(workspacePath: ws.path, localEnv: [:])
        try MiniTest.expectEqual(resolved.config.dockerfileBuild?.context, ".")
    }),
    ("nonStringBuildArgsOrTargetFailsClosed", {
        try MiniTest.expectThrows({
            try ConfigAdmissions.admit([
                "build": [
                    "dockerfile": "Dockerfile",
                    "args": ["FOO": 1] as [String: Any]
                ] as [String: Any]
            ])
        }) { error in
            try MiniTest.expectEqual((error as! CLIError).property, "build")
        }
        try MiniTest.expectThrows({
            try ConfigAdmissions.admit([
                "build": [
                    "dockerfile": "Dockerfile",
                    "target": 1
                ] as [String: Any]
            ])
        }) { error in
            try MiniTest.expectEqual((error as! CLIError).property, "build")
        }
        try MiniTest.expectThrows({
            try ConfigAdmissions.admit([
                "build": [
                    "dockerfile": "Dockerfile",
                    "args": ["a", "b"] as [Any]
                ] as [String: Any]
            ])
        }) { error in
            try MiniTest.expectEqual((error as! CLIError).property, "build")
        }
    }),
    ("buildArgsReceiveSubstitution", {
        let ws = try TestRepo.makeTempWorkspace(configJSON: """
        {
          "build": {
            "dockerfile": "Dockerfile",
            "args": {
              "WS": "${localWorkspaceFolder}",
              "ENV": "${localEnv:HELLO}"
            }
          }
        }
        """)
        defer { try? FileManager.default.removeItem(at: ws) }
        try TestRepo.writeFile("FROM alpine:3.20\n", relativePath: ".devcontainer/Dockerfile", in: ws)
        let resolved = try ConfigResolver.resolve(
            workspacePath: ws.path,
            localEnv: ["HELLO": "world"]
        )
        try MiniTest.expectEqual(resolved.config.dockerfileBuild?.args["WS"], ws.path)
        try MiniTest.expectEqual(resolved.config.dockerfileBuild?.args["ENV"], "world")
    }),
    ("nestedBuildIsOnTheSupportedSurface", {
        try ConfigAdmissions.admit([
            "name": "df",
            "build": [
                "dockerfile": "Dockerfile",
                "context": ".",
                "args": ["A": "b"] as [String: Any],
                "target": "dev"
            ] as [String: Any],
            "remoteUser": "root"
        ])
    }),
    ("dockerfileReferenceAdmits", {
        let root = TestRepo.root().appendingPathComponent("references/dockerfile")
        let configPath = root.appendingPathComponent(".devcontainer.json").path
        let raw = try JSONCParser.loadFile(at: configPath)
        try MiniTest.expect(raw["image"] == nil)
        try MiniTest.expect(raw["dockerComposeFile"] == nil)
        try MiniTest.expect(raw["privileged"] == nil)
        try ConfigAdmissions.admit(raw)
        let resolved = try ConfigResolver.resolve(workspacePath: root.path, localEnv: [:])
        try MiniTest.expect(resolved.config.dockerfileBuild != nil)
        try MiniTest.expectEqual(resolved.config.dockerfileBuild?.dockerfile, "Dockerfile")
        try MiniTest.expect(resolved.config.image.isEmpty)
    }),
    ("materialWorkspaceOrProcessMismatchRemainsBlocked", {
        try MiniTest.expectThrows({
            try ConfigAdmissions.admit(["image": "alpine:3.20", "workspaceMount": "source=/a,target=/b"])
        }) { error in
            try MiniTest.expectEqual((error as! CLIError).property, "workspaceMount")
        }
        try MiniTest.expectThrows({
            try ConfigAdmissions.admit(["image": "alpine:3.20", "remoteEnv": ["A": "1"] as [String: Any]])
        }) { error in
            try MiniTest.expectEqual((error as! CLIError).property, "remoteEnv")
        }
    }),
    ("expandedLowRiskPropertySurfaceAdmits", {
        let previous = StatusPrinter.onWarning
        defer { StatusPrinter.onWarning = previous }
        var warnings: [String] = []
        StatusPrinter.onWarning = { warnings.append($0) }
        let raw = try JSONCParser.loadFile(
            at: TestRepo.root().appendingPathComponent("Tests/Fixtures/tolerant-compatibility.json").path
        )
        try ConfigAdmissions.admit(raw)
        let resolved = try TestRepo.resolveConfig(
            try String(
                contentsOf: TestRepo.root().appendingPathComponent("Tests/Fixtures/tolerant-compatibility.json"),
                encoding: .utf8
            )
        )
        try MiniTest.expect(resolved.runArgs.contains(.capAdd("SYS_PTRACE")))
        try MiniTest.expect(resolved.runArgs.contains(.capAdd("NET_ADMIN")))
        try MiniTest.expect(!resolved.runArgs.contains { $0.hashEncoding.contains("privileged") })
        try MiniTest.expect(warnings.contains { $0.contains(CompatibilityCode.configOtherPortsAttributesIgnored) })
        try MiniTest.expect(warnings.contains { $0.contains(CompatibilityCode.configSecretsIgnored) })
        try MiniTest.expect(warnings.contains { $0.contains(CompatibilityCode.configPrivilegedIgnored) })
        try MiniTest.expect(!warnings.contains { $0.contains("ghToken") })
        try MiniTest.expect(!warnings.contains { $0.contains("$schema") })
        try MiniTest.expect(!warnings.contains { $0.contains("overrideCommand") })
    }),
    ("defaultModeReportsKnownDegradationOnce", {
        let previous = StatusPrinter.onWarning
        defer { StatusPrinter.onWarning = previous }
        var warnings: [String] = []
        StatusPrinter.onWarning = { warnings.append($0) }
        let ws = try TestRepo.makeTempWorkspace(configJSON: """
        { "image": "alpine:3.20", "privileged": true }
        """)
        defer { try? FileManager.default.removeItem(at: ws) }
        _ = try ConfigResolver.resolve(workspacePath: ws.path, localEnv: [:])
        let privileged = warnings.filter { $0.contains(CompatibilityCode.configPrivilegedIgnored) }
        try MiniTest.expectEqual(privileged.count, 1)
        try MiniTest.expect(privileged[0].contains("privileged"))
        try MiniTest.expect(privileged[0].contains("ignored"))
    })
]
