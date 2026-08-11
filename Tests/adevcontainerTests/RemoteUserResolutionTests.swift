import Foundation
@testable import ADevContainerLib

nonisolated(unsafe) let remoteUserResolutionTests: [(String, () throws -> Void)] = [
    ("remoteUserWinsOverContainerUserAndOCI", {
        let resolved = try RemoteUserResolution.resolve(
            remoteUser: "alice",
            containerUser: "bob",
            ociUserProvider: { "carol" }
        )
        try MiniTest.expectEqual(resolved, "alice")
    }),
    ("containerUserUsedWhenRemoteUserUnset", {
        let resolved = try RemoteUserResolution.resolve(
            remoteUser: nil,
            containerUser: "bob",
            ociUserProvider: { "carol" }
        )
        try MiniTest.expectEqual(resolved, "bob")
        let emptyRemote = try RemoteUserResolution.resolve(
            remoteUser: "  ",
            containerUser: "bob",
            ociUserProvider: { "carol" }
        )
        try MiniTest.expectEqual(emptyRemote, "bob")
    }),
    ("ociUserUsedWhenBothConfigKeysUnset", {
        let resolved = try RemoteUserResolution.resolve(
            remoteUser: nil,
            containerUser: nil,
            ociUserProvider: { "node" }
        )
        try MiniTest.expectEqual(resolved, "node")
    }),
    ("rootOnlyAfterSuccessfulEmptyOCIUser", {
        let resolved = try RemoteUserResolution.resolve(
            remoteUser: nil,
            containerUser: "",
            ociUserProvider: { nil }
        )
        try MiniTest.expectEqual(resolved, "root")
        let emptyString = try RemoteUserResolution.resolve(
            remoteUser: nil,
            containerUser: nil,
            ociUserProvider: { "   " }
        )
        try MiniTest.expectEqual(emptyString, "root")
    }),
    ("inspectFailureDoesNotBecomeRoot", {
        try MiniTest.expectThrows({
            _ = try RemoteUserResolution.resolve(
                remoteUser: nil,
                containerUser: nil,
                ociUserProvider: {
                    throw CLIError(
                        code: CLIErrorCode.runtimeFailed,
                        message: "image inspect failed"
                    )
                }
            )
        }) { error in
            let err = error as! CLIError
            try MiniTest.expectEqual(err.code, CLIErrorCode.runtimeFailed)
            try MiniTest.expect(err.message.lowercased().contains("resolve") || err.message.lowercased().contains("inspect"))
            try MiniTest.expect(err.message != "root")
        }
    }),
    ("noHardcodedVscodeDefault", {
        let resolved = try RemoteUserResolution.resolve(
            remoteUser: nil,
            containerUser: nil,
            ociUserProvider: { "app" }
        )
        try MiniTest.expectEqual(resolved, "app")
        try MiniTest.expect(resolved != "vscode")
    }),
    ("trimWhitespaceOnConfigUsers", {
        let resolved = try RemoteUserResolution.resolve(
            remoteUser: "  alice  ",
            containerUser: "bob",
            ociUserProvider: { "carol" }
        )
        try MiniTest.expectEqual(resolved, "alice")
    }),
    ("createProcessUserExplicitContainerUserWins", {
        let both = ResolvedDevContainerConfig(
            image: "alpine:3.20",
            remoteUser: "alice",
            containerUser: "bob",
            workspaceFolder: "/ws"
        )
        try MiniTest.expectEqual(both.createProcessUser, "bob")
        try MiniTest.expectEqual(both.connectionUserFromConfig, "alice")
        let remoteOnly = ResolvedDevContainerConfig(
            image: "alpine:3.20",
            remoteUser: "alice",
            workspaceFolder: "/ws"
        )
        // Non-root connection user becomes create -u when containerUser unset (Apple attach).
        try MiniTest.expectEqual(remoteOnly.createProcessUser, "alice")
        try MiniTest.expectEqual(remoteOnly.connectionUserFromConfig, "alice")
        let rootConn = ResolvedDevContainerConfig(
            image: "alpine:3.20",
            remoteUser: "root",
            workspaceFolder: "/ws"
        )
        try MiniTest.expect(rootConn.createProcessUser == nil)
        let neither = ResolvedDevContainerConfig(
            image: "alpine:3.20",
            workspaceFolder: "/ws"
        )
        try MiniTest.expect(neither.createProcessUser == nil)
        try MiniTest.expect(neither.connectionUserFromConfig == nil)
        // Pure helper
        try MiniTest.expectEqual(
            RemoteUserResolution.createProcessUser(containerUser: "bob", connectionUser: "alice"),
            "bob"
        )
        try MiniTest.expectEqual(
            RemoteUserResolution.createProcessUser(containerUser: nil, connectionUser: "vscode"),
            "vscode"
        )
        try MiniTest.expect(
            RemoteUserResolution.createProcessUser(containerUser: nil, connectionUser: "root") == nil
        )
        try MiniTest.expect(
            RemoteUserResolution.createProcessUser(containerUser: nil, connectionUser: nil) == nil
        )
    }),
    ("createRequestUserFromContainerUserOrNonRootConnection", {
        let remoteOnly = ResolvedDevContainerConfig(
            image: "alpine:3.20",
            remoteUser: "alice",
            workspaceFolder: "/workspaces/app"
        )
        let req1 = CreateRequest.from(
            resolved: remoteOnly,
            identityName: "ctr",
            labels: [:],
            configHash: "h",
            workspacePath: "/ws"
        )
        try MiniTest.expectEqual(req1.user, "alice")
        let args1 = req1.createArguments()
        try MiniTest.expect(args1.contains("-u"))
        if let i = args1.firstIndex(of: "-u") {
            try MiniTest.expectEqual(args1[i + 1], "alice")
        }

        let containerOnly = ResolvedDevContainerConfig(
            image: "alpine:3.20",
            containerUser: "bob",
            workspaceFolder: "/workspaces/app"
        )
        let req2 = CreateRequest.from(
            resolved: containerOnly,
            identityName: "ctr",
            labels: [:],
            configHash: "h",
            workspacePath: "/ws"
        )
        try MiniTest.expectEqual(req2.user, "bob")
        let args2 = req2.createArguments()
        try MiniTest.expect(args2.contains("-u"))
        if let i = args2.firstIndex(of: "-u") {
            try MiniTest.expectEqual(args2[i + 1], "bob")
        }

        let both = ResolvedDevContainerConfig(
            image: "alpine:3.20",
            remoteUser: "alice",
            containerUser: "bob",
            workspaceFolder: "/workspaces/app"
        )
        let req3 = CreateRequest.from(
            resolved: both,
            identityName: "ctr",
            labels: [:],
            configHash: "h",
            workspacePath: "/ws"
        )
        try MiniTest.expectEqual(req3.user, "bob")
        let args3 = req3.createArguments()
        if let i = args3.firstIndex(of: "-u") {
            try MiniTest.expectEqual(args3[i + 1], "bob")
        }

        let vol = CreateRequest.fromVolumeMode(
            resolved: remoteOnly,
            identityName: "ctr",
            labels: [:],
            configHash: "h",
            workspaceVolumeName: "vol"
        )
        try MiniTest.expectEqual(vol.user, "alice")

        let rootOnly = ResolvedDevContainerConfig(
            image: "alpine:3.20",
            remoteUser: "root",
            workspaceFolder: "/workspaces/app"
        )
        let reqRoot = CreateRequest.from(
            resolved: rootOnly,
            identityName: "ctr",
            labels: [:],
            configHash: "h",
            workspacePath: "/ws"
        )
        try MiniTest.expect(reqRoot.user == nil)
        try MiniTest.expect(!reqRoot.createArguments().contains("-u"))
    }),
    ("lifecycleUsesConnectionUserNotContainerUser", {
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
        // After create-path resolution, remoteUser is stamped to connection user.
        let config = ResolvedDevContainerConfig(
            image: "alpine:3.20",
            remoteUser: "alice",
            containerUser: "bob",
            workspaceFolder: "/workspaces/app",
            postCreateCommand: .shell("true")
        )
        try LifecycleRunner.runIfPresent(
            property: "postCreateCommand",
            command: config.postCreateCommand,
            containerId: "ctr",
            config: config,
            runtime: runtime,
            failurePolicy: .failKeepContainer
        )
        let exec = mock.calls.first { $0.arguments.first == "exec" }!
        try MiniTest.expect(exec.arguments.contains("-u"))
        if let i = exec.arguments.firstIndex(of: "-u") {
            try MiniTest.expectEqual(exec.arguments[i + 1], "alice")
        }
        try MiniTest.expect(!exec.arguments.contains("bob") || exec.arguments.contains("alice"))
    }),
    ("featureOptionsUserInstallNoHardcodedVscode", {
        let env = FeatureOptions.userInstallEnvironment(remoteUser: nil, containerUser: nil)
        try MiniTest.expectEqual(env["_REMOTE_USER"], "root")
        try MiniTest.expectEqual(env["_CONTAINER_USER"], "root")
        try MiniTest.expect(env["_REMOTE_USER"] != "vscode")
    }),
    ("featureOptionsUserInstallUsesBaseUserWhenConfigEmpty", {
        let env = FeatureOptions.userInstallEnvironment(
            remoteUser: nil,
            containerUser: nil,
            baseUser: "node"
        )
        try MiniTest.expectEqual(env["_REMOTE_USER"], "node")
        try MiniTest.expectEqual(env["_CONTAINER_USER"], "node")
        try MiniTest.expectEqual(env["_REMOTE_USER_HOME"], "/home/node")
        try MiniTest.expect(env["_REMOTE_USER"] != "vscode")
        // Config still wins over base USER
        let withConfig = FeatureOptions.userInstallEnvironment(
            remoteUser: "alice",
            containerUser: nil,
            baseUser: "node"
        )
        try MiniTest.expectEqual(withConfig["_REMOTE_USER"], "alice")
        try MiniTest.expectEqual(withConfig["_CONTAINER_USER"], "alice")
    }),
    ("metadataRemoteUserWhenConfigEmpty", {
        let resolved = try RemoteUserResolution.resolve(
            remoteUser: nil,
            containerUser: nil,
            metadataRemoteUser: "vscode",
            metadataContainerUser: nil,
            ociUserProvider: { "root" }
        )
        try MiniTest.expectEqual(resolved, "vscode")
    }),
    ("metadataLastNonEmptyFragmentWins", {
        let labels = [
            DevContainerMetadataLabel.labelKey:
                #"[{"remoteUser":"first"},{"remoteUser":"second"},{"containerUser":"c1"},{"containerUser":"c2"}]"#
        ]
        let users = DevContainerMetadataLabel.parseUsers(from: labels)
        try MiniTest.expectEqual(users.remoteUser, "second")
        try MiniTest.expectEqual(users.containerUser, "c2")
    }),
    ("localConfigWinsOverMetadata", {
        let resolved = try RemoteUserResolution.resolve(
            remoteUser: "alice",
            containerUser: nil,
            metadataRemoteUser: "vscode",
            metadataContainerUser: nil,
            ociUserProvider: { "root" }
        )
        try MiniTest.expectEqual(resolved, "alice")
        let containerOnly = try RemoteUserResolution.resolve(
            remoteUser: nil,
            containerUser: "bob",
            metadataRemoteUser: "vscode",
            metadataContainerUser: nil,
            ociUserProvider: { "root" }
        )
        // Local containerUser wins over metadata remoteUser
        try MiniTest.expectEqual(containerOnly, "bob")
        let neitherLocal = try RemoteUserResolution.resolve(
            remoteUser: nil,
            containerUser: nil,
            metadataRemoteUser: nil,
            metadataContainerUser: "meta-c",
            ociUserProvider: { "root" }
        )
        try MiniTest.expectEqual(neitherLocal, "meta-c")
    }),
    ("officialBaseImageMetadataRemoteUserPattern", {
        // OCI USER=root + metadata remoteUser=vscode → connection vscode; create -u vscode
        // (Apple attach uses container default user — no exec -u)
        let connection = try RemoteUserResolution.resolve(
            remoteUser: nil,
            containerUser: nil,
            metadataRemoteUser: "vscode",
            metadataContainerUser: nil,
            ociUserProvider: { "root" }
        )
        try MiniTest.expectEqual(connection, "vscode")
        var config = ResolvedDevContainerConfig(
            image: "mcr.microsoft.com/devcontainers/base:ubuntu",
            workspaceFolder: "/workspaces/app"
        )
        config = RemoteUserResolution.applyingConnectionUser(connection, to: config)
        try MiniTest.expectEqual(config.createProcessUser, "vscode")
        let req = CreateRequest.from(
            resolved: config,
            identityName: "ctr",
            labels: [ContainerIdentity.labelRemoteUser: connection],
            configHash: "h",
            workspacePath: "/ws"
        )
        try MiniTest.expectEqual(req.user, "vscode")
        let args = req.createArguments()
        try MiniTest.expect(args.contains("-u"))
        if let i = args.firstIndex(of: "-u") {
            try MiniTest.expectEqual(args[i + 1], "vscode")
        }
        try MiniTest.expectEqual(req.labels[ContainerIdentity.labelRemoteUser], "vscode")
    })
]
