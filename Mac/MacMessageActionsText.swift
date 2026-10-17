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
        #if DEBUG
        let perfStart = MacPerfProbe.clock()
        defer { MacPerfProbe.add("text.make", since: perfStart) }
        #endif
        let view = BubbleTextView.make(drawsWhole: BubbleTextView.drawsWhole(text))
        view.delegate = context.coordinator
        context.coordinator.selectAllRequests = selectAllRequests
        return view
    }

    func updateNSView(_ view: BubbleTextView, context: Context) {
        #if DEBUG
        let perfStart = MacPerfProbe.clock()
        defer { MacPerfProbe.add("text.update", since: perfStart) }
        #endif
        context.coordinator.openLink = openLink
        view.messageMenu = menu
        let row = context.environment.timelineRow
        view.timelineKey = row.timeline.map { timeline in { [weak timeline, id = row.id] key in timeline?.bubbleTextKey(key, in: id) } }
        view.tookFocus = row.timeline.map { timeline in { [weak timeline, id = row.id] in timeline?.bubbleTextFocused(id) } }
        let resultClick = context.environment.findResultClick
        view.plainClick = resultClick.isActive ? { resultClick() } : nil
        if view.textStorage?.isEqual(to: text) != true { view.textStorage?.setAttributedString(text) }
        view.linkTextAttributes = [.foregroundColor: linkColor, .underlineStyle: NSUnderlineStyle.single.rawValue, .cursor: NSCursor.pointingHand]
        if context.coordinator.selectAllRequests != selectAllRequests {
            context.coordinator.selectAllRequests = selectAllRequests
            view.window?.makeFirstResponder(view)
            view.selectAll(nil)
        }
    }

    func sizeThatFits(_ proposal: ProposedViewSize, nsView: BubbleTextView, context: Context) -> CGSize? {
        #if DEBUG
        let perfStart = MacPerfProbe.clock()
        defer { MacPerfProbe.add("text.size", since: perfStart) }
        #endif
        return Self.measure(text, width: proposal.width)
    }

    /// The text's size laid out `width` wide, or on as few lines as its line breaks allow without one; laid out apart
    /// from the live view so measuring never disturbs what it shows.
    @MainActor static func measure(_ text: NSAttributedString, width: CGFloat?) -> CGSize {
        let available = width.map { $0.isFinite ? max(1, $0) : .greatestFiniteMagnitude } ?? .greatestFiniteMagnitude
        let key = Measured(text: text, width: available)
        if let size = measured[key] { return size }
        #if DEBUG
        MacPerfProbe.count("text.miss")
        #endif
        measuring.storage.setAttributedString(text)
        measuring.container.size = NSSize(width: available, height: .greatestFiniteMagnitude)
        measuring.layout.ensureLayout(for: measuring.container)
        let used = measuring.layout.usedRect(for: measuring.container)
        let size = CGSize(width: min(available, ceil(used.width)), height: ceil(used.height))
        // Layout asks each bubble several times (its natural width, then the capped one), and again whenever a row
        // scrolls back in; a bounded cache answers those without laying the text out again.
        if measured.count >= 2_000 { measured.removeAll(keepingCapacity: true) }
        // A copy as the key: the caller's string may be mutable.
        measured[Measured(text: NSAttributedString(attributedString: text), width: available)] = size
        return size
    }

    private struct Measured: Hashable {
        let text: NSAttributedString
        let width: CGFloat
    }

    @MainActor private static var measured: [Measured: CGSize] = [:]
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
    /// Takes the keys that belong to the timeline once this text has keyboard focus (`timelineKeys`).
    var timelineKey: ((MacTimelineKey) -> Void)?
    /// The text took keyboard focus: its message becomes the timeline's focused one.
    var tookFocus: (() -> Void)?
    /// What a single click that lands on no link and leaves nothing selected does besides placing the caret: a search
    /// result's jump.
    var plainClick: (() -> Void)?

    /// Whether the text draws all of itself into a plain layer (`makeBackingLayer`); fixed when the view is made.
    private var drawsWhole = false

    /// Whether `text` is short enough to draw whole: laid out in the narrowest bubble, no taller than a few screens, so
    /// its layer stays well inside the largest one Core Animation shows, even at twice the limit after an edit.
    @MainActor static func drawsWhole(_ text: NSAttributedString) -> Bool {
        // A short message passes without being laid out again at a width it is never shown at: 1,000 characters and
        // 40 line breaks come to about 125 lines in the narrowest bubble, some 2,100 pt.
        if text.length <= 1_000, text.string.utf16.lazy.filter({ $0 == 10 }).count <= 40 { return true }
        return MacBubbleText.measure(text, width: narrowestText).height <= 4_000
    }

    /// The narrowest a bubble's text is laid out: the narrowest bubble (`BubbleWidth`) less its padding.
    private static let narrowestText: CGFloat = 120 - 2 * 12

    static func make(drawsWhole: Bool) -> BubbleTextView {
        let stack = MacBubbleText.TextStack()
        stack.container.size = NSSize(width: CGFloat.greatestFiniteMagnitude, height: .greatestFiniteMagnitude)
        stack.container.widthTracksTextView = true
        let view = BubbleTextView(frame: .zero, textContainer: stack.container)
        // The view keeps its text system; the stack's owner goes when this returns.
        view.stack = stack
        view.drawsWhole = drawsWhole
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

    /// A plain layer that the text draws all of itself into, again only when the text view marks itself as needing
    /// display. AppKit's own backing layer holds only the part of a view in sight and redisplays whenever the view's
    /// visible rect changes, which for a view in a scroll view is every scrolled frame: every bubble's text would display
    /// again on each frame of a scroll. AppKit leaves a layer it did not make to its view (it never marks it as needing
    /// display), so the view keeps its scale and passes its own invalidations on.
    override func makeBackingLayer() -> CALayer {
        guard drawsWhole else { return super.makeBackingLayer() }
        let layer = CALayer()
        layer.needsDisplayOnBoundsChange = true
        layer.contentsScale = window?.backingScaleFactor ?? NSScreen.main?.backingScaleFactor ?? 1
        layer.setNeedsDisplay()
        return layer
    }

    override func setNeedsDisplay(_ invalidRect: NSRect) {
        super.setNeedsDisplay(invalidRect)
        if drawsWhole { redisplayLayer() }
    }

    override var needsDisplay: Bool {
        get { super.needsDisplay }
        set {
            super.needsDisplay = newValue
            if drawsWhole, newValue { redisplayLayer() }
        }
    }

    /// All of it, once per display: the bubble's text is short, and the layer's coordinates need not be the view's
    /// flipped ones. The text view marks itself many times over while its text and attributes are set.
    private func redisplayLayer() {
        guard let layer, !layer.needsDisplay() else { return }
        layer.setNeedsDisplay()
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        matchWindowScale()
    }

    override func viewDidChangeBackingProperties() {
        super.viewDidChangeBackingProperties()
        matchWindowScale()
    }

    /// The colours are the appearance's: dark text in Light, light in Dark.
    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        if drawsWhole { redisplayLayer() }
    }

    private func matchWindowScale() {
        guard drawsWhole, let window, let layer, layer.contentsScale != window.backingScaleFactor else { return }
        layer.contentsScale = window.backingScaleFactor
        layer.setNeedsDisplay()
    }

    override func menu(for event: NSEvent) -> NSMenu? {
        clickIsInSelection(event) ? super.menu(for: event) : messageMenu?(link(at: event))
    }

    /// The text view tracks the click until the button comes up, selecting as the pointer drags; only a click that
    /// selected nothing counts as a plain click. One inside a selection stays the selection's.
    override func mouseDown(with event: NSEvent) {
        guard let plainClick, event.clickCount == 1, link(at: event) == nil, !clickIsInSelection(event) else {
            super.mouseDown(with: event)
            return
        }
        super.mouseDown(with: event)
        if selectedRange().length == 0 { plainClick() }
    }

    /// A click or Select Text gives the text keyboard focus; Tab never stops here, the timeline around it is the stop.
    override var canBecomeKeyView: Bool { false }

    /// Scrolled out of the lazy stack with keyboard focus (which hides the view, or takes it out of the window): the
    /// focus stays with the timeline around the text, which SwiftUI hosts, rather than going wherever AppKit and
    /// SwiftUI would put it next (the sidebar).
    override func viewDidHide() {
        keepFocusInTimeline()
        super.viewDidHide()
    }

    override func viewWillMove(toWindow newWindow: NSWindow?) {
        if newWindow == nil { keepFocusInTimeline() }
        super.viewWillMove(toWindow: newWindow)
    }

    private func keepFocusInTimeline() {
        guard let window, window.firstResponder === self else { return }
        var host = superview
        while let view = host, !NSStringFromClass(type(of: view)).contains("NSHostingView") { host = view.superview }
        window.makeFirstResponder(host)
        // SwiftUI's focus goes to the timeline too, after this change: without it SwiftUI moves to its first stop.
        if let timelineKey { DispatchQueue.main.async { timelineKey(.refocus) } }
    }

    override func becomeFirstResponder() -> Bool {
        guard super.becomeFirstResponder() else { return false }
        tookFocus?()
        return true
    }

    /// A click into the text gives it keyboard focus, for selecting with the keys; the timeline's keys still work here:
    /// the scrolling keys scroll it, Up and Down (without Shift, which extends the selection) move on to the message
    /// before or after this one, and Esc goes to the composer. SwiftUI usually takes them first, as the timeline around
    /// the text has focus too; these are for when it does not.
    override func doCommand(by selector: Selector) {
        guard let timelineKey, let key = Self.timelineKeys[selector] else { return super.doCommand(by: selector) }
        timelineKey(key)
    }

    private static let timelineKeys: [Selector: MacTimelineKey] = [
        #selector(scrollPageUp(_:)): .scroll(.pageUp), #selector(pageUp(_:)): .scroll(.pageUp),
        #selector(scrollPageDown(_:)): .scroll(.pageDown), #selector(pageDown(_:)): .scroll(.pageDown),
        #selector(scrollToBeginningOfDocument(_:)): .scroll(.top), #selector(moveToBeginningOfDocument(_:)): .scroll(.top),
        #selector(scrollToEndOfDocument(_:)): .scroll(.bottom), #selector(moveToEndOfDocument(_:)): .scroll(.bottom),
        #selector(moveUp(_:)): .focus(forward: false), #selector(moveDown(_:)): .focus(forward: true),
        #selector(cancelOperation(_:)): .escape,
    ]

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
