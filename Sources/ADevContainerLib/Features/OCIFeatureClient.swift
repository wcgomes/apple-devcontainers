import Foundation
import FoundationNetworking

/// Embedded OCI distribution client for Dev Container **feature artifacts**.
///
/// Does **not** shell out to ORAS, Node, or Apple `container image pull`.
/// Uses HTTPS registry APIs (manifest → blob layers) via URLSession.
/// Layer unpack uses host `/usr/bin/tar` only (not a Features dependency).
public struct OCIFeatureClient: FeatureFetching, Sendable {
    public var session: URLSession
    public var userAgent: String

    public init(session: URLSession = .shared, userAgent: String = "adevcontainer/features") {
        self.session = session
        self.userAgent = userAgent
    }

    public func fetch(reference: String, destinationDirectory: String) throws -> FetchedFeaturePackage {
        let parsed = try parseReference(reference)
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
        let (data, response) = try syncData(for: req)
        guard let http = response as? HTTPURLResponse else {
            throw fetchError(featureRef: featureRef, detail: "No HTTP response for manifest")
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
        let (data, response) = try syncData(for: req)
        guard let http = response as? HTTPURLResponse else {
            throw fetchError(featureRef: featureRef, detail: "No HTTP response for blob \(digest)")
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

    private func syncData(for request: URLRequest) throws -> (Data, URLResponse) {
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
        if wait == .timedOut {
            task.cancel()
            throw CLIError(
                code: CLIErrorCode.featureFetch,
                property: "features",
                message: "Feature fetch timed out for \(request.url?.absoluteString ?? "unknown")",
                hint: "Check network connectivity"
            )
        }
        if let error = box.error {
            throw CLIError(
                code: CLIErrorCode.featureFetch,
                property: "features",
                message: "Feature fetch network error: \(error.localizedDescription)",
                hint: "Check network connectivity and registry host"
            )
        }
        guard let data = box.data, let response = box.response else {
            throw CLIError(
                code: CLIErrorCode.featureFetch,
                property: "features",
                message: "Feature fetch returned empty response",
                hint: "Check network connectivity"
            )
        }
        return (data, response)
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
