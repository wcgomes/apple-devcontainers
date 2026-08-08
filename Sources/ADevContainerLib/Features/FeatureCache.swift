import Foundation
import CryptoKit

/// Layout for fetched feature packages under a product-controlled cache root.
///
/// Default root: `~/Library/Caches/adevcontainer/features/`
/// Per-ref directory: `<cacheRoot>/<sha256(ref)[0..<16]>/`
///
/// Contents: extracted feature files (`devcontainer-feature.json`, `install.sh`, …).
public enum FeatureCache {
    public static func defaultRoot(fileManager: FileManager = .default) -> String {
        let base = fileManager.urls(for: .cachesDirectory, in: .userDomainMask).first
            ?? URL(fileURLWithPath: NSTemporaryDirectory())
        return base
            .appendingPathComponent("adevcontainer", isDirectory: true)
            .appendingPathComponent("features", isDirectory: true)
            .path
    }

    /// Deterministic directory for a feature reference under `cacheRoot`.
    public static func directory(for reference: String, cacheRoot: String) -> String {
        let digest = SHA256.hash(data: Data(reference.utf8))
        let hex = digest.map { String(format: "%02x", $0) }.joined()
        let short = String(hex.prefix(16))
        return (cacheRoot as NSString).appendingPathComponent(short)
    }

    /// Ensure cache root exists.
    public static func ensureRoot(_ cacheRoot: String, fileManager: FileManager = .default) throws {
        try fileManager.createDirectory(
            atPath: cacheRoot,
            withIntermediateDirectories: true
        )
    }

    /// Scratch root for generated Dockerfile + feature COPY context (`container build`).
    public static func buildContextRoot(
        cacheRoot: String? = nil,
        fileManager: FileManager = .default
    ) -> String {
        let root = cacheRoot ?? defaultRoot(fileManager: fileManager)
        return (root as NSString).appendingPathComponent("_build")
    }
}
