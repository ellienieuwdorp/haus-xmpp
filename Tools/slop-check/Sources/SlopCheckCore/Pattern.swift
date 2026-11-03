import Foundation

// NSRegularExpression rather than Swift Regex literals: on these patterns Regex ran several times slower.
struct Pattern: Sendable {
    private let regex: NSRegularExpression

    init(_ source: String) {
        // swiftlint:disable:next force_try - every pattern is a literal below, and the tests compile each one
        regex = try! NSRegularExpression(pattern: source)
    }

    func firstMatch(in text: String) -> String? {
        let range = NSRange(text.startIndex..., in: text)
        guard let match = regex.firstMatch(in: text, range: range), let found = Range(match.range, in: text) else {
            return nil
        }
        return String(text[found])
    }

    func matches(_ text: String) -> Bool {
        firstMatch(in: text) != nil
    }

    func replacingMatches(in text: String) -> String {
        regex.stringByReplacingMatches(in: text, range: NSRange(text.startIndex..., in: text), withTemplate: "code")
    }
}

enum Patterns {
    static let directive = Pattern(#"^\s*(swiftlint:|swift-format-ignore|swiftformat:|periphery:|sourcery:|MARK\b|-\s*Tag:)"#)
    static let mark = Pattern(#"^\s*MARK\b"#)
    static let banner = Pattern(#"([-=*#~_/])\1{3,}|[─━═│┃]"#)
    static let codeSpan = Pattern("`[^`]*`")
    static let marker = Pattern(#"\b(TODO|FIXME|HACK|XXX)\b|\b(?i:ponytail)\b"#)
    static let lintDisable = Pattern(#"swiftlint:disable"#)
    static let lintReason = Pattern(#"swiftlint:disable(:next|:this|:previous)?\s+\S+(\s+\S+)*?\s+-\s+\S"#)
    static let privateDocs = Pattern(#"\bdocs/|\b(AGENTS|CLAUDE)\.md\b"#)

    // Short work-item labels (`G3`, `M1–M4`, `(S5)`), tracker keys (`MS-124`), plan vocabulary (`Phase B`,
    // `round 2`) and review words. Standards keep their numbers: XEP-0444, RFC 6120, SHA-256, P-256, X25519.
    static let citation = Pattern(
        #"\b(?!(?:C0|C1|GS2|VS15|VS16|MP3|MP4|H2|H3)\b)[A-Z]{1,2}[0-9]{1,2}\b"#
            + #"|\b(?!(?:XEP|RFC|SHA|AES|UTF|ISO|CVE|SE|FB|TLS|HTTP|PKCS|RSA|CRC|NIST|ECDSA|SASL)-)[A-Z]{2,5}-[0-9]{1,5}\b"#
            + #"|\b(?i:phase|round|wave|sprint|milestone|plan|stage|step|track)\s+(?:[A-Z]|[0-9]{1,2})\b"#
            + #"|\b(?i:critique|backlog)\b"#
    )

    static let history = Pattern(
        #"(?<!\b(?:is|are|be|was|were|been|being|get|gets|got) )\b(?i:used to)\b"#
            + #"|\b(?i:previously)\b(?!\s+[a-z]+ed\b)"#
            + #"|\b(?i:as (?:it )?(?:did|before))(?=\s*[.,;:)]|\s*$)"#
            + #"|\b(?i:before the (?:split|change|fix|refactor|rewrite|move))\b"#
            + #"|(?<!\b(?:right|just|from|until|by|for) )\b[Nn]ow (?!(?:unless|as|its|this|thus|across)\b)(?:[a-z]+s|is|are|has|have|can|also|always|only|never|correctly)\b"#
            + #"|\b(?i:(?:copied|taken|ported|lifted|kept) verbatim|verbatim (?:from|copy)|verbatim\s*,)"#
            + #"|\b(?i:measured (?:on|in|with) (?:an? |the )?(?:real |physical )?(?:iPhone|iPad|Mac|device|simulator|iOS|macOS))"#
            + #"|\b(?i:(?:was|were|been|got) (?:fixed|wrong|broken))\b"#
            + #"|\b(?i:we (?:now|changed|switched|moved|added|removed|replaced))\b"#
            + #"|\b(?i:(?:old|original|earlier|previous) (?:implementation|code|approach|workaround|behaviou?r))\b"#
            + #"|\b(?i:this (?:commit|PR|pull request))\b"#
    )

    static let future = Pattern(
        #"\b(?i:for now)\b"#
            + #"|\b(?i:if (?:this|that|it|we|they) ever)\b"#
            + #"|\b(?i:someday)\b"#
            + #"|\b(?i:future (?:work|version|change|pipeline|refactor|cleanup|PR)|later (?:version|refactor|cleanup|PR))\b"#
            + #"|\b(?i:move (?:this |it )?off[- ]main)\b"#
    )
}
