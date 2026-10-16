import Foundation
import XMPPProtocol

/// The emoji a reaction picker offers, with a name to search by. Built from the Unicode properties of this OS's
/// character data rather than a bundled list, so it follows the system's emoji as it updates: faces and people first,
/// then the other pictographs and symbols, the keycaps, then the flags. Skin tones turn up when searching by name.
/// Sequences joined with zero-width joiners (🏳️‍🌈, 👩‍💻) have no Unicode name to list them by, so the search takes any
/// emoji typed or pasted into it, from the system's Emoji & Symbols viewer, for example, as itself. Every entry is one
/// the wire layer accepts as a reaction (`MessageContent.isEmoji`).
enum EmojiCatalog {
    struct Entry: Hashable, Sendable {
        let emoji: String
        /// Lowercased words to match, from the Unicode name ("grinning face") or, for a flag, "flag" and the region.
        let name: String
    }

    /// Unicode blocks in picker order; within a block, code point order keeps related emoji together.
    private static let blocks: [ClosedRange<UInt32>] = [
        0x1F600...0x1F64F, // Emoticons
        0x1F900...0x1F9FF, // Supplemental Symbols and Pictographs
        0x1F466...0x1F4FF, // people, body, hearts, objects
        0x1FA70...0x1FAFF, // Symbols and Pictographs Extended-A
        0x1F300...0x1F465, // weather, food, celebration, sport, animals
        0x1F500...0x1F5FF,
        0x1F680...0x1F6FF, // Transport and Map
        0x2600...0x27BF,   // Miscellaneous Symbols, Dingbats
        0x2190...0x21FF, 0x2300...0x23FF, 0x25A0...0x25FF, 0x2B00...0x2BFF, 0x3030...0x303D, 0x3297...0x3299,
        0x1F004...0x1F0CF, 0x1F170...0x1F251,
    ]

    static let all: [Entry] = {
        var seen = Set<String>()
        var entries: [Entry] = []
        for block in blocks {
            for value in block {
                guard let scalar = Unicode.Scalar(value), let entry = entry(for: scalar), seen.insert(entry.emoji).inserted else { continue }
                entries.append(entry)
            }
        }
        // Two regional indicators make a flag; only codes the region list knows, so no pair falls back to letters.
        let flags = Locale.Region.isoRegions.compactMap { region -> Entry? in
            let code = region.identifier
            guard code.count == 2, code.allSatisfy({ $0.isASCII && $0.isUppercase }) else { return nil }
            let emoji = String(String.UnicodeScalarView(code.unicodeScalars.compactMap { Unicode.Scalar(0x1F1E6 + $0.value - 0x41) }))
            guard MessageContent.isEmoji(emoji), seen.insert(emoji).inserted else { return nil }
            let name = Locale(identifier: "en").localizedString(forRegionCode: code) ?? code
            return Entry(emoji: emoji, name: "flag \(name)".lowercased())
        }
        // A digit, # or * in a keycap: "keycap digit one".
        let keycaps = "#*0123456789".unicodeScalars.compactMap { scalar -> Entry? in
            let emoji = String(String.UnicodeScalarView([scalar, "\u{FE0F}", "\u{20E3}"]))
            guard MessageContent.isEmoji(emoji), let name = scalar.properties.name else { return nil }
            return Entry(emoji: emoji, name: "keycap " + name.lowercased())
        }
        return entries + keycaps + flags.sorted { $0.name < $1.name }
    }()

    /// The catalogue with each emoji that takes a skin tone followed by its five toned forms, for searching.
    private static let withTones: [Entry] = all.flatMap { entry -> [Entry] in
        guard let base = entry.emoji.unicodeScalars.first, base.properties.isEmojiModifierBase else { return [entry] }
        let toned = tones.compactMap { modifier, tone -> Entry? in
            // The modifier makes it an emoji; a text-presentation base drops its selector for it.
            let emoji = String(String.UnicodeScalarView([base, modifier]))
            return MessageContent.isEmoji(emoji) ? Entry(emoji: emoji, name: "\(entry.name) \(tone) skin tone") : nil
        }
        return [entry] + toned
    }

    private static let tones: [(Unicode.Scalar, String)] = [
        ("\u{1F3FB}", "light"), ("\u{1F3FC}", "medium-light"), ("\u{1F3FD}", "medium"), ("\u{1F3FE}", "medium-dark"), ("\u{1F3FF}", "dark"),
    ]

    /// For an empty query the catalogue. For a query of emoji alone, those emoji, so any sequence the system can type
    /// is a choice. Otherwise the entries and toned forms whose name contains every word of `query`, in catalogue order.
    static func search(_ query: String) -> [Entry] {
        let words = query.lowercased().split(whereSeparator: \.isWhitespace)
        guard !words.isEmpty else { return all }
        let typed = query.filter { !$0.isWhitespace }.map { character -> String in
            // A pictograph typed in its text form (❤ without the emoji selector) means the emoji; an ASCII digit does not.
            guard character.unicodeScalars.count == 1, let scalar = character.unicodeScalars.first, scalar.properties.isEmoji, !scalar.isASCII,
                  !MessageContent.isEmoji(String(character)) else { return String(character) }
            return String(character) + "\u{FE0F}"
        }
        if typed.allSatisfy(MessageContent.isEmoji) {
            var seen = Set<String>()
            return typed.filter { seen.insert($0).inserted }.map { emoji in
                Entry(emoji: emoji, name: withTones.first { $0.emoji == emoji }?.name ?? TimelineReaction.name(for: emoji))
            }
        }
        return withTones.filter { entry in words.allSatisfy { entry.name.contains($0) } }
    }

    /// An emoji-presentation pictograph as it is, a text-presentation one with the emoji selector; nothing for
    /// components (skin tones, regional indicators, keycap digits) that only mean something in a sequence.
    private static func entry(for scalar: Unicode.Scalar) -> Entry? {
        let properties = scalar.properties
        guard properties.isEmoji, !properties.isEmojiModifier, !(0x1F1E6...0x1F1FF).contains(scalar.value),
              let name = properties.name else { return nil }
        var emoji = String(Character(scalar))
        if !properties.isEmojiPresentation { emoji.unicodeScalars.append("\u{FE0F}") }
        guard MessageContent.isEmoji(emoji) else { return nil }
        return Entry(emoji: emoji, name: name.lowercased())
    }
}
