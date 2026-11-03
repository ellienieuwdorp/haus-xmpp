import Foundation
import SwiftParser
import SwiftSyntax

enum Words {
    // A comment of at most this many content words, mostly words of its declaration's signature, restates it.
    static let restateMaxWords = 10
    static let restateRatio = 0.6

    static let stopwords: Set<String> = [
        "a", "an", "the", "is", "are", "be", "this", "that", "of", "to", "for", "in", "on", "or", "and", "it", "its",
        "if", "whether", "returns", "return", "true", "false", "when", "with", "by", "as", "from", "gets", "get",
        "sets", "set", "current", "currently", "given", "value", "which", "has", "have", "can", "does", "do", "not",
        "nil", "otherwise", "called", "used", "use", "uses", "here", "there", "one", "all", "any", "new", "make",
        "makes", "create", "creates", "type", "property", "method", "function", "func", "var", "let", "init",
        "initializer", "instance", "struct", "class", "enum", "protocol", "case", "self", "string", "bool", "int"
    ]

    // Lowercased words, with camelCase identifiers split into their parts.
    static func split(_ text: String) -> [String] {
        text.split { !$0.isLetter && !$0.isNumber }.flatMap(splitCamelCase)
    }

    private static func splitCamelCase(_ raw: Substring) -> [String] {
        var out: [String] = []
        var current = ""
        var previousLower = false
        for character in raw {
            if character.isUppercase && previousLower && !current.isEmpty {
                out.append(current.lowercased())
                current = ""
            }
            current.append(character)
            previousLower = character.isLowercase || character.isNumber
        }
        if !current.isEmpty { out.append(current.lowercased()) }
        return out
    }

    static func stem(_ word: String) -> String {
        for suffix in ["ing", "ed", "es", "s"] where word.count > suffix.count + 3 && word.hasSuffix(suffix) {
            return String(word.dropLast(suffix.count))
        }
        return word
    }

    static func restates(_ comment: String, _ decl: Declaration) -> Bool {
        let content = split(comment).filter { !stopwords.contains($0) }
        guard !content.isEmpty, content.count <= restateMaxWords else { return false }
        let vocabulary = Set(decl.vocabulary.map(stem))
        let known = content.filter { vocabulary.contains(stem($0)) }.count
        return Double(known) / Double(content.count) >= restateRatio
    }

    // Text that parses as Swift statements, other than a bare name, is commented-out code.
    static func looksLikeCode(_ text: String) -> Bool {
        let trimmed = text.trimmingCharacters(in: .whitespaces)
        let hasCodeShape = trimmed.rangeOfCharacter(from: CharacterSet(charactersIn: "(){}=;[]")) != nil
            || ["return ", "let ", "var "].contains { trimmed.hasPrefix($0) }
        guard trimmed.count > 2, hasCodeShape else { return false }
        let tree = Parser.parse(source: trimmed)
        guard !tree.hasError, let first = tree.statements.first else { return false }
        let bareName = first.item.is(DeclReferenceExprSyntax.self) || first.item.is(MemberAccessExprSyntax.self)
        return !(tree.statements.count == 1 && bareName)
    }
}
