import AppKit
import SwiftUI

// A read-only `NSTextView`, so a right-click knows which link it hit and selection, links and the text menu behave as
// everywhere on the Mac. A right-click inside a selection shows the text menu, elsewhere the message's menu.
final class BubbleTextView: NSTextView {
    var messageMenu: ((URL?) -> NSMenu)?
    var timelineKey: ((MacTimelineKey) -> Void)?
    var tookFocus: (() -> Void)?
    var plainClick: (() -> Void)?

    // A layer drawn whole is backed in full, so text taller than 4,000 pt in the narrowest bubble keeps AppKit's layer,
    // which backs only the part in sight.
    private var drawsWhole = false

    nonisolated static let narrowestText: CGFloat = 120 - 2 * 12

    // Only the bubble under the pointer registers cursor rects: every text in sight re-registering them on each
    // scrolled frame cost a window-server call per bubble.
    var showsCursor = false {
        didSet {
            guard showsCursor != oldValue else { return }
            window?.invalidateCursorRects(for: self)
        }
    }

    override func resetCursorRects() {
        if showsCursor { super.resetCursorRects() }
    }

    // A text view resized while it holds a caret or a selection scrolls its enclosing scroll view, which in a reused
    // cell moved the reader's rows.
    override func scrollToVisible(_ rect: NSRect) -> Bool { false }

    // TextKit 1 for both the live views and `MacRowMeasurer`, so the two lay lines out alike.
    final class TextStack {
        let storage = NSTextStorage()
        let layout = NSLayoutManager()
        let container = NSTextContainer()

        init() {
            container.lineFragmentPadding = 0
            layout.addTextContainer(container)
            storage.addLayoutManager(layout)
        }
    }

    static func make(_ text: NSAttributedString, drawsWhole: Bool) -> BubbleTextView {
        let stack = TextStack()
        stack.storage.setAttributedString(text)
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

    private var stack: TextStack?

    // AppKit's backing layer holds only the visible part and redisplays whenever the visible rect changes, which in a
    // scroll view is every scrolled frame. AppKit never marks a layer it did not make as needing display, so this one
    // redraws only on the view's own invalidations.
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

    override func setNeedsDisplay(_ rect: NSRect, avoidAdditionalLayout flag: Bool) {
        super.setNeedsDisplay(rect, avoidAdditionalLayout: flag)
        if drawsWhole { redisplayLayer() }
    }

    override var needsDisplay: Bool {
        get { super.needsDisplay }
        set {
            super.needsDisplay = newValue
            if drawsWhole, newValue { redisplayLayer() }
        }
    }

    // The text view marks itself many times while its text and attributes are set; the short text redraws whole, once.
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

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        if drawsWhole { redisplayLayer() }
    }

    private func matchWindowScale() {
        guard drawsWhole, let window, let layer, layer.contentsScale != window.backingScaleFactor else { return }
        layer.contentsScale = window.backingScaleFactor
        layer.setNeedsDisplay()
    }

    #if DEBUG
    var debugMessageID = ""
    var debugDraws = 0
    var debugDrawsWhole: Bool { drawsWhole }

    override func draw(_ dirtyRect: NSRect) {
        debugDraws += 1
        super.draw(dirtyRect)
    }

    // As AppKit does on a move to a screen of another scale: the layer takes the window's scale again and redraws.
    func debugRescale() {
        layer?.contentsScale = (window?.backingScaleFactor ?? 2) == 1 ? 2 : 1
        viewDidChangeBackingProperties()
    }
    #endif

    override func menu(for event: NSEvent) -> NSMenu? {
        clickIsInSelection(event) ? super.menu(for: event) : messageMenu?(link(at: event))
    }

    // The text view tracks the click until mouse-up, so only a click that selected nothing counts as plain.
    override func mouseDown(with event: NSEvent) {
        guard let plainClick, event.clickCount == 1, link(at: event) == nil, !clickIsInSelection(event) else {
            super.mouseDown(with: event)
            return
        }
        super.mouseDown(with: event)
        if selectedRange().length == 0 { plainClick() }
    }

    override var canBecomeKeyView: Bool { false }

    // A cell scrolled out with keyboard focus: focus stays with the timeline, not wherever AppKit would put it next.
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
        while let view = host, !(view is NSTableView) { host = view.superview }
        window.makeFirstResponder(host)
    }

    override func becomeFirstResponder() -> Bool {
        guard super.becomeFirstResponder() else { return false }
        tookFocus?()
        return true
    }

    // Up and Down without Shift (which extends the selection) move to the neighbouring message; the scrolling keys and
    // Esc act as in the timeline.
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

    // Skips the text view's selecting of the word under the pointer.
    override func rightMouseDown(with event: NSEvent) {
        guard !clickIsInSelection(event), let menu = messageMenu?(link(at: event)) else {
            super.rightMouseDown(with: event)
            return
        }
        NSMenu.popUpContextMenu(menu, with: event, for: self)
    }

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

#if DEBUG
// Bubble-text tour steps check that a text drawn whole redraws when what it shows changes. `text-layers` renders each
// such layer over purple, so a blank one shows.
@MainActor enum MacBubbleTextTour {
    static func step(_ name: String, _ argument: String, window: NSWindow?) {
        let texts = window?.contentView.map(visibleTexts) ?? []
        switch name {
        case "appearance":
            forThisRun(AppearanceView.modeKey) { AppearanceStore.shared.mode = AppearanceStore.modes.contains(argument) ? argument : "automatic" }
        case "accent":
            guard let accent = AccentTheme(rawValue: argument) else { return MacDebugHooks.log("tour accent: no accent \(argument)") }
            forThisRun(AccentTheme.storageKey) { AppearanceStore.shared.accent = accent }
        case "text-select":
            let parts = argument.split(separator: " ")
            guard parts.count == 3, let location = Int(parts[1]), let length = Int(parts[2]),
                  let text = texts.first(where: { $0.debugMessageID == parts[0] }), location >= 0, length >= 0,
                  location + length <= text.string.utf16.count else {
                return MacDebugHooks.log("tour text-select: no text in sight with that range for \(argument)")
            }
            text.setSelectedRange(NSRange(location: location, length: length))
            report([text], name: nil)
        case "text-rescale":
            let whole = texts.filter(\.debugDrawsWhole)
            whole.forEach { $0.debugRescale() }
            report(whole, name: nil)
        case "text-layers": report(texts, name: argument)
        default: break
        }
    }

    // The store saves each change in the app's preferences, which later runs of this build would start from.
    private static func forThisRun(_ key: String, _ change: () -> Void) {
        let stored = UserDefaults.standard.object(forKey: key)
        change()
        UserDefaults.standard.set(stored, forKey: key)
    }

    private static func visibleTexts(in view: NSView) -> [BubbleTextView] {
        if let text = view as? BubbleTextView { return text.isHiddenOrHasHiddenAncestor || text.visibleRect.isEmpty ? [] : [text] }
        return view.subviews.flatMap(visibleTexts)
    }

    private static func report(_ texts: [BubbleTextView], name: String?) {
        MacDebugHooks.log("text-layers \(name ?? "now"): \(texts.count) texts in sight")
        for text in texts {
            let scale = text.layer?.contentsScale ?? 0, windowScale = text.window?.backingScaleFactor ?? 0
            MacDebugHooks.log("text \(text.debugMessageID): \(text.debugDrawsWhole ? "whole" : "AppKit's layer") "
                + "\(text.layer.map { NSStringFromClass(type(of: $0)) } ?? "no layer") scale \(scale)/\(windowScale)\(scale == windowScale ? "" : " MISMATCH") "
                + "needs display \(text.layer?.needsDisplay() ?? false) drew \(text.debugDraws) selection \(text.selectedRange())")
            text.debugDraws = 0
            guard let name, text.debugDrawsWhole, let layer = text.layer, let png = render(layer),
                  let directory = MacDebugHooks.value(after: "-haus-capture-frames") ?? MacDebugHooks.value(after: "-haus-capture") else { continue }
            MacDebugHooks.emit(png, directory: directory, file: "\(name)-\(text.debugMessageID).png")
        }
    }

    private static func render(_ layer: CALayer) -> Data? {
        let scale = layer.contentsScale
        let width = Int(ceil(layer.bounds.width * scale)), height = Int(ceil(layer.bounds.height * scale))
        guard width > 0, height > 0, let context = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
                                                            space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return nil }
        context.setFillColor(NSColor.systemPurple.cgColor)
        context.fill(CGRect(x: 0, y: 0, width: width, height: height))
        // The view draws flipped; the image reads top down.
        context.translateBy(x: 0, y: CGFloat(height))
        context.scaleBy(x: scale, y: -scale)
        layer.render(in: context)
        return context.makeImage().flatMap { NSBitmapImageRep(cgImage: $0).representation(using: .png, properties: [:]) }
    }
}
#endif
