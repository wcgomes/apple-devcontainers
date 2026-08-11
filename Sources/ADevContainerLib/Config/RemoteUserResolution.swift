import Foundation

/// Pure remote connection user resolution for managed create paths.
///
/// Precedence (first non-empty after trim wins):
/// 1. config `remoteUser` (local devcontainer.json)
/// 2. config `containerUser` (local)
/// 3. image `devcontainer.metadata` `remoteUser` (last non-empty fragment)
/// 4. image `devcontainer.metadata` `containerUser` (last non-empty fragment)
/// 5. final OCI image `USER` (from successful image inspect)
/// 6. literal `root`
///
/// Local config wins when set (steps 1–2 before metadata). Create `-u` still uses only local
/// `containerUser` — metadata does not force create process user.
/// Inspect failure while config+metadata users are empty MUST throw — never invent `root` from failure.
/// No hardcoded editor usernames (`vscode`, etc.).
public enum RemoteUserResolution {
    /// Trim and reject empty/whitespace-only strings.
    public static func nonEmptyTrimmed(_ value: String?) -> String? {
        guard let value else { return nil }
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }

    /// Config-only tiers (steps 1–2). Nil when both unset/empty.
    public static func fromConfig(remoteUser: String?, containerUser: String?) -> String? {
        nonEmptyTrimmed(remoteUser) ?? nonEmptyTrimmed(containerUser)
    }

    /// Full connection-user resolution.
    ///
    /// - Parameter ociUserProvider: Invoked only when config and metadata users are empty. Must throw on
    ///   inspect failure; return nil/empty on successful inspect with no usable USER.
    public static func resolve(
        remoteUser: String?,
        containerUser: String?,
        metadataRemoteUser: String? = nil,
        metadataContainerUser: String? = nil,
        ociUserProvider: () throws -> String?
    ) throws -> String {
        if let fromConfig = fromConfig(remoteUser: remoteUser, containerUser: containerUser) {
            return fromConfig
        }
        if let fromMeta = nonEmptyTrimmed(metadataRemoteUser) ?? nonEmptyTrimmed(metadataContainerUser) {
            return fromMeta
        }
        let ociUser: String?
        do {
            ociUser = try ociUserProvider()
        } catch let err as CLIError {
            throw CLIError(
                code: err.code,
                property: err.property ?? "remoteUser",
                message: "Failed to resolve remote connection user: \(err.message)",
                hint: err.hint ?? "Image inspect must succeed when remoteUser and containerUser are unset"
            )
        } catch {
            throw CLIError(
                code: CLIErrorCode.runtimeFailed,
                property: "remoteUser",
                message: "Failed to resolve remote connection user: image inspect failed (\(error.localizedDescription))",
                hint: "Image inspect must succeed when remoteUser and containerUser are unset"
            )
        }
        if let user = nonEmptyTrimmed(ociUser) {
            return user
        }
        return "root"
    }

    /// Resolve using runtime image inspect of `imageRef` when config/metadata users are empty.
    ///
    /// - Parameter knownOCIUser: When non-nil, the outer optional means "already inspected"
    ///   (inner value may be nil/empty → step 6 `root`). Avoids a second inspect after Features
    ///   when base USER was already obtained for Dockerfile restore.
    /// - Parameter knownMetadataUsers: When non-nil, skip label re-read (e.g. Features already
    ///   parsed base image `devcontainer.metadata`). Derived images may lack the base label.
    public static func resolve(
        config: ResolvedDevContainerConfig,
        imageRef: String,
        runtime: AppleContainerRuntime,
        knownOCIUser: String?? = nil,
        knownMetadataUsers: DevContainerMetadataLabel.ImageMetadataUsers? = nil
    ) throws -> String {
        let meta = knownMetadataUsers
            ?? DevContainerMetadataLabel.parseUsers(from: (try? runtime.imageLabels(ref: imageRef)) ?? [:])
        return try resolve(
            remoteUser: config.remoteUser,
            containerUser: config.containerUser,
            metadataRemoteUser: meta.remoteUser,
            metadataContainerUser: meta.containerUser,
            ociUserProvider: {
                if let known = knownOCIUser {
                    return known
                }
                return try runtime.inspectImage(ref: imageRef).user
            }
        )
    }

    /// Apply resolved connection user onto config so lifecycle / VS Code consumers see it via
    /// `connectionUser` / `effectiveUser`, without changing `containerUser` (create `-u`).
    public static func applyingConnectionUser(
        _ connectionUser: String,
        to config: ResolvedDevContainerConfig
    ) -> ResolvedDevContainerConfig {
        var copy = config
        copy.remoteUser = connectionUser
        return copy
    }
}
