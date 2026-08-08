import Foundation

/// Clone-path helper: ensure volume-mode workspaces get in-container git via Features.
///
/// When neither an admitted `git` nor `common-utils` feature is present, appends the
/// official `ghcr.io/devcontainers/features/git:1` entry so FeaturesRunner installs git.
/// `up` bind-mode does not use this path.
public enum FeatureGitEnsure {
    /// Official OCI git feature injected when missing.
    public static let gitFeatureRef = "ghcr.io/devcontainers/features/git:1"

    /// Feature ids that already provide git (or commonly ship it).
    public static let coveringFeatureIds: Set<String> = ["git", "common-utils"]

    /// Returns the features list, appending `git:1` when not already covered.
    /// - Returns: `(features, didInject)` — `didInject` is true only when a new entry was appended.
    public static func ensurePresent(features: [AdmittedFeature]) -> (features: [AdmittedFeature], didInject: Bool) {
        if features.contains(where: coversGit) {
            return (features, false)
        }
        var out = features
        out.append(AdmittedFeature(reference: gitFeatureRef, options: [:]))
        return (out, true)
    }

    /// True when this admitted feature already covers in-container git.
    public static func coversGit(_ feature: AdmittedFeature) -> Bool {
        coveringFeatureIds.contains(FeatureRef.featureId(from: feature.reference))
    }
}
