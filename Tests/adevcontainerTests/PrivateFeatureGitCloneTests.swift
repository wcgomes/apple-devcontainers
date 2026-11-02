import Foundation
#if canImport(Darwin)
import Darwin
#endif
@testable import ADevContainerLib

// MARK: - Shared seam (unit + command tests; no live registry, no live git remote)

enum PrivateFeatureGitCloneSupport {
    static let fixtureToken = "fixture-token-DO-NOT-LEAK"
    static let collectionURL = "https://some.private.registry/devcontainer-features"
    static let tagRef = "some.private.registry/devcontainer-features/feature:1"
    static let digest = "sha256:0123456789abcdef0123456789abcdef0123456789abcdef0123456789abcdef"
    static let digestRef = "some.private.registry/devcontainer-features/feature@\(digest)"
    static let noCollectionRef = "some.private.registry/feature:1"
    static let featureARef = "some.private.registry/devcontainer-features/feature-a:1"
    static let featureBRef = "some.private.registry/devcontainer-features/feature-b:1"
    static let successRef = "ghcr.io/devcontainers/features/sample:1"
    static let officialGitRef = "ghcr.io/devcontainers/features/git:1"
    static let successDigest = "sha256:aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa"

    struct BlobResponse {
        var status: Int
        var body: Data
    }

    struct HostRule {
        var manifestStatus: Int = 401
        var blobStatus: Int = 401
        var networkError = false
        var malformedManifest = false
        var tar: Data?
        var digest: String = PrivateFeatureGitCloneSupport.successDigest
        /// When set, the manifest lists these digests and blob requests are consumed in order.
        var layerDigests: [String] = []
        var blobs: [BlobResponse] = []
    }

    struct Script {
        var hosts: [String: HostRule] = [:]
    }

    nonisolated(unsafe) static var script = Script()

    final class BlobCursor: @unchecked Sendable {
        private let lock = NSLock()
        private var indexByHost: [String: Int] = [:]

        func reset() {
            lock.lock()
            indexByHost = [:]
            lock.unlock()
        }

        func next(host: String) -> Int {
            lock.lock()
            defer { lock.unlock() }
            let index = indexByHost[host] ?? 0
            indexByHost[host] = index + 1
            return index
        }
    }

    nonisolated(unsafe) static var blobCursor = BlobCursor()

    final class FakeGit: ProcessRunning, @unchecked Sendable {
        struct Call: Equatable {
            var executable: String
            var arguments: [String]
            var environment: [String: String]?
            var currentDirectory: String?
        }

        var calls: [Call] = []
        var exitCode: Int32 = 0
        var stderr = Data()
        /// Clone URL → directory whose contents are copied into the destination argument.
        var treesByURL: [String: String] = [:]
        var cloneDestinations: [String] = []
        /// When set, a relative `GIT_TRACE` in the effective git environment is written here,
        /// the way host git would write it into the workspace cwd.
        var traceWorkspace: String?

        var cloneCalls: [Call] {
            calls.filter { $0.arguments.contains("clone") }
        }

        func run(
            executable: String,
            arguments: [String],
            environment: [String: String]?,
            currentDirectory: String?,
            stdinData: Data?
        ) throws -> ProcessResult {
            calls.append(Call(
                executable: executable,
                arguments: arguments,
                environment: environment,
                currentDirectory: currentDirectory
            ))
            if let traceWorkspace {
                let effective = environment ?? ProcessInfo.processInfo.environment.merging(liveTraceOverlay()) { _, live in live }
                if let trace = effective["GIT_TRACE"], !trace.isEmpty, !trace.hasPrefix("/") {
                    let path = (traceWorkspace as NSString).appendingPathComponent(trace)
                    try? Data("trace-leak\n".utf8).write(to: URL(fileURLWithPath: path))
                }
            }
            if exitCode != 0 {
                return ProcessResult(exitCode: exitCode, stdout: Data(), stderr: stderr)
            }
            if let url = arguments.first(where: { $0.hasPrefix("https://") || $0.hasPrefix("ssh://") || $0.hasPrefix("git@") }),
               let urlIndex = arguments.firstIndex(of: url),
               urlIndex + 1 < arguments.count {
                let dest = arguments[urlIndex + 1]
                cloneDestinations.append(dest)
                if let tree = treesByURL[url] {
                    try FileManager.default.createDirectory(atPath: dest, withIntermediateDirectories: true)
                    try copyTree(from: tree, to: dest)
                }
            }
            return ProcessResult(exitCode: 0, stdout: Data(), stderr: stderr)
        }

        /// Variables a nil inherit would pass to git even when `ProcessInfo` is a stale snapshot.
        private func liveTraceOverlay() -> [String: String] {
            var overlay: [String: String] = [:]
            for key in [
                "GIT_TRACE", "GIT_TRACE_PACKET", "GIT_TRACE_PERFORMANCE", "GIT_TRACE_SETUP",
                "GIT_CURL_VERBOSE", "GCM_TRACE", "GH_DEBUG", "GH_FORCE_TTY", "GCM_DEBUG",
                "ADEVCONTAINER_GIT_TOKEN", "SSH_AUTH_SOCK"
            ] {
                if let value = getenv(key) {
                    overlay[key] = String(cString: value)
                }
            }
            return overlay
        }

        private func copyTree(from source: String, to dest: String) throws {
            let fm = FileManager.default
            let names = try fm.contentsOfDirectory(atPath: source)
            for name in names {
                let from = (source as NSString).appendingPathComponent(name)
                let to = (dest as NSString).appendingPathComponent(name)
                if fm.fileExists(atPath: to) {
                    try fm.removeItem(atPath: to)
                }
                try fm.copyItem(atPath: from, toPath: to)
            }
        }
    }

    static func install(git: FakeGit, gitMissing: Bool = false) -> () -> Void {
        let previousSession = OCIFeatureClient.sessionOverride
        let previousRunner = OCIFeatureClient.gitRunnerOverride
        let previousPath = OCIFeatureClient.gitPathOverride
        let previousScript = script
        blobCursor.reset()
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [PrivateFeatureHTTPProtocol.self]
        OCIFeatureClient.sessionOverride = URLSession(configuration: config)
        OCIFeatureClient.gitRunnerOverride = git
        OCIFeatureClient.gitPathOverride = gitMissing ? .some(nil) : .some("/usr/bin/git")
        return {
            OCIFeatureClient.sessionOverride = previousSession
            OCIFeatureClient.gitRunnerOverride = previousRunner
            OCIFeatureClient.gitPathOverride = previousPath
            script = previousScript
        }
    }

    static func authRule(_ status: Int) -> HostRule {
        HostRule(manifestStatus: status, blobStatus: status)
    }

    static func successRule(marker: String, id: String) throws -> HostRule {
        HostRule(manifestStatus: 200, blobStatus: 200, tar: try featureTar(id: id, marker: marker))
    }

    static func gitFeatureRule() throws -> HostRule {
        let fixture = TestRepo.root().appendingPathComponent("Tests/Fixtures/features-sample/git").path
        return HostRule(manifestStatus: 200, blobStatus: 200, tar: try tarOfPackage(fixture))
    }

    static func writePackage(at directory: String, id: String, marker: String) throws {
        let fm = FileManager.default
        try fm.createDirectory(atPath: directory, withIntermediateDirectories: true)
        let meta = """
        { "id": "\(id)", "version": "1.0.0", "name": "\(id)" }
        """
        try meta.write(
            toFile: (directory as NSString).appendingPathComponent("devcontainer-feature.json"),
            atomically: true,
            encoding: .utf8
        )
        try "echo \(marker)\n".write(
            toFile: (directory as NSString).appendingPathComponent("install.sh"),
            atomically: true,
            encoding: .utf8
        )
    }

    static func makeCollection(
        featureIds: [String],
        srcMarkers: [String: String] = [:],
        rootMarker: String? = nil,
        srcPartial: Set<String> = []
    ) throws -> String {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("adev-coll-\(UUID().uuidString)", isDirectory: true).path
        try FileManager.default.createDirectory(atPath: root, withIntermediateDirectories: true)
        for id in featureIds {
            if let marker = srcMarkers[id] {
                let src = (root as NSString).appendingPathComponent("src/\(id)")
                if srcPartial.contains(id) {
                    try FileManager.default.createDirectory(atPath: src, withIntermediateDirectories: true)
                    try "{ \"id\": \"\(id)\" }\n".write(
                        toFile: (src as NSString).appendingPathComponent("devcontainer-feature.json"),
                        atomically: true,
                        encoding: .utf8
                    )
                } else {
                    try writePackage(at: src, id: id, marker: marker)
                }
            }
        }
        if let rootMarker {
            try writePackage(at: root, id: featureIds.first ?? "root", marker: rootMarker)
        }
        return root
    }

    static func featureTar(id: String, marker: String) throws -> Data {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("adev-oci-pkg-\(UUID().uuidString)", isDirectory: true).path
        defer { try? FileManager.default.removeItem(atPath: dir) }
        try writePackage(at: dir, id: id, marker: marker)
        return try tarOfPackage(dir)
    }

    static func tarOfNamedFiles(_ files: [String: String]) throws -> Data {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("adev-oci-files-\(UUID().uuidString)", isDirectory: true).path
        defer { try? FileManager.default.removeItem(atPath: dir) }
        try FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
        for (name, contents) in files {
            try contents.write(
                toFile: (dir as NSString).appendingPathComponent(name),
                atomically: true,
                encoding: .utf8
            )
        }
        let tar = FileManager.default.temporaryDirectory
            .appendingPathComponent("adev-oci-layer-\(UUID().uuidString).tar").path
        defer { try? FileManager.default.removeItem(atPath: tar) }
        let result = try FoundationProcessRunner().run(
            executable: "/usr/bin/tar",
            arguments: ["cf", tar, "-C", dir] + files.keys.sorted(),
            environment: nil,
            currentDirectory: nil
        )
        guard result.succeeded else {
            throw MiniTest.Failure(message: "failed to build layer tar: \(result.stderrString)")
        }
        return try Data(contentsOf: URL(fileURLWithPath: tar))
    }

    static func tarOfPackage(_ directory: String) throws -> Data {
        let tar = FileManager.default.temporaryDirectory
            .appendingPathComponent("adev-oci-layer-\(UUID().uuidString).tar").path
        defer { try? FileManager.default.removeItem(atPath: tar) }
        let result = try FoundationProcessRunner().run(
            executable: "/usr/bin/tar",
            arguments: ["cf", tar, "-C", directory, "devcontainer-feature.json", "install.sh"],
            environment: nil,
            currentDirectory: nil
        )
        guard result.succeeded else {
            throw MiniTest.Failure(message: "failed to build feature tar: \(result.stderrString)")
        }
        return try Data(contentsOf: URL(fileURLWithPath: tar))
    }

    static func destination() -> String {
        FileManager.default.temporaryDirectory
            .appendingPathComponent("adev-feat-dest-\(UUID().uuidString)", isDirectory: true).path
    }

    static func marker(in packageDir: String) throws -> String {
        try String(
            contentsOfFile: (packageDir as NSString).appendingPathComponent("install.sh"),
            encoding: .utf8
        )
    }

    static func assertNoToken(_ text: String, _ label: String) throws {
        try MiniTest.expect(!text.contains(fixtureToken), "\(label) must not contain the fixture token")
    }

    static func assertFallbackError(_ error: Error, ref: String) throws {
        guard let err = error as? CLIError else {
            throw MiniTest.Failure(message: "expected CLIError for \(ref), got \(type(of: error)): \(error)")
        }
        try MiniTest.expectEqual(err.code, CLIErrorCode.featureFetch)
        try MiniTest.expect(err.message.contains(ref), "error must name \(ref), got: \(err.message)")
        try MiniTest.expect(
            err.message.contains("OCI authentication failed"),
            "error must state OCI authentication failed, got: \(err.message)"
        )
        try MiniTest.expect(
            err.message.contains("git fallback failed"),
            "error must state the git fallback failed, got: \(err.message)"
        )
        let json = try err.jsonString()
        try assertNoToken(json, "error JSON")
        try assertNoToken(err.message, "error message")
        try assertNoToken(err.hint ?? "", "error hint")
    }

    static let strippedGitEnvironmentKeys = [
        "GIT_TRACE", "GIT_TRACE_PACKET", "GIT_TRACE_PERFORMANCE", "GIT_TRACE_SETUP",
        "GIT_CURL_VERBOSE", "GCM_TRACE", "GH_DEBUG", "GH_FORCE_TTY", "GCM_DEBUG",
        "ADEVCONTAINER_GIT_TOKEN"
    ]

    static func assertCloneInvocation(_ call: FakeGit.Call, url: String, forbidden: [String] = []) throws {
        guard let env = call.environment else {
            throw MiniTest.Failure(message: "git must receive the host environment so credential helpers apply, not a nil inherit that keeps GIT_TRACE")
        }
        try MiniTest.expect(env["PATH"] != nil, "git must inherit host PATH")
        for key in strippedGitEnvironmentKeys {
            try MiniTest.expect(env[key] == nil, "git environment must strip \(key)")
        }
        try MiniTest.expect(!env.values.contains(fixtureToken), "git environment must not contain the fixture token")
        try MiniTest.expect(call.arguments.contains(url), "argv must include \(url), got \(call.arguments)")
        let joined = call.arguments.joined(separator: " ")
        try assertNoToken(joined, "git argv")
        try MiniTest.expect(!joined.contains("password"), "git argv must not pass a password: \(call.arguments)")
        try MiniTest.expect(!call.arguments.contains { $0.hasPrefix("ssh://") || $0.hasPrefix("git@") }, "must not synthesize an SSH URL: \(call.arguments)")
        try MiniTest.expect(!call.arguments.contains("-b") && !call.arguments.contains("--branch"), "must not check out a git ref: \(call.arguments)")
        for item in forbidden {
            try MiniTest.expect(!joined.contains(item), "argv must not contain \(item): \(call.arguments)")
        }
        try MiniTest.expect(call.executable.hasSuffix("/git") || call.executable == "git", "must invoke git, got \(call.executable)")
    }

    static func listing(_ path: String) -> [String] {
        (try? FileManager.default.subpathsOfDirectory(atPath: path)) ?? []
    }

    static func captureStatus(enabled: Bool, _ body: () throws -> Void) throws -> String {
        let previousEnabled = StatusPrinter.enabled
        let previousWrite = StatusPrinter.writeStderr
        let previousPhase = StatusPrinter.hasEmittedPhase
        let previousColor = TerminalStyle.colorOverride
        defer {
            StatusPrinter.enabled = previousEnabled
            StatusPrinter.writeStderr = previousWrite
            StatusPrinter.hasEmittedPhase = previousPhase
            TerminalStyle.colorOverride = previousColor
        }
        TerminalStyle.colorOverride = false
        StatusPrinter.enabled = enabled
        StatusPrinter.resetSectionState()
        var buffer = Data()
        StatusPrinter.writeStderr = { buffer.append($0) }
        try body()
        return String(data: buffer, encoding: .utf8) ?? ""
    }

    static func tempChildren(prefix: String) -> Set<String> {
        let root = FileManager.default.temporaryDirectory
        let names = (try? FileManager.default.contentsOfDirectory(atPath: root.path)) ?? []
        return Set(names.filter { $0.hasPrefix(prefix) })
    }
}

final class PrivateFeatureHTTPProtocol: URLProtocol, @unchecked Sendable {
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        let url = request.url ?? URL(string: "https://invalid.example/")!
        let path = url.path
        let host = url.host ?? ""
        if path.contains("/token") {
            let body = (try? JSONSerialization.data(withJSONObject: ["token": PrivateFeatureGitCloneSupport.fixtureToken])) ?? Data()
            finish(status: 200, body: body, url: url)
            return
        }
        guard let rule = PrivateFeatureGitCloneSupport.script.hosts[host] else {
            finish(status: 401, body: Data(), url: url)
            return
        }
        if rule.networkError {
            client?.urlProtocol(self, didFailWithError: URLError(.cannotConnectToHost))
            return
        }
        if path.contains("/manifests") {
            if rule.malformedManifest {
                finish(status: 200, body: Data("not-json".utf8), url: url)
                return
            }
            if rule.manifestStatus == 200 {
                let digests = rule.layerDigests.isEmpty ? [rule.digest] : rule.layerDigests
                let layers = digests.map { digest in
                    ["digest": digest, "mediaType": "application/vnd.oci.image.layer.v1.tar"]
                }
                let manifest: [String: Any] = [
                    "schemaVersion": 2,
                    "layers": layers
                ]
                let body = (try? JSONSerialization.data(withJSONObject: manifest)) ?? Data()
                finish(status: 200, body: body, url: url)
                return
            }
            finish(status: rule.manifestStatus, body: Data(), url: url)
            return
        }
        if path.contains("/blobs") {
            if !rule.blobs.isEmpty {
                let index = PrivateFeatureGitCloneSupport.blobCursor.next(host: host)
                if index < rule.blobs.count {
                    let blob = rule.blobs[index]
                    finish(status: blob.status, body: blob.body, url: url)
                    return
                }
            }
            if rule.blobStatus == 200, let tar = rule.tar {
                finish(status: 200, body: tar, url: url)
                return
            }
            finish(status: rule.blobStatus, body: Data(), url: url)
            return
        }
        finish(status: 404, body: Data(), url: url)
    }

    override func stopLoading() {}

    private func finish(status: Int, body: Data, url: URL) {
        let response = HTTPURLResponse(url: url, statusCode: status, httpVersion: nil, headerFields: nil)!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: body)
        client?.urlProtocolDidFinishLoading(self)
    }
}

// MARK: - Unit tests

nonisolated(unsafe) let privateFeatureGitCloneTests: [(String, () throws -> Void)] = [
    ("collectionURLStripsTagAndDigest", {
        let git = PrivateFeatureGitCloneSupport.FakeGit()
        let restore = PrivateFeatureGitCloneSupport.install(git: git)
        defer { restore() }
        let tree = try PrivateFeatureGitCloneSupport.makeCollection(
            featureIds: ["feature"],
            srcMarkers: ["feature": "tip-marker"]
        )
        git.treesByURL[PrivateFeatureGitCloneSupport.collectionURL] = tree
        PrivateFeatureGitCloneSupport.script.hosts = [
            "some.private.registry": PrivateFeatureGitCloneSupport.authRule(401)
        ]
        let client = OCIFeatureClient()
        let tagDest = PrivateFeatureGitCloneSupport.destination()
        let tagPkg = try client.fetch(reference: PrivateFeatureGitCloneSupport.tagRef, destinationDirectory: tagDest)
        try MiniTest.expectEqual(tagPkg.reference, PrivateFeatureGitCloneSupport.tagRef)
        try MiniTest.expectEqual(git.cloneCalls.count, 1)
        try PrivateFeatureGitCloneSupport.assertCloneInvocation(
            git.cloneCalls[0],
            url: PrivateFeatureGitCloneSupport.collectionURL,
            forbidden: [":1", PrivateFeatureGitCloneSupport.digest, "sha256:"]
        )

        let digestGit = PrivateFeatureGitCloneSupport.FakeGit()
        OCIFeatureClient.gitRunnerOverride = digestGit
        digestGit.treesByURL[PrivateFeatureGitCloneSupport.collectionURL] = tree
        let digestClient = OCIFeatureClient()
        let digestDest = PrivateFeatureGitCloneSupport.destination()
        _ = try digestClient.fetch(reference: PrivateFeatureGitCloneSupport.digestRef, destinationDirectory: digestDest)
        try MiniTest.expectEqual(digestGit.cloneCalls.count, 1)
        try PrivateFeatureGitCloneSupport.assertCloneInvocation(
            digestGit.cloneCalls[0],
            url: PrivateFeatureGitCloneSupport.collectionURL,
            forbidden: [PrivateFeatureGitCloneSupport.digest, "sha256:"]
        )
        try MiniTest.expect(try PrivateFeatureGitCloneSupport.marker(in: tagDest).contains("tip-marker"))
        try MiniTest.expect(try PrivateFeatureGitCloneSupport.marker(in: digestDest).contains("tip-marker"))
    }),

    ("ociRefWithNoCollectionSegmentFailsStructured", {
        let git = PrivateFeatureGitCloneSupport.FakeGit()
        let restore = PrivateFeatureGitCloneSupport.install(git: git)
        defer { restore() }
        PrivateFeatureGitCloneSupport.script.hosts = [
            "some.private.registry": PrivateFeatureGitCloneSupport.authRule(401)
        ]
        let client = OCIFeatureClient()
        try MiniTest.expectThrows({
            _ = try client.fetch(
                reference: PrivateFeatureGitCloneSupport.noCollectionRef,
                destinationDirectory: PrivateFeatureGitCloneSupport.destination()
            )
        }) { error in
            try PrivateFeatureGitCloneSupport.assertFallbackError(error, ref: PrivateFeatureGitCloneSupport.noCollectionRef)
            let err = error as! CLIError
            let blob = err.message + (err.hint ?? "") + (try err.jsonString())
            try MiniTest.expect(!blob.contains("https://"), "must not invent a clone URL, got: \(blob)")
        }
        try MiniTest.expect(git.calls.isEmpty, "must not invoke git when there is no collection segment")
    }),

    ("http401And403LoadPackageWithoutRewritingKey", {
        for status in [401, 403] {
            let git = PrivateFeatureGitCloneSupport.FakeGit()
            let restore = PrivateFeatureGitCloneSupport.install(git: git)
            defer { restore() }
            let tree = try PrivateFeatureGitCloneSupport.makeCollection(
                featureIds: ["feature"],
                srcMarkers: ["feature": "loaded-\(status)"]
            )
            git.treesByURL[PrivateFeatureGitCloneSupport.collectionURL] = tree
            PrivateFeatureGitCloneSupport.script.hosts = [
                "some.private.registry": PrivateFeatureGitCloneSupport.authRule(status)
            ]
            let configDir = FileManager.default.temporaryDirectory
                .appendingPathComponent("adev-cfg-\(UUID().uuidString)", isDirectory: true).path
            try FileManager.default.createDirectory(atPath: configDir, withIntermediateDirectories: true)
            let configPath = (configDir as NSString).appendingPathComponent("devcontainer.json")
            let original = """
            { "image": "alpine:3.20", "features": { "\(PrivateFeatureGitCloneSupport.tagRef)": {} } }
            """
            try original.write(toFile: configPath, atomically: true, encoding: .utf8)
            let before = try Data(contentsOf: URL(fileURLWithPath: configPath))
            let pkg = try OCIFeatureClient().fetch(
                reference: PrivateFeatureGitCloneSupport.tagRef,
                destinationDirectory: PrivateFeatureGitCloneSupport.destination()
            )
            let after = try Data(contentsOf: URL(fileURLWithPath: configPath))
            try MiniTest.expectEqual(pkg.reference, PrivateFeatureGitCloneSupport.tagRef)
            try MiniTest.expectEqual(before, after, "devcontainer.json bytes must stay unchanged")
            try MiniTest.expect(try PrivateFeatureGitCloneSupport.marker(in: pkg.directoryPath).contains("loaded-\(status)"))
            try MiniTest.expectEqual(git.cloneCalls.count, 1)
        }
    }),

    ("blob401And403LoadPackage", {
        for status in [401, 403] {
            let git = PrivateFeatureGitCloneSupport.FakeGit()
            let restore = PrivateFeatureGitCloneSupport.install(git: git)
            defer { restore() }
            let tree = try PrivateFeatureGitCloneSupport.makeCollection(
                featureIds: ["feature"],
                srcMarkers: ["feature": "blob-\(status)"]
            )
            git.treesByURL[PrivateFeatureGitCloneSupport.collectionURL] = tree
            PrivateFeatureGitCloneSupport.script.hosts = [
                "some.private.registry": PrivateFeatureGitCloneSupport.HostRule(
                    manifestStatus: 200,
                    blobStatus: status,
                    tar: Data("not-used".utf8)
                )
            ]
            let pkg = try OCIFeatureClient().fetch(
                reference: PrivateFeatureGitCloneSupport.tagRef,
                destinationDirectory: PrivateFeatureGitCloneSupport.destination()
            )
            try MiniTest.expectEqual(pkg.reference, PrivateFeatureGitCloneSupport.tagRef)
            try MiniTest.expect(try PrivateFeatureGitCloneSupport.marker(in: pkg.directoryPath).contains("blob-\(status)"))
        }
    }),

    ("successfulOCIFetchDoesNotClone", {
        let git = PrivateFeatureGitCloneSupport.FakeGit()
        let restore = PrivateFeatureGitCloneSupport.install(git: git)
        defer { restore() }
        PrivateFeatureGitCloneSupport.script.hosts = [
            "ghcr.io": try PrivateFeatureGitCloneSupport.successRule(marker: "oci-only", id: "sample")
        ]
        let pkg = try OCIFeatureClient().fetch(
            reference: PrivateFeatureGitCloneSupport.successRef,
            destinationDirectory: PrivateFeatureGitCloneSupport.destination()
        )
        try MiniTest.expectEqual(pkg.reference, PrivateFeatureGitCloneSupport.successRef)
        try MiniTest.expect(try PrivateFeatureGitCloneSupport.marker(in: pkg.directoryPath).contains("oci-only"))
        try MiniTest.expect(git.calls.isEmpty, "successful OCI fetch must not clone")
        try MiniTest.expect(!git.calls.contains {
            $0.executable.contains("container") || $0.executable.contains("oras") || $0.executable.contains("node")
        })
    }),

    ("successfulOCIFeatureBesideAuthFailureStaysOnOCI", {
        let git = PrivateFeatureGitCloneSupport.FakeGit()
        let restore = PrivateFeatureGitCloneSupport.install(git: git)
        defer { restore() }
        let tree = try PrivateFeatureGitCloneSupport.makeCollection(
            featureIds: ["feature"],
            srcMarkers: ["feature": "from-git"]
        )
        git.treesByURL[PrivateFeatureGitCloneSupport.collectionURL] = tree
        PrivateFeatureGitCloneSupport.script.hosts = [
            "ghcr.io": try PrivateFeatureGitCloneSupport.successRule(marker: "from-oci", id: "sample"),
            "some.private.registry": PrivateFeatureGitCloneSupport.authRule(401)
        ]
        let client = OCIFeatureClient()
        let ociPkg = try client.fetch(
            reference: PrivateFeatureGitCloneSupport.successRef,
            destinationDirectory: PrivateFeatureGitCloneSupport.destination()
        )
        let gitPkg = try client.fetch(
            reference: PrivateFeatureGitCloneSupport.tagRef,
            destinationDirectory: PrivateFeatureGitCloneSupport.destination()
        )
        try MiniTest.expect(try PrivateFeatureGitCloneSupport.marker(in: ociPkg.directoryPath).contains("from-oci"))
        try MiniTest.expect(try PrivateFeatureGitCloneSupport.marker(in: gitPkg.directoryPath).contains("from-git"))
        try MiniTest.expectEqual(git.cloneCalls.count, 1)
        try MiniTest.expectEqual(git.cloneCalls[0].arguments.contains(PrivateFeatureGitCloneSupport.collectionURL), true)
        try MiniTest.expect(!git.cloneCalls.contains { $0.arguments.contains { $0.contains("ghcr.io") } }, "successful OCI feature must not be cloned")
    }),

    ("fetch404IsStructuredFailure", {
        let git = PrivateFeatureGitCloneSupport.FakeGit()
        let restore = PrivateFeatureGitCloneSupport.install(git: git)
        defer { restore() }
        PrivateFeatureGitCloneSupport.script.hosts = [
            "some.private.registry": PrivateFeatureGitCloneSupport.authRule(404)
        ]
        try MiniTest.expectThrows({
            _ = try OCIFeatureClient().fetch(
                reference: PrivateFeatureGitCloneSupport.tagRef,
                destinationDirectory: PrivateFeatureGitCloneSupport.destination()
            )
        }) { error in
            let err = error as! CLIError
            try MiniTest.expectEqual(err.code, CLIErrorCode.featureFetch)
            try MiniTest.expect(err.message.contains(PrivateFeatureGitCloneSupport.tagRef))
            try MiniTest.expect(err.message.contains("404"))
        }
        try MiniTest.expect(git.calls.isEmpty, "404 must not clone")
    }),

    ("nonAuthOCIFailureDoesNotClone", {
        let cases: [(String, PrivateFeatureGitCloneSupport.HostRule)] = [
            ("network", PrivateFeatureGitCloneSupport.HostRule(networkError: true)),
            ("malformed", PrivateFeatureGitCloneSupport.HostRule(manifestStatus: 200, malformedManifest: true)),
            ("http500", PrivateFeatureGitCloneSupport.authRule(500)),
            ("http429", PrivateFeatureGitCloneSupport.authRule(429))
        ]
        for (name, rule) in cases {
            let git = PrivateFeatureGitCloneSupport.FakeGit()
            let restore = PrivateFeatureGitCloneSupport.install(git: git)
            defer { restore() }
            PrivateFeatureGitCloneSupport.script.hosts = ["some.private.registry": rule]
            try MiniTest.expectThrows({
                _ = try OCIFeatureClient().fetch(
                    reference: PrivateFeatureGitCloneSupport.tagRef,
                    destinationDirectory: PrivateFeatureGitCloneSupport.destination()
                )
            }) { error in
                guard let err = error as? CLIError else {
                    throw MiniTest.Failure(message: "\(name) threw \(type(of: error)): \(error)")
                }
                try MiniTest.expectEqual(err.code, CLIErrorCode.featureFetch, name)
                try MiniTest.expect(err.message.contains(PrivateFeatureGitCloneSupport.tagRef), "\(name): \(err.message)")
            }
            try MiniTest.expect(git.calls.isEmpty, "\(name) must not clone")
        }
    }),

    ("hostGitCredentialsApplyWithoutProductSecrets", {
        let git = PrivateFeatureGitCloneSupport.FakeGit()
        git.stderr = Data(PrivateFeatureGitCloneSupport.fixtureToken.utf8)
        let restore = PrivateFeatureGitCloneSupport.install(git: git)
        defer { restore() }
        let tree = try PrivateFeatureGitCloneSupport.makeCollection(
            featureIds: ["feature"],
            srcMarkers: ["feature": "cred-ok"]
        )
        git.treesByURL[PrivateFeatureGitCloneSupport.collectionURL] = tree
        PrivateFeatureGitCloneSupport.script.hosts = [
            "some.private.registry": PrivateFeatureGitCloneSupport.authRule(401)
        ]
        _ = try OCIFeatureClient().fetch(
            reference: PrivateFeatureGitCloneSupport.tagRef,
            destinationDirectory: PrivateFeatureGitCloneSupport.destination()
        )
        try MiniTest.expectEqual(git.cloneCalls.count, 1)
        try PrivateFeatureGitCloneSupport.assertCloneInvocation(
            git.cloneCalls[0],
            url: PrivateFeatureGitCloneSupport.collectionURL,
            forbidden: ["Authorization", "Bearer", "insteadOf", "credential.helper"]
        )
    }),

    ("registryLoginTokenIsNotForwarded", {
        let git = PrivateFeatureGitCloneSupport.FakeGit()
        git.exitCode = 128
        git.stderr = Data("auth failed \(PrivateFeatureGitCloneSupport.fixtureToken)".utf8)
        let restore = PrivateFeatureGitCloneSupport.install(git: git)
        defer { restore() }
        PrivateFeatureGitCloneSupport.script.hosts = [
            "some.private.registry": PrivateFeatureGitCloneSupport.authRule(401)
        ]
        let dest = PrivateFeatureGitCloneSupport.destination()
        try MiniTest.expectThrows({
            _ = try OCIFeatureClient().fetch(reference: PrivateFeatureGitCloneSupport.tagRef, destinationDirectory: dest)
        }) { error in
            try PrivateFeatureGitCloneSupport.assertFallbackError(error, ref: PrivateFeatureGitCloneSupport.tagRef)
        }
        try MiniTest.expectEqual(git.cloneCalls.count, 1)
        try PrivateFeatureGitCloneSupport.assertCloneInvocation(
            git.cloneCalls[0],
            url: PrivateFeatureGitCloneSupport.collectionURL
        )
        let env = git.cloneCalls[0].environment ?? [:]
        try MiniTest.expect(!env.values.contains(PrivateFeatureGitCloneSupport.fixtureToken), "must not inject the registry token into git's environment")
        let meta = (dest as NSString).appendingPathComponent("devcontainer-feature.json")
        let install = (dest as NSString).appendingPathComponent("install.sh")
        try MiniTest.expect(
            !FileManager.default.fileExists(atPath: meta) || !FileManager.default.fileExists(atPath: install),
            "must not return a partial package"
        )
    }),

    ("packageLookupPrefersSrc", {
        let git = PrivateFeatureGitCloneSupport.FakeGit()
        let restore = PrivateFeatureGitCloneSupport.install(git: git)
        defer { restore() }
        let tree = try PrivateFeatureGitCloneSupport.makeCollection(
            featureIds: ["feature"],
            srcMarkers: ["feature": "from-src"],
            rootMarker: "from-root"
        )
        git.treesByURL[PrivateFeatureGitCloneSupport.collectionURL] = tree
        PrivateFeatureGitCloneSupport.script.hosts = [
            "some.private.registry": PrivateFeatureGitCloneSupport.authRule(403)
        ]
        let pkg = try OCIFeatureClient().fetch(
            reference: PrivateFeatureGitCloneSupport.tagRef,
            destinationDirectory: PrivateFeatureGitCloneSupport.destination()
        )
        try MiniTest.expect(try PrivateFeatureGitCloneSupport.marker(in: pkg.directoryPath).contains("from-src"))
        try MiniTest.expect(!((try PrivateFeatureGitCloneSupport.marker(in: pkg.directoryPath)).contains("from-root")))
    }),

    ("packageLookupUsesRepositoryRootWhenSrcIsNotValid", {
        let git = PrivateFeatureGitCloneSupport.FakeGit()
        let restore = PrivateFeatureGitCloneSupport.install(git: git)
        defer { restore() }
        let absent = try PrivateFeatureGitCloneSupport.makeCollection(
            featureIds: ["feature"],
            rootMarker: "root-only"
        )
        git.treesByURL[PrivateFeatureGitCloneSupport.collectionURL] = absent
        PrivateFeatureGitCloneSupport.script.hosts = [
            "some.private.registry": PrivateFeatureGitCloneSupport.authRule(401)
        ]
        let absentPkg = try OCIFeatureClient().fetch(
            reference: PrivateFeatureGitCloneSupport.tagRef,
            destinationDirectory: PrivateFeatureGitCloneSupport.destination()
        )
        try MiniTest.expect(try PrivateFeatureGitCloneSupport.marker(in: absentPkg.directoryPath).contains("root-only"))

        let partialGit = PrivateFeatureGitCloneSupport.FakeGit()
        OCIFeatureClient.gitRunnerOverride = partialGit
        let partial = try PrivateFeatureGitCloneSupport.makeCollection(
            featureIds: ["feature"],
            srcMarkers: ["feature": "ignored"],
            rootMarker: "root-wins",
            srcPartial: ["feature"]
        )
        partialGit.treesByURL[PrivateFeatureGitCloneSupport.collectionURL] = partial
        let partialPkg = try OCIFeatureClient().fetch(
            reference: PrivateFeatureGitCloneSupport.tagRef,
            destinationDirectory: PrivateFeatureGitCloneSupport.destination()
        )
        try MiniTest.expect(try PrivateFeatureGitCloneSupport.marker(in: partialPkg.directoryPath).contains("root-wins"))
    }),

    ("partialPackageIsNotUsed", {
        let git = PrivateFeatureGitCloneSupport.FakeGit()
        let restore = PrivateFeatureGitCloneSupport.install(git: git)
        defer { restore() }
        let tree = try PrivateFeatureGitCloneSupport.makeCollection(
            featureIds: ["feature"],
            srcMarkers: ["feature": "partial"],
            srcPartial: ["feature"]
        )
        git.treesByURL[PrivateFeatureGitCloneSupport.collectionURL] = tree
        PrivateFeatureGitCloneSupport.script.hosts = [
            "some.private.registry": PrivateFeatureGitCloneSupport.authRule(401)
        ]
        let dest = PrivateFeatureGitCloneSupport.destination()
        try MiniTest.expectThrows({
            _ = try OCIFeatureClient().fetch(reference: PrivateFeatureGitCloneSupport.tagRef, destinationDirectory: dest)
        }) { error in
            try PrivateFeatureGitCloneSupport.assertFallbackError(error, ref: PrivateFeatureGitCloneSupport.tagRef)
        }
        let meta = (dest as NSString).appendingPathComponent("devcontainer-feature.json")
        let install = (dest as NSString).appendingPathComponent("install.sh")
        try MiniTest.expect(
            !(FileManager.default.fileExists(atPath: meta) && FileManager.default.fileExists(atPath: install)),
            "must not install a partial package"
        )
    }),

    ("fallbackUsesCurrentDefaultBranchTip", {
        let git = PrivateFeatureGitCloneSupport.FakeGit()
        let restore = PrivateFeatureGitCloneSupport.install(git: git)
        defer { restore() }
        let tree = try PrivateFeatureGitCloneSupport.makeCollection(
            featureIds: ["feature"],
            srcMarkers: ["feature": "tip-v1"]
        )
        git.treesByURL[PrivateFeatureGitCloneSupport.collectionURL] = tree
        PrivateFeatureGitCloneSupport.script.hosts = [
            "some.private.registry": PrivateFeatureGitCloneSupport.authRule(401)
        ]
        let first = try OCIFeatureClient().fetch(
            reference: PrivateFeatureGitCloneSupport.tagRef,
            destinationDirectory: PrivateFeatureGitCloneSupport.destination()
        )
        try MiniTest.expect(try PrivateFeatureGitCloneSupport.marker(in: first.directoryPath).contains("tip-v1"))
        let install = (tree as NSString).appendingPathComponent("src/feature/install.sh")
        try "echo tip-v2\n".write(toFile: install, atomically: true, encoding: .utf8)
        let second = try OCIFeatureClient().fetch(
            reference: PrivateFeatureGitCloneSupport.tagRef,
            destinationDirectory: PrivateFeatureGitCloneSupport.destination()
        )
        try MiniTest.expect(try PrivateFeatureGitCloneSupport.marker(in: second.directoryPath).contains("tip-v2"), "later resolution must obtain the current tip")
        try MiniTest.expect(git.cloneCalls.count >= 2, "later resolution must not reuse an unchecked stale cache")
        try MiniTest.expect(!git.cloneCalls.contains { $0.arguments.contains("-b") || $0.arguments.contains(PrivateFeatureGitCloneSupport.digest) })
    }),

    ("oneCollectionCloneLoadsSeveralFeatures", {
        let git = PrivateFeatureGitCloneSupport.FakeGit()
        let restore = PrivateFeatureGitCloneSupport.install(git: git)
        defer { restore() }
        let tree = try PrivateFeatureGitCloneSupport.makeCollection(
            featureIds: ["feature-a", "feature-b"],
            srcMarkers: ["feature-a": "pkg-a", "feature-b": "pkg-b"]
        )
        git.treesByURL[PrivateFeatureGitCloneSupport.collectionURL] = tree
        PrivateFeatureGitCloneSupport.script.hosts = [
            "some.private.registry": PrivateFeatureGitCloneSupport.authRule(401)
        ]
        let client = OCIFeatureClient()
        let a = try client.fetch(
            reference: PrivateFeatureGitCloneSupport.featureARef,
            destinationDirectory: PrivateFeatureGitCloneSupport.destination()
        )
        let b = try client.fetch(
            reference: PrivateFeatureGitCloneSupport.featureBRef,
            destinationDirectory: PrivateFeatureGitCloneSupport.destination()
        )
        try MiniTest.expect(try PrivateFeatureGitCloneSupport.marker(in: a.directoryPath).contains("pkg-a"))
        try MiniTest.expect(try PrivateFeatureGitCloneSupport.marker(in: b.directoryPath).contains("pkg-b"))
        try MiniTest.expectEqual(git.cloneCalls.count, 1, "one resolution must clone the collection once")
        try MiniTest.expect(git.cloneCalls[0].arguments.contains(PrivateFeatureGitCloneSupport.collectionURL))
    }),

    ("cloneStaysOutsideTheWorkspace", {
        let git = PrivateFeatureGitCloneSupport.FakeGit()
        let restore = PrivateFeatureGitCloneSupport.install(git: git)
        defer { restore() }
        let workspace = FileManager.default.temporaryDirectory
            .appendingPathComponent("adev-ws-\(UUID().uuidString)", isDirectory: true).path
        try FileManager.default.createDirectory(atPath: workspace, withIntermediateDirectories: true)
        try "keep\n".write(toFile: (workspace as NSString).appendingPathComponent("marker.txt"), atomically: true, encoding: .utf8)
        let before = PrivateFeatureGitCloneSupport.listing(workspace)
        let tree = try PrivateFeatureGitCloneSupport.makeCollection(
            featureIds: ["feature"],
            srcMarkers: ["feature": "outside"]
        )
        git.treesByURL[PrivateFeatureGitCloneSupport.collectionURL] = tree
        PrivateFeatureGitCloneSupport.script.hosts = [
            "some.private.registry": PrivateFeatureGitCloneSupport.authRule(401)
        ]
        let dest = PrivateFeatureGitCloneSupport.destination()
        _ = try OCIFeatureClient().fetch(reference: PrivateFeatureGitCloneSupport.tagRef, destinationDirectory: dest)
        try MiniTest.expectEqual(PrivateFeatureGitCloneSupport.listing(workspace), before, "workspace must not be dirty")
        try MiniTest.expect(!git.cloneDestinations.isEmpty)
        for cloneDest in git.cloneDestinations {
            try MiniTest.expect(
                !cloneDest.hasPrefix(workspace + "/") && cloneDest != workspace,
                "clone \(cloneDest) must stay outside workspace \(workspace)"
            )
        }
        try MiniTest.expect(
            !dest.hasPrefix(workspace + "/") && dest != workspace,
            "feature cache destination must stay outside the workspace"
        )
    }),

    ("missingGitOrCredentialsFailsClosed", {
        let missing = PrivateFeatureGitCloneSupport.FakeGit()
        let restoreMissing = PrivateFeatureGitCloneSupport.install(git: missing, gitMissing: true)
        defer { restoreMissing() }
        PrivateFeatureGitCloneSupport.script.hosts = [
            "some.private.registry": PrivateFeatureGitCloneSupport.authRule(401)
        ]
        let missingDest = PrivateFeatureGitCloneSupport.destination()
        try MiniTest.expectThrows({
            _ = try OCIFeatureClient().fetch(
                reference: PrivateFeatureGitCloneSupport.tagRef,
                destinationDirectory: missingDest
            )
        }) { error in
            try PrivateFeatureGitCloneSupport.assertFallbackError(error, ref: PrivateFeatureGitCloneSupport.tagRef)
        }
        try MiniTest.expect(missing.calls.isEmpty, "missing git must not invoke a clone")
        try MiniTest.expect(!FileManager.default.fileExists(atPath: (missingDest as NSString).appendingPathComponent("install.sh")))

        let denied = PrivateFeatureGitCloneSupport.FakeGit()
        OCIFeatureClient.gitRunnerOverride = denied
        OCIFeatureClient.gitPathOverride = .some("/usr/bin/git")
        denied.exitCode = 128
        denied.stderr = Data(PrivateFeatureGitCloneSupport.fixtureToken.utf8)
        let deniedDest = PrivateFeatureGitCloneSupport.destination()
        try MiniTest.expectThrows({
            _ = try OCIFeatureClient().fetch(
                reference: PrivateFeatureGitCloneSupport.tagRef,
                destinationDirectory: deniedDest
            )
        }) { error in
            try PrivateFeatureGitCloneSupport.assertFallbackError(error, ref: PrivateFeatureGitCloneSupport.tagRef)
        }
        try MiniTest.expect(!FileManager.default.fileExists(atPath: (deniedDest as NSString).appendingPathComponent("install.sh")))
    }),

    ("statusReportsCloneAfterOCIAuthFailure", {
        let git = PrivateFeatureGitCloneSupport.FakeGit()
        let restore = PrivateFeatureGitCloneSupport.install(git: git)
        defer { restore() }
        let tree = try PrivateFeatureGitCloneSupport.makeCollection(
            featureIds: ["feature"],
            srcMarkers: ["feature": "status"]
        )
        git.treesByURL[PrivateFeatureGitCloneSupport.collectionURL] = tree
        PrivateFeatureGitCloneSupport.script.hosts = [
            "some.private.registry": PrivateFeatureGitCloneSupport.authRule(401)
        ]
        let loud = try PrivateFeatureGitCloneSupport.captureStatus(enabled: true) {
            _ = try OCIFeatureClient().fetch(
                reference: PrivateFeatureGitCloneSupport.tagRef,
                destinationDirectory: PrivateFeatureGitCloneSupport.destination()
            )
        }
        try MiniTest.expect(loud.contains("==> "), "status must use the ==> family, got: \(loud)")
        try MiniTest.expect(
            loud.contains("being cloned after OCI authentication failure")
                || loud.contains("cloned after OCI authentication failure"),
            "status must say the feature is being cloned after OCI authentication failure, got: \(loud)"
        )
        try MiniTest.expect(loud.contains(PrivateFeatureGitCloneSupport.tagRef), "status must name the ref, got: \(loud)")
        try PrivateFeatureGitCloneSupport.assertNoToken(loud, "status")
        let quiet = try PrivateFeatureGitCloneSupport.captureStatus(enabled: false) {
            _ = try OCIFeatureClient().fetch(
                reference: PrivateFeatureGitCloneSupport.tagRef,
                destinationDirectory: PrivateFeatureGitCloneSupport.destination()
            )
        }
        try MiniTest.expect(!quiet.contains("==>"), "StatusPrinter.enabled = false must silence the clone status, got: \(quiet)")
    }),

    ("gitContentDoesNotInvalidateIdentity", {
        try MiniTest.expectEqual(DerivedImageTag.recipeVersion, "7")
        let ref = PrivateFeatureGitCloneSupport.tagRef
        let meta = try FeatureMetadata.parse(
            data: Data(#"{ "id": "feature", "version": "1.0.0" }"#.utf8),
            featureRef: ref
        )
        let ordered = [
            FeatureOrder.OrderedFeature(
                admitted: AdmittedFeature(reference: ref, options: [:]),
                metadata: meta
            )
        ]
        let first = DerivedImageTag.compute(baseImage: "alpine:3.20", ordered: ordered, nameBase: "app")
        let second = DerivedImageTag.compute(baseImage: "alpine:3.20", ordered: ordered, nameBase: "app")
        try MiniTest.expectEqual(first, second, "git file content is not a hash input; the OCI ref string is")
        try MiniTest.expect(first.contains(":"))
        try MiniTest.expect(!first.contains("tip-v2"))
    }),

    ("fetchInvokesEmbeddedRegistryClientNotContainerPull", {
        let git = PrivateFeatureGitCloneSupport.FakeGit()
        let restore = PrivateFeatureGitCloneSupport.install(git: git)
        defer { restore() }
        PrivateFeatureGitCloneSupport.script.hosts = [
            "ghcr.io": try PrivateFeatureGitCloneSupport.successRule(marker: "embedded", id: "sample")
        ]
        let pkg = try OCIFeatureClient().fetch(
            reference: PrivateFeatureGitCloneSupport.successRef,
            destinationDirectory: PrivateFeatureGitCloneSupport.destination()
        )
        try MiniTest.expect(try PrivateFeatureGitCloneSupport.marker(in: pkg.directoryPath).contains("embedded"))
        try MiniTest.expect(git.calls.isEmpty)
        try MiniTest.expect(!git.calls.contains {
            let exe = $0.executable
            return exe.contains("container") || exe.contains("oras") || exe.contains("node")
        }, "fetch must not shell out to container image pull, ORAS, or Node")
    }),

    ("defaultFeatureFetcherHonorsSeam", {
        let git = PrivateFeatureGitCloneSupport.FakeGit()
        let restore = PrivateFeatureGitCloneSupport.install(git: git)
        defer { restore() }
        let tree = try PrivateFeatureGitCloneSupport.makeCollection(
            featureIds: ["feature"],
            srcMarkers: ["feature": "default-client"]
        )
        git.treesByURL[PrivateFeatureGitCloneSupport.collectionURL] = tree
        PrivateFeatureGitCloneSupport.script.hosts = [
            "some.private.registry": PrivateFeatureGitCloneSupport.authRule(403)
        ]
        let fetcher = DefaultFeatureFetcher(workspacePath: "/tmp/unused-workspace")
        let pkg = try fetcher.fetch(
            reference: PrivateFeatureGitCloneSupport.tagRef,
            destinationDirectory: PrivateFeatureGitCloneSupport.destination()
        )
        try MiniTest.expectEqual(pkg.reference, PrivateFeatureGitCloneSupport.tagRef)
        try MiniTest.expect(try PrivateFeatureGitCloneSupport.marker(in: pkg.directoryPath).contains("default-client"))
        try MiniTest.expectEqual(git.cloneCalls.count, 1)
    }),

    ("lateBlobAuthFailureDoesNotLeavePartialPackage", {
        let leftoverName = "oci-layer-leftover.txt"
        let layerTar = try PrivateFeatureGitCloneSupport.tarOfNamedFiles([
            leftoverName: "from-oci-layer\n"
        ])
        for status in [401, 403] {
            let git = PrivateFeatureGitCloneSupport.FakeGit()
            git.exitCode = 128
            git.stderr = Data(PrivateFeatureGitCloneSupport.fixtureToken.utf8)
            let restore = PrivateFeatureGitCloneSupport.install(git: git)
            defer { restore() }
            PrivateFeatureGitCloneSupport.script.hosts = [
                "some.private.registry": PrivateFeatureGitCloneSupport.HostRule(
                    manifestStatus: 200,
                    layerDigests: [
                        "sha256:bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb",
                        "sha256:cccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccc"
                    ],
                    blobs: [
                        PrivateFeatureGitCloneSupport.BlobResponse(status: 200, body: layerTar),
                        PrivateFeatureGitCloneSupport.BlobResponse(status: status, body: Data())
                    ]
                )
            ]
            let dest = PrivateFeatureGitCloneSupport.destination()
            try MiniTest.expectThrows({
                _ = try OCIFeatureClient().fetch(
                    reference: PrivateFeatureGitCloneSupport.tagRef,
                    destinationDirectory: dest
                )
            }) { error in
                try PrivateFeatureGitCloneSupport.assertFallbackError(error, ref: PrivateFeatureGitCloneSupport.tagRef)
            }
            let leftover = (dest as NSString).appendingPathComponent(leftoverName)
            try MiniTest.expect(!FileManager.default.fileExists(atPath: leftover), "HTTP \(status) fallback failure must not keep extracted OCI layers")
            let meta = (dest as NSString).appendingPathComponent("devcontainer-feature.json")
            let install = (dest as NSString).appendingPathComponent("install.sh")
            try MiniTest.expect(
                !FileManager.default.fileExists(atPath: meta) && !FileManager.default.fileExists(atPath: install),
                "HTTP \(status) fallback failure must not leave a package to install"
            )
        }
    }),

    ("lateBlobAuthFailureSuccessWritesOnlyGitPackage", {
        let leftoverName = "oci-layer-leftover.txt"
        let layerTar = try PrivateFeatureGitCloneSupport.tarOfNamedFiles([
            leftoverName: "from-oci-layer\n"
        ])
        for status in [401, 403] {
            let git = PrivateFeatureGitCloneSupport.FakeGit()
            let restore = PrivateFeatureGitCloneSupport.install(git: git)
            defer { restore() }
            let tree = try PrivateFeatureGitCloneSupport.makeCollection(
                featureIds: ["feature"],
                srcMarkers: ["feature": "git-only-\(status)"]
            )
            git.treesByURL[PrivateFeatureGitCloneSupport.collectionURL] = tree
            PrivateFeatureGitCloneSupport.script.hosts = [
                "some.private.registry": PrivateFeatureGitCloneSupport.HostRule(
                    manifestStatus: 200,
                    layerDigests: [
                        "sha256:dddddddddddddddddddddddddddddddddddddddddddddddddddddddddddddddd",
                        "sha256:eeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeee"
                    ],
                    blobs: [
                        PrivateFeatureGitCloneSupport.BlobResponse(status: 200, body: layerTar),
                        PrivateFeatureGitCloneSupport.BlobResponse(status: status, body: Data())
                    ]
                )
            ]
            let dest = PrivateFeatureGitCloneSupport.destination()
            let pkg = try OCIFeatureClient().fetch(
                reference: PrivateFeatureGitCloneSupport.tagRef,
                destinationDirectory: dest
            )
            try MiniTest.expect(try PrivateFeatureGitCloneSupport.marker(in: pkg.directoryPath).contains("git-only-\(status)"))
            let names = try FileManager.default.contentsOfDirectory(atPath: dest)
            try MiniTest.expect(!names.contains(leftoverName), "HTTP \(status) success must not keep OCI layer files, got \(names)")
            try MiniTest.expect(names.contains("devcontainer-feature.json"))
            try MiniTest.expect(names.contains("install.sh"))
            try MiniTest.expect(!names.contains { $0.hasPrefix(".") }, "must not keep OCI scratch, got \(names)")
        }
    }),

    ("gitCloneStripsTraceVariablesAndDoesNotWriteWorkspaceTrace", {
        let leakName = "adev-git-trace-leak.log"
        let workspace = FileManager.default.temporaryDirectory
            .appendingPathComponent("adev-trace-ws-\(UUID().uuidString)", isDirectory: true).path
        try FileManager.default.createDirectory(atPath: workspace, withIntermediateDirectories: true)
        let sock = "/tmp/adev-feature-agent.sock"
        let keys = [
            "GIT_TRACE": leakName,
            "GIT_TRACE_PACKET": "1",
            "GIT_CURL_VERBOSE": "1",
            "GCM_TRACE": "1",
            "GH_DEBUG": "1",
            "GCM_DEBUG": "1",
            "ADEVCONTAINER_GIT_TOKEN": PrivateFeatureGitCloneSupport.fixtureToken,
            "SSH_AUTH_SOCK": sock
        ]
        let previous = keys.keys.map { ($0, getenv($0).map { String(cString: $0) }) }
        defer {
            for (key, value) in previous {
                if let value {
                    setenv(key, value, 1)
                } else {
                    unsetenv(key)
                }
            }
            try? FileManager.default.removeItem(atPath: (workspace as NSString).appendingPathComponent(leakName))
            try? FileManager.default.removeItem(
                atPath: (FileManager.default.currentDirectoryPath as NSString).appendingPathComponent(leakName)
            )
        }
        for (key, value) in keys {
            setenv(key, value, 1)
        }
        let git = PrivateFeatureGitCloneSupport.FakeGit()
        git.traceWorkspace = workspace
        let restore = PrivateFeatureGitCloneSupport.install(git: git)
        defer { restore() }
        let tree = try PrivateFeatureGitCloneSupport.makeCollection(
            featureIds: ["feature"],
            srcMarkers: ["feature": "trace-ok"]
        )
        git.treesByURL[PrivateFeatureGitCloneSupport.collectionURL] = tree
        PrivateFeatureGitCloneSupport.script.hosts = [
            "some.private.registry": PrivateFeatureGitCloneSupport.authRule(401)
        ]
        _ = try OCIFeatureClient().fetch(
            reference: PrivateFeatureGitCloneSupport.tagRef,
            destinationDirectory: PrivateFeatureGitCloneSupport.destination()
        )
        let leakInWorkspace = (workspace as NSString).appendingPathComponent(leakName)
        let leakInCwd = (FileManager.default.currentDirectoryPath as NSString).appendingPathComponent(leakName)
        try MiniTest.expect(!FileManager.default.fileExists(atPath: leakInWorkspace), "relative GIT_TRACE must not create a file in the workspace")
        try MiniTest.expect(!FileManager.default.fileExists(atPath: leakInCwd), "relative GIT_TRACE must not create a file in the process cwd")
        try MiniTest.expectEqual(git.cloneCalls.count, 1)
        try PrivateFeatureGitCloneSupport.assertCloneInvocation(
            git.cloneCalls[0],
            url: PrivateFeatureGitCloneSupport.collectionURL
        )
        let env = git.cloneCalls[0].environment ?? [:]
        try MiniTest.expectEqual(env["SSH_AUTH_SOCK"], sock, "credential-helper environment must still be inherited")
        let hostNoSystem = getenv("GIT_CONFIG_NOSYSTEM").map { String(cString: $0) }
        try MiniTest.expectEqual(env["GIT_CONFIG_NOSYSTEM"], hostNoSystem, "must not disable host git config, so url.insteadOf still applies")
        try MiniTest.expect(!git.cloneCalls[0].arguments.contains { $0.contains("insteadOf") })
        try PrivateFeatureGitCloneSupport.assertNoToken(env.values.joined(separator: "\n"), "git environment")
    })
]
