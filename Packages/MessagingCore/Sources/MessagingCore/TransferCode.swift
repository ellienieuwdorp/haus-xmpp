import Foundation

/// The secret that opens one transfer archive: 24 random symbols of Crockford's base32 (120 bits), shown as six groups
/// of four. The source generates it and shows it once per transfer; the target types or pastes it.
///
/// It is random, not chosen by a person, so the archive key comes from it through HKDF directly; no password
/// stretching is needed. Contains a secret: it has no printable description, and only `grouped` spells it out.
public struct TransferCode: Sendable, Equatable {
    public static let groupCount = 6
    public static let groupLength = 4
    public static let length = groupCount * groupLength
    /// Crockford's base32: no I, L, O or U, so a misread 1/I/L or 0/O still parses.
    static let alphabet = Array("0123456789ABCDEFGHJKMNPQRSTVWXYZ")

    /// Each symbol's value, 0 to 31.
    let values: [UInt8]

    /// A fresh code from the system's cryptographically secure generator.
    public static func generate() -> TransferCode {
        var generator = SystemRandomNumberGenerator()
        return TransferCode(values: (0..<length).map { _ in UInt8.random(in: 0..<32, using: &generator) })
    }

    private init(values: [UInt8]) { self.values = values }

    /// Reads a code as typed or pasted: case, spaces, hyphens and line breaks do not matter, and O reads as 0 and I or L
    /// as 1. Nil unless exactly 24 symbols remain.
    public init?(_ text: String) {
        var values: [UInt8] = []
        for character in text.uppercased() {
            if character == " " || character == "-" || character.isNewline || character == "\t" { continue }
            let mapped: Character
            switch character {
            case "O": mapped = "0"
            case "I", "L": mapped = "1"
            default: mapped = character
            }
            guard let index = Self.alphabet.firstIndex(of: mapped) else { return nil }
            values.append(UInt8(index))
        }
        guard values.count == Self.length else { return nil }
        self.values = values
    }

    /// The six groups of four, for display.
    public var groups: [String] {
        stride(from: 0, to: Self.length, by: Self.groupLength).map { start in
            String(values[start..<start + Self.groupLength].map { Self.alphabet[Int($0)] })
        }
    }

    /// The code as one line, groups joined by hyphens: what Copy puts on the clipboard.
    public var grouped: String { groups.joined(separator: "-") }

    /// The 120 bits, packed into 15 bytes: the key derivation's input.
    var keyMaterial: Data {
        var bytes = Data(), buffer: UInt32 = 0, bits = 0
        for value in values {
            buffer = (buffer << 5) | UInt32(value)
            bits += 5
            while bits >= 8 {
                bits -= 8
                bytes.append(UInt8((buffer >> UInt32(bits)) & 0xFF))
            }
        }
        return bytes
    }
}

extension TransferCode: CustomStringConvertible, CustomDebugStringConvertible {
    public var description: String { "TransferCode(redacted)" }
    public var debugDescription: String { description }
}
