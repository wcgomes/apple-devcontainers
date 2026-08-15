import Foundation
#if canImport(Darwin)
import Darwin
#endif

/// Shared terminal presentation policy: color enablement, ANSI helpers, and prefix/indent constants.
///
/// Color is enabled when stderr is a TTY and `NO_COLOR` is unset, or when `FORCE_COLOR=1`.
/// `NO_COLOR` (any value, key present) always wins over `FORCE_COLOR`.
public enum TerminalStyle {
    // MARK: - Stable monochrome prefixes / indent

    public static let phasePrefix = "==> "
    public static let warningPrefix = "warning: "
    /// Human error label (machine `code` lives in JSON / structured fields, not this prefix).
    public static let errorPrefix = "error: "
    public static let toolPipePrefix = "| "
    /// Indent for framed internal tool lines and quieter info lines (4 spaces).
    public static let nestIndent = "    "

    // MARK: - ANSI (SGR)

    public static let ansiReset = "\u{001B}[0m"
    public static let ansiBold = "\u{001B}[1m"
    public static let ansiDim = "\u{001B}[2m"
    /// Legacy basic cyan (36); phase styling prefers `ansiPhaseCyan`.
    public static let ansiCyan = "\u{001B}[36m"
    /// Standard yellow (SGR 33). Prefer `styleWarning` / `ansiWarningYellow`.
    public static let ansiYellow = "\u{001B}[33m"
    public static let ansiRed = "\u{001B}[31m"
    /// Bright yellow (SGR 93).
    public static let ansiBrightYellow = "\u{001B}[93m"
    /// Bright red (SGR 91).
    public static let ansiBrightRed = "\u{001B}[91m"
    /// Phase: bold soft steel blue (256-color 75) — less neon than bright cyan 51.
    public static let ansiPhaseCyan = "\u{001B}[38;5;75m"
    /// Warning: 256-color pure yellow (226) — stays yellow when theme remaps basic 33/93 toward orange.
    public static let ansiWarningYellow = "\u{001B}[38;5;226m"
    /// Error: 256-color pure red (196).
    public static let ansiErrorRed = "\u{001B}[38;5;196m"
    /// Success value (e.g. outcome success): 256-color green (46).
    public static let ansiSuccessGreen = "\u{001B}[38;5;46m"
    /// Muted secondary text (e.g. non-running STATE): 256-color gray (245), distinct from SGR dim.
    public static let ansiMutedGray = "\u{001B}[38;5;245m"
    /// Hint lines under errors: soft cyan (distinct from phase steel blue 75).
    public static let ansiHintCyan = "\u{001B}[38;5;87m"

    // MARK: - Test / injection seams

    /// When non-nil, overrides the computed color policy (unit tests).
    nonisolated(unsafe) public static var colorOverride: Bool?

    /// Environment provider (default: process environment).
    nonisolated(unsafe) public static var environmentProvider: () -> [String: String] = {
        ProcessInfo.processInfo.environment
    }

    /// stderr TTY probe (default: `isatty(STDERR_FILENO)`).
    nonisolated(unsafe) public static var stderrIsTTYProvider: () -> Bool = {
        #if canImport(Darwin)
        return isatty(STDERR_FILENO) != 0
        #else
        return false
        #endif
    }

    /// Reset test seams to production defaults.
    public static func resetTestSeams() {
        colorOverride = nil
        environmentProvider = { ProcessInfo.processInfo.environment }
        stderrIsTTYProvider = {
            #if canImport(Darwin)
            return isatty(STDERR_FILENO) != 0
            #else
            return false
            #endif
        }
    }

    // MARK: - Color policy

    /// Effective color enablement for the current process (honors override, then policy).
    public static var colorEnabled: Bool {
        if let colorOverride { return colorOverride }
        return colorEnabled(
            stderrIsTTY: stderrIsTTYProvider(),
            env: environmentProvider()
        )
    }

    /// Pure policy: `NO_COLOR` present → false; else `FORCE_COLOR=1` → true; else stderr TTY.
    public static func colorEnabled(stderrIsTTY: Bool, env: [String: String]) -> Bool {
        // Key presence disables color (any value), per common CLI convention.
        if env.keys.contains("NO_COLOR") {
            return false
        }
        if env["FORCE_COLOR"] == "1" {
            return true
        }
        return stderrIsTTY
    }

    // MARK: - Styling helpers
    //
    // Color defaults use `Bool? = nil` then `color ?? colorEnabled` so the policy is always
    // resolved at call time (avoids stale/quirky static default-arg evaluation).

    /// Phase line: bold blue. Trailing "item" (parenthetical or resource token) is bold white.
    ///
    /// Examples (color on):
    /// - `==> Running postStartCommand (feature 1)` → blue head + white `(feature 1)`
    /// - `==> Pulling image alpine:3.20` → blue head + white `alpine:3.20`
    /// - `==> Ready` → all blue
    public static func stylePhase(_ text: String, color: Bool? = nil) -> String {
        guard color ?? colorEnabled else { return text }
        if let split = splitPhaseItem(text) {
            return stylePhaseHead(split.head, color: true) + styleCommand(split.item, color: true)
        }
        return stylePhaseHead(text, color: true)
    }

    public static func stylePhaseHead(_ text: String, color: Bool? = nil) -> String {
        guard color ?? colorEnabled else { return text }
        return ansiBold + ansiPhaseCyan + text + ansiReset
    }

    /// Split a phase line into blue head + white item when an item is present.
    /// Accepts full `==> …` lines or bare status messages.
    public static func splitPhaseItem(_ text: String) -> (head: String, item: String)? {
        let prefix: String
        let body: String
        if text.hasPrefix(phasePrefix) {
            prefix = phasePrefix
            body = String(text.dropFirst(phasePrefix.count))
        } else {
            prefix = ""
            body = text
        }
        guard !body.isEmpty else { return nil }

        // 1) Trailing parenthetical: "Running postStartCommand (feature 1)"
        if body.hasSuffix(")"), let open = body.lastIndex(of: "("), open > body.startIndex {
            let before = body.index(before: open)
            if body[before] == " " {
                let headBody = String(body[..<open]) // includes trailing space before "("
                let item = String(body[open...])
                if item.count > 2 { // at least "()"
                    return (prefix + headBody, item)
                }
            }
        }

        // 2) Trailing resource-like token: image refs, adev-* ids, paths, quoted names
        if let space = body.lastIndex(of: " ") {
            let tokenStart = body.index(after: space)
            let token = String(body[tokenStart...])
            if looksLikePhaseItem(token) {
                let headBody = String(body[...space]) // includes trailing space
                return (prefix + headBody, token)
            }
        }

        return nil
    }

    /// Heuristic: token is a resource name worth white emphasis on a phase line.
    public static func looksLikePhaseItem(_ token: String) -> Bool {
        guard token.count >= 2 else { return false }
        if (token.hasPrefix("'") && token.hasSuffix("'") && token.count >= 3)
            || (token.hasPrefix("\"") && token.hasSuffix("\"") && token.count >= 3)
        {
            return true
        }
        if token.hasPrefix("adev-") { return true }
        // DNS-friendly create names (e.g. my-app) after the adev- prefix went away.
        if token.contains("-"),
           token.range(of: #"^[a-z0-9]([a-z0-9-]*[a-z0-9])?$"#, options: .regularExpression) != nil
        {
            return true
        }
        if token.contains("/") || token.contains(":") || token.contains("@") { return true }
        // Dotted refs (ghcr.io/… already has /; alpine.x rare) — require a dot not only extension-less words
        if token.contains("."), token.contains(where: { $0.isLetter }) { return true }
        return false
    }

    public static func styleInfo(_ text: String, color: Bool? = nil) -> String {
        guard color ?? colorEnabled else { return text }
        return ansiDim + text + ansiReset
    }

    /// Bold muted gray (256-color 245), distinct from `styleInfo` dim — e.g. non-running container STATE.
    public static func styleMuted(_ text: String, color: Bool? = nil) -> String {
        guard color ?? colorEnabled else { return text }
        return ansiBold + ansiMutedGray + text + ansiReset
    }

    /// Emphasized command / copy-paste target: bold default foreground (reads as white on dark themes).
    public static func styleCommand(_ text: String, color: Bool? = nil) -> String {
        guard color ?? colorEnabled else { return text }
        return ansiBold + text + ansiReset
    }

    /// Success value (e.g. `success` in `outcome: success`): bold green.
    public static func styleSuccess(_ text: String, color: Bool? = nil) -> String {
        guard color ?? colorEnabled else { return text }
        return ansiBold + ansiSuccessGreen + text + ansiReset
    }

    /// Warning label only (typically `warning: `): bold + pure yellow.
    public static func styleWarningLabel(_ text: String, color: Bool? = nil) -> String {
        guard color ?? colorEnabled else { return text }
        return ansiBold + ansiWarningYellow + text + ansiReset
    }

    /// Warning message body: same dim gray as info/other secondary log text.
    public static func styleWarningBody(_ text: String, color: Bool? = nil) -> String {
        styleInfo(text, color: color)
    }

    /// Full warning line helper: yellow label + dim body. Prefer composing via StatusPrinter.
    public static func styleWarning(_ text: String, color: Bool? = nil) -> String {
        let useColor = color ?? colorEnabled
        guard useColor else { return text }
        if text.hasPrefix(warningPrefix) {
            let body = String(text.dropFirst(warningPrefix.count))
            return styleWarningLabel(warningPrefix, color: true) + styleWarningBody(body, color: true)
        }
        return styleWarningLabel(text, color: true)
    }

    /// Error label only (typically `error: `): bold + pure red (256-color 196).
    public static func styleErrorLabel(_ text: String, color: Bool? = nil) -> String {
        guard color ?? colorEnabled else { return text }
        return ansiBold + ansiErrorRed + text + ansiReset
    }

    /// Error message body / property: same dim gray as info.
    public static func styleErrorBody(_ text: String, color: Bool? = nil) -> String {
        styleInfo(text, color: color)
    }

    /// Error hint line (`  hint: …`): cyan so actionable guidance stands out from dim body.
    public static func styleHint(_ text: String, color: Bool? = nil) -> String {
        guard color ?? colorEnabled else { return text }
        return ansiHintCyan + text + ansiReset
    }

    /// Full error head helper: red `error: ` label + dim message body.
    public static func styleError(_ text: String, color: Bool? = nil) -> String {
        let useColor = color ?? colorEnabled
        guard useColor else { return text }
        if let split = splitErrorHead(text) {
            return styleErrorLabel(split.label, color: true) + styleErrorBody(split.body, color: true)
        }
        return styleErrorLabel(text, color: true)
    }

    /// Split `error: <body>` into label (including trailing space after `:`) and body.
    public static func splitErrorHead(_ text: String) -> (label: String, body: String)? {
        guard text.hasPrefix(errorPrefix) else { return nil }
        let body = String(text.dropFirst(errorPrefix.count))
        return (errorPrefix, body)
    }

    public static func styleToolLine(_ text: String, color: Bool? = nil) -> String {
        guard color ?? colorEnabled else { return text }
        return ansiDim + text + ansiReset
    }

    /// Frame one display line of internal tool output: indent + `| ` + content.
    public static func frameToolLine(_ line: String, color: Bool? = nil) -> String {
        // Normalize CR leftovers from CRLF without double-prefixing.
        var content = line
        if content.hasSuffix("\r") {
            content = String(content.dropLast())
        }
        let framed = nestIndent + toolPipePrefix + content
        return styleToolLine(framed, color: color)
    }

    /// Strip CSI / OSC-style ANSI sequences so monochrome greps still see stable prefixes.
    public static func stripANSI(_ text: String) -> String {
        var result = ""
        result.reserveCapacity(text.count)
        var i = text.startIndex
        while i < text.endIndex {
            if text[i] == "\u{001B}" {
                let next = text.index(after: i)
                guard next < text.endIndex else { break }
                if text[next] == "[" {
                    // CSI: ESC [ ... letter
                    var j = text.index(after: next)
                    while j < text.endIndex {
                        let c = text[j]
                        if ("a"..."z").contains(c) || ("A"..."Z").contains(c) {
                            j = text.index(after: j)
                            break
                        }
                        j = text.index(after: j)
                    }
                    i = j
                    continue
                }
                if text[next] == "]" {
                    // OSC: ESC ] ... BEL or ST
                    var j = text.index(after: next)
                    while j < text.endIndex {
                        if text[j] == "\u{0007}" {
                            j = text.index(after: j)
                            break
                        }
                        if text[j] == "\u{001B}" {
                            let k = text.index(after: j)
                            if k < text.endIndex, text[k] == "\\" {
                                j = text.index(after: k)
                                break
                            }
                        }
                        j = text.index(after: j)
                    }
                    i = j
                    continue
                }
                // Lone ESC — skip it.
                i = next
                continue
            }
            result.append(text[i])
            i = text.index(after: i)
        }
        return result
    }
}
