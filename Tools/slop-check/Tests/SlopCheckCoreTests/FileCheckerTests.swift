@testable import SlopCheckCore
import Testing

struct FileCheckerTests {
    private func rules(_ source: String, path: String = "Sources/Thing.swift") -> [String] {
        FileChecker.check(path: path, text: source).map(\.rule)
    }

    @Test func docCommentsBelongToAPIOnly() {
        let source = """
            /// Internal.
            struct Thing {}
            public enum Kind {
                /// A case of a public enum is public.
                case one
                /// A method without a modifier is internal.
                func run() {}
            }
            public extension Thing {
                /// Inherits public from its extension.
                func start() {}
            }
            """
        let found = FileChecker.check(path: "Sources/Thing.swift", text: source).filter { $0.rule == Rule.docOnNonAPI }
        #expect(found.map(\.line) == [1, 6])
    }

    @Test func marksAreForTests() {
        #expect(rules("// MARK: Setup\nlet x = 1\n") == [Rule.mark])
        #expect(rules("// MARK: Setup\nlet x = 1\n", path: "Tests/ThingTests.swift").isEmpty)
    }

    @Test func reasonsAreShort() {
        let four = "// One line of reason here.\n// Two.\n// Three.\n// Four.\nlet x = 1\n"
        #expect(rules(four) == [Rule.tooLong])
        #expect(rules("// One.\n// Two.\n// Three.\nlet x = 1\n").isEmpty)
    }

    @Test func escapeHatchesNeedAReason() {
        #expect(rules("func f() throws {}\nfunc g() {\n    try? f()\n}\n") == [Rule.discardedTry])
        #expect(rules("func f() throws {}\nfunc g() {\n    // Dropping the error is safe: the file is gone.\n    try? f()\n}\n").isEmpty)
        #expect(rules("nonisolated(unsafe) var x = 1\n") == [Rule.nonisolatedUnsafe])
        #expect(rules("final class C: @unchecked Sendable {}\n") == [Rule.uncheckedSendable])
        #expect(rules("// The lock in `state` serialises every access.\nfinal class C: @unchecked Sendable {}\n").isEmpty)
    }

    @Test func restatedNamesAreFlagged() {
        #expect(rules("// The bubble text.\nlet bubbleText = \"\"\n") == [Rule.restatesName])
        #expect(rules("// Trimmed so a pasted address matches the roster.\nlet bubbleText = \"\"\n").isEmpty)
    }

    @Test func densityIsMeasured() {
        let source = (0..<6).map { "// Reason \($0) for the line below.\nlet x\($0) = \($0)\n" }.joined()
            + (0..<24).map { "let y\($0) = \($0)\n" }.joined()
        let density = FileChecker.check(path: "Sources/Thing.swift", text: source).first { $0.rule == Rule.density }
        #expect(density?.message.hasPrefix("comments are 16%") == true)
        #expect(density?.measure == 6)
    }
}

struct BaselineTests {
    private func violation(_ fingerprint: String, measure: Int? = nil) -> Violation {
        Violation(file: "A.swift", line: 1, rule: measure == nil ? Rule.history : Rule.density, message: "m",
                  fingerprint: fingerprint, measure: measure)
    }

    @Test func coversRecordedViolationsOnly() {
        let baseline = Baseline(recording: [violation("// used to"), violation("", measure: 20)])
        let comparison = baseline.compare([violation("// used to"), violation("// used to"), violation("", measure: 15)],
                                          checked: ["A.swift"])
        #expect(comparison.reported.map(\.fingerprint) == ["// used to"])
        #expect(comparison.kept.count == 2)
        #expect(comparison.fixed == 1)
    }

    @Test func measuresMayOnlyFall() {
        let baseline = Baseline(recording: [violation("", measure: 20)])
        let comparison = baseline.compare([violation("", measure: 21)], checked: ["A.swift"])
        #expect(comparison.reported.count == 1)
        #expect(baseline.shrunk(by: comparison, checked: ["A.swift"]) == baseline)
    }

    @Test func deletedFilesAreDropped() {
        let gone = Violation(file: "Deleted/Gone.swift", line: 1, rule: Rule.history, message: "m", fingerprint: "// x")
        let baseline = Baseline(recording: [gone])
        let comparison = baseline.compare([], checked: [])
        #expect(comparison.fixed == 1)
        #expect(baseline.shrunk(by: comparison, checked: []).entries.isEmpty)
    }

    @Test func shrinkingNeverAdds() {
        let baseline = Baseline(recording: [violation("// used to"), violation("", measure: 20)])
        let comparison = baseline.compare([violation("", measure: 12), violation("// new")], checked: ["A.swift"])
        let next = baseline.shrunk(by: comparison, checked: ["A.swift"])
        #expect(next.entries == ["A.swift": [Rule.density: ["12"]]])
    }
}
