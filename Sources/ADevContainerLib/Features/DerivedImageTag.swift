import Foundation

/// Deterministic local image tag for a features-derived image.
///
/// Format: `adev-{nameBase}:{hash12}` (fallback `adevcontainer:{hash12}` when nameBase is empty).
/// Hash material: base image + ordered feature refs + options + `recipeVersion`
/// (stable canonical JSON via ContainerIdentity).
public enum DerivedImageTag {
    public static let emptyBaseFallback = "adevcontainer"

    /// Product Features Dockerfile install recipe epoch.
    ///
    /// Bump when `FeatureDockerfileGenerator` install-layer semantics change
    /// so `imageExists` does not reuse images built with the old recipe.
    /// Current `"7"`: install COPY/RUN paths use sanitized feature identity
    /// (`feature-<id>` / `/tmp/adev-feature-<id>`) instead of ordinal `feature-N`.
    /// Prior `"6"`: bake unioned lifecycle (base-image metadata + features)
    /// onto `devcontainer.metadata` so resume remelt does not drop base-image
    /// hooks. Was `"5"`: features-only LABEL (plus chmod-before-install,
    /// restore base USER, and feature `containerEnv` as Dockerfile `ENV` before
    /// each install `RUN`).
    public static let recipeVersion = "7"

    public static func compute(
        baseImage: String,
        ordered: [FeatureOrder.OrderedFeature],
        nameBase: String,
        recipeVersion: String = DerivedImageTag.recipeVersion
    ) -> String {
        var featuresMaterial: [[String: Any]] = []
        for f in ordered {
            var entry: [String: Any] = [
                "ref": f.admitted.reference,
                "id": f.metadata.id
            ]
            var opts: [String: Any] = [:]
            let merged = FeatureOptions.resolvedOptions(
                user: f.admitted.options,
                defaults: f.metadata.optionDefaults
            )
            for key in merged.keys.sorted() {
                opts[key] = merged[key]!.jsonValue
            }
            entry["options"] = opts
            featuresMaterial.append(entry)
        }
        let material: [String: Any] = [
            "baseImage": baseImage,
            "features": featuresMaterial,
            "recipeVersion": recipeVersion
        ]
        let hash = ContainerIdentity.configHash(from: material)
        let short = String(hash.prefix(12))
        let repo = nameBase.isEmpty ? emptyBaseFallback : "adev-\(nameBase)"
        return "\(repo):\(short)"
    }
}
