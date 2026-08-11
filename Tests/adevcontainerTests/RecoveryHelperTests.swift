import Foundation
@testable import ADevContainerLib

private func recoveryImageInspectionJSON() -> Data {
    let object: [String: Any] = [
        "configuration": [
            "name": RecoveryHelper.helperImageReference,
            "variants": [[
                "digest": RecoveryHelper.helperImageDigest,
                "platform": ["os": "linux", "architecture": "arm64", "variant": "v8"]
            ]]
        ]
    ]
    return try! JSONSerialization.data(withJSONObject: [object])
}

private func recoveryVolumeListJSON(_ names: [String]) -> Data {
    try! JSONSerialization.data(withJSONObject: names.map { ["configuration": ["name": $0]] })
}

private func recoveryContainerListJSON(
    id: String,
    volume: String,
    destination: String = "/workspaces/repo"
) -> Data {
    let object: [String: Any] = [
        "id": id,
        "configuration": [
            "id": id,
            "labels": [:],
            "mounts": [[
                "source": "/var/lib/container/volumes/\(volume).img",
                "destination": destination,
                "options": [],
                "type": ["volume": ["name": volume]]
            ]]
        ],
        "status": ["state": "running"]
    ]
    return try! JSONSerialization.data(withJSONObject: [object])
}

private func recoveryLabels(
    managed: String = ContainerIdentity.managedValue,
    mode: String = ContainerIdentity.workspaceModeVolume,
    gitURL: String = "https://github.com/example/repo.git",
    volume: String = "adev-repo-ws",
    config: String = ".devcontainer/devcontainer.json"
) -> [String: String] {
    [
        ContainerIdentity.labelManaged: managed,
        ContainerIdentity.labelWorkspaceMode: mode,
        ContainerIdentity.labelGitURL: gitURL,
        ContainerIdentity.labelWorkspaceVolume: volume,
        ContainerIdentity.labelConfigFile: config,
        ContainerIdentity.labelWorkspaceFolder: "/workspaces/repo",
        ContainerIdentity.labelConfigHash: "old-hash"
    ]
}

nonisolated(unsafe) let recoveryHelperTests: [(String, () throws -> Void)] = [
    ("recoveryEligibilityRequiresAllCloneOriginStamps", {
        let labels = recoveryLabels()
        try MiniTest.expect(RecoveryHelper.isEligible(labels: labels))
        try MiniTest.expect(!RecoveryHelper.isEligible(labels: recoveryLabels(mode: ContainerIdentity.workspaceModeBind)))
        try MiniTest.expect(!RecoveryHelper.isEligible(labels: recoveryLabels(gitURL: "")))
        try MiniTest.expect(!RecoveryHelper.isEligible(labels: recoveryLabels(volume: "")))
        try MiniTest.expect(!RecoveryHelper.isEligible(labels: recoveryLabels(config: "")))
        try MiniTest.expect(!RecoveryHelper.isEligible(labels: recoveryLabels(managed: "other")))
        try MiniTest.expect(!RecoveryHelper.isEligible(labels: recoveryLabels(config: "../../etc/passwd")))
        try MiniTest.expect(!RecoveryHelper.isEligible(labels: recoveryLabels(config: "/etc/passwd")))
    }),

    ("recoveryImageIsImmutableNativeArmDigest", {
        try MiniTest.expect(RecoveryHelper.helperImageReference.contains("@sha256:"))
        try MiniTest.expectEqual(RecoveryHelper.helperPlatform, "linux/arm64")
        try MiniTest.expectEqual(RecoveryHelper.helperImageDigest.count, 71)
        try MiniTest.expect(RecoveryHelper.helperImageDigest.hasPrefix("sha256:"))
    }),

    ("recoveryImagePreflightVerifiesDigestAndPlatform", {
        let mock = MockProcessRunner()
        mock.handlers = [{ args in
            guard args == ["image", "inspect", RecoveryHelper.helperImageReference] else { return nil }
            return ProcessResult(exitCode: 0, stdout: recoveryImageInspectionJSON(), stderr: Data())
        }]
        let runtime = AppleContainerRuntime(executablePath: "container", runner: mock)
        let image = try RecoveryHelper.preflightImage(runtime: runtime, pullIfMissing: false)
        try MiniTest.expectEqual(image, RecoveryHelper.pinnedImage)
        try MiniTest.expectEqual(mock.calls.map(\.arguments), [["image", "inspect", RecoveryHelper.helperImageReference]])
    }),

     ("recoveryImagePreflightRejectsWrongDigestOrPlatform", {
        let wrongCases: [(String, [String: Any])] = [
            ("wrong-digest", ["os": "linux", "architecture": "arm64", "digest": "sha256:" + String(repeating: "a", count: 64)]),
            ("wrong-platform", ["os": "linux", "architecture": "amd64", "digest": RecoveryHelper.helperImageDigest])
        ]
        for (name, platform) in wrongCases {
            let mock = MockProcessRunner()
            let object: [String: Any] = [
                "configuration": [
                    "name": RecoveryHelper.helperImageReference,
                    "variants": [["digest": platform["digest"]!, "platform": platform]]
                ]
            ]
            let data = try JSONSerialization.data(withJSONObject: [object])
            mock.handlers = [{ args in
                guard args == ["image", "inspect", RecoveryHelper.helperImageReference] else { return nil }
                return ProcessResult(exitCode: 0, stdout: data, stderr: Data())
            }]
            let runtime = AppleContainerRuntime(executablePath: "container", runner: mock)
            try MiniTest.expectThrows({
                _ = try RecoveryHelper.preflightImage(runtime: runtime, pullIfMissing: false)
            }, validate: { error in
                try MiniTest.expectEqual((error as? CLIError)?.code, CLIErrorCode.recoveryUnavailable, name)
            })
        }
     }),

     ("recoveryImagePreflightRejectsMixedInspectArray", {
         let mock = MockProcessRunner()
         let list: [Any] = [[
             "configuration": [
                 "name": RecoveryHelper.helperImageReference,
                 "variants": [[
                     "digest": RecoveryHelper.helperImageDigest,
                     "platform": ["os": "linux", "architecture": "arm64"]
                 ]]
             ]
         ], "unexpected-entry"]
         let data = try JSONSerialization.data(withJSONObject: list)
         mock.handlers = [{ args in
             guard args == ["image", "inspect", RecoveryHelper.helperImageReference] else { return nil }
             return ProcessResult(exitCode: 0, stdout: data, stderr: Data())
         }]
         let runtime = AppleContainerRuntime(executablePath: "container", runner: mock)
         try MiniTest.expectThrows({
             _ = try RecoveryHelper.preflightImage(runtime: runtime, pullIfMissing: false)
         }, validate: { error in
             try MiniTest.expectEqual((error as? CLIError)?.code, CLIErrorCode.recoveryUnavailable)
         })
     }),

    ("recoveryImageUnavailableFailsClosedBeforeDelete", {
        let mock = MockProcessRunner()
        mock.handlers = [{ args in
            if args == ["image", "inspect", RecoveryHelper.helperImageReference] {
                return ProcessResult(exitCode: 1, stdout: Data(), stderr: Data("missing".utf8))
            }
            if args == ["image", "pull", "--platform", "linux/arm64", RecoveryHelper.helperImageReference] {
                return ProcessResult(exitCode: 1, stdout: Data(), stderr: Data("offline".utf8))
            }
            return nil
        }]
        let runtime = AppleContainerRuntime(executablePath: "container", runner: mock)
        try MiniTest.expectThrows({
            _ = try RecoveryHelper.preflightImage(runtime: runtime)
        }, validate: { error in
            try MiniTest.expectEqual((error as? CLIError)?.code, CLIErrorCode.recoveryUnavailable)
        })
        try MiniTest.expect(!mock.calls.contains { $0.arguments.first == "delete" })
        let pull = mock.calls.first { $0.arguments.first == "image" && $0.arguments.dropFirst().first == "pull" }
        try MiniTest.expectEqual(pull?.arguments.dropFirst(3).first, "linux/arm64")
    }),

    ("recoveryPreparationVerifiesExistingVolumeAndCreatesOnlyWorkspaceMount", {
        let mock = MockProcessRunner()
        mock.handlers = [{ args in
            if args == ["volume", "list", "--format", "json"] {
                return ProcessResult(exitCode: 0, stdout: recoveryVolumeListJSON(["adev-repo-ws"]), stderr: Data())
            }
            if args == ["image", "inspect", RecoveryHelper.helperImageReference] {
                return ProcessResult(exitCode: 0, stdout: recoveryImageInspectionJSON(), stderr: Data())
            }
            return nil
        }]
        let original = ContainerInfo(
            id: "old-id",
            name: "adev-repo-hash",
            state: "running",
            labels: recoveryLabels(),
            image: "alpine:3.20"
        )
        let runtime = AppleContainerRuntime(executablePath: "container", runner: mock)
        let preparation = try RecoveryHelper.prepare(
            for: original,
            sessionID: "session-opaque",
            runtime: runtime,
            pullIfMissing: false
        )
        let args = preparation.request.createRequest.createArguments()
        try MiniTest.expect(args.contains("--platform"))
        try MiniTest.expect(args.contains("linux/arm64"))
        try MiniTest.expectEqual(args.filter { $0 == "--mount" }.count, 1)
        try MiniTest.expect(args.contains("type=volume,source=adev-repo-ws,target=/workspaces/repo"))
        try MiniTest.expect(args.contains("devcontainer.recovery=adevcontainer"))
        try MiniTest.expect(args.contains("devcontainer.recovery_session=session-opaque"))
        try MiniTest.expect(args.contains("devcontainer.git_url=https://github.com/example/repo.git"))
        try MiniTest.expect(!args.contains("container cp"))
        try MiniTest.expect(!mock.calls.contains { $0.arguments.first == "volume" && $0.arguments.dropFirst().first == "create" })
    }),

    ("recoveryMissingVolumeRefusesBlankReplacement", {
        let mock = MockProcessRunner()
        mock.handlers = [{ args in
            if args == ["volume", "list", "--format", "json"] {
                return ProcessResult(exitCode: 0, stdout: recoveryVolumeListJSON([]), stderr: Data())
            }
            return nil
        }]
        let original = ContainerInfo(
            id: "old-id",
            name: "adev-repo-hash",
            state: "running",
            labels: recoveryLabels(),
            image: "alpine:3.20"
        )
        let runtime = AppleContainerRuntime(executablePath: "container", runner: mock)
        try MiniTest.expectThrows({
            _ = try RecoveryHelper.prepare(
                for: original,
                sessionID: "session",
                runtime: runtime,
                pullIfMissing: false
            )
        }, validate: { error in
            try MiniTest.expectEqual((error as? CLIError)?.code, CLIErrorCode.recoveryUnavailable)
        })
        try MiniTest.expect(!mock.calls.contains { $0.arguments.first == "volume" && $0.arguments.dropFirst().first == "create" })
    }),

    ("recoveryHelperCreateRetainsIdentityAndDoesNotEnsureVolume", {
        let mock = MockProcessRunner()
        mock.handlers = [{ args in
            if args == ["volume", "list", "--format", "json"] {
                return ProcessResult(exitCode: 0, stdout: recoveryVolumeListJSON(["adev-repo-ws"]), stderr: Data())
            }
            if args == ["image", "inspect", RecoveryHelper.helperImageReference] {
                return ProcessResult(exitCode: 0, stdout: recoveryImageInspectionJSON(), stderr: Data())
            }
            if args.first == "create" { return ProcessResult(exitCode: 0, stdout: Data("helper-id\n".utf8), stderr: Data()) }
            if args.first == "start" { return ProcessResult(exitCode: 0, stdout: Data(), stderr: Data()) }
            if args == ["inspect", "helper-id"] {
                return ProcessResult(
                    exitCode: 0,
                    stdout: recoveryContainerListJSON(id: "helper-id", volume: "adev-repo-ws"),
                    stderr: Data()
                )
            }
            return nil
        }]
        let original = ContainerInfo(
            id: "old-id",
            name: "adev-repo-hash",
            state: "running",
            labels: recoveryLabels(),
            image: "alpine:3.20"
        )
        let runtime = AppleContainerRuntime(executablePath: "container", runner: mock)
        let preparation = try RecoveryHelper.prepare(
            for: original,
            sessionID: "session",
            runtime: runtime,
            pullIfMissing: false
        )
        let helperID = try RecoveryHelper.createHelper(preparation: preparation, runtime: runtime)
        try MiniTest.expectEqual(helperID, "helper-id")
        let create = mock.calls.first { $0.arguments.first == "create" }!.arguments
        try MiniTest.expect(create.contains("--name"))
        try MiniTest.expect(create.contains("adev-repo-hash"))
        try MiniTest.expect(create.contains("devcontainer.managed=adevcontainer"))
        try MiniTest.expect(create.contains("devcontainer.recovery=adevcontainer"))
        try MiniTest.expect(create.contains("devcontainer.recovery_session=session"))
        try MiniTest.expect(create.contains("type=volume,source=adev-repo-ws,target=/workspaces/repo"))
        try MiniTest.expect(!mock.calls.contains { $0.arguments == ["volume", "create", "adev-repo-ws"] })
        try MiniTest.expect(!mock.calls.contains { $0.arguments.first == "cp" || $0.arguments.first == "copy" })
    }),

    ("recoveryAttachmentMatchesNestedLogicalVolumeName", {
        let mock = MockProcessRunner()
        mock.handlers = [{ args in
            guard args == ["list", "--all", "--format", "json"] else { return nil }
            return ProcessResult(
                exitCode: 0,
                stdout: recoveryContainerListJSON(
                    id: "attached",
                    volume: "adev-repo-ws"
                ),
                stderr: Data()
            )
        }]
        let runtime = AppleContainerRuntime(executablePath: "container", runner: mock)
        let attached = try runtime.containersAttached(to: "adev-repo-ws")
        try MiniTest.expectEqual(attached.map(\.id), ["attached"])
        let attachedOther = try runtime.isVolumeAttached(volumeName: "not-the-backing-image")
        try MiniTest.expect(!attachedOther)
    }),
    ("recoveryMissingMountMetadataFailsClosed", {
        let mock = MockProcessRunner()
        mock.handlers = [{ args in
            guard args == ["list", "--all", "--format", "json"] else { return nil }
            let object: [String: Any] = [
                "id": "missing-mounts",
                "configuration": ["id": "missing-mounts", "labels": [:]],
                "status": ["state": "running"]
            ]
            return ProcessResult(
                exitCode: 0,
                stdout: try! JSONSerialization.data(withJSONObject: [object]),
                stderr: Data()
            )
        }]
        let runtime = AppleContainerRuntime(executablePath: "container", runner: mock)
        try MiniTest.expectThrows({
            _ = try runtime.containersAttached(to: "adev-repo-ws")
        }, validate: { error in
            try MiniTest.expectEqual((error as? CLIError)?.code, CLIErrorCode.recoveryUnavailable)
        })
    }),
    ("recoveryKnownEmptyMountMetadataIsDetached", {
        let mock = MockProcessRunner()
        mock.handlers = [{ args in
            guard args == ["list", "--all", "--format", "json"] else { return nil }
            let object: [String: Any] = [
                "id": "no-mounts",
                "configuration": [
                    "id": "no-mounts",
                    "labels": [:],
                    "mounts": []
                ],
                "status": ["state": "stopped"]
            ]
            return ProcessResult(
                exitCode: 0,
                stdout: try! JSONSerialization.data(withJSONObject: [object]),
                stderr: Data()
            )
        }]
        let runtime = AppleContainerRuntime(executablePath: "container", runner: mock)
        try RecoveryHelper.verifyWorkspaceVolumeDetached(volumeName: "adev-repo-ws", runtime: runtime)
    }),
    ("recoveryNonObjectMountEntryFailsClosed", {
        let mock = MockProcessRunner()
        mock.handlers = [{ args in
            guard args == ["list", "--all", "--format", "json"] else { return nil }
            let object: [String: Any] = [
                "id": "malformed-mount-entry",
                "configuration": [
                    "id": "malformed-mount-entry",
                    "mounts": ["not-an-object"]
                ],
                "status": ["state": "running"]
            ]
            return ProcessResult(
                exitCode: 0,
                stdout: try! JSONSerialization.data(withJSONObject: [object]),
                stderr: Data()
            )
        }]
        let runtime = AppleContainerRuntime(executablePath: "container", runner: mock)
        try MiniTest.expectThrows({
            _ = try runtime.containersAttached(to: "adev-repo-ws")
        }, validate: { error in
            try MiniTest.expectEqual((error as? CLIError)?.code, CLIErrorCode.recoveryUnavailable)
        })
    }),
    ("recoveryMalformedVolumeListFailsClosed", {
        let mock = MockProcessRunner()
        mock.handlers = [{ args in
            guard args == ["volume", "list", "--format", "json"] else { return nil }
            let list: [Any] = [["configuration": ["name": "adev-repo-ws"]], "not-an-object"]
            return ProcessResult(
                exitCode: 0,
                stdout: try! JSONSerialization.data(withJSONObject: list),
                stderr: Data()
            )
        }]
        let original = ContainerInfo(
            id: "old-id",
            name: "adev-repo",
            state: "running",
            labels: recoveryLabels(),
            image: "alpine:3.20"
        )
        let runtime = AppleContainerRuntime(executablePath: "container", runner: mock)
        try MiniTest.expectThrows({
            _ = try RecoveryHelper.prepare(
                for: original,
                sessionID: "malformed-volume-list",
                runtime: runtime,
                pullIfMissing: false
            )
        }, validate: { error in
            try MiniTest.expectEqual((error as? CLIError)?.code, CLIErrorCode.recoveryUnavailable)
        })
    }),

    ("recoveryMalformedMountSchemaFailsClosed", {
        let mock = MockProcessRunner()
        mock.handlers = [{ args in
            guard args == ["list", "--all", "--format", "json"] else { return nil }
            let malformed: [String: Any] = [
                "id": "attached",
                "configuration": [
                    "id": "attached",
                    "mounts": [[
                        "source": "/var/lib/container/volumes/adev-repo-ws.img",
                        "destination": "/workspaces/repo",
                        "type": ["volume": [:]]
                    ]]
                ],
                "status": ["state": "running"]
            ]
            return ProcessResult(
                exitCode: 0,
                stdout: try! JSONSerialization.data(withJSONObject: [malformed]),
                stderr: Data()
            )
        }]
        let runtime = AppleContainerRuntime(executablePath: "container", runner: mock)
        try MiniTest.expectThrows({
            _ = try runtime.containersAttached(to: "adev-repo-ws")
        }, validate: { error in
            try MiniTest.expectEqual((error as? CLIError)?.code, CLIErrorCode.recoveryUnavailable)
        })
    }),

    ("recoveryHelperRejectsReadOnlyWrongTargetOrExtraAttachment", {
        let mock = MockProcessRunner()
        mock.handlers = [{ args in
            if args == ["volume", "list", "--format", "json"] {
                return ProcessResult(exitCode: 0, stdout: recoveryVolumeListJSON(["adev-repo-ws"]), stderr: Data())
            }
            if args == ["image", "inspect", RecoveryHelper.helperImageReference] {
                return ProcessResult(exitCode: 0, stdout: recoveryImageInspectionJSON(), stderr: Data())
            }
            if args.first == "create" { return ProcessResult(exitCode: 0, stdout: Data("helper-id\n".utf8), stderr: Data()) }
            if args.first == "start" { return ProcessResult(exitCode: 0, stdout: Data(), stderr: Data()) }
            if args == ["inspect", "helper-id"] {
                let object: [String: Any] = [
                    "id": "helper-id",
                    "configuration": [
                        "id": "helper-id",
                        "mounts": [[
                            "source": "/var/lib/container/volumes/adev-repo-ws.img",
                            "destination": "/wrong-target",
                            "options": ["ro"],
                            "type": ["volume": ["name": "adev-repo-ws"]]
                        ]]
                    ],
                    "status": ["state": "running"]
                ]
                return ProcessResult(
                    exitCode: 0,
                    stdout: try! JSONSerialization.data(withJSONObject: [object]),
                    stderr: Data()
                )
            }
            return nil
        }]
        let original = ContainerInfo(
            id: "old-id",
            name: "adev-repo-hash",
            state: "running",
            labels: recoveryLabels(),
            image: "alpine:3.20"
        )
        let runtime = AppleContainerRuntime(executablePath: "container", runner: mock)
        let preparation = try RecoveryHelper.prepare(
            for: original,
            sessionID: "session-rw",
            runtime: runtime,
            pullIfMissing: false
        )
        try MiniTest.expectThrows({
            _ = try RecoveryHelper.createHelper(preparation: preparation, runtime: runtime)
        }, validate: { error in
            try MiniTest.expectEqual((error as? CLIError)?.code, CLIErrorCode.recoveryUnavailable)
        })
        try MiniTest.expect(mock.calls.contains { $0.arguments.first == "delete" && $0.arguments.last == "helper-id" })
        try MiniTest.expect(!mock.calls.contains { $0.arguments.first == "volume" && $0.arguments.dropFirst().first == "delete" })
    }),
     ("recoveryHelperRequiresExactlyOneWorkspaceVolumeMount", {
         let extraMounts: [[String: Any]] = [
             [
                 "source": "/host/tmp",
                 "destination": "/tmp",
                 "options": [],
                 "type": ["bind": ["source": "/host/tmp"]]
             ],
             [
                 "source": "/var/lib/container/volumes/other.img",
                 "destination": "/other",
                 "options": [],
                 "type": ["volume": ["name": "other-volume"]]
             ],
             [
                 "destination": "/tmp",
                 "options": [],
                 "type": ["tmpfs": [:]]
             ]
         ]
         for extra in extraMounts {
             let mock = MockProcessRunner()
             mock.handlers = [{ args in
                 guard args == ["inspect", "helper-id"] else { return nil }
                 let object: [String: Any] = [
                     "configuration": [
                         "mounts": [
                             ["destination": "/workspaces/repo", "options": [], "type": ["volume": ["name": "adev-repo-ws"]]],
                             extra
                         ]
                     ]
                 ]
                 return ProcessResult(exitCode: 0, stdout: try! JSONSerialization.data(withJSONObject: [object]), stderr: Data())
             }]
             let runtime = AppleContainerRuntime(executablePath: "container", runner: mock)
             try MiniTest.expectThrows({
                 try runtime.verifyVolumeAttachment(nameOrId: "helper-id", volumeName: "adev-repo-ws", targetPath: "/workspaces/repo")
             }, validate: { error in
                 try MiniTest.expectEqual((error as? CLIError)?.code, CLIErrorCode.recoveryUnavailable)
             })
         }
     }),

     ("recoveryContainerInspectRejectsMultipleObjects", {
         let mock = MockProcessRunner()
         let object: [String: Any] = [
             "configuration": [
                 "mounts": [[
                     "source": "/var/lib/container/volumes/adev-repo-ws.img",
                     "destination": "/workspaces/repo",
                     "options": [],
                     "type": ["volume": ["name": "adev-repo-ws"]]
                 ]]
             ]
         ]
         let data = try JSONSerialization.data(withJSONObject: [object, object])
         mock.handlers = [{ args in
             guard args == ["inspect", "helper-id"] else { return nil }
             return ProcessResult(exitCode: 0, stdout: data, stderr: Data())
         }]
         let runtime = AppleContainerRuntime(executablePath: "container", runner: mock)
         try MiniTest.expectThrows({
             try runtime.verifyVolumeAttachment(nameOrId: "helper-id", volumeName: "adev-repo-ws", targetPath: "/workspaces/repo")
         }, validate: { error in
             try MiniTest.expectEqual((error as? CLIError)?.code, CLIErrorCode.recoveryUnavailable)
         })
     }),

     ("recoveryAttachmentInspectionFailsClosed", {
        let mock = MockProcessRunner()
        mock.handlers = [{ args in
            if args == ["list", "--all", "--format", "json"] {
                return ProcessResult(
                    exitCode: 0,
                    stdout: recoveryContainerListJSON(id: "failed-new", volume: "adev-repo-ws"),
                    stderr: Data()
                )
            }
            return nil
        }]
        let runtime = AppleContainerRuntime(executablePath: "container", runner: mock)
        try MiniTest.expectThrows({
            try RecoveryHelper.verifyWorkspaceVolumeDetached(volumeName: "adev-repo-ws", runtime: runtime)
        }, validate: { error in
            try MiniTest.expectEqual((error as? CLIError)?.code, CLIErrorCode.recoveryUnavailable)
        })
    }),

    ("recoveryHelperEnsureExecReadyNoopsWhenProbeSucceeds", {
        let mock = MockProcessRunner()
        mock.handlers = [{ args in
            if args.first == "exec", args.contains("true") {
                return ProcessResult(exitCode: 0, stdout: Data(), stderr: Data())
            }
            return nil
        }]
        let runtime = AppleContainerRuntime(executablePath: "container", runner: mock)
        try RecoveryHelper.ensureExecReady(nameOrId: "helper-id", runtime: runtime)
        try MiniTest.expectEqual(
            mock.calls.filter { $0.arguments.first == "exec" }.count,
            1,
            "healthy helper needs only one probe"
        )
        try MiniTest.expect(!mock.calls.contains { $0.arguments.first == "start" || $0.arguments.first == "stop" })
    }),

    ("recoveryHelperEnsureExecReadyStartsStoppedHelper", {
        var probe = 0
        let mock = MockProcessRunner()
        mock.handlers = [{ args in
            if args.first == "exec", args.contains("true") {
                probe += 1
                // Fail until start has been issued.
                let started = mock.calls.contains { $0.arguments.first == "start" }
                return ProcessResult(
                    exitCode: started ? 0 : 1,
                    stdout: Data(),
                    stderr: started
                        ? Data()
                        : Data("cannot exec: container is not running".utf8)
                )
            }
            if args.first == "start" {
                return ProcessResult(exitCode: 0, stdout: Data(), stderr: Data())
            }
            return nil
        }]
        let runtime = AppleContainerRuntime(executablePath: "container", runner: mock)
        try RecoveryHelper.ensureExecReady(nameOrId: "helper-id", runtime: runtime)
        try MiniTest.expect(mock.calls.contains { $0.arguments == ["start", "helper-id"] })
        try MiniTest.expect(probe >= 2, "probe before and after start")
        try MiniTest.expect(!mock.calls.contains { $0.arguments.first == "stop" }, "start alone is enough when it restores exec")
    }),

    ("recoveryHelperEnsureExecReadyBouncesZombieRunningHelper", {
        // Apple container list/inspect can say running while exec fails with
        // "cannot exec: container is not running". Product must stop+start once.
        var startedAfterStop = false
        let mock = MockProcessRunner()
        mock.handlers = [{ args in
            if args.first == "exec", args.contains("true") {
                if startedAfterStop {
                    return ProcessResult(exitCode: 0, stdout: Data(), stderr: Data())
                }
                return ProcessResult(
                    exitCode: 1,
                    stdout: Data(),
                    stderr: Data("cannot exec: container is not running".utf8)
                )
            }
            if args.first == "start" {
                // First start (before bounce) is a no-op on zombie metadata; exec still fails.
                // After stop, start restores exec.
                if mock.calls.contains(where: { $0.arguments.first == "stop" }) {
                    startedAfterStop = true
                }
                return ProcessResult(exitCode: 0, stdout: Data(), stderr: Data())
            }
            if args.first == "stop" {
                return ProcessResult(exitCode: 0, stdout: Data(), stderr: Data())
            }
            return nil
        }]
        let runtime = AppleContainerRuntime(executablePath: "container", runner: mock)
        try RecoveryHelper.ensureExecReady(nameOrId: "helper-id", runtime: runtime)
        try MiniTest.expect(mock.calls.contains { $0.arguments.first == "stop" })
        try MiniTest.expect(mock.calls.contains { $0.arguments == ["start", "helper-id"] })
        try MiniTest.expect(startedAfterStop)
    }),

    ("recoveryHelperEnsureExecReadyFailsClosedWhenBounceDoesNotRestoreExec", {
        let mock = MockProcessRunner()
        mock.handlers = [{ args in
            if args.first == "exec", args.contains("true") {
                return ProcessResult(
                    exitCode: 1,
                    stdout: Data(),
                    stderr: Data("cannot exec: container is not running".utf8)
                )
            }
            if args.first == "start" || args.first == "stop" {
                return ProcessResult(exitCode: 0, stdout: Data(), stderr: Data())
            }
            return nil
        }]
        let runtime = AppleContainerRuntime(executablePath: "container", runner: mock)
        try MiniTest.expectThrows({
            try RecoveryHelper.ensureExecReady(nameOrId: "helper-id", runtime: runtime)
        }, validate: { error in
            try MiniTest.expectEqual((error as? CLIError)?.code, CLIErrorCode.recoveryUnavailable)
        })
        try MiniTest.expect(!mock.calls.contains { $0.arguments.first == "volume" })
        try MiniTest.expect(!mock.calls.contains { $0.arguments.first == "delete" })
    })
]
