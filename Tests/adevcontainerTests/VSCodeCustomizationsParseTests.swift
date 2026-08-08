import Foundation
@testable import ADevContainerLib

nonisolated(unsafe) let vscodeCustomizationsParseTests: [(String, () throws -> Void)] = [
    ("vscodeParseWellformedExtensionsAndSettingsRetained", {
        let ws = try TestRepo.makeTempWorkspace(configJSON: """
        {
          "image": "alpine:3.20",
          "customizations": {
            "vscode": {
              "extensions": [" swiftlang.swift-vscode ", "ms-python.python"],
              "settings": { "editor.formatOnSave": true, "files.eol": "\\n" }
            }
          }
        }
        """)
        defer { try? FileManager.default.removeItem(at: ws) }
        let resolved = try ConfigResolver.resolve(workspacePath: ws.path, localEnv: [:])
        try MiniTest.expect(resolved.config.hasVscodeCustomizations)
        try MiniTest.expectEqual(resolved.config.vscodeExtensions, [
            "swiftlang.swift-vscode",
            "ms-python.python"
        ])
        let settings = try JSONSerialization.jsonObject(with: resolved.config.vscodeSettingsJSON) as! [String: Any]
        try MiniTest.expectEqual(settings["editor.formatOnSave"] as? Bool, true)
        try MiniTest.expectEqual(settings["files.eol"] as? String, "\n")
        try MiniTest.expect(resolved.config.hasApplyableVscodeCustomizations)
    }),

    ("vscodeParseMalformedNestedExtensionsDoesNotFailResolve", {
        let ws = try TestRepo.makeTempWorkspace(configJSON: """
        {
          "image": "alpine:3.20",
          "customizations": {
            "vscode": {
              "extensions": "not-an-array",
              "settings": { "a": 1 }
            }
          }
        }
        """)
        defer { try? FileManager.default.removeItem(at: ws) }
        let resolved = try ConfigResolver.resolve(workspacePath: ws.path, localEnv: [:])
        try MiniTest.expect(resolved.config.hasVscodeCustomizations)
        try MiniTest.expectEqual(resolved.config.vscodeExtensions, [])
        let settings = try JSONSerialization.jsonObject(with: resolved.config.vscodeSettingsJSON) as! [String: Any]
        try MiniTest.expectEqual(settings["a"] as? Int, 1)
    }),

    ("vscodeParseMalformedNestedSettingsDoesNotFailResolve", {
        let ws = try TestRepo.makeTempWorkspace(configJSON: """
        {
          "image": "alpine:3.20",
          "customizations": {
            "vscode": {
              "extensions": ["ms-python.python"],
              "settings": ["not", "object"]
            }
          }
        }
        """)
        defer { try? FileManager.default.removeItem(at: ws) }
        let resolved = try ConfigResolver.resolve(workspacePath: ws.path, localEnv: [:])
        try MiniTest.expect(resolved.config.hasVscodeCustomizations)
        try MiniTest.expectEqual(resolved.config.vscodeExtensions, ["ms-python.python"])
        try MiniTest.expect(!ResolvedDevContainerConfig.settingsObjectHasKeys(resolved.config.vscodeSettingsJSON))
    }),

    ("vscodeParseEmptyOrAbsentNoApplyPayload", {
        let absent = try TestRepo.makeTempWorkspace(configJSON: #"{ "image": "alpine:3.20" }"#)
        defer { try? FileManager.default.removeItem(at: absent) }
        let r1 = try ConfigResolver.resolve(workspacePath: absent.path, localEnv: [:])
        try MiniTest.expect(!r1.config.hasVscodeCustomizations)
        try MiniTest.expectEqual(r1.config.vscodeExtensions, [])
        try MiniTest.expect(!r1.config.hasApplyableVscodeCustomizations)

        let empty = try TestRepo.makeTempWorkspace(configJSON: """
        {
          "image": "alpine:3.20",
          "customizations": { "vscode": { "extensions": [], "settings": {} } }
        }
        """)
        defer { try? FileManager.default.removeItem(at: empty) }
        let r2 = try ConfigResolver.resolve(workspacePath: empty.path, localEnv: [:])
        try MiniTest.expect(r2.config.hasVscodeCustomizations)
        try MiniTest.expect(!r2.config.hasApplyableVscodeCustomizations)

        let noVscode = try TestRepo.makeTempWorkspace(configJSON: """
        { "image": "alpine:3.20", "customizations": { "codespaces": {} } }
        """)
        defer { try? FileManager.default.removeItem(at: noVscode) }
        let r3 = try ConfigResolver.resolve(workspacePath: noVscode.path, localEnv: [:])
        try MiniTest.expect(!r3.config.hasVscodeCustomizations)
        try MiniTest.expect(!r3.config.hasApplyableVscodeCustomizations)
    }),

    ("vscodeCustomizationsOutsideIdentityHash", {
        // Same workspaceFolder basename so default folder does not confound identity.
        let base = FileManager.default.temporaryDirectory
            .appendingPathComponent("adev-hash-ws-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: base) }
        try FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)

        func writeConfig(_ json: String, name: String) throws -> URL {
            let ws = base.appendingPathComponent(name, isDirectory: true)
            let dc = ws.appendingPathComponent(".devcontainer", isDirectory: true)
            try FileManager.default.createDirectory(at: dc, withIntermediateDirectories: true)
            try json.write(
                to: dc.appendingPathComponent("devcontainer.json"),
                atomically: true,
                encoding: .utf8
            )
            return ws
        }

        let wsA = try writeConfig("""
        {
          "image": "alpine:3.20",
          "workspaceFolder": "/workspaces/app",
          "customizations": {
            "vscode": {
              "extensions": ["a.b"],
              "settings": { "x": 1 }
            }
          }
        }
        """, name: "a")
        let wsB = try writeConfig("""
        {
          "image": "alpine:3.20",
          "workspaceFolder": "/workspaces/app",
          "customizations": {
            "vscode": {
              "extensions": ["c.d", "e.f"],
              "settings": { "y": 2 }
            }
          }
        }
        """, name: "b")
        let a = try ConfigResolver.resolve(workspacePath: wsA.path, localEnv: [:])
        let b = try ConfigResolver.resolve(workspacePath: wsB.path, localEnv: [:])
        try MiniTest.expectEqual(
            ContainerIdentity.configHash(from: a.config.hashMaterial()),
            ContainerIdentity.configHash(from: b.config.hashMaterial())
        )
        try MiniTest.expect(a.config.vscodeExtensions != b.config.vscodeExtensions)
        // Material must not contain customizations keys
        let material = a.config.hashMaterial()
        try MiniTest.expect(material["vscodeExtensions"] == nil)
        try MiniTest.expect(material["customizations"] == nil)
        try MiniTest.expect(material["hasVscodeCustomizations"] == nil)
    }),

    ("vscodeNonObjectCustomizationsStillFails", {
        let ws = try TestRepo.makeTempWorkspace(configJSON: """
        { "image": "alpine:3.20", "customizations": ["nope"] }
        """)
        defer { try? FileManager.default.removeItem(at: ws) }
        try MiniTest.expectThrows({
            _ = try ConfigResolver.resolve(workspacePath: ws.path, localEnv: [:])
        }) { error in
            let err = error as! CLIError
            try MiniTest.expectEqual(err.property, "customizations")
        }
    }),

    ("vscodeNonObjectVscodeSoftSkipsApply", {
        let ws = try TestRepo.makeTempWorkspace(configJSON: """
        {
          "image": "alpine:3.20",
          "customizations": { "vscode": "yes" }
        }
        """)
        defer { try? FileManager.default.removeItem(at: ws) }
        let resolved = try ConfigResolver.resolve(workspacePath: ws.path, localEnv: [:])
        try MiniTest.expect(resolved.config.hasVscodeCustomizations)
        try MiniTest.expect(!resolved.config.hasApplyableVscodeCustomizations)
    }),

    ("vscodeSkipNonStringExtensionEntries", {
        let ws = try TestRepo.makeTempWorkspace(configJSON: """
        {
          "image": "alpine:3.20",
          "customizations": {
            "vscode": {
              "extensions": ["ok.ext", 42, null, "  "]
            }
          }
        }
        """)
        defer { try? FileManager.default.removeItem(at: ws) }
        let resolved = try ConfigResolver.resolve(workspacePath: ws.path, localEnv: [:])
        try MiniTest.expectEqual(resolved.config.vscodeExtensions, ["ok.ext"])
    }),

    ("vscodeFixturesParse", {
        let root = TestRepo.root()
        for name in [
            "vscode-customizations-wellformed.json",
            "vscode-customizations-bad-nested.json",
            "vscode-customizations-empty.json"
        ] {
            let path = root.appendingPathComponent("Tests/Fixtures/\(name)").path
            let ws = FileManager.default.temporaryDirectory
                .appendingPathComponent("vsc-fix-\(UUID().uuidString)", isDirectory: true)
            let dc = ws.appendingPathComponent(".devcontainer", isDirectory: true)
            try FileManager.default.createDirectory(at: dc, withIntermediateDirectories: true)
            try Data(contentsOf: URL(fileURLWithPath: path))
                .write(to: dc.appendingPathComponent("devcontainer.json"))
            defer { try? FileManager.default.removeItem(at: ws) }
            let resolved = try ConfigResolver.resolve(workspacePath: ws.path, localEnv: [:])
            try MiniTest.expect(!resolved.config.image.isEmpty, name)
        }
        let well = root.appendingPathComponent("Tests/Fixtures/vscode-customizations-wellformed.json")
        let ws = FileManager.default.temporaryDirectory
            .appendingPathComponent("vsc-well-\(UUID().uuidString)", isDirectory: true)
        let dc = ws.appendingPathComponent(".devcontainer", isDirectory: true)
        try FileManager.default.createDirectory(at: dc, withIntermediateDirectories: true)
        try Data(contentsOf: well).write(to: dc.appendingPathComponent("devcontainer.json"))
        defer { try? FileManager.default.removeItem(at: ws) }
        let r = try ConfigResolver.resolve(workspacePath: ws.path, localEnv: [:])
        try MiniTest.expectEqual(r.config.vscodeExtensions.count, 2)
        try MiniTest.expect(r.config.hasApplyableVscodeCustomizations)
    }),

    ("vscodePropertySurfaceAdmitsExtensionsAndSettings", {
        let raw: [String: Any] = [
            "image": "alpine:3.20",
            "customizations": [
                "vscode": [
                    "extensions": ["swiftlang.swift-vscode"],
                    "settings": ["editor.tabSize": 2]
                ] as [String: Any]
            ]
        ]
        try ConfigAdmissions.admit(raw)
        let ws = try TestRepo.makeTempWorkspace(configJSON: """
        {
          "image": "alpine:3.20",
          "customizations": {
            "vscode": {
              "extensions": ["swiftlang.swift-vscode"],
              "settings": { "editor.tabSize": 2 }
            }
          }
        }
        """)
        defer { try? FileManager.default.removeItem(at: ws) }
        let resolved = try ConfigResolver.resolve(workspacePath: ws.path, localEnv: [:])
        try MiniTest.expectEqual(resolved.config.vscodeExtensions, ["swiftlang.swift-vscode"])
        let s = try JSONSerialization.jsonObject(with: resolved.config.vscodeSettingsJSON) as! [String: Any]
        try MiniTest.expectEqual(s["editor.tabSize"] as? Int, 2)
    })
]
