import Foundation

public struct ProcessResult: Equatable, Sendable {
    public var exitCode: Int32
    public var stdout: Data
    public var stderr: Data

    public init(exitCode: Int32, stdout: Data, stderr: Data) {
        self.exitCode = exitCode
        self.stdout = stdout
        self.stderr = stderr
    }

    public var stdoutString: String {
        String(data: stdout, encoding: .utf8) ?? ""
    }

    public var stderrString: String {
        String(data: stderr, encoding: .utf8) ?? ""
    }

    public var succeeded: Bool { exitCode == 0 }
}

public protocol ProcessRunning: Sendable {
    func run(
        executable: String,
        arguments: [String],
        environment: [String: String]?,
        currentDirectory: String?
    ) throws -> ProcessResult
}

public struct FoundationProcessRunner: ProcessRunning {
    public init() {}

    public func run(
        executable: String,
        arguments: [String],
        environment: [String: String]?,
        currentDirectory: String?
    ) throws -> ProcessResult {
        try run(
            executable: executable,
            arguments: arguments,
            environment: environment,
            currentDirectory: currentDirectory,
            streamStderr: false
        )
    }

    /// When `streamStderr` is true, tee child stderr to the host while still capturing it.
    public func run(
        executable: String,
        arguments: [String],
        environment: [String: String]?,
        currentDirectory: String?,
        streamStderr: Bool
    ) throws -> ProcessResult {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: executable)
        process.arguments = arguments

        var env = ProcessInfo.processInfo.environment
        if let environment {
            for (k, v) in environment {
                env[k] = v
            }
        }
        process.environment = env

        if let currentDirectory {
            process.currentDirectoryURL = URL(fileURLWithPath: currentDirectory)
        }

        let outPipe = Pipe()
        let errPipe = Pipe()
        process.standardOutput = outPipe
        process.standardError = errPipe
        process.standardInput = FileHandle.nullDevice

        // Drain pipes while the process runs to avoid pipe-buffer deadlock.
        final class DataBox: @unchecked Sendable {
            var value = Data()
        }
        let stdoutBox = DataBox()
        let stderrBox = DataBox()
        let group = DispatchGroup()

        group.enter()
        DispatchQueue.global(qos: .userInitiated).async {
            stdoutBox.value = outPipe.fileHandleForReading.readDataToEndOfFile()
            group.leave()
        }
        group.enter()
        DispatchQueue.global(qos: .userInitiated).async {
            let handle = errPipe.fileHandleForReading
            if streamStderr {
                var accumulated = Data()
                while true {
                    let chunk = handle.availableData
                    if chunk.isEmpty { break }
                    accumulated.append(chunk)
                    try? FileHandle.standardError.write(contentsOf: chunk)
                }
                stderrBox.value = accumulated
            } else {
                stderrBox.value = handle.readDataToEndOfFile()
            }
            group.leave()
        }

        do {
            try process.run()
        } catch {
            throw CLIError(
                code: CLIErrorCode.runtimeFailed,
                message: "Failed to launch \(executable): \(error.localizedDescription)",
                hint: "Ensure the binary exists and is executable"
            )
        }

        process.waitUntilExit()
        group.wait()
        return ProcessResult(
            exitCode: process.terminationStatus,
            stdout: stdoutBox.value,
            stderr: stderrBox.value
        )
    }
}

/// Process runner that inherits stdio for interactive `exec` sessions.
public struct InteractiveProcessRunner: ProcessRunning {
    public init() {}

    public func run(
        executable: String,
        arguments: [String],
        environment: [String: String]?,
        currentDirectory: String?
    ) throws -> ProcessResult {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: executable)
        process.arguments = arguments

        var env = ProcessInfo.processInfo.environment
        if let environment {
            for (k, v) in environment {
                env[k] = v
            }
        }
        process.environment = env

        if let currentDirectory {
            process.currentDirectoryURL = URL(fileURLWithPath: currentDirectory)
        }

        process.standardInput = FileHandle.standardInput
        process.standardOutput = FileHandle.standardOutput
        process.standardError = FileHandle.standardError

        do {
            try process.run()
        } catch {
            throw CLIError(
                code: CLIErrorCode.runtimeFailed,
                message: "Failed to launch \(executable): \(error.localizedDescription)",
                hint: "Ensure the binary exists and is executable"
            )
        }

        process.waitUntilExit()
        return ProcessResult(exitCode: process.terminationStatus, stdout: Data(), stderr: Data())
    }
}
