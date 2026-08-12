import Foundation
#if canImport(Darwin)
import Darwin
#elseif canImport(Glibc)
import Glibc
#endif

/// Low-level stdin key reads for interactive TTY pickers (raw mode, no heavy deps).
///
/// Production host is Darwin; Glibc paths exist so Linux package tests can compile the same
/// sources. Raw mode clears `ISIG` so Ctrl-C arrives as byte `0x03` and termios restore
/// (via `defer`) always runs — never leave the host shell without ICANON/ECHO.
enum TerminalRawInput {
    static var stdinIsTTY: Bool {
        #if canImport(Darwin) || canImport(Glibc)
        return isatty(STDIN_FILENO) != 0
        #else
        return false
        #endif
    }

    static var canUseRawInput: Bool { stdinIsTTY }

    /// Run `body` with stdin in non-canonical, no-echo, no-ISIG mode.
    /// Returns `nil` (without running `body`) when stdin is not a TTY or termios setup fails,
    /// so callers can fall back to line-oriented input instead of a broken key loop.
    /// Restores prior termios on all exits after a successful enter (including Ctrl-C → cancel).
    static func withRawStdin<T>(_ body: () throws -> T) throws -> T? {
        #if canImport(Darwin) || canImport(Glibc)
        let fd = STDIN_FILENO
        guard isatty(fd) != 0 else { return nil }
        var original = termios()
        guard tcgetattr(fd, &original) == 0 else { return nil }
        var raw = original
        // Clear ISIG so Ctrl-C is a byte (0x03), not SIGINT that would skip defer restore.
        raw.c_lflag &= ~tcflag_t(ICANON | ECHO | ISIG)
        setControlChar(&raw, VMIN, 1)
        setControlChar(&raw, VTIME, 0)
        guard tcsetattr(fd, TCSANOW, &raw) == 0 else { return nil }
        defer { _ = tcsetattr(fd, TCSANOW, &original) }
        return try body()
        #else
        return nil
        #endif
    }

    /// Blocking read of one picker event from stdin (caller should be in raw mode).
    static func readPickerInput() -> InteractivePickerInput {
        #if canImport(Darwin) || canImport(Glibc)
        guard let first = readByte() else { return .eof }
        if first == 0x1B {
            return readEscapeSequence()
        }
        return decodeSingleByte(first)
        #else
        return .eof
        #endif
    }

    /// Pure single-byte classification (no ESC sequences). Used by live reads and unit tests.
    static func decodeSingleByte(_ byte: UInt8) -> InteractivePickerInput {
        switch byte {
        case 0x03: // Ctrl-C (ISIG off) → cancel
            return .eof
        case 0x0A, 0x0D: // LF / CR
            return .enter
        case UInt8(ascii: "k"), UInt8(ascii: "K"):
            return .up
        case UInt8(ascii: "j"), UInt8(ascii: "J"):
            return .down
        case UInt8(ascii: "1")...UInt8(ascii: "9"):
            return .digit(Int(byte - UInt8(ascii: "0")))
        default:
            return .other
        }
    }

    /// Pure CSI / bare-ESC classification after the leading `0x1B` has been consumed.
    /// `following` is the bytes after ESC (empty ⇒ bare Esc).
    static func decodeAfterEscape(_ following: [UInt8]) -> InteractivePickerInput {
        if following.isEmpty {
            return .escape
        }
        if following[0] == UInt8(ascii: "["), following.count >= 2 {
            switch following[1] {
            case UInt8(ascii: "A"): return .up
            case UInt8(ascii: "B"): return .down
            default: return .other
            }
        }
        // ESC + other: treat as cancel (common for Alt-key leftovers too).
        return .escape
    }

    #if canImport(Darwin) || canImport(Glibc)
    private static func readEscapeSequence() -> InteractivePickerInput {
        // Disambiguate bare Esc from CSI sequences with a short poll.
        guard pollReadable(timeoutMs: 50) else {
            return decodeAfterEscape([])
        }
        guard let next = readByte() else { return decodeAfterEscape([]) }
        if next == UInt8(ascii: "[") {
            guard let code = readByte() else { return decodeAfterEscape([next]) }
            return decodeAfterEscape([next, code])
        }
        return decodeAfterEscape([next])
    }

    private static func readByte() -> UInt8? {
        var byte: UInt8 = 0
        while true {
            let n = read(STDIN_FILENO, &byte, 1)
            if n == 1 { return byte }
            if n == 0 { return nil }
            if errno == EINTR { continue }
            return nil
        }
    }

    private static func pollReadable(timeoutMs: Int32) -> Bool {
        while true {
            var fds = pollfd(fd: STDIN_FILENO, events: Int16(POLLIN), revents: 0)
            let rc = poll(&fds, 1, timeoutMs)
            if rc > 0 {
                return (fds.revents & Int16(POLLIN)) != 0
            }
            if rc == 0 {
                return false
            }
            if errno == EINTR {
                continue
            }
            return false
        }
    }

    private static func setControlChar(_ term: inout termios, _ index: Int32, _ value: cc_t) {
        withUnsafeMutableBytes(of: &term.c_cc) { raw in
            let buf = raw.bindMemory(to: cc_t.self)
            let i = Int(index)
            guard i >= 0, i < buf.count else { return }
            buf[i] = value
        }
    }
    #endif
}

/// Key / control events consumed by `InteractivePicker` navigable UI.
public enum InteractivePickerInput: Equatable, Sendable {
    case up
    case down
    case enter
    case escape
    /// Digit 1...9 (1-based index shortcut).
    case digit(Int)
    case other
    case eof
}
