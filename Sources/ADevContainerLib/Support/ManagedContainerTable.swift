import Foundation

/// Shared human-table layout for managed containers (`list` + InteractivePicker).
///
/// Pad plain cells, then wrap styles so ANSI length does not skew columns.
public enum ManagedContainerTable {
    public static let modeWidth = 6
    private static let gap = "  "

    /// Visible name, including recovery helper suffix when applicable.
    public static func displayName(for info: ContainerInfo) -> String {
        RecoveryHelper.isRecoveryHelper(info) ? "\(info.name) [RECOVERY]" : info.name
    }

    public static func pad(_ s: String, _ width: Int) -> String {
        if s.count >= width { return s }
        return s + String(repeating: " ", count: width - s.count)
    }

    /// Column widths for a container set. `lead` is the picker prefix column (0 for `list`).
    public struct Widths: Sendable {
        public let lead: Int
        public let name: Int
        public let state: Int

        public init(containers: [ContainerInfo], lead: Int = 0) {
            let names = containers.map(ManagedContainerTable.displayName(for:))
            self.lead = lead
            self.name = max(4, names.map(\.count).max() ?? 4)
            self.state = max(5, containers.map(\.state.count).max() ?? 5)
        }
    }

    /// Lead column width for navigable picker (`" > "` / `"   "`).
    public static let navigableLeadWidth = 3

    /// Lead column width for numbered picker (`"  N) "`).
    public static func numberedLeadWidth(count: Int) -> Int {
        // "  " + digits + ") "
        4 + String(max(count, 1)).count
    }

    /// Dim header: optional blank lead, then NAME STATE MODE GIT_URL.
    public static func header(widths: Widths) -> String {
        TerminalStyle.styleInfo(plainHeader(widths: widths))
    }

    public static func plainHeader(widths: Widths) -> String {
        var s = ""
        if widths.lead > 0 {
            s += pad("", widths.lead)
        }
        s += pad("NAME", widths.name)
            + gap + pad("STATE", widths.state)
            + gap + pad("MODE", modeWidth)
            + gap + "GIT_URL"
        return s
    }

    /// One styled data row. When `widths.lead > 0`, `leadStyled` must match that visible width.
    public static func row(
        info: ContainerInfo,
        widths: Widths,
        leadStyled: String = ""
    ) -> String {
        let name = displayName(for: info)
        let mode = info.labels[ContainerIdentity.labelWorkspaceMode] ?? "-"
        let git = info.labels[ContainerIdentity.labelGitURL] ?? ""

        var out = ""
        if widths.lead > 0 {
            out += leadStyled
        }
        out += TerminalStyle.stylePhaseHead(pad(name, widths.name))
        out += gap
        out += info.isRunning
            ? TerminalStyle.styleSuccess(pad(info.state, widths.state))
            : TerminalStyle.styleMuted(pad(info.state, widths.state))
        out += gap
        out += TerminalStyle.styleCommand(pad(mode, modeWidth))
        out += gap
        // Default foreground, normal weight (not dim, not bold).
        out += git
        return out
    }

    /// Navigable selection lead: bold `>` when selected, spaces otherwise.
    public static func navigableLead(selected: Bool) -> String {
        if selected {
            return " " + TerminalStyle.styleCommand(">") + " "
        }
        return "   "
    }

    /// Numbered lead (`"  1) "`) right-padded to `width`.
    public static func numberedLead(index: Int, width: Int) -> String {
        pad("  \(index + 1)) ", width)
    }
}
