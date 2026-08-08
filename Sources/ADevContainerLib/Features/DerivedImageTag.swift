import Foundation

/// Deterministic local image tag for a features-derived image.
///
/// Format: `adev-{nameBase}:{hash12}` (fallback `adevcontainer:{hash12}` when nameBase is empty).
/// Hash material: base image + ordered feature refs + options (stable canonical JSON via ContainerIdentity).
public enum DerivedImageTag {
    public static let emptyBaseFallback = "adevcontainer"

    public static func compute(
        baseImage: String,
        ordered: [FeatureOrder.OrderedFeature],
        nameBase: String
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
            "features": featuresMaterial
        ]
        let hash = ContainerIdentity.configHash(from: material)
        let short = String(hash.prefix(12))
        let repo = nameBase.isEmpty ? emptyBaseFallback : "adev-\(nameBase)"
        return "\(repo):\(short)"
    }
}
