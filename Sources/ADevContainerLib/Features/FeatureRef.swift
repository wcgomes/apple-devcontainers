import Foundation

/// One admitted feature entry (OCI ref + options).
public struct AdmittedFeature: Equatable, Sendable {
    public var reference: String
    public var options: [String: FeatureOptionValue]

    public init(reference: String, options: [String: FeatureOptionValue] = [:]) {
        self.reference = reference
        self.options = options
    }

    /// Stable identity for hashing (ref + sorted options).
    public var hashMaterial: [String: Any] {
        var opts: [String: Any] = [:]
        for key in options.keys.sorted() {
            opts[key] = options[key]!.jsonValue
        }
        return ["ref": reference, "options": opts]
    }
}

/// Option value from the features map (string / bool / number / null).
public enum FeatureOptionValue: Equatable, Sendable {
    case string(String)
    case bool(Bool)
    case number(Double)
    case null

    public init?(json: Any) {
        if json is NSNull {
            self = .null
            return
        }
        if let s = json as? String {
            self = .string(s)
            return
        }
        if let b = json as? Bool {
            self = .bool(b)
            return
        }
        // Bool was handled above; NSNumber is always numeric.
        if let n = json as? NSNumber {
            self = .number(n.doubleValue)
            return
        }
        return nil
    }

    public var stringValue: String {
        switch self {
        case .string(let s): return s
        case .bool(let b): return b ? "true" : "false"
        case .number(let n):
            if n == floor(n), n >= Double(Int.min), n <= Double(Int.max) {
                return "\(Int(n))"
            }
            return "\(n)"
        case .null: return ""
        }
    }

    public var jsonValue: Any {
        switch self {
        case .string(let s): return s
        case .bool(let b): return b
        case .number(let n): return n
        case .null: return NSNull()
        }
    }
}

public enum FeatureRef {
    /// Substring warn-skipped in any feature reference (legacy name for OOD).
    public static let dockerOODMarker = "docker-outside-of-docker"

    /// Docker-related feature id substrings warn-skipped at admission (any registry/tag).
    public static let warnSkippedDockerMarkers = [
        "docker-outside-of-docker",
        "docker-in-docker",
        "docker-from-docker"
    ]

    /// True when the feature key is a local filesystem path (not OCI).
    public static func isLocalPath(_ ref: String) -> Bool {
        let trimmed = ref.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty { return false }
        if trimmed.hasPrefix("file://") { return true }
        if trimmed.hasPrefix("./") || trimmed.hasPrefix("../") { return true }
        if trimmed.hasPrefix("/") { return true }
        // Windows-style absolute (unlikely on macOS host but fail closed)
        if trimmed.count >= 3,
           trimmed[trimmed.startIndex].isLetter,
           trimmed[trimmed.index(trimmed.startIndex, offsetBy: 1)] == ":" {
            return true
        }
        return false
    }

    /// Matched warn-skipped docker marker in `ref`, if any.
    public static func warnSkippedDockerMarker(in ref: String) -> String? {
        warnSkippedDockerMarkers.first { ref.contains($0) }
    }

    /// Bare feature id without registry/tag for soft matching (last path segment before `:`).
    public static func featureId(from ref: String) -> String {
        let withoutTag: String
        if let colon = ref.lastIndex(of: ":"),
           !ref[ref.index(after: colon)...].contains("/") {
            withoutTag = String(ref[..<colon])
        } else {
            withoutTag = ref
        }
        return (withoutTag as NSString).lastPathComponent
    }

    /// Phase-item name for a feature hook: metadata `id` when present, else last-segment ref.
    public static func hookDisplayName(metadataId: String?, reference: String? = nil) -> String {
        if let metadataId {
            let trimmed = metadataId.trimmingCharacters(in: .whitespacesAndNewlines)
            if !trimmed.isEmpty {
                return featureId(from: trimmed)
            }
        }
        if let reference {
            let trimmed = reference.trimmingCharacters(in: .whitespacesAndNewlines)
            if !trimmed.isEmpty {
                return featureId(from: trimmed)
            }
        }
        return ""
    }

    /// Match dependsOn / installsAfter keys against selected refs (id, full ref, or prefix).
    public static func matchesDependencyKey(_ key: String, selectedRef: String) -> Bool {
        if key == selectedRef { return true }
        let keyId = featureId(from: key)
        let selId = featureId(from: selectedRef)
        if keyId == selId { return true }
        // Prefix without tag
        let keyBase = stripTag(key)
        let selBase = stripTag(selectedRef)
        if keyBase == selBase { return true }
        if selectedRef.hasPrefix(keyBase) || key.hasPrefix(selBase) { return true }
        return false
    }

    public static func stripTag(_ ref: String) -> String {
        if let colon = ref.lastIndex(of: ":"),
           !ref[ref.index(after: colon)...].contains("/") {
            return String(ref[..<colon])
        }
        return ref
    }
}
