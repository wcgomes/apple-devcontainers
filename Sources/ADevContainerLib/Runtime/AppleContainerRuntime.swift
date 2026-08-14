import Foundation
import Crypto

public struct ContainerInfo: Equatable, Sendable {
    public var id: String
    public var name: String
    public var state: String
    public var labels: [String: String]
    public var image: String?

    public var isRunning: Bool {
        state.lowercased() == "running"
    }
}

public enum ContainerMountType: String, Equatable, Sendable {
    case bind
    case volume
    case virtiofs
    case tmpfs
    case unknown
}

/// A mount reported by Apple `container inspect`/`list` machine JSON.
public struct ContainerMountInfo: Equatable, Sendable {
    public var type: ContainerMountType
    /// Backing source reported by Apple container (for a named volume this is usually a
    /// volume image path, not the logical volume name).
    public var source: String
    public var destination: String
    public var readOnly: Bool
    /// Logical named-volume identity from `type.volume.name`.
    public var logicalVolumeName: String?

    public init(
        type: ContainerMountType,
        source: String,
        destination: String,
        readOnly: Bool = false,
        logicalVolumeName: String? = nil
    ) {
        self.type = type
        self.source = source
        self.destination = destination
        self.readOnly = readOnly
        self.logicalVolumeName = logicalVolumeName
    }
}

public struct RuntimeImagePlatform: Equatable, Sendable {
    public var os: String
    public var architecture: String
    public var variant: String?
    public var digest: String?

    public init(
        os: String,
        architecture: String,
        variant: String? = nil,
        digest: String? = nil
    ) {
        self.os = os
        self.architecture = architecture
        self.variant = variant
        self.digest = digest
    }

    public var normalizedPlatform: String {
        "\(os.lowercased())/\(architecture.lowercased())"
    }
}

public struct RuntimeImageInspection: Equatable, Sendable {
    public var reference: String
    public var digests: [String]
    public var platforms: [RuntimeImagePlatform]
    /// Final OCI image `USER` when present in inspect JSON. Empty/nil means absent — never fabricated `"root"`.
    public var user: String?

    public init(
        reference: String,
        digests: [String] = [],
        platforms: [RuntimeImagePlatform] = [],
        user: String? = nil
    ) {
        self.reference = reference
        self.digests = digests
        self.platforms = platforms
        self.user = user
    }

    public func hasPlatform(_ platform: String) -> Bool {
        let wanted = platform.lowercased()
        return platforms.contains { $0.normalizedPlatform == wanted }
    }

    public func containsDigest(_ digest: String) -> Bool {
        digests.contains { $0.lowercased() == digest.lowercased() }
    }
}

public enum SafeFileWriteResult: Equatable, Sendable {
    case applied(hash: String)
    case conflict(currentHash: String)
}

/// Sole module that invokes the Apple `container` CLI.
public struct AppleContainerRuntime: Sendable {
    public var executablePath: String
    public var runner: any ProcessRunning
    /// Used for interactive/TTY `exec` (inherits host stdio).
    public var interactiveRunner: any ProcessRunning

    public init(
        executablePath: String = AppleContainerRuntime.resolveDefaultBinary(),
        runner: any ProcessRunning = FoundationProcessRunner(),
        interactiveRunner: any ProcessRunning = InteractiveProcessRunner()
    ) {
        self.executablePath = executablePath
        self.runner = runner
        self.interactiveRunner = interactiveRunner
    }

    public static let defaultBinaryPath = "/usr/local/bin/container"

    public static func resolveDefaultBinary(fileManager: FileManager = .default) -> String {
        if fileManager.isExecutableFile(atPath: defaultBinaryPath) {
            return defaultBinaryPath
        }
        // PATH lookup
        if let pathEnv = ProcessInfo.processInfo.environment["PATH"] {
            for dir in pathEnv.split(separator: ":") {
                let candidate = "\(dir)/container"
                if fileManager.isExecutableFile(atPath: candidate) {
                    return candidate
                }
            }
        }
        return defaultBinaryPath
    }

    // MARK: - Doctor helpers

    public func binaryExists(fileManager: FileManager = .default) -> Bool {
        fileManager.isExecutableFile(atPath: executablePath)
    }

    public func systemVersion() throws -> [[String: Any]] {
        let result = try invoke(["system", "version", "--format", "json"])
        try ensureSuccess(result, action: "system version")
        return try parseJSONArray(result.stdout)
    }

    public func systemStatus() throws -> [String: Any] {
        let result = try invoke(["system", "status", "--format", "json"])
        try ensureSuccess(result, action: "system status")
        return try parseJSONObject(result.stdout)
    }

    /// Effective system properties as TOML text (`container system property list`).
    public func systemPropertyList() throws -> String {
        let result = try invoke(["system", "property", "list"])
        try ensureSuccess(result, action: "system property list")
        return result.stdoutString
    }

    /// Stop Apple container services (`container system stop`).
    public func systemStop() throws {
        let result = try invoke(["system", "stop"], streamStderr: true)
        try ensureSuccess(result, action: "system stop")
    }

    /// Start Apple container services (`container system start`).
    public func systemStart() throws {
        let result = try invoke(["system", "start"], streamStderr: true)
        try ensureSuccess(result, action: "system start")
    }

    /// Stop the BuildKit builder container if running.
    public func builderStop() throws {
        let result = try invoke(["builder", "stop"], streamStderr: true)
        try ensureSuccess(result, action: "builder stop")
    }

    /// Delete the BuildKit builder so the next build starts fresh (picks up config).
    public func builderDelete(force: Bool = true) throws {
        var args = ["builder", "delete"]
        if force { args.append("--force") }
        let result = try invoke(args, streamStderr: true)
        if result.succeeded { return }
        // Alternate verb
        var altArgs = ["builder", "rm"]
        if force { altArgs.append("--force") }
        let alt = try invoke(altArgs, streamStderr: true)
        if alt.succeeded { return }
        throw mapFailure(result, action: "builder delete")
    }

    /// Whether the BuildKit builder is currently running (`container builder status --format json`).
    /// - `true` when any builder entry has `status.state == running`
    /// - `false` when status is empty (absent), stopped, or any non-running state
    /// - `true` when status cannot be determined (fail closed: skip restore-stop if unsure)
    public func isBuilderRunning() -> Bool {
        guard let result = try? invoke(["builder", "status", "--format", "json"]),
              result.succeeded,
              let arr = try? parseJSONArray(result.stdout)
        else {
            return true
        }
        if arr.isEmpty { return false }
        for item in arr {
            let status = item["status"] as? [String: Any] ?? [:]
            let state = ((status["state"] as? String) ?? "").lowercased()
            if state == "running" { return true }
        }
        return false
    }

    // MARK: - Lifecycle

    /// Pull an image. Pass `platform` (e.g. `linux/arm64`) for multi-arch refs; never enables Rosetta.
    public func pullImage(_ image: String, platform: String? = ContainerPlatform.defaultLinuxPlatform) throws {
        var args = ["image", "pull"]
        if let platform, !platform.isEmpty {
            args += ["--platform", platform]
        }
        args.append(image)
        let result = try invoke(args, streamStderr: true)
        if result.succeeded { return }
        // Fallback alternate verb
        var altArgs = ["images", "pull"]
        if let platform, !platform.isEmpty {
            altArgs += ["--platform", platform]
        }
        altArgs.append(image)
        let alt = try invoke(altArgs, streamStderr: true)
        if alt.succeeded { return }
        throw mapFailure(result, action: "image pull \(image)")
    }

    /// Copy files between host and container (`container cp <source> <destination>`).
    /// Destination may be `containerId:/path` or a local path.
    ///
    /// Note: Apple `container cp` into a **named volume mount** is a silent no-op
    /// (exit 0, no files). Prefer ``copyTreeIntoContainer(hostDir:containerId:destPath:)``
    /// when the destination is on a volume mount.
    public func copy(from source: String, to destination: String) throws {
        let result = try invoke(["cp", source, destination], streamStderr: true)
        if result.succeeded { return }
        let alt = try invoke(["copy", source, destination], streamStderr: true)
        if alt.succeeded { return }
        throw mapFailure(result, action: "cp \(source) → \(destination)")
    }

    /// Copy a host directory tree into a path inside a running container via tar-pipe.
    ///
    /// Uses `(cd hostDir && tar cf - .) | container exec -i id tar xf - -C destPath`.
    /// This writes correctly into named volume mounts where `container cp` is a no-op.
    public func copyTreeIntoContainer(hostDir: String, containerId: String, destPath: String) throws {
        let mkdir = try exec(nameOrId: containerId, command: ["mkdir", "-p", destPath])
        if !mkdir.succeeded {
            throw mapFailure(mkdir, action: "mkdir -p \(destPath) in \(containerId)")
        }

        if runner is FoundationProcessRunner {
            try tarPipeIntoContainer(hostDir: hostDir, containerId: containerId, destPath: destPath)
        } else {
            // Mock / non-Foundation runners: record logical steps without a real pipe.
            let hostTar = try runner.run(
                executable: "/usr/bin/tar",
                arguments: ["cf", "-", "-C", hostDir, "."],
                environment: nil,
                currentDirectory: nil
            )
            if !hostTar.succeeded {
                throw CLIError(
                    code: CLIErrorCode.populateFailed,
                    message: "Host tar create failed (exit \(hostTar.exitCode))",
                    hint: "Ensure /usr/bin/tar is available"
                )
            }
            let extract = try runner.run(
                executable: executablePath,
                arguments: ["exec", "-i", containerId, "tar", "xf", "-", "-C", destPath],
                environment: nil,
                currentDirectory: nil
            )
            if !extract.succeeded {
                throw mapFailure(extract, action: "exec tar extract into \(destPath)")
            }
        }
    }

    /// True when `path` exists inside the container (`test -e`).
    public func pathExistsInContainer(containerId: String, path: String) throws -> Bool {
        let result = try exec(nameOrId: containerId, command: ["test", "-e", path])
        return result.succeeded
    }

    /// Stream host directory as tar into `container exec -i … tar xf - -C dest`.
    private func tarPipeIntoContainer(hostDir: String, containerId: String, destPath: String) throws {
        let pipe = Pipe()

        let tar = Process()
        tar.executableURL = URL(fileURLWithPath: "/usr/bin/tar")
        tar.arguments = ["cf", "-", "-C", hostDir, "."]
        tar.standardOutput = pipe
        let tarErr = Pipe()
        tar.standardError = tarErr
        tar.standardInput = FileHandle.nullDevice

        let extract = Process()
        extract.executableURL = URL(fileURLWithPath: executablePath)
        extract.arguments = ["exec", "-i", containerId, "tar", "xf", "-", "-C", destPath]
        extract.standardInput = pipe
        let extractOut = Pipe()
        let extractErr = Pipe()
        extract.standardOutput = extractOut
        extract.standardError = extractErr

        final class DataBox: @unchecked Sendable {
            var value = Data()
        }
        let tarErrBox = DataBox()
        let extractOutBox = DataBox()
        let extractErrBox = DataBox()
        let group = DispatchGroup()

        group.enter()
        DispatchQueue.global(qos: .userInitiated).async {
            tarErrBox.value = tarErr.fileHandleForReading.readDataToEndOfFile()
            group.leave()
        }
        group.enter()
        DispatchQueue.global(qos: .userInitiated).async {
            extractOutBox.value = extractOut.fileHandleForReading.readDataToEndOfFile()
            group.leave()
        }
        group.enter()
        DispatchQueue.global(qos: .userInitiated).async {
            extractErrBox.value = extractErr.fileHandleForReading.readDataToEndOfFile()
            group.leave()
        }

        do {
            // Start consumer first so it is ready when tar writes.
            try extract.run()
            try tar.run()
        } catch {
            throw CLIError(
                code: CLIErrorCode.populateFailed,
                message: "Failed to launch tar-pipe into container: \(error.localizedDescription)",
                hint: "Ensure /usr/bin/tar and Apple container CLI are available"
            )
        }

        tar.waitUntilExit()
        extract.waitUntilExit()
        group.wait()

        if tar.terminationStatus != 0 {
            let detail = String(data: tarErrBox.value, encoding: .utf8)?
                .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            throw CLIError(
                code: CLIErrorCode.populateFailed,
                message: "Host tar create failed (exit \(tar.terminationStatus))"
                    + (detail.isEmpty ? "" : ": \(detail)"),
                hint: "Ensure /usr/bin/tar can read the staging directory"
            )
        }
        if extract.terminationStatus != 0 {
            let err = String(data: extractErrBox.value, encoding: .utf8)?
                .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            let out = String(data: extractOutBox.value, encoding: .utf8)?
                .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            let detail = [err, out].filter { !$0.isEmpty }.joined(separator: " | ")
            throw CLIError(
                code: CLIErrorCode.populateFailed,
                message: "container exec tar extract failed (exit \(extract.terminationStatus))"
                    + (detail.isEmpty ? "" : ": \(detail)"),
                hint: "Ensure the container is running and tar exists in the image"
            )
        }
    }

    /// Build a local image via `container build` (Features derived image path).
    /// Always pass host-native `--platform` on arm64; never passes `--rosetta`.
    /// If the BuildKit builder was not running before the build, stops it again afterward
    /// (success or failure) so a side-effect start does not leave it running.
    public func build(
        contextDirectory: String,
        dockerfilePath: String,
        tag: String,
        platform: String? = ContainerPlatform.defaultLinuxPlatform
    ) throws {
        let wasRunning = isBuilderRunning()
        defer {
            if !wasRunning {
                try? builderStop()
            }
        }
        var args = ["build", "-f", dockerfilePath, "-t", tag]
        if let platform, !platform.isEmpty {
            args += ["--platform", platform]
        }
        args.append(contextDirectory)
        let result = try invoke(args, streamStderr: true)
        if result.succeeded { return }
        let err = mapFailure(result, action: "build -t \(tag)")
        throw CLIError(
            code: CLIErrorCode.featureBuild,
            property: "features",
            message: err.message,
            hint: "Inspect the generated Dockerfile and Apple container build logs; ensure build.rosetta=false for native arm64"
        )
    }

    /// True when a local image with the given reference/tag exists.
    public func imageExists(ref: String) throws -> Bool {
        // Prefer inspect when available.
        let inspect = try invoke(["image", "inspect", ref])
        if inspect.succeeded {
            return true
        }
        // Fallback: list and match reference.
        let list = try invoke(["image", "list", "--format", "json"])
        guard list.succeeded else {
            // Try alternate list form
            let alt = try invoke(["images", "list", "--format", "json"])
            guard alt.succeeded, let arr = try? parseJSONArray(alt.stdout) else {
                return false
            }
            return imageListContains(arr, ref: ref)
        }
        guard let arr = try? parseJSONArray(list.stdout) else { return false }
        return imageListContains(arr, ref: ref)
    }

    /// Inspect an image using the Apple CLI's machine-readable JSON response.
    ///
    /// Apple `container image inspect` emits JSON without accepting the Docker-style
    /// `--format` flag, so the command itself is kept minimal while the response is parsed
    /// strictly here. Recovery image preflight uses the returned digest/platform data rather
    /// than a tag-only existence check.
    public func inspectImage(ref: String) throws -> RuntimeImageInspection {
        let result = try invoke(["image", "inspect", ref])
        try ensureSuccess(result, action: "image inspect \(ref)")

        let object: [String: Any]
        if let arr = try? parseJSONArray(result.stdout, requireObjectEntries: true) {
            guard arr.count == 1, let first = arr.first else {
                throw CLIError(
                    code: CLIErrorCode.runtimeFailed,
                    message: "Image inspect array must contain exactly one object"
                )
            }
            object = first
        } else {
            object = try parseJSONObject(result.stdout)
        }
        return try parseImageInspection(object, requestedReference: ref)
    }

    /// Ensure an image is locally available and its machine-inspected platform matches the
    /// requested OCI platform. Pulling is explicit and never falls back to another platform.
    public func preflightImage(
        reference: String,
        platform: String,
        pullIfMissing: Bool = true
    ) throws -> RuntimeImageInspection {
        if let inspection = try? inspectImage(ref: reference) {
            guard inspection.hasPlatform(platform) else {
                throw CLIError(
                    code: CLIErrorCode.runtimeFailed,
                    message: "Image \(reference) is not available for \(platform)",
                    hint: "Use an image manifest that contains the requested native platform"
                )
            }
            return inspection
        }
        guard pullIfMissing else {
            throw CLIError(
                code: CLIErrorCode.runtimeFailed,
                message: "Image \(reference) is not available locally",
                hint: "Pull the image before the destructive operation"
            )
        }
        try pullImage(reference, platform: platform)
        let inspection = try inspectImage(ref: reference)
        guard inspection.hasPlatform(platform) else {
            throw CLIError(
                code: CLIErrorCode.runtimeFailed,
                message: "Image \(reference) is not available for \(platform)",
                hint: "Use an image manifest that contains the requested native platform"
            )
        }
        return inspection
    }

    /// Labels from a local image inspect (empty when unavailable).
    public func imageLabels(ref: String) throws -> [String: String] {
        let result = try invoke(["image", "inspect", ref])
        guard result.succeeded else { return [:] }
        if let arr = try? parseJSONArray(result.stdout), let first = arr.first {
            return extractImageLabels(first)
        }
        if let obj = try? parseJSONObject(result.stdout) {
            return extractImageLabels(obj)
        }
        return [:]
    }

    private func imageListContains(_ arr: [[String: Any]], ref: String) -> Bool {
        for item in arr {
            if imageItemMatches(item, ref: ref) { return true }
        }
        return false
    }

    private func imageItemMatches(_ item: [String: Any], ref: String) -> Bool {
        if let reference = item["reference"] as? String, reference == ref { return true }
        if let id = item["id"] as? String, id == ref { return true }
        if let tags = item["tags"] as? [String], tags.contains(ref) { return true }
        if let names = item["names"] as? [String], names.contains(ref) { return true }
        if let cfg = item["configuration"] as? [String: Any] {
            if let reference = cfg["reference"] as? String, reference == ref { return true }
            if let img = cfg["image"] as? [String: Any],
               let reference = img["reference"] as? String, reference == ref {
                return true
            }
        }
        // Match repository:tag parts
        if let repo = item["repository"] as? String, let tag = item["tag"] as? String {
            if "\(repo):\(tag)" == ref { return true }
        }
        return false
    }

    private func extractImageLabels(_ obj: [String: Any]) -> [String: String] {
        func asStringMap(_ value: Any?) -> [String: String]? {
            if let labels = value as? [String: String] { return labels }
            if let labels = value as? [String: Any] {
                let mapped = labels.compactMapValues { $0 as? String }
                return mapped.isEmpty ? nil : mapped
            }
            return nil
        }

        if let labels = asStringMap(obj["labels"]) ?? asStringMap(obj["Labels"]) {
            return labels
        }
        if let cfg = obj["configuration"] as? [String: Any],
           let labels = asStringMap(cfg["labels"]) ?? asStringMap(cfg["Labels"]) {
            return labels
        }
        if let config = obj["Config"] as? [String: Any],
           let labels = asStringMap(config["Labels"]) ?? asStringMap(config["labels"]) {
            return labels
        }
        // Apple `container image inspect`: variants[].config.config.Labels
        if let variants = obj["variants"] as? [[String: Any]] {
            for variant in variants {
                if let outer = variant["config"] as? [String: Any] {
                    if let inner = outer["config"] as? [String: Any],
                       let labels = asStringMap(inner["Labels"]) ?? asStringMap(inner["labels"]) {
                        return labels
                    }
                    if let labels = asStringMap(outer["Labels"]) ?? asStringMap(outer["labels"]) {
                        return labels
                    }
                }
            }
        }
        return [:]
    }

    public func ensureVolume(name: String) throws {
        if try volumeExists(name) {
            StatusPrinter.status("Reusing existing volume", item: name)
            return
        }
        let result = try invoke(["volume", "create", name], streamStderr: true)
        if result.succeeded { return }
        // Belt and suspenders: treat race / already-exists create failure as reuse.
        let combined = (result.stdoutString + result.stderrString).lowercased()
        if combined.contains("already") || combined.contains("exists") {
            StatusPrinter.status("Reusing existing volume", item: name)
            return
        }
        throw mapFailure(result, action: "volume create \(name)")
    }

    public func volumeExists(_ name: String, requireObjectEntries: Bool = false) throws -> Bool {
        let list = try invoke(["volume", "list", "--format", "json"])
        guard list.succeeded else { return false }
        guard let arr = try? parseJSONArray(list.stdout, requireObjectEntries: requireObjectEntries) else {
            return false
        }
        for item in arr {
            if let id = item["id"] as? String, id == name { return true }
            if let n = item["name"] as? String, n == name { return true }
            if let cfg = item["configuration"] as? [String: Any],
               let n = cfg["name"] as? String, n == name { return true }
        }
        return false
    }

    public func deleteVolume(name: String) throws {
        let result = try invoke(["volume", "delete", name], streamStderr: false)
        try ensureSuccess(result, action: "volume delete \(name)")
    }

    public func deleteImage(reference: String) throws {
        let result = try invoke(["image", "delete", reference], streamStderr: false)
        if result.succeeded { return }
        // Some versions use `image rm`
        let alt = try invoke(["image", "rm", reference], streamStderr: false)
        if alt.succeeded { return }
        throw mapFailure(result, action: "image delete \(reference)")
    }

    public func create(request: CreateRequest, ensureVolumes: Bool = true) throws -> String {
        // Ensure workspace named volume (clone / volume-mode)
        if ensureVolumes, request.workspaceMountMode == .volume {
            try ensureVolume(name: request.workspaceBindHost)
        }
        // Ensure named volumes from config mounts
        if ensureVolumes {
            for mount in request.mounts where mount.type == .volume {
                try ensureVolume(name: mount.source)
            }
        }

        let args = request.createArguments()
        let result = try invoke(args, streamStderr: true)
        try ensureSuccess(result, action: "create")
        let id = result.stdoutString.trimmingCharacters(in: .whitespacesAndNewlines)
        return id.isEmpty ? request.name : id
    }

    public func start(nameOrId: String) throws {
        let result = try invoke(["start", nameOrId], streamStderr: true)
        try ensureSuccess(result, action: "start \(nameOrId)")
    }

    public func stop(nameOrId: String) throws {
        let result = try invoke(["stop", nameOrId], streamStderr: true)
        try ensureSuccess(result, action: "stop \(nameOrId)")
    }

    public func delete(nameOrId: String, force: Bool = true) throws {
        var args = ["delete"]
        if force { args.append("--force") }
        args.append(nameOrId)
        let result = try invoke(args, streamStderr: true)
        try ensureSuccess(result, action: "delete \(nameOrId)")
    }

    public func exec(
        nameOrId: String,
        command: [String],
        user: String? = nil,
        workdir: String? = nil,
        env: [String: String] = [:],
        interactive: Bool = false,
        stdinData: Data? = nil,
        streamOutput: Bool = false
    ) throws -> ProcessResult {
        var args = ["exec"]
        if let user, !user.isEmpty {
            args += ["-u", user]
        }
        if let workdir, !workdir.isEmpty {
            args += ["-w", workdir]
        }
        // Same as create: Apple container does not expand ${PATH}/$PATH in -e values.
        // Feature containerEnv (e.g. node) sets PATH=…:${PATH}; without expansion,
        // lifecycle exec (sh -lc) cannot find id/bash under a broken PATH.
        let expandedEnv = CreateRequest.expandEnvPathRefs(env)
        for (k, v) in expandedEnv.sorted(by: { $0.key < $1.key }) {
            args += ["-e", "\(k)=\(v)"]
        }
        if interactive {
            args += ["-i", "-t"]
        } else if stdinData != nil {
            // A non-TTY stdin stream still requires `-i`; never allocate a pseudo-TTY for
            // exact byte transfer.
            args.append("-i")
        }
        args.append(nameOrId)
        args.append(contentsOf: command)

        let selected = interactive ? interactiveRunner : runner
        // Lifecycle hooks: tee child stdout+stderr to host stderr while capturing both so
        // long-running scripts are visible and `--json` host stdout stays pure.
        if streamOutput, !interactive, let streaming = selected as? any StreamTeeingProcessRunning {
            return try streaming.run(
                executable: executablePath,
                arguments: args,
                environment: nil,
                currentDirectory: nil,
                stdinData: stdinData,
                streamStderr: true,
                teeStdoutToStderr: true
            )
        }
        return try selected.run(
            executable: executablePath,
            arguments: args,
            environment: nil,
            currentDirectory: nil,
            stdinData: stdinData
        )
    }

    /// Read a regular file through the helper's exec/stdout boundary. This is deliberately
    /// separate from `copy`: Apple `container cp` is not reliable for named-volume mounts.
    public func readFile(nameOrId: String, path: String) throws -> Data {
        let result = try exec(nameOrId: nameOrId, command: ["cat", path])
        guard result.succeeded else {
            throw mapFailure(result, action: "read file in \(nameOrId)")
        }
        return result.stdout
    }

    /// Hash a file after reading it through the same safe exec boundary.
    public func readFileSHA256(nameOrId: String, path: String) throws -> String {
        Self.sha256Hex(try readFile(nameOrId: nameOrId, path: path))
    }

    /// Stream exact bytes to a same-directory temporary file in the helper and atomically
    /// replace `path`. The path and hashes are argv values, never shell-interpolated. Exit 42
    /// is reserved by the helper script for an optimistic-concurrency conflict.
    public func atomicWriteFile(
        nameOrId: String,
        path: String,
        bytes: Data,
        expectedCurrentHash: String,
        expectedBytesHash: String
    ) throws -> SafeFileWriteResult {
        let command = [
            "sh", "-ceu", Self.atomicWriteScript,
            "adevcontainer-recovery-write", path, expectedCurrentHash, expectedBytesHash,
            "\(bytes.count)"
        ]
        let result = try exec(
            nameOrId: nameOrId,
            command: command,
            stdinData: bytes
        )
        if result.exitCode == 42 {
            let current = Self.parseRecoveryHash(result.stderr)
                ?? Self.parseRecoveryHash(result.stdout)
                ?? ""
            return .conflict(currentHash: current)
        }
        guard result.succeeded else {
            throw mapFailure(result, action: "atomically write recovery config in \(nameOrId)")
        }
        let applied = Self.parseRecoveryHash(result.stdout)
            ?? Self.parseRecoveryHash(result.stderr)
            ?? expectedBytesHash
        return .applied(hash: applied)
    }

    /// Machine-JSON mount inspection for one container.
    public func inspectMounts(nameOrId: String) throws -> [ContainerMountInfo] {
        let result = try invoke(["inspect", nameOrId])
        try ensureSuccess(result, action: "inspect mounts \(nameOrId)")
        let object = try parseSingleContainerObject(result.stdout)
        return try parseMounts(from: object)
    }

    /// Verify one exact named-volume attachment. The logical volume name comes from Apple's
    /// nested `type.volume.name` field; the backing `source` path is intentionally ignored.
    public func verifyVolumeAttachment(
        nameOrId: String,
        volumeName: String,
        targetPath: String,
        readOnly: Bool = false
    ) throws {
        let mounts = try inspectMounts(nameOrId: nameOrId)
        let volumeMounts = mounts.filter { $0.type == .volume }
        guard mounts.count == 1,
              volumeMounts.count == 1,
              let mount = volumeMounts.first,
              mount.logicalVolumeName == volumeName,
              mount.destination == targetPath,
              mount.readOnly == readOnly
        else {
            throw CLIError(
                code: CLIErrorCode.recoveryUnavailable,
                message: "Recovery helper volume attachment could not be verified",
                hint: "The helper must mount only the existing workspace volume read-write at the stamped workspace path"
            )
        }
    }

    /// Return managed/runtime containers currently attached to a named volume. The list call
    /// is machine JSON and includes mounts on Apple container 1.x.
    public func containersAttached(to volumeName: String) throws -> [ContainerInfo] {
        let result = try invoke(["list", "--all", "--format", "json"])
        try ensureSuccess(result, action: "list container attachments")
        let arr = try parseJSONArray(result.stdout, requireObjectEntries: true)
        var attached: [ContainerInfo] = []
        attached.reserveCapacity(arr.count)
        for object in arr {
            guard let info = parseContainerInfo(object) else {
                throw mountSchemaError("container attachment entry has no id")
            }
            let mounts = try parseMounts(from: object)
            if mounts.contains(where: {
                $0.type == .volume && $0.logicalVolumeName == volumeName
            }) {
                attached.append(info)
            }
        }
        return attached
    }

    public func isVolumeAttached(
        volumeName: String,
        excludingContainerID: String? = nil
    ) throws -> Bool {
        try containersAttached(to: volumeName).contains { info in
            guard let excludingContainerID else { return true }
            return info.id != excludingContainerID
        }
    }

    /// Fail closed when the exact workspace volume still has any attached container.
    public func verifyVolumeDetached(
        volumeName: String,
        excludingContainerID: String? = nil
    ) throws {
        let attached = try containersAttached(to: volumeName).filter { info in
            guard let excludingContainerID else { return true }
            return info.id != excludingContainerID
        }
        guard attached.isEmpty else {
            throw CLIError(
                code: CLIErrorCode.recoveryUnavailable,
                message: "Workspace volume remains attached to a container",
                hint: "Stop and remove the failed container before starting recovery"
            )
        }
    }

    public func listAll() throws -> [ContainerInfo] {
        let result = try invoke(["list", "--all", "--format", "json"])
        try ensureSuccess(result, action: "list")
        let arr = try parseJSONArray(result.stdout, requireObjectEntries: true)
        return try arr.map { object in
            guard let info = parseContainerInfo(object) else {
                throw CLIError(
                    code: CLIErrorCode.runtimeFailed,
                    message: "Container list entry is missing an id"
                )
            }
            return info
        }
    }

    public func inspect(nameOrId: String) throws -> ContainerInfo {
        let result = try invoke(["inspect", nameOrId])
        try ensureSuccess(result, action: "inspect \(nameOrId)")
        let object = try parseSingleContainerObject(result.stdout)
        if let info = parseContainerInfo(object) {
            return info
        }
        throw CLIError(
            code: CLIErrorCode.runtimeFailed,
            message: "Unexpected inspect JSON for \(nameOrId)"
        )
    }

    public func findByName(_ name: String) throws -> ContainerInfo? {
        let all = try listAll()
        return all.first { $0.id == name || $0.name == name }
    }

    // MARK: - Internals

    private static let atomicWriteScript = #"""
set -eu
target="$1"
expected_current="$2"
expected_bytes="$3"
expected_length="$4"
dir=$(dirname -- "$target")
hash_file() {
  sha256sum -- "$1" | cut -d ' ' -f 1
}
current=$(hash_file "$target")
if [ "$current" != "$expected_current" ]; then
  printf 'RECOVERY_CONFLICT:%s\n' "$current" >&2
  exit 42
fi
# Private temp while streaming bytes; final in-volume config must remain readable by
# the workspace remoteUser (final-container verification and normal volume cat use
# non-root). umask 077 only protects the transient temp file.
umask 077
tmp=$(mktemp "$dir/.adevcontainer-recovery.XXXXXX")
cleanup() {
  rm -f -- "$tmp"
}
trap cleanup EXIT
chmod 600 "$tmp"
cat > "$tmp"
actual_length=$(wc -c < "$tmp" | tr -d '[:space:]')
if [ "$actual_length" != "$expected_length" ]; then
  printf 'RECOVERY_LENGTH_MISMATCH:%s\n' "$actual_length" >&2
  exit 43
fi
actual=$(hash_file "$tmp")
if [ "$actual" != "$expected_bytes" ]; then
  printf 'RECOVERY_STREAM_MISMATCH:%s\n' "$actual" >&2
  exit 43
fi
mv -f -- "$tmp" "$target"
trap - EXIT
# Match ordinary workspace file readability (owner rw, group/other r).
chmod 644 -- "$target"
actual=$(hash_file "$target")
printf 'RECOVERY_APPLIED:%s\n' "$actual"
"""#

    private static func sha256Hex(_ data: Data) -> String {
        SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }

    private static func parseRecoveryHash(_ data: Data) -> String? {
        guard let text = String(data: data, encoding: .utf8) else { return nil }
        for line in text.split(whereSeparator: \.isNewline) {
            let value = String(line)
            if let range = value.range(of: "RECOVERY_CONFLICT:") {
                let hash = String(value[range.upperBound...]).trimmingCharacters(in: .whitespacesAndNewlines)
                if hash.count == 64 { return hash }
            }
            if let range = value.range(of: "RECOVERY_APPLIED:") {
                let hash = String(value[range.upperBound...]).trimmingCharacters(in: .whitespacesAndNewlines)
                if hash.count == 64 { return hash }
            }
        }
        return nil
    }

    private func parseImageInspection(
        _ object: [String: Any],
        requestedReference: String
    ) throws -> RuntimeImageInspection {
        var digests: [String] = []
        var platforms: [RuntimeImagePlatform] = []

        func addDigest(_ value: String?) {
            guard let value, !value.isEmpty, !digests.contains(value) else { return }
            digests.append(value)
        }

        func parsePlatform(_ object: [String: Any]?, digest: String? = nil) {
            guard let object,
                  let os = object["os"] as? String,
                  let architecture = (object["architecture"] as? String)
                      ?? (object["arch"] as? String)
            else { return }
            let value = RuntimeImagePlatform(
                os: os,
                architecture: architecture,
                variant: object["variant"] as? String,
                digest: digest
            )
            if !platforms.contains(value) { platforms.append(value) }
            addDigest(digest)
        }

        if let id = object["id"] as? String, id.hasPrefix("sha256:") {
            addDigest(id)
        }
        if let digest = object["digest"] as? String {
            addDigest(digest)
        }
        if let configuration = object["configuration"] as? [String: Any] {
            if let name = configuration["name"] as? String, !name.isEmpty {
                _ = name
            }
            if let descriptor = configuration["descriptor"] as? [String: Any] {
                addDigest(descriptor["digest"] as? String)
            }
            parsePlatform(configuration["platform"] as? [String: Any])
            if let variants = configuration["variants"] as? [[String: Any]] {
                for variant in variants {
                    parsePlatform(
                        variant["platform"] as? [String: Any] ?? variant,
                        digest: variant["digest"] as? String
                    )
                }
            }
        }
        parsePlatform(object["platform"] as? [String: Any])
        if let variants = object["variants"] as? [[String: Any]] {
            for variant in variants {
                parsePlatform(
                    variant["platform"] as? [String: Any] ?? variant,
                    digest: variant["digest"] as? String
                )
            }
        }

        guard !platforms.isEmpty || !digests.isEmpty else {
            throw CLIError(
                code: CLIErrorCode.runtimeFailed,
                message: "Unexpected image inspect JSON for \(requestedReference)"
            )
        }
        let reference = (object["reference"] as? String)
            ?? ((object["configuration"] as? [String: Any])?["name"] as? String)
            ?? requestedReference
        let user = Self.extractOCIUser(from: object)
        return RuntimeImageInspection(
            reference: reference,
            digests: digests,
            platforms: platforms,
            user: user
        )
    }

    /// Pull OCI `USER` from Apple / Docker-shaped image inspect payloads.
    /// Returns nil when absent or whitespace-only — never fabricates `"root"`.
    static func extractOCIUser(from object: [String: Any]) -> String? {
        func trimmedUser(_ value: Any?) -> String? {
            guard let s = value as? String else { return nil }
            let t = s.trimmingCharacters(in: .whitespacesAndNewlines)
            return t.isEmpty ? nil : t
        }

        // Apple `container image inspect`: variants[].config.config.User
        if let variants = object["variants"] as? [[String: Any]] {
            for variant in variants {
                if let outer = variant["config"] as? [String: Any] {
                    if let inner = outer["config"] as? [String: Any],
                       let user = trimmedUser(inner["User"] ?? inner["user"]) {
                        return user
                    }
                    if let user = trimmedUser(outer["User"] ?? outer["user"]) {
                        return user
                    }
                }
                if let user = trimmedUser(variant["User"] ?? variant["user"]) {
                    return user
                }
            }
        }

        // Docker-style Config.User
        if let config = object["Config"] as? [String: Any],
           let user = trimmedUser(config["User"] ?? config["user"]) {
            return user
        }
        // Nested configuration.user / configuration.User
        if let configuration = object["configuration"] as? [String: Any] {
            if let user = trimmedUser(configuration["User"] ?? configuration["user"]) {
                return user
            }
            if let config = configuration["config"] as? [String: Any],
               let user = trimmedUser(config["User"] ?? config["user"]) {
                return user
            }
        }
        // Top-level
        if let user = trimmedUser(object["User"] ?? object["user"]) {
            return user
        }
        return nil
    }

    private func parseMounts(from object: [String: Any]) throws -> [ContainerMountInfo] {
        let configuration = object["configuration"] as? [String: Any] ?? object
        guard let rawMounts = configuration["mounts"] else {
            throw mountSchemaError("container mounts metadata is missing")
        }
        guard let rawMounts = rawMounts as? [Any] else {
            throw mountSchemaError("container mounts is not an array")
        }
        var mounts: [ContainerMountInfo] = []
        mounts.reserveCapacity(rawMounts.count)
        for rawValue in rawMounts {
            guard let raw = rawValue as? [String: Any] else {
                throw mountSchemaError("container mount entry is not an object")
            }
            guard let destination = raw["destination"] as? String, !destination.isEmpty else {
                throw mountSchemaError("container mount has no destination")
            }
            let options: [String]
            if let rawOptions = raw["options"] {
                guard let parsedOptions = rawOptions as? [Any],
                      parsedOptions.allSatisfy({ $0 is String })
                else {
                    throw mountSchemaError("container mount options are malformed")
                }
                options = parsedOptions.compactMap { $0 as? String }
            } else {
                options = []
            }

            let parsedType = try parseMountType(raw["type"])
            let source: String
            if let rawSource = raw["source"] {
                guard let parsedSource = rawSource as? String else {
                    throw mountSchemaError("container mount source is malformed")
                }
                source = parsedSource
            } else if parsedType.type == .tmpfs {
                source = ""
            } else {
                throw mountSchemaError("container mount source is missing")
            }
            let readOnly: Bool
            if let explicit = raw["readOnly"] {
                guard let parsed = explicit as? Bool else {
                    throw mountSchemaError("container mount readOnly is malformed")
                }
                readOnly = parsed
            } else {
                readOnly = options.contains { option in
                    let lower = option.lowercased()
                    return lower == "ro" || lower == "readonly"
                }
            }
            mounts.append(ContainerMountInfo(
                type: parsedType.type,
                source: source,
                destination: destination,
                readOnly: readOnly,
                logicalVolumeName: parsedType.logicalVolumeName
            ))
        }
        return mounts
    }

    private func parseMountType(_ raw: Any?) throws -> (
        type: ContainerMountType,
        logicalVolumeName: String?
    ) {
        guard let object = raw as? [String: Any], object.count == 1,
              let key = object.keys.first
        else {
            throw mountSchemaError("container mount type is malformed")
        }
        switch key.lowercased() {
        case "volume":
            guard let details = object[key] as? [String: Any],
                  let name = details["name"] as? String,
                  !name.isEmpty
            else {
                throw mountSchemaError("container volume mount has no logical name")
            }
            return (.volume, name)
        case "bind":
            guard object[key] is [String: Any] else {
                throw mountSchemaError("container bind mount details are malformed")
            }
            return (.bind, nil)
        case "virtiofs":
            guard object[key] is [String: Any] else {
                throw mountSchemaError("container virtiofs mount details are malformed")
            }
            return (.virtiofs, nil)
        case "tmpfs":
            guard object[key] is [String: Any] else {
                throw mountSchemaError("container tmpfs mount details are malformed")
            }
            return (.tmpfs, nil)
        default:
            throw mountSchemaError("container mount type is unknown")
        }
    }

    private func mountSchemaError(_ detail: String) -> CLIError {
        CLIError(
            code: CLIErrorCode.recoveryUnavailable,
            message: "Unable to verify container mount schema: \(detail)",
            hint: "Recovery requires machine-readable Apple container mount metadata"
        )
    }

    @discardableResult
    public func invoke(_ arguments: [String], streamStderr: Bool = false) throws -> ProcessResult {
        if streamStderr, let streaming = runner as? any StreamTeeingProcessRunning {
            return try streaming.run(
                executable: executablePath,
                arguments: arguments,
                environment: nil,
                currentDirectory: nil,
                stdinData: nil,
                streamStderr: true,
                teeStdoutToStderr: false
            )
        }
        return try runner.run(
            executable: executablePath,
            arguments: arguments,
            environment: nil,
            currentDirectory: nil
        )
    }

    private func ensureSuccess(_ result: ProcessResult, action: String) throws {
        if result.succeeded { return }
        throw mapFailure(result, action: action)
    }

    private func mapFailure(_ result: ProcessResult, action: String) -> CLIError {
        let err = result.stderrString.trimmingCharacters(in: .whitespacesAndNewlines)
        let out = result.stdoutString.trimmingCharacters(in: .whitespacesAndNewlines)
        let detail = [err, out].filter { !$0.isEmpty }.joined(separator: " | ")
        return CLIError(
            code: CLIErrorCode.runtimeFailed,
            message: "container \(action) failed (exit \(result.exitCode))"
                + (detail.isEmpty ? "" : ": \(detail)"),
            hint: "Run 'adevcontainer doctor' and check Apple container system status"
        )
    }

    private func parseSingleContainerObject(_ data: Data) throws -> [String: Any] {
        let obj: Any
        do {
            obj = try JSONSerialization.jsonObject(with: data, options: [.fragmentsAllowed])
        } catch {
            throw mountSchemaError("container inspect JSON is malformed")
        }
        if let dict = obj as? [String: Any] {
            return dict
        }
        if let arr = obj as? [Any] {
            guard arr.count == 1,
                   arr.allSatisfy({ $0 is [String: Any] }),
                   let first = arr.first as? [String: Any]
            else {
                throw mountSchemaError("container inspect array must contain exactly one object")
            }
            return first
        }
        throw mountSchemaError("container inspect JSON is neither an object nor an array")
    }

    private func parseJSONArray(
        _ data: Data,
        requireObjectEntries: Bool = false
    ) throws -> [[String: Any]] {
        if data.isEmpty { return [] }
        let obj: Any
        do {
            obj = try JSONSerialization.jsonObject(with: data, options: [.fragmentsAllowed])
        } catch {
            throw CLIError(
                code: CLIErrorCode.runtimeFailed,
                message: "Failed to parse container JSON: \(error.localizedDescription)"
            )
        }
        if let arr = obj as? [[String: Any]] { return arr }
        if let arr = obj as? [Any] {
            if requireObjectEntries, !arr.allSatisfy({ $0 is [String: Any] }) {
                throw mountSchemaError("JSON array contains a non-object entry")
            }
            return arr.compactMap { $0 as? [String: Any] }
        }
        throw CLIError(code: CLIErrorCode.runtimeFailed, message: "Expected JSON array from container CLI")
    }

    private func parseJSONObject(_ data: Data) throws -> [String: Any] {
        let obj: Any
        do {
            obj = try JSONSerialization.jsonObject(with: data, options: [.fragmentsAllowed])
        } catch {
            throw CLIError(
                code: CLIErrorCode.runtimeFailed,
                message: "Failed to parse container JSON: \(error.localizedDescription)"
            )
        }
        if let dict = obj as? [String: Any] { return dict }
        throw CLIError(code: CLIErrorCode.runtimeFailed, message: "Expected JSON object from container CLI")
    }

    private func parseContainerInfo(_ obj: [String: Any]) -> ContainerInfo? {
        let id = (obj["id"] as? String)
            ?? ((obj["configuration"] as? [String: Any])?["id"] as? String)
        guard let id else { return nil }

        let configuration = obj["configuration"] as? [String: Any] ?? [:]
        let status = obj["status"] as? [String: Any] ?? [:]
        let state = (status["state"] as? String) ?? "unknown"
        let labels = (configuration["labels"] as? [String: String])
            ?? (configuration["labels"] as? [String: Any])?.compactMapValues { $0 as? String }
            ?? [:]
        var image: String?
        if let imageObj = configuration["image"] as? [String: Any] {
            image = imageObj["reference"] as? String ?? imageObj["id"] as? String
        }
        if image == nil {
            image = configuration["image"] as? String ?? obj["image"] as? String
        }
        if let trimmed = image?.trimmingCharacters(in: .whitespacesAndNewlines), trimmed.isEmpty {
            image = nil
        }
        return ContainerInfo(
            id: id,
            name: id,
            state: state,
            labels: labels,
            image: image
        )
    }
}
