import Foundation

/// Which incoming messages of a chat may alert. Local only: never sent to the server.
public enum ChatNotificationLevel: String, Sendable, Equatable, CaseIterable {
    /// Every incoming message.
    case all
    /// Groups only: a message that mentions this account (see `Mention`).
    case mentions
}

/// A chat's notification choice. `mutedUntil` overrides the level while it lies in the future; an expired mute
/// reads as unmuted without anyone clearing it.
public struct ChatNotificationSetting: Sendable, Equatable {
    public var level: ChatNotificationLevel
    /// Nil when not muted. `ChatNotificationSetting.always` (a far-future instant) means muted until unmuted.
    public var mutedUntil: Date?

    /// The stored instant for "muted until I unmute": 3000-01-01T00:00:00Z. Any later instant also reads as always.
    public static let always = Date(timeIntervalSince1970: 32_503_680_000)

    public init(level: ChatNotificationLevel = .all, mutedUntil: Date? = nil) {
        self.level = level
        self.mutedUntil = mutedUntil
    }

    public func isMuted(at now: Date = Date()) -> Bool { mutedUntil.map { $0 > now } ?? false }
    public var isMutedAlways: Bool { mutedUntil.map { $0 >= Self.always } ?? false }
}

/// Mention detection over a decrypted body. Pure: no storage, no network.
///
/// The user is mentioned when the text names them (their room nickname, account localpart or bare JID),
/// case-insensitively and on word boundaries. A text that names more than `massMentionLimit` room members
/// (the user included) is a mass mention and does not count.
public enum Mention {
    public static let massMentionLimit = 5

    /// - Parameters:
    ///   - account: the account's bare JID.
    ///   - nickname: the account's own nickname in this room, when known.
    ///   - members: the room's members as bare JIDs; the account may be among them.
    public static func mentions(_ text: String, account: String, nickname: String?, members: [String]) -> Bool {
        let own = names(jid: account) + [nickname].compactMap { $0 }
        guard own.contains(where: { names($0, in: text) }) else { return false }
        let others = Set(members.map { $0.lowercased() }).subtracting([account.lowercased()])
        let named = others.filter { member in names(jid: member).contains { names($0, in: text) } }.count + 1
        return named <= massMentionLimit
    }

    /// A bare JID's names: its localpart and the whole address.
    static func names(jid: String) -> [String] {
        guard let at = jid.firstIndex(of: "@") else { return [jid] }
        return [String(jid[..<at]), jid]
    }

    /// Whether `name` occurs in `text` with no letter, digit or underscore directly on either side.
    /// Names shorter than two characters never match: a one-letter localpart would match ordinary words.
    static func names(_ name: String, in text: String) -> Bool {
        let name = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard name.count >= 2 else { return false }
        var searchStart = text.startIndex
        while searchStart < text.endIndex,
              let range = text.range(of: name, options: [.caseInsensitive], range: searchStart..<text.endIndex) {
            let before = range.lowerBound == text.startIndex ? nil : text[text.index(before: range.lowerBound)]
            let after = range.upperBound == text.endIndex ? nil : text[range.upperBound]
            if !isWordCharacter(before), !isWordCharacter(after) { return true }
            searchStart = text.index(after: range.lowerBound)
        }
        return false
    }

    private static func isWordCharacter(_ character: Character?) -> Bool {
        guard let character else { return false }
        return character.isLetter || character.isNumber || character == "_"
    }
}
