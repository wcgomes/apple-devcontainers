import Foundation
@testable import ADevContainerLib

// MARK: - Synthetic ext4 images

/// Superblock region (bytes 1024..<2048) with the fields the health gate reads.
func syntheticExt4Superblock(
    magic: UInt16 = 0xEF53,
    state: UInt16 = 0x0001,
    errorCount: UInt32 = 0,
    compat: UInt32 = 0x0004,
    incompat: UInt32 = 0
) -> Data {
    var bytes = [UInt8](repeating: 0, count: 1024)
    func put16(_ value: UInt16, _ at: Int) {
        bytes[at] = UInt8(value & 0xFF)
        bytes[at + 1] = UInt8(value >> 8)
    }
    func put32(_ value: UInt32, _ at: Int) {
        for index in 0..<4 { bytes[at + index] = UInt8((value >> (8 * UInt32(index))) & 0xFF) }
    }
    put16(magic, 0x38)
    put16(state, 0x3A)
    put16(1, 0x3C)
    put32(compat, 0x5C)
    put32(incompat, 0x60)
    put32(errorCount, 0x194)
    return Data(bytes)
}

/// Write a small image file (1024 zero bytes + superblock region) and return its path.
func makeSyntheticExt4Image(_ superblock: Data) throws -> String {
    let url = StateDirectories.temporaryDirectory()
        .appendingPathComponent("vh-\(UUID().uuidString).img")
    try (Data(count: 1024) + superblock).write(to: url)
    return url.path
}

/// Mock handler answering `volume inspect <name>` with the given image path.
func volumeInspectHandler(_ images: [String: String]) -> ([String]) -> ProcessResult? {
    { args in
        guard args.count == 3, args.starts(with: ["volume", "inspect"]),
              let path = images[args[2]] else { return nil }
        let payload: [[String: Any]] = [["name": args[2], "source": path, "format": "ext4"]]
        return ProcessResult(
            exitCode: 0,
            stdout: try! JSONSerialization.data(withJSONObject: payload),
            stderr: Data()
        )
    }
}

/// `list --all` entry for a container that mounts `volume`.
func containerListEntryMounting(volume: String, id: String, state: String) -> [String: Any] {
    [
        "id": id,
        "configuration": [
            "id": id,
            "labels": [:] as [String: String],
            "image": ["reference": "alpine:3.20"],
            "mounts": [[
                "source": "/volumes/\(volume)/volume.img",
                "destination": "/data",
                "options": [],
                "type": ["volume": ["name": volume]]
            ]]
        ] as [String: Any],
        "status": ["state": state]
    ]
}

private func captureWarnings(_ body: () throws -> Void) rethrows -> [String] {
    let previous = StatusPrinter.onWarning
    var warnings: [String] = []
    StatusPrinter.onWarning = { warnings.append($0) }
    defer { StatusPrinter.onWarning = previous }
    try body()
    return warnings
}

private func gateRuntime(
    images: [String: String],
    listEntries: [[String: Any]] = []
) -> (AppleContainerRuntime, MockProcessRunner) {
    let mock = MockProcessRunner()
    mock.handlers = [
        { args in
            guard args.starts(with: ["list"]) else { return nil }
            return ProcessResult(
                exitCode: 0,
                stdout: try! JSONSerialization.data(withJSONObject: listEntries),
                stderr: Data()
            )
        },
        volumeInspectHandler(images)
    ]
    return (AppleContainerRuntime(executablePath: "container", runner: mock), mock)
}

nonisolated(unsafe) let volumeHealthTests: [(String, () throws -> Void)] = [
    ("ext4SuperblockCleanWithJournalIsHealthy", {
        let parsed = Ext4Superblock.parse(syntheticExt4Superblock())
        try MiniTest.expect(parsed != nil)
        try MiniTest.expect(parsed!.isCleanlyUnmounted)
        try MiniTest.expect(parsed!.hasJournal)
        try MiniTest.expect(!parsed!.needsRecovery)
        try MiniTest.expectEqual(VolumeHealth.verdict(for: parsed!), .healthy)
    }),

    ("ext4SuperblockNotCleanWithoutJournalIsUnclean", {
        let parsed = Ext4Superblock.parse(syntheticExt4Superblock(state: 0, compat: 0))!
        try MiniTest.expect(!parsed.isCleanlyUnmounted)
        try MiniTest.expect(!parsed.hasJournal)
        try MiniTest.expectEqual(VolumeHealth.verdict(for: parsed), .unclean)
        // A journaled filesystem replays on mount; not clean alone is not a warning.
        let journaled = Ext4Superblock.parse(syntheticExt4Superblock(state: 0, incompat: 0x0004))!
        try MiniTest.expect(journaled.needsRecovery)
        try MiniTest.expectEqual(VolumeHealth.verdict(for: journaled), .healthy)
    }),

    ("ext4SuperblockErrorsAreCorrupt", {
        let counted = Ext4Superblock.parse(syntheticExt4Superblock(errorCount: 3, compat: 0))!
        try MiniTest.expectEqual(counted.errorCount, 3)
        try MiniTest.expectEqual(VolumeHealth.verdict(for: counted), .corrupt)
        let flagged = Ext4Superblock.parse(syntheticExt4Superblock(state: 0x0003))!
        try MiniTest.expect(flagged.hasErrorFlag)
        try MiniTest.expectEqual(VolumeHealth.verdict(for: flagged), .corrupt)
    }),

    ("ext4SuperblockRejectsBadMagicAndShortInput", {
        try MiniTest.expect(Ext4Superblock.parse(syntheticExt4Superblock(magic: 0x1234)) == nil)
        try MiniTest.expect(Ext4Superblock.parse(syntheticExt4Superblock().prefix(0x100)) == nil)
        try MiniTest.expect(Ext4Superblock.parse(Data()) == nil)
        let short = StateDirectories.temporaryDirectory().appendingPathComponent("vh-short-\(UUID().uuidString).img")
        try Data(count: 1500).write(to: short)
        try MiniTest.expect(Ext4Superblock.read(imagePath: short.path) == nil, "short file is unreadable")
        try MiniTest.expect(Ext4Superblock.read(imagePath: short.path + ".missing") == nil)
        let good = try makeSyntheticExt4Image(syntheticExt4Superblock(errorCount: 2))
        try MiniTest.expectEqual(Ext4Superblock.read(imagePath: good)?.errorCount, 2)
    }),

    ("volumeHealthGateRefusesCorruptVolume", {
        let image = try makeSyntheticExt4Image(syntheticExt4Superblock(errorCount: 5))
        let (runtime, _) = gateRuntime(images: ["data-vol": image])
        try MiniTest.expectThrows({
            try VolumeHealth.gate(volumes: ["data-vol"], runtime: runtime)
        }) { error in
            let cli = error as? CLIError
            try MiniTest.expectEqual(cli?.code, CLIErrorCode.volumeCorrupt)
            try MiniTest.expect(cli?.message.contains("'data-vol'") == true)
            try MiniTest.expect(cli?.hint?.contains("cp -c") == true)
            try MiniTest.expect(cli?.hint?.contains("e2fsck -fy") == true)
            try MiniTest.expect(cli?.hint?.contains("tune2fs -O has_journal -c -1 -i 0") == true)
        }
    }),

    ("volumeHealthGateWarnsOnUncleanUnjournaledVolume", {
        let image = try makeSyntheticExt4Image(syntheticExt4Superblock(state: 0, compat: 0))
        let (runtime, _) = gateRuntime(images: ["data-vol": image])
        let warnings = try captureWarnings {
            try VolumeHealth.gate(volumes: ["data-vol", "data-vol"], runtime: runtime)
        }
        try MiniTest.expectEqual(warnings.count, 1, "not clean + no journal is one combined warning")
        try MiniTest.expect(warnings[0].contains("'data-vol'"))
        try MiniTest.expect(warnings[0].contains("not cleanly unmounted"))
        try MiniTest.expect(warnings[0].contains("e2fsck -fy"))
        try MiniTest.expect(warnings[0].contains("tune2fs -O has_journal -c -1 -i 0"))
    }),

    ("volumeHealthGateWarnsOnCleanVolumeWithoutJournal", {
        let parsed = Ext4Superblock.parse(syntheticExt4Superblock(compat: 0))!
        try MiniTest.expectEqual(VolumeHealth.verdict(for: parsed), .unjournaled)
        let image = try makeSyntheticExt4Image(syntheticExt4Superblock(compat: 0))
        let (runtime, _) = gateRuntime(images: ["data-vol": image])
        let warnings = try captureWarnings {
            try VolumeHealth.gate(volumes: ["data-vol"], runtime: runtime)
        }
        try MiniTest.expectEqual(warnings.count, 1)
        let warning = warnings[0]
        try MiniTest.expect(warning.contains("'data-vol'") && warning.contains("no ext4 journal"))
        try MiniTest.expect(!warning.contains("not cleanly unmounted"))
        for step in ["cp -c", "e2fsck -fy <volume.img>", "tune2fs -O has_journal -c -1 -i 0 <volume.img>", "brew install e2fsprogs"] {
            try MiniTest.expect(warning.contains(step), "migration step: \(step)")
        }
    }),

    ("volumeHealthGateSharedWarnedSetSuppressesRepeatsButNotRefusal", {
        let unjournaled = try makeSyntheticExt4Image(syntheticExt4Superblock(compat: 0))
        let corrupt = try makeSyntheticExt4Image(syntheticExt4Superblock(errorCount: 1))
        let (runtime, _) = gateRuntime(images: ["data-vol": unjournaled, "bad-vol": corrupt])
        var warned: Set<String> = []
        let warnings = try captureWarnings {
            try VolumeHealth.gate(volumes: ["data-vol"], runtime: runtime, warned: &warned)
            try VolumeHealth.gate(volumes: ["data-vol"], runtime: runtime, warned: &warned)
        }
        try MiniTest.expectEqual(warnings.count, 1)
        for _ in 0..<2 {
            try MiniTest.expectThrows({
                try VolumeHealth.gate(volumes: ["bad-vol"], runtime: runtime, warned: &warned)
            }) { error in
                try MiniTest.expectEqual((error as? CLIError)?.code, CLIErrorCode.volumeCorrupt)
            }
        }
    }),

    ("volumeHealthGateIsSilentOnCleanJournaledVolume", {
        let image = try makeSyntheticExt4Image(syntheticExt4Superblock())
        let (runtime, _) = gateRuntime(images: ["data-vol": image])
        let warnings = try captureWarnings {
            try VolumeHealth.gate(volumes: ["data-vol"], runtime: runtime)
        }
        try MiniTest.expect(warnings.isEmpty)
    }),

    ("volumeHealthGateSkipsInUseOrUnreadableVolumes", {
        let corrupt = try makeSyntheticExt4Image(syntheticExt4Superblock(errorCount: 1))
        let (inUse, inUseMock) = gateRuntime(
            images: ["data-vol": corrupt],
            listEntries: [containerListEntryMounting(volume: "data-vol", id: "other", state: "running")]
        )
        let warnings = try captureWarnings {
            try VolumeHealth.gate(volumes: ["data-vol"], runtime: inUse)
        }
        try MiniTest.expect(warnings.isEmpty)
        try MiniTest.expect(
            !inUseMock.calls.contains { $0.arguments.starts(with: ["volume", "inspect"]) },
            "a volume mounted by a running container is not inspected"
        )

        // A stopped container referencing the volume does not mount it.
        let (stopped, _) = gateRuntime(
            images: ["data-vol": corrupt],
            listEntries: [containerListEntryMounting(volume: "data-vol", id: "other", state: "stopped")]
        )
        try MiniTest.expectThrows({ try VolumeHealth.gate(volumes: ["data-vol"], runtime: stopped) }) { error in
            try MiniTest.expectEqual((error as? CLIError)?.code, CLIErrorCode.volumeCorrupt)
        }

        // Inspect failure, missing image, or a non-ext4 image: skip silently.
        let (noInspect, _) = gateRuntime(images: [:])
        try VolumeHealth.gate(volumes: ["data-vol"], runtime: noInspect)
        let (missing, _) = gateRuntime(images: ["data-vol": corrupt + ".missing"])
        try VolumeHealth.gate(volumes: ["data-vol"], runtime: missing)
        let notExt4 = try makeSyntheticExt4Image(syntheticExt4Superblock(magic: 0))
        let (badMagic, _) = gateRuntime(images: ["data-vol": notExt4])
        try VolumeHealth.gate(volumes: ["data-vol"], runtime: badMagic)
    }),

    ("volumeCreateRequestsJournal", {
        let mock = MockProcessRunner()
        mock.handlers = [{ args in
            if args.starts(with: ["volume", "list"]) {
                return ProcessResult(exitCode: 0, stdout: Data("[]".utf8), stderr: Data())
            }
            return nil
        }]
        let runtime = AppleContainerRuntime(executablePath: "container", runner: mock)
        try MiniTest.expect(try runtime.ensureVolume(name: "fresh-vol"))
        try MiniTest.expect(
            mock.calls.contains { $0.arguments == ["volume", "create", "--opt", "journal=ordered", "fresh-vol"] },
            "new volumes are created with an ext4 journal"
        )
    }),
]
