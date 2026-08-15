import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif
#if canImport(Darwin)
import Darwin
#elseif canImport(Glibc)
import Glibc
#endif

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

/// Interactive TTY picker for managed container selection.
///
/// Production (`.default`, stdin TTY): ↑/↓ (or j/k) moves highlight, Enter confirms, Esc/Ctrl-C
/// cancels, digits 1–9 jump-select when in range. Injected `readInput` drives the same UI in
/// tests. Injected `readLine` without `readInput` always uses the numbered prompt — never live
/// raw mode — so mocks cannot hang on a developer TTY.
public struct InteractivePicker: Sendable {
    public var isInteractive: Bool
    public var readLine: @Sendable () -> String?
    public var writeError: @Sendable (String) -> Void
    /// Optional key-event source for navigable UI (and unit tests). When nil, production
    /// `.default` may use raw stdin; custom inits fall back to the numbered `readLine` prompt.
    public var readInput: (@Sendable () -> InteractivePickerInput)?
    /// When true and `readInput` is nil, enter live raw-key UI on a TTY. Only `.default` sets
    /// this; test/mocks leave it false so a custom `readLine` is always honored.
    public var prefersLiveRawInput: Bool

    public init(
        isInteractive: Bool,
        readLine: @escaping @Sendable () -> String?,
        writeError: @escaping @Sendable (String) -> Void = { FileHandle.standardError.write(Data($0.utf8)) },
        readInput: (@Sendable () -> InteractivePickerInput)? = nil,
        prefersLiveRawInput: Bool = false
    ) {
        self.isInteractive = isInteractive
        self.readLine = readLine
        self.writeError = writeError
        self.readInput = readInput
        self.prefersLiveRawInput = prefersLiveRawInput
    }

    public static var `default`: InteractivePicker {
        InteractivePicker(
            isInteractive: stdinIsTTY(),
            readLine: { Swift.readLine() },
            prefersLiveRawInput: true
        )
    }

    public func pick(from containers: [ContainerInfo]) throws -> ContainerInfo {
        if let readInput {
            return try pickNavigable(from: containers, readInput: readInput)
        }
        // Live raw mode only for production `.default` — never when callers injected readLine.
        if prefersLiveRawInput,
           TerminalRawInput.canUseRawInput,
           let picked = try TerminalRawInput.withRawStdin({
               try pickNavigable(from: containers, readInput: TerminalRawInput.readPickerInput)
           })
        {
            return picked
        }
        return try pickNumbered(from: containers)
    }

    /// Numbered / navigable list of labels (same stderr style as managed-container selection).
    /// Not QUIET-gated — writes go through `writeError`.
    public func pickLabel(from labels: [String], prompt: String) throws -> Int {
        if let readInput {
            return try pickNavigableLabels(labels, prompt: prompt, readInput: readInput)
        }
        if prefersLiveRawInput,
           TerminalRawInput.canUseRawInput,
           let picked = try TerminalRawInput.withRawStdin({
               try pickNavigableLabels(
                   labels,
                   prompt: prompt,
                   readInput: TerminalRawInput.readPickerInput
               )
           })
        {
            return picked
        }
        return try pickNumberedLabels(labels, prompt: prompt)
    }

    private func pickNumberedLabels(_ labels: [String], prompt: String) throws -> Int {
        writeError(prompt + "\n")
        let leadWidth = ManagedContainerTable.numberedLeadWidth(count: labels.count)
        for (index, label) in labels.enumerated() {
            writeError(ManagedContainerTable.numberedLead(index: index, width: leadWidth) + label + "\n")
        }
        writeError("Enter number: ")
        guard let line = readLine()?.trimmingCharacters(in: .whitespacesAndNewlines),
              let n = Int(line),
              n >= 1, n <= labels.count
        else {
            throw CLIError(
                code: CLIErrorCode.usage,
                message: "Invalid selection",
                hint: "Enter a number between 1 and \(labels.count)"
            )
        }
        return n - 1
    }

    private func pickNavigableLabels(
        _ labels: [String],
        prompt: String,
        readInput: @Sendable () -> InteractivePickerInput
    ) throws -> Int {
        precondition(!labels.isEmpty)
        var selected = 0
        writeError(prompt + "\n")
        writeLabelRows(labels, selected: selected, clearLines: true)
        writeError(hintLine())
        let listLineCount = labels.count

        while true {
            switch readInput() {
            case .up:
                selected = selected == 0 ? labels.count - 1 : selected - 1
                redrawLabelRows(labels, selected: selected, listLineCount: listLineCount)
            case .down:
                selected = selected == labels.count - 1 ? 0 : selected + 1
                redrawLabelRows(labels, selected: selected, listLineCount: listLineCount)
            case .enter:
                writeError("\n")
                return selected
            case .escape, .eof:
                writeError("\n")
                throw CLIError(
                    code: CLIErrorCode.usage,
                    message: "Selection cancelled",
                    hint: "Re-run and choose an option"
                )
            case .digit(let n):
                if n >= 1, n <= labels.count {
                    writeError("\n")
                    return n - 1
                }
            case .other:
                break
            }
        }
    }

    private func redrawLabelRows(_ labels: [String], selected: Int, listLineCount: Int) {
        let up = listLineCount + 1
        writeError("\u{001B}[\(up)A")
        writeLabelRows(labels, selected: selected, clearLines: true)
        writeError("\r\u{001B}[2K")
        writeError(hintLine())
    }

    private func writeLabelRows(_ labels: [String], selected: Int, clearLines: Bool) {
        for (index, label) in labels.enumerated() {
            if clearLines { writeError("\r\u{001B}[2K") }
            let lead = ManagedContainerTable.navigableLead(selected: index == selected)
            writeError(lead + label + "\n")
        }
    }

    private func pickNumbered(from containers: [ContainerInfo]) throws -> ContainerInfo {
        let widths = tableWidths(containers: containers, numbered: true)
        writeError("Select a container:\n")
        // One-shot list: no CSI clear-line (keeps monochrome/scripted stderr clean).
        writeTable(
            containers: containers,
            selected: 0,
            widths: widths,
            numbered: true,
            clearLines: false
        )
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

    private func pickNavigable(
        from containers: [ContainerInfo],
        readInput: @Sendable () -> InteractivePickerInput
    ) throws -> ContainerInfo {
        precondition(!containers.isEmpty)
        var selected = 0
        let widths = tableWidths(containers: containers, numbered: false)
        // Table header + rows (listLineCount includes header for CSI redraw).
        let listLineCount = containers.count + 1
        writeError("Select a container:\n")
        writeTable(
            containers: containers,
            selected: selected,
            widths: widths,
            numbered: false,
            clearLines: true
        )
        writeError(hintLine())

        while true {
            switch readInput() {
            case .up:
                let next = selected == 0 ? containers.count - 1 : selected - 1
                if next != selected {
                    selected = next
                    redrawList(
                        containers: containers,
                        selected: selected,
                        widths: widths,
                        listLineCount: listLineCount
                    )
                }
            case .down:
                let next = selected == containers.count - 1 ? 0 : selected + 1
                if next != selected {
                    selected = next
                    redrawList(
                        containers: containers,
                        selected: selected,
                        widths: widths,
                        listLineCount: listLineCount
                    )
                }
            case .enter:
                // Leave final highlight visible; advance past hint for a clean prompt.
                writeError("\n")
                return containers[selected]
            case .escape, .eof:
                writeError("\n")
                throw CLIError(
                    code: CLIErrorCode.usage,
                    message: "Selection cancelled",
                    hint: "Re-run and choose a container, or pass --name <container>"
                )
            case .digit(let n):
                if n >= 1, n <= containers.count {
                    selected = n - 1
                    redrawList(
                        containers: containers,
                        selected: selected,
                        widths: widths,
                        listLineCount: listLineCount
                    )
                    writeError("\n")
                    return containers[selected]
                }
            case .other:
                break
            }
        }
    }

    private func tableWidths(
        containers: [ContainerInfo],
        numbered: Bool
    ) -> ManagedContainerTable.Widths {
        let lead = numbered
            ? ManagedContainerTable.numberedLeadWidth(count: containers.count)
            : ManagedContainerTable.navigableLeadWidth
        return ManagedContainerTable.Widths(containers: containers, lead: lead)
    }

    private func redrawList(
        containers: [ContainerInfo],
        selected: Int,
        widths: ManagedContainerTable.Widths,
        listLineCount: Int
    ) {
        // Move up past hint + table (header + rows), then rewrite table + hint.
        let up = listLineCount + 1
        writeError("\u{001B}[\(up)A")
        writeTable(
            containers: containers,
            selected: selected,
            widths: widths,
            numbered: false,
            clearLines: true
        )
        writeError("\r\u{001B}[2K")
        writeError(hintLine())
    }

    private func writeTable(
        containers: [ContainerInfo],
        selected: Int,
        widths: ManagedContainerTable.Widths,
        numbered: Bool,
        clearLines: Bool
    ) {
        // CR + clear-line so redraw after CSI-A (same column) still starts at column 0
        // and shorter labels do not leave a stale tail.
        if clearLines { writeError("\r\u{001B}[2K") }
        writeError(ManagedContainerTable.header(widths: widths) + "\n")
        for (index, c) in containers.enumerated() {
            if clearLines { writeError("\r\u{001B}[2K") }
            let lead: String
            if numbered {
                lead = ManagedContainerTable.numberedLead(index: index, width: widths.lead)
            } else {
                lead = ManagedContainerTable.navigableLead(selected: index == selected)
            }
            writeError(
                ManagedContainerTable.row(info: c, widths: widths, leadStyled: lead) + "\n"
            )
        }
    }

    private func hintLine() -> String {
        TerminalStyle.styleInfo(" ↑/↓ move · Enter select · Esc cancel") + "\n"
    }


    private static func stdinIsTTY() -> Bool {
        #if canImport(Darwin) || canImport(Glibc)
        return isatty(FileHandle.standardInput.fileDescriptor) != 0
        #else
        return false
        #endif
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
