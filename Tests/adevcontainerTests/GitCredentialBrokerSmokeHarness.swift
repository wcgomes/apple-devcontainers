import Foundation
import Crypto
import Darwin
@testable import ADevContainerLib

struct GitCredentialSmokeManifest: Codable, Equatable, Sendable {
    var label: String
    var state: String
    var endpoints: String
    var executable: String
    var providerConfig: String
    var helper: String
    var containers: [String]
    /// pids started by this fixture. Cleanup signals only these processes.
    var processes: [Int32]
    var productionState: String
}

enum GitCredentialBrokerSmokeHarness {
    static let productionLabel = GitCredentialLaunchContext.productionLabel
    static func isolatedContext(root: URL, executable: String = "/usr/bin/true") -> GitCredentialLaunchContext {
        let label = "com.adevcontainer.git-credentials.test.\(UUID().uuidString)"
        let state = root.appendingPathComponent("state").path
        return GitCredentialLaunchContext(label: label, state: state, endpoints: root.path, executable: executable, providerEnvironment: syntheticProviderEnvironment(state: state))
    }
    static func syntheticProviderEnvironment(state: String) -> [String: String] {
        ["PATH": "/usr/bin:/bin:/usr/sbin:/sbin", "HOME": state, "GIT_CONFIG_GLOBAL": state + "/credential-smoke.gitconfig", "GIT_CONFIG_SYSTEM": "/dev/null", "GIT_CONFIG_NOSYSTEM": "1"]
    }
    static func prepare(_ context: GitCredentialLaunchContext) throws -> GitCredentialSmokeManifest {
        try context.validate()
        guard context.label != productionLabel else { throw GitCredentialFailure.invalidContext }
        let endpoints = try GitCredentialPrivateFiles.directory(context.endpoints, create: true); close(endpoints)
        let state = context.state
        try FileManager.default.createDirectory(atPath: state, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        let helper = state + "/credential-smoke-helper"
        let config = state + "/credential-smoke.gitconfig"
        let script = "#!/bin/sh\nprintf '%s\\n' 'username=synthetic' 'password=synthetic-smoke' ''\n"
        try Data(script.utf8).write(to: URL(fileURLWithPath: helper), options: .atomic)
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: helper)
        let gitconfig = "[credential \"https://credential-smoke.invalid\"]\n\thelper = !\(helper)\n"
        try Data(gitconfig.utf8).write(to: URL(fileURLWithPath: config), options: .atomic)
        return GitCredentialSmokeManifest(label: context.label, state: state, endpoints: context.endpoints, executable: context.executable,
                                          providerConfig: config, helper: helper, containers: [], processes: [], productionState: "")
    }
    static func fingerprint(_ path: String) -> String {
        guard !path.isEmpty, let attributes = try? FileManager.default.attributesOfItem(atPath: path),
              let size = attributes[.size] as? NSNumber, let modified = attributes[.modificationDate] as? Date else { return "absent" }
        let material = Data("\(size.intValue)\n\(modified.timeIntervalSince1970)\n".utf8)
        return SHA256.hash(data: material).map { String(format: "%02x", $0) }.joined()
    }
    /// No launchd surface exists: cleanup terminates recorded test-owned pids
    /// and removes owned paths. It never touches a production broker.
    static func cleanup(_ manifest: GitCredentialSmokeManifest) throws {
        try validateOwned(manifest)
        for pid in manifest.processes where pid > 1 && pid != getpid() {
            guard kill(pid, 0) == 0 else { continue }
            _ = kill(pid, SIGTERM)
            let deadline = ProcessInfo.processInfo.systemUptime + 3
            while kill(pid, 0) == 0, ProcessInfo.processInfo.systemUptime < deadline { Thread.sleep(forTimeInterval: 0.025) }
            if kill(pid, 0) == 0 { _ = kill(pid, SIGKILL) }
        }
        for path in [manifest.helper, manifest.providerConfig, manifest.state, manifest.endpoints] where !path.isEmpty {
            try removeOwned(path, root: manifest.endpoints)
        }
    }
    static func protect<T>(_ manifest: GitCredentialSmokeManifest, _ body: () throws -> T) throws -> T {
        do { return try body() }
        catch {
            try cleanup(manifest)
            throw error
        }
    }
    static func unhandleableInstructions(_ manifest: GitCredentialSmokeManifest) -> String {
        let containers = manifest.containers.isEmpty ? "(none)" : manifest.containers.joined(separator: " ")
        let pids = manifest.processes.isEmpty ? "(none)" : manifest.processes.map(String.init).joined(separator: " ")
        return """
        Targeted cleanup after unhandleable termination of \(manifest.label).
        Do not signal any pid that is not listed here.
        Do not touch \(productionLabel).
        Do not delete \(manifest.productionState.isEmpty ? "(no production state recorded)" : manifest.productionState).
        Test-owned broker pids: \(pids)
        kill -TERM \(pids)
        rm -f -- \(manifest.helper) \(manifest.providerConfig)
        rm -rf -- \(manifest.state) \(manifest.endpoints)
        Exclusively created containers: \(containers)
        """
    }
    static func liveRefusedReason(_ environment: [String: String] = ProcessInfo.processInfo.environment) -> String? {
        guard environment["ADEVCONTAINER_CREDENTIAL_SMOKE"] == "1" else {
            return "Credential smoke is opt-in. Set ADEVCONTAINER_CREDENTIAL_SMOKE=1 only after reading Tests/GuestGitCredentialRelay/SMOKE.md."
        }
        guard environment["ADEVCONTAINER_CREDENTIAL_SMOKE_AUTHORIZED"] == "1" else {
            return "Live credential smoke requires separate authorization. No broker process, container, keychain, or provider was contacted."
        }
        return "Live arm64 credential smoke is not part of the automatic suite. Follow Tests/GuestGitCredentialRelay/SMOKE.md; this process starts no broker."
    }
    private static func validateOwned(_ manifest: GitCredentialSmokeManifest) throws {
        let prefix = "com.adevcontainer.git-credentials.test."
        guard manifest.label != productionLabel, manifest.label.hasPrefix(prefix), UUID(uuidString: String(manifest.label.dropFirst(prefix.count))) != nil else { throw GitCredentialFailure.invalidContext }
        let root = try credentialTestBase().path + "/"
        for path in [manifest.state, manifest.endpoints, manifest.providerConfig, manifest.helper] {
            guard path.hasPrefix(root), !path.split(separator: "/").contains(".."), path != String(root.dropLast()) else { throw GitCredentialFailure.unsafePath }
        }
        if !manifest.productionState.isEmpty {
            guard manifest.productionState != manifest.state else { throw GitCredentialFailure.unsafePath }
        }
    }
    private static func removeOwned(_ path: String, root: String) throws {
        var info = stat()
        guard lstat(path, &info) == 0 else { return }
        guard info.st_mode & S_IFMT != S_IFLNK else { throw GitCredentialFailure.unsafePath }
        guard path == root || path.hasPrefix(root + "/") else { throw GitCredentialFailure.unsafePath }
        try FileManager.default.removeItem(atPath: path)
    }
}
