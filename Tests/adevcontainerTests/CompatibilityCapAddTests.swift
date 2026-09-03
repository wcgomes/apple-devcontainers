import Foundation
@testable import ADevContainerLib

nonisolated(unsafe) let compatibilityCapAddTests: [(String, () throws -> Void)] = [
    ("topLevelCapAddMapsThroughTypedCreatePath", {
        let resolved = try TestRepo.resolveConfig("""
        { "image": "alpine:3.20", "capAdd": ["SYS_PTRACE", "NET_ADMIN"] }
        """)
        try MiniTest.expect(resolved.runArgs.contains(.capAdd("SYS_PTRACE")))
        try MiniTest.expect(resolved.runArgs.contains(.capAdd("NET_ADMIN")))
        let args = CreateRequest.from(
            resolved: resolved,
            identityName: "ctr",
            labels: [:],
            configHash: "h",
            workspacePath: "/ws"
        ).createArguments()
        try MiniTest.expect(args.contains("--cap-add"))
        if let idx = args.firstIndex(of: "--cap-add") {
            try MiniTest.expectEqual(args[idx + 1], "SYS_PTRACE")
        }
        try MiniTest.expectEqual(args.filter { $0 == "--cap-add" }.count, 2)
        try MiniTest.expect(!args.contains { $0.contains("SYS_PTRACE") && $0.contains(",") })
        try MiniTest.expect(!resolved.compatibilityReport.hasDegradation)
    }),
    ("topLevelAndRunArgsCapAddDeduplicateFirstSeenCaseSensitive", {
        let topLevel = try TestRepo.resolveConfig("""
        { "image": "alpine:3.20", "workspaceFolder": "/workspaces/x", "capAdd": ["SYS_PTRACE"] }
        """)
        let runArgsOnly = try TestRepo.resolveConfig("""
        { "image": "alpine:3.20", "workspaceFolder": "/workspaces/x", "runArgs": ["--cap-add=SYS_PTRACE"] }
        """)
        let both = try TestRepo.resolveConfig("""
        { "image": "alpine:3.20", "workspaceFolder": "/workspaces/x", "capAdd": ["SYS_PTRACE"], "runArgs": ["--cap-add=SYS_PTRACE"] }
        """)
        try MiniTest.expectEqual(topLevel.runArgs.filter { $0 == .capAdd("SYS_PTRACE") }.count, 1)
        try MiniTest.expectEqual(runArgsOnly.runArgs.filter { $0 == .capAdd("SYS_PTRACE") }.count, 1)
        try MiniTest.expectEqual(both.runArgs.filter { $0 == .capAdd("SYS_PTRACE") }.count, 1)
        try MiniTest.expectEqual(
            ContainerIdentity.configHash(from: topLevel.hashMaterial()),
            ContainerIdentity.configHash(from: runArgsOnly.hashMaterial())
        )
        try MiniTest.expectEqual(
            ContainerIdentity.configHash(from: topLevel.hashMaterial()),
            ContainerIdentity.configHash(from: both.hashMaterial())
        )
        let args = CreateRequest.from(
            resolved: both,
            identityName: "ctr",
            labels: [:],
            configHash: "h",
            workspacePath: "/ws"
        ).createArguments()
        try MiniTest.expectEqual(args.filter { $0 == "--cap-add" }.count, 1)
    }),
    ("capAddDedupIsCaseSensitiveFirstSeen", {
        let mixed = try TestRepo.resolveConfig("""
        { "image": "alpine:3.20", "capAdd": ["SYS_PTRACE", "sys_ptrace"] }
        """)
        try MiniTest.expectEqual(mixed.runArgs.filter { if case .capAdd = $0 { return true }; return false }.count, 2)
        let duplicateCase = try TestRepo.resolveConfig("""
        { "image": "alpine:3.20", "capAdd": ["SYS_PTRACE"], "runArgs": ["--cap-add=SYS_PTRACE"] }
        """)
        try MiniTest.expectEqual(duplicateCase.runArgs.filter { $0 == .capAdd("SYS_PTRACE") }.count, 1)
    }),
    ("emptyCapAddIsSilent", {
        let previous = StatusPrinter.onWarning
        defer { StatusPrinter.onWarning = previous }
        var warnings: [String] = []
        StatusPrinter.onWarning = { warnings.append($0) }
        let resolved = try TestRepo.resolveConfig(#"{ "image": "alpine:3.20", "capAdd": [] }"#)
        try MiniTest.expect(warnings.isEmpty)
        try MiniTest.expect(!resolved.compatibilityReport.hasDegradation)
        try MiniTest.expect(!resolved.runArgs.contains { if case .capAdd = $0 { return true }; return false })
    }),
    ("invalidCapAddBlocksBeforeCreate", {
        let invalid: [Any] = [
            "SYS_PTRACE",
            ["", "SYS_PTRACE"] as [Any],
            ["-ALL"] as [Any],
            [1] as [Any],
            [true] as [Any]
        ]
        for value in invalid {
            try MiniTest.expectThrows({
                try ConfigAdmissions.admit(["image": "alpine:3.20", "capAdd": value])
            }) { error in
                try MiniTest.expectEqual((error as! CLIError).property, "capAdd")
            }
        }
        let workspace = try TestRepo.makeTempWorkspace(
            configJSON: #"{ "image": "alpine:3.20", "capAdd": ["-ALL"] }"#
        )
        defer { try? FileManager.default.removeItem(at: workspace) }
        let mock = MockProcessRunner()
        let runtime = AppleContainerRuntime(
            executablePath: "/usr/local/bin/container",
            runner: mock
        )
        try MiniTest.expectThrows({
            _ = try UpCommand.run(
                options: UpOptions(workspacePath: workspace.path, jsonOutput: true, skipPull: true),
                runtime: runtime,
                localEnv: [:],
                isTTY: false
            )
        }) { error in
            let err = error as! CLIError
            try MiniTest.expectEqual(err.code, CLIErrorCode.unsupportedProperty)
            try MiniTest.expectEqual(err.property, "capAdd")
        }
        try MiniTest.expect(!mock.calls.contains { $0.arguments.first == "create" })
    }),
    ("featureCapabilityStillPreservesFeatureIdentity", {
        let config = try TestRepo.resolveConfig("""
        { "image": "alpine:3.20", "capAdd": ["SYS_PTRACE"] }
        """)
        let withFeature = ResolvedDevContainerConfig(
            image: config.image,
            workspaceFolder: config.workspaceFolder,
            runArgs: config.runArgs,
            features: [AdmittedFeature(reference: "ghcr.io/example/features/sample:1", options: ["mode": .string("x")])]
        )
        let merged = try FeatureContributionMerge.apply(
            contributions: FeatureContributions(capAdd: ["SYS_PTRACE"]),
            to: withFeature
        )
        try MiniTest.expectEqual(merged.runArgs.filter { $0 == .capAdd("SYS_PTRACE") }.count, 1)
        try MiniTest.expectEqual(merged.features.count, 1)
        let withFeatureHash = ContainerIdentity.configHash(from: withFeature.hashMaterial())
        let withoutFeature = ResolvedDevContainerConfig(
            image: config.image,
            workspaceFolder: config.workspaceFolder,
            runArgs: config.runArgs
        )
        let withoutHash = ContainerIdentity.configHash(from: withoutFeature.hashMaterial())
        try MiniTest.expect(withFeatureHash != withoutHash)
        let args = CreateRequest.from(
            resolved: merged,
            identityName: "ctr",
            labels: [:],
            configHash: "h",
            workspacePath: "/ws"
        ).createArguments()
        try MiniTest.expectEqual(args.filter { $0 == "--cap-add" }.count, 1)
    })
]
