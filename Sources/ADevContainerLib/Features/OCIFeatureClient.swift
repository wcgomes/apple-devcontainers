import Foundation
#if canImport(Darwin)
import Darwin
#endif
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

/// One git clone per collection on a single `OCIFeatureClient` value.
/// A new client (a later resolution) gets a new store and must clone again.
final class CollectionCloneStore: @unchecked Sendable {
    let lock = NSLock()
    var directories: [String: String] = [:]
    let root: String

    init() {
        root = FileManager.default.temporaryDirectory
            .appendingPathComponent("adev-feature-git-\(UUID().uuidString)", isDirectory: true)
            .path
    }
}

/// Git clone runner that assigns `process.environment` exactly.
/// `FoundationProcessRunner` merges onto the host environment and would put
/// `GIT_TRACE` back after this client strips it.
private struct ExactEnvironmentProcessRunner: ProcessRunning {
    func run(
        executable: String,
        arguments: [String],
        environment: [String: String]?,
        currentDirectory: String?,
        stdinData: Data?
    ) throws -> ProcessResult {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: executable)
        process.arguments = arguments
        process.environment = environment ?? OCIFeatureClient.strippedGitEnvironment()
        if let currentDirectory {
            process.currentDirectoryURL = URL(fileURLWithPath: currentDirectory)
        }
        let outPipe = Pipe()
        let errPipe = Pipe()
        process.standardOutput = outPipe
        process.standardError = errPipe
        process.standardInput = FileHandle.nullDevice

        final class Box: @unchecked Sendable {
            var value = Data()
        }
        let stdout = Box()
        let stderr = Box()
        let group = DispatchGroup()
        group.enter()
        DispatchQueue.global(qos: .userInitiated).async {
            stdout.value = outPipe.fileHandleForReading.readDataToEndOfFile()
            group.leave()
        }
        group.enter()
        DispatchQueue.global(qos: .userInitiated).async {
            stderr.value = errPipe.fileHandleForReading.readDataToEndOfFile()
            group.leave()
        }
        try process.run()
        process.waitUntilExit()
        group.wait()
        return ProcessResult(
            exitCode: process.terminationStatus,
            stdout: stdout.value,
            stderr: stderr.value
        )
    }
}

/// Embedded OCI distribution client for Dev Container **feature artifacts**.
///
/// Does **not** shell out to ORAS, Node, or Apple `container image pull`.
/// Uses HTTPS registry APIs (manifest → blob layers) via URLSession.
/// Layer unpack uses host `/usr/bin/tar` only (not a Features dependency).
public struct OCIFeatureClient: FeatureFetching, Sendable {
    /// Test seam honored by `OCIFeatureClient()` and therefore by `DefaultFeatureFetcher()`'s default client.
    /// Command tests leave `featuresFetcherOverride` nil and still inject HTTP and host git through these.
    nonisolated(unsafe) public static var sessionOverride: URLSession?
    nonisolated(unsafe) public static var gitRunnerOverride: (any ProcessRunning)?
    /// `.some(nil)` means host git is missing. `nil` means look up git on PATH.
    nonisolated(unsafe) public static var gitPathOverride: String??

    public var session: URLSession
    public var userAgent: String
    var gitRunner: any ProcessRunning
    var gitPathOverride: String??
    var collectionClones: CollectionCloneStore

    public init(session: URLSession = .shared, userAgent: String = "adevcontainer/features") {
        self.session = Self.sessionOverride ?? session
        self.userAgent = userAgent
        // Exact environment, not FoundationProcessRunner: that runner merges the
        // overlay back onto the host environment and would reintroduce GIT_TRACE.
        self.gitRunner = Self.gitRunnerOverride ?? ExactEnvironmentProcessRunner()
        self.gitPathOverride = Self.gitPathOverride
        self.collectionClones = CollectionCloneStore()
    }

    /// HTTP 401/403 from the embedded manifest or blob fetch. Not a user-facing error:
    /// `fetch` turns it into the host-git collection fallback.
    private struct OCIAuthenticationRejected: Error {}

    public func fetch(reference: String, destinationDirectory: String) throws -> FetchedFeaturePackage {
        let parsed = try parseReference(reference)
        do {
            return try fetchOCI(reference: reference, parsed: parsed, destinationDirectory: destinationDirectory)
        } catch is OCIAuthenticationRejected {
            // A later blob can 401/403 after earlier layers were extracted here.
            // Drop that partial tree before the git fallback so a failed clone
            // cannot be installed, and a successful one cannot keep OCI files.
            try? FileManager.default.removeItem(atPath: destinationDirectory)
            return try fetchViaGit(reference: reference, parsed: parsed, destinationDirectory: destinationDirectory)
        } catch let error as CLIError {
            throw error
        } catch {
            throw CLIError(
                code: CLIErrorCode.featureFetch,
                property: "features",
                message: "Feature fetch network error for '\(reference)': \(error.localizedDescription)",
                hint: "Check network connectivity and registry host"
            )
        }
    }

    private func fetchOCI(
        reference: String,
        parsed: ParsedRef,
        destinationDirectory: String
    ) throws -> FetchedFeaturePackage {
        let token = try? fetchBearerToken(registry: parsed.registry, repository: parsed.repository)
        let manifestData = try getManifest(
            registry: parsed.registry,
            repository: parsed.repository,
            reference: parsed.tagOrDigest,
            token: token,
            featureRef: reference
        )
        let layers = try layerDigests(from: manifestData, featureRef: reference)
        guard !layers.isEmpty else {
            throw CLIError(
                code: CLIErrorCode.featureFetch,
                property: "features",
                message: "Feature '\(reference)' manifest has no layers",
                hint: "Confirm the reference points to a Dev Container feature OCI artifact"
            )
        }

        let fm = FileManager.default
        try fm.createDirectory(atPath: destinationDirectory, withIntermediateDirectories: true)
        let scratch = (destinationDirectory as NSString).appendingPathComponent(".oci-scratch")
        try? fm.removeItem(atPath: scratch)
        try fm.createDirectory(atPath: scratch, withIntermediateDirectories: true)
        defer { try? fm.removeItem(atPath: scratch) }

        for (index, digest) in layers.enumerated() {
            let blob = try getBlob(
                registry: parsed.registry,
                repository: parsed.repository,
                digest: digest,
                token: token,
                featureRef: reference
            )
            let blobPath = (scratch as NSString).appendingPathComponent("layer-\(index).tar")
            try blob.write(to: URL(fileURLWithPath: blobPath))
            try extractArchive(blobPath: blobPath, destination: destinationDirectory)
        }

        let metaPath = (destinationDirectory as NSString).appendingPathComponent("devcontainer-feature.json")
        guard fm.fileExists(atPath: metaPath) else {
            throw CLIError(
                code: CLIErrorCode.featureMetadata,
                property: "features",
                message: "Feature '\(reference)' artifact is missing devcontainer-feature.json",
                hint: "Confirm the OCI artifact is a Dev Container feature package"
            )
        }
        return FetchedFeaturePackage(reference: reference, directoryPath: destinationDirectory)
    }

    // MARK: - Reference parse

    struct ParsedRef {
        var registry: String
        var repository: String
        var tagOrDigest: String
    }

    func parseReference(_ ref: String) throws -> ParsedRef {
        let trimmed = ref.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            throw CLIError(
                code: CLIErrorCode.featureFetch,
                property: "features",
                message: "Empty feature reference",
                hint: "Use ghcr.io/org/features/name:tag"
            )
        }

        var remainder = trimmed
        var tagOrDigest = "latest"
        if let at = remainder.firstIndex(of: "@") {
            tagOrDigest = String(remainder[remainder.index(after: at)...])
            remainder = String(remainder[..<at])
        } else if let colon = remainder.lastIndex(of: ":"),
                  !remainder[remainder.index(after: colon)...].contains("/") {
            tagOrDigest = String(remainder[remainder.index(after: colon)...])
            remainder = String(remainder[..<colon])
        }

        guard let slash = remainder.firstIndex(of: "/") else {
            throw CLIError(
                code: CLIErrorCode.featureFetch,
                property: "features",
                message: "Feature reference '\(ref)' is missing registry host",
                hint: "Use ghcr.io/org/features/name:tag"
            )
        }
        let registry = String(remainder[..<slash])
        let repository = String(remainder[remainder.index(after: slash)...])
        guard !registry.isEmpty, !repository.isEmpty else {
            throw CLIError(
                code: CLIErrorCode.featureFetch,
                property: "features",
                message: "Invalid feature reference '\(ref)'",
                hint: "Use ghcr.io/org/features/name:tag"
            )
        }
        return ParsedRef(registry: registry, repository: repository, tagOrDigest: tagOrDigest)
    }

    // MARK: - Registry API

    private func fetchBearerToken(registry: String, repository: String) throws -> String? {
        var comps = URLComponents(string: "https://\(registry == "ghcr.io" ? "ghcr.io" : registry)/token")!
        if registry == "ghcr.io" {
            comps = URLComponents(string: "https://ghcr.io/token")!
        }
        comps.queryItems = [
            URLQueryItem(name: "service", value: registry),
            URLQueryItem(name: "scope", value: "repository:\(repository):pull")
        ]
        guard let realmURL = comps.url else { return nil }

        var req = URLRequest(url: realmURL)
        req.setValue(userAgent, forHTTPHeaderField: "User-Agent")
        let (data, response) = try syncData(for: req)
        guard let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode) else {
            return nil
        }
        guard let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let token = obj["token"] as? String ?? obj["access_token"] as? String else {
            return nil
        }
        return token
    }

    private func getManifest(
        registry: String,
        repository: String,
        reference: String,
        token: String?,
        featureRef: String
    ) throws -> Data {
        let url = URL(string: "https://\(registry)/v2/\(repository)/manifests/\(reference)")!
        var req = URLRequest(url: url)
        req.setValue(userAgent, forHTTPHeaderField: "User-Agent")
        req.setValue(
            [
                "application/vnd.oci.image.manifest.v1+json",
                "application/vnd.oci.image.index.v1+json",
                "application/vnd.docker.distribution.manifest.v2+json",
                "application/vnd.devcontainers",
                "*/*"
            ].joined(separator: ", "),
            forHTTPHeaderField: "Accept"
        )
        if let token {
            req.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        }
        let (data, response) = try syncData(for: req, featureRef: featureRef)
        guard let http = response as? HTTPURLResponse else {
            throw fetchError(featureRef: featureRef, detail: "No HTTP response for manifest")
        }
        if http.statusCode == 401 || http.statusCode == 403 {
            throw OCIAuthenticationRejected()
        }
        if http.statusCode == 404 {
            throw CLIError(
                code: CLIErrorCode.featureFetch,
                property: "features",
                message: "Feature '\(featureRef)' not found (404)",
                hint: "Check the feature reference and tag"
            )
        }
        guard (200..<300).contains(http.statusCode) else {
            throw CLIError(
                code: CLIErrorCode.featureFetch,
                property: "features",
                message: "Feature manifest fetch failed (HTTP \(http.statusCode)) for '\(featureRef)'",
                hint: "Check network access and registry permissions"
            )
        }

        // If index, follow first manifest digest.
        if let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
           let manifests = obj["manifests"] as? [[String: Any]],
           obj["layers"] == nil,
           let dig = manifests.first?["digest"] as? String {
            return try getManifest(
                registry: registry,
                repository: repository,
                reference: dig,
                token: token,
                featureRef: featureRef
            )
        }
        return data
    }

    private func getBlob(
        registry: String,
        repository: String,
        digest: String,
        token: String?,
        featureRef: String
    ) throws -> Data {
        let url = URL(string: "https://\(registry)/v2/\(repository)/blobs/\(digest)")!
        var req = URLRequest(url: url)
        req.setValue(userAgent, forHTTPHeaderField: "User-Agent")
        if let token {
            req.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        }
        let (data, response) = try syncData(for: req, featureRef: featureRef)
        guard let http = response as? HTTPURLResponse else {
            throw fetchError(featureRef: featureRef, detail: "No HTTP response for blob \(digest)")
        }
        if http.statusCode == 401 || http.statusCode == 403 {
            throw OCIAuthenticationRejected()
        }
        if http.statusCode == 404 {
            throw CLIError(
                code: CLIErrorCode.featureFetch,
                property: "features",
                message: "Feature '\(featureRef)' blob not found (404)",
                hint: "The feature artifact may be incomplete"
            )
        }
        guard (200..<300).contains(http.statusCode) else {
            throw CLIError(
                code: CLIErrorCode.featureFetch,
                property: "features",
                message: "Feature '\(featureRef)' blob fetch failed (HTTP \(http.statusCode))",
                hint: "Check network access and registry permissions"
            )
        }
        return data
    }

    private func layerDigests(from manifestData: Data, featureRef: String) throws -> [String] {
        guard let obj = try JSONSerialization.jsonObject(with: manifestData) as? [String: Any] else {
            throw CLIError(
                code: CLIErrorCode.featureFetch,
                property: "features",
                message: "Feature '\(featureRef)' manifest is not a JSON object",
                hint: "Confirm the reference is an OCI feature artifact"
            )
        }

        var digests: [String] = []
        if let layers = obj["layers"] as? [[String: Any]] {
            for layer in layers {
                if let d = layer["digest"] as? String {
                    digests.append(d)
                }
            }
        }
        if digests.isEmpty, let fs = obj["fsLayers"] as? [[String: Any]] {
            for layer in fs {
                if let d = layer["blobSum"] as? String {
                    digests.append(d)
                }
            }
        }
        return digests
    }

    // MARK: - Extract via tar

    private func extractArchive(blobPath: String, destination: String) throws {
        // Detect gzip magic and choose tar flags.
        let handle = try FileHandle(forReadingFrom: URL(fileURLWithPath: blobPath))
        let magic = try handle.read(upToCount: 2) ?? Data()
        try handle.close()
        let isGzip = magic.count >= 2 && magic[0] == 0x1f && magic[1] == 0x8b

        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/tar")
        // -x extract, -f file, -C dest; -z for gzip; -o no same owner
        var args = ["-x", "-f", blobPath, "-C", destination, "-o"]
        if isGzip {
            args.insert("-z", at: 1)
        }
        process.arguments = args
        let err = Pipe()
        process.standardError = err
        process.standardOutput = FileHandle.nullDevice
        process.standardInput = FileHandle.nullDevice
        do {
            try process.run()
            process.waitUntilExit()
        } catch {
            throw CLIError(
                code: CLIErrorCode.featureFetch,
                property: "features",
                message: "Failed to launch tar to extract feature layer: \(error.localizedDescription)",
                hint: "Ensure /usr/bin/tar is available"
            )
        }
        if process.terminationStatus != 0 {
            let errData = err.fileHandleForReading.readDataToEndOfFile()
            let msg = String(data: errData, encoding: .utf8) ?? ""
            throw CLIError(
                code: CLIErrorCode.featureFetch,
                property: "features",
                message: "Failed to extract feature layer"
                    + (msg.isEmpty ? "" : ": \(msg.trimmingCharacters(in: .whitespacesAndNewlines))"),
                hint: "Feature layer may be corrupt or not a tar archive"
            )
        }

        // Ensure install.sh is executable when present
        let install = (destination as NSString).appendingPathComponent("install.sh")
        if FileManager.default.fileExists(atPath: install) {
            try? FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: install)
        }
    }

    // MARK: - HTTP sync

    private func syncData(for request: URLRequest, featureRef: String? = nil) throws -> (Data, URLResponse) {
        final class Box: @unchecked Sendable {
            var data: Data?
            var response: URLResponse?
            var error: Error?
        }
        let box = Box()
        let sem = DispatchSemaphore(value: 0)
        let task = session.dataTask(with: request) { data, response, error in
            box.data = data
            box.response = response
            box.error = error
            sem.signal()
        }
        task.resume()
        let wait = sem.wait(timeout: .now() + 120)
        let named = featureRef.map { " for '\($0)'" } ?? ""
        if wait == .timedOut {
            task.cancel()
            throw CLIError(
                code: CLIErrorCode.featureFetch,
                property: "features",
                message: "Feature fetch timed out\(named) for \(request.url?.absoluteString ?? "unknown")",
                hint: "Check network connectivity"
            )
        }
        if let error = box.error {
            throw CLIError(
                code: CLIErrorCode.featureFetch,
                property: "features",
                message: "Feature fetch network error\(named): \(error.localizedDescription)",
                hint: "Check network connectivity and registry host"
            )
        }
        guard let data = box.data, let response = box.response else {
            throw CLIError(
                code: CLIErrorCode.featureFetch,
                property: "features",
                message: "Feature fetch returned empty response\(named)",
                hint: "Check network connectivity"
            )
        }
        return (data, response)
    }

    // MARK: - HTTP 401/403 git fallback

    /// Collection is the repository path without the last segment (the feature id).
    /// Tag and digest are not git refs. A single-segment repository has no collection.
    private func collectionCloneTarget(from parsed: ParsedRef) -> (url: String, featureId: String)? {
        let parts = parsed.repository.split(separator: "/", omittingEmptySubsequences: true).map(String.init)
        guard parts.count >= 2, let featureId = parts.last, !featureId.isEmpty else {
            return nil
        }
        let collection = parts.dropLast().joined(separator: "/")
        guard !parsed.registry.isEmpty, !collection.isEmpty else { return nil }
        return ("https://\(parsed.registry)/\(collection)", featureId)
    }

    private func fetchViaGit(
        reference: String,
        parsed: ParsedRef,
        destinationDirectory: String
    ) throws -> FetchedFeaturePackage {
        guard let target = collectionCloneTarget(from: parsed) else {
            throw gitFallbackError(
                featureRef: reference,
                hint: "The OCI reference has no collection segment, so no git clone URL was used"
            )
        }
        StatusPrinter.status("Feature is being cloned after OCI authentication failure", item: reference)
        let cloneRoot: String
        do {
            cloneRoot = try collectionClone(url: target.url, featureRef: reference)
        } catch let error as CLIError {
            throw error
        } catch {
            throw gitFallbackError(featureRef: reference)
        }
        guard let package = selectPackage(in: cloneRoot, featureId: target.featureId) else {
            throw gitFallbackError(featureRef: reference)
        }
        try copyPackage(from: package, to: destinationDirectory, featureRef: reference)
        return FetchedFeaturePackage(reference: reference, directoryPath: destinationDirectory)
    }

    /// One clone per collection on this client. A later client clones again so the tip is current.
    private func collectionClone(url: String, featureRef: String) throws -> String {
        collectionClones.lock.lock()
        defer { collectionClones.lock.unlock() }
        if let existing = collectionClones.directories[url], isCloneUsable(existing) {
            return existing
        }
        let git = try resolveGit(featureRef: featureRef)
        let fm = FileManager.default
        try fm.createDirectory(atPath: collectionClones.root, withIntermediateDirectories: true)
        let dest = (collectionClones.root as NSString).appendingPathComponent(UUID().uuidString)
        let result: ProcessResult
        do {
            result = try gitRunner.run(
                executable: git,
                arguments: ["clone", "--", url, dest],
                environment: Self.strippedGitEnvironment(),
                // Temp parent, not the workspace cwd, so a relative trace path
                // cannot land in the workspace even if one slips through.
                currentDirectory: collectionClones.root
            )
        } catch {
            throw gitFallbackError(featureRef: featureRef)
        }
        guard result.succeeded, isCloneUsable(dest) else {
            try? fm.removeItem(atPath: dest)
            throw gitFallbackError(featureRef: featureRef)
        }
        collectionClones.directories[url] = dest
        return dest
    }

    /// Host environment so credential helpers and `url.insteadOf` still apply,
    /// minus the trace variables `HostGitCredential` strips before `git credential fill`.
    static func strippedGitEnvironment() -> [String: String] {
        var env = HostGitCredential.strippingCredentialTraces(liveProcessEnvironment())
        env.removeValue(forKey: "ADEVCONTAINER_GIT_TOKEN")
        return env
    }

    /// Live process environment. `ProcessInfo.processInfo.environment` can be a
    /// startup snapshot and would miss a `GIT_TRACE` set on the host later.
    private static func liveProcessEnvironment() -> [String: String] {
        #if canImport(Darwin)
        var env: [String: String] = [:]
        var index = 0
        while let entry = environ[index] {
            let pair = String(cString: entry)
            if let eq = pair.firstIndex(of: "="), eq != pair.startIndex {
                env[String(pair[..<eq])] = String(pair[pair.index(after: eq)...])
            }
            index += 1
        }
        if !env.isEmpty {
            return env
        }
        #endif
        return ProcessInfo.processInfo.environment
    }

    private func resolveGit(featureRef: String) throws -> String {
        let path: String?
        if let override = gitPathOverride {
            path = override
        } else {
            path = HostGitClient.whichGit()
        }
        guard let path, !path.isEmpty else {
            throw gitFallbackError(featureRef: featureRef)
        }
        return path
    }

    private func isCloneUsable(_ path: String) -> Bool {
        var isDir: ObjCBool = false
        return FileManager.default.fileExists(atPath: path, isDirectory: &isDir) && isDir.boolValue
    }

    private func selectPackage(in cloneRoot: String, featureId: String) -> String? {
        let src = (cloneRoot as NSString).appendingPathComponent("src/\(featureId)")
        if isValidPackage(src) { return src }
        if isValidPackage(cloneRoot) { return cloneRoot }
        return nil
    }

    private func isValidPackage(_ path: String) -> Bool {
        var isDir: ObjCBool = false
        let fm = FileManager.default
        guard fm.fileExists(atPath: path, isDirectory: &isDir), isDir.boolValue else { return false }
        let meta = (path as NSString).appendingPathComponent("devcontainer-feature.json")
        let install = (path as NSString).appendingPathComponent("install.sh")
        return fm.fileExists(atPath: meta) && fm.fileExists(atPath: install)
    }

    private func copyPackage(from source: String, to destination: String, featureRef: String) throws {
        let fm = FileManager.default
        if fm.fileExists(atPath: destination) {
            try? fm.removeItem(atPath: destination)
        }
        do {
            try fm.createDirectory(atPath: destination, withIntermediateDirectories: true)
            let names = try fm.contentsOfDirectory(atPath: source)
            for name in names where !name.hasPrefix(".") {
                let from = (source as NSString).appendingPathComponent(name)
                let to = (destination as NSString).appendingPathComponent(name)
                if fm.fileExists(atPath: to) {
                    try fm.removeItem(atPath: to)
                }
                try fm.copyItem(atPath: from, toPath: to)
            }
        } catch let error as CLIError {
            try? fm.removeItem(atPath: destination)
            throw error
        } catch {
            try? fm.removeItem(atPath: destination)
            throw gitFallbackError(featureRef: featureRef)
        }
        guard isValidPackage(destination) else {
            try? fm.removeItem(atPath: destination)
            throw gitFallbackError(featureRef: featureRef)
        }
        let install = (destination as NSString).appendingPathComponent("install.sh")
        try? fm.setAttributes([.posixPermissions: 0o755], ofItemAtPath: install)
    }

    private func gitFallbackError(featureRef: String, hint: String? = nil) -> CLIError {
        CLIError(
            code: CLIErrorCode.featureFetch,
            property: "features",
            message: "Feature '\(featureRef)' OCI authentication failed and the git fallback failed",
            hint: hint ?? "Confirm host git can clone the feature collection with existing credential helpers"
        )
    }

    private func fetchError(featureRef: String, detail: String) -> CLIError {
        CLIError(
            code: CLIErrorCode.featureFetch,
            property: "features",
            message: "Feature fetch failed for '\(featureRef)': \(detail)",
            hint: "Check network and feature reference"
        )
    }
}
