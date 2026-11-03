import AppKit
import CoreText
import SwiftUI

// Row geometry is held as immutable records keyed by row id, revision and content width, so timeline widths giving the
// same content width (from about 699 pt, the 560 pt cap) reuse them. Records are made on a serial queue and, for rows
// in sight, on the main thread; the cell mirrors them for sent messages.

// Fonts are immutable, so the measuring queue may read them.
struct MacTimelineMetrics: @unchecked Sendable {
    let body: NSFont
    let caption: NSFont
    let captionSemibold: NSFont
    let caption2: NSFont
    let caption2Semibold: NSFont
    let captionLine: CGFloat
    let caption2Line: CGFloat
    let starSize: CGSize
    let star: NSImage

    @MainActor static let shared = MacTimelineMetrics()

    @MainActor private init() {
        body = NSFont.preferredFont(forTextStyle: .body)
        caption = NSFont.preferredFont(forTextStyle: .caption1)
        captionSemibold = NSFont.systemFont(ofSize: caption.pointSize, weight: .semibold)
        caption2 = NSFont.preferredFont(forTextStyle: .caption2)
        caption2Semibold = NSFont.systemFont(ofSize: caption2.pointSize, weight: .semibold)
        let layout = NSLayoutManager()
        captionLine = ceil(layout.defaultLineHeight(for: caption))
        caption2Line = ceil(layout.defaultLineHeight(for: caption2))
        let configuration = NSImage.SymbolConfiguration(pointSize: caption2.pointSize, weight: .regular)
        star = NSImage(systemSymbolName: "star.fill", accessibilityDescription: nil)?.withSymbolConfiguration(configuration) ?? NSImage()
        star.isTemplate = true
        starSize = CGSize(width: ceil(star.size.width), height: ceil(star.size.height))
    }

    static let sidePadding: CGFloat = 16
    static let bubblePaddingH: CGFloat = 12
    static let bubbleTop: CGFloat = 8
    static let bubbleBottom: CGFloat = 6
    static let partSpacing: CGFloat = 4
    static let stackSpacing: CGFloat = 2
    static let cornerRadius: CGFloat = 16
    static let statusSlot = CGSize(width: MessageStatusArt.slotWidth, height: MessageStatusArt.designHeight)
    static let mediaContentWidth = MacMediaPreview.width - 2 * MacMediaPreview.edge

    static func cap(contentWidth width: CGFloat) -> CGFloat { floor(max(120, min(560, width * 0.84, width - 32))) }
}

// An immutable snapshot the measuring queue may read.
struct MacRowInput: @unchecked Sendable {
    let id: String
    let revision: Int
    let text: NSAttributedString
    let header: String?
    let author: String?
    let isOutgoing: Bool
    let footer: String?
    let hasStatus: Bool
    let reactions: [(emoji: String, count: String?)]
    let startsRun: Bool
    let extras: Extras?
    let message: TimelineMessage

    struct Extras: Sendable {
        let content: MacExtrasSizes.Content
        let fixedWidth: CGFloat?
        let estimate: CGFloat
    }

    var hasText: Bool { text.length > 0 }
}

// In the cell's flipped coordinates, for a bubble on the leading side.
struct MacRowLayout: @unchecked Sendable {
    struct Key: Hashable {
        let id: String
        let revision: Int
        let contentWidth: CGFloat
    }

    let key: Key
    let input: MacRowInput
    let height: CGFloat
    let header: (width: CGFloat, y: CGFloat, height: CGFloat)?
    let authorFrame: CGRect?
    let bubbleFrame: CGRect
    // Spans from the bubble's top edge, so a photo can reach into the bubble's padding.
    let extrasFrame: CGRect?
    let textFrame: CGRect?
    let footerFrame: CGRect
    let reactionsFrame: CGRect?
    let pills: [MacReactionPill]
    let drawsWhole: Bool
    // Made off the main thread before SwiftUI measured the extras: their height is a guess, measured again when shown.
    let provisional: Bool
    var isStandIn = false
}

extension MacRowLayout {
    func settled(_ input: MacRowInput, extrasHeight delta: CGFloat) -> MacRowLayout {
        func moved(_ rect: CGRect?) -> CGRect? { rect?.offsetBy(dx: 0, dy: delta) }
        var bubble = bubbleFrame
        bubble.size.height += delta
        var extras = extrasFrame
        extras?.size.height += delta
        return MacRowLayout(key: key, input: input, height: height + delta, header: header, authorFrame: authorFrame, bubbleFrame: bubble,
                            extrasFrame: extras, textFrame: moved(textFrame), footerFrame: footerFrame.offsetBy(dx: 0, dy: delta),
                            reactionsFrame: moved(reactionsFrame), pills: pills, drawsWhole: drawsWhole, provisional: false)
    }

    // Shown until the table takes the record's own height: what falls below the row's edge is cropped.
    func standIn(height: CGFloat) -> MacRowLayout {
        MacRowLayout(key: key, input: input, height: height, header: header, authorFrame: authorFrame, bubbleFrame: bubbleFrame,
                     extrasFrame: extrasFrame, textFrame: textFrame, footerFrame: footerFrame, reactionsFrame: reactionsFrame, pills: pills,
                     drawsWhole: drawsWhole, provisional: provisional, isStandIn: true)
    }
}

struct MacReactionPill: Equatable, Sendable {
    let emoji: String?
    let count: String?
    let width: CGFloat
}

// Readable from the measuring queue. Held per message only while its extras stay the same, not per revision:
// revisions are a table's own and start over when a chat opens again.
final class MacExtrasSizes: @unchecked Sendable {
    static let shared = MacExtrasSizes()

    // Without the card's image, whose stored aspect sizes it.
    struct Content: Equatable, Sendable {
        let reply: TimelineReply?
        let attachment: TimelineAttachment?
        let linkPreview: TimelineLinkPreview?

        init(_ message: TimelineMessage) {
            reply = message.reply
            attachment = message.attachment
            var preview = message.linkPreview
            preview?.image = nil
            linkPreview = preview
        }
    }

    private struct Entry {
        var content: Content
        var ideal: CGFloat?
        var heights: [CGFloat: CGFloat]
    }

    private let lock = NSLock()
    private var entries: [String: Entry] = [:]

    func ideal(_ id: String, content: Content) -> CGFloat? {
        lock.withLock { entries[id].flatMap { $0.content == content ? $0.ideal : nil } }
    }

    func height(_ id: String, content: Content, width: CGFloat) -> CGFloat? {
        lock.withLock { entries[id].flatMap { $0.content == content ? $0.heights[width] : nil } }
    }

    func store(_ id: String, content: Content, ideal: CGFloat) {
        lock.withLock {
            if entries[id]?.content != content { entries[id] = Entry(content: content, ideal: nil, heights: [:]) }
            entries[id]?.ideal = ideal
        }
    }

    func store(_ id: String, content: Content, width: CGFloat, height: CGFloat) {
        lock.withLock {
            if entries[id]?.content != content { entries[id] = Entry(content: content, ideal: nil, heights: [:]) }
            entries[id]?.heights[width] = height
        }
    }
}

// One hosting controller, its root swapped for each.
@MainActor final class MacExtrasSizer {
    private let host = NSHostingController(rootView: AnyView(EmptyView()))

    init() { host.sizingOptions = [] }

    func ideal(_ message: TimelineMessage, content: MacExtrasSizes.Content) -> CGFloat {
        if let ideal = MacExtrasSizes.shared.ideal(message.id, content: content) { return ideal }
        host.rootView = AnyView(MacBubbleExtrasContent.sizing(message).fixedSize())
        let ideal = ceil(host.sizeThatFits(in: CGSize(width: CGFloat.greatestFiniteMagnitude, height: .greatestFiniteMagnitude)).width)
        MacExtrasSizes.shared.store(message.id, content: content, ideal: ideal)
        return ideal
    }

    func height(_ message: TimelineMessage, content: MacExtrasSizes.Content, width: CGFloat) -> CGFloat {
        if let height = MacExtrasSizes.shared.height(message.id, content: content, width: width) { return height }
        #if DEBUG
        MacPerfProbe.count("extras.measure")
        #endif
        host.rootView = AnyView(MacBubbleExtrasContent.sizing(message).frame(width: width))
        let height = ceil(host.sizeThatFits(in: CGSize(width: width, height: .greatestFiniteMagnitude)).height)
        MacExtrasSizes.shared.store(message.id, content: content, width: width, height: height)
        return height
    }
}

// One per table, as its revisions are, shared by its two measurers so the main thread finds what the queue measured.
final class MacNaturalWidths: @unchecked Sendable {
    private let lock = NSLock()
    private var widths: [String: (revision: Int, text: CGFloat, footer: CGFloat)] = [:]

    func widths(_ id: String, revision: Int) -> (text: CGFloat, footer: CGFloat)? {
        lock.withLock { widths[id].flatMap { $0.revision == revision ? ($0.text, $0.footer) : nil } }
    }

    func store(_ id: String, revision: Int, text: CGFloat, footer: CGFloat) {
        lock.withLock { widths[id] = (revision, text, footer) }
    }
}

// One measurer per thread. TextKit 1 may be used off the main thread with no view attached and one thread at a time,
// which the serial queue guarantees; it is configured as `BubbleTextView.TextStack`, so lines match to the point (Core
// Text differs by up to a hundred points on long texts).
final class MacRowMeasurer: @unchecked Sendable {
    let metrics: MacTimelineMetrics
    let queue = DispatchQueue(label: "haus.timeline.measure", qos: .utility)
    private let sizer: MacExtrasSizer?
    private let natural: MacNaturalWidths
    private let storage = NSTextStorage()
    private let layoutManager = NSLayoutManager()
    private let container = NSTextContainer()

    init(metrics: MacTimelineMetrics, sizer: MacExtrasSizer?, natural: MacNaturalWidths) {
        self.metrics = metrics
        self.sizer = sizer
        self.natural = natural
        container.lineFragmentPadding = 0
        layoutManager.addTextContainer(container)
        storage.addLayoutManager(layoutManager)
    }

    func measureText(_ text: NSAttributedString, width: CGFloat?) -> CGSize {
        let available = width ?? .greatestFiniteMagnitude
        storage.setAttributedString(text)
        container.size = NSSize(width: available, height: .greatestFiniteMagnitude)
        layoutManager.ensureLayout(for: container)
        let used = layoutManager.usedRect(for: container)
        return CGSize(width: min(available, ceil(used.width)), height: ceil(used.height))
    }

    // `known` is false while the extras' width is a guess.
    func contentWidth(for input: MacRowInput, available: CGFloat) -> (width: CGFloat, known: Bool) {
        if let fixed = input.extras?.fixedWidth { return (fixed, true) }
        let (text, footer) = naturalWidths(input)
        var natural = max(text, footer)
        var known = true
        if input.extras != nil {
            if let ideal = extrasIdeal(input) { natural = max(natural, ideal) } else { known = false }
        }
        let bubble = min(ceil(natural) + 2 * MacTimelineMetrics.bubblePaddingH, MacTimelineMetrics.cap(contentWidth: available))
        return (bubble - 2 * MacTimelineMetrics.bubblePaddingH, known)
    }

    private func extrasIdeal(_ input: MacRowInput) -> CGFloat? {
        guard let content = input.extras?.content else { return nil }
        if let sizer { return MainActor.assumeIsolated { sizer.ideal(input.message, content: content) } }
        return MacExtrasSizes.shared.ideal(input.id, content: content)
    }

    private func extrasHeight(_ input: MacRowInput, width: CGFloat) -> CGFloat? {
        guard let content = input.extras?.content else { return nil }
        if let sizer { return MainActor.assumeIsolated { sizer.height(input.message, content: content, width: width) } }
        return MacExtrasSizes.shared.height(input.id, content: content, width: width)
    }

    private func naturalWidths(_ input: MacRowInput) -> (CGFloat, CGFloat) {
        if let cached = natural.widths(input.id, revision: input.revision) { return cached }
        let text = input.hasText ? measureText(input.text, width: nil).width : 0
        let footer = footerWidth(input)
        natural.store(input.id, revision: input.revision, text: text, footer: footer)
        return (text, footer)
    }

    func lineWidth(_ string: String, _ font: NSFont) -> CGFloat {
        let line = CTLineCreateWithAttributedString(NSAttributedString(string: string, attributes: [.font: font]))
        return ceil(CTLineGetTypographicBounds(line, nil, nil, nil))
    }

    // The star's slot is there on every message, so starring never widens the bubble.
    private func footerWidth(_ input: MacRowInput) -> CGFloat {
        var width = 4 + metrics.starSize.width
        if let footer = input.footer { width += 4 + lineWidth(footer, metrics.caption2) }
        if input.hasStatus { width += 4 + MacTimelineMetrics.statusSlot.width }
        return width
    }

    func key(_ input: MacRowInput, tableWidth: CGFloat) -> MacRowLayout.Key {
        let available = max(1, tableWidth - 2 * MacTimelineMetrics.sidePadding)
        return MacRowLayout.Key(id: input.id, revision: input.revision, contentWidth: contentWidth(for: input, available: available).width)
    }

    // On the main thread the extras' measured height replaces a queue record's guess.
    func layout(_ input: MacRowInput, tableWidth: CGFloat, previous: MacRowLayout? = nil) -> MacRowLayout {
        typealias M = MacTimelineMetrics
        let available = max(1, tableWidth - 2 * M.sidePadding)
        let (contentWidth, widthKnown) = self.contentWidth(for: input, available: available)
        let key = MacRowLayout.Key(id: input.id, revision: input.revision, contentWidth: contentWidth)
        if let previous, previous.key == key, !previous.isStandIn {
            guard previous.provisional, sizer != nil else { return previous }
            if let frame = previous.extrasFrame, let height = extrasHeight(input, width: contentWidth) {
                return previous.settled(input, extrasHeight: M.bubbleTop + height - frame.height)
            }
        }
        let bubbleWidth = contentWidth + 2 * M.bubblePaddingH
        let footerHeight = max(metrics.caption2Line, M.statusSlot.height, metrics.starSize.height)

        var y: CGFloat = input.startsRun && input.header == nil ? 8 : 2
        var header: (width: CGFloat, y: CGFloat, height: CGFloat)?
        if let text = input.header {
            y += 10
            let height = metrics.captionLine + 8
            header = (lineWidth(text, metrics.captionSemibold) + 20, y, height)
            y += height + 10 + M.stackSpacing
        }
        var authorFrame: CGRect?
        if input.startsRun, let author = input.author {
            let width = lineWidth(author, metrics.captionSemibold)
            authorFrame = CGRect(x: M.sidePadding + 12, y: y, width: min(width, available - 12), height: metrics.captionLine)
            y += metrics.captionLine + M.stackSpacing
        }
        let bubbleX = M.sidePadding
        let bubbleTop = y
        var inner = bubbleTop + M.bubbleTop
        var provisional = false
        var extrasFrame: CGRect?
        if let extras = input.extras {
            let measured = widthKnown ? extrasHeight(input, width: contentWidth) : nil
            if measured == nil { provisional = true }
            let height = measured ?? extras.estimate
            extrasFrame = CGRect(x: bubbleX, y: bubbleTop, width: bubbleWidth, height: M.bubbleTop + height)
            inner += height + M.partSpacing
        }
        var textFrame: CGRect?
        if input.hasText {
            let size = measureText(input.text, width: contentWidth)
            textFrame = CGRect(x: bubbleX + M.bubblePaddingH, y: inner, width: contentWidth, height: size.height)
            inner += size.height + M.partSpacing
        }
        let footerFrame = CGRect(x: bubbleX + M.bubblePaddingH, y: inner, width: contentWidth, height: footerHeight)
        let bubbleFrame = CGRect(x: bubbleX, y: bubbleTop, width: bubbleWidth, height: footerFrame.maxY + M.bubbleBottom - bubbleTop)
        y = bubbleFrame.maxY
        var reactionsFrame: CGRect?
        var pills: [MacReactionPill] = []
        if !input.reactions.isEmpty {
            pills = fitPills(input.reactions, available: available - 20)
            let width = pills.reduce(0) { $0 + $1.width } + CGFloat(max(0, pills.count - 1)) * 4
            let height = metrics.captionLine + 4
            // Into the bubble's 6 pt bottom padding only, clear of the footer, with 2 pt kept below so the pills stay
            // clear of the next message.
            y -= 3
            reactionsFrame = CGRect(x: M.sidePadding + 10, y: y, width: width, height: height)
            y += height + 2
        }
        let drawsWhole = input.text.length <= 1_000 && input.text.string.unicodeScalars.lazy.filter(CharacterSet.newlines.contains).count <= 40
            || measureText(input.text, width: BubbleTextView.narrowestText).height <= 4_000
        return MacRowLayout(key: key, input: input, height: ceil(y), header: header, authorFrame: authorFrame, bubbleFrame: bubbleFrame,
                            extrasFrame: extrasFrame, textFrame: textFrame, footerFrame: footerFrame, reactionsFrame: reactionsFrame, pills: pills,
                            drawsWhole: drawsWhole, provisional: provisional)
    }

    private func fitPills(_ reactions: [(emoji: String, count: String?)], available: CGFloat) -> [MacReactionPill] {
        func pill(_ emoji: String?, _ count: String?) -> MacReactionPill {
            var width: CGFloat = 12
            if let emoji { width += lineWidth(emoji, metrics.caption) }
            if let count { width += (emoji == nil ? 0 : 2) + lineWidth(count, metrics.caption2Semibold) }
            return MacReactionPill(emoji: emoji, count: count, width: width)
        }
        for shown in (1...reactions.count).reversed() {
            var pills = reactions.prefix(shown).map { pill($0.emoji, $0.count) }
            if shown < reactions.count { pills.append(pill(nil, "+\(reactions.count - shown)")) }
            let total = pills.reduce(0) { $0 + $1.width } + CGFloat(pills.count - 1) * 4
            if total <= available || shown == 1 { return pills }
        }
        return []
    }
}

// Safe off the main thread: rows past the first screenful are built on the measuring queue (link detection and date
// formatting are most of a reload).
enum MacBubbleTextBuilder {
    static func attributed(_ message: TimelineMessage, accent: AccentTheme, body: NSFont) -> NSAttributedString {
        guard !message.displayedText.isEmpty else { return NSAttributedString() }
        let font = message.showsPlaceholder ? NSFont(descriptor: body.fontDescriptor.withSymbolicTraits(.italic), size: 0) ?? body : body
        let color: NSColor = switch (message.isOutgoing, message.showsPlaceholder) {
        case (true, false): accent.bubbleText
        case (true, true): accent.bubbleText.withAlphaComponent(0.75)
        case (false, false): .labelColor
        case (false, true): .secondaryLabelColor
        }
        let text = NSMutableAttributedString(string: message.displayedText, attributes: [.font: font, .foregroundColor: color])
        for link in message.links where NSMaxRange(link.range) <= text.length {
            text.addAttribute(.link, value: link.url, range: link.range)
        }
        return NSAttributedString(attributedString: text)
    }

    static func input(_ row: TimelineRow, revision: Int, isGroup: Bool, accent: AccentTheme, body: NSFont) -> MacRowInput {
        let message = row.message
        return MacRowInput(id: message.id, revision: revision, text: attributed(message, accent: accent, body: body), header: row.dateHeader,
                           author: isGroup ? message.author.map { ContactName.display(for: $0, title: nil) } : nil,
                           isOutgoing: message.isOutgoing, footer: message.showsFooterText ? message.footerText : nil,
                           hasStatus: message.statusGlyph != nil,
                           reactions: message.reactions.map { ($0.emoji, $0.count > 1 ? "\($0.count)" : nil) }, startsRun: row.startsRun,
                           extras: extras(message), message: message)
    }

    static func extras(_ message: TimelineMessage) -> MacRowInput.Extras? {
        guard !message.showsPlaceholder, message.reply != nil || message.attachment != nil || message.linkPreview != nil else { return nil }
        var estimate: CGFloat = 0
        var parts = 0
        if message.reply != nil { estimate += 32; parts += 1 }
        if let attachment = message.attachment {
            estimate += attachment.showsPreview ? MacMediaPreview.height(for: attachment) - (message.reply == nil ? MacMediaPreview.top : 0) : 36
            parts += 1
        }
        if message.linkPreview != nil { estimate += 72; parts += 1 }
        estimate += CGFloat(max(0, parts - 1)) * MacTimelineMetrics.partSpacing
        let media = message.attachment?.showsPreview == true
        return MacRowInput.Extras(content: MacExtrasSizes.Content(message), fixedWidth: media ? MacTimelineMetrics.mediaContentWidth : nil, estimate: estimate)
    }
}
