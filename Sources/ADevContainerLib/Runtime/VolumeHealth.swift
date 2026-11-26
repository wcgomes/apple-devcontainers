import Foundation

/// Read-only ext4 superblock fields of an Apple named-volume image (`volume.img`).
///
/// Parsed directly in Swift so the health gate does not depend on e2fsprogs on the host.
public struct Ext4Superblock: Equatable, Sendable {
    /// Superblock starts at byte 1024 of the filesystem image.
    public static let offset: UInt64 = 1024
    /// Bytes read from `offset`; covers every field below (`s_error_count` ends at 0x198).
    public static let length = 1024
    static let magic: UInt16 = 0xEF53
    static let stateValid: UInt16 = 0x0001   // EXT4_VALID_FS
    static let stateError: UInt16 = 0x0002   // EXT4_ERROR_FS
    static let compatHasJournal: UInt32 = 0x0004
    static let incompatRecover: UInt32 = 0x0004   // needs_recovery

    public let state: UInt16
    public let errorsBehavior: UInt16
    public let errorCount: UInt32
    public let featureCompat: UInt32
    public let featureIncompat: UInt32

    public var isCleanlyUnmounted: Bool { state & Self.stateValid != 0 }
    public var hasErrorFlag: Bool { state & Self.stateError != 0 }
    public var hasJournal: Bool { featureCompat & Self.compatHasJournal != 0 }
    public var needsRecovery: Bool { featureIncompat & Self.incompatRecover != 0 }

    /// Parse the 1024-byte superblock region (bytes 1024..<2048 of the image).
    /// Returns nil for short input or a wrong magic (not ext2/3/4).
    public static func parse(_ superblock: Data) -> Ext4Superblock? {
        let bytes = [UInt8](superblock)
        guard bytes.count >= 0x198 else { return nil }
        func u16(_ at: Int) -> UInt16 { UInt16(bytes[at]) | UInt16(bytes[at + 1]) << 8 }
        func u32(_ at: Int) -> UInt32 {
            UInt32(bytes[at]) | UInt32(bytes[at + 1]) << 8
                | UInt32(bytes[at + 2]) << 16 | UInt32(bytes[at + 3]) << 24
        }
        guard u16(0x38) == magic else { return nil }
        return Ext4Superblock(
            state: u16(0x3A),
            errorsBehavior: u16(0x3C),
            errorCount: u32(0x194),
            featureCompat: u32(0x5C),
            featureIncompat: u32(0x60)
        )
    }

    /// Read the superblock from an image file. Nil when unreadable, short, or not ext4.
    public static func read(imagePath: String) -> Ext4Superblock? {
        guard let handle = FileHandle(forReadingAtPath: imagePath) else { return nil }
        defer { try? handle.close() }
        do {
            try handle.seek(toOffset: offset)
            guard let data = try handle.read(upToCount: length) else { return nil }
            return parse(data)
        } catch {
            return nil
        }
    }
}

/// Pre-start health gate for reused managed named volumes.
///
/// Refuses to mount a volume whose ext4 superblock records errors (writing to it only adds
/// damage), and warns once per volume when it has no journal (one combined message when it
/// was also not cleanly unmounted). Never repairs or
/// migrates a volume. Any uncertainty (volume in use, inspect or image unreadable) skips the
/// check silently so the gate can only stop a known-bad volume.
public enum VolumeHealth {
    public enum Verdict: Equatable, Sendable {
        case healthy
        /// Clean but without a journal: an unclean VM stop can corrupt it.
        case unjournaled
        /// Not cleanly unmounted and without a journal (no errors recorded yet).
        case unclean
        case corrupt
    }

    public static func verdict(for superblock: Ext4Superblock) -> Verdict {
        if superblock.errorCount > 0 || superblock.hasErrorFlag { return .corrupt }
        if !superblock.hasJournal {
            return superblock.isCleanlyUnmounted ? .unjournaled : .unclean
        }
        return .healthy
    }

    /// Backup-first offline repair steps, shared with ownership-time corruption errors.
    public static func repairHint(image: String) -> String {
        "Repair offline, backup first: keep every container using the volume stopped; "
            + "clone \(image) outside the container volume store with `cp -c` (APFS clone, never a plain copy); "
            + "run `e2fsck -fy` on the unmounted image; optionally add a journal with "
            + "`tune2fs -O has_journal -c -1 -i 0` on the unmounted image; then retry. The volume was not deleted"
    }

    /// Backup-first offline journal migration (never run automatically).
    static func journalMigrationSteps(_ name: String) -> String {
        "To add a journal, backup first: stop every container using '\(name)'; "
            + "clone its volume.img (see `container volume inspect \(name)`) outside the container volume store with `cp -c`; "
            + "run `e2fsck -fy <volume.img>`; then `tune2fs -O has_journal -c -1 -i 0 <volume.img>` "
            + "(e2fsprogs: `brew install e2fsprogs`)"
    }

    /// Check each distinct volume. Throws `volume_corrupt` for the first corrupt one; warns
    /// once for each unjournaled one. Volumes mounted by a running container are skipped.
    public static func gate(volumes: [String], runtime: AppleContainerRuntime) throws {
        var warned: Set<String> = []
        try gate(volumes: volumes, runtime: runtime, warned: &warned)
    }

    /// Same as `gate(volumes:runtime:)`, for a command that checks more than once per run:
    /// `warned` carries the volumes already warned about so each warns at most once.
    /// Refusal is never suppressed.
    public static func gate(
        volumes: [String],
        runtime: AppleContainerRuntime,
        warned: inout Set<String>
    ) throws {
        var seen: Set<String> = []
        for name in volumes where !name.isEmpty && seen.insert(name).inserted {
            guard let superblock = readSuperblock(volume: name, runtime: runtime) else { continue }
            switch verdict(for: superblock) {
            case .healthy:
                continue
            case .unjournaled:
                guard warned.insert(name).inserted else { continue }
                StatusPrinter.warning(
                    "Named volume '\(name)' has no ext4 journal, so an unclean VM stop can corrupt it. "
                        + journalMigrationSteps(name)
                )
            case .unclean:
                // One combined warning per volume: not clean and no journal.
                guard warned.insert(name).inserted else { continue }
                StatusPrinter.warning(
                    "Named volume '\(name)' was not cleanly unmounted and has no ext4 journal; "
                        + "check it offline before it accumulates errors. " + journalMigrationSteps(name)
                )
            case .corrupt:
                throw CLIError(
                    code: CLIErrorCode.volumeCorrupt,
                    message: "Named volume '\(name)' has a corrupted ext4 filesystem "
                        + "(\(superblock.errorCount) recorded error(s)); refusing to mount it",
                    hint: repairHint(image: "its volume.img (see `container volume inspect \(name)`)")
                )
            }
        }
    }

    /// Named volumes stamped on a managed container (workspace volume + config volumes).
    public static func managedVolumes(labels: [String: String]) -> [String] {
        let workspace = labels[ContainerIdentity.labelWorkspaceVolume]?
            .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return (workspace.isEmpty ? [] : [workspace])
            + ContainerIdentity.parseConfigVolumeNames(from: labels)
    }

    private static func readSuperblock(volume name: String, runtime: AppleContainerRuntime) -> Ext4Superblock? {
        // A mounted image is live; its on-disk superblock is not meaningful. Unknown → skip.
        guard let attached = try? runtime.containersAttached(to: name),
              !attached.contains(where: \.isRunning)
        else { return nil }
        guard let path = runtime.volumeImagePath(name) else { return nil }
        return Ext4Superblock.read(imagePath: path)
    }
}
