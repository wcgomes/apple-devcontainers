import Foundation

public struct SubstitutionContext: Sendable {
    public var localWorkspaceFolder: String
    public var localWorkspaceFolderBasename: String
    public var containerWorkspaceFolder: String
    public var localEnv: [String: String]

    public init(
        localWorkspaceFolder: String,
        containerWorkspaceFolder: String,
        localEnv: [String: String] = ProcessInfo.processInfo.environment,
        localWorkspaceFolderBasename: String? = nil
    ) {
        let ws = (localWorkspaceFolder as NSString).standardizingPath
        self.localWorkspaceFolder = ws
        if let override = localWorkspaceFolderBasename, !override.isEmpty {
            self.localWorkspaceFolderBasename = override
        } else {
            self.localWorkspaceFolderBasename = (ws as NSString).lastPathComponent
        }
        self.containerWorkspaceFolder = containerWorkspaceFolder
        self.localEnv = localEnv
    }
}

public enum VariableSubstitutor {
    /// Match `${...}` tokens.
    private static let pattern = try! NSRegularExpression(
        pattern: #"\$\{([^}]+)\}"#,
        options: []
    )

    public static func substitute(_ input: String, context: SubstitutionContext) throws -> String {
        let ns = input as NSString
        let full = NSRange(location: 0, length: ns.length)
        let matches = pattern.matches(in: input, options: [], range: full)

        guard !matches.isEmpty else { return input }

        var result = input
        // Replace from end so ranges stay valid relative to original, rebuild carefully.
        // Use original ranges on `input`, apply to `result` which starts equal to input.
        for match in matches.reversed() {
            guard match.numberOfRanges >= 2,
                  let tokenRange = Range(match.range(at: 1), in: input),
                  let fullRange = Range(match.range(at: 0), in: result)
            else { continue }

            let token = String(input[tokenRange])
            let replacement = try resolve(token: token, context: context)
            result.replaceSubrange(fullRange, with: replacement)
        }
        return result
    }

    public static func substituteAny(_ value: Any, context: SubstitutionContext) throws -> Any {
        if let s = value as? String {
            return try substitute(s, context: context)
        }
        if let arr = value as? [Any] {
            return try arr.map { try substituteAny($0, context: context) }
        }
        if let dict = value as? [String: Any] {
            var out: [String: Any] = [:]
            for (k, v) in dict {
                out[k] = try substituteAny(v, context: context)
            }
            return out
        }
        return value
    }

    private static func resolve(token: String, context: SubstitutionContext) throws -> String {
        if token == "localWorkspaceFolder" {
            return context.localWorkspaceFolder
        }
        if token == "localWorkspaceFolderBasename" {
            return context.localWorkspaceFolderBasename
        }
        if token == "containerWorkspaceFolder" {
            return context.containerWorkspaceFolder
        }
        if token.hasPrefix("localEnv:") {
            let name = String(token.dropFirst("localEnv:".count))
            return context.localEnv[name] ?? ""
        }
        throw CLIError(
            code: CLIErrorCode.unsupportedSubstitution,
            property: token,
            message: "Unsupported substitution token '\(token)'",
            hint: "Supported: localWorkspaceFolder, localWorkspaceFolderBasename, localEnv:VAR, containerWorkspaceFolder"
        )
    }
}
