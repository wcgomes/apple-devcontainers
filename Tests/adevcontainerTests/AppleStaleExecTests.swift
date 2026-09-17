import Foundation
@testable import ADevContainerLib

private let appleStaleExecStderr = """
Error: an unknown error occurred
caused by: internalError: failed to delete container
caused by: deleteProcess: exec 8F2A9C1B-4D3E-4A10-9B2C-1D2E3F4A5B6C does not exist in container adev-helper
"""

private func appleStaleExecFailure() -> ProcessResult {
    ProcessResult(exitCode: 1, stdout: Data(), stderr: Data(appleStaleExecStderr.utf8))
}

private func appleListedJSON(id: String, state: String = "running") -> Data {
    try! JSONSerialization.data(
        withJSONObject: [MockProcessRunner.containerListJSON(id: id, state: state)]
    )
}

private func appleEmptyListJSON() -> Data {
    Data("[]".utf8)
}

private func appleRuntime(_ mock: MockProcessRunner) -> AppleContainerRuntime {
    AppleContainerRuntime(executablePath: "container", runner: mock)
}

private func isVolumeOrImageCommand(_ args: [String]) -> Bool {
    args.first == "volume" || args.first == "image"
}

private func assertDeleteStopNotStreamed(_ mock: MockProcessRunner) throws {
    for call in mock.calls where call.arguments.first == "delete" || call.arguments.first == "stop" {
        try MiniTest.expect(
            call.streamStderr != true,
            "delete/stop must not live-tee Apple stderr (got streamStderr=\(String(describing: call.streamStderr)) for \(call.arguments))"
        )
    }
}

nonisolated(unsafe) let appleStaleExecTests: [(String, () throws -> Void)] = [
    ("deleteSucceedsFirstShotWithoutStreaming", {
        var deleteCount = 0
        let mock = MockProcessRunner()
        mock.handlers = [{ args in
            if args.first == "delete" {
                deleteCount += 1
                return ProcessResult(exitCode: 0, stdout: Data(), stderr: Data())
            }
            return nil
        }]
        try appleRuntime(mock).delete(nameOrId: "adev-helper", force: true)
        try MiniTest.expectEqual(deleteCount, 1, "first-shot success is one invoke")
        try MiniTest.expect(!mock.calls.contains { $0.arguments.first == "list" })
        try MiniTest.expect(!mock.calls.contains { $0.arguments.first == "stop" })
        try MiniTest.expect(!mock.calls.contains { $0.arguments.first == "start" })
        try assertDeleteStopNotStreamed(mock)
    }),

    ("appleStaleExecClassifiesNestedDeleteProcess", {
        try MiniTest.expect(AppleStaleExec.isMissingExecProcess(in: appleStaleExecStderr))
        try MiniTest.expect(AppleStaleExec.isMissingExecProcess(appleStaleExecFailure()))
        let stdoutOnly = ProcessResult(
            exitCode: 1,
            stdout: Data(appleStaleExecStderr.utf8),
            stderr: Data()
        )
        try MiniTest.expect(AppleStaleExec.isMissingExecProcess(stdoutOnly))
    }),

    ("appleStaleExecRejectsUnrelatedAbsenceAndExecErrors", {
        let negatives = [
            "Error: ENOENT",
            "volume data-vol does not exist",
            "container adev-helper does not exist",
            "no such container: adev-helper",
            "not found",
            "cannot exec: container is not running",
            "deleteProcess: something else failed",
            "exec 8F2A9C1B does not exist"
        ]
        for text in negatives {
            try MiniTest.expect(
                !AppleStaleExec.isMissingExecProcess(in: text),
                "must not classify: \(text)"
            )
        }
    }),

    ("deleteRetriesStaleExecThenSucceedsWithoutBounce", {
        var deleteCount = 0
        let mock = MockProcessRunner()
        mock.handlers = [{ args in
            if args.first == "delete" {
                deleteCount += 1
                if deleteCount == 1 {
                    return appleStaleExecFailure()
                }
                return ProcessResult(exitCode: 0, stdout: Data(), stderr: Data())
            }
            if args == ["list", "--all", "--format", "json"] {
                return ProcessResult(exitCode: 0, stdout: appleListedJSON(id: "adev-helper"), stderr: Data())
            }
            return nil
        }]
        try appleRuntime(mock).delete(nameOrId: "adev-helper", force: true)
        try MiniTest.expectEqual(deleteCount, 2)
        try MiniTest.expectEqual(
            mock.calls.filter { $0.arguments.first == "delete" }.map(\.arguments),
            [["delete", "--force", "adev-helper"], ["delete", "--force", "adev-helper"]]
        )
        try MiniTest.expect(!mock.calls.contains { $0.arguments.first == "stop" })
        try MiniTest.expect(!mock.calls.contains { $0.arguments.first == "start" })
        try MiniTest.expect(!mock.calls.contains { isVolumeOrImageCommand($0.arguments) })
        try assertDeleteStopNotStreamed(mock)
    }),

    ("deleteTreatsGoneAfterRetryBudgetAsSuccessWithoutBounce", {
        var deleteCount = 0
        var listCount = 0
        let mock = MockProcessRunner()
        mock.handlers = [{ args in
            if args.first == "delete" {
                deleteCount += 1
                return appleStaleExecFailure()
            }
            if args == ["list", "--all", "--format", "json"] {
                listCount += 1
                if listCount <= 3 {
                    return ProcessResult(exitCode: 0, stdout: appleListedJSON(id: "adev-helper"), stderr: Data())
                }
                return ProcessResult(exitCode: 0, stdout: appleEmptyListJSON(), stderr: Data())
            }
            return nil
        }]
        try appleRuntime(mock).delete(nameOrId: "adev-helper", force: true)
        try MiniTest.expectEqual(deleteCount, 3)
        try MiniTest.expect(!mock.calls.contains { $0.arguments.first == "stop" })
        try MiniTest.expect(!mock.calls.contains { $0.arguments.first == "start" })
        try MiniTest.expect(!mock.calls.contains { isVolumeOrImageCommand($0.arguments) })
    }),

    ("deleteTreatsStaleExecAsSuccessWhenContainerAlreadyGone", {
        var deleteCount = 0
        let mock = MockProcessRunner()
        mock.handlers = [{ args in
            if args.first == "delete" {
                deleteCount += 1
                return appleStaleExecFailure()
            }
            if args == ["list", "--all", "--format", "json"] {
                return ProcessResult(exitCode: 0, stdout: appleEmptyListJSON(), stderr: Data())
            }
            return nil
        }]
        try appleRuntime(mock).delete(nameOrId: "adev-helper", force: true)
        try MiniTest.expectEqual(deleteCount, 1, "gone after failed-looking delete is success")
        try MiniTest.expect(!mock.calls.contains { $0.arguments.first == "stop" })
        try MiniTest.expect(!mock.calls.contains { $0.arguments.first == "start" })
        try MiniTest.expect(!mock.calls.contains { isVolumeOrImageCommand($0.arguments) })
    }),

    ("deleteBouncesThenDeletesOnlyAfterRetriesStillSeeContainer", {
        var deleteCount = 0
        let mock = MockProcessRunner()
        mock.handlers = [{ args in
            if args.first == "delete" {
                deleteCount += 1
                let bounced = mock.calls.contains { $0.arguments.first == "stop" }
                    && mock.calls.contains { $0.arguments.first == "start" }
                if bounced {
                    return ProcessResult(exitCode: 0, stdout: Data(), stderr: Data())
                }
                return appleStaleExecFailure()
            }
            if args == ["list", "--all", "--format", "json"] {
                return ProcessResult(exitCode: 0, stdout: appleListedJSON(id: "adev-helper"), stderr: Data())
            }
            if args.first == "stop" || args.first == "start" {
                return ProcessResult(exitCode: 0, stdout: Data(), stderr: Data())
            }
            return nil
        }]
        try appleRuntime(mock).delete(nameOrId: "adev-helper", force: true)
        let deleteIndexes = mock.calls.indices.filter { mock.calls[$0].arguments.first == "delete" }
        let stopIndex = mock.calls.firstIndex { $0.arguments.first == "stop" }
        let startIndex = mock.calls.firstIndex { $0.arguments.first == "start" }
        try MiniTest.expectEqual(deleteIndexes.count, 4)
        try MiniTest.expect(stopIndex != nil, "bounce stop after retries")
        try MiniTest.expect(startIndex != nil, "bounce start after stop")
        try MiniTest.expect(deleteIndexes.filter { $0 < stopIndex! }.count == 3, "bounce only after retries still see the container")
        try MiniTest.expect(stopIndex! < startIndex!)
        try MiniTest.expect(startIndex! < deleteIndexes.last!)
        try MiniTest.expect(!mock.calls.contains { isVolumeOrImageCommand($0.arguments) })
    }),

    ("deleteTreatsPostBounceGoneAsSuccessEvenWhenStderrIsNotFound", {
        var deleteCount = 0
        let mock = MockProcessRunner()
        mock.handlers = [{ args in
            if args.first == "delete" {
                deleteCount += 1
                let bounced = mock.calls.contains { $0.arguments.first == "stop" }
                    && mock.calls.contains { $0.arguments.first == "start" }
                if bounced {
                    return ProcessResult(
                        exitCode: 1,
                        stdout: Data(),
                        stderr: Data("Error: no such container: adev-helper".utf8)
                    )
                }
                return appleStaleExecFailure()
            }
            if args == ["list", "--all", "--format", "json"] {
                let stopIndex = mock.calls.firstIndex { $0.arguments.first == "stop" }
                let deletedAfterBounce = stopIndex.map { stop in
                    mock.calls.enumerated().contains { offset, call in
                        offset > stop && call.arguments.first == "delete"
                    }
                } ?? false
                if deletedAfterBounce {
                    return ProcessResult(exitCode: 0, stdout: appleEmptyListJSON(), stderr: Data())
                }
                return ProcessResult(exitCode: 0, stdout: appleListedJSON(id: "adev-helper"), stderr: Data())
            }
            if args.first == "stop" || args.first == "start" {
                return ProcessResult(exitCode: 0, stdout: Data(), stderr: Data())
            }
            return nil
        }]
        try appleRuntime(mock).delete(nameOrId: "adev-helper", force: true)
        try MiniTest.expectEqual(deleteCount, 4)
        try MiniTest.expect(mock.calls.contains { $0.arguments.first == "stop" })
        try MiniTest.expect(mock.calls.contains { $0.arguments.first == "start" })
        try MiniTest.expect(!mock.calls.contains { isVolumeOrImageCommand($0.arguments) })
    }),

    ("deleteFailsClosedWithAppleDiagnosticWhenStillListed", {
        let mock = MockProcessRunner()
        mock.handlers = [{ args in
            if args.first == "delete" {
                return appleStaleExecFailure()
            }
            if args == ["list", "--all", "--format", "json"] {
                return ProcessResult(exitCode: 0, stdout: appleListedJSON(id: "adev-helper"), stderr: Data())
            }
            if args.first == "stop" || args.first == "start" {
                return ProcessResult(exitCode: 0, stdout: Data(), stderr: Data())
            }
            return nil
        }]
        try MiniTest.expectThrows({
            try appleRuntime(mock).delete(nameOrId: "adev-helper", force: true)
        }, validate: { error in
            let cli = error as? CLIError
            try MiniTest.expectEqual(cli?.code, CLIErrorCode.runtimeFailed)
            try MiniTest.expect(
                cli?.message.contains("deleteProcess") == true
                    && cli?.message.contains("does not exist in container") == true,
                "fail closed with the Apple diagnostic"
            )
        })
        try MiniTest.expect(mock.calls.contains { $0.arguments.first == "stop" })
        try MiniTest.expect(mock.calls.contains { $0.arguments.first == "start" })
        try MiniTest.expect(!mock.calls.contains { isVolumeOrImageCommand($0.arguments) })
        try assertDeleteStopNotStreamed(mock)
    }),

    ("deleteDoesNotRetryUnrelatedFailure", {
        var deleteCount = 0
        let mock = MockProcessRunner()
        mock.handlers = [{ args in
            if args.first == "delete" {
                deleteCount += 1
                return ProcessResult(
                    exitCode: 1,
                    stdout: Data(),
                    stderr: Data("Error: permission denied".utf8)
                )
            }
            return nil
        }]
        try MiniTest.expectThrows({
            try appleRuntime(mock).delete(nameOrId: "adev-helper", force: true)
        }, validate: { error in
            try MiniTest.expectEqual((error as? CLIError)?.code, CLIErrorCode.runtimeFailed)
        })
        try MiniTest.expectEqual(deleteCount, 1)
        try MiniTest.expect(!mock.calls.contains { $0.arguments.first == "list" })
        try MiniTest.expect(!mock.calls.contains { $0.arguments.first == "stop" })
        try MiniTest.expect(!mock.calls.contains { isVolumeOrImageCommand($0.arguments) })
    }),

    ("stopRetriesStaleExecThenSucceeds", {
        var stopCount = 0
        let mock = MockProcessRunner()
        mock.handlers = [{ args in
            if args.first == "stop" {
                stopCount += 1
                if stopCount == 1 {
                    return appleStaleExecFailure()
                }
                return ProcessResult(exitCode: 0, stdout: Data(), stderr: Data())
            }
            if args == ["list", "--all", "--format", "json"] {
                return ProcessResult(exitCode: 0, stdout: appleListedJSON(id: "adev-helper"), stderr: Data())
            }
            return nil
        }]
        try appleRuntime(mock).stop(nameOrId: "adev-helper")
        try MiniTest.expectEqual(stopCount, 2)
        try MiniTest.expect(!mock.calls.contains { $0.arguments.first == "start" })
        try MiniTest.expect(!mock.calls.contains { $0.arguments.first == "delete" })
        try MiniTest.expect(!mock.calls.contains { isVolumeOrImageCommand($0.arguments) })
        try assertDeleteStopNotStreamed(mock)
    }),

    ("stopFailsClosedWithoutBounceWhenStillListed", {
        var stopCount = 0
        let mock = MockProcessRunner()
        mock.handlers = [{ args in
            if args.first == "stop" {
                stopCount += 1
                return appleStaleExecFailure()
            }
            if args == ["list", "--all", "--format", "json"] {
                return ProcessResult(exitCode: 0, stdout: appleListedJSON(id: "adev-helper"), stderr: Data())
            }
            return nil
        }]
        try MiniTest.expectThrows({
            try appleRuntime(mock).stop(nameOrId: "adev-helper")
        }, validate: { error in
            let cli = error as? CLIError
            try MiniTest.expectEqual(cli?.code, CLIErrorCode.runtimeFailed)
            try MiniTest.expect(
                cli?.message.contains("deleteProcess") == true,
                "fail closed with the Apple diagnostic"
            )
        })
        try MiniTest.expectEqual(stopCount, 3)
        try MiniTest.expect(!mock.calls.contains { $0.arguments.first == "start" })
        try MiniTest.expect(!mock.calls.contains { $0.arguments.first == "delete" })
        try MiniTest.expect(!mock.calls.contains { isVolumeOrImageCommand($0.arguments) })
        try assertDeleteStopNotStreamed(mock)
    }),

    ("stopTreatsStaleExecAsSuccessWhenContainerAlreadyGone", {
        var stopCount = 0
        let mock = MockProcessRunner()
        mock.handlers = [{ args in
            if args.first == "stop" {
                stopCount += 1
                return appleStaleExecFailure()
            }
            if args == ["list", "--all", "--format", "json"] {
                return ProcessResult(exitCode: 0, stdout: appleEmptyListJSON(), stderr: Data())
            }
            return nil
        }]
        try appleRuntime(mock).stop(nameOrId: "adev-helper")
        try MiniTest.expectEqual(stopCount, 1)
        try MiniTest.expect(!mock.calls.contains { $0.arguments.first == "start" })
        try MiniTest.expect(!mock.calls.contains { $0.arguments.first == "delete" })
        try MiniTest.expect(!mock.calls.contains { isVolumeOrImageCommand($0.arguments) })
    })
]
