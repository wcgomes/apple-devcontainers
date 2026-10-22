import Foundation
import Darwin
@testable import ADevContainerLib

@MainActor let gitCredentialBrokerSmokeTests: [(String, () throws -> Void)] = [
    ("credentials.smoke.uniqueContextLeavesProductionUntouched", {
        let root = try credentialShortRoot(); defer { try? FileManager.default.removeItem(at: root) }
        let production = root.appendingPathComponent("production-fixture")
        try FileManager.default.createDirectory(at: production, withIntermediateDirectories: true)
        let productionState = production.appendingPathComponent("registrations.json")
        try Data("production-not-a-secret\n".utf8).write(to: productionState)
        let before = GitCredentialBrokerSmokeHarness.fingerprint(productionState.path)
        let context = GitCredentialBrokerSmokeHarness.isolatedContext(root: root.appendingPathComponent("job"))
        try context.validate()
        try MiniTest.expect(context.label.hasPrefix("com.adevcontainer.git-credentials.test."))
        try MiniTest.expect(context.label != GitCredentialBrokerSmokeHarness.productionLabel)
        try MiniTest.expect(context.providerEnvironment?["ADEVCONTAINER_GIT_TOKEN"] == nil)
        try MiniTest.expectEqual(context.providerEnvironment?["GIT_CONFIG_NOSYSTEM"], "1")
        try MiniTest.expect(context.providerEnvironment?["GIT_CONFIG_GLOBAL"]?.hasPrefix(context.state + "/") == true)
        var manifest = try GitCredentialBrokerSmokeHarness.prepare(context)
        manifest.productionState = production.path
        let identity = try credentialIdentity(context.executable)
        let probe = CredentialProbeFake(.absent), launcher = CredentialDetachedLauncher()
        launcher.afterLaunch = { probe.set(.owner(identity)) }
        try GitCredentialBrokerService(context: context, launcher: launcher, control: probe).ensure()
        guard let launch = launcher.launches.first else { throw MiniTest.Failure(message: "no detached launch recorded") }
        try MiniTest.expectEqual(launch.executable, context.executable)
        try MiniTest.expect(!launch.arguments.contains { $0.contains(".plist") || $0.contains("launchctl") })
        try MiniTest.expect(launch.environment.allSatisfy { $0.key != "ADEVCONTAINER_GIT_TOKEN" })
        try MiniTest.expect(!FileManager.default.fileExists(atPath: NSHomeDirectory() + "/Library/LaunchAgents/" + context.label + ".plist"),
                            "no LaunchAgent plist may exist for this context")
        try GitCredentialBrokerSmokeHarness.cleanup(manifest)
        try MiniTest.expectEqual(GitCredentialBrokerSmokeHarness.fingerprint(productionState.path), before)
        try MiniTest.expect(!FileManager.default.fileExists(atPath: manifest.state))
        try MiniTest.expect(!FileManager.default.fileExists(atPath: manifest.endpoints))
    }),
    ("credentials.smoke.syntheticProviderAndFailureCleanup", {
        let root = try credentialShortRoot(); defer { try? FileManager.default.removeItem(at: root) }
        let context = GitCredentialBrokerSmokeHarness.isolatedContext(root: root)
        var manifest = try GitCredentialBrokerSmokeHarness.prepare(context)
        let config = try String(contentsOfFile: manifest.providerConfig, encoding: .utf8)
        try MiniTest.expect(config.contains("https://credential-smoke.invalid"))
        try MiniTest.expect(!config.contains("ADEVCONTAINER_GIT_TOKEN"))
        let environment = GitCredentialBrokerSmokeHarness.syntheticProviderEnvironment(state: manifest.state)
        let query = try CredentialProviderProcessRunner(timeout: 3).run(executable: "/usr/bin/git", arguments: ["-c", "credential.helper=", "-c", "credential.helper=!\(manifest.helper)", "credential", "fill"], environment: environment, currentDirectory: nil, stdinData: Data("protocol=https\nhost=credential-smoke.invalid\n\n".utf8))
        try MiniTest.expect(query.succeeded)
        try MiniTest.expect(query.stdoutString.contains("password=synthetic-smoke\n"))
        // A recorded test-owned process is terminated by the manifest alone.
        let standIn = Process()
        standIn.executableURL = URL(fileURLWithPath: "/bin/sleep")
        standIn.arguments = ["30"]
        try standIn.run()
        manifest.processes = [standIn.processIdentifier]
        try MiniTest.expectThrows({
            try GitCredentialBrokerSmokeHarness.protect(manifest) { throw GitCredentialFailure.transport }
        }, validate: { _ in })
        standIn.waitUntilExit()
        try MiniTest.expectEqual(standIn.terminationStatus, 15, "cleanup signals only the recorded test-owned pid")
        try MiniTest.expect(!FileManager.default.fileExists(atPath: manifest.helper))
        try MiniTest.expect(!FileManager.default.fileExists(atPath: manifest.endpoints))
    }),
    ("credentials.smoke.handledSignalAndUnhandleableManifest", {
        let root = try credentialShortRoot(); defer { try? FileManager.default.removeItem(at: root) }
        let context = GitCredentialBrokerSmokeHarness.isolatedContext(root: root)
        var manifest = try GitCredentialBrokerSmokeHarness.prepare(context)
        manifest.containers = ["synthetic-container-only"]
        manifest.processes = [4242]
        manifest.productionState = "/Users/example/Library/Application Support/adevcontainer/git-credentials"
        try GitCredentialBrokerSmokeHarness.cleanup(manifest)
        try MiniTest.expect(!FileManager.default.fileExists(atPath: manifest.endpoints))
        let instructions = GitCredentialBrokerSmokeHarness.unhandleableInstructions(manifest)
        try MiniTest.expect(instructions.contains("kill -TERM 4242"))
        try MiniTest.expect(instructions.contains("Do not touch \(GitCredentialBrokerSmokeHarness.productionLabel)"))
        try MiniTest.expect(instructions.contains("synthetic-container-only"))
        try MiniTest.expect(!instructions.contains("launchctl"))
        try MiniTest.expect(!instructions.contains(".plist"))
        try MiniTest.expect(GitCredentialBrokerSmokeHarness.liveRefusedReason(["ADEVCONTAINER_CREDENTIAL_SMOKE": "1"])?.contains("No broker process") == true)
        try MiniTest.expect(GitCredentialBrokerSmokeHarness.liveRefusedReason(["ADEVCONTAINER_CREDENTIAL_SMOKE": "1", "ADEVCONTAINER_CREDENTIAL_SMOKE_AUTHORIZED": "1"])?.contains("starts no broker") == true)
        var production = manifest
        production.label = GitCredentialBrokerSmokeHarness.productionLabel
        try MiniTest.expectThrows({ try GitCredentialBrokerSmokeHarness.cleanup(production) }, validate: { _ in })
    })
]
