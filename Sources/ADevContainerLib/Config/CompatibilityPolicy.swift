import Foundation

/// Opt-in strictness for recognized compatibility degradation.
public enum CompatibilityMode: Equatable, Sendable {
    case tolerant
    case strict

    public static let environmentKey = "ADEVCONTAINER_STRICT_COMPATIBILITY"

    public static func from(environment: [String: String]) -> CompatibilityMode {
        environment[environmentKey] == "1" ? .strict : .tolerant
    }
}

/// Reported outcome for a recognized bounded-emulation or warn-and-ignore decision.
public enum CompatibilityDisposition: String, Equatable, Sendable {
    case emulated
    case ignored
}

/// Stable compatibility issue codes for the first compatibility slice.
public enum CompatibilityCode {
    public static let configOtherPortsAttributesIgnored = "config_other_ports_attributes_ignored"
    public static let configSecretsIgnored = "config_secrets_ignored"
    public static let configPrivilegedIgnored = "config_privileged_ignored"
    public static let configSecurityOptIgnored = "config_security_opt_ignored"
    public static let runArgIgnored = "run_arg_ignored"
    public static let dockerFeatureIgnored = "docker_feature_ignored"
    public static let featurePrivilegedIgnored = "feature_privileged_ignored"
    public static let featureSecurityOptIgnored = "feature_security_opt_ignored"
    public static let imagePrivilegedIgnored = "image_privileged_ignored"
    public static let imageSecurityOptIgnored = "image_security_opt_ignored"
    public static let mountFileBindPromoted = "mount_file_bind_promoted"
}

/// One classified compatibility decision.
public struct CompatibilityIssue: Equatable, Sendable {
    public var code: String
    public var propertyPath: String
    public var disposition: CompatibilityDisposition
    public var message: String
    /// Non-secret subject used for dedup/sort (feature ref, runArg flag, promoted bind path).
    public var subjectIdentity: String

    public init(
        code: String,
        propertyPath: String,
        disposition: CompatibilityDisposition,
        message: String,
        subjectIdentity: String = ""
    ) {
        self.code = code
        self.propertyPath = propertyPath
        self.disposition = disposition
        self.message = message
        self.subjectIdentity = subjectIdentity
    }

    public var identity: CompatibilityIssueIdentity {
        CompatibilityIssueIdentity(
            code: code,
            propertyPath: propertyPath,
            subjectIdentity: subjectIdentity
        )
    }

    /// Body for the existing `warning: ` stderr channel (one line).
    public var warningText: String {
        "[\(code)] \(propertyPath) (\(disposition.rawValue)): \(message)"
    }
}

public struct CompatibilityIssueIdentity: Hashable, Equatable, Sendable {
    public var code: String
    public var propertyPath: String
    public var subjectIdentity: String

    public init(code: String, propertyPath: String, subjectIdentity: String) {
        self.code = code
        self.propertyPath = propertyPath
        self.subjectIdentity = subjectIdentity
    }
}

/// Deduplicated, deterministically ordered compatibility issues for one evaluation boundary.
public struct CompatibilityReport: Equatable, Sendable {
    public private(set) var issues: [CompatibilityIssue]

    public init(issues: [CompatibilityIssue] = []) {
        self.issues = Self.deduplicated(issues)
    }

    public var isEmpty: Bool { issues.isEmpty }

    public var hasDegradation: Bool { !issues.isEmpty }

    public mutating func add(_ issue: CompatibilityIssue) {
        issues = Self.deduplicated(issues + [issue])
    }

    public mutating func add(contentsOf newIssues: [CompatibilityIssue]) {
        guard !newIssues.isEmpty else { return }
        issues = Self.deduplicated(issues + newIssues)
    }

    public mutating func merge(_ other: CompatibilityReport) {
        add(contentsOf: other.issues)
    }

    public func merging(_ other: CompatibilityReport) -> CompatibilityReport {
        var copy = self
        copy.merge(other)
        return copy
    }

    /// Issues in this report that are not in `baseline` (by identity).
    public func subtracting(_ baseline: CompatibilityReport) -> CompatibilityReport {
        let known = Set(baseline.issues.map(\.identity))
        return CompatibilityReport(issues: issues.filter { !known.contains($0.identity) })
    }

    public func emitWarnings() {
        for issue in issues {
            StatusPrinter.warning(issue.warningText)
        }
    }

    public static func emit(_ issues: [CompatibilityIssue]) {
        CompatibilityReport(issues: issues).emitWarnings()
    }

    /// Fail when any ignored/emulated issue is present.
    public func enforceStrict() throws {
        let ordered = issues
        guard let first = ordered.first else { return }
        var seenCodes: [String] = []
        var codeSet = Set<String>()
        for issue in ordered where codeSet.insert(issue.code).inserted {
            seenCodes.append(issue.code)
        }
        throw CLIError(
            code: CLIErrorCode.compatibilityDegraded,
            property: first.propertyPath,
            message: "Compatibility degraded (\(seenCodes.joined(separator: ", ")))",
            hint: "Remove the ignored or emulated properties, or unset \(CompatibilityMode.environmentKey)"
        )
    }

    public func enforce(mode: CompatibilityMode) throws {
        guard mode == .strict else { return }
        try enforceStrict()
    }

    private static func deduplicated(_ issues: [CompatibilityIssue]) -> [CompatibilityIssue] {
        var firstByIdentity: [CompatibilityIssueIdentity: CompatibilityIssue] = [:]
        var order: [CompatibilityIssueIdentity] = []
        for issue in issues {
            let id = issue.identity
            if firstByIdentity[id] == nil {
                firstByIdentity[id] = issue
                order.append(id)
            }
        }
        return order
            .compactMap { firstByIdentity[$0] }
            .sorted { lhs, rhs in
                if lhs.propertyPath != rhs.propertyPath {
                    return lhs.propertyPath < rhs.propertyPath
                }
                if lhs.code != rhs.code {
                    return lhs.code < rhs.code
                }
                return lhs.subjectIdentity < rhs.subjectIdentity
            }
    }
}
