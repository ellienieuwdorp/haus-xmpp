@testable import SlopCheckCore
import Testing

struct PatternTests {
    @Test(arguments: ["critique G3", "(S5)", "MS-124", "CX-1", "M1–M4", "Phase B", "round 2", "Plan D8", "per the backlog"])
    func citesALabel(_ text: String) {
        #expect(Patterns.citation.matches(text))
    }

    @Test(arguments: [
        "XEP-0444", "RFC 6120 §6", "SHA-256", "AES-256-GCM", "P-256", "UTF-8", "UTF-16", "X25519", "Ed25519",
        "SCRAM-SHA-256", "HMAC-SHA256", "IPv4 and IPv6", "NAT64", "C0 and C1 controls", "VS16", "SASL1", "GS2 flag",
        "SE-0480", "ISO 8601", "TLS 1.3", "OMEMO 2", "base64", "HTTP/2", "one step at a time", "the scene phase a window sees"
    ])
    func allowsAStandard(_ text: String) {
        #expect(!Patterns.citation.matches(text))
    }

    @Test(arguments: [
        "each chat used to build its own source", "Previously never replayable.", "keeps no baseline, as before.",
        "before the split", "the rest of the app now uses", "copied verbatim from the old file",
        "measured on the iPhone", "measured on iOS 27", "the race was fixed", "we switched to a lease",
        "the old implementation", "this commit"
    ])
    func narratesHistory(_ text: String) {
        #expect(Patterns.history.matches(text))
    }

    @Test(arguments: [
        "pure encoding is used to persist the ciphertext", "a server that cannot answer right now is retried",
        "replays only previously authorized bytes", "the body stays verbatim without a reply",
        "the room is rejoined now unless a join is pending", "the bubble was measured with the keyboard up",
        "the previous version's data", "As before code: an identity mismatch fails closed"
    ])
    func allowsPresentTense(_ text: String) {
        #expect(!Patterns.history.matches(text))
    }

    @Test(arguments: ["files are refused for now", "if this ever changes", "Move off-main if it stutters", "future work"])
    func plansFutureWork(_ text: String) {
        #expect(Patterns.future.matches(text))
    }

    @Test(arguments: ["a mute that lies in the future", "only later work showed it", "a later release of the lock"])
    func allowsTimeWords(_ text: String) {
        #expect(!Patterns.future.matches(text))
    }

    @Test(arguments: ["TODO: x", "FIXME", "ponytail: rooms wait", "XXX"])
    func findsMarkers(_ text: String) {
        #expect(Patterns.marker.matches(text))
    }

    @Test func requiresASuppressionReason() {
        #expect(Patterns.lintReason.matches(" swiftlint:disable:next force_try - the literal is checked by a test"))
        #expect(!Patterns.lintReason.matches(" swiftlint:disable:next force_try"))
        #expect(!Patterns.lintReason.matches(" swiftlint:disable:next force_try because"))
    }
}
