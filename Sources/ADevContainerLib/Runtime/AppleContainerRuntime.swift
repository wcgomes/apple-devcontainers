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

    // MARK: - Lifecycle

    public func pullImage(_ image: String) throws {
        let result = try invoke(["image", "pull", image], streamStderr: true)
        // Some versions use `container image pull`
        if result.succeeded { return }
        // Fallback: pull via create will fetch; surface error if explicit pull fails hard
        let alt = try invoke(["images", "pull", image], streamStderr: true)
        if alt.succeeded { return }
        throw mapFailure(result, action: "image pull \(image)")
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
        // Ensure named volumes exist
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
        for (k, v) in env.sorted(by: { $0.key < $1.key }) {
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
