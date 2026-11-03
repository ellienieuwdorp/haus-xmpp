import AppKit
import XCTest
@testable import HausXMPP

// The Mac counterpart of the iPhone's `TimelineCellSemanticsTests`. Cells are laid out from their row record as the
// table does, but in no window: nothing here is ever on screen.
@MainActor
final class MacTimelineCellTests: XCTestCase {
    private let context = MacTimelineCellContext()
    private let sentAt = Date(timeIntervalSince1970: 1_789_380_000)
    private let width: CGFloat = 700
    private let side = MacTimelineMetrics.sidePadding

    override func tearDown() async throws {
        XCTAssertEqual(NSApp.windows.filter(\.isVisible).count, 0, "no window was shown")
        XCTAssertFalse(NSApp.isActive)
    }

    private func message(_ id: String = "m", body: String = "Ok", outgoing: Bool, starred: Bool = false,
                         reactions: [TimelineReaction] = [], edited: Bool = false) -> TimelineMessage {
        TimelineMessage(id: id, body: body, isOutgoing: outgoing, isStarred: starred, sentAt: sentAt,
                        status: outgoing ? .displayed : nil, reactions: reactions, canReact: true, isEdited: edited)
    }

    // A fresh measurer each time: its natural-width cache is per revision, and a cached width would hide a change.
    private func record(_ message: TimelineMessage, width: CGFloat) -> MacRowLayout {
        let row = TimelineRow(message: message, dateHeader: nil, startsRun: true, endsRun: true)
        let metrics = MacTimelineMetrics.shared
        let input = MacBubbleTextBuilder.input(row, revision: 0, isGroup: false, accent: context.accent, body: metrics.body)
        return MacRowMeasurer(metrics: metrics, sizer: nil, natural: MacNaturalWidths()).layout(input, tableWidth: width)
    }

    private func cell(_ message: TimelineMessage, width: CGFloat? = nil) -> MacTimelineMessageCell {
        let width = width ?? self.width
        let layout = record(message, width: width)
        let cell = MacTimelineMessageCell(drawsWhole: layout.drawsWhole, context: context)
        cell.frame = CGRect(x: 0, y: 0, width: width, height: layout.height)
        cell.configure(layout, message: message)
        cell.layoutSubtreeIfNeeded()
        return cell
    }

    private func part<View: NSView>(_ kind: View.Type, of cell: MacTimelineMessageCell) throws -> View {
        try XCTUnwrap(cell.subviews.compactMap { $0 as? View }.first, "\(kind)")
    }

    private func footerPlacement(_ cell: MacTimelineMessageCell) throws -> MacFooterView.Placement {
        let footer = try part(MacFooterView.self, of: cell)
        return MacFooterView.placement(footer.content, in: footer.bounds, metrics: .shared)
    }

    private func render(_ view: NSView) throws -> NSBitmapImageRep {
        let rep = try XCTUnwrap(view.bitmapImageRepForCachingDisplay(in: view.bounds))
        view.cacheDisplay(in: view.bounds, to: rep)
        return rep
    }

    private func png(_ view: NSView) throws -> Data { try XCTUnwrap(try render(view).representation(using: .png, properties: [:])) }

    private func label(_ outgoing: Bool) -> String { outgoing ? "own" : "received" }

    // Every footer reserves the star's slot.
    func testStarringKeepsTheBubbleAndItsFooterWhereTheyWere() throws {
        for outgoing in [true, false] {
            let plain = cell(message(outgoing: outgoing))
            let starred = cell(message(outgoing: outgoing, starred: true))
            XCTAssertEqual(starred.bubble.frame, plain.bubble.frame, label(outgoing))
            XCTAssertEqual(starred.textView.frame, plain.textView.frame, label(outgoing))
            XCTAssertEqual(try part(MacFooterView.self, of: starred).frame, try part(MacFooterView.self, of: plain).frame, label(outgoing))
            let before = try footerPlacement(plain), after = try footerPlacement(starred)
            XCTAssertNil(before.star)
            XCTAssertNotNil(after.star)
            XCTAssertEqual(after.text, before.text, "the time stays put: \(label(outgoing))")
            XCTAssertEqual(after.glyph, before.glyph, "the receipt stays put: \(label(outgoing))")
        }
    }

    // The narrowest bubble with the longest footer: its width comes from the footer alone.
    func testTimeStarAndReceiptStayInsideTheBubbleOnOneLine() throws {
        for outgoing in [true, false] {
            let cell = cell(message(body: "k", outgoing: outgoing, starred: true, edited: true))
            let bubble = cell.bubble.frame
            let footer = try part(MacFooterView.self, of: cell)
            XCTAssertTrue(bubble.insetBy(dx: MacTimelineMetrics.bubblePaddingH, dy: 0).contains(footer.frame), label(outgoing))
            XCTAssertGreaterThanOrEqual(footer.frame.minY, cell.textView.frame.maxY, "below the text: \(label(outgoing))")
            let placement = try footerPlacement(cell)
            let parts = [placement.star, placement.text, placement.glyph].compactMap { $0 }
            XCTAssertEqual(parts.count, outgoing ? 3 : 2, label(outgoing))
            for part in parts {
                XCTAssertGreaterThanOrEqual(part.minX, -0.5, "\(part) \(label(outgoing))")
                XCTAssertLessThanOrEqual(part.maxX, footer.bounds.width + 0.5, "\(part) \(label(outgoing))")
                XCTAssertEqual(part.midY, footer.bounds.midY, accuracy: 0.5, "one line: \(label(outgoing))")
            }
            XCTAssertEqual(try XCTUnwrap(parts.max { $0.maxX < $1.maxX }).maxX, footer.bounds.width, accuracy: 0.5, "trailing-aligned")
        }
    }

    // A peer may send a dozen distinct reactions to a short message: the ones that do not fit fold into one "+N" pill
    // that accounts for every reaction.
    func testManyReactionsStayOnScreenAndNeverWidenTheBubble() throws {
        let emoji = ["❤️", "👍", "😂", "😮", "😢", "🙏", "🎉", "🔥", "👀", "💯", "✨", "🤔"]
        let reactions = emoji.enumerated().map { TimelineReaction(emoji: $1, count: $0 < 3 ? 12 : 1, isSelected: false) }
        for width in [self.width, 360] {
            for outgoing in [true, false] {
                let name = "\(label(outgoing)) at \(width)"
                let bare = cell(message(outgoing: outgoing), width: width)
                let reacted = cell(message(outgoing: outgoing, reactions: reactions), width: width)
                XCTAssertEqual(reacted.bubble.frame, bare.bubble.frame, name)
                let layout = try XCTUnwrap(reacted.layoutRecord)
                let shown = layout.pills.filter { $0.emoji != nil }.count
                let folded = layout.pills.last.flatMap { $0.emoji == nil ? Int($0.count?.dropFirst() ?? "") : nil } ?? 0
                XCTAssertEqual(shown + folded, emoji.count, name)
                if width < self.width { XCTAssertGreaterThan(folded, 0, "a narrow window folds some: \(name)") }
                let pills = try part(MacReactionsView.self, of: reacted).frame
                XCTAssertGreaterThanOrEqual(pills.minX, side, name)
                XCTAssertLessThanOrEqual(pills.maxX, width - side, name)
            }
        }
    }

    // As in WhatsApp: off the bubble's outer bottom corner, over its bottom padding only, with room kept below.
    func testReactionPillsHangOffTheOuterBottomCornerBelowTheFooter() throws {
        for outgoing in [true, false] {
            let bare = cell(message(outgoing: outgoing))
            let reacted = cell(message(outgoing: outgoing, reactions: [TimelineReaction(emoji: "👍", count: 2, isSelected: false)]))
            let bubble = reacted.bubble.frame
            let pills = try part(MacReactionsView.self, of: reacted).frame
            let footer = try part(MacFooterView.self, of: reacted).frame
            XCTAssertTrue(try part(MacReactionsView.self, of: bare).isHidden)
            XCTAssertGreaterThanOrEqual(pills.minY, footer.maxY, "clear of the time, star and receipt: \(label(outgoing))")
            XCTAssertLessThan(pills.minY, bubble.maxY, "overlapping the bubble: \(label(outgoing))")
            XCTAssertGreaterThan(pills.maxY, bubble.maxY, "hanging below it: \(label(outgoing))")
            XCTAssertLessThanOrEqual(pills.maxY, reacted.bounds.height, "the row reserves the room: \(label(outgoing))")
            XCTAssertGreaterThan(reacted.bounds.height, bare.bounds.height, label(outgoing))
            if outgoing {
                XCTAssertEqual(pills.maxX, bubble.maxX - 10, accuracy: 0.5, "the trailing corner")
            } else {
                XCTAssertEqual(pills.minX, bubble.minX + 10, accuracy: 0.5, "the leading corner")
            }
            XCTAssertTrue(reacted.messageFrame.contains(pills), "VoiceOver's frame takes in the pills: \(label(outgoing))")
        }
    }

    func testTheOwnReactionGetsNoRingAndVoiceOverSaysItIsYours() throws {
        for outgoing in [true, false] {
            func reacted(_ yours: Bool, _ accent: AccentTheme) -> MacTimelineMessageCell {
                context.accent = accent
                return cell(message(outgoing: outgoing, reactions: [TimelineReaction(emoji: "👍", count: 2, isSelected: yours),
                                                                    TimelineReaction(emoji: "❤️", count: 1, isSelected: false)]))
            }
            let theirs = try png(try part(MacReactionsView.self, of: reacted(false, .indigo)))
            for accent in [AccentTheme.indigo, .crab] {
                let own = reacted(true, accent)
                XCTAssertEqual(try png(try part(MacReactionsView.self, of: own)), theirs, "drawn alike: \(label(outgoing)), \(accent)")
                let spoken = own.element.accessibilityLabel() ?? ""
                XCTAssertTrue(spoken.hasSuffix("2 thumbs up reactions, including you, 1 heart reaction"), spoken)
                let actions = own.accessibilityActions().map(\.name)
                XCTAssertTrue(actions.contains("Remove thumbs up reaction"), "\(actions)")
                XCTAssertTrue(actions.contains("Add heart reaction"), "\(actions)")
            }
            let drawn = try render(try part(MacReactionsView.self, of: reacted(false, .indigo)))
            let inked = (0..<drawn.pixelsWide).contains { x in (drawn.colorAt(x: x, y: drawn.pixelsHigh / 2)?.alphaComponent ?? 0) > 0 }
            XCTAssertTrue(inked, "the pills draw something")
        }
    }

    // Right-clicking the empty gutter beside a bubble opens nothing.
    func testTheContextMenuTargetsTheBubbleNotTheGutter() throws {
        for outgoing in [true, false] {
            let cell = cell(message(body: "See you at ten", outgoing: outgoing))
            let bubble = cell.bubble.frame
            XCTAssertEqual(outgoing ? bubble.maxX : bubble.minX, outgoing ? width - side : side, accuracy: 0.5, "\(label(outgoing)) side")
            let menu = try XCTUnwrap(cell.menu(at: NSPoint(x: bubble.midX, y: bubble.midY)), label(outgoing))
            XCTAssertTrue(menu.items.map(\.title).starts(with: ["React"]), "\(menu.items.map(\.title))")
            XCTAssertTrue(menu.items.contains { $0.title == "Reply" }, "\(menu.items.map(\.title))")
            let gutterX = outgoing ? bubble.minX - 20 : bubble.maxX + 20
            XCTAssertNil(cell.menu(at: NSPoint(x: gutterX, y: bubble.midY)), "the gutter: \(label(outgoing))")
            XCTAssertNil(cell.menu(at: NSPoint(x: outgoing ? side / 2 : width - side / 2, y: bubble.midY)), "the row's far edge: \(label(outgoing))")
        }
    }
}
