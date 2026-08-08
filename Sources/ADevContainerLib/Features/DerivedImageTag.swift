import Foundation

/// Deterministic local image tag for a features-derived image.
///
/// Format: `adevcontainer/features:<hash12>`
/// Hash material: base image + ordered feature refs + options (stable canonical JSON via ContainerIdentity).
public enum DerivedImageTag {
    public static let repository = "adevcontainer/features"

    public static func compute(
        baseImage: String,
        ordered: [FeatureOrder.OrderedFeature]
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
        return "\(repository):\(short)"
    }
}
