import Foundation

/// Persist a create name into an editable `devcontainer.json` (host or retained checkout).
/// Used by foreign-name suffix recovery so the next `up`/`clone` is stable.
public enum ConfigNameWriter {
    /// Set `"name"` to `createName`. Replaces an existing string `name` in place when possible;
    /// otherwise inserts a new key after the root `{`.
    public static func persistCreateName(_ createName: String, inFileAt path: String) throws {
        let url = URL(fileURLWithPath: path)
        let text: String
        do {
            text = try String(contentsOf: url, encoding: .utf8)
        } catch {
            throw CLIError(
                code: CLIErrorCode.configParse,
                property: "name",
                message: "Could not read config to persist name at \(path)",
                hint: "Ensure the editable devcontainer.json is readable"
            )
        }
        let updated = upsertName(createName, in: text)
        do {
            try updated.write(to: url, atomically: true, encoding: .utf8)
        } catch {
            throw CLIError(
                code: CLIErrorCode.configParse,
                property: "name",
                message: "Could not write persisted name to \(path)",
                hint: "Ensure the editable devcontainer.json is writable"
            )
        }
    }

    /// Replace or insert `"name": "<value>"` in a JSONC object document.
    public static func upsertName(_ name: String, in text: String) -> String {
        let escaped = escapeJSONString(name)
        if let range = findNameStringValueRange(in: text) {
            return text.replacingCharacters(in: range, with: escaped)
        }
        return insertNameKey(escaped, in: text)
    }

    private static func escapeJSONString(_ value: String) -> String {
        var out = ""
        out.reserveCapacity(value.count)
        for ch in value {
            switch ch {
            case "\\": out += "\\\\"
            case "\"": out += "\\\""
            case "\n": out += "\\n"
            case "\r": out += "\\r"
            case "\t": out += "\\t"
            default: out.append(ch)
            }
        }
        return out
    }

    /// Locate the quoted value of a top-level `"name"` string key (outside comments).
    private static func findNameStringValueRange(in text: String) -> Range<String.Index>? {
        var i = text.startIndex
        var inString = false
        var escaped = false
        var inLineComment = false
        var inBlockComment = false
        var depth = 0

        while i < text.endIndex {
            let ch = text[i]
            let next = text.index(after: i)

            if inLineComment {
                if ch == "\n" { inLineComment = false }
                i = next
                continue
            }
            if inBlockComment {
                if ch == "*", next < text.endIndex, text[next] == "/" {
                    i = text.index(after: next)
                    inBlockComment = false
                    continue
                }
                i = next
                continue
            }
            if inString {
                if escaped {
                    escaped = false
                } else if ch == "\\" {
                    escaped = true
                } else if ch == "\"" {
                    inString = false
                }
                i = next
                continue
            }
            if ch == "/", next < text.endIndex, text[next] == "/" {
                inLineComment = true
                i = text.index(after: next)
                continue
            }
            if ch == "/", next < text.endIndex, text[next] == "*" {
                inBlockComment = true
                i = text.index(after: next)
                continue
            }
            if ch == "\"" {
                if depth == 1, let key = readJSONString(in: text, startingAt: i) {
                    let afterKey = key.end
                    var j = afterKey
                    while j < text.endIndex, text[j].isWhitespace { j = text.index(after: j) }
                    if j < text.endIndex, text[j] == ":" {
                        j = text.index(after: j)
                        while j < text.endIndex, text[j].isWhitespace { j = text.index(after: j) }
                        if key.value == "name", j < text.endIndex, text[j] == "\"" {
                            if let value = readJSONString(in: text, startingAt: j) {
                                return value.inner
                            }
                        }
                    }
                }
                inString = true
                i = next
                continue
            }
            if ch == "{" { depth += 1 }
            if ch == "}" { depth = max(0, depth - 1) }
            i = next
        }
        return nil
    }

    private static func readJSONString(
        in text: String,
        startingAt start: String.Index
    ) -> (value: String, end: String.Index, inner: Range<String.Index>)? {
        guard start < text.endIndex, text[start] == "\"" else { return nil }
        var i = text.index(after: start)
        var escaped = false
        var value = ""
        let innerStart = i
        while i < text.endIndex {
            let ch = text[i]
            if escaped {
                value.append(ch)
                escaped = false
                i = text.index(after: i)
                continue
            }
            if ch == "\\" {
                escaped = true
                i = text.index(after: i)
                continue
            }
            if ch == "\"" {
                return (value, text.index(after: i), innerStart..<i)
            }
            value.append(ch)
            i = text.index(after: i)
        }
        return nil
    }

    private static func insertNameKey(_ escaped: String, in text: String) -> String {
        guard let open = text.firstIndex(of: "{") else {
            return "{ \"name\": \"\(escaped)\" }\n"
        }
        let after = text.index(after: open)
        return String(text[..<after]) + "\n  \"name\": \"\(escaped)\"," + String(text[after...])
    }
}
