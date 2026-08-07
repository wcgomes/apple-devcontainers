import Foundation
@testable import ADevContainerLib

enum IntegrationSupport {
    /// When set, replaces `image` in the temp copy only (fixture files stay canonical).
    static var testImageOverride: String? {
        ProcessInfo.processInfo.environment["ADEVCONTAINER_TEST_IMAGE"]
    }

    static func containerRuntimeIfAvailable() -> AppleContainerRuntime? {
        let runtime = AppleContainerRuntime()
        guard runtime.binaryExists() else { return nil }
        do {
            let status = try runtime.systemStatus()
            let s = (status["status"] as? String ?? "").lowercased()
            guard s == "running" else { return nil }
            return runtime
        } catch {
            return nil
        }
    }

    static func fixtureURL(_ fileName: String) -> URL {
        TestRepo.root().appendingPathComponent("Tests/Fixtures/\(fileName)")
    }

    /// Loads a real fixture into a temp workspace. Optionally overrides image and remaps
    /// forwardPorts in the temp copy only so fixture files stay canonical for unit tests.
    /// E2E remaps ports to high free ports to avoid host conflicts.
    static func makeWorkspaceFromFixture(_ fileName: String) throws -> (workspace: URL, config: [String: Any]) {
        let data = try Data(contentsOf: fixtureURL(fileName))
        guard var obj = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw MiniTest.Failure(message: "fixture \(fileName) is not a JSON object")
        }

        if let override = testImageOverride {
            obj["image"] = override
        }

        if let ports = obj["forwardPorts"] as? [Int], !ports.isEmpty {
            let base = 28000 + (abs(UUID().uuidString.hashValue) % 2000)
            var map: [String: String] = [:]
            var newPorts: [Int] = []
            for (i, p) in ports.enumerated() {
                let np = base + i
                map[String(p)] = String(np)
                newPorts.append(np)
            }
            obj["forwardPorts"] = newPorts
            if let attrs = obj["portsAttributes"] as? [String: Any] {
                var newAttrs: [String: Any] = [:]
                for (k, v) in attrs {
                    newAttrs[map[k] ?? k] = v
                }
                obj["portsAttributes"] = newAttrs
            }
        }

        let out = try JSONSerialization.data(withJSONObject: obj, options: [.prettyPrinted, .sortedKeys])
        let json = String(data: out, encoding: .utf8) ?? "{}"
        let ws = try TestRepo.makeTempWorkspace(configJSON: json, prefix: "adev-int")
        return (ws, obj)
    }

    static func cleanup(workspace: URL, runtime: AppleContainerRuntime) {
        if let resolved = try? ConfigResolver.resolve(
            workspacePath: workspace.path,
            localEnv: ProcessInfo.processInfo.environment
        ) {
            try? runtime.delete(nameOrId: resolved.containerName, force: true)
        }
        try? FileManager.default.removeItem(at: workspace)
    }

    static func runFixtureE2E(
        fixtureFile: String,
        ensureKube: Bool = false,
        extra: ((URL, AppleContainerRuntime, [String: Any]) throws -> Void)? = nil
    ) throws {
        guard let runtime = containerRuntimeIfAvailable() else {
            try MiniTest.skip("Apple container unavailable")
        }

        if ensureKube {
            let kube = URL(fileURLWithPath: NSHomeDirectory()).appendingPathComponent(".kube", isDirectory: true)
            try FileManager.default.createDirectory(at: kube, withIntermediateDirectories: true)
        }

        let (ws, config) = try makeWorkspaceFromFixture(fixtureFile)
        defer { cleanup(workspace: ws, runtime: runtime) }

        let up = try UpCommand.run(
            options: UpOptions(workspacePath: ws.path, jsonOutput: true, skipPull: true),
            runtime: runtime
        )
        try MiniTest.expectEqual(up.outcome, "success")
        try MiniTest.expect(!up.containerId.isEmpty)

        let code = try ExecCommand.run(
            options: ExecOptions(workspacePath: ws.path, command: ["true"]),
            runtime: runtime
        )
        try MiniTest.expectEqual(code, 0)

        let inspect = try InspectCommand.run(workspacePath: ws.path, runtime: runtime)
        try MiniTest.expectEqual(inspect.state.lowercased(), "running")

        if let extra {
            try extra(ws, runtime, config)
        }

        try DeleteCommand.run(workspacePath: ws.path, runtime: runtime)
        try MiniTest.expect(try runtime.findByName(up.containerId) == nil)
    }
}

nonisolated(unsafe) let integrationTests: [(String, () throws -> Void)] = [
    ("fixtureE2E_smoke", {
        try IntegrationSupport.runFixtureE2E(fixtureFile: "smoke.json")
    }),
    ("fixtureE2E_envUser", {
        try IntegrationSupport.runFixtureE2E(fixtureFile: "env-user.json") { ws, runtime, _ in
            let up = try InspectCommand.run(workspacePath: ws.path, runtime: runtime)
            try MiniTest.expectEqual(up.remoteUser, "vscode")
            try MiniTest.expectEqual(
                up.remoteWorkspaceFolder,
                "/workspaces/\(ws.lastPathComponent)"
            )
            let code = try ExecCommand.run(
                options: ExecOptions(
                    workspacePath: ws.path,
                    command: [
                        "sh", "-lc",
                        "test \"$ENVIRONMENT\" = Development && test \"$WORKSPACE_BASENAME\" = '\(ws.lastPathComponent)'"
                    ]
                ),
                runtime: runtime
            )
            try MiniTest.expectEqual(code, 0)
        }
    }),
    ("fixtureE2E_mountsPorts", {
        try IntegrationSupport.runFixtureE2E(fixtureFile: "mounts-ports.json", ensureKube: true) { ws, runtime, config in
            let code = try ExecCommand.run(
                options: ExecOptions(
                    workspacePath: ws.path,
                    command: ["sh", "-lc", "test -d /home/vscode/.config/opencode && test -d /home/vscode/.kube"]
                ),
                runtime: runtime
            )
            try MiniTest.expectEqual(code, 0)

            let inspect = try InspectCommand.run(workspacePath: ws.path, runtime: runtime)
            try MiniTest.expectEqual(
                inspect.portsAttributes["\( (config["forwardPorts"] as? [Int])?.first ?? -1 )"]?["label"],
                "PlantSuite Portal"
            )
        }
    }),
    ("fixtureE2E_lifecycle", {
        // postCreate is "echo postCreate-ok && pwd" — success of up + exec is enough
        try IntegrationSupport.runFixtureE2E(fixtureFile: "lifecycle.json")
    }),
    ("fixtureE2E_lifecycleHooks", {
        // Lifecycle hooks are echo-only; up success implies create-path order completed.
        try IntegrationSupport.runFixtureE2E(fixtureFile: "lifecycle-hooks.json")
    }),
    ("fixtureE2E_runargsHost", {
        // Allowlisted runArgs + hostRequirements enforce+apply (8gb/4 cpus OK on typical Macs).
        try IntegrationSupport.runFixtureE2E(fixtureFile: "runargs-host.json")
    })
]
