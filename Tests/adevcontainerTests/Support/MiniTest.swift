import Foundation

enum MiniTest {
    nonisolated(unsafe) private static var failures = 0
    nonisolated(unsafe) private static var passes = 0
    nonisolated(unsafe) private static var skips = 0
    nonisolated(unsafe) private static var current = ""

    static func runAll(_ tests: [(String, () throws -> Void)]) -> Int32 {
        failures = 0
        passes = 0
        skips = 0
        print("ADevContainer tests (\(tests.count) cases)")
        for (name, body) in tests {
            current = name
            do {
                try body()
                passes += 1
                print("  PASS \(name)")
            } catch let skip as Skip {
                skips += 1
                print("  SKIP \(name) — \(skip.message)")
            } catch let fail as Failure {
                failures += 1
                print("  FAIL \(name) — \(fail.message)")
            } catch {
                failures += 1
                print("  FAIL \(name) — \(error)")
            }
        }
        print("Summary: \(passes) passed, \(failures) failed, \(skips) skipped")
        return failures == 0 ? 0 : 1
    }

    struct Failure: Error, CustomStringConvertible {
        let message: String
        var description: String { message }
    }

    struct Skip: Error {
        let message: String
    }

    static func skip(_ message: String) throws -> Never {
        throw Skip(message: message)
    }

    static func expect(_ condition: Bool, _ message: String = "expectation failed", file: String = #fileID, line: Int = #line) throws {
        if !condition {
            throw Failure(message: "\(file):\(line): \(message)")
        }
    }

    static func expectEqual<T: Equatable>(_ a: T, _ b: T, _ message: String = "", file: String = #fileID, line: Int = #line) throws {
        if a != b {
            let suffix = message.isEmpty ? "" : " — \(message)"
            throw Failure(message: "\(file):\(line): expected \(b), got \(a)\(suffix)")
        }
    }

    static func expectThrows(_ body: () throws -> Void, file: String = #fileID, line: Int = #line, validate: (Error) throws -> Void) throws {
        do {
            try body()
            throw Failure(message: "\(file):\(line): expected throw")
        } catch let f as Failure {
            throw f
        } catch let s as Skip {
            throw s
        } catch {
            try validate(error)
        }
    }
}
