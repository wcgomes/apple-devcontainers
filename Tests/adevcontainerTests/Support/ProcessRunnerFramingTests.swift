import Foundation
#if canImport(Darwin)
import Darwin
#endif
@testable import ADevContainerLib

/// Capture host stderr (fd 2) around a body — used for FoundationProcessRunner tee framing.
private func captureStderrFD(_ body: () throws -> Void) throws -> String {
    let saved = dup(STDERR_FILENO)
    let pipe = Pipe()
    dup2(pipe.fileHandleForWriting.fileDescriptor, STDERR_FILENO)
    pipe.fileHandleForWriting.closeFile()
    do {
        try body()
        fflush(nil)
        dup2(saved, STDERR_FILENO)
        close(saved)
        return String(data: pipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
    } catch {
        fflush(nil)
        dup2(saved, STDERR_FILENO)
        close(saved)
        _ = pipe.fileHandleForReading.readDataToEndOfFile()
        throw error
    }
}

private final class ProcessResultBox: @unchecked Sendable {
    var value: ProcessResult?
}

nonisolated(unsafe) let processRunnerFramingTests: [(String, () throws -> Void)] = [
    ("processRunnerFramesStreamedLinesIndentPipe", {
        let previousColor = TerminalStyle.colorOverride
        TerminalStyle.colorOverride = false
        defer { TerminalStyle.colorOverride = previousColor }

        let runner = FoundationProcessRunner()
        let box = ProcessResultBox()
        let display = try captureStderrFD {
            box.value = try runner.run(
                executable: "/bin/sh",
                arguments: ["-c", "printf 'line-one\\nline-two\\n'; printf 'err-a\\nerr-b\\n' 1>&2"],
                environment: nil,
                currentDirectory: nil,
                streamStderr: true,
                teeStdoutToStderr: true
            )
        }
        guard let result = box.value else {
            throw MiniTest.Failure(message: "missing process result")
        }
        try MiniTest.expect(result.succeeded)
        // Capture buffers raw (no frame).
        try MiniTest.expect(result.stdoutString.contains("line-one"))
        try MiniTest.expect(result.stdoutString.contains("line-two"))
        try MiniTest.expect(!result.stdoutString.contains("| line-one"))
        try MiniTest.expect(result.stderrString.contains("err-a"))
        try MiniTest.expect(!result.stderrString.contains("| err-a"))
        // Display framed.
        try MiniTest.expect(display.contains("    | line-one\n"))
        try MiniTest.expect(display.contains("    | line-two\n"))
        try MiniTest.expect(display.contains("    | err-a\n"))
        try MiniTest.expect(display.contains("    | err-b\n"))
    }),
    ("processRunnerPartialLineAtEOFFlushedFramed", {
        let previousColor = TerminalStyle.colorOverride
        TerminalStyle.colorOverride = false
        defer { TerminalStyle.colorOverride = previousColor }

        let runner = FoundationProcessRunner()
        let box = ProcessResultBox()
        let display = try captureStderrFD {
            box.value = try runner.run(
                executable: "/bin/sh",
                arguments: ["-c", "printf 'no-trailing-nl'"],
                environment: nil,
                currentDirectory: nil,
                streamStderr: false,
                teeStdoutToStderr: true
            )
        }
        guard let result = box.value else {
            throw MiniTest.Failure(message: "missing process result")
        }
        try MiniTest.expect(result.succeeded)
        try MiniTest.expectEqual(result.stdoutString, "no-trailing-nl")
        try MiniTest.expect(!result.stdoutString.contains("| "))
        try MiniTest.expect(display.contains("    | no-trailing-nl\n"))
    }),
    ("processRunnerNonStreamDoesNotFrameOrWriteToolBody", {
        let previousColor = TerminalStyle.colorOverride
        TerminalStyle.colorOverride = false
        defer { TerminalStyle.colorOverride = previousColor }

        let runner = FoundationProcessRunner()
        let display = try captureStderrFD {
            _ = try runner.run(
                executable: "/bin/sh",
                arguments: ["-c", "echo SECRET_MARK; echo ERR_MARK 1>&2"],
                environment: nil,
                currentDirectory: nil
            )
        }
        let result = try runner.run(
            executable: "/bin/sh",
            arguments: ["-c", "echo SECRET_MARK; echo ERR_MARK 1>&2"],
            environment: nil,
            currentDirectory: nil
        )
        try MiniTest.expect(result.succeeded)
        try MiniTest.expect(result.stdoutString.contains("SECRET_MARK"))
        try MiniTest.expect(result.stderrString.contains("ERR_MARK"))
        // No host tee when not streaming.
        try MiniTest.expect(!display.contains("SECRET_MARK"))
        try MiniTest.expect(!display.contains("ERR_MARK"))
        try MiniTest.expect(!display.contains("| "))
    }),
    ("processRunnerMultiChunkLineReassembly", {
        let previousColor = TerminalStyle.colorOverride
        TerminalStyle.colorOverride = false
        defer { TerminalStyle.colorOverride = previousColor }

        let runner = FoundationProcessRunner()
        let payload = String(repeating: "x", count: 200) + "CHUNK_END"
        let box = ProcessResultBox()
        let display = try captureStderrFD {
            box.value = try runner.run(
                executable: "/bin/sh",
                arguments: ["-c", "printf '%s\\n' '\(payload)'"],
                environment: nil,
                currentDirectory: nil,
                streamStderr: false,
                teeStdoutToStderr: true
            )
        }
        guard let result = box.value else {
            throw MiniTest.Failure(message: "missing process result")
        }
        try MiniTest.expect(display.contains("    | \(payload)\n"))
        try MiniTest.expect(result.stdoutString.contains(payload))
        try MiniTest.expect(!result.stdoutString.contains("| "))
    }),
    ("interactiveProcessRunnerPathUnchangedNoFramingAPI", {
        // InteractiveProcessRunner does not implement StreamTeeingProcessRunning — no frame path.
        let interactive: any ProcessRunning = InteractiveProcessRunner()
        try MiniTest.expect(!(interactive is any StreamTeeingProcessRunning))
    }),
]
