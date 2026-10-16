import AppKit
import SwiftUI

/// The bubble's text as a read-only `NSTextView`, so a right-click knows which link it landed on, Select Text can
/// select it all, and selection, links and the text's own menu behave as everywhere on the Mac. A right-click inside a
/// selection shows the system's text menu (Copy, Look Up, Services); anywhere else in the text the message's menu.
struct MacBubbleText: NSViewRepresentable {
    let text: NSAttributedString
    let linkColor: NSColor
    /// Bumped by Select Text: the text view takes focus and selects everything.
    let selectAllRequests: Int
    /// The message's menu for a right-click on `link`, nil away from a link.
    let menu: (URL?) -> NSMenu
    let openLink: (URL) -> Void

    final class Coordinator: NSObject, NSTextViewDelegate {
        var openLink: (URL) -> Void = { _ in }
        var selectAllRequests = 0

        func textView(_ textView: NSTextView, clickedOnLink link: Any, at charIndex: Int) -> Bool {
            guard let url = link as? URL ?? (link as? String).flatMap(URL.init(string:)) else { return false }
            openLink(url)
            return true
        }
    }

    func makeCoordinator() -> Coordinator { Coordinator() }

    func makeNSView(context: Context) -> BubbleTextView {
        let view = BubbleTextView.make()
        view.delegate = context.coordinator
        context.coordinator.selectAllRequests = selectAllRequests
        return view
    }

    func updateNSView(_ view: BubbleTextView, context: Context) {
        context.coordinator.openLink = openLink
        view.messageMenu = menu
        if view.textStorage?.isEqual(to: text) != true { view.textStorage?.setAttributedString(text) }
        view.linkTextAttributes = [.foregroundColor: linkColor, .underlineStyle: NSUnderlineStyle.single.rawValue, .cursor: NSCursor.pointingHand]
        if context.coordinator.selectAllRequests != selectAllRequests {
            context.coordinator.selectAllRequests = selectAllRequests
            view.window?.makeFirstResponder(view)
            view.selectAll(nil)
        }
    }

    func sizeThatFits(_ proposal: ProposedViewSize, nsView: BubbleTextView, context: Context) -> CGSize? {
        Self.measure(text, width: proposal.width)
    }

    /// The text's size laid out `width` wide, or on as few lines as its line breaks allow without one; laid out apart
    /// from the live view so measuring never disturbs what it shows.
    @MainActor static func measure(_ text: NSAttributedString, width: CGFloat?) -> CGSize {
        let available = width.map { $0.isFinite ? max(1, $0) : .greatestFiniteMagnitude } ?? .greatestFiniteMagnitude
        measuring.storage.setAttributedString(text)
        measuring.container.size = NSSize(width: available, height: .greatestFiniteMagnitude)
        measuring.layout.ensureLayout(for: measuring.container)
        let used = measuring.layout.usedRect(for: measuring.container)
        return CGSize(width: min(available, ceil(used.width)), height: ceil(used.height))
    }

    @MainActor private static let measuring = TextStack()

    /// TextKit 1 for both the live views and the measuring, so the two lay lines out alike.
    @MainActor final class TextStack {
        let storage = NSTextStorage()
        let layout = NSLayoutManager()
        let container = NSTextContainer()

        init() {
            container.lineFragmentPadding = 0
            layout.addTextContainer(container)
            storage.addLayoutManager(layout)
        }
    }
}

final class BubbleTextView: NSTextView {
    var messageMenu: ((URL?) -> NSMenu)?

    static func make() -> BubbleTextView {
        let stack = MacBubbleText.TextStack()
        stack.container.size = NSSize(width: CGFloat.greatestFiniteMagnitude, height: .greatestFiniteMagnitude)
        stack.container.widthTracksTextView = true
        let view = BubbleTextView(frame: .zero, textContainer: stack.container)
        // The view keeps its text system; the stack's owner goes when this returns.
        view.stack = stack
        view.isEditable = false
        view.isSelectable = true
        view.isRichText = true
        view.drawsBackground = false
        view.textContainerInset = .zero
        view.isVerticallyResizable = false
        view.isHorizontallyResizable = false
        view.isAutomaticLinkDetectionEnabled = false
        // The row speaks for the message as one element; the text would read it a second time.
        view.setAccessibilityElement(false)
        return view
    }

    private var stack: MacBubbleText.TextStack?

    override func menu(for event: NSEvent) -> NSMenu? {
        clickIsInSelection(event) ? super.menu(for: event) : messageMenu?(link(at: event))
    }

    /// The message's menu without first selecting the word under the pointer, as a text view would.
    override func rightMouseDown(with event: NSEvent) {
        guard !clickIsInSelection(event), let menu = messageMenu?(link(at: event)) else {
            super.rightMouseDown(with: event)
            return
        }
        NSMenu.popUpContextMenu(menu, with: event, for: self)
    }

    /// The character under the pointer, nil between lines or past a line's end.
    private func characterIndex(at event: NSEvent) -> Int? {
        guard let layoutManager, let textContainer else { return nil }
        let point = convert(event.locationInWindow, from: nil)
        let inContainer = NSPoint(x: point.x - textContainerOrigin.x, y: point.y - textContainerOrigin.y)
        let glyph = layoutManager.glyphIndex(for: inContainer, in: textContainer)
        guard glyph < layoutManager.numberOfGlyphs,
              layoutManager.boundingRect(forGlyphRange: NSRange(location: glyph, length: 1), in: textContainer).contains(inContainer) else { return nil }
        return layoutManager.characterIndexForGlyph(at: glyph)
    }

    private func link(at event: NSEvent) -> URL? {
        guard let index = characterIndex(at: event), let storage = textStorage, index < storage.length else { return nil }
        let value = storage.attribute(.link, at: index, effectiveRange: nil)
        return value as? URL ?? (value as? String).flatMap(URL.init(string:))
    }

    private func clickIsInSelection(_ event: NSEvent) -> Bool {
        guard let index = characterIndex(at: event) else { return false }
        return selectedRanges.contains { $0.rangeValue.length > 0 && NSLocationInRange(index, $0.rangeValue) }
    }
}
