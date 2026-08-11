import Foundation

/// Lightweight host-side resume state for bind-mode recovery after the managed container is gone.
///
/// Unlike volume recovery, bind recovery has no helper container. After a hard post-delete
/// failure the operator may edit the host stamped config and run `rebuild --name` later.
/// This retain stores only non-secret identity stamps so selection can resume without a live
/// container. It never stores config bytes and never creates a recovery helper.
public enum BindRecoveryResume {
    public static let directoryPrefix = "adev-bind-recovery-"

    public struct State: Equatable, Sendable, Codable {
        public let containerName: String
        public let containerID: String
        public let labels: [String: String]
        public let hostConfigPath: String

        public init(
            containerName: String,
            containerID: String,
            labels: [String: String],
            hostConfigPath: String
        ) {
            self.containerName = containerName
            self.containerID = containerID
            self.labels = labels
            self.hostConfigPath = hostConfigPath
        }
    }

    /// Private root under the process temporary directory.
    public static func rootURL(fileManager: FileManager = .default) -> URL {
        fileManager.temporaryDirectory
            .appendingPathComponent("adevcontainer-bind-recovery", isDirectory: true)
    }

    public static func directoryURL(
        forName name: String,
        fileManager: FileManager = .default
    ) throws -> URL {
        let safe = safeNameComponent(name)
        guard !safe.isEmpty else {
            throw CLIError(
                code: CLIErrorCode.recoveryUnavailable,
                message: "Bind recovery resume name is invalid"
            )
        }
        return rootURL(fileManager: fileManager)
            .appendingPathComponent(directoryPrefix + safe, isDirectory: true)
    }

    /// Retain stamps so a later named `rebuild` can proceed after the container was removed.
    public static func retain(
        container: ContainerInfo,
        hostConfigPath: String,
        fileManager: FileManager = .default
    ) throws {
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
            labels: RecoveryHelper.normalContainerLabels(container.labels),
            hostConfigPath: hostConfigPath
        )
        let data = try JSONEncoder().encode(state)
        let meta = dir.appendingPathComponent("state.json", isDirectory: false)
        try data.write(to: meta, options: .atomic)
        try fileManager.setAttributes(
            [.posixPermissions: NSNumber(value: 0o600)],
            ofItemAtPath: meta.path
        )
    }

    /// Load retained stamps for a named rebuild when the container is missing.
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
              RecoveryOrchestrator.isBindEligible(labels: state.labels),
              !state.hostConfigPath.isEmpty
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
