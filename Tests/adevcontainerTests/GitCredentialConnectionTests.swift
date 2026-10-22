import Foundation
@testable import ADevContainerLib

final class CredentialConnectionRecorder: @unchecked Sendable {
    private let lock = NSLock()
    private var values: [GitCredentialControlRequest] = []
    func record(_ request: GitCredentialControlRequest, _ activate: Bool) { lock.lock(); values.append(request); lock.unlock() }
    var requests: [GitCredentialControlRequest] { lock.lock(); defer { lock.unlock() }; return values }
}
@MainActor let gitCredentialConnectionTests: [(String, () throws -> Void)] = [
    ("credentials.connection.migrationPreservesUserOrderAndUnmarkedStores", {
        let root = try credentialTestRoot()
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
        defer { try? FileManager.default.removeItem(at: root) }
        let home = root.appendingPathComponent("home with 'quotes"), bin = root.appendingPathComponent("bin"), base = root.appendingPathComponent("endpoints"), directory = root.appendingPathComponent("endpoints/s-test")
        for path in [home, home.appendingPathComponent(".adevcontainer"), bin, base, directory] {
            try FileManager.default.createDirectory(at: path, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
        }
        // Exercise the production migration shell on macOS with only the Linux
        // stat formatting port adapted. Git reads this isolated config, never a
        // user credential helper; no fill/approve/reject is invoked.
        let stat = bin.appendingPathComponent("stat")
        try Data("#!/bin/sh\ncase \"$2\" in %u) exec /usr/bin/stat -f %u \"$3\" ;; %a) exec /usr/bin/stat -f %Lp \"$3\" ;; *) exit 1 ;; esac\n".utf8).write(to: stat)
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: stat.path)
        let environment = ["HOME": home.path, "PATH": bin.path + ":/usr/bin:/bin", "GIT_CONFIG_NOSYSTEM": "1", "GIT_CONFIG_SYSTEM": "/dev/null", "GIT_CONFIG_GLOBAL": home.appendingPathComponent(".gitconfig").path]
        let runner = FoundationProcessRunner()
        func git(_ arguments: [String]) throws -> ProcessResult {
            try runner.run(executable: "/usr/bin/git", arguments: ["config", "--global"] + arguments, environment: environment, currentDirectory: nil, stdinData: nil)
        }
        let helper = home.appendingPathComponent(".adevcontainer/git-credential-adev").path
        let helperCommand = "!exec '" + helper.replacingOccurrences(of: "'", with: "'\\''") + "'"
        for value in ["earlier-user-helper", "later-user-helper"] { try MiniTest.expect(try git(["--add", "credential.helper", value]).succeeded) }
        for value in ["", "azure-user-one", helper, "azure-user-two", helper] {
            try MiniTest.expect(try git(["--add", "credential.https://dev.azure.com.helper", value]).succeeded)
        }
        try MiniTest.expect(try git(["--add", "credential.http://dev.azure.com.helper", "http-user-helper"]).succeeded)
        let oldStore = home.appendingPathComponent(".adevcontainer/git-credentials"), userStore = home.appendingPathComponent(".git-credentials")
        for path in [oldStore, userStore] {
            try Data("synthetic-store-marker\n".utf8).write(to: path)
            try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: path.path)
        }
        func install(_ scopes: [String]) throws {
            let temporary = directory.appendingPathComponent(".relay.test")
            try Data("synthetic-not-executed-relay".utf8).write(to: temporary)
            let result = try runner.run(executable: "/bin/sh", arguments: ["-ceu", GitCredentialConnection.installScript, "synthetic-install", home.path, directory.path, temporary.path, "1", "synthetic"] + scopes, environment: environment, currentDirectory: nil, stdinData: Data(GitCredentialConnection.wrapper.utf8))
            try MiniTest.expect(result.succeeded, "sandbox migration failed")
        }
        try install(["https://dev.azure.com"])
        try install(["https://dev.azure.com"])
        try MiniTest.expectEqual(try git(["--get-all", "credential.helper"]).stdoutString, "earlier-user-helper\nlater-user-helper\n\(helperCommand)\n")
        try MiniTest.expectEqual(try git(["--get-all", "credential.https://dev.azure.com.helper"]).stdoutString, "azure-user-one\nazure-user-two\n\(helperCommand)\n")
        try MiniTest.expectEqual(try git(["--get", "credential.https://dev.azure.com.useHttpPath"]).stdoutString, "true\n")
        try MiniTest.expectEqual(try git(["--get-all", "credential.http://dev.azure.com.helper"]).stdoutString, "http-user-helper\n")
        try MiniTest.expect(!FileManager.default.fileExists(atPath: oldStore.path))
        try MiniTest.expectEqual(try String(contentsOf: userStore, encoding: .utf8), "synthetic-store-marker\n")
        try install(["http://dev.azure.com"])
        try MiniTest.expectEqual(try git(["--get-all", "credential.http://dev.azure.com.helper"]).stdoutString, "http-user-helper\n\(helperCommand)\n")
        try MiniTest.expectEqual(try git(["--get", "credential.http://dev.azure.com.useHttpPath"]).stdoutString, "true\n")
        // Execute only a fixture helper in the isolated config to prove the
        // installed command survives spaces/quotes without a host lookup.
        try Data("#!/bin/sh\nprintf 'username=synthetic\\npassword=synthetic\\n\\n'\n".utf8).write(to: URL(fileURLWithPath: helper))
        var queryEnvironment = environment
        queryEnvironment["GIT_TERMINAL_PROMPT"] = "0"; queryEnvironment["GIT_ASKPASS"] = "/usr/bin/false"
        let query = try runner.run(executable: "/usr/bin/git", arguments: ["-c", "credential.helper=", "-c", "credential.helper=" + helperCommand, "credential", "fill"], environment: queryEnvironment, currentDirectory: nil, stdinData: Data("protocol=https\nhost=credential-smoke.invalid\n\n".utf8))
        try MiniTest.expect(query.succeeded)
        try MiniTest.expect(query.stdoutString.contains("password=synthetic\n"))
    }),
    ("credentials.connection.azureMigrationKeepsUserHelpersWhenAddFails", {
        let root = try credentialTestRoot()
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
        defer { try? FileManager.default.removeItem(at: root) }
        let home = root.appendingPathComponent("home"), bin = root.appendingPathComponent("bin"), directory = root.appendingPathComponent("endpoints/s-test")
        for path in [home, home.appendingPathComponent(".adevcontainer"), bin, directory] {
            try FileManager.default.createDirectory(at: path, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        }
        let stat = bin.appendingPathComponent("stat")
        try Data("#!/bin/sh\ncase \"$2\" in %u) exec /usr/bin/stat -f %u \"$3\" ;; %a) exec /usr/bin/stat -f %Lp \"$3\" ;; *) exit 1 ;; esac\n".utf8).write(to: stat)
        let gitWrapper = bin.appendingPathComponent("git")
        try Data("#!/bin/sh\nfor arg in \"$@\"; do [ \"$arg\" = \"--add\" ] && exit 1; done\nexec /usr/bin/git \"$@\"\n".utf8).write(to: gitWrapper)
        for path in [stat, gitWrapper] {
            try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: path.path)
        }
        let config = home.appendingPathComponent(".gitconfig")
        let environment = ["HOME": home.path, "PATH": bin.path + ":/usr/bin:/bin", "GIT_CONFIG_NOSYSTEM": "1", "GIT_CONFIG_SYSTEM": "/dev/null", "GIT_CONFIG_GLOBAL": config.path]
        let runner = FoundationProcessRunner()
        for value in ["user-helper-one", "user-helper-two"] {
            let seeded = try runner.run(executable: "/usr/bin/git", arguments: ["config", "--global", "--add", "credential.https://dev.azure.com.helper", value], environment: environment, currentDirectory: nil, stdinData: nil)
            try MiniTest.expect(seeded.succeeded)
        }
        let temporary = directory.appendingPathComponent(".relay.test")
        try Data("synthetic-not-executed-relay".utf8).write(to: temporary)
        let result = try runner.run(executable: "/bin/sh", arguments: ["-ceu", GitCredentialConnection.installScript, "synthetic-install", home.path, directory.path, temporary.path, "0", "synthetic", "https://dev.azure.com"], environment: environment, currentDirectory: nil, stdinData: Data(GitCredentialConnection.wrapper.utf8))
        let remaining = try runner.run(executable: "/usr/bin/git", arguments: ["config", "--global", "--get-all", "credential.https://dev.azure.com.helper"], environment: environment, currentDirectory: nil, stdinData: nil)
        try MiniTest.expect(!result.succeeded, "a failed helper insert must fail the migration")
        try MiniTest.expectEqual(remaining.stdoutString, "user-helper-one\nuser-helper-two\n")
        try MiniTest.expect(!result.stderrString.contains("user-helper-one"))
        try MiniTest.expect(!result.stdoutString.contains("user-helper"))
    }),
    ("credentials.connection.singleBudgetStopsAfterSlowContext", {
        let runner = MockProcessRunner(), recorder = CredentialConnectionRecorder()
        let fixture: [String: Any] = ["configuration": ["id": "synthetic", "creationDate": 800000000, "platform": ["os": "linux", "architecture": "arm64"], "labels": ["devcontainer.managed": "adevcontainer", "devcontainer.remote_user": "root"]], "status": ["state": "running"]]
        let bytes = try JSONSerialization.data(withJSONObject: fixture)
        runner.handlers = [{ args in
            if args.first == "inspect" { Thread.sleep(forTimeInterval: 0.04); return .init(exitCode: 0, stdout: bytes, stderr: Data()) }
            return .init(exitCode: 0, stdout: Data(), stderr: Data())
        }]
        let connection = GitCredentialConnection(runtime: .init(executablePath: "/synthetic/container", runner: runner), control: { request, activate, _ in recorder.record(request, activate); return true }, timeout: 0.02)
        try MiniTest.expectThrows({ _ = try connection.setup(id: "synthetic", hostWorkspace: nil, gitURL: "https://example.invalid/repo") }) { error in
            try MiniTest.expectEqual(error as? GitCredentialFailure, .deadline)
        }
        try MiniTest.expectEqual(runner.calls.count, 1, "an expired context budget must not start provisioning")
        try MiniTest.expect(recorder.requests.isEmpty)
    }),
    ("credentials.connection.sharedHomeIncarnationsHaveDifferentEndpoints", {
        let first = GitCredentialRuntimeContext(id: "one", incarnation: "reference:800000000", platform: "linux/arm64", user: "root", labels: [:])
        let second = GitCredentialRuntimeContext(id: first.id, incarnation: "reference:800000001", platform: first.platform, user: first.user, labels: [:])
        try MiniTest.expectEqual(GitCredentialConnection.namespace(first).count, 45)
        try MiniTest.expect(GitCredentialConnection.namespace(first) != GitCredentialConnection.namespace(second))
        try MiniTest.expect(GitCredentialConnection.wrapper.contains("/proc/sys/kernel/hostname"))
        try MiniTest.expect(!GitCredentialConnection.wrapper.contains("${0%/*}/git-broker"))
    }),
    ("credentials.connection.skipMissingSourcesWithoutServiceOrExec", {
        let runner = MockProcessRunner(), recorder = CredentialConnectionRecorder()
        let connection = GitCredentialConnection(runtime: .init(executablePath: "/synthetic/container", runner: runner), control: { request, activate, _ in recorder.record(request, activate); return true }, gitPathOverride: .some(nil))
        try MiniTest.expect(try !connection.setup(id: "synthetic", hostWorkspace: nil, gitURL: nil))
        try MiniTest.expect(try !connection.setup(id: "synthetic", hostWorkspace: "/synthetic/workspace", gitURL: nil))
        try MiniTest.expect(runner.calls.isEmpty && recorder.requests.isEmpty)
    }),
    ("credentials.connection.assetReadBackAndRegistrationBeforeReady", {
        let runner = MockProcessRunner(), recorder = CredentialConnectionRecorder()
        let artifact = try GuestGitCredentialArtifact.select(platform: "linux/arm64")
        let fixture: [String: Any] = ["configuration": ["id": "synthetic", "creationDate": 800000000, "platform": ["os": "linux", "architecture": "arm64"], "labels": ["devcontainer.managed": "adevcontainer", "devcontainer.remote_user": "root"]], "status": ["state": "running"]]
        let bytes = try JSONSerialization.data(withJSONObject: fixture)
        runner.stdinHandlers = [{ args, input in
            if args.first == "inspect" { return .init(exitCode: 0, stdout: bytes, stderr: Data()) }
            if args.contains("adevcontainer-git-prepare"), let namespace = args.last {
                let directory = "/tmp/.adevcontainer-git-0/" + namespace
                return .init(exitCode: 0, stdout: Data("/home/root\n\(directory)\n\(directory)/.relay.abcdef\n0\n".utf8), stderr: Data())
            }
            if args.contains("cat") { return .init(exitCode: 0, stdout: artifact.bytes, stderr: Data()) }
            return .init(exitCode: 0, stdout: Data(), stderr: Data())
        }]
        let connection = GitCredentialConnection(runtime: .init(executablePath: "/synthetic/container", runner: runner), control: { request, activate, _ in recorder.record(request, activate); return true }, token: "synthetic-override")
        try MiniTest.expect(try connection.setup(id: "synthetic", hostWorkspace: nil, gitURL: "https://dev.azure.com/org/repo"))
        try MiniTest.expectEqual(recorder.requests.first?.registration?.destinations, [try GitCredentialDestination(url: "https://dev.azure.com/org/repo")])
        try MiniTest.expectEqual(recorder.requests.first?.token, "synthetic-override")
        try MiniTest.expect(runner.calls.allSatisfy { !$0.arguments.joined().contains("synthetic-override") && $0.environment?["ADEVCONTAINER_GIT_TOKEN"] == nil })
        try MiniTest.expect(runner.calls.contains { $0.stdinData == artifact.bytes })
        try MiniTest.expect(runner.calls.contains { $0.arguments.contains("adevcontainer-git-install") })
        try MiniTest.expect(runner.calls.contains { $0.arguments.contains("-S") })
        try connection.unregister(id: "synthetic")
        try MiniTest.expectEqual(recorder.requests.last?.operation, .unregister)
    }),
    ("credentials.connection.ownedLooseDirectoryIsTightenedWithoutFollowingSymlink", {
        let root = try credentialTestRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let bin = root.appendingPathComponent("bin")
        let home = root.appendingPathComponent("home")
        let loose = home.appendingPathComponent(".adevcontainer")
        let marker = loose.appendingPathComponent("vscode-customizations.applied")
        let foreign = root.appendingPathComponent("foreign")
        let link = root.appendingPathComponent("link")
        try FileManager.default.createDirectory(at: bin, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: loose, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o755])
        try Data("marker\n".utf8).write(to: marker)
        try FileManager.default.createDirectory(at: foreign, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o755])
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: foreign)
        let stat = bin.appendingPathComponent("stat")
        try Data("#!/bin/sh\ncase \"$2\" in %u) exec /usr/bin/stat -f %u \"$3\" ;; %a) exec /usr/bin/stat -f %Lp \"$3\" ;; *) exit 1 ;; esac\n".utf8).write(to: stat)
        let chmodLog = root.appendingPathComponent("chmod.log")
        let chmod = bin.appendingPathComponent("chmod")
        try Data("#!/bin/sh\nprintf '%s\\n' \"$*\" >> \"\(chmodLog.path)\"\nexec /bin/chmod \"$@\"\n".utf8).write(to: chmod)
        for path in [stat, chmod] {
            try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: path.path)
        }
        let uid = String(getuid())
        let environment = ["PATH": bin.path + ":/bin:/usr/bin"]
        let runner = FoundationProcessRunner()
        func repair(_ path: String) throws -> ProcessResult {
            try runner.run(executable: "/bin/sh", arguments: ["-c", GitCredentialConnection.privateDirectoryRepair + "ensure_private_dir \"$1\" \"$2\"", "repair", path, uid], environment: environment, currentDirectory: nil, stdinData: nil)
        }
        let tightened = try repair(loose.path)
        try MiniTest.expect(tightened.succeeded, "owned 0755 product directory must be tightened")
        let mode = try FileManager.default.attributesOfItem(atPath: loose.path)[.posixPermissions] as? NSNumber
        try MiniTest.expectEqual(mode?.intValue ?? 0, 0o700)
        try MiniTest.expectEqual(try String(contentsOf: marker, encoding: .utf8), "marker\n")
        let refused = try repair(link.path)
        try MiniTest.expect(!refused.succeeded, "symlink must be refused")
        let foreignMode = try FileManager.default.attributesOfItem(atPath: foreign.path)[.posixPermissions] as? NSNumber
        try MiniTest.expectEqual(foreignMode?.intValue ?? 0, 0o755)
        let log = (try? String(contentsOf: chmodLog, encoding: .utf8)) ?? ""
        try MiniTest.expect(!log.contains(link.path) && !log.contains(foreign.path), "refused path must not be chmod'd")
        let unowned = bin.appendingPathComponent("stat-foreign")
        try Data("#!/bin/sh\ncase \"$2\" in %u) printf '0\\n' ;; %a) exec /usr/bin/stat -f %Lp \"$3\" ;; *) exit 1 ;; esac\n".utf8).write(to: unowned)
        try FileManager.default.removeItem(at: stat)
        try FileManager.default.copyItem(at: unowned, to: stat)
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: stat.path)
        let other = root.appendingPathComponent("other")
        try FileManager.default.createDirectory(at: other, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o755])
        let denied = try repair(other.path)
        try MiniTest.expect(!denied.succeeded, "unowned directory must be refused")
        let otherMode = try FileManager.default.attributesOfItem(atPath: other.path)[.posixPermissions] as? NSNumber
        try MiniTest.expectEqual(otherMode?.intValue ?? 0, 0o755)
    }),
    ("credentials.connection.unsafePrepareDoesNotInstall", {
        let runner = MockProcessRunner()
        let fixture: [String: Any] = ["configuration": ["id": "synthetic", "creationDate": 800000000, "platform": ["os": "linux", "architecture": "arm64"], "labels": ["devcontainer.managed": "adevcontainer", "devcontainer.remote_user": "root"]], "status": ["state": "running"]]
        let bytes = try JSONSerialization.data(withJSONObject: fixture)
        runner.handlers = [{ args in
            if args.first == "inspect" { return .init(exitCode: 0, stdout: bytes, stderr: Data()) }
            if args.contains("adevcontainer-git-prepare") { return .init(exitCode: 4, stdout: Data(), stderr: Data("password=must-not-surface".utf8)) }
            return .init(exitCode: 0, stdout: Data(), stderr: Data())
        }]
        let connection = GitCredentialConnection(runtime: .init(executablePath: "/synthetic/container", runner: runner), control: { _, _, _ in true })
        try MiniTest.expectThrows({ _ = try connection.setup(id: "synthetic", hostWorkspace: nil, gitURL: "https://dev.azure.com/org/repo") }) { error in
            try MiniTest.expectEqual(error as? GitCredentialFailure, .unsafePath)
            try MiniTest.expectEqual((error as? GitCredentialFailure)?.diagnosticCode, "unsafe private path")
            try MiniTest.expect(!String(describing: error).contains("must-not-surface"))
        }
        try MiniTest.expect(!runner.calls.contains { $0.arguments.contains("adevcontainer-git-install") })
    })
]
