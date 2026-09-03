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
        for key in ["build", "dockerFile", "dockerComposeFile"] {
            try MiniTest.expectThrows({
                try ConfigAdmissions.admit(["image": "alpine:3.20", key: ["context": "."] as [String: Any]])
            }) { error in
                let err = error as! CLIError
                try MiniTest.expectEqual(err.code, CLIErrorCode.unsupportedProperty)
                try MiniTest.expectEqual(err.property, key)
            }
        }
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
