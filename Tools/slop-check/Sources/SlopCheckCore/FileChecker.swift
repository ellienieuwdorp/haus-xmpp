struct Report {
    let file: SourceFile
    private(set) var violations: [Violation] = []

    init(_ file: SourceFile) {
        self.file = file
    }

    mutating func add(_ line: Int, _ rule: String, _ message: String, measure: Int? = nil) {
        violations.append(Violation(file: file.path, line: line, rule: rule, message: message,
                                    fingerprint: file.text(ofLine: line), measure: measure))
    }
}

package enum FileChecker {
    package static func check(path: String, text: String) -> [Violation] {
        let file = SourceFile(path: path, text: text)
        let comments = CommentScanner.comments(in: file)
        var report = Report(file)
        CommentRules(file: file, comments: comments, index: DeclarationIndex(file.tree)).check(into: &report)
        if !file.isTest {
            EscapeHatches.check(file, comments: comments, into: &report)
        }
        return report.violations.sorted { $0.line < $1.line }
    }
}
