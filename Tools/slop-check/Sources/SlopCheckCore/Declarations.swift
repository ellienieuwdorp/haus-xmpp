import SwiftSyntax

struct Declaration {
    let name: String
    let vocabulary: Set<String>
    let access: String

    var isAPI: Bool { ["public", "open", "package"].contains(access) }
}

// Effective access: an explicit modifier, else what an extension or protocol gives its members, or an enum its
// cases. Anything inside a code block, closure or accessor is local.
private struct Scope {
    var memberAccess: String?
    var caseAccess: String?
    var isLocal = false
}

struct DeclarationIndex {
    // Offset of each doc comment piece in a declaration's leading trivia.
    private(set) var docOwners: [Int: Declaration] = [:]
    // Own-line `//` comments directly above a declaration, by offset.
    private(set) var commentsAbove: [(Declaration, [Int])] = []

    init(_ tree: SourceFileSyntax) {
        walk(Syntax(tree), Scope())
    }

    private mutating func walk(_ node: Syntax, _ scope: Scope) {
        var inner = Scope(isLocal: scope.isLocal)
        if let decl = node.as(DeclSyntax.self), let found = describe(decl, scope) {
            attach(node, found)
            inner.memberAccess = memberAccess(of: decl, found)
            inner.caseAccess = decl.is(EnumDeclSyntax.self) ? found.access : nil
        }
        if node.is(CodeBlockSyntax.self) || node.is(ClosureExprSyntax.self) || node.is(AccessorBlockSyntax.self) {
            inner.isLocal = true
        }
        let structural = node.is(MemberBlockSyntax.self) || node.is(MemberBlockItemListSyntax.self)
            || node.is(MemberBlockItemSyntax.self) || node.is(IfConfigDeclSyntax.self)
            || node.is(IfConfigClauseListSyntax.self) || node.is(IfConfigClauseSyntax.self)
        for child in node.children(viewMode: .sourceAccurate) {
            walk(child, structural ? scope : inner)
        }
    }

    private func memberAccess(of decl: DeclSyntax, _ found: Declaration) -> String? {
        if decl.is(ExtensionDeclSyntax.self) { return explicitAccess(decl) }
        return decl.is(ProtocolDeclSyntax.self) ? found.access : nil
    }

    private func describe(_ decl: DeclSyntax, _ scope: Scope) -> Declaration? {
        guard let (name, extra) = Self.signature(of: decl) else { return nil }
        let inherited = decl.is(EnumCaseDeclSyntax.self) ? scope.caseAccess : scope.memberAccess
        let access = scope.isLocal ? "local" : explicitAccess(decl) ?? inherited ?? "internal"
        return Declaration(name: name, vocabulary: Set(([name] + extra).flatMap(Words.split)), access: access)
    }

    private func explicitAccess(_ decl: DeclSyntax) -> String? {
        let levels: Set<String> = ["public", "open", "package", "internal", "fileprivate", "private"]
        let modifiers = decl.asProtocol(WithModifiersSyntax.self)?.modifiers
        return modifiers?.first { $0.detail == nil && levels.contains($0.name.text) }?.name.text
    }

    private static func signature(of decl: DeclSyntax) -> (String, [String])? {
        switch decl.as(DeclSyntaxEnum.self) {
        case .functionDecl(let d): (d.name.text, words(d.signature.parameterClause) + [d.signature.returnClause?.type.description].compactMap { $0 })
        case .initializerDecl(let d): ("init", words(d.signature.parameterClause))
        case .variableDecl(let d): (d.bindings.map(\.pattern.trimmedDescription).joined(separator: " "), d.bindings.compactMap { $0.typeAnnotation?.type.description })
        case .structDecl(let d): (d.name.text, [])
        case .classDecl(let d): (d.name.text, [])
        case .enumDecl(let d): (d.name.text, [])
        case .actorDecl(let d): (d.name.text, [])
        case .protocolDecl(let d): (d.name.text, [])
        case .typeAliasDecl(let d): (d.name.text, [])
        case .associatedTypeDecl(let d): (d.name.text, [])
        case .macroDecl(let d): (d.name.text, [])
        case .enumCaseDecl(let d): (d.elements.map(\.name.text).joined(separator: " "), [])
        case .extensionDecl(let d): (d.extendedType.trimmedDescription, [])
        case .subscriptDecl(let d): ("subscript", words(d.parameterClause))
        default: nil
        }
    }

    private static func words(_ clause: FunctionParameterClauseSyntax) -> [String] {
        clause.parameters.flatMap { [$0.firstName.text, $0.secondName?.text, $0.type.description].compactMap { $0 } }
    }

    // Doc comments attach to the declaration whose first token carries them. A `//` run counts as above the
    // declaration when at most one newline separates the run's last line from it.
    private mutating func attach(_ node: Syntax, _ decl: Declaration) {
        guard let first = node.firstToken(viewMode: .sourceAccurate) else { return }
        var offset = first.position.utf8Offset
        var run: [Int] = []
        var newlines = 0
        for piece in first.leadingTrivia {
            switch piece {
            case .docLineComment, .docBlockComment: docOwners[offset] = decl
            case .lineComment:
                if newlines > 1 { run = [] }
                run.append(offset)
                newlines = 0
            case .newlines(let count), .carriageReturnLineFeeds(let count): newlines += count
            default: break
            }
            offset += piece.sourceLength.utf8Length
        }
        if !run.isEmpty && newlines <= 1 { commentsAbove.append((decl, run)) }
    }
}
