struct CommentRules {
    let file: SourceFile
    let comments: [Comment]
    let index: DeclarationIndex

    func check(into report: inout Report) {
        for comment in comments {
            checkMarkers(comment, &report)
            checkProse(comment, &report)
            checkShape(comment, &report)
        }
        let apiDocLines = checkDocRuns(&report)
        checkLineRuns(&report)
        checkCommentsAbove(&report)
        checkDensity(excluding: apiDocLines, &report)
    }

    private func checkMarkers(_ comment: Comment, _ report: inout Report) {
        if Patterns.lintDisable.matches(comment.text) && !Patterns.lintReason.matches(comment.text) {
            report.add(comment.line, Rule.suppression,
                       "a swiftlint:disable needs its reason: `// swiftlint:disable:next rule_id - why the rule does not apply`")
        }
        if !file.isTest && Patterns.mark.matches(comment.text) {
            report.add(comment.line, Rule.mark,
                       "MARK in a source file; delete it. A file that needs sections should be split, and extensions already group conformances")
        }
        if let found = Patterns.marker.firstMatch(in: comment.text) {
            report.add(comment.line, Rule.marker,
                       "`\(found)` marker; delete it and track the work as an issue. Code describes what is true now")
        }
        if let found = Patterns.privateDocs.firstMatch(in: comment.text) {
            report.add(comment.line, Rule.privateDocs,
                       "comment points at documents outside this repository (`\(found)`); state the fact here in \(Limits.reasonLines) lines or fewer, or delete it")
        }
    }

    // Code spans are identifiers or literals, not prose: the prose rules read them as the word "code".
    private func checkProse(_ comment: Comment, _ report: inout Report) {
        let prose = Patterns.codeSpan.replacingMatches(in: comment.text)
        if let found = Patterns.citation.firstMatch(in: prose) {
            report.add(comment.line, Rule.citation,
                       "comment cites a task, plan or review label (`\(found)`); delete the label, the comment must stand on its own. XEP and RFC numbers are fine")
        }
        if let found = Patterns.history.firstMatch(in: prose) {
            report.add(comment.line, Rule.history,
                       "comment narrates history (`\(found)`); delete it, git keeps history. If a constraint remains, state it in the present tense")
        }
        if let found = Patterns.future.firstMatch(in: prose) {
            report.add(comment.line, Rule.future,
                       "comment plans future work (`\(found)`); delete it and track the work as an issue, or state the current constraint")
        }
    }

    private func checkShape(_ comment: Comment, _ report: inout Report) {
        guard !comment.isDirective else { return }
        if Patterns.banner.matches(comment.text) {
            report.add(comment.line, Rule.banner, "banner or separator comment; delete it")
        }
        if comment.kind == .line && !comment.isTrailing && Words.looksLikeCode(comment.text) {
            report.add(comment.line, Rule.commentedOutCode, "commented-out code; delete it, git keeps it")
        }
        if comment.kind == .block && comment.lineCount > Limits.reasonLines {
            report.add(comment.line, Rule.tooLong, tooLongMessage(comment.lineCount))
        }
    }

    private func tooLongMessage(_ lines: Int) -> String {
        "comment is \(lines) lines; state the mechanism in \(Limits.reasonLines) lines or fewer, or delete it"
    }

    // Returns the lines of doc comments on public, package or open API, which the density limit leaves out.
    private func checkDocRuns(_ report: inout Report) -> Set<Int> {
        var apiDocLines = Set<Int>()
        var run: [Comment] = []
        for comment in comments where comment.isDoc {
            if let last = run.last, last.kind == .docLine, comment.kind == .docLine, comment.line == last.endLine + 1 {
                run.append(comment)
            } else {
                apiDocLines.formUnion(checkDocRun(run, &report))
                run = [comment]
            }
        }
        apiDocLines.formUnion(checkDocRun(run, &report))
        return apiDocLines
    }

    private func checkDocRun(_ run: [Comment], _ report: inout Report) -> Set<Int> {
        guard let first = run.first else { return [] }
        let owner = run.reversed().lazy.compactMap { index.docOwners[$0.offset] }.first
        let lineCount = run.map(\.lineCount).reduce(0, +)
        if lineCount > Limits.docLines {
            report.add(first.line, Rule.docTooLong,
                       "doc comment is \(lineCount) lines; state the contract in \(Limits.docLines) lines or fewer")
        }
        guard let owner else {
            report.add(first.line, Rule.docOnNonAPI, "`///` that documents no declaration; delete it, or make it a `//` comment")
            return []
        }
        if Words.restates(run.map(\.text).joined(separator: " "), owner) {
            report.add(first.line, Rule.restatesName, "doc comment restates `\(owner.name)`; delete it")
        }
        if owner.isAPI {
            return Set(run.flatMap { $0.line...$0.endLine })
        }
        report.add(first.line, Rule.docOnNonAPI,
                   "`///` on `\(owner.name)`, which is \(owner.access): `///` is only for public, package or open API. Delete it, or keep the reason as a `//` comment of \(Limits.reasonLines) lines or fewer")
        return []
    }

    private func checkLineRuns(_ report: inout Report) {
        var run: [Comment] = []
        for comment in comments where comment.kind == .line && !comment.isTrailing && !comment.isDirective {
            if let last = run.last, comment.line == last.line + 1 {
                run.append(comment)
            } else {
                if run.count > Limits.reasonLines { report.add(run[0].line, Rule.tooLong, tooLongMessage(run.count)) }
                run = [comment]
            }
        }
        if run.count > Limits.reasonLines { report.add(run[0].line, Rule.tooLong, tooLongMessage(run.count)) }
    }

    private func checkCommentsAbove(_ report: inout Report) {
        let byOffset = Dictionary(comments.map { ($0.offset, $0) }) { first, _ in first }
        for (decl, offsets) in index.commentsAbove {
            let run = offsets.compactMap { byOffset[$0] }.filter { !$0.isDirective }
            guard let first = run.first, Words.restates(run.map(\.text).joined(separator: " "), decl) else { continue }
            report.add(first.line, Rule.restatesName, "comment restates `\(decl.name)`; delete it, or say why instead")
        }
    }

    private func checkDensity(excluding apiDocLines: Set<Int>, _ report: inout Report) {
        let nonBlank = file.lines.filter { !$0.trimmingCharacters(in: .whitespaces).isEmpty }.count
        guard nonBlank >= Limits.densityMinLines else { return }
        let ownLine = comments.filter { !$0.isTrailing && !$0.isDirective }
        let commentLines = Set(ownLine.flatMap { $0.line...$0.endLine }).subtracting(apiDocLines)
        let percent = commentLines.count * 100 / nonBlank
        guard percent > Limits.densityPercent else { return }
        report.add(1, Rule.density,
                   "comments are \(percent)% of this file's lines (limit \(Limits.densityPercent)%); delete the ones that restate the code",
                   measure: percent)
    }
}
