import Foundation
@testable import ADevContainerLib

@MainActor let gitCredentialRuntimeTests: [(String, () throws -> Void)] = [
    ("credentials.runtime.observationRequiresDefinitiveMachineState", {
        let fixture: [String: Any] = ["configuration": ["id": "synthetic", "creationDate": 800000000.125, "platform": ["os": "linux", "architecture": "arm64"], "labels": ["devcontainer.managed": "adevcontainer", "devcontainer.remote_user": "root"]], "status": ["state": "running"]]
        let runner = MockProcessRunner(), runtime = AppleContainerRuntime(executablePath: "/synthetic/container", runner: runner)
        let running = try JSONSerialization.data(withJSONObject: [fixture])
        runner.enqueueStdout(String(decoding: running, as: UTF8.self))
        try MiniTest.expectEqual(runtime.credentialObservation(id: "synthetic"), .running(try .parse(running)))
        var stopped = fixture; stopped["status"] = ["state": "stopped"]
        runner.enqueueStdout(String(decoding: try JSONSerialization.data(withJSONObject: [stopped]), as: UTF8.self))
        try MiniTest.expectEqual(runtime.credentialObservation(id: "synthetic"), .inactive)
        runner.enqueueFailure(exitCode: 1, stderr: "runtime unavailable"); runner.enqueueFailure(exitCode: 1, stderr: "runtime unavailable")
        try MiniTest.expectEqual(runtime.credentialObservation(id: "synthetic"), .unknown)
        runner.enqueueFailure(exitCode: 1, stderr: "ambiguous inspect"); runner.enqueueStdout("[]")
        try MiniTest.expectEqual(runtime.credentialObservation(id: "synthetic"), .inactive)
        runner.enqueueFailure(exitCode: 1, stderr: "ambiguous inspect")
        runner.enqueueStdout("[{\"configuration\":{\"id\":\"other\"}}]")
        try MiniTest.expectEqual(runtime.credentialObservation(id: "synthetic"), .unknown, "malformed inventory cannot prove absence")
        runner.enqueueFailure(exitCode: 1, stderr: "ambiguous inspect")
        runner.enqueueStdout("[{\"configuration\":{\"id\":\"other\",\"labels\":{}},\"status\":{\"state\":\"stopped\"}}]")
        try MiniTest.expectEqual(runtime.credentialObservation(id: "synthetic"), .inactive)
        for text in ["garbage", "{}", "[{\"configuration\":{\"id\":\"synthetic\"}}]", "[{\"configuration\":{\"id\":\"other\"}}]"] {
            runner.enqueueStdout(text)
            try MiniTest.expectEqual(runtime.credentialObservation(id: "synthetic"), .unknown)
        }
        try MiniTest.expectEqual(runtime.credentialObservation(id: "synthetic", deadline: 0), .unknown)
        try MiniTest.expect(runner.calls.allSatisfy { $0.arguments.first == "inspect" || $0.arguments == ["list", "--all", "--format", "json"] })
    }),
    ("credentials.runtime.immutableMachineContext", {
        let fixture: [String: Any] = ["configuration": ["id": "synthetic", "creationDate": 800000000.125, "platform": ["os": "linux", "architecture": "amd64"], "labels": ["devcontainer.managed": "adevcontainer", "devcontainer.remote_user": "vscode", "devcontainer.config_hash": "hash"]], "status": ["state": "running"]]
        let data = try JSONSerialization.data(withJSONObject: [fixture])
        let context = try GitCredentialRuntimeContext.parse(data)
        try MiniTest.expectEqual(context.platform, "linux/amd64"); try MiniTest.expectEqual(context.user, "vscode")
        try MiniTest.expectEqual(context.id, "synthetic")
        var configuration = fixture["configuration"] as! [String: Any]
        for key in ["creationDate", "platform", "labels"] {
            var bad = fixture; var config = configuration; config.removeValue(forKey: key); bad["configuration"] = config
            try MiniTest.expectThrows({ _ = try GitCredentialRuntimeContext.parse(JSONSerialization.data(withJSONObject: bad)) }, validate: { _ in })
        }
        for date: Any in [true, 0, "invalid", -978307200] {
            configuration["creationDate"] = date; var bad = fixture; bad["configuration"] = configuration
            try MiniTest.expectThrows({ _ = try GitCredentialRuntimeContext.parse(JSONSerialization.data(withJSONObject: bad)) }, validate: { _ in })
        }
        for platform in [["os": "linux", "architecture": "riscv64"], ["os": "darwin", "architecture": "arm64"]] {
            var bad = fixture; var config = fixture["configuration"] as! [String: Any]; config["platform"] = platform; bad["configuration"] = config
            try MiniTest.expectThrows({ _ = try GitCredentialRuntimeContext.parse(JSONSerialization.data(withJSONObject: bad)) }, validate: { _ in })
        }
        var stopped = fixture; stopped["status"] = ["state": "stopped"]
        try MiniTest.expectThrows({ _ = try GitCredentialRuntimeContext.parse(JSONSerialization.data(withJSONObject: stopped)) }, validate: { _ in })
        configuration["creationDate"] = "2026-10-21T12:00:00Z"; var iso = fixture; iso["configuration"] = configuration
        try MiniTest.expect(try GitCredentialRuntimeContext.parse(JSONSerialization.data(withJSONObject: iso)).incarnation != context.incarnation)
    }),
    ("credentials.runtime.privateExecArguments", {
        let context = GitCredentialRuntimeContext(id: "synthetic", incarnation: "test", platform: "linux/arm64", user: "root", labels: [:])
        let args = try AppleContainerRuntime.credentialExecArguments(context: context, command: ["/private/helper", "relay", "/private/dir", "7"])
        try MiniTest.expectEqual(args, ["exec", "-i", "-u", "root", "synthetic", "/private/helper", "relay", "/private/dir", "7"])
        try MiniTest.expect(!args.contains("-t") && !args.contains("-e"))
        let runner = MockProcessRunner()
        runner.stdinHandlers = [{ _, input in .init(exitCode: 0, stdout: input ?? Data(), stderr: Data()) }]
        let runtime = AppleContainerRuntime(executablePath: "/synthetic/container", runner: runner)
        let artifact = try GuestGitCredentialArtifact.select(platform: context.platform)
        let readBack = try runtime.credentialExec(context: context, command: ["/synthetic/write-and-read"], input: artifact.bytes)
        try artifact.verify(readBack: readBack.stdout)
        try MiniTest.expectEqual(runner.calls.first?.stdinData, artifact.bytes)
        try MiniTest.expectEqual(runner.calls.first?.arguments, ["exec", "-i", "-u", "root", "synthetic", "/synthetic/write-and-read"])
        try MiniTest.expect(runner.calls.first?.environment?["ADEVCONTAINER_GIT_TOKEN"] == nil)
        try MiniTest.expectThrows({ _ = try runtime.credentialDuplex(context: context, command: ["must-not-execute"]) }, validate: { error in try MiniTest.expectEqual(error as? GitCredentialFailure, .invalidContext) })
    })
]
