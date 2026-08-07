import Foundation

/// Minimal JSONC support: strip `//` line comments and `/* */` block comments
/// outside of strings, then optionally strip trailing commas before JSONSerialization.
public enum JSONCParser {
    public static func stripComments(_ input: String) throws -> String {
        var out = ""
        out.reserveCapacity(input.count)
        var i = input.startIndex
        var inString = false
        var escaped = false

        while i < input.endIndex {
            let ch = input[i]
            let next = input.index(after: i)

            if inString {
                out.append(ch)
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

            if ch == "\"" {
                inString = true
                out.append(ch)
                i = next
                continue
            }

            // Line comment
            if ch == "/", next < input.endIndex, input[next] == "/" {
                i = input.index(after: next)
                while i < input.endIndex, input[i] != "\n", input[i] != "\r" {
                    i = input.index(after: i)
                }
                continue
            }

            // Block comment
            if ch == "/", next < input.endIndex, input[next] == "*" {
                i = input.index(after: next)
                var closed = false
                while i < input.endIndex {
                    if input[i] == "*", input.index(after: i) < input.endIndex,
                       input[input.index(after: i)] == "/" {
                        i = input.index(i, offsetBy: 2)
                        closed = true
                        break
                    }
                    i = input.index(after: i)
                }
                if !closed {
                    throw CLIError(
                        code: CLIErrorCode.configParse,
                        message: "Unterminated block comment in JSONC",
                        hint: "Close /* */ comments before end of file"
                    )
                }
                continue
            }

            out.append(ch)
            i = next
        }

        return out
    }

    /// Remove trailing commas before `}` or `]` outside strings.
    public static func stripTrailingCommas(_ input: String) -> String {
        var out = ""
        out.reserveCapacity(input.count)
        var i = input.startIndex
        var inString = false
        var escaped = false

        while i < input.endIndex {
            let ch = input[i]
            let next = input.index(after: i)

            if inString {
                out.append(ch)
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

            if ch == "\"" {
                inString = true
                out.append(ch)
                i = next
                continue
            }

            if ch == "," {
                // Look ahead over whitespace for } or ]
                var j = next
                while j < input.endIndex, input[j].isWhitespace {
                    j = input.index(after: j)
                }
                if j < input.endIndex, input[j] == "}" || input[j] == "]" {
                    // skip comma
                    i = next
                    continue
                }
            }

            out.append(ch)
            i = next
        }
        return out
    }

    public static func parseObject(_ text: String) throws -> [String: Any] {
        let stripped = try stripComments(text)
        let cleaned = stripTrailingCommas(stripped)
        guard let data = cleaned.data(using: .utf8) else {
            throw CLIError(code: CLIErrorCode.configParse, message: "Config is not valid UTF-8")
        }
        let obj: Any
        do {
            obj = try JSONSerialization.jsonObject(with: data, options: [.fragmentsAllowed])
        } catch {
            throw CLIError(
                code: CLIErrorCode.configParse,
                message: "Invalid JSON in config: \(error.localizedDescription)",
                hint: "Check for syntax errors after comments are removed"
            )
        }
        guard let dict = obj as? [String: Any] else {
            throw CLIError(
                code: CLIErrorCode.configParse,
                message: "devcontainer.json root must be a JSON object"
            )
        }
        return dict
    }

    public static func loadFile(at path: String) throws -> [String: Any] {
        let url = URL(fileURLWithPath: path)
        let data: Data
        do {
            data = try Data(contentsOf: url)
        } catch {
            throw CLIError(
                code: CLIErrorCode.configNotFound,
                message: "Cannot read config at \(path): \(error.localizedDescription)"
            )
        }
        guard let text = String(data: data, encoding: .utf8) else {
            throw CLIError(code: CLIErrorCode.configParse, message: "Config is not valid UTF-8: \(path)")
        }
        return try parseObject(text)
    }
}
