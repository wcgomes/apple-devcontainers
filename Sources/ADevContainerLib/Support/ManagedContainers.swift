import Foundation
import FoundationNetworking

/// Client-side discovery of clone-managed containers (`devcontainer.managed=adevcontainer`).
public enum ManagedContainers {
    public static func isManaged(_ info: ContainerInfo) -> Bool {
        info.labels[ContainerIdentity.labelManaged] == ContainerIdentity.managedValue
    }

    public static func isVolumeMode(_ info: ContainerInfo) -> Bool {
        info.labels[ContainerIdentity.labelWorkspaceMode] == ContainerIdentity.workspaceModeVolume
    }

    /// List managed containers only (filter after machine JSON list).
    public static func list(runtime: AppleContainerRuntime) throws -> [ContainerInfo] {
        try runtime.listAll().filter(isManaged)
    }

    /// Find managed container by name or id.
    public static func find(nameOrId: String, runtime: AppleContainerRuntime) throws -> ContainerInfo? {
        let all = try list(runtime: runtime)
        return all.first { $0.id == nameOrId || $0.name == nameOrId }
    }

    /// Resolve a single target from optional `--name`, auto-single, or interactive picker.
    public static func resolveSelection(
        name: String?,
        runtime: AppleContainerRuntime,
        picker: InteractivePicker = .default
    ) throws -> ContainerInfo {
        let managed = try list(runtime: runtime)
        if let name, !name.isEmpty {
            guard let found = managed.first(where: { $0.id == name || $0.name == name }) else {
                throw CLIError(
                    code: CLIErrorCode.containerNotFound,
                    message: "No managed container named '\(name)'",
                    hint: "Run 'adevcontainer list' to see managed containers"
                )
            }
            return found
        }
        if managed.isEmpty {
            throw CLIError(
                code: CLIErrorCode.containerNotFound,
                message: "No managed containers found",
                hint: "Create one with 'adevcontainer up' or 'adevcontainer clone <git-url>'"
            )
        }
        if managed.count == 1 {
            return managed[0]
        }
        // Multiple: picker if interactive, else require --name
        guard picker.isInteractive else {
            throw CLIError(
                code: CLIErrorCode.selectionRequired,
                message: "Multiple managed containers; specify --name",
                hint: "Run 'adevcontainer list' then retry with --name <container>"
            )
        }
        return try picker.pick(from: managed)
    }
}

/// Simple numbered TTY picker for managed container selection.
public struct InteractivePicker: Sendable {
    public var isInteractive: Bool
    public var readLine: @Sendable () -> String?
    public var writeError: @Sendable (String) -> Void

    public init(
        isInteractive: Bool,
        readLine: @escaping @Sendable () -> String?,
        writeError: @escaping @Sendable (String) -> Void = { FileHandle.standardError.write(Data($0.utf8)) }
    ) {
        self.isInteractive = isInteractive
        self.readLine = readLine
        self.writeError = writeError
    }

    public static var `default`: InteractivePicker {
        InteractivePicker(
            isInteractive: isatty(FileHandle.standardInput.fileDescriptor) != 0,
            readLine: { Swift.readLine() }
        )
    }

    public func pick(from containers: [ContainerInfo]) throws -> ContainerInfo {
        writeError("Select a container:\n")
        for (index, c) in containers.enumerated() {
            let git = c.labels[ContainerIdentity.labelGitURL] ?? ""
            let mode = c.labels[ContainerIdentity.labelWorkspaceMode] ?? ""
            let extra = [git, mode].filter { !$0.isEmpty }.joined(separator: " ")
            let suffix = extra.isEmpty ? "" : "  \(extra)"
            writeError("  \(index + 1)) \(c.name)  [\(c.state)]\(suffix)\n")
        }
        writeError("Enter number: ")
        guard let line = readLine()?.trimmingCharacters(in: .whitespacesAndNewlines),
              let n = Int(line),
              n >= 1, n <= containers.count
        else {
            throw CLIError(
                code: CLIErrorCode.usage,
                message: "Invalid selection",
                hint: "Enter a number between 1 and \(containers.count)"
            )
        }
        return containers[n - 1]
    }
}

/// Confirm or collect git author identity on clone (stderr prompts; mockable for tests).
public struct IdentityPrompt: Sendable {
    public var isInteractive: Bool
    public var readLine: @Sendable () -> String?
    public var writeError: @Sendable (String) -> Void

    public init(
        isInteractive: Bool,
        readLine: @escaping @Sendable () -> String?,
        writeError: @escaping @Sendable (String) -> Void = { FileHandle.standardError.write(Data($0.utf8)) }
    ) {
        self.isInteractive = isInteractive
        self.readLine = readLine
        self.writeError = writeError
    }

    public static var `default`: IdentityPrompt {
        IdentityPrompt(
            isInteractive: isatty(FileHandle.standardInput.fileDescriptor) != 0,
            readLine: { Swift.readLine() }
        )
    }

    /// Decide author identity before expensive Features/create work.
    /// - When `bothEnvExplicit`, skip prompt even on TTY (caller already applied env).
    /// - Non-interactive: return `current` unchanged (incomplete → later warn path).
    /// - Interactive complete: confirm keep or collect custom.
    /// - Interactive incomplete: collect both fields (required).
    public func confirmOrCollect(
        current: GitAuthorIdentity,
        bothEnvExplicit: Bool
    ) throws -> GitAuthorIdentity {
        if bothEnvExplicit || !isInteractive {
            return current
        }

        if current.isComplete {
            writeError("Git author identity for this clone:\n")
            writeError("  Name:  \(current.trimmedName)\n")
            writeError("  Email: \(current.trimmedEmail)\n")
            writeError("Use this identity? [Y/n]: ")
            let answer = (readLine() ?? "").trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
            if answer.isEmpty || answer == "y" || answer == "yes" {
                return current
            }
            return try collectNameAndEmail()
        }

        writeError("Git author identity not found for this repository.\n")
        return try collectNameAndEmail()
    }

    private func collectNameAndEmail() throws -> GitAuthorIdentity {
        writeError("user.name: ")
        let name = (readLine() ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        writeError("user.email: ")
        let email = (readLine() ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty, !email.isEmpty else {
            throw CLIError(
                code: CLIErrorCode.usage,
                message: "git user.name and user.email are required",
                hint: "Enter both values, or set ADEVCONTAINER_GIT_AUTHOR_NAME and ADEVCONTAINER_GIT_AUTHOR_EMAIL"
            )
        }
        return GitAuthorIdentity(name: name, email: email)
    }
}
