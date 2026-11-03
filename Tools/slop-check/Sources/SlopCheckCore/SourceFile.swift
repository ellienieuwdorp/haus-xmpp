import Foundation
import SwiftParser
import SwiftSyntax

struct SourceFile {
    let path: String
    let isTest: Bool
    let tree: SourceFileSyntax
    let lines: [String]
    private let converter: SourceLocationConverter

    init(path: String, text: String) {
        self.path = path
        isTest = path.range(of: #"(^|/)[A-Za-z]*Tests?/|Tests?\.swift$"#, options: .regularExpression) != nil
        tree = Parser.parse(source: text)
        lines = text.split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
        converter = SourceLocationConverter(fileName: path, tree: tree)
    }

    func line(at offset: Int) -> Int {
        converter.location(for: AbsolutePosition(utf8Offset: offset)).line
    }

    func line(of node: some SyntaxProtocol) -> Int {
        line(at: node.positionAfterSkippingLeadingTrivia.utf8Offset)
    }

    func text(ofLine line: Int) -> String {
        lines.indices.contains(line - 1) ? lines[line - 1].trimmingCharacters(in: .whitespaces) : ""
    }
}

struct Comment {
    enum Kind { case line, block, docLine, docBlock }

    let kind: Kind
    let text: String
    let line: Int
    let endLine: Int
    let offset: Int
    let isTrailing: Bool

    var isDoc: Bool { kind == .docLine || kind == .docBlock }
    var lineCount: Int { endLine - line + 1 }
    var isDirective: Bool { Patterns.directive.matches(text) }
}

enum CommentScanner {
    static func comments(in file: SourceFile) -> [Comment] {
        var out: [Comment] = []
        for token in file.tree.tokens(viewMode: .sourceAccurate) {
            scan(token.leadingTrivia, from: token.position.utf8Offset, trailing: false, in: file, into: &out)
            scan(token.trailingTrivia, from: token.endPositionBeforeTrailingTrivia.utf8Offset, trailing: true, in: file, into: &out)
        }
        return out
    }

    private static func scan(_ trivia: Trivia, from start: Int, trailing: Bool, in file: SourceFile, into out: inout [Comment]) {
        var offset = start
        for piece in trivia {
            let length = piece.sourceLength.utf8Length
            if let (kind, text) = classify(piece) {
                out.append(Comment(kind: kind, text: text, line: file.line(at: offset),
                                   endLine: file.line(at: offset + max(length - 1, 0)), offset: offset, isTrailing: trailing))
            }
            offset += length
        }
    }

    private static func classify(_ piece: TriviaPiece) -> (Comment.Kind, String)? {
        switch piece {
        case .lineComment(let text): (.line, String(text.dropFirst(2)))
        case .docLineComment(let text): (.docLine, String(text.dropFirst(3)))
        case .blockComment(let text): (.block, String(text.dropFirst(2).dropLast(2)))
        case .docBlockComment(let text): (.docBlock, String(text.dropFirst(3).dropLast(2)))
        default: nil
        }
    }
}
