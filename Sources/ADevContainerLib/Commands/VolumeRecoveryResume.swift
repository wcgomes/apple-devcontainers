import Foundation

/// Name-indexed pointer at a volume recovery session after the old container is gone.
///
/// Volume recovery normally resumes through a marked helper (`openRetry`). A process exit
/// after the old container is deleted can leave the secure session on disk and never create
/// that helper. This retain stores only non-secret identity so `rebuild --name` can open the
/// existing session, reuse the stamped workspace volume, and refuse to manufacture a blank one.
/// It never stores config bytes and never creates a container or volume.
public enum VolumeRecoveryResume {
    public static let directoryPrefix = "adev-volume-recovery-"

    public struct State: Equatable, Sendable, Codable {
        public let containerName: String
        public let containerID: String
        public let labels: [String: String]
        public let sessionID: String
        public let authorName: String?
        public let authorEmail: String?

        public init(
            containerName: String,
            containerID: String,
            labels: [String: String],
            sessionID: String,
            authorName: String?,
            authorEmail: String?
        ) {
            self.containerName = containerName
            self.containerID = containerID
            self.labels = labels
            self.sessionID = sessionID
            self.authorName = authorName
            self.authorEmail = authorEmail
        }

        public var identity: GitAuthorIdentity {
            GitAuthorIdentity(name: authorName, email: authorEmail)
        }
    }

    public static func rootURL(fileManager: FileManager = .default) -> URL {
        fileManager.temporaryDirectory
            .appendingPathComponent("adevcontainer-volume-recovery", isDirectory: true)
    }

    public static func directoryURL(
        forName name: String,
        fileManager: FileManager = .default
    ) throws -> URL {
        let safe = safeNameComponent(name)
        guard !safe.isEmpty else {
            throw CLIError(
                code: CLIErrorCode.recoveryUnavailable,
                message: "Volume recovery resume name is invalid"
            )
        }
        return rootURL(fileManager: fileManager)
            .appendingPathComponent(directoryPrefix + safe, isDirectory: true)
    }

    /// Publish the session id under the container name before the old container is deleted.
    /// A later process exit can then resume without a live helper.
    public static func retain(
        container: ContainerInfo,
        sessionID: String,
        authorName: String?,
        authorEmail: String?,
        fileManager: FileManager = .default
    ) throws {
        guard RecoveryConfigSession.isSafeSessionID(sessionID) else {
            throw CLIError(
                code: CLIErrorCode.recoveryUnavailable,
                message: "Volume recovery resume session id is not safe"
            )
        }
        let labels = RecoveryHelper.normalContainerLabels(container.labels)
        guard RecoveryHelper.isEligible(labels: labels) else {
            throw CLIError(
                code: CLIErrorCode.recoveryUnavailable,
                message: "Volume recovery resume requires clone-origin stamps"
            )
        }

        if let previous = try? load(name: container.name, fileManager: fileManager),
           previous.sessionID != sessionID,
           RecoveryConfigSession.isSafeSessionID(previous.sessionID),
           let previousDir = try? RecoveryConfigSession.directoryURL(
               forSessionID: previous.sessionID,
               fileManager: fileManager
           )
        {
            try? fileManager.removeItem(at: previousDir)
        }

        let dir = try directoryURL(forName: container.name, fileManager: fileManager)
        if fileManager.fileExists(atPath: dir.path) {
            try fileManager.removeItem(at: dir)
        }
        try fileManager.createDirectory(
            at: dir,
            withIntermediateDirectories: true,
            attributes: [.posixPermissions: NSNumber(value: 0o700)]
        )

        let state = State(
            containerName: container.name,
            containerID: container.id,
            labels: labels,
            sessionID: sessionID,
            authorName: nonEmpty(authorName),
            authorEmail: nonEmpty(authorEmail)
        )
        let data = try JSONEncoder().encode(state)
        let meta = dir.appendingPathComponent("state.json", isDirectory: false)
        try data.write(to: meta, options: .atomic)
        try fileManager.setAttributes(
            [.posixPermissions: NSNumber(value: 0o600)],
            ofItemAtPath: meta.path
        )
    }

    /// Load retained stamps when `rebuild --name` cannot find a live container or helper.
    public static func load(
        name: String,
        fileManager: FileManager = .default
    ) throws -> State? {
        let dir = try directoryURL(forName: name, fileManager: fileManager)
        let meta = dir.appendingPathComponent("state.json", isDirectory: false)
        guard fileManager.fileExists(atPath: meta.path) else { return nil }
        let data: Data
        do {
            data = try Data(contentsOf: meta)
        } catch {
            return nil
        }
        guard let state = try? JSONDecoder().decode(State.self, from: data),
              state.containerName == name,
              RecoveryConfigSession.isSafeSessionID(state.sessionID),
              RecoveryHelper.isEligible(labels: state.labels)
        else {
            try? cleanup(name: name, fileManager: fileManager)
            return nil
        }
        return state
    }

    public static func cleanup(name: String, fileManager: FileManager = .default) throws {
        let dir = try directoryURL(forName: name, fileManager: fileManager)
        if fileManager.fileExists(atPath: dir.path) {
            try fileManager.removeItem(at: dir)
        }
    }

    public static func containerInfo(from state: State) -> ContainerInfo {
        ContainerInfo(
            id: state.containerID.isEmpty ? state.containerName : state.containerID,
            name: state.containerName,
            state: "exited",
            labels: state.labels,
            image: ""
        )
    }

    private static func nonEmpty(_ value: String?) -> String? {
        let trimmed = value?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return trimmed.isEmpty ? nil : trimmed
    }

    private static func safeNameComponent(_ name: String) -> String {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty,
              !trimmed.contains("/"),
              !trimmed.contains(".."),
              trimmed != ".",
              trimmed != ".."
        else { return "" }
        let allowed = CharacterSet.alphanumerics.union(CharacterSet(charactersIn: "-_."))
        let filtered = String(trimmed.unicodeScalars.map { allowed.contains($0) ? Character($0) : "_" })
        return String(filtered.prefix(120))
    }
}
