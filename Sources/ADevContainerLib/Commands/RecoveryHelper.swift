import Foundation

/// Policy and runtime request primitives for a clone-origin volume recovery endpoint.
///
/// This type deliberately does not orchestrate rebuild retries. It owns the invariants that
/// make a helper safe to create: the target must carry clone identity stamps, the immutable
/// native image must be preflighted, and the exact existing workspace volume must be present.
public enum RecoveryHelper {
    /// Alpine 3.20 arm64 manifest digest verified against Docker Hub and Apple container.
    ///
    /// The digest is the platform-specific `linux/arm64/v8` manifest, not a mutable tag. The
    /// image was verified with `container image pull --platform linux/arm64` followed by
    /// `container image inspect`; its variant reports `os=linux`, `architecture=arm64`.
    public static let helperImageReference =
        "docker.io/library/alpine@sha256:45e09956dc667c5eff3583c9d94830261fb1ca0be10a0a7db36266edf5de9e1d"
    public static let helperImageDigest =
        "sha256:45e09956dc667c5eff3583c9d94830261fb1ca0be10a0a7db36266edf5de9e1d"
    public static let helperPlatform = "linux/arm64"

    public static let recoveryMarkerLabel = "devcontainer.recovery"
    public static let recoveryMarkerValue = "adevcontainer"
    public static let recoverySessionLabel = "devcontainer.recovery_session"
    public static let recoveryForLabel = "devcontainer.recovery_for"

    /// Recovery-only labels must never survive into the normal replacement container. Keep the
    /// prefix rule in addition to the known keys so a future recovery marker cannot leak by
    /// accident when rebuild copies the selected helper's labels.
    public static func normalContainerLabels(_ labels: [String: String]) -> [String: String] {
        labels.filter { key, _ in
            !key.hasPrefix("devcontainer.recovery")
        }
    }

    public struct Image: Equatable, Sendable {
        public let reference: String
        public let digest: String
        public let platform: String

        public init(reference: String, digest: String, platform: String) {
            self.reference = reference
            self.digest = digest
            self.platform = platform
        }
    }

    public static let pinnedImage = Image(
        reference: helperImageReference,
        digest: helperImageDigest,
        platform: helperPlatform
    )

    public struct Eligibility: Equatable, Sendable {
        public let isEligible: Bool
        public let workspaceVolume: String?
        public let configFile: String?
        public let gitURL: String?
        public let workspaceFolder: String
        public let missingStamps: [String]

        public init(
            isEligible: Bool,
            workspaceVolume: String?,
            configFile: String?,
            gitURL: String?,
            workspaceFolder: String,
            missingStamps: [String]
        ) {
            self.isEligible = isEligible
            self.workspaceVolume = workspaceVolume
            self.configFile = configFile
            self.gitURL = gitURL
            self.workspaceFolder = workspaceFolder
            self.missingStamps = missingStamps
        }
    }

    public struct HelperRequest: Equatable, Sendable {
        public let image: Image
        public let sessionID: String
        public let containerName: String
        public let workspaceVolume: String
        public let workspaceFolder: String
        public let labels: [String: String]
        public let createRequest: CreateRequest

        public init(
            image: Image,
            sessionID: String,
            containerName: String,
            workspaceVolume: String,
            workspaceFolder: String,
            labels: [String: String],
            createRequest: CreateRequest
        ) {
            self.image = image
            self.sessionID = sessionID
            self.containerName = containerName
            self.workspaceVolume = workspaceVolume
            self.workspaceFolder = workspaceFolder
            self.labels = labels
            self.createRequest = createRequest
        }
    }

    public struct Preparation: Equatable, Sendable {
        public let image: Image
        public let request: HelperRequest

        fileprivate init(image: Image, request: HelperRequest) {
            self.image = image
            self.request = request
        }
    }

    /// Determine clone-origin eligibility from the selected container's existing stamps.
    public static func eligibility(labels: [String: String]) -> Eligibility {
        let managed = trimmed(labels[ContainerIdentity.labelManaged])
        let mode = trimmed(labels[ContainerIdentity.labelWorkspaceMode])
        let gitURL = nonEmpty(labels[ContainerIdentity.labelGitURL])
        let workspaceVolume = nonEmpty(labels[ContainerIdentity.labelWorkspaceVolume])
        let configFile = nonEmpty(labels[ContainerIdentity.labelConfigFile])
        let stampedWorkspaceFolder = nonEmpty(labels[ContainerIdentity.labelWorkspaceFolder]) ?? "/workspaces"
        let location = try? ConfigReader.volumeConfigLocation(labels: labels)
        let workspaceFolder = location?.workspaceFolder ?? stampedWorkspaceFolder

        var missing: [String] = []
        if managed != ContainerIdentity.managedValue {
            missing.append(ContainerIdentity.labelManaged)
        }
        if mode != ContainerIdentity.workspaceModeVolume {
            missing.append(ContainerIdentity.labelWorkspaceMode)
        }
        if gitURL == nil { missing.append(ContainerIdentity.labelGitURL) }
        if workspaceVolume == nil { missing.append(ContainerIdentity.labelWorkspaceVolume) }
        if configFile == nil { missing.append(ContainerIdentity.labelConfigFile) }
        if configFile != nil, location == nil
        {
            missing.append("config_path_within_workspace")
        }

        return Eligibility(
            isEligible: missing.isEmpty,
            workspaceVolume: workspaceVolume,
            configFile: configFile,
            gitURL: gitURL,
            workspaceFolder: workspaceFolder,
            missingStamps: missing
        )
    }

    public static func isEligible(labels: [String: String]) -> Bool {
        eligibility(labels: labels).isEligible
    }

    public static func isEligible(_ container: ContainerInfo) -> Bool {
        isEligible(labels: container.labels)
    }

    public static func isRecoveryHelper(_ container: ContainerInfo) -> Bool {
        container.labels[recoveryMarkerLabel] == recoveryMarkerValue
    }

    public static func isPinnedHelperImage(_ container: ContainerInfo) -> Bool {
        container.image == helperImageReference
    }

    /// Verify the immutable image and exact platform before the old container delete gate.
    /// When `pullIfMissing` is false, a missing local image fails closed without a pull.
    public static func preflightImage(
        runtime: AppleContainerRuntime,
        pullIfMissing: Bool = true
    ) throws -> Image {
        let inspection: RuntimeImageInspection
        if let found = try? runtime.inspectImage(ref: helperImageReference) {
            inspection = found
        } else {
            guard pullIfMissing else {
                throw unavailable(
                    "The pinned recovery helper image is unavailable",
                    hint: "Allow the recovery helper image to be pulled before deleting the old container"
                )
            }
            do {
                try runtime.pullImage(helperImageReference, platform: helperPlatform)
            } catch {
                throw unavailable(
                    "The pinned recovery helper image could not be pulled",
                    hint: "Check Apple container connectivity and image access"
                )
            }
            do {
                inspection = try runtime.inspectImage(ref: helperImageReference)
            } catch {
                throw unavailable(
                    "The pinned recovery helper image could not be verified",
                    hint: "The image must be inspectable before the old container is deleted"
                )
            }
        }

        guard inspection.containsDigest(helperImageDigest) else {
            throw unavailable(
                "The recovery helper digest could not be verified",
                hint: "Refusing a mutable or different helper image"
            )
        }
        guard inspection.hasPlatform(helperPlatform) else {
            throw unavailable(
                "The recovery helper image is not available for \(helperPlatform)",
                hint: "Recovery requires the pinned native arm64 Alpine manifest"
            )
        }
        return pinnedImage
    }

    /// Prepare all helper inputs before the destructive boundary. No container or volume is
    /// deleted or created by this method.
    public static func prepare(
        for container: ContainerInfo,
        sessionID: String,
        runtime: AppleContainerRuntime,
        pullIfMissing: Bool = true
    ) throws -> Preparation {
        let eligibility = try requireEligibility(container.labels)
        try validateSessionID(sessionID)

        guard let workspaceVolume = eligibility.workspaceVolume else {
            throw unavailable("The recovery target has no workspace volume stamp")
        }
        guard (try runtime.volumeExists(workspaceVolume, requireObjectEntries: true)) else {
            throw unavailable(
                "The existing workspace volume is not present; refusing a blank replacement",
                hint: "Restore the stamped workspace volume before retrying recovery"
            )
        }

        let image = try preflightImage(runtime: runtime, pullIfMissing: pullIfMissing)
        let request = try makeRequest(
            for: container,
            sessionID: sessionID,
            image: image
        )
        return Preparation(image: image, request: request)
    }

    /// Construct a helper create request without touching the runtime. `prepare` should be
    /// used at the pre-delete gate when image and volume verification are required.
    public static func makeRequest(
        for container: ContainerInfo,
        sessionID: String,
        image: Image = pinnedImage
    ) throws -> HelperRequest {
        let eligibility = try requireEligibility(container.labels)
        try validateSessionID(sessionID)
        guard let workspaceVolume = eligibility.workspaceVolume else {
            throw unavailable("The recovery target has no workspace volume stamp")
        }
        guard image == pinnedImage else {
            throw unavailable("Recovery helper image is not the checked-in pinned image")
        }

        var labels = container.labels
        labels[recoveryMarkerLabel] = recoveryMarkerValue
        labels[recoverySessionLabel] = sessionID
        let configHash = labels[ContainerIdentity.labelConfigHash] ?? ""
        let createRequest = CreateRequest(
            name: container.name,
            image: image.reference,
            labels: labels,
            workspaceBindHost: workspaceVolume,
            workspaceBindTarget: eligibility.workspaceFolder,
            workspaceMountMode: .volume,
            env: [:],
            user: nil,
            workdir: eligibility.workspaceFolder,
            mounts: [],
            publishPorts: [],
            portsAttributes: [:],
            runArgs: [],
            memoryLimit: nil,
            cpuLimit: nil,
            platform: image.platform,
            configHash: configHash
        )
        return HelperRequest(
            image: image,
            sessionID: sessionID,
            containerName: container.name,
            workspaceVolume: workspaceVolume,
            workspaceFolder: eligibility.workspaceFolder,
            labels: labels,
            createRequest: createRequest
        )
    }

    /// Create and start a prepared helper. Explicit volume preflight is repeated immediately
    /// before create, but runtime volume creation is disabled so a missing/racing volume cannot
    /// silently become a blank recovery target.
    public static func createHelper(
        preparation: Preparation,
        runtime: AppleContainerRuntime
    ) throws -> String {
        guard preparation.image == pinnedImage else {
            throw unavailable("Recovery helper preparation is not pinned")
        }
        guard try runtime.volumeExists(
            preparation.request.workspaceVolume,
            requireObjectEntries: true
        ) else {
            throw unavailable(
                "The existing workspace volume is not present; refusing a blank replacement",
                hint: "Restore the stamped workspace volume before retrying recovery"
            )
        }
        var createdID: String?
        do {
            let id = try runtime.create(
                request: preparation.request.createRequest,
                ensureVolumes: false
            )
            createdID = id
            try runtime.start(nameOrId: id)
            try runtime.verifyVolumeAttachment(
                nameOrId: id,
                volumeName: preparation.request.workspaceVolume,
                targetPath: preparation.request.workspaceFolder,
                readOnly: false
            )
        } catch {
            if let createdID {
                try? runtime.delete(nameOrId: createdID, force: true)
            }
            throw unavailable(
                "The recovery helper could not be created or started",
                hint: "The workspace volume was not modified"
            )
        }
        return createdID!
    }

    /// Attachment verification seam used after failed-container cleanup and before helper
    /// mounting. It never removes a container or volume.
    public static func verifyWorkspaceVolumeDetached(
        volumeName: String,
        runtime: AppleContainerRuntime
    ) throws {
        try runtime.verifyVolumeDetached(volumeName: volumeName)
    }

    /// Ensure a retained recovery helper can accept `exec` before read/write/readback.
    ///
    /// Apple `container` can report `state=running` while rejecting exec with
    /// `cannot exec: container is not running` (stale/zombie keep-alive). Named retry also
    /// applies edits before the ordinary volume-mode auto-start gate, so a stopped helper must
    /// be started here. Probe with a no-op exec; on failure attempt `start`, then one
    /// stop+start bounce, then fail closed without touching volumes.
    public static func ensureExecReady(
        nameOrId: String,
        runtime: AppleContainerRuntime
    ) throws {
        if execProbe(nameOrId: nameOrId, runtime: runtime) {
            return
        }
        // Stopped helper (or inspect lag): start may be enough.
        do {
            try runtime.start(nameOrId: nameOrId)
        } catch {
            // Fall through to bounce; a zombie "running" start can no-op/fail.
        }
        if execProbe(nameOrId: nameOrId, runtime: runtime) {
            return
        }
        // Zombie running metadata: bounce once.
        try? runtime.stop(nameOrId: nameOrId)
        do {
            try runtime.start(nameOrId: nameOrId)
        } catch {
            throw unavailable(
                "The recovery helper could not be restarted for write-back",
                hint: "Keep the recovery session; check Apple container system status"
            )
        }
        guard execProbe(nameOrId: nameOrId, runtime: runtime) else {
            throw unavailable(
                "The recovery helper is not accepting exec",
                hint: "Keep the recovery session; check Apple container system status and retry"
            )
        }
    }

    private static func execProbe(
        nameOrId: String,
        runtime: AppleContainerRuntime
    ) -> Bool {
        do {
            let result = try runtime.exec(nameOrId: nameOrId, command: ["true"])
            return result.succeeded
        } catch {
            return false
        }
    }

    private static func requireEligibility(_ labels: [String: String]) throws -> Eligibility {
        let result = eligibility(labels: labels)
        guard result.isEligible else {
            throw unavailable(
                "The selected container is not a clone-origin volume target",
                hint: "Recovery requires managed volume-mode clone identity stamps"
            )
        }
        return result
    }

    private static func validateSessionID(_ sessionID: String) throws {
        guard RecoveryConfigSession.isSafeSessionID(sessionID)
        else {
            throw unavailable("Recovery session marker is not opaque and safe")
        }
    }

    private static func trimmed(_ value: String?) -> String {
        value?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
    }

    private static func nonEmpty(_ value: String?) -> String? {
        let result = trimmed(value)
        return result.isEmpty ? nil : result
    }

    private static func unavailable(_ message: String, hint: String? = nil) -> CLIError {
        CLIError(code: CLIErrorCode.recoveryUnavailable, message: message, hint: hint)
    }
}
