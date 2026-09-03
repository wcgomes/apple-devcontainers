import Foundation

/// Parse and admit the top-level `features` object into feature entries (OCI or local path).
public enum FeatureAdmission {
    /// Returns admitted features in declaration key-sorted order for stable ties.
    /// Empty / omitted → empty array.
    /// Docker-* markers are warn-skipped (not admitted); other hard errors still throw.
    /// - Parameter emitWarnings: When false, still skip docker-* markers but do not warn
    ///   (used by pre-resolve admission so resolve emits each skip warning once).
    public struct ParseResult: Equatable, Sendable {
        public var features: [AdmittedFeature]
        public var issues: [CompatibilityIssue]

        public init(features: [AdmittedFeature] = [], issues: [CompatibilityIssue] = []) {
            self.features = features
            self.issues = issues
        }
    }

    public static func parse(_ features: Any?, emitWarnings: Bool = true) throws -> [AdmittedFeature] {
        let parsed = try parseResult(features)
        if emitWarnings {
            CompatibilityReport.emit(parsed.issues)
        }
        return parsed.features
    }

    public static func parseResult(_ features: Any?) throws -> ParseResult {
        guard let features else { return ParseResult() }

        guard let dict = features as? [String: Any] else {
            throw CLIError(
                code: CLIErrorCode.unsupportedFeature,
                property: "features",
                message: "features must be an object map of feature ref → options",
                hint: "Use \"features\": { \"ghcr.io/org/features/name:tag\": { \"option\": \"value\" } } or \"./path/to/feature\": {}"
            )
        }

        if dict.isEmpty { return ParseResult() }

        var admitted: [AdmittedFeature] = []
        var issues: [CompatibilityIssue] = []
        for key in dict.keys.sorted() {
            if let marker = FeatureRef.warnSkippedDockerMarker(in: key) {
                issues.append(CompatibilityIssue(
                    code: CompatibilityCode.dockerFeatureIgnored,
                    propertyPath: "features",
                    disposition: .ignored,
                    message: "Feature '\(key)' is incompatible with Apple container (no Docker socket / DinD path); skipped (\(marker))",
                    subjectIdentity: key
                ))
                continue
            }

            let optionsRaw = dict[key]
            let options = try parseOptions(optionsRaw, featureKey: key)
            admitted.append(AdmittedFeature(reference: key, options: options))
        }
        return ParseResult(features: admitted, issues: issues)
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
