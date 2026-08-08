import Foundation

/// Parse and admit the top-level `features` object into feature entries (OCI or local path).
public enum FeatureAdmission {
    /// Returns admitted features in declaration key-sorted order for stable ties.
    /// Empty / omitted → empty array.
    public static func parse(_ features: Any?) throws -> [AdmittedFeature] {
        guard let features else { return [] }

        guard let dict = features as? [String: Any] else {
            throw CLIError(
                code: CLIErrorCode.unsupportedFeature,
                property: "features",
                message: "features must be an object map of feature ref → options",
                hint: "Use \"features\": { \"ghcr.io/org/features/name:tag\": { \"option\": \"value\" } } or \"./path/to/feature\": {}"
            )
        }

        if dict.isEmpty { return [] }

        var admitted: [AdmittedFeature] = []
        for key in dict.keys.sorted() {
            try rejectDockerOOD(key)

            let optionsRaw = dict[key]
            let options = try parseOptions(optionsRaw, featureKey: key)
            admitted.append(AdmittedFeature(reference: key, options: options))
        }
        return admitted
    }

    private static func rejectDockerOOD(_ ref: String) throws {
        guard let marker = FeatureRef.foreverRejectedDockerMarker(in: ref) else { return }
        throw CLIError(
            code: CLIErrorCode.unsupportedFeature,
            property: "features",
            message: "Feature '\(ref)' is forever-rejected (\(marker))",
            hint: "Remove \(marker); Apple container has no privileged/device path for this"
        )
    }

    private static func parseOptions(_ value: Any?, featureKey: String) throws -> [String: FeatureOptionValue] {
        // Missing value treated as empty options.
        guard let value else { return [:] }
        guard let obj = value as? [String: Any] else {
            throw CLIError(
                code: CLIErrorCode.unsupportedFeature,
                property: "features",
                message: "Feature '\(featureKey)' options must be an object",
                hint: "Use { \"optionName\": \"value\" } or {}"
            )
        }
        var out: [String: FeatureOptionValue] = [:]
        for (k, v) in obj {
            guard let parsed = FeatureOptionValue(json: v) else {
                throw CLIError(
                    code: CLIErrorCode.unsupportedFeature,
                    property: "features",
                    message: "Feature '\(featureKey)' option '\(k)' must be a string, number, boolean, or null",
                    hint: "Use a scalar option value"
                )
            }
            out[k] = parsed
        }
        return out
    }
}
