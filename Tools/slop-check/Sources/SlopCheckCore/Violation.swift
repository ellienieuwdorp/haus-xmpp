package struct Violation: Sendable, Equatable {
    package let file: String
    package let line: Int
    package let rule: String
    package let message: String
    // The trimmed source line, so a baselined violation still matches after lines above it move.
    package let fingerprint: String
    // Set for rules that measure the whole file; the baseline records the value, which may only fall.
    package let measure: Int?

    package init(file: String, line: Int, rule: String, message: String, fingerprint: String, measure: Int? = nil) {
        self.file = file
        self.line = line
        self.rule = rule
        self.message = message
        self.fingerprint = fingerprint
        self.measure = measure
    }

    package var baselineEntry: String { measure.map(String.init) ?? fingerprint }
}

enum Limits {
    static let docLines = 8
    static let reasonLines = 3
    static let densityPercent = 10
    static let densityMinLines = 30
}

enum Rule {
    static let docOnNonAPI = "comment.doc-on-non-api"
    static let docTooLong = "comment.doc-too-long"
    static let tooLong = "comment.too-long"
    static let restatesName = "comment.restates-name"
    static let mark = "comment.mark"
    static let marker = "comment.marker"
    static let citation = "comment.citation"
    static let history = "comment.history"
    static let future = "comment.future"
    static let privateDocs = "comment.private-docs"
    static let banner = "comment.banner"
    static let commentedOutCode = "comment.commented-out-code"
    static let density = "comment.density"
    static let suppression = "suppression.needs-reason"
    static let discardedTry = "unsafe.discarded-try"
    static let uncheckedSendable = "unsafe.unchecked-sendable"
    static let nonisolatedUnsafe = "unsafe.nonisolated-unsafe"
}
