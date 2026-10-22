import Foundation

protocol GitCredentialConnecting: Sendable {
    @discardableResult func setup(id: String, hostWorkspace: String?, gitURL: String?, refresh: Bool) throws -> Bool
    func unregister(id: String) throws
}

enum GitCredentialLifecycle {
    private final class Port: @unchecked Sendable {
        private let lock = NSLock()
        private var value: (any GitCredentialConnecting)?
        func get() -> (any GitCredentialConnecting)? { lock.lock(); defer { lock.unlock() }; return value }
        func set(_ value: (any GitCredentialConnecting)?) { lock.lock(); self.value = value; lock.unlock() }
    }
    private static let port = Port()
    static func setTestConnection(_ connection: (any GitCredentialConnecting)?) { port.set(connection) }
    private static func connection(runtime: AppleContainerRuntime, credentials: any GitCredentialProviding) throws -> any GitCredentialConnecting {
        if let injected = port.get() { return injected }
        guard runtime.runner is FoundationProcessRunner else { throw GitCredentialFailure.invalidContext }
        let token = (credentials as? HostGitCredential)?.environment["ADEVCONTAINER_GIT_TOKEN"]?.trimmingCharacters(in: .whitespacesAndNewlines)
        return GitCredentialConnection(runtime: runtime, hostRunner: LifecycleRunner.hostProcessRunnerOverride ?? CredentialProviderProcessRunner(), token: token?.isEmpty == false ? token : nil)
    }
    @discardableResult static func setup(id: String, hostWorkspace: String?, gitURL: String?, runtime: AppleContainerRuntime, credentials: any GitCredentialProviding, refresh: Bool = false) throws -> Bool {
        try connection(runtime: runtime, credentials: credentials).setup(id: id, hostWorkspace: hostWorkspace, gitURL: gitURL, refresh: refresh)
    }
    static func setupSoft(id: String, hostWorkspace: String?, gitURL: String?, runtime: AppleContainerRuntime, credentials: any GitCredentialProviding) {
        do { _ = try setup(id: id, hostWorkspace: hostWorkspace, gitURL: gitURL, runtime: runtime, credentials: credentials) }
        catch {
            let reason = (error as? GitCredentialFailure)?.diagnosticCode ?? "unknown failure"
            StatusPrinter.warning("Automatic Git credential setup failed (\(reason)); continuing. Run adevcontainer start or up on the running container to retry, or log in on the host.")
        }
    }
    static func setupSoft(id: String, labels: [String: String], runtime: AppleContainerRuntime, credentials: any GitCredentialProviding) {
        let sources = GitCredentialDiscovery.credentialSources(from: labels)
        setupSoft(id: id, hostWorkspace: sources.hostWorkspace, gitURL: sources.gitURL, runtime: runtime, credentials: credentials)
    }
    static func unregisterSoft(id: String, runtime: AppleContainerRuntime) {
        do { try connection(runtime: runtime, credentials: HostGitCredential(environment: [:])).unregister(id: id) }
        catch { /* Runtime teardown retains its primary result; reconciliation also fences the session. */ }
    }
}
