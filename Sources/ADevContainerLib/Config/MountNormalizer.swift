import Foundation

/// Promotes host file bind mounts to parent-directory binds (Apple container limitation).
public enum MountNormalizer {
    public struct Promotion: Equatable, Sendable {
        public var from: MountSpec
        public var to: MountSpec

        public init(from: MountSpec, to: MountSpec) {
            self.from = from
            self.to = to
        }
    }

    public static func normalize(
        mounts: [MountSpec],
        fileManager: FileManager = .default
    ) -> (mounts: [MountSpec], promotions: [Promotion]) {
        var result: [MountSpec] = []
        var promotions: [Promotion] = []
        result.reserveCapacity(mounts.count)

        for mount in mounts {
            if let promoted = promoteIfFileBind(mount, fileManager: fileManager) {
                result.append(promoted)
                promotions.append(Promotion(from: mount, to: promoted))
            } else {
                result.append(mount)
            }
        }
        return (result, promotions)
    }

    /// Human-readable warning for stderr (all promotions).
    public static func warningMessage(promotions: [Promotion]) -> String {
        var lines = [
            "warning: Apple container does not support binding individual files; binding parent directories instead:"
        ]
        for p in promotions {
            lines.append("  \(p.from.source) -> \(p.from.target)")
            lines.append("  became: \(p.to.source) -> \(p.to.target)")
        }
        return lines.joined(separator: "\n")
    }

    private static func promoteIfFileBind(
        _ mount: MountSpec,
        fileManager: FileManager
    ) -> MountSpec? {
        guard mount.type == .bind else { return nil }

        let source = mount.source
        let target = mount.target

        var isDirectory: ObjCBool = false
        let exists = fileManager.fileExists(atPath: source, isDirectory: &isDirectory)

        let shouldPromote: Bool
        if exists {
            shouldPromote = !isDirectory.boolValue
        } else {
            let sourceEndsSlash = source.hasSuffix("/")
            let targetEndsSlash = target.hasSuffix("/")
            let sourceBase = (source as NSString).lastPathComponent
            let targetBase = (target as NSString).lastPathComponent
            let parent = (source as NSString).deletingLastPathComponent
            var parentIsDir: ObjCBool = false
            let parentExists = fileManager.fileExists(atPath: parent, isDirectory: &parentIsDir)
            shouldPromote =
                !sourceEndsSlash
                && !targetEndsSlash
                && sourceBase == targetBase
                && !sourceBase.isEmpty
                && parentExists
                && parentIsDir.boolValue
        }

        guard shouldPromote else { return nil }

        let newSource = (source as NSString).deletingLastPathComponent
        let newTarget = (target as NSString).deletingLastPathComponent
        guard !newSource.isEmpty, !newTarget.isEmpty, newSource != source else { return nil }

        return MountSpec(
            type: .bind,
            source: newSource,
            target: newTarget,
            readonly: mount.readonly
        )
    }
}
