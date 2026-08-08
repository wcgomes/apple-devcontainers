import Foundation
import CryptoKit

public enum ContainerIdentity {
    public static let labelLocalFolder = "devcontainer.local_folder"
    public static let labelConfigFile = "devcontainer.config_file"
    public static let labelConfigHash = "devcontainer.config_hash"

    /// DNS-safe human base (≤20) from config `name` when non-empty after trim; else workspace basename.
    public static func humanBase(configName: String?, workspacePath: String) -> String {
        let raw: String
        if let name = configName?.trimmingCharacters(in: .whitespacesAndNewlines), !name.isEmpty {
            raw = name
        } else {
            raw = ((workspacePath as NSString).standardizingPath as NSString).lastPathComponent
        }
        let base = raw
            .lowercased()
            .replacingOccurrences(of: "[^a-z0-9-]", with: "-", options: .regularExpression)
            .trimmingCharacters(in: CharacterSet(charactersIn: "-"))
        return String(base.prefix(20)).trimmingCharacters(in: CharacterSet(charactersIn: "-"))
    }

    /// Deterministic DNS-safe container name ≤ 63 chars from workspace + config path.
    /// Human segment prefers config `name` when set; hash material remains workspace|config paths.
    public static func containerName(
        workspacePath: String,
        configPath: String,
        configName: String? = nil
    ) -> String {
        let workspace = (workspacePath as NSString).standardizingPath
        let config = (configPath as NSString).standardizingPath
        let material = "\(workspace)|\(config)"
        let digest = SHA256.hash(data: Data(material.utf8))
        let hex = digest.map { String(format: "%02x", $0) }.joined()
        let short = String(hex.prefix(12))

        let clippedBase = humanBase(configName: configName, workspacePath: workspace)
        let candidate = clippedBase.isEmpty
            ? "adev-\(short)"
            : "adev-\(clippedBase)-\(short)"
        return String(candidate.prefix(63))
    }

    /// Stable hash of resolved config fields that affect runtime shape.
    public static func configHash(from fields: [String: Any]) -> String {
        let data = canonicalJSONData(fields)
        let digest = SHA256.hash(data: data)
        return digest.map { String(format: "%02x", $0) }.joined()
    }

    public static func labels(
        workspacePath: String,
        configPath: String,
        configHash: String
    ) -> [String: String] {
        [
            labelLocalFolder: (workspacePath as NSString).standardizingPath,
            labelConfigFile: (configPath as NSString).standardizingPath,
            labelConfigHash: configHash
        ]
    }

    private static func canonicalJSONData(_ value: Any) -> Data {
        // Sort keys for stability when possible.
        if let dict = value as? [String: Any] {
            let sortedKeys = dict.keys.sorted()
            var parts: [String] = []
            for key in sortedKeys {
                let k = escapeJSONString(key)
                let v = String(data: canonicalJSONData(dict[key]!), encoding: .utf8) ?? "null"
                parts.append("\"\(k)\":\(v)")
            }
            return Data("{\(parts.joined(separator: ","))}".utf8)
        }
        if let arr = value as? [Any] {
            let parts = arr.map { String(data: canonicalJSONData($0), encoding: .utf8) ?? "null" }
            return Data("[\(parts.joined(separator: ","))]".utf8)
        }
        if let s = value as? String {
            return Data("\"\(escapeJSONString(s))\"".utf8)
        }
        if let b = value as? Bool {
            return Data((b ? "true" : "false").utf8)
        }
        if let n = value as? NSNumber {
            // Distinguish bool boxed as NSNumber
            if CFGetTypeID(n) == CFBooleanGetTypeID() {
                return Data((n.boolValue ? "true" : "false").utf8)
            }
            return Data("\(n)".utf8)
        }
        if value is NSNull {
            return Data("null".utf8)
        }
        return Data("null".utf8)
    }

    private static func escapeJSONString(_ s: String) -> String {
        var out = ""
        for ch in s {
            switch ch {
            case "\\": out += "\\\\"
            case "\"": out += "\\\""
            case "\n": out += "\\n"
            case "\r": out += "\\r"
            case "\t": out += "\\t"
            default: out.append(ch)
            }
        }
        return out
    }
}
