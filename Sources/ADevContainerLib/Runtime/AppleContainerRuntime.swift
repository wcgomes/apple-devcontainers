import Foundation

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
        if let labels = obj["labels"] as? [String: String] {
            return labels
        }
        if let labels = obj["Labels"] as? [String: String] {
            return labels
        }
        if let labels = obj["labels"] as? [String: Any] {
            return labels.compactMapValues { $0 as? String }
        }
        if let cfg = obj["configuration"] as? [String: Any] {
            if let labels = cfg["labels"] as? [String: String] {
                return labels
            }
            if let labels = cfg["labels"] as? [String: Any] {
                return labels.compactMapValues { $0 as? String }
            }
        }
        if let config = obj["Config"] as? [String: Any],
           let labels = config["Labels"] as? [String: String] {
            return labels
        }
        return [:]
    }

    public func ensureVolume(name: String) throws {
        if try volumeExists(name) {
            StatusPrinter.status("Volume '\(name)' already exists — reusing")
            return
        }
        let result = try invoke(["volume", "create", name], streamStderr: true)
        if result.succeeded { return }
        // Belt and suspenders: treat race / already-exists create failure as reuse.
        let combined = (result.stdoutString + result.stderrString).lowercased()
        if combined.contains("already") || combined.contains("exists") {
            StatusPrinter.status("Volume '\(name)' already exists — reusing")
            return
        }
        throw mapFailure(result, action: "volume create \(name)")
    }

    public func volumeExists(_ name: String) throws -> Bool {
        let list = try invoke(["volume", "list", "--format", "json"])
        guard list.succeeded else { return false }
        guard let arr = try? parseJSONArray(list.stdout) else { return false }
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

    public func create(request: CreateRequest) throws -> String {
        // Ensure workspace named volume (clone / volume-mode)
        if request.workspaceMountMode == .volume {
            try ensureVolume(name: request.workspaceBindHost)
        }
        // Ensure named volumes from config mounts
        for mount in request.mounts where mount.type == .volume {
            try ensureVolume(name: mount.source)
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
        interactive: Bool = false
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
        }
        args.append(nameOrId)
        args.append(contentsOf: command)

        let selected = interactive ? interactiveRunner : runner
        return try selected.run(
            executable: executablePath,
            arguments: args,
            environment: nil,
            currentDirectory: nil
        )
    }

    public func listAll() throws -> [ContainerInfo] {
        let result = try invoke(["list", "--all", "--format", "json"])
        try ensureSuccess(result, action: "list")
        let arr = try parseJSONArray(result.stdout)
        return arr.compactMap { parseContainerInfo($0) }
    }

    public func inspect(nameOrId: String) throws -> ContainerInfo {
        let result = try invoke(["inspect", nameOrId])
        try ensureSuccess(result, action: "inspect \(nameOrId)")
        // inspect returns array
        if let arr = try? parseJSONArray(result.stdout), let first = arr.first,
           let info = parseContainerInfo(first) {
            return info
        }
        if let obj = try? parseJSONObject(result.stdout), let info = parseContainerInfo(obj) {
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

    @discardableResult
    public func invoke(_ arguments: [String], streamStderr: Bool = false) throws -> ProcessResult {
        if streamStderr, let foundation = runner as? FoundationProcessRunner {
            return try foundation.run(
                executable: executablePath,
                arguments: arguments,
                environment: nil,
                currentDirectory: nil,
                streamStderr: true
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

    private func parseJSONArray(_ data: Data) throws -> [[String: Any]] {
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
            image = imageObj["reference"] as? String
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
