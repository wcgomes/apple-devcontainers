import Foundation
import Crypto

#if canImport(Darwin)
import Darwin
#elseif canImport(Glibc)
import Glibc
#endif

public struct RecoveryConfigSessionMetadata: Codable, Equatable, Sendable {
    public let version: Int
    public let sessionID: String
    public let targetContainerID: String
    public let targetContainerName: String
    public let workspaceVolume: String
    public let configFile: String
    public let workspaceFolder: String
    public let workspaceFolderBasename: String?
    public let originalHash: String
    public var baselineHash: String
    public var lastAppliedHash: String?
    public var conflictHash: String?
    public var conflictAcknowledged: Bool?
    public let tempFileName: String
    public var conflictFileName: String?

    public init(
        version: Int = 1,
        sessionID: String,
        targetContainerID: String,
        targetContainerName: String,
        workspaceVolume: String,
        configFile: String,
        workspaceFolder: String,
        workspaceFolderBasename: String?,
        originalHash: String,
        baselineHash: String,
        lastAppliedHash: String? = nil,
        conflictHash: String? = nil,
        conflictAcknowledged: Bool? = nil,
        tempFileName: String = "devcontainer.json",
        conflictFileName: String? = nil
    ) {
        self.version = version
        self.sessionID = sessionID
        self.targetContainerID = targetContainerID
        self.targetContainerName = targetContainerName
        self.workspaceVolume = workspaceVolume
        self.configFile = configFile
        self.workspaceFolder = workspaceFolder
        self.workspaceFolderBasename = workspaceFolderBasename
        self.originalHash = originalHash
        self.baselineHash = baselineHash
        self.lastAppliedHash = lastAppliedHash
        self.conflictHash = conflictHash
        self.conflictAcknowledged = conflictAcknowledged
        self.tempFileName = tempFileName
        self.conflictFileName = conflictFileName
    }
}

public struct RecoverySessionSummary: Codable, Equatable, Sendable {
    public let sessionID: String
    public let targetContainerID: String
    public let targetContainerName: String
    public let workspaceVolume: String
    public let configFile: String
    public let tempFile: String
    public let conflictFile: String?
    public let conflictHash: String?
    public let expectedHash: String

    public init(
        sessionID: String,
        targetContainerID: String,
        targetContainerName: String,
        workspaceVolume: String,
        configFile: String,
        tempFile: String,
        conflictFile: String?,
        conflictHash: String? = nil,
        expectedHash: String
    ) {
        self.sessionID = sessionID
        self.targetContainerID = targetContainerID
        self.targetContainerName = targetContainerName
        self.workspaceVolume = workspaceVolume
        self.configFile = configFile
        self.tempFile = tempFile
        self.conflictFile = conflictFile
        self.conflictHash = conflictHash
        self.expectedHash = expectedHash
    }
}

/// Private host-side recovery state for one in-volume config.
///
/// The session never puts raw config bytes in labels, status output, or error messages. It
/// retains the bytes in a `0600` file under a `0700` directory and keeps only hashes and opaque
/// identity metadata in the sidecar.
public final class RecoveryConfigSession: @unchecked Sendable {
    public static let directoryPrefix = "adev-recovery-"
    public static let tempFileName = "devcontainer.json"
    public static let metadataFileName = "metadata.json"
    public static let conflictFileName = "conflict.json"

    public let directoryURL: URL
    public let metadataURL: URL
    public let tempFileURL: URL
    public private(set) var metadata: RecoveryConfigSessionMetadata

    private let fileManager: FileManager
    private let configPathInContainerValue: String

    public var sessionID: String { metadata.sessionID }
    public var targetContainerID: String { metadata.targetContainerID }
    public var targetContainerName: String { metadata.targetContainerName }
    public var workspaceVolume: String { metadata.workspaceVolume }
    public var configFile: String { metadata.configFile }
    /// Absolute path used for helper exec. The stamped label remains unchanged in metadata;
    /// relative labels are resolved against the stamped workspace folder, never the temp dir.
    public var configPathInContainer: String {
        configPathInContainerValue
    }
    public var workspaceFolder: String { metadata.workspaceFolder }
    public var workspaceFolderBasename: String? { metadata.workspaceFolderBasename }
    public var originalHash: String { metadata.originalHash }
    public var baselineHash: String { metadata.baselineHash }
    public var lastAppliedHash: String? { metadata.lastAppliedHash }
    public var conflictHash: String? { metadata.conflictHash }
    public var conflictFileURL: URL? {
        guard let name = metadata.conflictFileName else { return nil }
        return directoryURL.appendingPathComponent(name, isDirectory: false)
    }

    public var summary: RecoverySessionSummary {
        RecoverySessionSummary(
            sessionID: sessionID,
            targetContainerID: targetContainerID,
            targetContainerName: targetContainerName,
            workspaceVolume: workspaceVolume,
            configFile: configFile,
            tempFile: tempFileURL.path,
            conflictFile: conflictFileURL?.path,
            conflictHash: conflictHash,
            expectedHash: baselineHash
        )
    }

    /// Capture exact bytes before the old container is deleted.
    public init(
        rawBytes: Data,
        targetContainerID: String,
        targetContainerName: String,
        workspaceVolume: String,
        configFile: String,
        workspaceFolder: String,
        fileManager: FileManager = .default,
        sessionID: String = UUID().uuidString.lowercased()
    ) throws {
        let location: VolumeConfigLocation
        do {
            location = try ConfigReader.volumeConfigLocation(labels: [
                ContainerIdentity.labelWorkspaceMode: ContainerIdentity.workspaceModeVolume,
                ContainerIdentity.labelWorkspaceFolder: workspaceFolder,
                ContainerIdentity.labelConfigFile: configFile
            ])
        } catch {
            throw Self.securityError("Recovery config path is outside the effective workspace folder")
        }
        try Self.validateRequiredIdentity(
            sessionID: sessionID,
            targetContainerID: targetContainerID,
            targetContainerName: targetContainerName,
            workspaceVolume: workspaceVolume,
            configFile: configFile
        )

        self.fileManager = fileManager
        self.configPathInContainerValue = location.pathInContainer
        let root = try Self.directoryURL(forSessionID: sessionID, fileManager: fileManager)
        self.directoryURL = root
        self.metadataURL = root.appendingPathComponent(Self.metadataFileName, isDirectory: false)
        self.tempFileURL = root.appendingPathComponent(Self.tempFileName, isDirectory: false)

        let folder = location.workspaceFolder
        let basename = (folder as NSString).lastPathComponent
        let hash = Self.sha256Hex(rawBytes)
        self.metadata = RecoveryConfigSessionMetadata(
            sessionID: sessionID,
            targetContainerID: targetContainerID,
            targetContainerName: targetContainerName,
            workspaceVolume: workspaceVolume,
            configFile: configFile,
            workspaceFolder: folder,
            workspaceFolderBasename: basename.isEmpty ? nil : basename,
            originalHash: hash,
            baselineHash: hash
        )

        if fileManager.fileExists(atPath: root.path) {
            throw Self.securityError(
                "Recovery session directory already exists",
                hint: "Remove the retained session directory before capturing a new session with the same id"
            )
        }
        do {
            try fileManager.createDirectory(
                at: root,
                withIntermediateDirectories: false,
                attributes: [.posixPermissions: NSNumber(value: 0o700)]
            )
            try Self.setPermissions(0o700, at: root, fileManager: fileManager)
            try Self.writePrivateFile(rawBytes, to: tempFileURL, fileManager: fileManager)
            try persistMetadata()
            try validateSecureState()
        } catch {
            // Only roll back a directory we created in this attempt.
            try? fileManager.removeItem(at: root)
            throw Self.mapSecurityError(error)
        }
    }

    /// Capture directly from the shared strict reader's retained raw volume value.
    public convenience init(
        rawVolumeConfig: RawVolumeConfig,
        targetContainerID: String,
        targetContainerName: String,
        workspaceVolume: String,
        configFile: String,
        fileManager: FileManager = .default,
        sessionID: String = UUID().uuidString.lowercased()
    ) throws {
        try self.init(
            rawBytes: rawVolumeConfig.bytes,
            targetContainerID: targetContainerID,
            targetContainerName: targetContainerName,
            workspaceVolume: workspaceVolume,
            configFile: configFile,
            workspaceFolder: rawVolumeConfig.workspaceFolder,
            fileManager: fileManager,
            sessionID: sessionID
        )
    }

    /// Construct a session from selected clone-origin labels and an exact raw read.
    public static func capture(
        rawVolumeConfig: RawVolumeConfig,
        container: ContainerInfo,
        fileManager: FileManager = .default,
        sessionID: String = UUID().uuidString.lowercased()
    ) throws -> RecoveryConfigSession {
        let labels = container.labels
        guard RecoveryHelper.isEligible(labels: labels),
              let volume = nonEmpty(labels[ContainerIdentity.labelWorkspaceVolume]),
              let configFile = nonEmpty(labels[ContainerIdentity.labelConfigFile])
        else {
            throw CLIError(
                code: CLIErrorCode.recoveryUnavailable,
                message: "The selected container has no eligible clone-origin recovery stamps",
                hint: "Recovery requires a managed volume-mode clone container"
            )
        }
        let location: VolumeConfigLocation
        do {
            location = try ConfigReader.volumeConfigLocation(labels: labels)
        } catch {
            throw CLIError(
                code: CLIErrorCode.recoveryUnavailable,
                message: "The stamped config path is outside the effective workspace folder",
                hint: "Keep devcontainer.config_file beneath devcontainer.workspace_folder"
            )
        }
        let expectedPath = location.pathInContainer
        guard rawVolumeConfig.pathInContainer == expectedPath else {
            throw CLIError(
                code: CLIErrorCode.recoveryVerificationFailed,
                message: "The retained config path does not match the stamped volume path",
                hint: "Capture the raw config again from the selected helper endpoint"
            )
        }
        return try RecoveryConfigSession(
            rawVolumeConfig: rawVolumeConfig,
            targetContainerID: container.id,
            targetContainerName: container.name,
            workspaceVolume: volume,
            configFile: configFile,
            fileManager: fileManager,
            sessionID: sessionID
        )
    }

    /// Open and validate an existing session sidecar. All known files must remain owned by the
    /// invoking user, private, regular files; symlinks and insecure modes fail closed.
    public static func open(
        directoryURL: URL,
        fileManager: FileManager = .default
    ) throws -> RecoveryConfigSession {
        do {
            let (safeDirectory, pathSessionID) = try validateSessionDirectoryURL(
                directoryURL,
                fileManager: fileManager
            )
            try validateDirectory(safeDirectory, fileManager: fileManager)
            let metadataURL = safeDirectory.appendingPathComponent(Self.metadataFileName, isDirectory: false)
            try validateFile(metadataURL, expectedPermissions: 0o600, fileManager: fileManager)
            let data = try Data(contentsOf: metadataURL)
            let metadata = try JSONDecoder().decode(RecoveryConfigSessionMetadata.self, from: data)
            try validateMetadata(metadata)
            guard metadata.sessionID == pathSessionID else {
                throw Self.securityError("Recovery session id does not match its private directory")
            }

            let tempURL = safeDirectory.appendingPathComponent(metadata.tempFileName, isDirectory: false)
            try validateFile(tempURL, expectedPermissions: 0o600, fileManager: fileManager)

            let session = try RecoveryConfigSession(
                directoryURL: safeDirectory,
                metadataURL: metadataURL,
                tempFileURL: tempURL,
                metadata: metadata,
                fileManager: fileManager
            )
            try session.validateSecureState()
            return session
        } catch {
            throw mapSecurityError(error)
        }
    }

    /// Return the retained bytes after rechecking secure file properties.
    public func readTempBytes() throws -> Data {
        try validateSecureState()
        do {
            return try Data(contentsOf: tempFileURL)
        } catch {
            throw Self.securityError("The recovery config file could not be read")
        }
    }

    /// Validate edited bytes through the same volume-mode resolver and stamped basename path as
    /// `ConfigReader.read`; the private temp directory's basename is never used.
    @discardableResult
    public func validateEditedConfig(
        localEnv: [String: String] = ProcessInfo.processInfo.environment
    ) throws -> ResolvedWorkspace {
        try validateSecureState()
        _ = try readTempBytes()
        return try ConfigReader.resolveVolumeFile(
            at: tempFileURL.path,
            labels: validationLabels,
            localEnv: localEnv,
            fileManager: fileManager
        )
    }

    /// Validate that a live marked helper still addresses this session's stamped identity.
    /// A later retry can use this seam before any write-back or helper deletion.
    public func validateAgainstHelper(_ helper: ContainerInfo) throws {
        try validateSecureState()
        let labels = helper.labels
        let helperLocation = try? ConfigReader.volumeConfigLocation(labels: labels)
        guard helper.name == metadata.targetContainerName,
              labels[RecoveryHelper.recoveryMarkerLabel] == RecoveryHelper.recoveryMarkerValue,
              labels[RecoveryHelper.recoverySessionLabel] == metadata.sessionID,
              labels[ContainerIdentity.labelWorkspaceVolume] == metadata.workspaceVolume,
              labels[ContainerIdentity.labelConfigFile] == metadata.configFile,
              helperLocation?.workspaceFolder == metadata.workspaceFolder,
              helperLocation?.pathInContainer == configPathInContainer
        else {
            throw Self.securityError("Recovery helper identity does not match the retained session")
        }
    }

    /// Validate the private temp file, then write it through a live helper using atomic
    /// same-directory replacement and readback verification.
    @discardableResult
    public func applyValidatedEdit(
        helperContainerID: String,
        runtime: AppleContainerRuntime,
        localEnv: [String: String] = [:]
    ) throws -> String {
        _ = try validateEditedConfig(localEnv: localEnv)
        return try applyEdit(helperContainerID: helperContainerID, runtime: runtime)
    }

    /// Apply the already-validated private temp bytes. The optimistic baseline check happens
    /// before the write and again inside the helper's atomic script; a conflict never overwrites
    /// the stamped target.
    @discardableResult
    public func applyEdit(
        helperContainerID: String,
        runtime: AppleContainerRuntime
    ) throws -> String {
        try validateSecureState()
        // Editor sessions can outlive a healthy helper keep-alive. Re-probe (and bounce if
        // needed) immediately before baseline read so a stale "running" helper does not
        // surface as recovery_verification_failed after a successful TTY save.
        try RecoveryHelper.ensureExecReady(nameOrId: helperContainerID, runtime: runtime)
        let edited = try readTempBytes()
        let editedHash = Self.sha256Hex(edited)
        let expected = metadata.baselineHash
        let current: Data
        do {
            current = try runtime.readFile(nameOrId: helperContainerID, path: configPathInContainer)
        } catch {
            throw CLIError(
                code: CLIErrorCode.recoveryVerificationFailed,
                message: "The recovery target could not be read for verification",
                hint: "Keep the recovery helper and session for another retry"
            )
        }
        let currentHash = Self.sha256Hex(current)
        guard currentHash == expected else {
            try recordConflict(bytes: current, hash: currentHash)
            throw CLIError(
                code: CLIErrorCode.recoveryConflict,
                message: "The in-volume config changed since this recovery session was captured",
                hint: "Review the retained conflict file before retrying"
            )
        }

        let writeResult: SafeFileWriteResult
        do {
            writeResult = try runtime.atomicWriteFile(
                nameOrId: helperContainerID,
                path: configPathInContainer,
                bytes: edited,
                expectedCurrentHash: expected,
                expectedBytesHash: editedHash
            )
        } catch {
            throw CLIError(
                code: CLIErrorCode.recoveryVerificationFailed,
                message: "The recovery config could not be atomically written",
                hint: "Keep the recovery helper and session for another retry"
            )
        }
        switch writeResult {
        case .conflict:
            let latest: Data
            do {
                latest = try runtime.readFile(nameOrId: helperContainerID, path: configPathInContainer)
            } catch {
                throw CLIError(
                    code: CLIErrorCode.recoveryVerificationFailed,
                    message: "The recovery conflict could not be captured safely",
                    hint: "Keep the recovery helper and session; do not force an overwrite"
                )
            }
            let latestHash = Self.sha256Hex(latest)
            try recordConflict(bytes: latest, hash: latestHash)
            throw CLIError(
                code: CLIErrorCode.recoveryConflict,
                message: "The in-volume config changed during recovery write-back",
                hint: "Review the retained conflict file before retrying"
            )
        case .applied:
            let readback: Data
            do {
                readback = try runtime.readFile(nameOrId: helperContainerID, path: configPathInContainer)
            } catch {
                throw CLIError(
                    code: CLIErrorCode.recoveryVerificationFailed,
                    message: "The recovery config could not be read back after atomic write",
                    hint: "Keep the recovery helper and session for another retry"
                )
            }
            let readbackHash = Self.sha256Hex(readback)
            guard readbackHash == editedHash, readback == edited else {
                throw CLIError(
                    code: CLIErrorCode.recoveryVerificationFailed,
                    message: "Recovery config readback did not match the validated edit",
                    hint: "Keep the recovery helper and session for another retry"
                )
            }
            metadata.baselineHash = editedHash
            metadata.lastAppliedHash = editedHash
            if let conflictURL = conflictFileURL {
                try? fileManager.removeItem(at: conflictURL)
                metadata.conflictFileName = nil
                metadata.conflictHash = nil
                metadata.conflictAcknowledged = nil
            }
            try persistMetadata()
            return editedHash
        }
    }

    /// A conflict requires an explicit editor pass before the captured current baseline can be
    /// used for a subsequent atomic write. This acknowledges only the exact baseline captured
    /// in `conflict.json`; if the volume changed again, another conflict is retained instead.
    public func acknowledgeConflict(
        helperContainerID: String,
        runtime: AppleContainerRuntime
    ) throws {
        try validateSecureState()
        guard let expectedConflictHash = metadata.conflictHash else { return }
        try RecoveryHelper.ensureExecReady(nameOrId: helperContainerID, runtime: runtime)
        let current: Data
        do {
            current = try runtime.readFile(nameOrId: helperContainerID, path: configPathInContainer)
        } catch {
            throw CLIError(
                code: CLIErrorCode.recoveryVerificationFailed,
                message: "The recovery conflict baseline could not be read",
                hint: "Keep the recovery helper and session for another retry"
            )
        }
        let currentHash = Self.sha256Hex(current)
        guard currentHash == expectedConflictHash else {
            try recordConflict(bytes: current, hash: currentHash)
            throw CLIError(
                code: CLIErrorCode.recoveryConflict,
                message: "The recovery conflict baseline changed again",
                hint: "Review the newly retained conflict file before retrying"
            )
        }
        metadata.baselineHash = currentHash
        metadata.conflictAcknowledged = true
        try persistMetadata()
    }

    /// Remove only the private session directory. Ownership and path checks are required, but
    /// in-memory metadata need not match on-disk metadata: another open of the same session may
    /// have advanced baseline/applied hashes (named retry write-back) before this handle cleans up.
    public func cleanup() throws {
        do {
            let (safeDirectory, pathSessionID) = try Self.validateSessionDirectoryURL(
                directoryURL,
                fileManager: fileManager
            )
            guard pathSessionID == metadata.sessionID else {
                throw Self.securityError("Recovery session id does not match its private directory")
            }
            try Self.validateDirectory(safeDirectory, fileManager: fileManager)
            // Directory-only delete after path/owner checks. Do not require in-memory metadata
            // equality with on-disk sidecar contents; that would strand sessions after a retry
            // advanced lastAppliedHash through a different session handle.
            try fileManager.removeItem(at: safeDirectory)
        } catch {
            throw Self.mapSecurityError(error)
        }
    }

    public static func sha256Hex(_ data: Data) -> String {
        SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }

    // MARK: - Private

    private init(
        directoryURL: URL,
        metadataURL: URL,
        tempFileURL: URL,
        metadata: RecoveryConfigSessionMetadata,
        fileManager: FileManager
    ) throws {
        let location = try ConfigReader.volumeConfigLocation(labels: [
            ContainerIdentity.labelWorkspaceMode: ContainerIdentity.workspaceModeVolume,
            ContainerIdentity.labelWorkspaceFolder: metadata.workspaceFolder,
            ContainerIdentity.labelConfigFile: metadata.configFile
        ])
        self.directoryURL = directoryURL
        self.metadataURL = metadataURL
        self.tempFileURL = tempFileURL
        self.metadata = metadata
        self.fileManager = fileManager
        self.configPathInContainerValue = location.pathInContainer
    }

    private var validationLabels: [String: String] {
        [
            ContainerIdentity.labelWorkspaceMode: ContainerIdentity.workspaceModeVolume,
            ContainerIdentity.labelWorkspaceFolder: metadata.workspaceFolder,
            ContainerIdentity.labelConfigFile: metadata.configFile
        ]
    }

    private func recordConflict(bytes: Data, hash: String) throws {
        let url = directoryURL.appendingPathComponent(Self.conflictFileName, isDirectory: false)
        if fileManager.fileExists(atPath: url.path) {
            try Self.validateFile(url, expectedPermissions: 0o600, fileManager: fileManager)
        }
        try Self.writePrivateFile(bytes, to: url, fileManager: fileManager)
        metadata.conflictFileName = Self.conflictFileName
        metadata.conflictHash = hash
        metadata.conflictAcknowledged = false
        try persistMetadata()
    }

    private func persistMetadata() throws {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        let data: Data
        do {
            data = try encoder.encode(metadata)
        } catch {
            throw Self.securityError("Recovery session metadata could not be encoded")
        }
        if fileManager.fileExists(atPath: metadataURL.path) {
            try Self.validateFile(metadataURL, expectedPermissions: 0o600, fileManager: fileManager)
        }
        try Self.writePrivateFile(data, to: metadataURL, fileManager: fileManager)
    }

    private func validateSecureState() throws {
        try Self.validateDirectory(directoryURL, fileManager: fileManager)
        try Self.validateFile(tempFileURL, expectedPermissions: 0o600, fileManager: fileManager)
        try Self.validateFile(metadataURL, expectedPermissions: 0o600, fileManager: fileManager)
        try Self.validateMetadata(metadata)
        if let conflictFileURL {
            try Self.validateFile(conflictFileURL, expectedPermissions: 0o600, fileManager: fileManager)
            guard let expectedHash = metadata.conflictHash else {
                throw Self.securityError("Recovery conflict hash metadata is missing")
            }
            let actualHash: String
            do {
                actualHash = Self.sha256Hex(try Data(contentsOf: conflictFileURL))
            } catch {
                throw Self.securityError("Recovery conflict file could not be verified")
            }
            guard actualHash == expectedHash else {
                throw Self.securityError("Recovery conflict file hash does not match session metadata")
            }
        } else if metadata.conflictHash != nil {
            throw Self.securityError("Recovery conflict metadata has no retained conflict file")
        }
        do {
            let onDisk = try JSONDecoder().decode(
                RecoveryConfigSessionMetadata.self,
                from: Data(contentsOf: metadataURL)
            )
            guard onDisk == metadata else {
                throw Self.securityError("Recovery session metadata changed unexpectedly")
            }
        } catch let error as CLIError {
            throw error
        } catch {
            throw Self.securityError("Recovery session metadata could not be verified")
        }
    }

    private static func validateMetadata(_ metadata: RecoveryConfigSessionMetadata) throws {
        guard metadata.version == 1,
              metadata.tempFileName == Self.tempFileName,
              metadata.tempFileName == (metadata.tempFileName as NSString).lastPathComponent,
              metadata.tempFileName != ".",
              metadata.tempFileName != "..",
              !metadata.sessionID.isEmpty,
              !metadata.targetContainerID.isEmpty,
              !metadata.targetContainerName.isEmpty,
              !metadata.workspaceVolume.isEmpty,
              !metadata.configFile.isEmpty,
              !metadata.originalHash.isEmpty,
              !metadata.baselineHash.isEmpty
        else {
            throw securityError("Recovery session metadata is invalid")
        }
        try validateSessionID(metadata.sessionID)
        do {
            let location = try ConfigReader.volumeConfigLocation(labels: [
                ContainerIdentity.labelWorkspaceMode: ContainerIdentity.workspaceModeVolume,
                ContainerIdentity.labelWorkspaceFolder: metadata.workspaceFolder,
                ContainerIdentity.labelConfigFile: metadata.configFile
            ])
            guard location.workspaceFolder == metadata.workspaceFolder else {
                throw securityError("Recovery session workspace path is not canonical")
            }
        } catch let error as CLIError {
            if error.code == CLIErrorCode.recoveryUnavailable { throw error }
            throw securityError("Recovery session config path is outside its workspace")
        } catch {
            throw securityError("Recovery session config path is outside its workspace")
        }
        for hash in [metadata.originalHash, metadata.baselineHash, metadata.lastAppliedHash, metadata.conflictHash].compactMap({ $0 }) {
            guard hash.count == 64, hash.allSatisfy(\.isHexDigit) else {
                throw securityError("Recovery session hash metadata is invalid")
            }
        }
        if let conflict = metadata.conflictFileName {
            guard conflict == Self.conflictFileName,
                  conflict == (conflict as NSString).lastPathComponent
            else { throw securityError("Recovery conflict metadata is invalid") }
            guard metadata.conflictHash != nil else {
                throw securityError("Recovery conflict hash metadata is missing")
            }
        } else if metadata.conflictHash != nil {
            throw securityError("Recovery conflict metadata is invalid")
        }
        if metadata.conflictAcknowledged == true, metadata.conflictHash == nil {
            throw securityError("Recovery conflict acknowledgement metadata is invalid")
        }
    }

    private static func validateRequiredIdentity(
        sessionID: String,
        targetContainerID: String,
        targetContainerName: String,
        workspaceVolume: String,
        configFile: String
    ) throws {
        try validateSessionID(sessionID)
        guard !targetContainerID.isEmpty, !targetContainerName.isEmpty,
              !workspaceVolume.isEmpty, !configFile.isEmpty
        else {
            throw securityError("Recovery session identity is incomplete")
        }
    }

    public static func isSafeSessionID(_ value: String) -> Bool {
        guard !value.isEmpty, value.count <= 128,
              let first = value.unicodeScalars.first,
              let last = value.unicodeScalars.last,
              isSessionIDAlphaNumeric(first),
              isSessionIDAlphaNumeric(last)
        else { return false }
        return value.unicodeScalars.allSatisfy { scalar in
            isSessionIDAlphaNumeric(scalar) || scalar.value == 45
        }
    }

    /// Construct the only session directory accepted by `open`: one safe-id child of the
    /// process-private temporary root. The resolved path is checked before any session file is
    /// opened, and an existing symlink at the child is rejected.
    public static func directoryURL(
        forSessionID sessionID: String,
        fileManager: FileManager = .default
    ) throws -> URL {
        guard isSafeSessionID(sessionID) else {
            throw securityError("Recovery session id is not safe")
        }
        let root = fileManager.temporaryDirectory
            .standardizedFileURL
            .resolvingSymlinksInPath()
        let directory = root.appendingPathComponent(
            "\(directoryPrefix)\(sessionID)",
            isDirectory: true
        )
        _ = try validateSessionDirectoryURL(directory, fileManager: fileManager)
        return directory
    }

    private static func validateSessionID(_ value: String) throws {
        guard isSafeSessionID(value)
        else {
            throw securityError("Recovery session id is not safe")
        }
    }

    private static func isSessionIDAlphaNumeric(_ scalar: Unicode.Scalar) -> Bool {
        scalar.isASCII && (scalar.value >= 48 && scalar.value <= 57
            || scalar.value >= 65 && scalar.value <= 90
            || scalar.value >= 97 && scalar.value <= 122)
    }

    private static func validateSessionDirectoryURL(
        _ directoryURL: URL,
        fileManager: FileManager
    ) throws -> (URL, String) {
        let root = fileManager.temporaryDirectory
            .standardizedFileURL
            .resolvingSymlinksInPath()
        let candidate = directoryURL.standardizedFileURL
        guard candidate.deletingLastPathComponent().resolvingSymlinksInPath().path == root.path,
              candidate.pathComponents.count == root.pathComponents.count + 1,
              candidate.lastPathComponent.hasPrefix(directoryPrefix)
        else {
            throw securityError("Recovery session directory is not a direct child of the private temp root")
        }
        let sessionID = String(candidate.lastPathComponent.dropFirst(directoryPrefix.count))
        guard isSafeSessionID(sessionID) else {
            throw securityError("Recovery session directory id is not safe")
        }
        let expected = root.appendingPathComponent(
            "\(directoryPrefix)\(sessionID)",
            isDirectory: true
        )
        guard candidate.path == expected.path else {
            throw securityError("Recovery session directory resolved outside the private temp root")
        }
        try rejectSymlink(candidate, fileManager: fileManager)
        return (candidate, sessionID)
    }

    private static func rejectSymlink(_ url: URL, fileManager: FileManager) throws {
        if let _ = try? fileManager.destinationOfSymbolicLink(atPath: url.path) {
            throw securityError("Recovery session path must not be a symlink")
        }
    }

    private static func nonEmpty(_ value: String?) -> String? {
        let trimmed = value?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return trimmed.isEmpty ? nil : trimmed
    }

    private static func writePrivateFile(
        _ data: Data,
        to url: URL,
        fileManager: FileManager
    ) throws {
        do {
            try data.write(to: url, options: .atomic)
            try setPermissions(0o600, at: url, fileManager: fileManager)
            try validateFile(url, expectedPermissions: 0o600, fileManager: fileManager)
        } catch {
            throw securityError("Recovery session file could not be written securely")
        }
    }

    private static func setPermissions(
        _ permissions: Int,
        at url: URL,
        fileManager: FileManager
    ) throws {
        try fileManager.setAttributes(
            [.posixPermissions: NSNumber(value: permissions)],
            ofItemAtPath: url.path
        )
    }

    private static func validateDirectory(_ url: URL, fileManager: FileManager) throws {
        try rejectSymlink(url, fileManager: fileManager)
        let attrs: [FileAttributeKey: Any]
        do {
            attrs = try fileManager.attributesOfItem(atPath: url.path)
        } catch {
            throw securityError("Recovery session directory is unavailable")
        }
        guard attrs[.type] as? FileAttributeType == .typeDirectory,
              permissions(from: attrs) == 0o700,
              ownerMatches(attrs)
        else {
            throw securityError("Recovery session directory is not private")
        }
    }

    private static func validateFile(
        _ url: URL,
        expectedPermissions: Int,
        fileManager: FileManager
    ) throws {
        try rejectSymlink(url, fileManager: fileManager)
        let attrs: [FileAttributeKey: Any]
        do {
            attrs = try fileManager.attributesOfItem(atPath: url.path)
        } catch {
            throw securityError("Recovery session file is unavailable")
        }
        guard attrs[.type] as? FileAttributeType == .typeRegular,
              permissions(from: attrs) == expectedPermissions,
              ownerMatches(attrs)
        else {
            throw securityError("Recovery session file is not a private regular file")
        }
    }

    private static func permissions(from attrs: [FileAttributeKey: Any]) -> Int {
        (attrs[.posixPermissions] as? NSNumber)?.intValue ?? -1
    }

    private static func ownerMatches(_ attrs: [FileAttributeKey: Any]) -> Bool {
        guard let owner = attrs[.ownerAccountID] as? NSNumber else { return false }
        return owner.uint32Value == UInt32(getuid())
    }

    private static func securityError(_ message: String, hint: String? = nil) -> CLIError {
        CLIError(
            code: CLIErrorCode.recoveryUnavailable,
            message: message,
            hint: hint
                ?? "Keep the recovery helper and use the reported cleanup path after reviewing the session"
        )
    }

    private static func mapSecurityError(_ error: Error) -> CLIError {
        if let cli = error as? CLIError,
           [
               CLIErrorCode.recoveryUnavailable,
               CLIErrorCode.recoveryConflict,
               CLIErrorCode.recoveryVerificationFailed
           ].contains(cli.code)
        {
            return cli
        }
        let detail = (error as NSError).localizedDescription
        let suffix = detail.isEmpty ? "" : " (\(detail))"
        return securityError("Recovery session security validation failed\(suffix)")
    }
}
