import Foundation
import Darwin

private final class GitCredentialServiceStop: @unchecked Sendable {
    private let lock = NSLock()
    private var stopped = false
    func stop() { lock.lock(); stopped = true; lock.unlock() }
    func shouldStop() -> Bool { lock.lock(); defer { lock.unlock() }; return stopped }
}

/// Internal executable entry, deliberately not part of public command parsing/help.
public enum GitCredentialBrokerEntry {
    public static func run(arguments: [String]) -> Int32? {
        guard arguments.first == "__adevcontainer_git_broker" else { return nil }
        do {
            if arguments == ["__adevcontainer_git_broker", "__verify_embedded_assets"] {
                let assets = try ["linux/arm64", "linux/amd64"].map(GuestGitCredentialArtifact.select)
                let manifest: [[String: Any]] = assets.map { ["target": $0.platform, "size": $0.bytes.count, "sha256": $0.sha256, "protocolVersion": GitCredentialProtocol.version] }
                FileHandle.standardOutput.write(try JSONSerialization.data(withJSONObject: manifest, options: [.sortedKeys]))
                return 0
            }
            let context: GitCredentialLaunchContext
            if arguments.count == 1 { context = try .production() }
            else {
                guard arguments.count == 2, let base = realpath(FileManager.default.temporaryDirectory.appendingPathComponent("opencode").path, nil) else { throw GitCredentialFailure.invalidContext }
                defer { free(base) }
                let path = arguments[1]
                guard path.hasPrefix(String(cString: base) + "/"), !path.split(separator: "/").contains(".."), (path as NSString).lastPathComponent == "launch-context.json" else { throw GitCredentialFailure.invalidContext }
                let directory = try GitCredentialPrivateFiles.directory((path as NSString).deletingLastPathComponent, create: false); defer { close(directory) }
                guard let bytes = try GitCredentialPrivateFiles.read("launch-context.json", directory: directory),
                      let decoded = try? JSONDecoder().decode(GitCredentialLaunchContext.self, from: bytes),
                      decoded.label != "com.adevcontainer.git-credentials" else { throw GitCredentialFailure.invalidContext }
                context = decoded
            }
            try context.validate()
            let environment: [String: String]
            if context.label == "com.adevcontainer.git-credentials" { environment = ProcessInfo.processInfo.environment.filter { $0.key != "ADEVCONTAINER_GIT_TOKEN" } }
            else {
                guard let isolated = context.providerEnvironment, isolated["GIT_CONFIG_NOSYSTEM"] == "1", isolated["GIT_CONFIG_SYSTEM"] == "/dev/null",
                      let global = isolated["GIT_CONFIG_GLOBAL"], global.hasPrefix(context.state + "/"), !global.split(separator: "/").contains(".."),
                      isolated["ADEVCONTAINER_GIT_TOKEN"] == nil, !isolated.keys.contains(where: { $0.hasPrefix("GIT_CONFIG_KEY_") || $0.hasPrefix("GIT_CONFIG_VALUE_") || ["GIT_CONFIG_COUNT", "GIT_CONFIG_PARAMETERS", "GH_TOKEN", "GITHUB_TOKEN"].contains($0) }) else { throw GitCredentialFailure.invalidContext }
                environment = isolated
            }
            let stop = GitCredentialServiceStop()
            // A detached session has no controlling terminal, so SIGHUP is
            // ignored while SIGTERM/SIGINT keep the same bounded cleanup.
            let term = signal(SIGTERM, SIG_IGN), interrupt = signal(SIGINT, SIG_IGN), hangup = signal(SIGHUP, SIG_IGN)
            let sources = [SIGTERM, SIGINT].map { number -> DispatchSourceSignal in
                let source = DispatchSource.makeSignalSource(signal: number, queue: .global()); source.setEventHandler { stop.stop() }; source.resume(); return source
            }
            defer { for source in sources { source.cancel() }; signal(SIGTERM, term); signal(SIGINT, interrupt); signal(SIGHUP, hangup) }
            try GitCredentialBrokerService(context: context).run(ports: AppleContainerRuntime().credentialBrokerPorts(providerEnvironment: environment), shouldStop: { stop.shouldStop() })
            return 0
        } catch {
            FileHandle.standardError.write(Data("Git credential service could not start; retry a lifecycle command to repair registration, or check the private service context.\n".utf8))
            return 1
        }
    }
}
