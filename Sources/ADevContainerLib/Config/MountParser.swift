import Foundation

public enum MountParser {
    /// Parse mounts array entries (string or object form) after substitution.
    public static func parse(_ raw: Any) throws -> [MountSpec] {
        guard let items = raw as? [Any] else {
            throw CLIError(
                code: CLIErrorCode.unsupportedProperty,
                property: "mounts",
                message: "mounts must be an array",
                hint: "Use string or object mount entries"
            )
        }
        return try items.map { try parseOne($0) }
    }

    public static func parseOne(_ item: Any) throws -> MountSpec {
        if let s = item as? String {
            return try parseString(s)
        }
        if let dict = item as? [String: Any] {
            return try parseObject(dict)
        }
        throw CLIError(
            code: CLIErrorCode.unsupportedProperty,
            property: "mounts",
            message: "Each mount must be a string or object",
            hint: "Example: source=...,target=...,type=bind"
        )
    }

    private static func parseString(_ s: String) throws -> MountSpec {
        var parts: [String: String] = [:]
        for segment in s.split(separator: ",") {
            let kv = segment.split(separator: "=", maxSplits: 1).map(String.init)
            if kv.count == 2 {
                parts[kv[0].trimmingCharacters(in: .whitespaces)] = kv[1].trimmingCharacters(in: .whitespaces)
            } else if kv.count == 1 {
                let flag = kv[0].trimmingCharacters(in: .whitespaces).lowercased()
                if flag == "readonly" || flag == "ro" {
                    parts["readonly"] = "true"
                }
            }
        }
        return try build(from: parts)
    }

    private static func parseObject(_ dict: [String: Any]) throws -> MountSpec {
        var parts: [String: String] = [:]
        for (k, v) in dict {
            if let s = v as? String {
                parts[k] = s
            } else if let b = v as? Bool {
                parts[k] = b ? "true" : "false"
            } else if let n = v as? NSNumber {
                parts[k] = "\(n)"
            }
        }
        return try build(from: parts)
    }

    private static func build(from parts: [String: String]) throws -> MountSpec {
        guard let typeRaw = parts["type"]?.lowercased() else {
            throw CLIError(
                code: CLIErrorCode.unsupportedProperty,
                property: "mounts.type",
                message: "mount entry missing type",
                hint: "Set type=bind or type=volume"
            )
        }
        guard let type = MountSpec.MountType(rawValue: typeRaw) else {
            throw CLIError(
                code: CLIErrorCode.unsupportedProperty,
                property: "mounts.type",
                message: "Unsupported mount type '\(typeRaw)'",
                hint: "MVP supports bind and volume only"
            )
        }
        guard let source = parts["source"], !source.isEmpty else {
            throw CLIError(
                code: CLIErrorCode.unsupportedProperty,
                property: "mounts.source",
                message: "mount entry missing source"
            )
        }
        guard let target = parts["target"] ?? parts["destination"], !target.isEmpty else {
            throw CLIError(
                code: CLIErrorCode.unsupportedProperty,
                property: "mounts.target",
                message: "mount entry missing target"
            )
        }
        let readonly =
            parts["readonly"]?.lowercased() == "true"
            || parts["readonly"] == "1"
            || parts["consistency"] == nil && (parts["ro"]?.lowercased() == "true")
        return MountSpec(type: type, source: source, target: target, readonly: readonly)
    }
}
