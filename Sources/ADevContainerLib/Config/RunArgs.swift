import Foundation

/// Allowlisted `runArgs` entry after admission (normalized for create argv).
public enum AllowlistedRunArg: Equatable, Sendable {
    case initFlag
    case capAdd(String)
    case capDrop(String)
    case shmSize(String)
    case dns(String)
    case dnsSearch(String)
    case dnsOption(String)
    case dnsDomain(String)
    case noDns
    case ulimit(String)
    case tmpfs(String)
    /// Parsed from `--cpus`/`-c`; applied via CreateRequest memory/cpu merge (no createTokens).
    case cpus(String)
    /// Parsed from `--memory`/`-m`; applied via CreateRequest memory/cpu merge (no createTokens).
    case memory(String)
    case network(String)
    case rosetta
    case ssh
    case readOnly

    /// Tokens appended to `container create` argv.
    /// Memory/cpus intentionally empty — merged into `-m`/`-c` by `CreateRequest.from`.
    public var createTokens: [String] {
        switch self {
        case .initFlag:
            return ["--init"]
        case .capAdd(let name):
            return ["--cap-add", name]
        case .capDrop(let name):
            return ["--cap-drop", name]
        case .shmSize(let size):
            return ["--shm-size", size]
        case .dns(let ip):
            return ["--dns", ip]
        case .dnsSearch(let val):
            return ["--dns-search", val]
        case .dnsOption(let val):
            return ["--dns-option", val]
        case .dnsDomain(let val):
            return ["--dns-domain", val]
        case .noDns:
            return ["--no-dns"]
        case .ulimit(let val):
            return ["--ulimit", val]
        case .tmpfs(let path):
            return ["--tmpfs", path]
        case .cpus, .memory:
            return []
        case .network(let name):
            return ["--network", name]
        case .rosetta:
            return ["--rosetta"]
        case .ssh:
            return ["--ssh"]
        case .readOnly:
            return ["--read-only"]
        }
    }

    /// Stable encoding for config hash material.
    public var hashEncoding: String {
        switch self {
        case .initFlag: return "--init"
        case .capAdd(let n): return "--cap-add=\(n)"
        case .capDrop(let n): return "--cap-drop=\(n)"
        case .shmSize(let s): return "--shm-size=\(s)"
        case .dns(let s): return "--dns=\(s)"
        case .dnsSearch(let s): return "--dns-search=\(s)"
        case .dnsOption(let s): return "--dns-option=\(s)"
        case .dnsDomain(let s): return "--dns-domain=\(s)"
        case .noDns: return "--no-dns"
        case .ulimit(let s): return "--ulimit=\(s)"
        case .tmpfs(let s): return "--tmpfs=\(s)"
        case .cpus(let s): return "--cpus=\(s)"
        case .memory(let s): return "--memory=\(s)"
        case .network(let s): return "--network=\(s)"
        case .rosetta: return "--rosetta"
        case .ssh: return "--ssh"
        case .readOnly: return "--read-only"
        }
    }
}

/// Parse and admit `runArgs` against the runArgs allowlist.
public enum RunArgsAdmission {
    private static let allowlistHint =
        "runArgs allowlist: --init, --cap-add, --cap-drop, --shm-size, --dns, --dns-search, "
        + "--dns-option, --dns-domain, --no-dns, --ulimit, --tmpfs, --cpus/-c, --memory/-m, "
        + "--network (named only), --rosetta, --ssh, --read-only"

    /// Parse `runArgs` array. Omitted/`nil` → empty. Empty array → empty.
    /// - Parameter emitWarnings: When false, still skip Apple-incompatible entries but do not warn
    ///   (used by pre-resolve admission so resolve emits each skip warning once).
    public static func parse(_ value: Any?, emitWarnings: Bool = true) throws -> [AllowlistedRunArg] {
        guard let value else { return [] }
        guard let items = value as? [Any] else {
            throw CLIError(
                code: CLIErrorCode.unsupportedProperty,
                property: "runArgs",
                message: "runArgs must be an array of strings"
            )
        }

        var result: [AllowlistedRunArg] = []
        var sawInit = false
        var sawNoDns = false
        var sawRosetta = false
        var sawSsh = false
        var sawReadOnly = false
        var skippedPrivilegedOrDevice = false
        var index = 0
        while index < items.count {
            guard let arg = items[index] as? String else {
                throw CLIError(
                    code: CLIErrorCode.unsupportedProperty,
                    property: "runArgs",
                    message: "runArgs entries must be strings"
                )
            }

            // --- Apple-incompatible flags: warn + skip (do not apply) ---
            if arg == "--privileged" || arg.hasPrefix("--privileged=") {
                skippedPrivilegedOrDevice = true
                if emitWarnings {
                    StatusPrinter.warning(
                        "runArgs entry '--privileged' is incompatible with Apple container; ignored"
                    )
                }
                index += 1
                continue
            }
            if isDeviceArg(arg) || arg == "--device" {
                skippedPrivilegedOrDevice = true
                let display = arg == "--device" ? "--device" : arg
                if emitWarnings {
                    StatusPrinter.warning(
                        "runArgs entry '\(display)' is incompatible with Apple container (no device passthrough); ignored"
                    )
                }
                index = advancePastOptionalValue(items: items, index: index, bareFlag: arg == "--device")
                continue
            }
            if let rejected = incompatibleSkippedFlag(arg) {
                if emitWarnings {
                    StatusPrinter.warning(
                        "runArgs entry '\(rejected.display)' is incompatible with Apple container; ignored"
                    )
                }
                index = advancePastOptionalValue(
                    items: items,
                    index: index,
                    bareFlag: arg == rejected.prefix
                )
                continue
            }

            // --- Boolean flags ---
            if arg == "--init" {
                if !sawInit {
                    result.append(.initFlag)
                    sawInit = true
                }
                index += 1
                continue
            }
            if arg == "--no-dns" {
                if !sawNoDns {
                    result.append(.noDns)
                    sawNoDns = true
                }
                index += 1
                continue
            }
            if arg == "--rosetta" {
                if !sawRosetta {
                    result.append(.rosetta)
                    sawRosetta = true
                }
                index += 1
                continue
            }
            if arg == "--ssh" {
                if !sawSsh {
                    result.append(.ssh)
                    sawSsh = true
                }
                index += 1
                continue
            }
            if arg == "--read-only" {
                if !sawReadOnly {
                    result.append(.readOnly)
                    sawReadOnly = true
                }
                index += 1
                continue
            }

            // --- Valued flags ---
            if let (name, nextIndex) = try takeValue("--cap-add", items: items, index: index) {
                guard isValidCapabilityName(name) else {
                    throw invalidValue(flag: "--cap-add", value: name, arg: arg)
                }
                result.append(.capAdd(name))
                index = nextIndex
                continue
            }

            if let (name, nextIndex) = try takeValue("--cap-drop", items: items, index: index) {
                guard isValidCapabilityName(name) else {
                    throw invalidValue(flag: "--cap-drop", value: name, arg: arg)
                }
                result.append(.capDrop(name))
                index = nextIndex
                continue
            }

            if let (size, nextIndex) = try takeValue("--shm-size", items: items, index: index) {
                guard isNonEmptyValue(size) else {
                    throw invalidValue(flag: "--shm-size", value: size, arg: arg)
                }
                result.append(.shmSize(size))
                index = nextIndex
                continue
            }

            if let (ip, nextIndex) = try takeValue("--dns", items: items, index: index) {
                guard isNonEmptyValue(ip) else {
                    throw invalidValue(flag: "--dns", value: ip, arg: arg)
                }
                result.append(.dns(ip))
                index = nextIndex
                continue
            }

            if let (val, nextIndex) = try takeValue("--dns-search", items: items, index: index) {
                guard isNonEmptyValue(val) else {
                    throw invalidValue(flag: "--dns-search", value: val, arg: arg)
                }
                result.append(.dnsSearch(val))
                index = nextIndex
                continue
            }

            if let (val, nextIndex) = try takeValue("--dns-option", items: items, index: index) {
                guard isNonEmptyValue(val) else {
                    throw invalidValue(flag: "--dns-option", value: val, arg: arg)
                }
                result.append(.dnsOption(val))
                index = nextIndex
                continue
            }

            if let (val, nextIndex) = try takeValue("--dns-domain", items: items, index: index) {
                guard isNonEmptyValue(val) else {
                    throw invalidValue(flag: "--dns-domain", value: val, arg: arg)
                }
                result.append(.dnsDomain(val))
                index = nextIndex
                continue
            }

            if let (val, nextIndex) = try takeValue("--ulimit", items: items, index: index) {
                guard isNonEmptyValue(val) else {
                    throw invalidValue(flag: "--ulimit", value: val, arg: arg)
                }
                result.append(.ulimit(val))
                index = nextIndex
                continue
            }

            if let (raw, nextIndex) = try takeValue("--tmpfs", items: items, index: index) {
                // Strip Docker-style options after first ':'; path only.
                let path = tmpfsPath(from: raw)
                guard isNonEmptyValue(path) else {
                    throw invalidValue(flag: "--tmpfs", value: raw, arg: arg)
                }
                result.append(.tmpfs(path))
                index = nextIndex
                continue
            }

            if let (name, nextIndex) = try takeValue("--network", items: items, index: index) {
                if try shouldSkipDockerOnlyNetwork(name, displayArg: arg, emitWarnings: emitWarnings) {
                    index = nextIndex
                    continue
                }
                result.append(.network(name))
                index = nextIndex
                continue
            }

            // Memory / cpus — stored for CreateRequest merge; no createTokens.
            if let (size, nextIndex) = try takeValue("--memory", short: "-m", items: items, index: index) {
                guard isNonEmptyValue(size) else {
                    throw invalidValue(flag: "--memory", value: size, arg: arg)
                }
                result.append(.memory(size))
                index = nextIndex
                continue
            }

            if let (n, nextIndex) = try takeValue("--cpus", short: "-c", items: items, index: index) {
                guard isNonEmptyValue(n) else {
                    throw invalidValue(flag: "--cpus", value: n, arg: arg)
                }
                result.append(.cpus(n))
                index = nextIndex
                continue
            }

            // First-class props must not be smuggled via runArgs
            if isFirstClassOnlyFlag(arg) {
                throw CLIError(
                    code: CLIErrorCode.unsupportedProperty,
                    property: "runArgs",
                    message: "runArgs entry '\(arg)' collides with a first-class config property",
                    hint: "Use the dedicated devcontainer.json property instead of runArgs"
                )
            }

            throw CLIError(
                code: CLIErrorCode.unsupportedProperty,
                property: "runArgs",
                message: "runArgs entry '\(arg)' is not on the allowlist",
                hint: allowlistHint
            )
        }

        if emitWarnings, skippedPrivilegedOrDevice, result.contains(where: isNetAdminCapAdd) {
            StatusPrinter.warning(
                "cap-add NET_ADMIN alone does not provide device/privileged/VPN-in-container on Apple container (privileged/device were skipped)"
            )
        }

        return result
    }

    private static func isNetAdminCapAdd(_ arg: AllowlistedRunArg) -> Bool {
        if case .capAdd(let name) = arg {
            return name.uppercased() == "NET_ADMIN"
        }
        return false
    }

    // MARK: - takeValue

    /// Consume `=VALUE` or two-token forms for a long flag (and optional short alias).
    /// Returns `(value, nextIndex)` when the current item matches; `nil` if flag does not match.
    private static func takeValue(
        _ longFlag: String,
        short: String? = nil,
        items: [Any],
        index: Int
    ) throws -> (String, Int)? {
        guard let arg = items[index] as? String else { return nil }

        let eqPrefix = longFlag + "="
        if arg.hasPrefix(eqPrefix) {
            return (String(arg.dropFirst(eqPrefix.count)), index + 1)
        }

        if arg == longFlag || (short != nil && arg == short) {
            guard index + 1 < items.count else {
                throw CLIError(
                    code: CLIErrorCode.unsupportedProperty,
                    property: "runArgs",
                    message: "runArgs entry '\(longFlag)' is incomplete (missing value)",
                    hint: "Provide a value after \(longFlag)"
                )
            }
            guard let value = items[index + 1] as? String else {
                throw CLIError(
                    code: CLIErrorCode.unsupportedProperty,
                    property: "runArgs",
                    message: "runArgs entries must be strings"
                )
            }
            if value.hasPrefix("-") {
                throw CLIError(
                    code: CLIErrorCode.unsupportedProperty,
                    property: "runArgs",
                    message: "runArgs entry '\(longFlag)' is incomplete (missing value)",
                    hint: "Provide a value after \(longFlag) that does not start with '-'"
                )
            }
            return (value, index + 2)
        }

        return nil
    }

    // MARK: - Validation helpers

    private static func isDeviceArg(_ arg: String) -> Bool {
        arg.hasPrefix("--device=") || arg.hasPrefix("--device ")
    }

    private static func isValidCapabilityName(_ name: String) -> Bool {
        !name.isEmpty && !name.hasPrefix("-")
    }

    private static func isNonEmptyValue(_ value: String) -> Bool {
        !value.isEmpty && !value.hasPrefix("-")
    }

    private static func tmpfsPath(from raw: String) -> String {
        if let colon = raw.firstIndex(of: ":") {
            return String(raw[..<colon])
        }
        return raw
    }

    /// Returns true when the network mode was warn-skipped. Empty name still hard-errors.
    private static func shouldSkipDockerOnlyNetwork(
        _ name: String,
        displayArg: String,
        emitWarnings: Bool
    ) throws -> Bool {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            throw CLIError(
                code: CLIErrorCode.unsupportedProperty,
                property: "runArgs",
                message: "runArgs entry '\(displayArg)' has an empty network name",
                hint: "Use a named network only (not host/bridge/none/container:*)"
            )
        }
        let lower = trimmed.lowercased()
        if lower == "host" || lower == "bridge" || lower == "none" || lower.hasPrefix("container:") {
            if emitWarnings {
                StatusPrinter.warning(
                    "runArgs network mode '\(trimmed)' is incompatible with Apple container; ignored (use a named network)"
                )
            }
            return true
        }
        return false
    }

    /// After a bare flag token, skip the following value token when present.
    private static func advancePastOptionalValue(items: [Any], index: Int, bareFlag: Bool) -> Int {
        guard bareFlag, index + 1 < items.count else { return index + 1 }
        guard let next = items[index + 1] as? String, !next.hasPrefix("-") else {
            return index + 1
        }
        return index + 2
    }

    private static func isFirstClassOnlyFlag(_ arg: String) -> Bool {
        let firstClass: [String] = [
            "-e", "--env", "-u", "--user", "-w", "--workdir", "-p", "--publish",
            "-v", "--volume", "--mount", "--name", "--label", "-l",
            "-i", "--interactive", "-t", "--tty", "-d", "--detach",
            "--rm", "--entrypoint"
        ]
        for flag in firstClass {
            if arg == flag || arg.hasPrefix(flag + "=") {
                return true
            }
        }
        return false
    }

    /// Known Apple-incompatible flags (beyond privileged/device handled above) → warn-skip.
    private static func incompatibleSkippedFlag(_ arg: String) -> (prefix: String, display: String)? {
        let prefixes = [
            "--security-opt",
            "--gpus",
            "--ipc",
            "--pid",
            "--userns",
            "--cgroupns",
            "--hostname",
            "--add-host",
            "--sysctl",
            "--group-add",
            "--runtime",
        ]
        for prefix in prefixes {
            if arg == prefix || arg.hasPrefix(prefix + "=") {
                return (prefix, prefix)
            }
        }
        return nil
    }

    private static func invalidValue(flag: String, value: String, arg: String) -> CLIError {
        if value.isEmpty {
            return CLIError(
                code: CLIErrorCode.unsupportedProperty,
                property: "runArgs",
                message: "runArgs entry '\(arg)' has an empty or invalid value",
                hint: "Use \(flag)=VALUE or \(flag) VALUE with a non-empty token"
            )
        }
        return CLIError(
            code: CLIErrorCode.unsupportedProperty,
            property: "runArgs",
            message: "runArgs entry '\(flag) \(value)' has an empty or invalid value"
        )
    }
}
