import Foundation

/// Parsed `hostRequirements` from devcontainer.json.
public struct HostRequirements: Equatable, Sendable {
    /// Required memory in bytes when `memory` was set.
    public var memoryBytes: UInt64?
    /// Original memory string for warnings (e.g. `"8gb"`).
    public var memoryRaw: String?
    /// Required CPU count when `cpus` was set.
    public var cpus: Double?
    /// Original cpus display for warnings.
    public var cpusRaw: String?
    /// True when `gpu` key was present (any value).
    public var gpuPresent: Bool

    public init(
        memoryBytes: UInt64? = nil,
        memoryRaw: String? = nil,
        cpus: Double? = nil,
        cpusRaw: String? = nil,
        gpuPresent: Bool = false
    ) {
        self.memoryBytes = memoryBytes
        self.memoryRaw = memoryRaw
        self.cpus = cpus
        self.cpusRaw = cpusRaw
        self.gpuPresent = gpuPresent
    }

    public var isEmpty: Bool {
        memoryBytes == nil && cpus == nil && !gpuPresent
    }

    /// Parse `hostRequirements` object. Returns `nil` when key is absent.
    public static func parse(_ value: Any?) throws -> HostRequirements? {
        guard let value else { return nil }
        guard let dict = value as? [String: Any] else {
            throw CLIError(
                code: CLIErrorCode.unsupportedProperty,
                property: "hostRequirements",
                message: "hostRequirements must be an object",
                hint: "Use an object with memory, cpus, and/or gpu keys"
            )
        }

        var result = HostRequirements()
        let known: Set<String> = ["memory", "cpus", "gpu"]

        for key in dict.keys {
            if !known.contains(key) {
                throw CLIError(
                    code: CLIErrorCode.unsupportedProperty,
                    property: "hostRequirements.\(key)",
                    message: "Unknown hostRequirements key '\(key)'",
                    hint: "Supported keys: memory, cpus, gpu"
                )
            }
        }

        if let memoryVal = dict["memory"] {
            let raw: String
            if let s = memoryVal as? String {
                raw = s
            } else if let n = memoryVal as? NSNumber {
                raw = "\(n)"
            } else {
                throw CLIError(
                    code: CLIErrorCode.unsupportedProperty,
                    property: "hostRequirements.memory",
                    message: "hostRequirements.memory must be a size string (e.g. \"8gb\", \"8192mb\")"
                )
            }
            guard let bytes = parseMemoryBytes(raw) else {
                throw CLIError(
                    code: CLIErrorCode.unsupportedProperty,
                    property: "hostRequirements.memory",
                    message: "Unparseable hostRequirements.memory value '\(raw)'",
                    hint: "Use a size with unit gb/g or mb/m (e.g. \"8gb\", \"8192mb\")"
                )
            }
            result.memoryBytes = bytes
            result.memoryRaw = raw
        }

        if let cpusVal = dict["cpus"] {
            let (cpus, raw) = try parseCpus(cpusVal)
            result.cpus = cpus
            result.cpusRaw = raw
        }

        if dict["gpu"] != nil {
            result.gpuPresent = true
        }

        return result
    }

    /// Apple `container create -m` value from requested memory (e.g. `8gb` → `8G`).
    public var memoryCreateFlagValue: String? {
        guard memoryBytes != nil else { return nil }
        if let raw = memoryRaw {
            let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
            let units: [(suffix: String, apple: String)] = [
                ("gb", "G"), ("g", "G"), ("mb", "M"), ("m", "M")
            ]
            for unit in units {
                if trimmed.hasSuffix(unit.suffix) {
                    let numPart = String(trimmed.dropLast(unit.suffix.count))
                        .trimmingCharacters(in: .whitespaces)
                    guard let value = Double(numPart), value > 0, value.isFinite else { break }
                    if value == floor(value), value <= Double(Int.max) {
                        return "\(Int(value))\(unit.apple)"
                    }
                    return "\(value)\(unit.apple)"
                }
            }
        }
        let mib = memoryBytes! / (1_024 * 1_024)
        return "\(max(mib, 1))M"
    }

    /// Apple `container create -c` value from requested cpus.
    public var cpuCreateFlagValue: String? {
        guard let cpus else { return nil }
        if cpus == floor(cpus), cpus <= Double(Int.max) {
            return "\(Int(cpus))"
        }
        return String(cpus)
    }

    /// Parse memory size strings: `8gb`, `8g`, `8192mb`, `8192m` (case-insensitive).
    public static func parseMemoryBytes(_ raw: String) -> UInt64? {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard !trimmed.isEmpty else { return nil }

        let units: [(suffix: String, multiplier: UInt64)] = [
            ("gb", 1_024 * 1_024 * 1_024),
            ("g", 1_024 * 1_024 * 1_024),
            ("mb", 1_024 * 1_024),
            ("m", 1_024 * 1_024)
        ]

        for unit in units {
            if trimmed.hasSuffix(unit.suffix) {
                let numPart = String(trimmed.dropLast(unit.suffix.count))
                    .trimmingCharacters(in: .whitespaces)
                guard let value = Double(numPart), value > 0, value.isFinite else { return nil }
                let bytes = value * Double(unit.multiplier)
                guard bytes <= Double(UInt64.max) else { return nil }
                return UInt64(bytes)
            }
        }
        return nil
    }

    private static func parseCpus(_ value: Any) throws -> (Double, String) {
        if let n = value as? NSNumber {
            let d = n.doubleValue
            guard d > 0, d.isFinite else {
                throw CLIError(
                    code: CLIErrorCode.unsupportedProperty,
                    property: "hostRequirements.cpus",
                    message: "hostRequirements.cpus must be a positive number"
                )
            }
            return (d, "\(n)")
        }
        if let s = value as? String {
            let trimmed = s.trimmingCharacters(in: .whitespacesAndNewlines)
            guard let d = Double(trimmed), d > 0, d.isFinite else {
                throw CLIError(
                    code: CLIErrorCode.unsupportedProperty,
                    property: "hostRequirements.cpus",
                    message: "Unparseable hostRequirements.cpus value '\(s)'",
                    hint: "Use a positive number or numeric string"
                )
            }
            return (d, trimmed)
        }
        throw CLIError(
            code: CLIErrorCode.unsupportedProperty,
            property: "hostRequirements.cpus",
            message: "hostRequirements.cpus must be a number or numeric string"
        )
    }
}

/// Result of comparing requirements against the host.
public struct HostRequirementsEvaluation: Equatable, Sendable {
    /// Capacity shortfall or unreadable host resources when memory/cpus are required.
    public var hardFailures: [String]
    /// Non-fatal notices (e.g. unsupported `gpu`).
    public var warnings: [String]

    public init(hardFailures: [String] = [], warnings: [String] = []) {
        self.hardFailures = hardFailures
        self.warnings = warnings
    }

    public var hasHardFailures: Bool { !hardFailures.isEmpty }

    public static func evaluate(
        _ requirements: HostRequirements?,
        host: any HostResourceProviding
    ) -> HostRequirementsEvaluation {
        guard let requirements, !requirements.isEmpty else {
            return HostRequirementsEvaluation()
        }

        var hardFailures: [String] = []
        var warnings: [String] = []

        if let needed = requirements.memoryBytes {
            if let available = host.physicalMemoryBytes {
                if available < needed {
                    let raw = requirements.memoryRaw ?? "\(needed) bytes"
                    hardFailures.append(
                        "hostRequirements.memory: host has less memory than required (\(raw))"
                    )
                }
            } else {
                hardFailures.append(
                    "hostRequirements.memory: could not read host memory; cannot verify requirement"
                )
            }
        }

        if let needed = requirements.cpus {
            if let available = host.cpuCount {
                if Double(available) < needed {
                    let raw = requirements.cpusRaw ?? "\(needed)"
                    hardFailures.append(
                        "hostRequirements.cpus: host has fewer CPUs than required (\(raw))"
                    )
                }
            } else {
                hardFailures.append(
                    "hostRequirements.cpus: could not read host CPU count; cannot verify requirement"
                )
            }
        }

        if requirements.gpuPresent {
            warnings.append(
                "hostRequirements.gpu: GPU host requirements are unsupported; ignoring"
            )
        }

        return HostRequirementsEvaluation(hardFailures: hardFailures, warnings: warnings)
    }

    /// Format warnings for stderr (volume-style `warning:` lines).
    public func warningMessage() -> String? {
        guard !warnings.isEmpty else { return nil }
        return warnings.map { "warning: \($0)" }.joined(separator: "\n")
    }
}
