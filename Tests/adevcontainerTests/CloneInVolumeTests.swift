import Foundation
@testable import ADevContainerLib

// MARK: - Mock GitClient

final class MockGitClient: GitClient, @unchecked Sendable {
    var requireGitResult: Result<String, Error> = .success("/usr/bin/git")
    var fetchConfigHandler: ((String, String) throws -> Void)?
    var fullCloneHandler: ((String, String) throws -> Void)?
    var fetchConfigCalls: [(url: String, directory: String)] = []
    var fullCloneCalls: [(url: String, directory: String)] = []
    var resolveAuthorIdentityResult = GitAuthorIdentity(name: "Test User", email: "test@example.com")
    var resolveAuthorIdentityCalls: [String] = []
    /// When set, write this config JSON into the fetch directory (nested path).
    var configJSONToWrite: String?
    var configRelativePath: String = ConfigDiscovery.nestedRelativePath
    var writeRootConfigOnly: Bool = false
    var writeNoConfig: Bool = false

    func requireGit() throws -> String {
        switch requireGitResult {
        case .success(let p): return p
        case .failure(let e): throw e
        }
    }

    func fetchConfig(url: String, into directory: String) throws {
        fetchConfigCalls.append((url, directory))
        if let handler = fetchConfigHandler {
            try handler(url, directory)
            return
        }
        try FileManager.default.createDirectory(
            atPath: directory,
            withIntermediateDirectories: true
        )
        if writeNoConfig { return }
        if writeRootConfigOnly {
            let root = (directory as NSString).appendingPathComponent(".devcontainer.json")
            let json = configJSONToWrite ?? #"{ "image": "alpine:3.20" }"#
            try json.write(toFile: root, atomically: true, encoding: .utf8)
            return
        }
        let json = configJSONToWrite ?? #"{ "image": "alpine:3.20" }"#
        if configRelativePath == ConfigDiscovery.rootRelativePath {
            let root = (directory as NSString).appendingPathComponent(".devcontainer.json")
            try json.write(toFile: root, atomically: true, encoding: .utf8)
        } else {
            let nestedDir = (directory as NSString).appendingPathComponent(".devcontainer")
            try FileManager.default.createDirectory(
                atPath: nestedDir,
                withIntermediateDirectories: true
            )
            let nested = (nestedDir as NSString).appendingPathComponent("devcontainer.json")
            try json.write(toFile: nested, atomically: true, encoding: .utf8)
        }
    }

    func fullClone(url: String, into directory: String) throws {
        fullCloneCalls.append((url, directory))
        if let handler = fullCloneHandler {
            try handler(url, directory)
            return
        }
        try FileManager.default.createDirectory(
            atPath: directory,
            withIntermediateDirectories: true
        )
    }

    func resolveAuthorIdentity(in directory: String) -> GitAuthorIdentity {
        resolveAuthorIdentityCalls.append(directory)
        return resolveAuthorIdentityResult
    }
}

// MARK: - Mock Git credentials

final class MockGitCredential: GitCredentialProviding, @unchecked Sendable {
    var fillResult: Result<GitHTTPSCredentials?, Error> = .success(
        GitHTTPSCredentials(username: "user", password: "secret-token")
    )
    var fillCalls: [String] = []

    func fillHTTPS(url: String) throws -> GitHTTPSCredentials? {
        fillCalls.append(url)
        switch fillResult {
        case .success(let c): return c
        case .failure(let e): throw e
        }
    }
}

/// Shared mock handlers for clone create/start/exec happy path (in-container clone).
enum CloneRuntimeMock {
    /// - Parameters:
    ///   - cloneExecSucceeds: in-container `sh -c` clone script
    ///   - verifyGitExists: `test -e …/.git`
    ///   - hookExecSucceeds: lifecycle `sh -lc`
    static func handlers(
        cloneExecSucceeds: Bool = true,
        verifyGitExists: Bool = true,
        hookExecSucceeds: Bool = true,
        onCreate: (([String]) -> Void)? = nil,
        baseUser: String? = nil
    ) -> [([String]) -> ProcessResult?] {
        [
            MockProcessRunner.imageInspectHandler(baseUser: baseUser),
            { args in
                onCreate?(args)
                if args.starts(with: ["list"]) || args.starts(with: ["volume", "list"]) {
                    let data = try! JSONSerialization.data(withJSONObject: [] as [Any])
                    return ProcessResult(exitCode: 0, stdout: data, stderr: Data())
                }
                if args.starts(with: ["image", "list"]) {
                    return ProcessResult(exitCode: 1, stdout: Data(), stderr: Data("missing".utf8))
                }
                if args.first == "build" {
                    return ProcessResult(exitCode: 0, stdout: Data(), stderr: Data())
                }
                if args.starts(with: ["volume", "create"]) || args.starts(with: ["volume", "delete"]) {
                    return ProcessResult(exitCode: 0, stdout: Data(), stderr: Data())
                }
                if args.first == "create" {
                    return ProcessResult(exitCode: 0, stdout: Data("ctr\n".utf8), stderr: Data())
                }
                if args.first == "start" || args.first == "delete" {
                    return ProcessResult(exitCode: 0, stdout: Data(), stderr: Data())
                }
                if args.first == "exec" {
                    if args.contains("test") && args.contains("-e") {
                        return ProcessResult(
                            exitCode: verifyGitExists ? 0 : 1,
                            stdout: Data(),
                            stderr: Data()
                        )
                    }
                    // In-container clone uses `sh -c`; hooks use `sh -lc`.
                    if args.contains("-lc") {
                        return ProcessResult(
                            exitCode: hookExecSucceeds ? 0 : 1,
                            stdout: Data(),
                            stderr: hookExecSucceeds ? Data() : Data("hook failed".utf8)
                        )
                    }
                    if args.contains("-c") {
                        return ProcessResult(
                            exitCode: cloneExecSucceeds ? 0 : 1,
                            stdout: Data(),
                            stderr: cloneExecSucceeds ? Data() : Data("clone failed".utf8)
                        )
                    }
                    return ProcessResult(exitCode: 0, stdout: Data(), stderr: Data())
                }
                return nil
            }
        ]
    }
}

// MARK: - Identity / CreateRequest unit tests

nonisolated(unsafe) let cloneIdentityTests: [(String, () throws -> Void)] = [
    ("volumeModeHashFromNormalizedURLAndConfigRelPath", {
        let a = ContainerIdentity.volumeModeIdentity(
            gitURL: "https://github.com/org/sample-repo.git",
            configRelativePath: ".devcontainer/devcontainer.json",
            configName: nil
        )
        let b = ContainerIdentity.volumeModeIdentity(
            gitURL: "https://github.com/org/sample-repo",
            configRelativePath: ".devcontainer/devcontainer.json",
            configName: nil
        )
        try MiniTest.expectEqual(a.hash12, b.hash12)
        try MiniTest.expectEqual(a.containerName, b.containerName)
        try MiniTest.expectEqual(a.workspaceVolumeName, b.workspaceVolumeName)
        try MiniTest.expectEqual(a.hash12.count, 12)
    }),
    ("volumeModeStableAcrossTempPathIrrelevance", {
        // Temp paths are not hash material — same URL+relpath always same identity
        let id1 = ContainerIdentity.volumeModeIdentity(
            gitURL: "https://github.com/acme/app.git",
            configRelativePath: ".devcontainer/devcontainer.json",
            configName: "MyApp"
        )
        let id2 = ContainerIdentity.volumeModeIdentity(
            gitURL: "https://github.com/acme/app.git",
            configRelativePath: ".devcontainer/devcontainer.json",
            configName: "MyApp"
        )
        try MiniTest.expectEqual(id1.hash12, id2.hash12)
        try MiniTest.expectEqual(id1.containerName, id2.containerName)
        try MiniTest.expectEqual(id1.workspaceVolumeName, id2.workspaceVolumeName)
        try MiniTest.expectEqual(id1.containerName, "myapp")
        try MiniTest.expect(!id1.containerName.hasPrefix("adev-"))
        try MiniTest.expect(id1.workspaceVolumeName.hasSuffix("-ws"))
        try MiniTest.expect(id1.workspaceVolumeName.contains(id1.hash12))
    }),
    ("volumeNameIncludesContainerIdentity", {
        let id = ContainerIdentity.volumeModeIdentity(
            gitURL: "https://example.com/r/myapp.git",
            configRelativePath: ".devcontainer/devcontainer.json",
            configName: "myapp"
        )
        try MiniTest.expectEqual(id.containerName, "myapp")
        try MiniTest.expectEqual(id.base, "myapp")
        try MiniTest.expectEqual(id.workspaceVolumeName, "adev-myapp-\(id.hash12)-ws")
        try MiniTest.expect(id.containerName.count <= 63)
        try MiniTest.expect(id.workspaceVolumeName.count <= 63)
        try MiniTest.expect(id.workspaceVolumeName.hasSuffix("-ws"))
        try MiniTest.expect(id.workspaceVolumeName.contains(id.hash12))
        try MiniTest.expect(!id.containerName.hasPrefix("adev-"))
        try MiniTest.expect(!id.workspaceVolumeName.hasPrefix("myapp"))
    }),
    ("humanBaseFromRepoBasenameWhenNameOmitted", {
        let id = ContainerIdentity.volumeModeIdentity(
            gitURL: "https://github.com/org/sample-repo.git",
            configRelativePath: ".devcontainer.json",
            configName: nil
        )
        try MiniTest.expectEqual(id.base, "sample-repo")
        try MiniTest.expectEqual(id.containerName, "sample-repo")
        let named = ContainerIdentity.volumeModeIdentity(
            gitURL: "https://github.com/org/sample-repo.git",
            configRelativePath: ".devcontainer.json",
            configName: "My App"
        )
        try MiniTest.expectEqual(named.containerName, "my-app")
        try MiniTest.expectEqual(named.base, "sample-repo")
        try MiniTest.expectEqual(named.workspaceVolumeName, "adev-sample-repo-\(named.hash12)-ws")
        try MiniTest.expect(named.resourceIdentityStem.hasPrefix("adev-sample-repo-"))
        try MiniTest.expect(!named.resourceIdentityStem.contains("my-app"))
        try MiniTest.expect(!id.containerName.hasPrefix("adev-"))
        try MiniTest.expect(!id.containerName.contains("tmp"))
        try MiniTest.expect(!id.containerName.contains("var"))
    }),
    ("urlNormalizationTrailingGitAndSlash", {
        let urls = [
            "https://github.com/org/repo.git",
            "https://github.com/org/repo.git/",
            "https://github.com/org/repo/",
            "https://github.com/org/repo",
            "  https://github.com/org/repo.git  "
        ]
        let norms = urls.map { ContainerIdentity.normalizeGitURL($0) }
        for n in norms {
            try MiniTest.expectEqual(n, norms[0])
        }
        try MiniTest.expectEqual(norms[0], "https://github.com/org/repo")
    }),
    ("urlNormalizationStripsEmbeddedCredentials", {
        let withPass = ContainerIdentity.normalizeGitURL(
            "https://user:s3cret-token@github.com/org/repo.git"
        )
        let withUser = ContainerIdentity.normalizeGitURL(
            "https://oauth2:ghp_abc@github.com/org/repo.git/"
        )
        let plain = ContainerIdentity.normalizeGitURL("https://github.com/org/repo")
        try MiniTest.expectEqual(withPass, plain)
        try MiniTest.expectEqual(withUser, plain)
        try MiniTest.expect(!withPass.contains("s3cret"))
        try MiniTest.expect(!withPass.contains("user:"))
        // SCP-like keeps git@ shape (not secret userinfo on scheme://)
        let scp = ContainerIdentity.normalizeGitURL("git@github.com:org/repo.git")
        try MiniTest.expectEqual(scp, "git@github.com:org/repo")
        // Identity hash ignores embedded credentials
        let a = ContainerIdentity.volumeModeIdentity(
            gitURL: "https://user:tok@github.com/org/repo.git",
            configRelativePath: ".devcontainer/devcontainer.json",
            configName: nil
        )
        let b = ContainerIdentity.volumeModeIdentity(
            gitURL: "https://github.com/org/repo",
            configRelativePath: ".devcontainer/devcontainer.json",
            configName: nil
        )
        try MiniTest.expectEqual(a.hash12, b.hash12)
        try MiniTest.expectEqual(a.normalizedGitURL, b.normalizedGitURL)
        let labels = ContainerIdentity.volumeModeLabels(identity: a, configHash: "h")
        try MiniTest.expectEqual(labels[ContainerIdentity.labelGitURL], "https://github.com/org/repo")
        try MiniTest.expect(!labels.values.contains(where: { $0.contains("tok") || $0.contains("user:") }))
    }),
    ("bindAndVolumeModesDistinctHashInputs", {
        let bindName = ContainerIdentity.containerName(
            workspacePath: "/Projects/foo",
            configPath: "/Projects/foo/.devcontainer/devcontainer.json"
        )
        let vol = ContainerIdentity.volumeModeIdentity(
            gitURL: "https://github.com/org/foo.git",
            configRelativePath: ".devcontainer/devcontainer.json",
            configName: nil
        )
        // Same sanitized fallback "foo"; hash material stays mode-specific.
        try MiniTest.expectEqual(bindName, "foo")
        try MiniTest.expectEqual(vol.containerName, "foo")
        let bindHash = ContainerIdentity.bindWorkspaceHash12(
            workspacePath: "/Projects/foo",
            configPath: "/Projects/foo/.devcontainer/devcontainer.json"
        )
        try MiniTest.expect(bindHash != vol.hash12, "bind and volume hash material must differ")
        try MiniTest.expectEqual(vol.workspaceVolumeName, "adev-foo-\(vol.hash12)-ws")
    }),
    ("bindAndVolumeStemsIgnoreSharedConfigName", {
        let bindStem = ContainerIdentity.bindResourceIdentityStem(
            workspacePath: "/Projects/foo",
            configPath: "/Projects/foo/.devcontainer/devcontainer.json"
        )
        let vol = ContainerIdentity.volumeModeIdentity(
            gitURL: "https://github.com/org/bar.git",
            configRelativePath: ".devcontainer/devcontainer.json",
            configName: "My App"
        )
        try MiniTest.expectEqual(
            ContainerIdentity.containerName(
                workspacePath: "/Projects/foo",
                configPath: "/Projects/foo/.devcontainer/devcontainer.json",
                configName: "My App"
            ),
            "my-app"
        )
        try MiniTest.expectEqual(vol.containerName, "my-app")
        try MiniTest.expect(bindStem.hasPrefix("adev-foo-"))
        try MiniTest.expect(vol.resourceIdentityStem.hasPrefix("adev-bar-"))
        try MiniTest.expectEqual(vol.workspaceVolumeName, "\(vol.resourceIdentityStem)-ws")
        try MiniTest.expect(bindStem != vol.resourceIdentityStem)
        try MiniTest.expect(!bindStem.contains("my-app"))
        try MiniTest.expect(!vol.resourceIdentityStem.contains("my-app"))
    }),
    ("volumeModeLabelsPresent", {
        let id = ContainerIdentity.volumeModeIdentity(
            gitURL: "https://github.com/org/app.git",
            configRelativePath: ".devcontainer/devcontainer.json",
            configName: "app"
        )
        let labels = ContainerIdentity.volumeModeLabels(
            identity: id,
            configHash: "abc123",
            workspaceFolder: "/workspaces/app",
            remoteUser: "vscode"
        )
        try MiniTest.expectEqual(labels[ContainerIdentity.labelManaged], "adevcontainer")
        try MiniTest.expectEqual(labels[ContainerIdentity.labelWorkspaceMode], "volume")
        try MiniTest.expectEqual(labels[ContainerIdentity.labelWorkspaceVolume], id.workspaceVolumeName)
        try MiniTest.expectEqual(labels[ContainerIdentity.labelGitURL], id.normalizedGitURL)
        try MiniTest.expectEqual(labels[ContainerIdentity.labelConfigHash], "abc123")
        try MiniTest.expectEqual(labels[ContainerIdentity.labelConfigFile], ".devcontainer/devcontainer.json")
        try MiniTest.expect(labels[ContainerIdentity.labelLocalFolder]?.hasPrefix("volume://") == true)
        try MiniTest.expect(labels[ContainerIdentity.labelConfigVolumes] == nil)
        try MiniTest.expectEqual(labels[ContainerIdentity.labelWorkspaceFolder], "/workspaces/app")
        try MiniTest.expectEqual(labels[ContainerIdentity.labelRemoteUser], "vscode")
    }),
    ("volumeModeLabelsRemoteUserEmptyWhenNil", {
        let id = ContainerIdentity.volumeModeIdentity(
            gitURL: "https://github.com/org/app.git",
            configRelativePath: ".devcontainer/devcontainer.json",
            configName: "app"
        )
        let labels = ContainerIdentity.volumeModeLabels(
            identity: id,
            configHash: "h",
            workspaceFolder: "/workspaces/app",
            remoteUser: nil
        )
        try MiniTest.expectEqual(labels[ContainerIdentity.labelWorkspaceFolder], "/workspaces/app")
        try MiniTest.expectEqual(labels[ContainerIdentity.labelRemoteUser], "")
    }),
    ("volumeModeLabelsIncludeConfigVolumes", {
        let id = ContainerIdentity.volumeModeIdentity(
            gitURL: "https://github.com/org/app.git",
            configRelativePath: ".devcontainer/devcontainer.json",
            configName: "app"
        )
        let labels = ContainerIdentity.volumeModeLabels(
            identity: id,
            configHash: "h",
            configVolumeNames: ["vol-a", "vol-b"]
        )
        try MiniTest.expectEqual(labels[ContainerIdentity.labelConfigVolumes], "vol-a,vol-b")
        try MiniTest.expectEqual(
            ContainerIdentity.parseConfigVolumeNames(from: labels),
            ["vol-a", "vol-b"]
        )
    }),
    ("volumeModeCreateRequestUsesNamedVolumeNotBind", {
        let resolved = ResolvedDevContainerConfig(
            image: "alpine:3.20",
            workspaceFolder: "/workspaces/app"
        )
        let id = ContainerIdentity.volumeModeIdentity(
            gitURL: "https://github.com/org/app.git",
            configRelativePath: ".devcontainer/devcontainer.json",
            configName: "app"
        )
        let labels = ContainerIdentity.volumeModeLabels(identity: id, configHash: "h")
        let request = CreateRequest.fromVolumeMode(
            resolved: resolved,
            identityName: id.containerName,
            labels: labels,
            configHash: "h",
            workspaceVolumeName: id.workspaceVolumeName
        )
        try MiniTest.expectEqual(request.workspaceMountMode, .volume)
        try MiniTest.expectEqual(request.workspaceBindHost, id.workspaceVolumeName)
        let args = request.createArguments()
        let mountFlags = args.enumerated().compactMap { i, a -> String? in
            a == "--mount" && i + 1 < args.count ? args[i + 1] : nil
        }
        try MiniTest.expect(mountFlags.contains { $0.contains("type=volume") && $0.contains(id.workspaceVolumeName) })
        try MiniTest.expect(!mountFlags.contains { $0.contains("type=bind") && $0.contains(id.workspaceVolumeName) })
    }),
    ("volumeModeCreateRequestInjectsSSHWhenEnabled", {
        let resolved = ResolvedDevContainerConfig(
            image: "alpine:3.20",
            workspaceFolder: "/workspaces/app",
            runArgs: [.initFlag]
        )
        let id = ContainerIdentity.volumeModeIdentity(
            gitURL: "git@github.com:org/app.git",
            configRelativePath: ".devcontainer/devcontainer.json",
            configName: "app"
        )
        let labels = ContainerIdentity.volumeModeLabels(identity: id, configHash: "h")
        let request = CreateRequest.fromVolumeMode(
            resolved: resolved,
            identityName: id.containerName,
            labels: labels,
            configHash: "h",
            workspaceVolumeName: id.workspaceVolumeName,
            enableSSHForward: true
        )
        try MiniTest.expect(request.runArgs.contains(.ssh))
        try MiniTest.expect(request.runArgs.contains(.initFlag))
        let args = request.createArguments()
        try MiniTest.expect(args.contains("--ssh"))
        // Idempotent: already has ssh
        let withSsh = ResolvedDevContainerConfig(
            image: "alpine:3.20",
            workspaceFolder: "/workspaces/app",
            runArgs: [.ssh]
        )
        let req2 = CreateRequest.fromVolumeMode(
            resolved: withSsh,
            identityName: id.containerName,
            labels: labels,
            configHash: "h",
            workspaceVolumeName: id.workspaceVolumeName,
            enableSSHForward: true
        )
        try MiniTest.expectEqual(req2.runArgs.filter { $0 == .ssh }.count, 1)
    }),
    ("gitURLClassifierSSHAndHTTPS", {
        try MiniTest.expectEqual(GitURLClassifier.kind(of: "git@github.com:org/repo.git"), .ssh)
        try MiniTest.expectEqual(GitURLClassifier.kind(of: "ssh://git@github.com/org/repo.git"), .ssh)
        try MiniTest.expectEqual(GitURLClassifier.kind(of: "https://github.com/org/repo.git"), .https)
        try MiniTest.expectEqual(GitURLClassifier.kind(of: "http://example.com/r.git"), .https)
        try MiniTest.expectEqual(GitURLClassifier.kind(of: "file:///tmp/r"), .other)
        let fields = GitURLClassifier.httpsCredentialFields(for: "https://github.com/org/repo.git")
        try MiniTest.expectEqual(fields?.protocolName, "https")
        try MiniTest.expectEqual(fields?.host, "github.com")
        try MiniTest.expectEqual(fields?.path, "org/repo.git")
    }),
    ("bindModeCreateRequestUnchanged", {
        let resolved = ResolvedDevContainerConfig(
            image: "alpine:3.20",
            workspaceFolder: "/workspaces/app"
        )
        let request = CreateRequest.from(
            resolved: resolved,
            identityName: "adev-app-deadbeefcaf0",
            labels: [:],
            configHash: "h",
            workspacePath: "/Projects/foo"
        )
        try MiniTest.expectEqual(request.workspaceMountMode, .bind)
        try MiniTest.expectEqual(request.workspaceBindHost, "/Projects/foo")
        let args = request.createArguments()
        let mountFlags = args.enumerated().compactMap { i, a -> String? in
            a == "--mount" && i + 1 < args.count ? args[i + 1] : nil
        }
        try MiniTest.expect(mountFlags.contains { $0.contains("type=bind") && $0.contains("/Projects/foo") })
    }),
    ("volumeNameClipKeepsHashAndWsSuffix", {
        let longName = String(repeating: "x", count: 80)
        let name = ContainerIdentity.composeWorkspaceVolumeName(base: longName, hash12: "abcdef123456")
        try MiniTest.expect(name.count <= 63)
        try MiniTest.expect(name.hasSuffix("-abcdef123456-ws") || name.contains("abcdef123456"))
        try MiniTest.expect(name.hasSuffix("-ws"))
        try MiniTest.expect(name.contains("abcdef123456"))
    })
]

// MARK: - Git client tests

nonisolated(unsafe) let gitClientTests: [(String, () throws -> Void)] = [
    ("missingHostGitFailsStructured", {
        let mock = MockGitClient()
        mock.requireGitResult = .failure(CLIError(
            code: CLIErrorCode.gitMissing,
            property: "git",
            message: "Host git is required for clone but was not found on PATH",
            hint: "Install git"
        ))
        try MiniTest.expectThrows({
            _ = try mock.requireGit()
        }) { error in
            let err = error as! CLIError
            try MiniTest.expectEqual(err.code, CLIErrorCode.gitMissing)
            try MiniTest.expect(err.message.lowercased().contains("git"))
        }
    }),
    ("hostGitClientMissingPath", {
        let client = HostGitClient(
            runner: MockProcessRunner(),
            gitPathOverride: .some(nil)
        )
        try MiniTest.expectThrows({ _ = try client.requireGit() }) { error in
            try MiniTest.expectEqual((error as! CLIError).code, CLIErrorCode.gitMissing)
        }
    }),
    ("fetchConfigInvokesCloneShape", {
        let runner = MockProcessRunner()
        // sparse clone success + sparse-checkout success
        runner.defaultResult = ProcessResult(exitCode: 0, stdout: Data(), stderr: Data())
        let gitPath = "/usr/bin/mock-git"
        let client = HostGitClient(runner: runner, gitPathOverride: .some(gitPath))
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("git-fetch-\(UUID().uuidString)").path
        // Don't actually create — mock doesn't need it
        try client.fetchConfig(url: "https://example.com/r.git", into: dir)
        try MiniTest.expect(runner.calls.count >= 1)
        let first = runner.calls[0].arguments
        try MiniTest.expectEqual(first.first, "clone")
        try MiniTest.expect(first.contains("--depth"))
        try MiniTest.expect(first.contains("--")) // end-of-options before URL
        try MiniTest.expect(first.contains("https://example.com/r.git"))
        try MiniTest.expect(first.contains(dir))
        // URL must appear after `--` so it cannot be parsed as a git option
        let dd = first.firstIndex(of: "--")!
        let urlIdx = first.firstIndex(of: "https://example.com/r.git")!
        try MiniTest.expect(urlIdx > dd)
        // No PAT / token flags
        try MiniTest.expect(!first.contains(where: { $0.lowercased().contains("token") || $0.lowercased().contains("pat") }))
    }),
    ("fullCloneInvokesWithoutCredentialFlags", {
        let runner = MockProcessRunner()
        runner.defaultResult = ProcessResult(exitCode: 0, stdout: Data(), stderr: Data())
        let client = HostGitClient(runner: runner, gitPathOverride: .some("/usr/bin/mock-git"))
        try client.fullClone(url: "git@github.com:org/repo.git", into: "/tmp/staging-x")
        let args = runner.calls[0].arguments
        try MiniTest.expectEqual(args, ["clone", "--", "git@github.com:org/repo.git", "/tmp/staging-x"])
        try MiniTest.expect(!args.contains(where: { $0.contains("GCM") || $0.lowercased().contains("token") }))
    }),
    ("gitCloneRejectsOptionShapedURLWithoutShell", {
        // URL that would be dangerous if passed without `--` (git option injection).
        let runner = MockProcessRunner()
        runner.defaultResult = ProcessResult(exitCode: 0, stdout: Data(), stderr: Data())
        let client = HostGitClient(runner: runner, gitPathOverride: .some("/usr/bin/mock-git"))
        let evil = "--upload-pack=evil"
        try client.fullClone(url: evil, into: "/tmp/staging-opt")
        let args = runner.calls[0].arguments
        try MiniTest.expectEqual(args, ["clone", "--", evil, "/tmp/staging-opt"])
        // Must not be invoked via shell; ProcessRunning gets argv list only
        try MiniTest.expectEqual(runner.calls[0].executable, "/usr/bin/mock-git")
    }),
    ("gitFailureMapsStructured", {
        let runner = MockProcessRunner()
        runner.enqueueFailure(exitCode: 128, stderr: "repository not found")
        let client = HostGitClient(runner: runner, gitPathOverride: .some("/usr/bin/mock-git"))
        try MiniTest.expectThrows({
            try client.fullClone(url: "https://example.com/nope.git", into: "/tmp/x")
        }) { error in
            try MiniTest.expectEqual((error as! CLIError).code, CLIErrorCode.gitFailed)
        }
    }),
    ("gitFailureRedactsEmbeddedCredentialsInMessage", {
        let runner = MockProcessRunner()
        let secretURL = "https://user:super-secret@github.com/org/private.git"
        runner.enqueueFailure(
            exitCode: 128,
            stderr: "fatal: repository '\(secretURL)' not found"
        )
        let client = HostGitClient(runner: runner, gitPathOverride: .some("/usr/bin/mock-git"))
        try MiniTest.expectThrows({
            try client.fullClone(url: secretURL, into: "/tmp/x")
        }) { error in
            let err = error as! CLIError
            try MiniTest.expectEqual(err.code, CLIErrorCode.gitFailed)
            try MiniTest.expect(!err.message.contains("super-secret"))
            try MiniTest.expect(err.message.contains("https://github.com/org/private"))
        }
    }),
    ("hostGitCredentialFillParsesOutput", {
        let runner = MockProcessRunner()
        runner.stdinHandlers = [
            { args, stdin in
                guard args == ["credential", "fill"] else { return nil }
                let text = String(data: stdin ?? Data(), encoding: .utf8) ?? ""
                guard text.contains("protocol=https"), text.contains("host=github.com") else {
                    return ProcessResult(exitCode: 1, stdout: Data(), stderr: Data("bad input".utf8))
                }
                let out = "protocol=https\nhost=github.com\nusername=alice\npassword=s3cret\n"
                return ProcessResult(exitCode: 0, stdout: Data(out.utf8), stderr: Data())
            }
        ]
        let cred = HostGitCredential(
            runner: runner,
            gitPathOverride: .some("/usr/bin/mock-git"),
            environment: [:],
            ghPathOverride: .some(nil)
        )
        let result = try cred.fillHTTPS(url: "https://github.com/org/repo.git")
        try MiniTest.expectEqual(result?.username, "alice")
        try MiniTest.expectEqual(result?.password, "s3cret")
        try MiniTest.expectEqual(runner.calls.count, 1)
        let stdinText = String(data: runner.calls[0].stdinData ?? Data(), encoding: .utf8) ?? ""
        try MiniTest.expect(stdinText.contains("protocol=https"))
        try MiniTest.expect(stdinText.contains("host=github.com"))
    }),
    ("hostGitCredentialTokenEnvEscapeHatch", {
        let runner = MockProcessRunner()
        let cred = HostGitCredential(
            runner: runner,
            gitPathOverride: .some("/usr/bin/mock-git"),
            environment: ["ADEVCONTAINER_GIT_TOKEN": "ghp_escape"],
            ghPathOverride: .some(nil)
        )
        let result = try cred.fillHTTPS(url: "https://github.com/org/repo.git")
        try MiniTest.expectEqual(result?.username, "x-access-token")
        try MiniTest.expectEqual(result?.password, "ghp_escape")
        try MiniTest.expect(runner.calls.isEmpty) // no git credential fill when token set
    }),
    ("hostGitCredentialFillFailureReturnsNil", {
        let runner = MockProcessRunner()
        runner.enqueueFailure(exitCode: 128, stderr: "no helper")
        let cred = HostGitCredential(
            runner: runner,
            gitPathOverride: .some("/usr/bin/mock-git"),
            environment: [:],
            ghPathOverride: .some(nil)
        )
        let result = try cred.fillHTTPS(url: "https://example.com/private.git")
        try MiniTest.expect(result == nil)
    }),
    ("parseCredentialOutputKeys", {
        let parsed = HostGitCredential.parseCredentialOutput(
            "protocol=https\nhost=h\nusername=u\npassword=p\n"
        )
        try MiniTest.expectEqual(parsed["username"], "u")
        try MiniTest.expectEqual(parsed["password"], "p")
    }),
    ("resolveAuthorIdentityReadsNameAndEmail", {
        let runner = MockProcessRunner()
        runner.handlers = [
            { args in
                if args.contains("user.name") {
                    return ProcessResult(exitCode: 0, stdout: Data("Ada Lovelace\n".utf8), stderr: Data())
                }
                if args.contains("user.email") {
                    return ProcessResult(exitCode: 0, stdout: Data("ada@example.com\n".utf8), stderr: Data())
                }
                return nil
            }
        ]
        let client = HostGitClient(runner: runner, gitPathOverride: .some("/usr/bin/mock-git"))
        let id = client.resolveAuthorIdentity(in: "/tmp/cfg-worktree")
        try MiniTest.expectEqual(id.name, "Ada Lovelace")
        try MiniTest.expectEqual(id.email, "ada@example.com")
        try MiniTest.expect(id.isComplete)
        try MiniTest.expectEqual(runner.calls.count, 2)
        try MiniTest.expect(runner.calls[0].arguments.contains("-C"))
        try MiniTest.expect(runner.calls[0].arguments.contains("/tmp/cfg-worktree"))
        try MiniTest.expect(runner.calls[0].arguments.contains("config"))
        try MiniTest.expect(runner.calls[0].arguments.contains("--get"))
    }),
    ("resolveAuthorIdentityMissingIsIncomplete", {
        let runner = MockProcessRunner()
        runner.handlers = [
            { args in
                if args.contains("user.name") {
                    return ProcessResult(exitCode: 0, stdout: Data("Only Name\n".utf8), stderr: Data())
                }
                // email missing
                return ProcessResult(exitCode: 1, stdout: Data(), stderr: Data())
            }
        ]
        let client = HostGitClient(runner: runner, gitPathOverride: .some("/usr/bin/mock-git"))
        let id = client.resolveAuthorIdentity(in: "/tmp/cfg")
        try MiniTest.expectEqual(id.name, "Only Name")
        try MiniTest.expect(id.email == nil)
        try MiniTest.expect(!id.isComplete)
    }),
    ("effectiveAuthorIdentityEnvOverrides", {
        let base = GitAuthorIdentity(name: "Host", email: "host@example.com")
        let both = CloneCommand.effectiveAuthorIdentity(
            resolved: base,
            localEnv: [
                "ADEVCONTAINER_GIT_AUTHOR_NAME": "Env Name",
                "ADEVCONTAINER_GIT_AUTHOR_EMAIL": "env@example.com"
            ]
        )
        try MiniTest.expectEqual(both.name, "Env Name")
        try MiniTest.expectEqual(both.email, "env@example.com")
        let nameOnly = CloneCommand.effectiveAuthorIdentity(
            resolved: base,
            localEnv: ["ADEVCONTAINER_GIT_AUTHOR_NAME": "Only"]
        )
        try MiniTest.expectEqual(nameOnly.name, "Only")
        try MiniTest.expectEqual(nameOnly.email, "host@example.com")
    })
]

// MARK: - FeatureGitEnsure (clone auto git feature)

nonisolated(unsafe) let featureGitEnsureTests: [(String, () throws -> Void)] = [
    ("featureGitEnsureEmptyInjectsGit1", {
        let (out, didInject) = FeatureGitEnsure.ensurePresent(features: [])
        try MiniTest.expect(didInject)
        try MiniTest.expectEqual(out.count, 1)
        try MiniTest.expectEqual(out[0].reference, FeatureGitEnsure.gitFeatureRef)
        try MiniTest.expectEqual(out[0].options.count, 0)
        try MiniTest.expectEqual(FeatureRef.featureId(from: out[0].reference), "git")
    }),
    ("featureGitEnsureAlreadyHasGitNoDuplicate", {
        let existing = AdmittedFeature(
            reference: "ghcr.io/devcontainers/features/git:1",
            options: ["version": .string("latest")]
        )
        let (out, didInject) = FeatureGitEnsure.ensurePresent(features: [existing])
        try MiniTest.expect(!didInject)
        try MiniTest.expectEqual(out.count, 1)
        try MiniTest.expectEqual(out[0].reference, existing.reference)
        try MiniTest.expectEqual(out[0].options["version"]?.stringValue, "latest")
    }),
    ("featureGitEnsureAlreadyHasCommonUtilsNoInject", {
        let existing = AdmittedFeature(
            reference: "ghcr.io/devcontainers/features/common-utils:2",
            options: [:]
        )
        let (out, didInject) = FeatureGitEnsure.ensurePresent(features: [existing])
        try MiniTest.expect(!didInject)
        try MiniTest.expectEqual(out.count, 1)
        try MiniTest.expectEqual(out[0].reference, existing.reference)
    }),
    ("featureGitEnsureOtherFeaturesStillInjects", {
        let node = AdmittedFeature(
            reference: "ghcr.io/devcontainers/features/node:1",
            options: [:]
        )
        let (out, didInject) = FeatureGitEnsure.ensurePresent(features: [node])
        try MiniTest.expect(didInject)
        try MiniTest.expectEqual(out.count, 2)
        try MiniTest.expectEqual(out[0].reference, node.reference)
        try MiniTest.expectEqual(out[1].reference, FeatureGitEnsure.gitFeatureRef)
    }),
    ("featureGitEnsureLocalPathGitIdCounts", {
        let local = AdmittedFeature(reference: "./.devcontainer/features/git", options: [:])
        let (out, didInject) = FeatureGitEnsure.ensurePresent(features: [local])
        try MiniTest.expect(!didInject)
        try MiniTest.expectEqual(out.count, 1)
    }),
    ("featureGitEnsureLocalPathCommonUtilsCounts", {
        let local = AdmittedFeature(reference: "../features/common-utils", options: [:])
        let (out, didInject) = FeatureGitEnsure.ensurePresent(features: [local])
        try MiniTest.expect(!didInject)
        try MiniTest.expectEqual(out.count, 1)
    })
]

// MARK: - Clone Features test support (auto-injected git)

/// Installs CloneCommand Features overrides so injected `git:1` is satisfied without network.
enum CloneGitFeatureTestSupport {
    static var gitFixturePath: String {
        TestRepo.root().appendingPathComponent("Tests/Fixtures/features-sample/git").path
    }

    /// Returns restore closure; always call via `defer { restore() }`.
    static func installOverrides(extraPackages: [String: String] = [:]) -> () -> Void {
        var packages = extraPackages
        packages[FeatureGitEnsure.gitFeatureRef] = gitFixturePath
        let cache = FileManager.default.temporaryDirectory
            .appendingPathComponent("clone-git-feat-\(UUID().uuidString)", isDirectory: true).path
        let previousFetcher = CloneCommand.featuresFetcherOverride
        let previousCache = CloneCommand.featuresCacheRootOverride
        let previousEnsure = CloneCommand.ensureNativeArmBuildOverride
        CloneCommand.featuresFetcherOverride = MockFeatureFetcher(packagesByRef: packages)
        CloneCommand.featuresCacheRootOverride = cache
        CloneCommand.ensureNativeArmBuildOverride = { /* no-op in tests */ }
        return {
            CloneCommand.featuresFetcherOverride = previousFetcher
            CloneCommand.featuresCacheRootOverride = previousCache
            CloneCommand.ensureNativeArmBuildOverride = previousEnsure
            try? FileManager.default.removeItem(atPath: cache)
        }
    }
}

// MARK: - Clone command orchestration

nonisolated(unsafe) let cloneCommandTests: [(String, () throws -> Void)] = [
    ("cloneOptionsDefaultJsonOutputFalse", {
        let opts = CloneOptions(gitURL: "https://example.com/r.git")
        try MiniTest.expectEqual(opts.jsonOutput, false)
        try MiniTest.expectEqual(opts.openVSCode, false)
        try MiniTest.expectEqual(opts.skipPull, false)
    }),
    ("cloneOptionsAcceptJsonFlagViaParseArgs", {
        let parsed = try CommandSurface.parseArgs([
            "https://example.com/r.git", "--json", "--skip-pull", "--vscode"
        ])
        try MiniTest.expect(parsed.flags.contains("json"))
        try MiniTest.expect(parsed.flags.contains("skip-pull"))
        try MiniTest.expect(parsed.flags.contains("vscode"))
        try MiniTest.expectEqual(parsed.passthrough, ["https://example.com/r.git"])
        let opts = CloneOptions(
            gitURL: parsed.passthrough[0],
            skipPull: parsed.flags.contains("skip-pull"),
            openVSCode: parsed.flags.contains("vscode"),
            jsonOutput: parsed.flags.contains("json")
        )
        try MiniTest.expectEqual(opts.jsonOutput, true)
        try MiniTest.expectEqual(opts.skipPull, true)
        try MiniTest.expectEqual(opts.openVSCode, true)
    }),
    ("cloneResumeFlagParsesAndIsCloneOnly", {
        let parsed = try CommandSurface.parseArgs(["https://example.com/r.git", "--resume", "/tmp/retained"])
        try MiniTest.expectEqual(parsed.resume, "/tmp/retained")
        try MiniTest.expectEqual(parsed.passthrough, ["https://example.com/r.git"])
        try CommandSurface.enforceWorkspaceGate(subcommand: "clone", parsed: parsed)
        try MiniTest.expectThrows({
            try CommandSurface.enforceWorkspaceGate(subcommand: "up", parsed: parsed)
        }) { error in
            try MiniTest.expectEqual((error as? CLIError)?.code, CLIErrorCode.usage)
            try MiniTest.expectEqual((error as? CLIError)?.property, "--resume")
        }
    }),
    ("cloneHelpAndUsageListJson", {
        let usage = CommandSurface.usageText()
        try MiniTest.expect(usage.contains("--json"), "usage mentions --json")
        try MiniTest.expect(
            usage.contains("up, clone, list, rebuild") || usage.contains("clone"),
            "usage associates --json with clone"
        )
        let help = CommandSurface.commandHelpText("clone")
        try MiniTest.expect(help != nil, "clone help present")
        guard let help else { return }
        try MiniTest.expect(help.contains("[--json]"), "clone help lists --json")
        try MiniTest.expect(help.contains("machine-readable"), "clone help describes JSON mode")
        try MiniTest.expect(help.contains("--resume"), "clone help describes resume")
    }),
    ("cloneMissingGitNoContainer", {
        let git = MockGitClient()
        git.requireGitResult = .failure(CLIError(
            code: CLIErrorCode.gitMissing,
            property: "git",
            message: "Host git is required for clone but was not found on PATH"
        ))
        let mock = MockProcessRunner()
        let runtime = AppleContainerRuntime(executablePath: "/usr/local/bin/container", runner: mock)
        try MiniTest.expectThrows({
            _ = try CloneCommand.run(
                options: CloneOptions(gitURL: "https://example.com/r.git", skipPull: true),
                runtime: runtime,
                git: git,
                credentials: MockGitCredential(),
                localEnv: [:]
            )
        }) { error in
            try MiniTest.expectEqual((error as! CLIError).code, CLIErrorCode.gitMissing)
        }
        try MiniTest.expect(!mock.calls.contains { $0.arguments.first == "create" })
        try MiniTest.expect(git.fetchConfigCalls.isEmpty)
    }),
    ("cloneMissingConfigNoContainerOrDefaultImage", {
        let git = MockGitClient()
        git.writeNoConfig = true
        let mock = MockProcessRunner()
        mock.handlers = CloneRuntimeMock.handlers()
        let runtime = AppleContainerRuntime(executablePath: "/usr/local/bin/container", runner: mock)
        try MiniTest.expectThrows({
            _ = try CloneCommand.run(
                options: CloneOptions(gitURL: "https://example.com/empty.git", skipPull: true),
                runtime: runtime,
                git: git,
                credentials: MockGitCredential(),
                localEnv: [:]
            )
        }) { error in
            let err = error as! CLIError
            try MiniTest.expectEqual(err.code, CLIErrorCode.configNotFound)
            try MiniTest.expect(err.hint?.contains(".devcontainer/devcontainer.json") == true)
            try MiniTest.expect(err.hint?.contains(".devcontainer.json") == true)
        }
        try MiniTest.expect(!mock.calls.contains { $0.arguments.first == "create" })
        try MiniTest.expect(git.fullCloneCalls.isEmpty)
    }),
    ("cloneSSHWithoutAgentFailsBeforeCreate", {
        let git = MockGitClient()
        let mock = MockProcessRunner()
        let runtime = AppleContainerRuntime(executablePath: "/usr/local/bin/container", runner: mock)
        try MiniTest.expectThrows({
            _ = try CloneCommand.run(
                options: CloneOptions(gitURL: "git@github.com:org/repo.git", skipPull: true),
                runtime: runtime,
                git: git,
                credentials: MockGitCredential(),
                localEnv: [:] // no SSH_AUTH_SOCK
            )
        }) { error in
            let err = error as! CLIError
            try MiniTest.expectEqual(err.code, CLIErrorCode.gitFailed)
            try MiniTest.expect(err.message.contains("SSH_AUTH_SOCK") || err.message.lowercased().contains("ssh-agent"))
        }
        try MiniTest.expect(!mock.calls.contains { $0.arguments.first == "create" })
        try MiniTest.expect(git.fetchConfigCalls.isEmpty)
        try MiniTest.expect(git.fullCloneCalls.isEmpty)
    }),
    ("cloneHappyPathVolumeMountLabelsInContainerCloneJSON", {
        let restore = CloneGitFeatureTestSupport.installOverrides()
        defer { restore() }
        let git = MockGitClient()
        git.configJSONToWrite = """
        {
          "name": "CloneApp",
          "image": "alpine:3.20",
          "postCreateCommand": "echo ok"
        }
        """
        let creds = MockGitCredential()
        let mock = MockProcessRunner()
        var createdName: String?
        mock.handlers = CloneRuntimeMock.handlers(onCreate: { args in
            if args.first == "create",
               let nameIdx = args.firstIndex(of: "--name"), nameIdx + 1 < args.count {
                createdName = args[nameIdx + 1]
            }
        })
        // Override create to return named id (keep inspect/build for Features + user resolution).
        mock.handlers = [
            MockProcessRunner.imageInspectHandler(baseUser: nil),
            { args in
                if args.starts(with: ["list"]) || args.starts(with: ["volume", "list"]) {
                    let data = try! JSONSerialization.data(withJSONObject: [] as [Any])
                    return ProcessResult(exitCode: 0, stdout: data, stderr: Data())
                }
                if args.starts(with: ["image", "list"]) {
                    return ProcessResult(exitCode: 1, stdout: Data(), stderr: Data("missing".utf8))
                }
                if args.first == "build" {
                    return ProcessResult(exitCode: 0, stdout: Data(), stderr: Data())
                }
                if args.starts(with: ["volume", "create"]) {
                    return ProcessResult(exitCode: 0, stdout: Data(), stderr: Data())
                }
                if args.first == "create" {
                    if let nameIdx = args.firstIndex(of: "--name"), nameIdx + 1 < args.count {
                        createdName = args[nameIdx + 1]
                    }
                    return ProcessResult(
                        exitCode: 0,
                        stdout: Data("\((createdName ?? "ctr"))\n".utf8),
                        stderr: Data()
                    )
                }
                if args.first == "start" || args.first == "delete" {
                    return ProcessResult(exitCode: 0, stdout: Data(), stderr: Data())
                }
                if args.first == "exec" {
                    if args.contains("test") && args.contains("-e") {
                        return ProcessResult(exitCode: 0, stdout: Data(), stderr: Data())
                    }
                    if args.contains("-lc") || args.contains("-c") {
                        return ProcessResult(exitCode: 0, stdout: Data(), stderr: Data())
                    }
                    return ProcessResult(exitCode: 0, stdout: Data(), stderr: Data())
                }
                return nil
            }
        ]
        let runtime = AppleContainerRuntime(executablePath: "/usr/local/bin/container", runner: mock)
        let result = try CloneCommand.run(
            options: CloneOptions(gitURL: "https://github.com/org/clone-app.git", skipPull: true),
            runtime: runtime,
            git: git,
            credentials: creds,
            localEnv: [:]
        )
        try MiniTest.expectEqual(result.outcome, "success")
        try MiniTest.expectEqual(result.gitUrl, "https://github.com/org/clone-app")
        try MiniTest.expect(result.workspaceVolume.hasSuffix("-ws"))
        try MiniTest.expect(result.workspaceVolume.hasPrefix("adev-"))
        try MiniTest.expectEqual(result.containerName, "cloneapp")
        try MiniTest.expect(!result.containerId.isEmpty)
        try MiniTest.expectEqual(result.remoteWorkspaceFolder, "/workspaces/clone-app")
        try MiniTest.expect(!result.remoteWorkspaceFolder.contains("adev-clone-cfg"))
        // Create argv: volume mount + managed labels
        let createCall = mock.calls.first { $0.arguments.first == "create" }!
        let mounts = createCall.arguments.enumerated().compactMap { i, a -> String? in
            a == "--mount" && i + 1 < createCall.arguments.count ? createCall.arguments[i + 1] : nil
        }
        try MiniTest.expect(mounts.contains { $0.contains("type=volume") && $0.contains(result.workspaceVolume) })
        if let wIdx = createCall.arguments.firstIndex(of: "-w"), wIdx + 1 < createCall.arguments.count {
            try MiniTest.expectEqual(createCall.arguments[wIdx + 1], "/workspaces/clone-app")
        } else {
            try MiniTest.expect(false, "expected -w workdir on create")
        }
        try MiniTest.expect(mounts.contains {
            $0.contains("dst=/workspaces/clone-app")
                || $0.contains("destination=/workspaces/clone-app")
                || $0.contains("target=/workspaces/clone-app")
        })
        let labelVals = createCall.arguments.enumerated().compactMap { i, a -> String? in
            a == "-l" && i + 1 < createCall.arguments.count ? createCall.arguments[i + 1] : nil
        }
        try MiniTest.expect(labelVals.contains { $0 == "devcontainer.managed=adevcontainer" })
        try MiniTest.expect(labelVals.contains { $0 == "devcontainer.workspace_mode=volume" })
        try MiniTest.expect(labelVals.contains { $0.hasPrefix("devcontainer.git_url=") })
        try MiniTest.expect(labelVals.contains { $0.hasPrefix("devcontainer.workspace_volume=") })
        try MiniTest.expect(labelVals.contains { $0 == "devcontainer.workspace_folder=/workspaces/clone-app" })
        // Empty OCI USER after successful inspect → resolved connection user `root`
        try MiniTest.expect(labelVals.contains { $0 == "devcontainer.remote_user=root" })
        try MiniTest.expectEqual(result.remoteUser, "root")
        // No secrets in labels / success JSON
        try MiniTest.expect(!labelVals.contains { $0.contains("secret-token") })
        let obj = try JSONSerialization.jsonObject(with: try result.jsonData()) as! [String: Any]
        try MiniTest.expectEqual(obj["remoteUser"] as? String, "root")
        let jsonText = String(data: try result.jsonData(), encoding: .utf8) ?? ""
        try MiniTest.expect(!jsonText.contains("secret-token"))
        // Populate: in-container git clone (sh -c), NOT host fullClone / tar-pipe
        try MiniTest.expect(git.fullCloneCalls.isEmpty)
        try MiniTest.expect(!mock.calls.contains { $0.executable == "/usr/bin/tar" })
        try MiniTest.expect(mock.calls.contains {
            $0.arguments.first == "exec" && $0.arguments.contains("sh") && $0.arguments.contains("-c")
        })
        try MiniTest.expect(mock.calls.contains {
            $0.arguments.first == "exec" && $0.arguments.contains("test") && $0.arguments.contains("-e")
        })
        // HTTPS credentials filled once
        try MiniTest.expectEqual(creds.fillCalls.count, 1)
        // Hooks: postCreate exec (sh -lc)
        try MiniTest.expect(mock.calls.contains {
            $0.arguments.first == "exec" && $0.arguments.contains("-lc")
        })
        try MiniTest.expectEqual(obj["outcome"] as? String, "success")
        try MiniTest.expect(obj["containerId"] != nil)
        try MiniTest.expectEqual(obj["remoteUser"] as? String, "root")
        try MiniTest.expect(obj["remoteWorkspaceFolder"] != nil)
        try MiniTest.expect(obj["gitUrl"] != nil)
        try MiniTest.expect(obj["workspaceVolume"] != nil)
        // Config temp cleaned
        try MiniTest.expect(!FileManager.default.fileExists(atPath: git.fetchConfigCalls[0].directory))
        let fetcher = CloneCommand.featuresFetcherOverride as? MockFeatureFetcher
        try MiniTest.expect((fetcher?.fetchCalls.count ?? 0) >= 1)
    }),
    ("cloneStampsConfigRemoteUserAlice", {
        let restore = CloneGitFeatureTestSupport.installOverrides()
        defer { restore() }
        let git = MockGitClient()
        git.configJSONToWrite = """
        {
          "name": "CloneAlice",
          "image": "alpine:3.20",
          "remoteUser": "alice"
        }
        """
        let mock = MockProcessRunner()
        mock.handlers = CloneRuntimeMock.handlers(baseUser: "node")
        let runtime = AppleContainerRuntime(executablePath: "/usr/local/bin/container", runner: mock)
        let result = try CloneCommand.run(
            options: CloneOptions(gitURL: "https://github.com/org/clone-alice.git", skipPull: true),
            runtime: runtime,
            git: git,
            credentials: MockGitCredential(),
            localEnv: [:]
        )
        try MiniTest.expectEqual(result.outcome, "success")
        try MiniTest.expectEqual(result.remoteUser, "alice")
        let createCall = mock.calls.first { $0.arguments.first == "create" }!
        let labelVals = createCall.arguments.enumerated().compactMap { i, a -> String? in
            a == "-l" && i + 1 < createCall.arguments.count ? createCall.arguments[i + 1] : nil
        }
        try MiniTest.expect(labelVals.contains { $0 == "devcontainer.remote_user=alice" })
        try MiniTest.expect(createCall.arguments.contains("-u"), "non-root remoteUser → create -u (Apple attach)")
        if let i = createCall.arguments.firstIndex(of: "-u") {
            try MiniTest.expectEqual(createCall.arguments[i + 1], "alice")
        }
    }),
    ("cloneSSHInjectsCreateSSHFlag", {
        let restore = CloneGitFeatureTestSupport.installOverrides()
        defer { restore() }
        let git = MockGitClient()
        git.configJSONToWrite = #"{ "image": "alpine:3.20" }"#
        let mock = MockProcessRunner()
        mock.handlers = CloneRuntimeMock.handlers()
        let runtime = AppleContainerRuntime(executablePath: "/usr/local/bin/container", runner: mock)
        let result = try CloneCommand.run(
            options: CloneOptions(gitURL: "git@github.com:org/ssh-app.git", skipPull: true),
            runtime: runtime,
            git: git,
            credentials: MockGitCredential(),
            localEnv: ["SSH_AUTH_SOCK": "/tmp/ssh-agent.sock"]
        )
        try MiniTest.expectEqual(result.outcome, "success")
        let createCall = mock.calls.first { $0.arguments.first == "create" }!
        try MiniTest.expect(createCall.arguments.contains("--ssh"))
        // SSH path does not call HTTPS credential fill
        try MiniTest.expect(git.fullCloneCalls.isEmpty)
        try MiniTest.expect(mock.calls.contains {
            $0.arguments.first == "exec" && $0.arguments.contains("-c")
        })
    }),
    ("cloneHTTPSPublicWorksWithoutHostCredentials", {
        let restore = CloneGitFeatureTestSupport.installOverrides()
        defer { restore() }
        let git = MockGitClient()
        git.configJSONToWrite = #"{ "image": "alpine:3.20" }"#
        let creds = MockGitCredential()
        creds.fillResult = .success(nil) // public: no stored credentials
        let mock = MockProcessRunner()
        mock.handlers = CloneRuntimeMock.handlers()
        let runtime = AppleContainerRuntime(executablePath: "/usr/local/bin/container", runner: mock)
        let result = try CloneCommand.run(
            options: CloneOptions(gitURL: "https://github.com/org/public.git", skipPull: true),
            runtime: runtime,
            git: git,
            credentials: creds,
            localEnv: [:]
        )
        try MiniTest.expectEqual(result.outcome, "success")
        try MiniTest.expectEqual(creds.fillCalls.count, 1)
        try MiniTest.expect(git.fullCloneCalls.isEmpty)
    }),
    ("cloneHTTPSCloneFailWithoutCredsHintsCredentials", {
        let restore = CloneGitFeatureTestSupport.installOverrides()
        defer { restore() }
        let git = MockGitClient()
        git.configJSONToWrite = #"{ "image": "alpine:3.20" }"#
        let creds = MockGitCredential()
        creds.fillResult = .success(nil)
        let mock = MockProcessRunner()
        mock.handlers = CloneRuntimeMock.handlers(cloneExecSucceeds: false)
        let runtime = AppleContainerRuntime(executablePath: "/usr/local/bin/container", runner: mock)
        try MiniTest.expectThrows({
            _ = try CloneCommand.run(
                options: CloneOptions(gitURL: "https://github.com/org/private.git", skipPull: true),
                runtime: runtime,
                git: git,
                credentials: creds,
                localEnv: [:]
            )
        }) { error in
            let err = error as! CLIError
            try MiniTest.expectEqual(err.code, CLIErrorCode.populateFailed)
            try MiniTest.expect(
                err.hint?.lowercased().contains("credential") == true
                    || err.hint?.lowercased().contains("ssh") == true
            )
        }
        try MiniTest.expect(mock.calls.contains { $0.arguments.first == "delete" })
        try MiniTest.expect(mock.calls.contains { $0.arguments.starts(with: ["volume", "delete"]) })
        try MiniTest.expect(git.fullCloneCalls.isEmpty)
    }),
    ("cloneRootConfigFallback", {
        let restore = CloneGitFeatureTestSupport.installOverrides()
        defer { restore() }
        let git = MockGitClient()
        git.writeRootConfigOnly = true
        git.configJSONToWrite = #"{ "image": "alpine:3.20" }"#
        let mock = MockProcessRunner()
        mock.handlers = CloneRuntimeMock.handlers()
        let runtime = AppleContainerRuntime(executablePath: "/usr/local/bin/container", runner: mock)
        let result = try CloneCommand.run(
            options: CloneOptions(gitURL: "https://example.com/root-cfg.git", skipPull: true),
            runtime: runtime,
            git: git,
            credentials: MockGitCredential(),
            localEnv: [:]
        )
        try MiniTest.expectEqual(result.outcome, "success")
        try MiniTest.expectEqual(result.remoteWorkspaceFolder, "/workspaces/root-cfg")
        let createCall = mock.calls.first { $0.arguments.first == "create" }!
        let labels = createCall.arguments.enumerated().compactMap { i, a -> String? in
            a == "-l" && i + 1 < createCall.arguments.count ? createCall.arguments[i + 1] : nil
        }
        try MiniTest.expect(labels.contains { $0 == "devcontainer.config_file=.devcontainer.json" })
    }),
    ("cloneWorkspaceFolderUsesRepoBasenameNotTempDir", {
        let restore = CloneGitFeatureTestSupport.installOverrides()
        defer { restore() }
        let git = MockGitClient()
        git.configJSONToWrite = #"{ "image": "alpine:3.20" }"#
        let mock = MockProcessRunner()
        mock.handlers = CloneRuntimeMock.handlers()
        let runtime = AppleContainerRuntime(executablePath: "/usr/local/bin/container", runner: mock)
        let result = try CloneCommand.run(
            options: CloneOptions(
                gitURL: "https://github.com/wcgomes/apple-devcontainers.git",
                skipPull: true
            ),
            runtime: runtime,
            git: git,
            credentials: MockGitCredential(),
            localEnv: [:]
        )
        try MiniTest.expectEqual(result.remoteWorkspaceFolder, "/workspaces/apple-devcontainers")
        try MiniTest.expect(!result.remoteWorkspaceFolder.contains("adev-clone-cfg"))
        try MiniTest.expect(!result.remoteWorkspaceFolder.contains("tmp"))
        let createCall = mock.calls.first { $0.arguments.first == "create" }!
        if let wIdx = createCall.arguments.firstIndex(of: "-w"), wIdx + 1 < createCall.arguments.count {
            try MiniTest.expectEqual(createCall.arguments[wIdx + 1], "/workspaces/apple-devcontainers")
        } else {
            try MiniTest.expect(false, "expected -w workdir on create")
        }
        try MiniTest.expectEqual(result.containerName, "apple-devcontainers")
    }),
    ("cloneHonorsExplicitWorkspaceFolder", {
        let restore = CloneGitFeatureTestSupport.installOverrides()
        defer { restore() }
        let git = MockGitClient()
        git.configJSONToWrite = """
        {
          "image": "alpine:3.20",
          "workspaceFolder": "/custom/ws"
        }
        """
        let mock = MockProcessRunner()
        mock.handlers = CloneRuntimeMock.handlers()
        let runtime = AppleContainerRuntime(executablePath: "/usr/local/bin/container", runner: mock)
        let result = try CloneCommand.run(
            options: CloneOptions(gitURL: "https://github.com/org/sample-repo.git", skipPull: true),
            runtime: runtime,
            git: git,
            credentials: MockGitCredential(),
            localEnv: [:]
        )
        try MiniTest.expectEqual(result.remoteWorkspaceFolder, "/custom/ws")
    }),
    ("cloneResolvesLocalWorkspaceFolderBasenameToRepo", {
        let restore = CloneGitFeatureTestSupport.installOverrides()
        defer { restore() }
        let git = MockGitClient()
        git.configJSONToWrite = """
        {
          "image": "alpine:3.20",
          "workspaceFolder": "/workspaces/${localWorkspaceFolderBasename}"
        }
        """
        let mock = MockProcessRunner()
        mock.handlers = CloneRuntimeMock.handlers()
        let runtime = AppleContainerRuntime(executablePath: "/usr/local/bin/container", runner: mock)
        let result = try CloneCommand.run(
            options: CloneOptions(gitURL: "https://github.com/org/sample-repo.git", skipPull: true),
            runtime: runtime,
            git: git,
            credentials: MockGitCredential(),
            localEnv: [:]
        )
        try MiniTest.expectEqual(result.remoteWorkspaceFolder, "/workspaces/sample-repo")
        try MiniTest.expect(!result.remoteWorkspaceFolder.contains("adev-clone-cfg"))
    }),
    ("configResolverWorkspaceFolderBasenameOverride", {
        let fm = FileManager.default
        let root = fm.temporaryDirectory.appendingPathComponent("adev-clone-cfg-\(UUID().uuidString)")
        defer { try? fm.removeItem(at: root) }
        let nested = root.appendingPathComponent(".devcontainer")
        try fm.createDirectory(at: nested, withIntermediateDirectories: true)
        try #"{ "image": "alpine:3.20" }"#.write(
            to: nested.appendingPathComponent("devcontainer.json"),
            atomically: true,
            encoding: .utf8
        )
        let without = try ConfigResolver.resolve(workspacePath: root.path, localEnv: [:])
        try MiniTest.expectEqual(
            without.config.workspaceFolder,
            "/workspaces/\(root.lastPathComponent)"
        )
        let with = try ConfigResolver.resolve(
            workspacePath: root.path,
            localEnv: [:],
            workspaceFolderBasename: "my-repo"
        )
        try MiniTest.expectEqual(with.config.workspaceFolder, "/workspaces/my-repo")
    }),
    ("cloneTempCleanupOnPopulateFailure", {
        let restore = CloneGitFeatureTestSupport.installOverrides()
        defer { restore() }
        let git = MockGitClient()
        git.configJSONToWrite = #"{ "image": "alpine:3.20" }"#
        var capturedConfigDir: String?
        git.fetchConfigHandler = { _, dir in
            capturedConfigDir = dir
            try FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
            let nested = (dir as NSString).appendingPathComponent(".devcontainer")
            try FileManager.default.createDirectory(atPath: nested, withIntermediateDirectories: true)
            try #"{ "image": "alpine:3.20" }"#.write(
                toFile: (nested as NSString).appendingPathComponent("devcontainer.json"),
                atomically: true,
                encoding: .utf8
            )
        }
        let mock = MockProcessRunner()
        mock.handlers = CloneRuntimeMock.handlers(cloneExecSucceeds: false)
        let runtime = AppleContainerRuntime(executablePath: "/usr/local/bin/container", runner: mock)
        try MiniTest.expectThrows({
            _ = try CloneCommand.run(
                options: CloneOptions(gitURL: "https://example.com/fail.git", skipPull: true),
                runtime: runtime,
                git: git,
                credentials: MockGitCredential(),
                localEnv: [:]
            )
        }) { error in
            try MiniTest.expectEqual((error as! CLIError).code, CLIErrorCode.populateFailed)
        }
        try MiniTest.expect(mock.calls.contains { $0.arguments.first == "delete" })
        try MiniTest.expect(mock.calls.contains { $0.arguments.starts(with: ["volume", "delete"]) })
        try MiniTest.expect(git.fullCloneCalls.isEmpty)
        if let d = capturedConfigDir {
            try MiniTest.expect(!FileManager.default.fileExists(atPath: d))
        }
    }),
    ("clonePopulateVerifyFailsWhenGitMissing", {
        let restore = CloneGitFeatureTestSupport.installOverrides()
        defer { restore() }
        let git = MockGitClient()
        git.configJSONToWrite = #"{ "image": "alpine:3.20" }"#
        let mock = MockProcessRunner()
        mock.handlers = CloneRuntimeMock.handlers(verifyGitExists: false)
        let runtime = AppleContainerRuntime(executablePath: "/usr/local/bin/container", runner: mock)
        try MiniTest.expectThrows({
            _ = try CloneCommand.run(
                options: CloneOptions(gitURL: "https://example.com/empty-vol.git", skipPull: true),
                runtime: runtime,
                git: git,
                credentials: MockGitCredential(),
                localEnv: [:]
            )
        }) { error in
            let err = error as! CLIError
            try MiniTest.expectEqual(err.code, CLIErrorCode.populateFailed)
            try MiniTest.expect(err.message.lowercased().contains("empty") || err.message.contains("missing") || err.message.contains(".git"))
        }
        try MiniTest.expect(mock.calls.contains { $0.arguments.first == "delete" })
        try MiniTest.expect(mock.calls.contains { $0.arguments.starts(with: ["volume", "delete"]) })
    }),
    ("cloneRunsInitializeCommandOnHostCheckout", {
        let restore = CloneGitFeatureTestSupport.installOverrides()
        defer { restore() }
        let git = MockGitClient()
        git.configJSONToWrite = """
        {
          "image": "alpine:3.20",
          "initializeCommand": "echo init-clone"
        }
        """
        var events: [String] = []
        let host = RecordingHostProcessRunner()
        host.handler = { _ in
            events.append("initialize")
            return ProcessResult(exitCode: 0, stdout: Data(), stderr: Data())
        }
        let restoreHost = RecordingHostProcessRunner.install(host)
        defer { restoreHost() }
        let mock = MockProcessRunner()
        mock.handlers = CloneRuntimeMock.handlers(onCreate: { args in
            if args.first == "create" {
                events.append("create")
            }
        })
        let runtime = AppleContainerRuntime(executablePath: "/usr/local/bin/container", runner: mock)
        let result = try CloneCommand.run(
            options: CloneOptions(gitURL: "https://github.com/org/init-clone.git", skipPull: true),
            runtime: runtime,
            git: git,
            credentials: MockGitCredential(),
            localEnv: [:]
        )
        try MiniTest.expectEqual(result.outcome, "success")
        try MiniTest.expect(events.contains("initialize"))
        try MiniTest.expect(events.contains("create"))
        try MiniTest.expectEqual(events.first, "initialize")
        let initIdx = events.firstIndex(of: "initialize")!
        let createIdx = events.firstIndex(of: "create")!
        try MiniTest.expect(initIdx < createIdx, "initializeCommand must run before create")
        try MiniTest.expectEqual(host.calls.count, 1)
        try MiniTest.expect(host.calls[0].arguments.contains("echo init-clone"))
        let checkout = git.fetchConfigCalls[0].directory
        try MiniTest.expectEqual(
            (host.calls[0].currentDirectory as NSString?)?.standardizingPath,
            (checkout as NSString).standardizingPath
        )
    }),
    ("cloneHookFailureDeletesContainer", {
        let restore = CloneGitFeatureTestSupport.installOverrides()
        defer { restore() }
        let git = MockGitClient()
        git.configJSONToWrite = """
        { "image": "alpine:3.20", "postCreateCommand": "false" }
        """
        let mock = MockProcessRunner()
        mock.handlers = CloneRuntimeMock.handlers(hookExecSucceeds: false)
        let runtime = AppleContainerRuntime(executablePath: "/usr/local/bin/container", runner: mock)
        try MiniTest.expectThrows({
            _ = try CloneCommand.run(
                options: CloneOptions(gitURL: "https://example.com/hooks.git", skipPull: true),
                runtime: runtime,
                git: git,
                credentials: MockGitCredential(),
                localEnv: [:]
            )
        }) { error in
            let err = error as! CLIError
            try MiniTest.expect(
                err.code == CLIErrorCode.postCreateFailed || err.code == CLIErrorCode.lifecycleFailed
            )
        }
        try MiniTest.expect(mock.calls.contains { $0.arguments.first == "delete" })
        try MiniTest.expect(mock.calls.contains { $0.arguments.starts(with: ["volume", "delete"]) })
    }),
    ("cloneRunsPostAttachWithoutVSCode", {
        let restore = CloneGitFeatureTestSupport.installOverrides()
        defer { restore() }
        let git = MockGitClient()
        git.configJSONToWrite = """
        {
          "image": "alpine:3.20",
          "postCreateCommand": "echo postCreate",
          "postAttachCommand": "echo clone-attach"
        }
        """
        var hookBodies: [String] = []
        let mock = MockProcessRunner()
        let baseHandlers = CloneRuntimeMock.handlers()
        mock.handlers = [
            { args in
                if args.first == "exec",
                   let lc = args.firstIndex(of: "-lc"),
                   lc + 1 < args.count
                {
                    hookBodies.append(args[lc + 1])
                }
                for h in baseHandlers {
                    if let r = h(args) { return r }
                }
                return nil
            }
        ]
        let launcher = MockVSCodeLauncher()
        let prevLauncher = VSCodeOpen.launcherOverride
        let prevResolver = VSCodeOpen.resolverOverride
        VSCodeOpen.launcherOverride = launcher
        VSCodeOpen.resolverOverride = MockVSCodeResolver(path: "/opt/code")
        defer {
            VSCodeOpen.launcherOverride = prevLauncher
            VSCodeOpen.resolverOverride = prevResolver
        }
        let runtime = AppleContainerRuntime(executablePath: "/usr/local/bin/container", runner: mock)
        let result = try CloneCommand.run(
            options: CloneOptions(
                gitURL: "https://github.com/org/clone-pa-novsc.git",
                skipPull: true,
                openVSCode: false
            ),
            runtime: runtime,
            git: git,
            credentials: MockGitCredential(),
            localEnv: [:]
        )
        try MiniTest.expectEqual(result.outcome, "success")
        try MiniTest.expectEqual(launcher.calls.count, 0)
        try MiniTest.expect(hookBodies.contains("echo clone-attach"))
        try MiniTest.expect(hookBodies.contains("echo postCreate"))
        try MiniTest.expect(!FileManager.default.fileExists(atPath: git.fetchConfigCalls[0].directory))
        try MiniTest.expect(!mock.calls.contains { $0.arguments.first == "delete" })
    }),
    ("clonePostAttachRunsWhenOpenSoftFails", {
        let restore = CloneGitFeatureTestSupport.installOverrides()
        defer { restore() }
        let git = MockGitClient()
        git.configJSONToWrite = """
        {
          "image": "alpine:3.20",
          "postAttachCommand": "echo clone-attach"
        }
        """
        var hookBodies: [String] = []
        let mock = MockProcessRunner()
        let baseHandlers = CloneRuntimeMock.handlers()
        mock.handlers = [
            { args in
                if args.first == "exec",
                   let lc = args.firstIndex(of: "-lc"),
                   lc + 1 < args.count
                {
                    hookBodies.append(args[lc + 1])
                }
                for h in baseHandlers {
                    if let r = h(args) { return r }
                }
                return nil
            }
        ]
        let launcher = MockVSCodeLauncher()
        let prevLauncher = VSCodeOpen.launcherOverride
        let prevResolver = VSCodeOpen.resolverOverride
        VSCodeOpen.launcherOverride = launcher
        VSCodeOpen.resolverOverride = MockVSCodeResolver(path: nil)
        defer {
            VSCodeOpen.launcherOverride = prevLauncher
            VSCodeOpen.resolverOverride = prevResolver
        }
        let runtime = AppleContainerRuntime(executablePath: "/usr/local/bin/container", runner: mock)
        let result = try CloneCommand.run(
            options: CloneOptions(
                gitURL: "https://github.com/org/clone-pa-soft-vol.git",
                skipPull: true,
                openVSCode: true
            ),
            runtime: runtime,
            git: git,
            credentials: MockGitCredential(),
            localEnv: [:]
        )
        try MiniTest.expectEqual(result.outcome, "success")
        try MiniTest.expect(hookBodies.contains("echo clone-attach"))
        try MiniTest.expect(!mock.calls.contains { $0.arguments.first == "delete" })
        try MiniTest.expect(!FileManager.default.fileExists(atPath: git.fetchConfigCalls[0].directory))
    }),
    ("cloneInjectsGitFeatureWhenConfigHasNone", {
        let restore = CloneGitFeatureTestSupport.installOverrides()
        defer { restore() }
        let git = MockGitClient()
        git.configJSONToWrite = #"{ "image": "alpine:3.20" }"#
        let mock = MockProcessRunner()
        var createImage: String?
        mock.handlers = CloneRuntimeMock.handlers(onCreate: { args in
            if args.first == "create", let img = args.last, !img.hasPrefix("-") {
                createImage = img
            }
        })
        let runtime = AppleContainerRuntime(executablePath: "/usr/local/bin/container", runner: mock)
        let result = try CloneCommand.run(
            options: CloneOptions(gitURL: "https://github.com/org/no-features.git", skipPull: true),
            runtime: runtime,
            git: git,
            credentials: MockGitCredential(),
            localEnv: [:]
        )
        try MiniTest.expectEqual(result.outcome, "success")
        let fetcher = CloneCommand.featuresFetcherOverride as? MockFeatureFetcher
        try MiniTest.expectEqual(fetcher?.fetchCalls.count, 1)
        try MiniTest.expect(createImage != nil)
        try MiniTest.expect(createImage != "alpine:3.20")
    }),
    ("cloneDoesNotDoubleAddWhenGitFeaturePresent", {
        let gitRef = "ghcr.io/devcontainers/features/git:1"
        let restore = CloneGitFeatureTestSupport.installOverrides()
        defer { restore() }
        let git = MockGitClient()
        git.configJSONToWrite = """
        {
          "image": "alpine:3.20",
          "features": { "\(gitRef)": {} }
        }
        """
        let mock = MockProcessRunner()
        mock.handlers = CloneRuntimeMock.handlers()
        let runtime = AppleContainerRuntime(executablePath: "/usr/local/bin/container", runner: mock)
        let result = try CloneCommand.run(
            options: CloneOptions(gitURL: "https://github.com/org/has-git.git", skipPull: true),
            runtime: runtime,
            git: git,
            credentials: MockGitCredential(),
            localEnv: [:]
        )
        try MiniTest.expectEqual(result.outcome, "success")
        let fetcher = CloneCommand.featuresFetcherOverride as? MockFeatureFetcher
        try MiniTest.expectEqual(fetcher?.fetchCalls.count, 1)
    }),
    ("cloneDoesNotInjectWhenCommonUtilsPresent", {
        let cuRef = "ghcr.io/devcontainers/features/common-utils:2"
        let cuFixture = TestRepo.root()
            .appendingPathComponent("Tests/Fixtures/features-sample/git").path
        let restore = CloneGitFeatureTestSupport.installOverrides(extraPackages: [cuRef: cuFixture])
        defer { restore() }
        let git = MockGitClient()
        git.configJSONToWrite = """
        {
          "image": "alpine:3.20",
          "features": { "\(cuRef)": {} }
        }
        """
        let mock = MockProcessRunner()
        mock.handlers = CloneRuntimeMock.handlers()
        let runtime = AppleContainerRuntime(executablePath: "/usr/local/bin/container", runner: mock)
        let result = try CloneCommand.run(
            options: CloneOptions(gitURL: "https://github.com/org/has-cu.git", skipPull: true),
            runtime: runtime,
            git: git,
            credentials: MockGitCredential(),
            localEnv: [:]
        )
        try MiniTest.expectEqual(result.outcome, "success")
        let fetcher = CloneCommand.featuresFetcherOverride as? MockFeatureFetcher
        try MiniTest.expectEqual(fetcher?.fetchCalls.count, 1)
    }),
    ("cloneAppliesLocalGitAuthorWhenResolved", {
        let restore = CloneGitFeatureTestSupport.installOverrides()
        defer { restore() }
        let git = MockGitClient()
        git.configJSONToWrite = #"{ "image": "alpine:3.20" }"#
        git.resolveAuthorIdentityResult = GitAuthorIdentity(name: "Ada Lovelace", email: "ada@example.com")
        let mock = MockProcessRunner()
        mock.handlers = CloneRuntimeMock.handlers()
        let runtime = AppleContainerRuntime(executablePath: "/usr/local/bin/container", runner: mock)
        let result = try CloneCommand.run(
            options: CloneOptions(gitURL: "https://github.com/org/author-ok.git", skipPull: true),
            runtime: runtime,
            git: git,
            credentials: MockGitCredential(),
            localEnv: [:]
        )
        try MiniTest.expectEqual(result.outcome, "success")
        try MiniTest.expectEqual(git.resolveAuthorIdentityCalls.count, 1)
        try MiniTest.expect(git.resolveAuthorIdentityCalls[0] == git.fetchConfigCalls[0].directory)
        let configCalls = mock.calls.filter {
            $0.arguments.first == "exec" && $0.arguments.contains("config") && $0.arguments.contains("--local")
        }
        try MiniTest.expectEqual(configCalls.count, 2)
        try MiniTest.expect(configCalls.contains {
            $0.arguments.contains("user.name") && $0.arguments.contains("Ada Lovelace")
        })
        try MiniTest.expect(configCalls.contains {
            $0.arguments.contains("user.email") && $0.arguments.contains("ada@example.com")
        })
        // No invented e2e identity
        try MiniTest.expect(!configCalls.contains {
            $0.arguments.contains(where: { $0.lowercased().contains("adevcontainer-e2e") })
        })
    }),
    ("cloneMissingAuthorEmailSkipsLocalConfig", {
        let restore = CloneGitFeatureTestSupport.installOverrides()
        defer { restore() }
        let git = MockGitClient()
        git.configJSONToWrite = #"{ "image": "alpine:3.20" }"#
        git.resolveAuthorIdentityResult = GitAuthorIdentity(name: "Only Name", email: nil)
        let mock = MockProcessRunner()
        mock.handlers = CloneRuntimeMock.handlers()
        let runtime = AppleContainerRuntime(executablePath: "/usr/local/bin/container", runner: mock)
        let result = try CloneCommand.run(
            options: CloneOptions(gitURL: "https://github.com/org/author-partial.git", skipPull: true),
            runtime: runtime,
            git: git,
            credentials: MockGitCredential(),
            localEnv: [:]
        )
        try MiniTest.expectEqual(result.outcome, "success")
        try MiniTest.expectEqual(git.resolveAuthorIdentityCalls.count, 1)
        let configCalls = mock.calls.filter {
            $0.arguments.first == "exec" && $0.arguments.contains("config") && $0.arguments.contains("--local")
        }
        try MiniTest.expect(configCalls.isEmpty)
    }),
    ("cloneAuthorEnvOverridesResolved", {
        let restore = CloneGitFeatureTestSupport.installOverrides()
        defer { restore() }
        let git = MockGitClient()
        git.configJSONToWrite = #"{ "image": "alpine:3.20" }"#
        git.resolveAuthorIdentityResult = GitAuthorIdentity(name: "Host", email: "host@example.com")
        let mock = MockProcessRunner()
        mock.handlers = CloneRuntimeMock.handlers()
        let runtime = AppleContainerRuntime(executablePath: "/usr/local/bin/container", runner: mock)
        let result = try CloneCommand.run(
            options: CloneOptions(gitURL: "https://github.com/org/author-env.git", skipPull: true),
            runtime: runtime,
            git: git,
            credentials: MockGitCredential(),
            localEnv: [
                "ADEVCONTAINER_GIT_AUTHOR_NAME": "Env User",
                "ADEVCONTAINER_GIT_AUTHOR_EMAIL": "env@example.com"
            ]
        )
        try MiniTest.expectEqual(result.outcome, "success")
        let configCalls = mock.calls.filter {
            $0.arguments.first == "exec" && $0.arguments.contains("config") && $0.arguments.contains("--local")
        }
        try MiniTest.expect(configCalls.contains {
            $0.arguments.contains("user.name") && $0.arguments.contains("Env User")
        })
        try MiniTest.expect(configCalls.contains {
            $0.arguments.contains("user.email") && $0.arguments.contains("env@example.com")
        })
    }),
    ("cloneAuthorTTYKeepResolved", {
        let restore = CloneGitFeatureTestSupport.installOverrides()
        defer { restore() }
        let git = MockGitClient()
        git.configJSONToWrite = #"{ "image": "alpine:3.20" }"#
        git.resolveAuthorIdentityResult = GitAuthorIdentity(name: "Ada Lovelace", email: "ada@example.com")
        let mock = MockProcessRunner()
        mock.handlers = CloneRuntimeMock.handlers()
        let runtime = AppleContainerRuntime(executablePath: "/usr/local/bin/container", runner: mock)
        final class Lines: @unchecked Sendable {
            var answers = ["y"]
            var readCount = 0
            func next() -> String? {
                readCount += 1
                return answers.isEmpty ? nil : answers.removeFirst()
            }
        }
        let lines = Lines()
        let prompt = IdentityPrompt(
            isInteractive: true,
            readLine: { lines.next() },
            writeError: { _ in }
        )
        let result = try CloneCommand.run(
            options: CloneOptions(gitURL: "https://github.com/org/author-tty-keep.git", skipPull: true),
            runtime: runtime,
            git: git,
            credentials: MockGitCredential(),
            localEnv: [:],
            identityPrompt: prompt
        )
        try MiniTest.expectEqual(result.outcome, "success")
        try MiniTest.expectEqual(lines.readCount, 1)
        let configCalls = mock.calls.filter {
            $0.arguments.first == "exec" && $0.arguments.contains("config") && $0.arguments.contains("--local")
        }
        try MiniTest.expect(configCalls.contains {
            $0.arguments.contains("user.name") && $0.arguments.contains("Ada Lovelace")
        })
        try MiniTest.expect(configCalls.contains {
            $0.arguments.contains("user.email") && $0.arguments.contains("ada@example.com")
        })
    }),
    ("cloneAuthorTTYDeclineCustom", {
        let restore = CloneGitFeatureTestSupport.installOverrides()
        defer { restore() }
        let git = MockGitClient()
        git.configJSONToWrite = #"{ "image": "alpine:3.20" }"#
        git.resolveAuthorIdentityResult = GitAuthorIdentity(name: "Host", email: "host@example.com")
        let mock = MockProcessRunner()
        mock.handlers = CloneRuntimeMock.handlers()
        let runtime = AppleContainerRuntime(executablePath: "/usr/local/bin/container", runner: mock)
        final class Lines: @unchecked Sendable {
            var answers = ["n", "Custom User", "custom@example.com"]
            func next() -> String? {
                answers.isEmpty ? nil : answers.removeFirst()
            }
        }
        let lines = Lines()
        let prompt = IdentityPrompt(
            isInteractive: true,
            readLine: { lines.next() },
            writeError: { _ in }
        )
        let result = try CloneCommand.run(
            options: CloneOptions(gitURL: "https://github.com/org/author-tty-custom.git", skipPull: true),
            runtime: runtime,
            git: git,
            credentials: MockGitCredential(),
            localEnv: [:],
            identityPrompt: prompt
        )
        try MiniTest.expectEqual(result.outcome, "success")
        let configCalls = mock.calls.filter {
            $0.arguments.first == "exec" && $0.arguments.contains("config") && $0.arguments.contains("--local")
        }
        try MiniTest.expect(configCalls.contains {
            $0.arguments.contains("user.name") && $0.arguments.contains("Custom User")
        })
        try MiniTest.expect(configCalls.contains {
            $0.arguments.contains("user.email") && $0.arguments.contains("custom@example.com")
        })
        try MiniTest.expect(!configCalls.contains {
            $0.arguments.contains("user.name") && $0.arguments.contains("Host")
        })
    }),
    ("cloneAuthorNonTTYUsesResolvedNoPrompt", {
        let restore = CloneGitFeatureTestSupport.installOverrides()
        defer { restore() }
        let git = MockGitClient()
        git.configJSONToWrite = #"{ "image": "alpine:3.20" }"#
        git.resolveAuthorIdentityResult = GitAuthorIdentity(name: "CI User", email: "ci@example.com")
        let mock = MockProcessRunner()
        mock.handlers = CloneRuntimeMock.handlers()
        let runtime = AppleContainerRuntime(executablePath: "/usr/local/bin/container", runner: mock)
        final class Counter: @unchecked Sendable { var readCount = 0 }
        let counter = Counter()
        let prompt = IdentityPrompt(
            isInteractive: false,
            readLine: {
                counter.readCount += 1
                return "should-not-be-read"
            },
            writeError: { _ in }
        )
        let result = try CloneCommand.run(
            options: CloneOptions(gitURL: "https://github.com/org/author-nontty.git", skipPull: true),
            runtime: runtime,
            git: git,
            credentials: MockGitCredential(),
            localEnv: [:],
            identityPrompt: prompt
        )
        try MiniTest.expectEqual(result.outcome, "success")
        try MiniTest.expectEqual(counter.readCount, 0)
        let configCalls = mock.calls.filter {
            $0.arguments.first == "exec" && $0.arguments.contains("config") && $0.arguments.contains("--local")
        }
        try MiniTest.expect(configCalls.contains {
            $0.arguments.contains("user.name") && $0.arguments.contains("CI User")
        })
    }),
    ("cloneAuthorEnvBothSkipsTTYPrompt", {
        let restore = CloneGitFeatureTestSupport.installOverrides()
        defer { restore() }
        let git = MockGitClient()
        git.configJSONToWrite = #"{ "image": "alpine:3.20" }"#
        git.resolveAuthorIdentityResult = GitAuthorIdentity(name: "Host", email: "host@example.com")
        let mock = MockProcessRunner()
        mock.handlers = CloneRuntimeMock.handlers()
        let runtime = AppleContainerRuntime(executablePath: "/usr/local/bin/container", runner: mock)
        final class Counter: @unchecked Sendable { var readCount = 0 }
        let counter = Counter()
        let prompt = IdentityPrompt(
            isInteractive: true,
            readLine: {
                counter.readCount += 1
                return "n"
            },
            writeError: { _ in }
        )
        let result = try CloneCommand.run(
            options: CloneOptions(gitURL: "https://github.com/org/author-env-skip.git", skipPull: true),
            runtime: runtime,
            git: git,
            credentials: MockGitCredential(),
            localEnv: [
                "ADEVCONTAINER_GIT_AUTHOR_NAME": "Env User",
                "ADEVCONTAINER_GIT_AUTHOR_EMAIL": "env@example.com"
            ],
            identityPrompt: prompt
        )
        try MiniTest.expectEqual(result.outcome, "success")
        try MiniTest.expectEqual(counter.readCount, 0)
        let configCalls = mock.calls.filter {
            $0.arguments.first == "exec" && $0.arguments.contains("config") && $0.arguments.contains("--local")
        }
        try MiniTest.expect(configCalls.contains {
            $0.arguments.contains("user.name") && $0.arguments.contains("Env User")
        })
        try MiniTest.expect(configCalls.contains {
            $0.arguments.contains("user.email") && $0.arguments.contains("env@example.com")
        })
    }),
    ("clonePopulateRequestsStreamOutput", {
        let restore = CloneGitFeatureTestSupport.installOverrides()
        defer { restore() }
        let git = MockGitClient()
        git.configJSONToWrite = #"{ "image": "alpine:3.20", "workspaceFolder": "/workspaces/app" }"#
        let mock = MockProcessRunner()
        mock.handlers = CloneRuntimeMock.handlers()
        let runtime = AppleContainerRuntime(executablePath: "/usr/local/bin/container", runner: mock)
        _ = try CloneCommand.run(
            options: CloneOptions(gitURL: "https://github.com/org/stream-pop.git", skipPull: true),
            runtime: runtime,
            git: git,
            credentials: MockGitCredential(),
            localEnv: [:]
        )
        // In-container populate uses `sh -c` (not hooks' `sh -lc`) and must live-stream.
        let populateCalls = mock.calls.filter {
            $0.arguments.first == "exec"
                && $0.arguments.contains("sh")
                && $0.arguments.contains("-c")
                && !$0.arguments.contains("-lc")
        }
        try MiniTest.expect(!populateCalls.isEmpty, "expected populate sh -c exec")
        try MiniTest.expect(populateCalls.contains { $0.streamStderr == true })
        try MiniTest.expect(populateCalls.contains { $0.teeStdoutToStderr == true })
    }),
    ("clonePopulateFailureDiagnosticsRawUnframed", {
        let restore = CloneGitFeatureTestSupport.installOverrides()
        defer { restore() }
        let git = MockGitClient()
        git.configJSONToWrite = #"{ "image": "alpine:3.20", "workspaceFolder": "/workspaces/app" }"#
        let mock = MockProcessRunner()
        mock.handlers = CloneRuntimeMock.handlers(
            cloneExecSucceeds: false
        )
        // Override clone exec to include recognizable diagnostic mark.
        mock.handlers = [
            MockProcessRunner.imageInspectHandler(baseUser: nil),
            { args in
                if args.starts(with: ["list"]) || args.starts(with: ["volume", "list"]) {
                    let data = try! JSONSerialization.data(withJSONObject: [] as [Any])
                    return ProcessResult(exitCode: 0, stdout: data, stderr: Data())
                }
                if args.starts(with: ["image", "list"]) {
                    return ProcessResult(exitCode: 1, stdout: Data(), stderr: Data("missing".utf8))
                }
                if args.first == "build"
                    || args.starts(with: ["volume", "create"])
                    || args.starts(with: ["volume", "delete"])
                    || args.first == "start"
                    || args.first == "delete"
                {
                    return ProcessResult(exitCode: 0, stdout: Data(), stderr: Data())
                }
                if args.first == "create" {
                    return ProcessResult(exitCode: 0, stdout: Data("ctr\n".utf8), stderr: Data())
                }
                if args.first == "exec" {
                    if args.contains("-c") && !args.contains("-lc") {
                        return ProcessResult(
                            exitCode: 1,
                            stdout: Data(),
                            stderr: Data("TOOL_FAIL_MARK populate boom\n".utf8)
                        )
                    }
                    return ProcessResult(exitCode: 0, stdout: Data(), stderr: Data())
                }
                return nil
            }
        ]
        let runtime = AppleContainerRuntime(executablePath: "/usr/local/bin/container", runner: mock)
        try MiniTest.expectThrows({
            _ = try CloneCommand.run(
                options: CloneOptions(gitURL: "https://github.com/org/fail-pop.git", skipPull: true),
                runtime: runtime,
                git: git,
                credentials: MockGitCredential(),
                localEnv: [:]
            )
        }) { error in
            let err = error as! CLIError
            try MiniTest.expectEqual(err.code, CLIErrorCode.populateFailed)
            try MiniTest.expect(err.message.contains("TOOL_FAIL_MARK"))
            try MiniTest.expect(!err.message.contains("| TOOL_FAIL_MARK"))
            try MiniTest.expect(!err.message.contains("    | "))
        }
    }),
    ("clonePopulateQuietStillRequestsStream", {
        let restore = CloneGitFeatureTestSupport.installOverrides()
        defer { restore() }
        let previousEnabled = StatusPrinter.enabled
        defer { StatusPrinter.enabled = previousEnabled }
        StatusPrinter.enabled = false
        let git = MockGitClient()
        git.configJSONToWrite = #"{ "image": "alpine:3.20", "workspaceFolder": "/workspaces/app" }"#
        let mock = MockProcessRunner()
        mock.handlers = CloneRuntimeMock.handlers()
        let runtime = AppleContainerRuntime(executablePath: "/usr/local/bin/container", runner: mock)
        _ = try CloneCommand.run(
            options: CloneOptions(gitURL: "https://github.com/org/quiet-pop.git", skipPull: true),
            runtime: runtime,
            git: git,
            credentials: MockGitCredential(),
            localEnv: [:]
        )
        let populateCalls = mock.calls.filter {
            $0.arguments.first == "exec"
                && $0.arguments.contains("sh")
                && $0.arguments.contains("-c")
                && !$0.arguments.contains("-lc")
        }
        try MiniTest.expect(populateCalls.contains { $0.streamStderr == true && $0.teeStdoutToStderr == true })
    }),
    ("cloneFailsClosedOnSameWorkspaceSameName", {
        let restore = CloneGitFeatureTestSupport.installOverrides()
        defer { restore() }
        let git = MockGitClient()
        git.configJSONToWrite = #"{ "name": "My App", "image": "alpine:3.20" }"#
        let identity = ContainerIdentity.volumeModeIdentity(
            gitURL: "https://github.com/org/sample-repo.git",
            configRelativePath: ".devcontainer/devcontainer.json",
            configName: "My App"
        )
        try MiniTest.expectEqual(identity.containerName, "my-app")
        let entry = MockProcessRunner.containerListJSON(
            id: "my-app",
            state: "running",
            labels: ContainerIdentity.volumeModeLabels(
                identity: identity,
                configHash: "h"
            )
        )
        let mock = MockProcessRunner()
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
        ] + CloneRuntimeMock.handlers()
        let runtime = AppleContainerRuntime(executablePath: "/usr/local/bin/container", runner: mock)
        try MiniTest.expectThrows({
            _ = try CloneCommand.run(
                options: CloneOptions(gitURL: "https://github.com/org/sample-repo.git", skipPull: true),
                runtime: runtime,
                git: git,
                credentials: MockGitCredential(),
                localEnv: [:],
                isTTY: true,
                openEditorPrompt: RecoveryOpenEditorPrompt(readLine: { "y" })
            )
        }) { error in
            let err = error as! CLIError
            try MiniTest.expectEqual(err.code, CLIErrorCode.workspaceContainerExists)
            try MiniTest.expect(err.message.contains("my-app"))
        }
        try MiniTest.expect(!mock.calls.contains { $0.arguments.first == "create" })
        try MiniTest.expect(!mock.calls.contains { $0.arguments.first == "delete" })
    }),
    ("cloneSameWorkspaceDifferentNameIsDeleteHint", {
        let restore = CloneGitFeatureTestSupport.installOverrides()
        defer { restore() }
        let git = MockGitClient()
        git.configJSONToWrite = #"{ "name": "My App", "image": "alpine:3.20" }"#
        let identity = ContainerIdentity.volumeModeIdentity(
            gitURL: "https://github.com/org/sample-repo.git",
            configRelativePath: ".devcontainer/devcontainer.json",
            configName: "My App"
        )
        var labels = ContainerIdentity.volumeModeLabels(identity: identity, configHash: "h")
        let leftover = MockProcessRunner.containerListJSON(
            id: "adev-my-app-abc123def456",
            state: "running",
            labels: labels
        )
        let mock = MockProcessRunner()
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
        ] + CloneRuntimeMock.handlers()
        let runtime = AppleContainerRuntime(executablePath: "/usr/local/bin/container", runner: mock)
        try MiniTest.expectThrows({
            _ = try CloneCommand.run(
                options: CloneOptions(gitURL: "https://github.com/org/sample-repo.git", skipPull: true),
                runtime: runtime,
                git: git,
                credentials: MockGitCredential(),
                localEnv: [:],
                isTTY: true,
                openEditorPrompt: RecoveryOpenEditorPrompt(readLine: { "y" })
            )
        }) { error in
            let err = error as! CLIError
            try MiniTest.expectEqual(err.code, CLIErrorCode.workspaceContainerExists)
            try MiniTest.expect(err.message.contains("adev-my-app-abc123def456"))
            try MiniTest.expect(err.hint?.contains("delete") == true)
        }
        try MiniTest.expect(!mock.calls.contains { $0.arguments.first == "create" })
        try MiniTest.expect(!mock.calls.contains { $0.arguments.first == "delete" })
        _ = labels
    }),
    ("cloneForeignOccupantOffersCollisionRecovery", {
        let restore = CloneGitFeatureTestSupport.installOverrides()
        defer { restore() }
        let git = MockGitClient()
        git.configJSONToWrite = #"{ "name": "My App", "image": "alpine:3.20" }"#
        let other = ContainerIdentity.volumeModeIdentity(
            gitURL: "https://github.com/other/repo.git",
            configRelativePath: ".devcontainer/devcontainer.json",
            configName: "My App"
        )
        let occupant = MockProcessRunner.containerListJSON(
            id: "my-app",
            state: "running",
            labels: ContainerIdentity.volumeModeLabels(identity: other, configHash: "h")
        )
        let mock = MockProcessRunner()
        mock.handlers = [
            { args in
                if args.starts(with: ["list"]) {
                    return ProcessResult(
                        exitCode: 0,
                        stdout: try! JSONSerialization.data(withJSONObject: [occupant]),
                        stderr: Data()
                    )
                }
                return nil
            }
        ] + CloneRuntimeMock.handlers()
        let runtime = AppleContainerRuntime(executablePath: "/usr/local/bin/container", runner: mock)
        try MiniTest.expectThrows({
            _ = try CloneCommand.run(
                options: CloneOptions(gitURL: "https://github.com/org/sample-repo.git", skipPull: true),
                runtime: runtime,
                git: git,
                credentials: MockGitCredential(),
                localEnv: [:],
                isTTY: false
            )
        }) { error in
            let err = error as! CLIError
            try MiniTest.expectEqual(err.code, CLIErrorCode.containerNameInUse)
            try MiniTest.expect(err.message.contains("my-app"))
            try MiniTest.expect(err.message.lowercased().contains("not this workspace"))
        }
        try MiniTest.expect(!mock.calls.contains { $0.arguments.first == "create" })
        try MiniTest.expect(!mock.calls.contains { $0.arguments.first == "delete" })
    }),
]

// MARK: - List / start / stop / prune

nonisolated(unsafe) let managedLifecycleTests: [(String, () throws -> Void)] = [
    ("listShowsOnlyManaged", {
        let mock = MockProcessRunner()
        let managed = MockProcessRunner.containerListJSON(
            id: "adev-app-aaaabbbbcccc",
            state: "running",
            labels: [
                ContainerIdentity.labelManaged: ContainerIdentity.managedValue,
                ContainerIdentity.labelGitURL: "https://github.com/org/app",
                ContainerIdentity.labelWorkspaceMode: "volume"
            ]
        )
        let unlabeled = MockProcessRunner.containerListJSON(
            id: "adev-other-ddddeeeeffff",
            state: "running",
            labels: [ContainerIdentity.labelLocalFolder: "/Projects/other"]
        )
        mock.handlers = [
            { args in
                if args.starts(with: ["list"]) {
                    let data = try! JSONSerialization.data(withJSONObject: [managed, unlabeled])
                    return ProcessResult(exitCode: 0, stdout: data, stderr: Data())
                }
                return nil
            }
        ]
        let runtime = AppleContainerRuntime(executablePath: "/usr/local/bin/container", runner: mock)
        let table = try ListCommand.run(options: ListOptions(jsonOutput: false), runtime: runtime)
        try MiniTest.expect(table.contains("adev-app-aaaabbbbcccc"))
        try MiniTest.expect(!table.contains("adev-other-ddddeeeeffff"))
        let json = try ListCommand.run(options: ListOptions(jsonOutput: true), runtime: runtime)
        let arr = try JSONSerialization.jsonObject(with: Data(json.utf8)) as! [[String: Any]]
        try MiniTest.expectEqual(arr.count, 1)
        try MiniTest.expectEqual(arr[0]["id"] as? String, "adev-app-aaaabbbbcccc")
        try MiniTest.expectEqual(arr[0]["gitUrl"] as? String, "https://github.com/org/app")
    }),
    ("listMarksRecoveryHelperHumanAndJSON", {
        let mock = MockProcessRunner()
        let helper = MockProcessRunner.containerListJSON(
            id: "adev-recovery-helper",
            state: "running",
            labels: [
                ContainerIdentity.labelManaged: ContainerIdentity.managedValue,
                ContainerIdentity.labelWorkspaceMode: ContainerIdentity.workspaceModeVolume,
                RecoveryHelper.recoveryMarkerLabel: RecoveryHelper.recoveryMarkerValue,
                RecoveryHelper.recoverySessionLabel: "list-session"
            ],
            image: RecoveryHelper.helperImageReference
        )
        mock.handlers = [{ args in
            guard args.starts(with: ["list"]) else { return nil }
            return ProcessResult(
                exitCode: 0,
                stdout: try! JSONSerialization.data(withJSONObject: [helper]),
                stderr: Data()
            )
        }]
        let runtime = AppleContainerRuntime(executablePath: "/usr/local/bin/container", runner: mock)
        let table = try ListCommand.run(options: ListOptions(jsonOutput: false), runtime: runtime)
        try MiniTest.expect(table.contains("adev-recovery-helper [RECOVERY]"))
        let json = try ListCommand.run(options: ListOptions(jsonOutput: true), runtime: runtime)
        let rows = try JSONSerialization.jsonObject(with: Data(json.utf8)) as! [[String: Any]]
        let labels = rows.first?["labels"] as? [String: String]
        try MiniTest.expectEqual(labels?[RecoveryHelper.recoveryMarkerLabel], RecoveryHelper.recoveryMarkerValue)
    }),
    ("startStoppedManagedRunsPostStart", {
        let configJSON = """
        {
          "image": "alpine:3.20",
          "onCreateCommand": "echo onCreate",
          "updateContentCommand": "echo updateContent",
          "postCreateCommand": "echo postCreate",
          "postStartCommand": "echo config-postStart"
        }
        """
        let labels: [String: String] = [
            ContainerIdentity.labelManaged: ContainerIdentity.managedValue,
            ContainerIdentity.labelWorkspaceMode: ContainerIdentity.workspaceModeVolume,
            ContainerIdentity.labelLocalFolder: "volume://adev-app-ws",
            ContainerIdentity.labelConfigFile: ".devcontainer/devcontainer.json",
            ContainerIdentity.labelWorkspaceFolder: "/workspaces/app",
            DevContainerMetadataLabel.labelKey: #"{"postStartCommand":"echo feature-postStart"}"#
        ]
        let entry = MockProcessRunner.containerListJSON(
            id: "adev-app-aaaabbbbcccc",
            state: "stopped",
            labels: labels,
            image: "alpine:3.20"
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
                if args.first == "inspect" {
                    let data = try! JSONSerialization.data(withJSONObject: entry)
                    return ProcessResult(exitCode: 0, stdout: data, stderr: Data())
                }
                if args.first == "exec" {
                    if args.contains("cat") && !args.contains(LifecycleRunner.userEnvProbeScript) {
                        return ProcessResult(exitCode: 0, stdout: Data(configJSON.utf8), stderr: Data())
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
        try StartCommand.run(
            options: StartOptions(name: "adev-app-aaaabbbbcccc"),
            runtime: runtime
        )
        try MiniTest.expect(mock.calls.contains { $0.arguments == ["start", "adev-app-aaaabbbbcccc"] })
        try MiniTest.expectEqual(execBodies, ["echo config-postStart", "echo feature-postStart"])
        try MiniTest.expect(!execBodies.contains("echo onCreate"))
        try MiniTest.expect(!execBodies.contains("echo updateContent"))
        try MiniTest.expect(!execBodies.contains("echo postCreate"))
        try MiniTest.expect(!mock.calls.contains { $0.arguments.first == "create" })
    }),
    ("volumeModeStartWithoutHostWorkspaceSkipsInitializeCommand", {
        let host = RecordingHostProcessRunner()
        let restoreHost = RecordingHostProcessRunner.install(host)
        defer { restoreHost() }
        let previous = StatusPrinter.onWarning
        var warnings: [String] = []
        StatusPrinter.onWarning = { warnings.append($0) }
        defer { StatusPrinter.onWarning = previous }
        let configJSON = """
        { "image": "alpine:3.20", "initializeCommand": "echo init-volume" }
        """
        let labels: [String: String] = [
            ContainerIdentity.labelManaged: ContainerIdentity.managedValue,
            ContainerIdentity.labelWorkspaceMode: ContainerIdentity.workspaceModeVolume,
            ContainerIdentity.labelLocalFolder: "volume://adev-app-ws",
            ContainerIdentity.labelConfigFile: ".devcontainer/devcontainer.json",
            ContainerIdentity.labelWorkspaceFolder: "/workspaces/app"
        ]
        let entry = MockProcessRunner.containerListJSON(
            id: "adev-app-aaaabbbbcccc",
            state: "stopped",
            labels: labels
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
                if args.first == "inspect" {
                    let data = try! JSONSerialization.data(withJSONObject: entry)
                    return ProcessResult(exitCode: 0, stdout: data, stderr: Data())
                }
                if args.first == "exec", args.contains("cat") {
                    return ProcessResult(exitCode: 0, stdout: Data(configJSON.utf8), stderr: Data())
                }
                return nil
            }
        ]
        let runtime = AppleContainerRuntime(executablePath: "/usr/local/bin/container", runner: mock)
        try StartCommand.run(
            options: StartOptions(name: "adev-app-aaaabbbbcccc"),
            runtime: runtime
        )
        try MiniTest.expect(mock.calls.contains { $0.arguments.first == "start" })
        try MiniTest.expect(host.calls.isEmpty, "volume-mode start must not run host initialize")
        try MiniTest.expect(
            warnings.contains { $0.lowercased().contains("initializecommand") && $0.lowercased().contains("host") },
            "must warn that the host command cannot run"
        )
        try MiniTest.expect(!mock.calls.contains { $0.arguments.first == "create" })
    }),
    ("volumeModeStartDoesNotInitializeAfterStartWhenGuestConfigBecomesReadable", {
        // Clone-origin: usable host checkout exists, but guest config is only
        // readable after start. Initialize after start would violate
        // initialize-before-start / failure-must-not-start.
        let ws = try TestRepo.makeTempWorkspace(configJSON: """
        { "image": "alpine:3.20" }
        """)
        defer { try? FileManager.default.removeItem(at: ws) }
        let host = RecordingHostProcessRunner()
        let restoreHost = RecordingHostProcessRunner.install(host)
        defer { restoreHost() }
        let configJSON = """
        {
          "image": "alpine:3.20",
          "initializeCommand": "echo init-after-start",
          "postStartCommand": "echo config-postStart"
        }
        """
        let labels: [String: String] = [
            ContainerIdentity.labelManaged: ContainerIdentity.managedValue,
            ContainerIdentity.labelWorkspaceMode: ContainerIdentity.workspaceModeVolume,
            ContainerIdentity.labelLocalFolder: ws.path,
            ContainerIdentity.labelConfigFile: ".devcontainer/devcontainer.json",
            ContainerIdentity.labelWorkspaceFolder: "/workspaces/app"
        ]
        let entry = MockProcessRunner.containerListJSON(
            id: "adev-app-aaaabbbbcccc",
            state: "stopped",
            labels: labels,
            image: "alpine:3.20"
        )
        var started = false
        var execBodies: [String] = []
        let mock = MockProcessRunner()
        mock.handlers = [
            { args in
                if args.starts(with: ["list"]) {
                    let data = try! JSONSerialization.data(withJSONObject: [entry])
                    return ProcessResult(exitCode: 0, stdout: data, stderr: Data())
                }
                if args.first == "start" {
                    started = true
                    return ProcessResult(exitCode: 0, stdout: Data(), stderr: Data())
                }
                if args.first == "inspect" {
                    let data = try! JSONSerialization.data(withJSONObject: [entry])
                    return ProcessResult(exitCode: 0, stdout: data, stderr: Data())
                }
                if args.first == "exec" {
                    if args.contains("cat") && !args.contains(LifecycleRunner.userEnvProbeScript) {
                        if !started {
                            return ProcessResult(
                                exitCode: 1,
                                stdout: Data(),
                                stderr: Data("container not running".utf8)
                            )
                        }
                        return ProcessResult(exitCode: 0, stdout: Data(configJSON.utf8), stderr: Data())
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
        try StartCommand.run(
            options: StartOptions(name: "adev-app-aaaabbbbcccc"),
            runtime: runtime
        )
        try MiniTest.expect(mock.calls.contains { $0.arguments.first == "start" })
        try MiniTest.expect(
            host.calls.isEmpty,
            "must not run initialize after start when guest config becomes readable"
        )
        try MiniTest.expect(
            execBodies.contains("echo config-postStart"),
            "after-start remelt/postStart must still run"
        )
        try MiniTest.expect(!mock.calls.contains { $0.arguments.first == "create" })
    }),
    ("startAlreadyRunningNoOp", {
        let host = RecordingHostProcessRunner()
        let restoreHost = RecordingHostProcessRunner.install(host)
        defer { restoreHost() }
        let ws = try TestRepo.makeTempWorkspace(configJSON: """
        {
          "image": "alpine:3.20",
          "initializeCommand": "echo init-already-running",
          "postStartCommand": "echo postStart-already-running"
        }
        """)
        defer { try? FileManager.default.removeItem(at: ws) }
        let labels: [String: String] = [
            ContainerIdentity.labelManaged: ContainerIdentity.managedValue,
            ContainerIdentity.labelWorkspaceMode: ContainerIdentity.workspaceModeBind,
            ContainerIdentity.labelLocalFolder: ws.path,
            ContainerIdentity.labelConfigFile: ws.appendingPathComponent(".devcontainer/devcontainer.json").path,
            ContainerIdentity.labelWorkspaceFolder: "/workspaces/app"
        ]
        let entry = MockProcessRunner.containerListJSON(
            id: "adev-app-aaaabbbbcccc",
            state: "running",
            labels: labels
        )
        var execBodies: [String] = []
        let mock = MockProcessRunner()
        mock.handlers = [
            { args in
                if args.starts(with: ["list"]) {
                    let data = try! JSONSerialization.data(withJSONObject: [entry])
                    return ProcessResult(exitCode: 0, stdout: data, stderr: Data())
                }
                if args.first == "inspect" {
                    let data = try! JSONSerialization.data(withJSONObject: entry)
                    return ProcessResult(exitCode: 0, stdout: data, stderr: Data())
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
        try StartCommand.run(
            options: StartOptions(name: "adev-app-aaaabbbbcccc"),
            runtime: runtime
        )
        try MiniTest.expect(!mock.calls.contains { $0.arguments.first == "start" })
        try MiniTest.expect(host.calls.isEmpty, "already-running start must not run initialize")
        try MiniTest.expect(
            !execBodies.contains("echo postStart-already-running"),
            "already-running start must not run postStart"
        )
    }),
    ("startInteractivePickerWhenMultiple", {
        let mock = MockProcessRunner()
        let a = MockProcessRunner.containerListJSON(
            id: "adev-a-111111111111",
            state: "stopped",
            labels: [ContainerIdentity.labelManaged: ContainerIdentity.managedValue]
        )
        let b = MockProcessRunner.containerListJSON(
            id: "adev-b-222222222222",
            state: "stopped",
            labels: [ContainerIdentity.labelManaged: ContainerIdentity.managedValue]
        )
        mock.handlers = [
            { args in
                if args.starts(with: ["list"]) {
                    let data = try! JSONSerialization.data(withJSONObject: [a, b])
                    return ProcessResult(exitCode: 0, stdout: data, stderr: Data())
                }
                if args.first == "start" {
                    return ProcessResult(exitCode: 0, stdout: Data(), stderr: Data())
                }
                return nil
            }
        ]
        let runtime = AppleContainerRuntime(executablePath: "/usr/local/bin/container", runner: mock)
        let picker = InteractivePicker(
            isInteractive: true,
            readLine: { "2" },
            writeError: { _ in }
        )
        try StartCommand.run(options: StartOptions(name: nil), runtime: runtime, picker: picker)
        try MiniTest.expect(mock.calls.contains { $0.arguments == ["start", "adev-b-222222222222"] })
    }),
    ("startNonTTYMultiRequiresName", {
        let mock = MockProcessRunner()
        let a = MockProcessRunner.containerListJSON(
            id: "adev-a-111111111111",
            state: "stopped",
            labels: [ContainerIdentity.labelManaged: ContainerIdentity.managedValue]
        )
        let b = MockProcessRunner.containerListJSON(
            id: "adev-b-222222222222",
            state: "stopped",
            labels: [ContainerIdentity.labelManaged: ContainerIdentity.managedValue]
        )
        mock.handlers = [
            { args in
                if args.starts(with: ["list"]) {
                    let data = try! JSONSerialization.data(withJSONObject: [a, b])
                    return ProcessResult(exitCode: 0, stdout: data, stderr: Data())
                }
                return nil
            }
        ]
        let runtime = AppleContainerRuntime(executablePath: "/usr/local/bin/container", runner: mock)
        let picker = InteractivePicker(isInteractive: false, readLine: { nil }, writeError: { _ in })
        try MiniTest.expectThrows({
            try StartCommand.run(options: StartOptions(name: nil), runtime: runtime, picker: picker)
        }) { error in
            try MiniTest.expectEqual((error as! CLIError).code, CLIErrorCode.selectionRequired)
        }
    }),
    ("stopByNameManaged", {
        let mock = MockProcessRunner()
        let entry = MockProcessRunner.containerListJSON(
            id: "adev-app-aaaabbbbcccc",
            state: "running",
            labels: [ContainerIdentity.labelManaged: ContainerIdentity.managedValue]
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
        try StopCommand.run(name: "adev-app-aaaabbbbcccc", runtime: runtime)
        try MiniTest.expect(mock.calls.contains { $0.arguments == ["stop", "adev-app-aaaabbbbcccc"] })
    }),
    ("execByNameManagedRunning", {
        let mock = MockProcessRunner()
        let entry = MockProcessRunner.containerListJSON(
            id: "adev-app-aaaabbbbcccc",
            state: "running",
            labels: [
                ContainerIdentity.labelManaged: ContainerIdentity.managedValue,
                ContainerIdentity.labelWorkspaceFolder: "/workspaces/app",
                ContainerIdentity.labelRemoteUser: "vscode"
            ]
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
            options: ExecOptions(
                command: ["echo", "ok"],
                name: "adev-app-aaaabbbbcccc"
            ),
            runtime: runtime
        )
        try MiniTest.expectEqual(code, 0)
        let execCall = mock.calls.first { $0.arguments.first == "exec" }!
        try MiniTest.expect(execCall.arguments.contains("adev-app-aaaabbbbcccc"))
        try MiniTest.expect(execCall.arguments.contains("vscode"))
        try MiniTest.expect(execCall.arguments.contains("/workspaces/app"))
        try MiniTest.expect(execCall.arguments.contains("echo"))
    }),
    ("execByNameUnknown", {
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
                options: ExecOptions(
                    command: ["true"],
                    name: "adev-missing"
                ),
                runtime: runtime
            )
        }) { error in
            try MiniTest.expectEqual((error as! CLIError).code, CLIErrorCode.containerNotFound)
        }
    }),
    ("execByNameStopped", {
        let mock = MockProcessRunner()
        let entry = MockProcessRunner.containerListJSON(
            id: "adev-app-aaaabbbbcccc",
            state: "stopped",
            labels: [
                ContainerIdentity.labelManaged: ContainerIdentity.managedValue,
                ContainerIdentity.labelWorkspaceFolder: "/workspaces/app",
                ContainerIdentity.labelRemoteUser: "vscode"
            ]
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
                options: ExecOptions(
                    command: ["true"],
                    name: "adev-app-aaaabbbbcccc"
                ),
                runtime: runtime
            )
        }) { error in
            try MiniTest.expectEqual((error as! CLIError).code, CLIErrorCode.containerNotRunning)
        }
    }),
    ("stopBindManagedByName", {
        let workspace = try TestRepo.makeTempWorkspace(configJSON: #"{ "image": "alpine:3.20" }"#)
        defer { try? FileManager.default.removeItem(at: workspace) }
        let mock = MockProcessRunner()
        let resolved = try ConfigResolver.resolve(workspacePath: workspace.path, localEnv: [:])
        try MiniTest.expectEqual(
            resolved.labels[ContainerIdentity.labelManaged],
            ContainerIdentity.managedValue
        )
        try MiniTest.expectEqual(
            resolved.labels[ContainerIdentity.labelWorkspaceMode],
            ContainerIdentity.workspaceModeBind
        )
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
    ("pruneRemovesWorkspaceVolume", {
        let mock = MockProcessRunner()
        let volName = "adev-app-aaaabbbbcccc-ws"
        let entry = MockProcessRunner.containerListJSON(
            id: "adev-app-aaaabbbbcccc",
            state: "stopped",
            labels: [
                ContainerIdentity.labelManaged: ContainerIdentity.managedValue,
                ContainerIdentity.labelWorkspaceMode: "volume",
                ContainerIdentity.labelWorkspaceVolume: volName
            ],
            image: "alpine:3.20"
        )
        let volumeListData = try JSONSerialization.data(withJSONObject: [["id": volName]] as [[String: Any]])
        var containerDeleted = false
        mock.handlers = [
            { args in
                if args.starts(with: ["list"]) {
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
        let code = try PruneCommand.run(
            name: "adev-app-aaaabbbbcccc",
            runtime: runtime
        )
        try MiniTest.expectEqual(code, 0)
        try MiniTest.expect(mock.calls.contains { $0.arguments.first == "delete" })
        try MiniTest.expect(mock.calls.contains { $0.arguments == ["volume", "delete", volName] })
    }),
    ("pruneManagedRemovesConfigVolumesFromLabel", {
        let mock = MockProcessRunner()
        let wsVol = "adev-app-aaaabbbbcccc-ws"
        let entry = MockProcessRunner.containerListJSON(
            id: "adev-app-aaaabbbbcccc",
            state: "stopped",
            labels: [
                ContainerIdentity.labelManaged: ContainerIdentity.managedValue,
                ContainerIdentity.labelWorkspaceMode: "volume",
                ContainerIdentity.labelWorkspaceVolume: wsVol,
                ContainerIdentity.labelConfigVolumes: "cfg-vol-a,cfg-vol-b"
            ],
            image: "alpine:3.20"
        )
        let volumeListData = try JSONSerialization.data(withJSONObject: [
            ["id": "cfg-vol-a"],
            ["id": "cfg-vol-b"],
            ["id": wsVol]
        ] as [[String: Any]])
        var containerDeleted = false
        mock.handlers = [
            { args in
                if args.starts(with: ["list"]) {
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
        let code = try PruneCommand.run(
            name: "adev-app-aaaabbbbcccc",
            runtime: runtime
        )
        try MiniTest.expectEqual(code, 0)
        try MiniTest.expect(mock.calls.contains { $0.arguments == ["volume", "delete", "cfg-vol-a"] })
        try MiniTest.expect(mock.calls.contains { $0.arguments == ["volume", "delete", "cfg-vol-b"] })
        try MiniTest.expect(mock.calls.contains { $0.arguments == ["volume", "delete", wsVol] })
    }),
    ("cloneReplacesExistingWorkspaceVolume", {
        let restore = CloneGitFeatureTestSupport.installOverrides()
        defer { restore() }
        let git = MockGitClient()
        git.configJSONToWrite = #"{ "image": "alpine:3.20" }"#
        let mock = MockProcessRunner()
        let identity = ContainerIdentity.volumeModeIdentity(
            gitURL: "https://github.com/org/reclone.git",
            configRelativePath: ".devcontainer/devcontainer.json",
            configName: nil
        )
        let wsVol = identity.workspaceVolumeName
        // volume list: first call (pre-create wipe check) has existing ws; later empty/create path
        var volumeListCalls = 0
        mock.handlers = [
            { args in
                if args.starts(with: ["list"]) {
                    let data = try! JSONSerialization.data(withJSONObject: [] as [Any])
                    return ProcessResult(exitCode: 0, stdout: data, stderr: Data())
                }
                if args == ["volume", "list", "--format", "json"] || args.starts(with: ["volume", "list"]) {
                    volumeListCalls += 1
                    // First existence check sees stale volume; after delete, not present
                    let items: [[String: Any]] = volumeListCalls == 1 ? [["id": wsVol]] : []
                    let data = try! JSONSerialization.data(withJSONObject: items)
                    return ProcessResult(exitCode: 0, stdout: data, stderr: Data())
                }
                if args.starts(with: ["volume", "delete"]) {
                    return ProcessResult(exitCode: 0, stdout: Data(), stderr: Data())
                }
                if args.starts(with: ["volume", "create"]) {
                    return ProcessResult(exitCode: 0, stdout: Data(), stderr: Data())
                }
                if args.first == "create" {
                    return ProcessResult(exitCode: 0, stdout: Data("ctr\n".utf8), stderr: Data())
                }
                if args.first == "start" || args.first == "exec" {
                    return ProcessResult(exitCode: 0, stdout: Data(), stderr: Data())
                }
                return nil
            }
        ]
        let runtime = AppleContainerRuntime(executablePath: "/usr/local/bin/container", runner: mock)
        let result = try CloneCommand.run(
            options: CloneOptions(gitURL: "https://github.com/org/reclone.git", skipPull: true),
            runtime: runtime,
            git: git,
            credentials: MockGitCredential(),
            localEnv: [:]
        )
        try MiniTest.expectEqual(result.outcome, "success")
        try MiniTest.expectEqual(result.workspaceVolume, wsVol)
        try MiniTest.expect(mock.calls.contains { $0.arguments == ["volume", "delete", wsVol] })
        try MiniTest.expect(mock.calls.contains { $0.arguments == ["volume", "create", wsVol] })
        let deleteIdx = mock.calls.firstIndex { $0.arguments == ["volume", "delete", wsVol] }!
        let createIdx = mock.calls.firstIndex { $0.arguments == ["volume", "create", wsVol] }!
        try MiniTest.expect(deleteIdx < createIdx)
    }),
    ("cloneSetsConfigVolumesLabel", {
        let restore = CloneGitFeatureTestSupport.installOverrides()
        defer { restore() }
        let git = MockGitClient()
        git.configJSONToWrite = """
        {
          "image": "alpine:3.20",
          "mounts": [
            { "source": "data-vol", "target": "/data", "type": "volume" },
            { "source": "/tmp", "target": "/host-tmp", "type": "bind" }
          ]
        }
        """
        let mock = MockProcessRunner()
        mock.handlers = [
            { args in
                if args.starts(with: ["list"]) || args.starts(with: ["volume", "list"]) {
                    let data = try! JSONSerialization.data(withJSONObject: [] as [Any])
                    return ProcessResult(exitCode: 0, stdout: data, stderr: Data())
                }
                if args.starts(with: ["volume", "create"]) {
                    return ProcessResult(exitCode: 0, stdout: Data(), stderr: Data())
                }
                if args.first == "create" {
                    return ProcessResult(exitCode: 0, stdout: Data("ctr\n".utf8), stderr: Data())
                }
                if args.first == "start" || args.first == "exec" {
                    return ProcessResult(exitCode: 0, stdout: Data(), stderr: Data())
                }
                return nil
            }
        ]
        let runtime = AppleContainerRuntime(executablePath: "/usr/local/bin/container", runner: mock)
        _ = try CloneCommand.run(
            options: CloneOptions(gitURL: "https://github.com/org/with-vols.git", skipPull: true),
            runtime: runtime,
            git: git,
            credentials: MockGitCredential(),
            localEnv: [:]
        )
        let createCall = mock.calls.first { $0.arguments.first == "create" }!
        let labels = createCall.arguments.enumerated().compactMap { i, a -> String? in
            a == "-l" && i + 1 < createCall.arguments.count ? createCall.arguments[i + 1] : nil
        }
        try MiniTest.expect(labels.contains { $0 == "devcontainer.config_volumes=data-vol" })
    }),
    ("deleteDoesNotRemoveWorkspaceVolume", {
        let mock = MockProcessRunner()
        let volName = "adev-app-aaaabbbbcccc-ws"
        let entry = MockProcessRunner.containerListJSON(
            id: "adev-app-aaaabbbbcccc",
            state: "stopped",
            labels: [
                ContainerIdentity.labelManaged: ContainerIdentity.managedValue,
                ContainerIdentity.labelWorkspaceVolume: volName
            ]
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
        try DeleteCommand.run(name: "adev-app-aaaabbbbcccc", runtime: runtime)
        try MiniTest.expect(mock.calls.contains { $0.arguments.first == "delete" })
        try MiniTest.expect(!mock.calls.contains { $0.arguments.starts(with: ["volume", "delete"]) })
    }),
    ("upStillBindMountsHostWorkspace", {
        let workspace = try TestRepo.makeTempWorkspace(configJSON: #"{ "image": "alpine:3.20" }"#)
        defer { try? FileManager.default.removeItem(at: workspace) }
        let mock = MockProcessRunner()
        let resolved = try ConfigResolver.resolve(workspacePath: workspace.path, localEnv: [:])
        mock.handlers = [
            { args in
                if args.starts(with: ["list"]) {
                    let data = try! JSONSerialization.data(withJSONObject: [] as [Any])
                    return ProcessResult(exitCode: 0, stdout: data, stderr: Data())
                }
                if args.first == "create" {
                    let mounts = args.enumerated().compactMap { i, a -> String? in
                        a == "--mount" && i + 1 < args.count ? args[i + 1] : nil
                    }
                    // Must bind host workspace path
                    let wsPath = (workspace.path as NSString).standardizingPath
                    guard mounts.contains(where: { $0.contains("type=bind") && $0.contains(wsPath) }) else {
                        return ProcessResult(exitCode: 1, stdout: Data(), stderr: Data("expected bind".utf8))
                    }
                    // Must stamp managed labels (bind mode)
                    let labels = args.enumerated().compactMap { i, a -> String? in
                        a == "-l" && i + 1 < args.count ? args[i + 1] : nil
                    }
                    guard labels.contains("devcontainer.managed=adevcontainer") else {
                        return ProcessResult(exitCode: 1, stdout: Data(), stderr: Data("missing managed".utf8))
                    }
                    guard labels.contains("devcontainer.workspace_mode=bind") else {
                        return ProcessResult(exitCode: 1, stdout: Data(), stderr: Data("missing bind mode".utf8))
                    }
                    if labels.contains(where: { $0.hasPrefix("devcontainer.git_url=") })
                        || labels.contains(where: { $0.hasPrefix("devcontainer.workspace_volume=") })
                    {
                        return ProcessResult(exitCode: 1, stdout: Data(), stderr: Data("unexpected volume labels".utf8))
                    }
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
            options: UpOptions(workspacePath: workspace.path, skipPull: true),
            runtime: runtime,
            localEnv: [:]
        )
        try MiniTest.expectEqual(result.outcome, "success")
        try MiniTest.expect(mock.calls.contains { $0.arguments.first == "create" })
    })
]
