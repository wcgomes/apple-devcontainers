import Foundation

/// Parse and merge image `devcontainer.metadata` label when present (SHOULD).
public enum DevContainerMetadataLabel {
    public static let labelKey = "devcontainer.metadata"

    /// `remoteUser` / `containerUser` contributed by image metadata fragments.
    /// Across an array of fragments, **last non-empty after trim wins** per field.
    public struct ImageMetadataUsers: Equatable, Sendable {
        public var remoteUser: String?
        public var containerUser: String?

        public init(remoteUser: String? = nil, containerUser: String? = nil) {
            self.remoteUser = remoteUser
            self.containerUser = containerUser
        }

        public static let empty = ImageMetadataUsers()
    }

    /// Parse label JSON into partial contributions. Absence / parse failure → empty (never fails up alone).
    /// Accepts a top-level JSON object or an array of objects (fragments are union-merged).
    public static func parseContributions(from labels: [String: String]) -> FeatureContributions {
        guard let raw = labels[labelKey], !raw.isEmpty else {
            return .empty
        }
        guard let data = raw.data(using: .utf8),
              let json = try? JSONSerialization.jsonObject(with: data) else {
            return .empty
        }
        if let obj = json as? [String: Any] {
            return parseObject(obj)
        }
        if let arr = json as? [Any] {
            var merged = FeatureContributions()
            for item in arr {
                guard let dict = item as? [String: Any] else { continue }
                merged = union(merged, fragment(dict))
            }
            return merged
        }
        return .empty
    }

    /// Extract `remoteUser` / `containerUser` from image `devcontainer.metadata`.
    /// Absence / parse failure → empty. Array fragments: last non-empty wins per field.
    public static func parseUsers(from labels: [String: String]) -> ImageMetadataUsers {
        guard let raw = labels[labelKey], !raw.isEmpty else {
            return .empty
        }
        guard let data = raw.data(using: .utf8),
              let json = try? JSONSerialization.jsonObject(with: data) else {
            return .empty
        }
        let fragments: [[String: Any]]
        if let obj = json as? [String: Any] {
            fragments = [obj]
        } else if let arr = json as? [Any] {
            fragments = arr.compactMap { $0 as? [String: Any] }
        } else {
            return .empty
        }
        var remote: String?
        var container: String?
        for dict in fragments {
            if let u = RemoteUserResolution.nonEmptyTrimmed(dict["remoteUser"] as? String) {
                remote = u
            }
            if let u = RemoteUserResolution.nonEmptyTrimmed(dict["containerUser"] as? String) {
                container = u
            }
        }
        return ImageMetadataUsers(remoteUser: remote, containerUser: container)
    }

    /// Also accept inspect configuration labels that may nest differently.
    public static func parseContributions(fromInspectJSON obj: [String: Any]) -> FeatureContributions {
        // Direct labels map
        if let labels = obj["labels"] as? [String: String] {
            let c = parseContributions(from: labels)
            if c != .empty { return c }
        }
        if let labels = obj["labels"] as? [String: Any],
           let raw = labels[labelKey] as? String {
            return parseContributions(from: [labelKey: raw])
        }
        if let configuration = obj["configuration"] as? [String: Any] {
            if let labels = configuration["labels"] as? [String: String] {
                return parseContributions(from: labels)
            }
            if let labels = configuration["labels"] as? [String: Any],
               let raw = labels[labelKey] as? String {
                return parseContributions(from: [labelKey: raw])
            }
        }
        return .empty
    }

    private static func parseObject(_ dict: [String: Any]) -> FeatureContributions {
        // Label may be a single object or an array of feature/config fragments.
        if let arr = dict["features"] as? [[String: Any]] {
            var merged = FeatureContributions()
            for item in arr {
                merged = union(merged, fragment(item))
            }
            // Also top-level fields
            merged = union(merged, fragment(dict))
            return merged
        }
        return fragment(dict)
    }

    private static func fragment(_ dict: [String: Any]) -> FeatureContributions {
        var c = FeatureContributions()
        if let b = dict["init"] as? Bool, b { c.initProcess = true }
        if let caps = dict["capAdd"] as? [Any] {
            c.capAdd = caps.compactMap { $0 as? String }
        }
        if let env = dict["containerEnv"] as? [String: Any] {
            for (k, v) in env {
                if let s = v as? String { c.containerEnv[k] = s }
            }
        }
        if let rawMounts = dict["mounts"], let mounts = try? MountParser.parse(rawMounts) {
            c.mounts = mounts
        }
        if let cmd = try? LifecycleCommand.parse(dict["onCreateCommand"], property: "onCreateCommand") {
            c.onCreateCommands = [cmd]
        }
        if let cmd = try? LifecycleCommand.parse(dict["updateContentCommand"], property: "updateContentCommand") {
            c.updateContentCommands = [cmd]
        }
        if let cmd = try? LifecycleCommand.parse(dict["postCreateCommand"], property: "postCreateCommand") {
            c.postCreateCommands = [cmd]
        }
        if let cmd = try? LifecycleCommand.parse(dict["postStartCommand"], property: "postStartCommand") {
            c.postStartCommands = [cmd]
        }
        if let cmd = try? LifecycleCommand.parse(dict["postAttachCommand"], property: "postAttachCommand") {
            c.postAttachCommands = [cmd]
        }
        // privileged / securityOpt are not merged; caller warns via warnStripUnsafe.
        return c
    }

    private static func union(_ a: FeatureContributions, _ b: FeatureContributions) -> FeatureContributions {
        var out = a
        if b.initProcess { out.initProcess = true }
        for cap in b.capAdd where !out.capAdd.contains(cap) {
            out.capAdd.append(cap)
        }
        for (k, v) in b.containerEnv where out.containerEnv[k] == nil {
            out.containerEnv[k] = v
        }
        out.mounts.append(contentsOf: b.mounts)
        out.onCreateCommands.append(contentsOf: b.onCreateCommands)
        out.updateContentCommands.append(contentsOf: b.updateContentCommands)
        out.postCreateCommands.append(contentsOf: b.postCreateCommands)
        out.postStartCommands.append(contentsOf: b.postStartCommands)
        out.postAttachCommands.append(contentsOf: b.postAttachCommands)
        return out
    }

    /// Warn when metadata label requires privileged/securityOpt (do not apply; do not fail).
    /// Checks each fragment when the label is a top-level array.
    public static func warnStripUnsafe(from labels: [String: String], imageRef: String) {
        guard let raw = labels[labelKey], let data = raw.data(using: .utf8),
              let json = try? JSONSerialization.jsonObject(with: data) else {
            return
        }
        let fragments: [[String: Any]]
        if let obj = json as? [String: Any] {
            fragments = [obj]
        } else if let arr = json as? [Any] {
            fragments = arr.compactMap { $0 as? [String: Any] }
        } else {
            return
        }
        for obj in fragments {
            if let p = obj["privileged"] as? Bool, p {
                StatusPrinter.warning(
                    "Image '\(imageRef)' devcontainer.metadata sets privileged: true; ignored (not applied on Apple container)"
                )
            }
            if let s = obj["securityOpt"] as? [Any], !s.isEmpty {
                StatusPrinter.warning(
                    "Image '\(imageRef)' devcontainer.metadata sets securityOpt; ignored (not applied on Apple container)"
                )
            } else if let s = obj["securityOpt"] as? String, !s.isEmpty {
                StatusPrinter.warning(
                    "Image '\(imageRef)' devcontainer.metadata sets securityOpt; ignored (not applied on Apple container)"
                )
            }
        }
    }
}
