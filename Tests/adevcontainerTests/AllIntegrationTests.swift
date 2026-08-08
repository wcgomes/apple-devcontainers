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

    /// Copy `Tests/Fixtures/features-sample/{sample-a,sample-b}` into workspace `.devcontainer/features/`.
    static func copySampleFeatures(into workspace: URL, names: [String] = ["sample-a", "sample-b"]) throws {
        let fm = FileManager.default
        let destRoot = workspace.appendingPathComponent(".devcontainer/features", isDirectory: true)
        try fm.createDirectory(at: destRoot, withIntermediateDirectories: true)
        for name in names {
            let src = TestRepo.root()
                .appendingPathComponent("Tests/Fixtures/features-sample/\(name)")
            let dest = destRoot.appendingPathComponent(name)
            if fm.fileExists(atPath: dest.path) {
                try fm.removeItem(at: dest)
            }
            try fm.copyItem(at: src, to: dest)
        }
    }

    static func runFixtureE2E(
        fixtureFile: String,
        ensureKube: Bool = false,
        smokeCommand: [String] = ["true"],
        prepareWorkspace: ((URL) throws -> Void)? = nil,
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

        if let prepareWorkspace {
            try prepareWorkspace(ws)
        }

        let up = try UpCommand.run(
            options: UpOptions(workspacePath: ws.path, jsonOutput: true, skipPull: true),
            runtime: runtime
        )
        try MiniTest.expectEqual(up.outcome, "success")
        try MiniTest.expect(!up.containerId.isEmpty)
        let managedName = up.containerName ?? up.containerId

        let code = try ExecCommand.run(
            options: ExecOptions(command: smokeCommand, name: managedName),
            runtime: runtime
        )
        try MiniTest.expectEqual(code, 0)

        let inspect = try InspectCommand.run(name: managedName, runtime: runtime)
        try MiniTest.expectEqual(inspect.state.lowercased(), "running")
        try MiniTest.expectEqual(
            inspect.labels[ContainerIdentity.labelManaged],
            ContainerIdentity.managedValue
        )
        try MiniTest.expectEqual(
            inspect.labels[ContainerIdentity.labelWorkspaceMode],
            ContainerIdentity.workspaceModeBind
        )

        if let extra {
            try extra(ws, runtime, config)
        }

        try DeleteCommand.run(name: managedName, runtime: runtime)
        try MiniTest.expect(try runtime.findByName(up.containerId) == nil)
    }
}

nonisolated(unsafe) let integrationTests: [(String, () throws -> Void)] = [
    ("fixtureE2E_smoke", {
        try IntegrationSupport.runFixtureE2E(fixtureFile: "smoke.json")
    }),
    ("fixtureE2E_envUser", {
        try IntegrationSupport.runFixtureE2E(fixtureFile: "env-user.json", extra: { ws, runtime, _ in
            let listed = try ManagedContainers.list(runtime: runtime)
            try MiniTest.expectEqual(listed.count, 1)
            let name = listed[0].name
            let inspected = try InspectCommand.run(name: name, runtime: runtime)
            try MiniTest.expectEqual(inspected.remoteUser, "vscode")
            try MiniTest.expectEqual(
                inspected.remoteWorkspaceFolder,
                "/workspaces/\(ws.lastPathComponent)"
            )
            let code = try ExecCommand.run(
                options: ExecOptions(
                    command: [
                        "sh", "-lc",
                        "test \"$ENVIRONMENT\" = Development && test \"$WORKSPACE_BASENAME\" = '\(ws.lastPathComponent)'"
                    ],
                    name: name
                ),
                runtime: runtime
            )
            try MiniTest.expectEqual(code, 0)
        })
    }),
    ("fixtureE2E_mountsPorts", {
        try IntegrationSupport.runFixtureE2E(fixtureFile: "mounts-ports.json", ensureKube: true, extra: { ws, runtime, config in
            let listed = try ManagedContainers.list(runtime: runtime)
            try MiniTest.expectEqual(listed.count, 1)
            let name = listed[0].name
            let code = try ExecCommand.run(
                options: ExecOptions(
                    command: ["sh", "-lc", "test -d /home/vscode/.config/opencode && test -d /home/vscode/.kube"],
                    name: name
                ),
                runtime: runtime
            )
            try MiniTest.expectEqual(code, 0)

            let inspect = try InspectCommand.run(name: name, runtime: runtime)
            // portsAttributes not stored on labels in v1
            try MiniTest.expect(inspect.portsAttributes.isEmpty)
            _ = config
            _ = ws
        })
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
    }),
    ("fixtureE2E_featuresNode_skipsWithoutNetworkOrRuntime", {
        // Live OCI fetch + container build requires network and Apple container.
        // Default suite must skip cleanly when either is unavailable.
        guard IntegrationSupport.containerRuntimeIfAvailable() != nil else {
            try MiniTest.skip("Apple container unavailable")
        }
        // Probe network to ghcr.io without pulling full feature (quick HEAD/GET).
        var reachable = false
        if let url = URL(string: "https://ghcr.io/v2/") {
            final class StatusBox: @unchecked Sendable { var value = 0 }
            let box = StatusBox()
            let sem = DispatchSemaphore(value: 0)
            let task = URLSession.shared.dataTask(with: url) { _, response, _ in
                box.value = (response as? HTTPURLResponse)?.statusCode ?? -1
                sem.signal()
            }
            task.resume()
            if sem.wait(timeout: .now() + 3) == .timedOut {
                task.cancel()
            } else {
                // ghcr often returns 401 for unauthenticated /v2/ — that still means reachable.
                reachable = box.value > 0
            }
        }
        guard reachable else {
            try MiniTest.skip("network unavailable for ghcr.io feature pull")
        }
        // Full live features-node E2E is optional and expensive; skip unless explicitly enabled.
        guard ProcessInfo.processInfo.environment["ADEVCONTAINER_FEATURES_E2E"] == "1" else {
            try MiniTest.skip("set ADEVCONTAINER_FEATURES_E2E=1 to run live features-node up")
        }
        // create argv expands feature PATH `${PATH}` so bare `node` is on PATH.
        try IntegrationSupport.runFixtureE2E(
            fixtureFile: "features-node.json",
            smokeCommand: ["node", "--version"]
        )
    }),
    ("fixtureE2E_featuresTriple_skipsWithoutNetworkOrRuntime", {
        guard IntegrationSupport.containerRuntimeIfAvailable() != nil else {
            try MiniTest.skip("Apple container unavailable")
        }
        var reachable = false
        if let url = URL(string: "https://ghcr.io/v2/") {
            final class StatusBox: @unchecked Sendable { var value = 0 }
            let box = StatusBox()
            let sem = DispatchSemaphore(value: 0)
            let task = URLSession.shared.dataTask(with: url) { _, response, _ in
                box.value = (response as? HTTPURLResponse)?.statusCode ?? -1
                sem.signal()
            }
            task.resume()
            if sem.wait(timeout: .now() + 3) == .timedOut {
                task.cancel()
            } else {
                reachable = box.value > 0
            }
        }
        guard reachable else {
            try MiniTest.skip("network unavailable for ghcr.io feature pull")
        }
        guard ProcessInfo.processInfo.environment["ADEVCONTAINER_FEATURES_E2E"] == "1" else {
            try MiniTest.skip("set ADEVCONTAINER_FEATURES_E2E=1 to run live features-triple up")
        }
        try IntegrationSupport.runFixtureE2E(
            fixtureFile: "features-triple.json",
            smokeCommand: [
                "/bin/bash", "-lc",
                "node --version && git --version && gh --version"
            ]
        )
    }),
    ("fixtureE2E_featuresLocal", {
        // Local path features only — no ghcr / ADEVCONTAINER_FEATURES_E2E gate.
        // Requires Apple container; uses DefaultFeatureFetcher + sample packages on disk.
        guard IntegrationSupport.containerRuntimeIfAvailable() != nil else {
            try MiniTest.skip("Apple container unavailable")
        }
        try IntegrationSupport.runFixtureE2E(
            fixtureFile: "features-local.json",
            smokeCommand: [
                "/bin/bash", "-lc",
                "test -f /usr/local/etc/adev-features/installed.txt"
                    + " && grep sample-a /usr/local/etc/adev-features/installed.txt"
                    + " && grep sample-b /usr/local/etc/adev-features/installed.txt"
            ],
            prepareWorkspace: { ws in
                try IntegrationSupport.copySampleFeatures(into: ws)
            }
        )
    })
]
