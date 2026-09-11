import Foundation

/// Deterministic local tag for a product-built user Dockerfile.
///
/// Format: `adev-{nameBase}-df:{hash12}` (fallback `adevcontainer-df:{hash12}` when nameBase is empty).
/// Hash material: Dockerfile file bytes + context path + args + target. Distinct from Features
/// `adev-{base}:{hash12}` / `recipeVersion`.
public enum DockerfileImageTag {
    public static let emptyBaseFallback = "adevcontainer-df"

    public static func compute(
        dockerfileBytes: Data,
        context: String,
        args: [String: String],
        target: String?,
        nameBase: String
    ) -> String {
        var material: [String: Any] = [
            "dockerfileBytes": dockerfileBytes.base64EncodedString(),
            "context": context,
            "args": args
        ]
        if let target { material["target"] = target }
        let hash = ContainerIdentity.configHash(from: material)
        let short = String(hash.prefix(12))
        let repo = nameBase.isEmpty ? emptyBaseFallback : "adev-\(nameBase)-df"
        return "\(repo):\(short)"
    }
}

public struct DockerfileImageBuildResult: Equatable, Sendable {
    public var tag: String
    public var reusedExistingImage: Bool

    public init(tag: String, reusedExistingImage: Bool) {
        self.tag = tag
        self.reusedExistingImage = reusedExistingImage
    }
}

/// Build or reuse the product Dockerfile tag on create paths.
public enum DockerfileImageBuilder {
    public static func resolvedPath(_ relative: String, configDirectory: String) -> String {
        let base = URL(fileURLWithPath: configDirectory, isDirectory: true)
        return URL(fileURLWithPath: relative, relativeTo: base).standardizedFileURL.path
    }

    public static func isInsideConfigDirectory(_ path: String, configDirectory: String) -> Bool {
        let dir = URL(fileURLWithPath: configDirectory, isDirectory: true).standardizedFileURL.path
        let candidate = URL(fileURLWithPath: path).standardizedFileURL.path
        if candidate == dir { return true }
        let prefix = dir.hasSuffix("/") ? dir : dir + "/"
        return candidate.hasPrefix(prefix)
    }

    /// Build or reuse `adev-{base}-df:{hash12}` from an admitted nested `build`.
    ///
    /// - Parameter forceBuild: When true (rebuild), always invoke `container build` even if
    ///   the product tag already exists so unhashed COPY sources are picked up.
    public static func buildOrReuse(
        build: DockerfileBuild,
        configDirectory: String,
        nameBase: String,
        runtime: AppleContainerRuntime,
        platform: String = ContainerPlatform.defaultLinuxPlatform,
        requireInsideConfigDirectory: Bool = false,
        forceBuild: Bool = false,
        fileManager: FileManager = .default
    ) throws -> DockerfileImageBuildResult {
        let dockerfilePath = resolvedPath(build.dockerfile, configDirectory: configDirectory)
        let contextPath = resolvedPath(build.context, configDirectory: configDirectory)

        if requireInsideConfigDirectory {
            if !isInsideConfigDirectory(dockerfilePath, configDirectory: configDirectory)
                || !isInsideConfigDirectory(contextPath, configDirectory: configDirectory)
            {
                throw CLIError(
                    code: CLIErrorCode.dockerfileBuild,
                    property: "build",
                    message: "Dockerfile or context path escapes the config-file directory",
                    hint: "On clone, build.dockerfile and build.context must stay inside the directory that contains the config file"
                )
            }
        }

        var isDir: ObjCBool = false
        let dockerfileOnDisk = fileManager.fileExists(atPath: dockerfilePath, isDirectory: &isDir) && !isDir.boolValue
        let bytes = (dockerfileOnDisk ? fileManager.contents(atPath: dockerfilePath) : nil) ?? build.dockerfileBytes
        let tag = DockerfileImageTag.compute(
            dockerfileBytes: bytes,
            context: build.context,
            args: build.args,
            target: build.target,
            nameBase: nameBase
        )

        if !forceBuild, try runtime.imageExists(ref: tag) {
            StatusPrinter.status("Reusing image", item: tag)
            return DockerfileImageBuildResult(tag: tag, reusedExistingImage: true)
        }

        guard dockerfileOnDisk else {
            throw CLIError(
                code: CLIErrorCode.dockerfileBuild,
                property: "build",
                message: "Dockerfile not found at \(dockerfilePath)",
                hint: "Set build.dockerfile to a file relative to the config-file directory"
            )
        }
        guard fileManager.fileExists(atPath: contextPath, isDirectory: &isDir), isDir.boolValue else {
            throw CLIError(
                code: CLIErrorCode.dockerfileBuild,
                property: "build",
                message: "Build context directory not found at \(contextPath)",
                hint: "Set build.context to a directory relative to the config-file directory"
            )
        }

        StatusPrinter.status("Building image", item: tag)
        try runtime.build(
            contextDirectory: contextPath,
            dockerfilePath: dockerfilePath,
            tag: tag,
            platform: platform,
            buildArgs: build.args,
            target: build.target,
            errorCode: CLIErrorCode.dockerfileBuild,
            errorProperty: "build"
        )
        return DockerfileImageBuildResult(tag: tag, reusedExistingImage: false)
    }
}
