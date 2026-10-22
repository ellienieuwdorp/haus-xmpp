import AppKit
import SwiftUI

// The timeline table's reused cells, laid out by hand from each row's cached record (`MacRowLayout`): no Auto Layout,
// and nothing is asked for its size. Each part is a small layer-backed view that redraws only when told to
// (`.onSetNeedsDisplay`), so scrolling moves layers and draws nothing; the bubble is a plain layer with continuous
// 16 pt corners and no mask. The quote, file and preview card, the hover toolbar and the typing and loading rows are
// SwiftUI in a hosting view each cell keeps and gives a new root on reuse.

/// What every cell acts through: the conversation's handlers and the timeline's state, shared by all cells of a table.
@MainActor final class MacTimelineCellContext {
    var accent: AccentTheme = .current
    var isFiltered = false
    /// The contact's name in a direct chat, which VoiceOver reads as the sender of what they sent.
    var contactName: String?
    var handlers = MacMessageHandlers(perform: { _, _, _ in }, react: { _, _ in })
    var openAttachment: (TimelineMessage) -> Void = { _ in }
    var openLink: (URL) -> Void = { _ in }
    var openQuote: (String) -> Void = { _ in }
    /// A key a bubble's text passed on, and the message it is in.
    var textKey: (MacTimelineKey, String) -> Void = { _, _ in }
    /// A bubble's text took keyboard focus.
    var textFocused: (String) -> Void = { _ in }
    /// A search or starred result was clicked: the whole timeline at that message.
    var showResult: (String) -> Void = { _ in }
    /// VoiceOver's Show Menu on a message.
    var openMenu: (String) -> Void = { _ in }
}

/// A row view that draws nothing: no selection, no background, no backing store.
final class MacTimelineRowView: NSTableRowView {
    static let identifier = NSUserInterfaceItemIdentifier("timeline.row")

    override var wantsUpdateLayer: Bool { true }
    override func updateLayer() {}
    override func drawBackground(in dirtyRect: NSRect) {}
    override func drawSelection(in dirtyRect: NSRect) {}
    override var isOpaque: Bool { false }
}

/// The bubble's fill: a layer's background colour and corner radius, and the keyboard focus ring around it.
final class MacBubbleView: NSView {
    var isOutgoing = false { didSet { if isOutgoing != oldValue { needsDisplay = true } } }
    var accent: AccentTheme = .indigo { didSet { if accent != oldValue { needsDisplay = true } } }
    var showsFocusRing = false {
        didSet {
            guard showsFocusRing != oldValue else { return }
            ring.isHidden = !showsFocusRing
            needsDisplay = true
        }
    }
    private let ring = CALayer()

    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
        layerContentsRedrawPolicy = .onSetNeedsDisplay
        ring.isHidden = true
        ring.borderWidth = 3
        ring.cornerRadius = MacTimelineMetrics.cornerRadius + 3
        ring.cornerCurve = .continuous
        layer?.addSublayer(ring)
    }

    required init?(coder: NSCoder) { fatalError("not used") }

    override var wantsUpdateLayer: Bool { true }
    override var isFlipped: Bool { true }

    override func updateLayer() {
        guard let layer else { return }
        layer.cornerRadius = MacTimelineMetrics.cornerRadius
        layer.cornerCurve = .continuous
        layer.masksToBounds = false
        effectiveAppearance.performAsCurrentDrawingAppearance {
            layer.backgroundColor = (isOutgoing ? accent.bubble : NSColor.tertiarySystemFill).cgColor
            ring.borderColor = NSColor.keyboardFocusIndicatorColor.cgColor
        }
    }

    override func layout() {
        super.layout()
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        ring.frame = bounds.insetBy(dx: -3, dy: -3)
        CATransaction.commit()
    }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        needsDisplay = true
    }

    override func hitTest(_ point: NSPoint) -> NSView? { nil }
}

/// A view that draws itself, once per `needsDisplay`.
class MacTimelineDrawnView: NSView {
    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
        layerContentsRedrawPolicy = .onSetNeedsDisplay
    }

    required init?(coder: NSCoder) { fatalError("not used") }

    override var isFlipped: Bool { true }
    override var isOpaque: Bool { false }
    override func hitTest(_ point: NSPoint) -> NSView? { nil }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        needsDisplay = true
    }
}

/// The day header: caption semibold in a quaternary capsule.
final class MacDayHeaderView: MacTimelineDrawnView {
    var text = "" { didSet { if text != oldValue { needsDisplay = true } } }

    override func draw(_ dirtyRect: NSRect) {
        NSColor.quaternaryLabelColor.setFill()
        NSBezierPath(roundedRect: bounds, xRadius: bounds.height / 2, yRadius: bounds.height / 2).fill()
        let attributes: [NSAttributedString.Key: Any] = [.font: MacTimelineMetrics.shared.captionSemibold, .foregroundColor: NSColor.secondaryLabelColor]
        (text as NSString).draw(at: NSPoint(x: 10, y: 4), withAttributes: attributes)
    }
}

/// A group member's name above their run, in their colour.
final class MacAuthorView: MacTimelineDrawnView {
    var text = "" { didSet { if text != oldValue { needsDisplay = true } } }
    var color: NSColor = .labelColor { didSet { if color != oldValue { needsDisplay = true } } }

    override func draw(_ dirtyRect: NSRect) {
        let style = NSMutableParagraphStyle()
        style.lineBreakMode = .byTruncatingTail
        (text as NSString).draw(in: bounds, withAttributes: [.font: MacTimelineMetrics.shared.captionSemibold, .foregroundColor: color, .paragraphStyle: style])
    }
}

/// The footer, right-aligned and quiet: the star (its slot is always there, so starring never moves anything), the time
/// and the status mark.
final class MacFooterView: MacTimelineDrawnView {
    struct Content: Equatable {
        var isOutgoing = false
        var accent: AccentTheme = .indigo
        var isStarred = false
        var text: String?
        var glyph: MessageStatusGlyph?
    }

    var content = Content() { didSet { if content != oldValue { needsDisplay = true } } }

    override func draw(_ dirtyRect: NSRect) {
        let metrics = MacTimelineMetrics.shared
        let color = content.isOutgoing ? content.accent.bubbleText.withAlphaComponent(0.75) : .secondaryLabelColor
        let slot = MacTimelineMetrics.statusSlot
        var x = bounds.width
        if let glyph = content.glyph {
            x -= slot.width
            let width = MessageStatusArt.designWidth(glyph)
            let rect = NSRect(x: x + slot.width - width, y: (bounds.height - slot.height) / 2, width: width, height: slot.height)
            Self.drawTinted(MessageStatusArt.image(glyph, scale: 1), in: rect, color: color)
            x -= 4
        }
        if let text = content.text {
            let attributes: [NSAttributedString.Key: Any] = [.font: metrics.caption2, .foregroundColor: color]
            let width = ceil((text as NSString).size(withAttributes: attributes).width)
            x -= width
            (text as NSString).draw(at: NSPoint(x: x, y: (bounds.height - metrics.caption2Line) / 2), withAttributes: attributes)
            x -= 4
        }
        if content.isStarred {
            x -= metrics.starSize.width
            let rect = NSRect(x: x, y: (bounds.height - metrics.starSize.height) / 2, width: metrics.starSize.width, height: metrics.starSize.height)
            Self.drawTinted(metrics.star, in: rect, color: color)
        }
    }

    /// A template image in `color`, drawn into the current flipped context.
    static func drawTinted(_ image: NSImage, in rect: NSRect, color: NSColor) {
        guard let context = NSGraphicsContext.current?.cgContext,
              let cgImage = image.cgImage(forProposedRect: nil, context: NSGraphicsContext.current, hints: nil) else { return }
        context.saveGState()
        context.translateBy(x: rect.minX, y: rect.maxY)
        context.scaleBy(x: 1, y: -1)
        let local = CGRect(origin: .zero, size: rect.size)
        context.clip(to: local, mask: cgImage)
        context.setFillColor(color.cgColor)
        context.fill(local)
        context.restoreGState()
    }
}

/// The reaction pills, hung off the bubble's outer bottom corner. Where the user can react, a click on a pill adds that
/// emoji as theirs, or takes theirs back; the pills' tooltips say which, on the row under the pointer only (a tooltip
/// is a tracking rect, which costs every scrolled frame as a cursor rect does).
final class MacReactionsView: MacTimelineDrawnView {
    var pills: [MacReactionPill] = [] { didSet { if pills != oldValue { needsDisplay = true; updateToolTips() } } }
    var reactions: [TimelineReaction] = [] { didSet { if reactions != oldValue { updateToolTips() } } }
    var showsToolTips = false { didSet { if showsToolTips != oldValue { updateToolTips() } } }
    /// Nil where the message takes no reactions: the pills only show.
    var react: ((String) -> Void)?

    override func hitTest(_ point: NSPoint) -> NSView? {
        react == nil ? nil : super.hitTest(point)
    }

    private func pillRects() -> [(pill: MacReactionPill, rect: NSRect)] {
        var x: CGFloat = 0
        return pills.map { pill in
            defer { x += pill.width + 4 }
            return (pill, NSRect(x: x, y: 0, width: pill.width, height: bounds.height))
        }
    }

    override func mouseDown(with event: NSEvent) {
        let point = convert(event.locationInWindow, from: nil)
        guard let hit = pillRects().first(where: { $0.rect.contains(point) }), let emoji = hit.pill.emoji else { return }
        react?(emoji)
    }

    private func updateToolTips() {
        removeAllToolTips()
        guard showsToolTips else { return }
        for (pill, rect) in pillRects() {
            guard let emoji = pill.emoji else { continue }
            let selected = reactions.first { $0.emoji == emoji }?.isSelected ?? false
            addToolTip(rect, owner: MessageActionMenu.reactionTitle(emoji, selected: selected) as NSString, userData: nil)
        }
    }

    override func draw(_ dirtyRect: NSRect) {
        let metrics = MacTimelineMetrics.shared
        let height = bounds.height
        for (pill, rect) in pillRects() {
            let path = NSBezierPath(roundedRect: rect.insetBy(dx: 0.25, dy: 0.25), xRadius: height / 2, yRadius: height / 2)
            NSColor.textBackgroundColor.setFill()
            path.fill()
            NSColor.secondaryLabelColor.withAlphaComponent(0.3).setStroke()
            path.lineWidth = 0.5
            path.stroke()
            var x = rect.minX + 6
            if let emoji = pill.emoji {
                (emoji as NSString).draw(at: NSPoint(x: x, y: 2), withAttributes: [.font: metrics.caption])
                x += ceil((emoji as NSString).size(withAttributes: [.font: metrics.caption]).width) + 2
            }
            if let count = pill.count {
                let attributes: [NSAttributedString.Key: Any] = [.font: metrics.caption2Semibold, .foregroundColor: NSColor.secondaryLabelColor]
                (count as NSString).draw(at: NSPoint(x: x, y: 2 + (metrics.captionLine - metrics.caption2Line) / 2), withAttributes: attributes)
            }
        }
    }
}

/// The tint behind a row: a search or starred result under the pointer, or a message just scrolled to.
final class MacRowTintView: NSView {
    enum Tint: Equatable { case none, hover, highlight }

    var tint = Tint.none {
        didSet {
            guard tint != oldValue else { return }
            if tint == .none, oldValue == .highlight {
                NSAnimationContext.runAnimationGroup { context in
                    context.duration = NSWorkspace.shared.accessibilityDisplayShouldReduceMotion ? 0 : 0.6
                    animator().alphaValue = 0
                }
            } else {
                alphaValue = tint == .none ? 0 : 1
            }
            needsDisplay = true
        }
    }
    var accent: AccentTheme = .indigo { didSet { if accent != oldValue { needsDisplay = true } } }

    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
        layerContentsRedrawPolicy = .onSetNeedsDisplay
        alphaValue = 0
    }

    required init?(coder: NSCoder) { fatalError("not used") }

    override var wantsUpdateLayer: Bool { true }
    override func hitTest(_ point: NSPoint) -> NSView? { nil }

    override func updateLayer() {
        guard let layer else { return }
        layer.cornerRadius = 10
        layer.cornerCurve = .continuous
        effectiveAppearance.performAsCurrentDrawingAppearance {
            switch tint {
            case .hover: layer.backgroundColor = NSColor.quaternaryLabelColor.withAlphaComponent(0.6 * NSColor.quaternaryLabelColor.alphaComponent).cgColor
            case .highlight, .none: layer.backgroundColor = accent.tint.withAlphaComponent(0.15).cgColor
            }
        }
    }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        needsDisplay = true
    }
}

/// One message row: its parts placed at the record's frames, mirrored for a sent message.
final class MacTimelineMessageCell: NSView, NSTextViewDelegate {
    static let identifier = NSUserInterfaceItemIdentifier("timeline.message")
    static let longIdentifier = NSUserInterfaceItemIdentifier("timeline.message.long")

    unowned let context: MacTimelineCellContext
    private let tint = MacRowTintView()
    private let header = MacDayHeaderView()
    private let author = MacAuthorView()
    let bubble = MacBubbleView()
    let textView: BubbleTextView
    private let footer = MacFooterView()
    private let reactions = MacReactionsView()
    private var extras: NSHostingView<MacBubbleExtras>?
    private var toolbar: NSHostingView<MacMessageToolbar<MacMessageMenuContent>>?
    private(set) var layoutRecord: MacRowLayout?
    private(set) var message: TimelineMessage?
    private var linkColor: NSColor?
    private var emojiPopover: NSPopover?
    let element = MacTimelineMessageElement()
    private let headerElement = MacTimelineHeaderElement()

    var hovering = false { didSet { if hovering != oldValue { hoverChanged() } } }
    var highlighted = false { didSet { if highlighted != oldValue { updateTint() } } }
    var showsFocusRing: Bool {
        get { bubble.showsFocusRing }
        set { bubble.showsFocusRing = newValue }
    }

    init(drawsWhole: Bool, context: MacTimelineCellContext) {
        self.context = context
        textView = BubbleTextView.make(NSAttributedString(), drawsWhole: drawsWhole)
        super.init(frame: .zero)
        identifier = drawsWhole ? Self.identifier : Self.longIdentifier
        wantsLayer = true
        layerContentsRedrawPolicy = .never
        textView.layerContentsRedrawPolicy = .onSetNeedsDisplay
        textView.delegate = self
        for view in [tint, header, author, bubble, textView, footer, reactions] as [NSView] {
            view.autoresizingMask = []
            addSubview(view)
        }
        element.cell = self
        headerElement.cell = self
    }

    required init?(coder: NSCoder) { fatalError("not used") }

    override var isFlipped: Bool { true }
    override var wantsUpdateLayer: Bool { true }
    override func updateLayer() {}

    // MARK: Content

    /// Sets the parts' content from `layout`; the text view is given new text only when the row's content changed.
    func configure(_ layout: MacRowLayout, message: TimelineMessage) {
        let input = layout.input
        let sameContent = layoutRecord.map { $0.key.id == input.id && $0.key.revision == input.revision } ?? false
        if layoutRecord?.key.id != input.id {
            closePopover()
            hovering = false
        }
        layoutRecord = layout
        self.message = message
        let accent = context.accent

        header.isHidden = layout.header == nil
        header.text = input.header ?? ""
        author.isHidden = layout.authorFrame == nil
        if layout.authorFrame != nil {
            author.text = input.author ?? ""
            author.color = message.author.map(AvatarPalette.color(for:)) ?? .labelColor
        }
        bubble.isOutgoing = input.isOutgoing
        bubble.accent = accent
        tint.accent = accent
        let linkColor = input.isOutgoing ? accent.bubbleText : accent.tint
        if self.linkColor != linkColor {
            self.linkColor = linkColor
            textView.linkTextAttributes = [.foregroundColor: linkColor, .underlineStyle: NSUnderlineStyle.single.rawValue, .cursor: NSCursor.pointingHand]
        }
        textView.isHidden = layout.textFrame == nil
        if !sameContent || textView.textStorage?.length != input.text.length {
            textView.textStorage?.setAttributedString(input.text)
        }
        let id = input.id
        textView.messageMenu = { [weak self] link in self?.textMenu(link) ?? NSMenu() }
        textView.timelineKey = { [context] key in context.textKey(key, id) }
        textView.tookFocus = { [context] in context.textFocused(id) }
        textView.plainClick = context.isFiltered ? { [context] in context.showResult(id) } : nil
        #if DEBUG
        textView.debugMessageID = id
        #endif
        footer.content = .init(isOutgoing: input.isOutgoing, accent: accent, isStarred: message.isStarred, text: input.footer, glyph: message.statusGlyph)
        reactions.isHidden = layout.reactionsFrame == nil
        reactions.pills = layout.pills
        reactions.reactions = message.reactions
        reactions.react = message.canReact ? { [weak self] emoji in self?.react(emoji) } : nil
        configureExtras(layout, message: message)
        if toolbar != nil { toolbar?.rootView = toolbarView(message) }
        updateToolTip()
        updateTint()
        updateAccessibility(layout, message: message)
        needsLayout = true
    }

    private func configureExtras(_ layout: MacRowLayout, message: TimelineMessage) {
        guard let frame = layout.extrasFrame else {
            extras?.isHidden = true
            return
        }
        let root = MacBubbleExtras(content: MacBubbleExtrasContent(
            message: message, accent: context.accent,
            openAttachment: { [context] in context.openAttachment(message) },
            openQuote: { [context] reference in context.openQuote(reference) },
            menu: { [weak self] link in self?.menuContent(link) ?? MacMessageMenuContent(menu: MacMessageMenu(message: message, link: link), perform: { _, _ in }, react: { _ in }, moreReactions: {}) }),
            contentWidth: layout.key.contentWidth, openLink: { [context] in context.openLink($0) })
        if let extras {
            extras.rootView = root
            extras.isHidden = false
        } else {
            let host = NSHostingView(rootView: root)
            host.sizingOptions = []
            host.autoresizingMask = []
            // Under the text, so the text's selection and links keep their clicks.
            addSubview(host, positioned: .below, relativeTo: textView)
            extras = host
        }
        _ = frame
    }

    // MARK: Layout

    /// Mirrors a leading-side frame to the trailing side for a sent message.
    private func place(_ rect: CGRect) -> CGRect {
        guard layoutRecord?.input.isOutgoing == true else { return rect }
        return CGRect(x: bounds.width - rect.maxX, y: rect.minY, width: rect.width, height: rect.height)
    }

    var bubbleFrame: CGRect { layoutRecord.map { place($0.bubbleFrame) } ?? .zero }

    override func layout() {
        super.layout()
        guard let layout = layoutRecord else { return }
        if let header = layout.header {
            self.header.frame = CGRect(x: floor((bounds.width - header.width) / 2), y: header.y, width: header.width, height: header.height)
        }
        if let frame = layout.authorFrame { author.frame = frame }
        let bubbleFrame = place(layout.bubbleFrame)
        bubble.frame = bubbleFrame
        if let frame = layout.textFrame {
            let placed = place(frame)
            if textView.frame != placed { textView.frame = placed }
        }
        footer.frame = place(layout.footerFrame)
        if let frame = layout.reactionsFrame { reactions.frame = place(frame) }
        if let frame = layout.extrasFrame, let extras { extras.frame = place(frame) }
        tint.frame = CGRect(x: MacTimelineMetrics.sidePadding - 8, y: 0, width: bounds.width - 2 * (MacTimelineMetrics.sidePadding - 8), height: bounds.height)
        placeToolbar()
    }

    // MARK: Hover toolbar

    /// Built the first time the pointer is over this row: a glass capsule and a menu on every row would cost layout
    /// in every step of a resize.
    private func hoverChanged() {
        textView.showsCursor = hovering
        reactions.showsToolTips = hovering
        updateToolTip()
        updateTint()
        if hovering, toolbar == nil, let message { buildToolbar(message) }
        updateToolbarVisibility()
    }

    private var toolbarShown: Bool {
        #if DEBUG
        let forced = message.map { MacDebugHooks.tour.hoveredMessage == $0.id } ?? false
        #else
        let forced = false
        #endif
        return hovering || emojiPopover != nil || forced
    }

    func updateToolbarVisibility() {
        let shown = toolbarShown
        if shown, toolbar == nil, let message { buildToolbar(message) }
        guard let toolbar else { return }
        let alpha: CGFloat = shown ? 1 : 0
        guard toolbar.alphaValue != alpha || toolbar.isHidden == shown else { return }
        toolbar.isHidden = false
        NSAnimationContext.runAnimationGroup { context in
            context.duration = NSWorkspace.shared.accessibilityDisplayShouldReduceMotion ? 0 : 0.12
            toolbar.animator().alphaValue = alpha
        }
    }

    private func buildToolbar(_ message: TimelineMessage) {
        let host = NSHostingView(rootView: toolbarView(message))
        // Its own size, read once it is built (`placeToolbar`); nothing lays it out but this cell.
        host.sizingOptions = [.intrinsicContentSize]
        host.translatesAutoresizingMaskIntoConstraints = true
        host.autoresizingMask = []
        host.alphaValue = 0
        addSubview(host)
        toolbar = host
        needsLayout = true
    }

    private func toolbarView(_ message: TimelineMessage) -> MacMessageToolbar<MacMessageMenuContent> {
        let replies = MessageActionMenu.items(for: message).contains { $0.kind == .reply }
        return MacMessageToolbar(message: message, react: { [weak self] in self?.pickEmoji() },
                                 reply: replies ? { [weak self] in self?.perform(.reply, link: nil) } : nil) { [weak self] in
            self?.menuContent(nil) ?? MacMessageMenuContent(menu: MacMessageMenu(message: message), perform: { _, _ in }, react: { _ in }, moreReactions: {})
        }
    }

    /// Beside the bubble in the gutter, on its outer side, centred on it; where the gutter is too narrow, over the
    /// bubble's top outer corner instead, so it never runs past the window's edge.
    private func placeToolbar() {
        guard let toolbar, let layout = layoutRecord else { return }
        let size = toolbar.intrinsicContentSize
        let bubble = place(layout.bubbleFrame)
        let outgoing = layout.input.isOutgoing
        let room = outgoing ? bubble.minX : bounds.width - bubble.maxX
        let origin: CGPoint
        if room >= MacMessageToolbarSize.maximumWidth + 6 + 4 {
            origin = CGPoint(x: outgoing ? bubble.minX - 6 - size.width : bubble.maxX + 6, y: bubble.midY - size.height / 2)
        } else {
            origin = CGPoint(x: outgoing ? bubble.minX + 6 : bubble.maxX - 6 - size.width, y: bubble.minY - size.height / 2)
        }
        toolbar.frame = CGRect(origin: CGPoint(x: round(origin.x), y: round(origin.y)), size: size)
    }

    // MARK: Actions

    private func menuContent(_ link: URL?) -> MacMessageMenuContent? {
        guard let message else { return nil }
        return MacMessageMenuContent(menu: MacMessageMenu(message: message, link: link), perform: { [weak self] kind, link in self?.perform(kind, link: link) },
                                     react: { [weak self] in self?.react($0) }, moreReactions: { [weak self] in self?.pickEmoji() })
    }

    /// The message's menu, with the link's items when it was opened on one.
    func textMenu(_ link: URL?) -> NSMenu {
        guard let message else { return NSMenu() }
        return MacMessageNSMenu.make(MacMessageMenu(message: message, link: link), perform: { [weak self] kind, link in self?.perform(kind, link: link) },
                                     react: { [weak self] in self?.react($0) }, moreReactions: { [weak self] in self?.pickEmoji() })
    }

    /// The menu as the keyboard opens it: the bubble's, then what a click on the bubble does.
    func keyboardMenu() -> NSMenu {
        let menu = textMenu(nil)
        guard let message else { return menu }
        MacKeyboardMenuItems.add(to: menu, message: message, openAttachment: { [context] in context.openAttachment(message) },
                                 openLink: { [context] in context.openLink($0) }, showQuote: showQuote)
        return menu
    }

    /// Scrolls to the message the reply quotes, as a click on the quote does.
    var showQuote: (() -> Void)? {
        guard let message, !message.showsPlaceholder, let reference = message.reply?.messageID else { return nil }
        return { [context] in context.openQuote(reference) }
    }

    /// Select Text stays in the row, where the text view is; everything else goes to the conversation.
    func perform(_ kind: MessageAction.Kind, link: URL?) {
        guard let message else { return }
        if kind == .selectText {
            window?.makeFirstResponder(textView)
            textView.selectAll(nil)
        } else {
            context.handlers.perform(kind, message, link)
        }
    }

    func react(_ emoji: String) {
        guard let message else { return }
        context.handlers.react(emoji, message)
    }

    /// Any emoji as a reaction, in a popover on the bubble.
    func pickEmoji() {
        guard let message, emojiPopover == nil else { return }
        let popover = NSPopover()
        popover.behavior = .transient
        popover.contentViewController = NSHostingController(rootView: MacEmojiPicker(message: message) { [weak self] emoji in
            self?.closePopover()
            self?.react(emoji)
        })
        popover.delegate = self
        emojiPopover = popover
        updateToolbarVisibility()
        #if DEBUG
        if MacUnobtrusive.isOn { MacDebugHooks.log("emoji picker on \(message.id)") }
        #endif
        popover.show(relativeTo: bubbleFrame, of: self, preferredEdge: .minY)
    }

    private func closePopover() {
        emojiPopover?.close()
        emojiPopover = nil
    }

    // MARK: Menus and clicks

    /// The message's menu for a right-click on the bubble, never on the empty gutter beside it.
    override func menu(for event: NSEvent) -> NSMenu? {
        let point = convert(event.locationInWindow, from: nil)
        return bubbleFrame.contains(point) ? textMenu(nil) : nil
    }

    func textView(_ textView: NSTextView, clickedOnLink link: Any, at charIndex: Int) -> Bool {
        guard let url = link as? URL ?? (link as? String).flatMap(URL.init(string:)) else { return false }
        context.openLink(url)
        return true
    }

    /// A search or starred result says what a click does, under the pointer.
    private func updateToolTip() {
        let tip = context.isFiltered && hovering ? "Show in Conversation" : nil
        if toolTip != tip { toolTip = tip }
    }

    // MARK: Tint

    private func updateTint() {
        tint.tint = highlighted ? .highlight : context.isFiltered && hovering ? .hover : .none
    }

    // MARK: Accessibility

    private func updateAccessibility(_ layout: MacRowLayout, message: TimelineMessage) {
        let sender = message.senderName(contactName: context.contactName)
        element.setAccessibilityLabel(message.accessibilityDescription(sender: sender))
        element.message = message
        if let text = layout.input.header {
            headerElement.setAccessibilityLabel(text)
        }
    }

    override func isAccessibilityElement() -> Bool { false }

    override func accessibilityChildren() -> [Any]? {
        guard layoutRecord != nil else { return [] }
        return layoutRecord?.header == nil ? [element] : [headerElement, element]
    }

    /// The actions VoiceOver offers on the message, in the order the bubble's menu lists them: a search or starred
    /// result's Show in Conversation first, then the menu's items, the file's (open it, then the Mac's copy, save and
    /// share), one per link, the quoted message, and one per quick reaction, as on the iPhone.
    func accessibilityActions() -> [NSAccessibilityCustomAction] {
        guard let message else { return [] }
        var actions: [NSAccessibilityCustomAction] = []
        func add(_ name: String, _ handler: @escaping () -> Void) {
            actions.append(NSAccessibilityCustomAction(name: name) { handler(); return true })
        }
        let id = message.id
        if context.isFiltered { add("Show in Conversation") { [context] in context.showResult(id) } }
        let menu = MacMessageMenu(message: message)
        for item in menu.items { add(MacMessageMenu.title(for: item)) { [weak self] in self?.perform(item.kind, link: nil) } }
        if let attachment = MessageActionMenu.attachmentAction(for: message) {
            add(attachment.title) { [context] in context.openAttachment(message) }
        }
        if let attachment = menu.attachment {
            for item in attachment.items { add(item.title) { attachment.perform(item.kind) } }
        }
        for link in message.links {
            add(MessageActionMenu.linkAccessibilityTitle(for: link)) { [context] in context.openLink(link.url) }
        }
        if let showQuote { add(MacKeyboardMenuItems.showQuoteTitle, showQuote) }
        for toggle in MessageActionMenu.reactionToggles(for: message) {
            add(toggle.title) { [weak self] in self?.react(toggle.emoji) }
        }
        return actions
    }

    var headerFrame: CGRect { header.frame }

    /// The message's element covers the author line, the bubble and its pills.
    var messageFrame: CGRect {
        guard let layout = layoutRecord else { return bounds }
        var frame = place(layout.bubbleFrame)
        if let author = layout.authorFrame { frame = frame.union(author) }
        if let pills = layout.reactionsFrame { frame = frame.union(place(pills)) }
        return frame
    }

    #if DEBUG
    /// The tour's row steps: Select Text, and the emoji picker.
    func debugRequest(_ verb: String) {
        switch verb {
        case "select-text": perform(.selectText, link: nil)
        case "pick-emoji": pickEmoji()
        default: break
        }
    }
    #endif
}

extension MacTimelineMessageCell: NSPopoverDelegate {
    func popoverDidClose(_ notification: Notification) {
        emojiPopover = nil
        updateToolbarVisibility()
    }
}

/// A message as VoiceOver reads it: one element with the author, the text, the file, the quote, the time, the status
/// and the reactions, and the bubble's actions.
final class MacTimelineMessageElement: NSAccessibilityElement, NSAccessibilityElementProtocol {
    weak var cell: MacTimelineMessageCell?
    var message: TimelineMessage?

    override func accessibilityRole() -> NSAccessibility.Role? { .staticText }
    override func accessibilityParent() -> Any? { cell }
    override func accessibilityIdentifier() -> String { message.map { "message.\($0.id)" } ?? "" }

    override func accessibilityFrame() -> NSRect {
        let cell = cell
        return MainActor.assumeIsolated {
            guard let cell, let window = cell.window else { return .zero }
            return window.convertToScreen(cell.convert(cell.messageFrame, to: nil))
        }
    }

    override func accessibilityCustomActions() -> [NSAccessibilityCustomAction]? {
        let cell = cell
        nonisolated(unsafe) var actions: [NSAccessibilityCustomAction]?
        MainActor.assumeIsolated { actions = cell?.accessibilityActions() }
        return actions
    }

    override func accessibilityPerformShowMenu() -> Bool {
        let cell = cell, id = message?.id
        return MainActor.assumeIsolated {
            guard let cell, let id else { return false }
            cell.context.openMenu(id)
            return true
        }
    }
}

/// The day header above a message, which VoiceOver reads as a heading.
final class MacTimelineHeaderElement: NSAccessibilityElement {
    weak var cell: MacTimelineMessageCell?

    override func accessibilityRole() -> NSAccessibility.Role? { NSAccessibility.Role(rawValue: "AXHeading") }
    override func accessibilityParent() -> Any? { cell }

    override func accessibilityFrame() -> NSRect {
        let cell = cell
        return MainActor.assumeIsolated {
            guard let cell, let window = cell.window else { return .zero }
            return window.convertToScreen(cell.convert(cell.headerFrame, to: nil))
        }
    }
}

/// A row SwiftUI draws whole: the typing bubble, or the loading row above the oldest message.
final class MacTimelineHostedCell: NSView {
    static let identifier = NSUserInterfaceItemIdentifier("timeline.hosted")

    private let host = NSHostingView(rootView: AnyView(EmptyView()))

    override init(frame: NSRect) {
        super.init(frame: frame)
        identifier = Self.identifier
        host.sizingOptions = []
        host.autoresizingMask = [.width, .height]
        host.frame = bounds
        addSubview(host)
    }

    required init?(coder: NSCoder) { fatalError("not used") }

    func show(_ view: AnyView) { host.rootView = view }
}
