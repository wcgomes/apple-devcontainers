import Foundation
#if canImport(Darwin)
import Darwin
#endif

/// Apple `container` user config: one-time consent to set `build.rosetta=false` for native arm64 Features builds.
///
/// Effective value is read via `container system property list`. Writes go only to the host config.toml
/// (`[build] rosetta = false`), preserving other keys/sections. Never installs Rosetta; never restores `true`.
public enum AppleContainerConfig {
    /// Env override: auto-accept disable without TTY prompt (CI / non-interactive).
    public static let allowDisableEnvKey = "ADEVCONTAINER_ALLOW_BUILD_ROSETTA_DISABLE"

    /// Canonical Apple container config path on macOS.
    public static func defaultConfigPath(home: String = NSHomeDirectory()) -> String {
        (home as NSString)
            .appendingPathComponent("Library/Application Support/com.apple.container/config/config.toml")
    }

    // MARK: - TOML helpers (minimal; only `[build]` / `rosetta`)

    /// Parse `build.rosetta` from TOML-ish text. `nil` when `[build]` or `rosetta` is absent.
    public static func parseBuildRosetta(from toml: String) -> Bool? {
        guard let sectionBody = buildSectionBody(from: toml) else { return nil }
        for rawLine in sectionBody.components(separatedBy: .newlines) {
            let line = stripComment(rawLine).trimmingCharacters(in: .whitespaces)
            guard !line.isEmpty else { continue }
            // rosetta = true|false (optional spaces)
            let parts = line.split(separator: "=", maxSplits: 1).map {
                $0.trimmingCharacters(in: .whitespaces)
            }
            guard parts.count == 2, parts[0] == "rosetta" else { continue }
            let value = parts[1].trimmingCharacters(in: CharacterSet(charactersIn: "\"'"))
            switch value.lowercased() {
            case "true": return true
            case "false": return false
            default: return nil
            }
        }
        return nil
    }

    /// Merge `rosetta = false` into `[build]`, creating the section if needed. Preserves other content.
    public static func mergeBuildRosettaFalse(into existing: String) -> String {
        let normalized = existing.replacingOccurrences(of: "\r\n", with: "\n")
        if let range = buildSectionRange(in: normalized) {
            let before = String(normalized[..<range.lowerBound])
            let section = String(normalized[range])
            let after = String(normalized[range.upperBound...])
            let updatedSection = rewriteRosettaFalse(inBuildSection: section)
            return before + updatedSection + after
        }
        // No [build] section — append.
        var out = normalized
        if !out.isEmpty && !out.hasSuffix("\n") {
            out += "\n"
        }
        return out + "[build]\nrosetta = false\n"
    }

    // MARK: - Ensure native arm64 builds

    public struct EnsureOptions: @unchecked Sendable {
        public var configPath: String
        public var environment: [String: String]
        public var isInteractive: Bool
        /// Returns one line of user input (without newline). Nil = EOF.
        public var readLine: () -> String?
        public var fileManager: FileManager

        public init(
            configPath: String = AppleContainerConfig.defaultConfigPath(),
            environment: [String: String] = ProcessInfo.processInfo.environment,
            isInteractive: Bool = AppleContainerConfig.stdinIsTTY(),
            readLine: @escaping () -> String? = {
                Swift.readLine(strippingNewline: true)
            },
            fileManager: FileManager = .default
        ) {
            self.configPath = configPath
            self.environment = environment
            self.isInteractive = isInteractive
            self.readLine = readLine
            self.fileManager = fileManager
        }
    }

    /// When Features need a BuildKit build: ensure effective `build.rosetta` is false.
    /// Already false → silent. Otherwise one-time confirm, write config, restart builder.
    public static func ensureNativeArmBuild(
        runtime: AppleContainerRuntime,
        options: EnsureOptions = EnsureOptions()
    ) throws {
        let effective = try readEffectiveBuildRosetta(runtime: runtime)
        if effective == false {
            return
        }

        // true or missing (treat missing as default true for BuildKit).
        try confirmDisableRosetta(options: options)

        StatusPrinter.status("Configuring native arm64 builds (build.rosetta=false)")

        try writeRosettaFalse(configPath: options.configPath, fileManager: options.fileManager)
        try restartBuilderForConfig(runtime: runtime)

        // Verify property took effect; escalate to system restart only if needed.
        let after = try? readEffectiveBuildRosetta(runtime: runtime)
        if after == false {
            return
        }

        StatusPrinter.status("Restarting Apple container services so build.rosetta takes effect")
        try runtime.systemStop()
        try runtime.systemStart()

        let final = try readEffectiveBuildRosetta(runtime: runtime)
        if final != false {
            throw CLIError(
                code: CLIErrorCode.buildRosettaConfig,
                property: "build.rosetta",
                message: "Wrote build.rosetta=false but effective property is still not false",
                hint: "Check \(options.configPath) and run `container system property list`; then retry `up`"
            )
        }
    }

    /// Read effective build.rosetta from `container system property list` (nil if key absent).
    public static func readEffectiveBuildRosetta(runtime: AppleContainerRuntime) throws -> Bool? {
        let toml = try runtime.systemPropertyList()
        return parseBuildRosetta(from: toml)
    }

    public static func stdinIsTTY() -> Bool {
        #if canImport(Darwin)
        return isatty(STDIN_FILENO) != 0
        #else
        return false
        #endif
    }

    // MARK: - Internals

    private static func confirmDisableRosetta(options: EnsureOptions) throws {
        let auto = options.environment[allowDisableEnvKey] == "1"
        if auto {
            return
        }

        let path = options.configPath
        let message = """
        Apple container BuildKit is configured with build.rosetta=true, which requires
        Rosetta even for native arm64 image builds and can fail when Rosetta is unavailable.

        adevcontainer will set build.rosetta=false in \(path)
        so feature image builds use native arm64 (closer to @devcontainers/cli behavior).

        Proceed? [Y/n]
        """

        if !options.isInteractive {
            throw CLIError(
                code: CLIErrorCode.buildRosettaConfig,
                property: "build.rosetta",
                message: "build.rosetta is true (or default true) but no TTY is available to confirm disabling it",
                hint: "Set build.rosetta=false in \(path), run interactively, or set \(allowDisableEnvKey)=1 to auto-accept"
            )
        }

        FileHandle.standardError.write(Data(message.utf8))
        // Prompt must be visible before readLine: FileHandle writes are unbuffered (no fflush needed).
        let line = options.readLine()?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        // Empty or Y/y → accept; n/N/no → decline
        let lowered = line.lowercased()
        if lowered.isEmpty || lowered == "y" || lowered == "yes" {
            return
        }
        throw CLIError(
            code: CLIErrorCode.buildRosettaConfig,
            property: "build.rosetta",
            message: "User declined setting build.rosetta=false; Features image builds require native arm64 BuildKit",
            hint: "Re-run and accept, or set build.rosetta=false in \(path) manually"
        )
    }

    private static func writeRosettaFalse(configPath: String, fileManager: FileManager) throws {
        let dir = (configPath as NSString).deletingLastPathComponent
        try fileManager.createDirectory(atPath: dir, withIntermediateDirectories: true)

        let existing: String
        if fileManager.fileExists(atPath: configPath) {
            existing = try String(contentsOfFile: configPath, encoding: .utf8)
        } else {
            existing = ""
        }
        let merged = mergeBuildRosettaFalse(into: existing)
        try merged.write(toFile: configPath, atomically: true, encoding: .utf8)
    }

    private static func restartBuilderForConfig(runtime: AppleContainerRuntime) throws {
        // Prefer builder restart so next build picks up property without full system bounce.
        try? runtime.builderStop()
        try? runtime.builderDelete(force: true)
    }

    // MARK: - TOML section parse

    private static func stripComment(_ line: String) -> String {
        if let idx = line.firstIndex(of: "#") {
            return String(line[..<idx])
        }
        return line
    }

    /// Body lines of `[build]` section (excluding the header), or nil if absent.
    private static func buildSectionBody(from toml: String) -> String? {
        guard let range = buildSectionRange(in: toml) else { return nil }
        let section = String(toml[range])
        // Drop first line (`[build]`)
        if let nl = section.firstIndex(of: "\n") {
            return String(section[section.index(after: nl)...])
        }
        return ""
    }

    /// Range covering `[build]` through the line before the next `[section]` (or EOF).
    private static func buildSectionRange(in toml: String) -> Range<String.Index>? {
        let lines = toml.split(separator: "\n", omittingEmptySubsequences: false)
        var startLine: Int?
        var endLine: Int = lines.count
        for (i, raw) in lines.enumerated() {
            let trimmed = raw.trimmingCharacters(in: .whitespaces)
            if trimmed == "[build]" {
                startLine = i
                continue
            }
            if startLine != nil, trimmed.hasPrefix("["), trimmed.hasSuffix("]"), trimmed != "[build]" {
                endLine = i
                break
            }
        }
        guard let startLine else { return nil }

        // Reconstruct character range from line indices.
        var idx = toml.startIndex
        var lineNum = 0
        var rangeStart: String.Index?
        var rangeEnd = toml.endIndex
        while idx < toml.endIndex {
            if lineNum == startLine { rangeStart = idx }
            if lineNum == endLine {
                rangeEnd = idx
                break
            }
            if toml[idx] == "\n" {
                lineNum += 1
            }
            idx = toml.index(after: idx)
        }
        if lineNum == endLine, rangeStart != nil, endLine == lines.count {
            rangeEnd = toml.endIndex
        }
        guard let rangeStart else { return nil }
        return rangeStart..<rangeEnd
    }

    private static func rewriteRosettaFalse(inBuildSection section: String) -> String {
        // section includes `[build]` header and following lines up to (not including) next section.
        var lines = section.split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
        guard !lines.isEmpty else {
            return "[build]\nrosetta = false\n"
        }
        var found = false
        for i in 1..<lines.count {
            let trimmed = stripComment(lines[i]).trimmingCharacters(in: .whitespaces)
            let parts = trimmed.split(separator: "=", maxSplits: 1).map {
                $0.trimmingCharacters(in: .whitespaces)
            }
            if parts.count == 2, parts[0] == "rosetta" {
                lines[i] = "rosetta = false"
                found = true
                break
            }
        }
        if !found {
            // Insert after [build] header
            lines.insert("rosetta = false", at: 1)
        }
        var out = lines.joined(separator: "\n")
        if !out.hasSuffix("\n") {
            out += "\n"
        }
        return out
    }
}
