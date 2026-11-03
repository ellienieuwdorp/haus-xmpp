import SwiftSyntax

private struct Hatch {
    let node: Syntax
    let rule: String
    let message: String
}

private final class HatchFinder: SyntaxVisitor {
    private(set) var hatches: [Hatch] = []

    override func visit(_ node: TryExprSyntax) -> SyntaxVisitorContinueKind {
        if node.questionOrExclamationMark?.tokenKind == .postfixQuestionMark, isDiscarded(node), !isInDefer(node) {
            let message = node.expression.trimmedDescription.contains("Task.sleep")
                ? "`try? await Task.sleep` swallows cancellation; use `try await` and let CancellationError end the task, or check Task.isCancelled on the next line"
                : "`try?` discards the error; handle or log it, or state on the line above why dropping it is safe"
            hatches.append(Hatch(node: Syntax(node), rule: Rule.discardedTry, message: message))
        }
        return .visitChildren
    }

    override func visit(_ node: AttributedTypeSyntax) -> SyntaxVisitorContinueKind {
        if node.attributes.trimmedDescription.contains("@unchecked") {
            hatches.append(Hatch(node: Syntax(node), rule: Rule.uncheckedSendable,
                                 message: "`@unchecked Sendable` needs a `//` reason above the type naming what serialises access"))
        }
        return .visitChildren
    }

    override func visit(_ node: DeclModifierSyntax) -> SyntaxVisitorContinueKind {
        if node.name.text == "nonisolated", node.detail?.detail.text == "unsafe" {
            hatches.append(Hatch(node: Syntax(node), rule: Rule.nonisolatedUnsafe,
                                 message: "`nonisolated(unsafe)` needs a `//` reason above it naming what makes access safe"))
        }
        return .visitChildren
    }

    // `defer { try? file.close() }`: a close failure after the work is done has nobody to report to.
    private func isInDefer(_ node: some SyntaxProtocol) -> Bool {
        var current = node.parent
        while let parent = current, !parent.is(FunctionDeclSyntax.self), !parent.is(ClosureExprSyntax.self) {
            if parent.is(DeferStmtSyntax.self) { return true }
            current = parent.parent
        }
        return false
    }

    // A statement of its own, or assigned to `_`.
    private func isDiscarded(_ node: TryExprSyntax) -> Bool {
        var current = Syntax(node)
        while let parent = current.parent {
            if parent.is(CodeBlockItemSyntax.self) { return true }
            if let sequence = parent.as(ExprListSyntax.self) {
                return sequence.first?.is(DiscardAssignmentExprSyntax.self) == true
            }
            guard parent.is(AwaitExprSyntax.self) else { return false }
            current = parent
        }
        return false
    }
}

enum EscapeHatches {
    static func check(_ file: SourceFile, comments: [Comment], into report: inout Report) {
        let finder = HatchFinder(viewMode: .sourceAccurate)
        finder.walk(file.tree)
        let reasons = reasonLines(comments)
        for hatch in finder.hatches where !isJustified(hatch, in: file, reasons: reasons) {
            report.add(file.line(of: hatch.node), hatch.rule, hatch.message)
        }
    }

    // A reason is a prose comment of three or more words.
    private static func reasonLines(_ comments: [Comment]) -> Set<Int> {
        let reasons = comments.filter { Words.split($0.text).count >= 3 && !Words.looksLikeCode($0.text) }
        return Set(reasons.flatMap { $0.line...$0.endLine })
    }

    // The reason sits on the line above the enclosing statement or declaration, or on its first lines.
    private static func isJustified(_ hatch: Hatch, in file: SourceFile, reasons: Set<Int>) -> Bool {
        let line = file.line(of: hatch.node)
        var statement = hatch.node
        while let parent = statement.parent, !parent.is(CodeBlockItemListSyntax.self), !parent.is(MemberBlockItemListSyntax.self) {
            statement = parent
        }
        let start = file.line(of: statement)
        let end = file.line(at: statement.endPositionBeforeTrailingTrivia.utf8Offset)
        let following = file.lines.dropFirst(line).prefix(2).joined()
        if hatch.rule == Rule.discardedTry && (following.contains("Task.isCancelled") || following.contains("checkCancellation")) {
            return true
        }
        return (start - 1...max(start, min(end, line + 1))).contains { reasons.contains($0) }
    }
}
