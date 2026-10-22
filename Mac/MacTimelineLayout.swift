import AppKit
import CoreText
import SwiftUI

// The timeline's row geometry, worked out once per row and held as immutable records (`MacRowLayout`). A record is
// keyed by the row's id, its revision (bumped whenever the row changes) and the width its bubble's content is laid out
// at; a timeline width that gives the same content width (any timeline at or above about 699 pt, where the bubble cap
// is 560) reuses the record, so the row's height never changes there. Records are made on a serial `.utility` queue and,
// for the rows in sight, on the main thread; the table only ever looks a height up.
//
// The geometry follows the bubble's design to whole points: the day header's capsule, the author line, the bubble (the
// quote, file and preview card, then the text, then the footer, 4 pt apart inside 12 pt sides, 8 pt above and 6 pt
// below) and the reaction pills hung 3 pt into the bubble's bottom padding. Frames are for a bubble on the leading
// side; the cell mirrors them for a sent message, so a record holds at every timeline width with the same key.

/// Fonts and fixed sizes, read once on the main thread. Fonts are immutable, so the measuring queue may read them.
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
    /// Between the bubble's parts: the quote, file and card, the text, the footer.
    static let partSpacing: CGFloat = 4
    static let stackSpacing: CGFloat = 2
    static let cornerRadius: CGFloat = 16
    static let statusSlot = CGSize(width: MessageStatusArt.slotWidth, height: MessageStatusArt.designHeight)
    /// A photo or video fixes the bubble's content width, as on the iPhone: a caption wraps under it.
    static let mediaContentWidth = MacMediaPreview.width - 2 * MacMediaPreview.edge

    /// The bubble's cap for a content width (the timeline less 16 pt each side), to whole points:
    /// `min(560, 0.84 × width, width − 32)`, and never under 120.
    static func cap(contentWidth width: CGFloat) -> CGFloat { floor(max(120, min(560, width * 0.84, width - 32))) }
}

/// What a row is laid out from: a snapshot the measuring queue may read.
struct MacRowInput: @unchecked Sendable {
    let id: String
    let revision: Int
    /// The bubble's text (`MacBubbleTextBuilder`), empty for a file without a caption. Immutable.
    let text: NSAttributedString
    let header: String?
    let author: String?
    let isOutgoing: Bool
    let footer: String?
    let hasStatus: Bool
    let reactions: [(emoji: String, count: String?)]
    let startsRun: Bool
    /// The quote, file and preview card above the text, which SwiftUI draws (`MacBubbleExtras`); nil without any.
    let extras: Extras?
    let message: TimelineMessage

    struct Extras: Sendable {
        /// The content width a photo or video fixes.
        let fixedWidth: CGFloat?
        /// A guess at their height for a record made before SwiftUI measured them.
        let estimate: CGFloat
    }

    var hasText: Bool { text.length > 0 }
}

/// A row's laid-out geometry, in its cell's flipped coordinates, for a bubble on the leading side.
struct MacRowLayout: @unchecked Sendable {
    struct Key: Hashable {
        let id: String
        let revision: Int
        let contentWidth: CGFloat
    }

    let key: Key
    let input: MacRowInput
    let height: CGFloat
    /// The day header's capsule: its width and its top; it is centred in the row.
    let header: (width: CGFloat, y: CGFloat, height: CGFloat)?
    let authorFrame: CGRect?
    let bubbleFrame: CGRect
    /// The hosting view of the quote, file and card: the bubble's width, from its top edge to theirs plus their height,
    /// so a photo can reach into the bubble's padding.
    let extrasFrame: CGRect?
    let textFrame: CGRect?
    let footerFrame: CGRect
    /// The pills' frame, 10 pt in from the row's edge on the bubble's side.
    let reactionsFrame: CGRect?
    /// The pills shown: all, or the first ones and a "+N".
    let pills: [MacReactionPill]
    /// The text draws whole into a plain layer (`BubbleTextView.drawsWhole`).
    let drawsWhole: Bool
    /// Made away from the main thread before SwiftUI had measured the extras: their height is a guess, and the row is
    /// measured again when it shows.
    let provisional: Bool
}

/// One reaction pill: its emoji (nil for the "+N" that stands for the rest), its count and its width.
struct MacReactionPill: Equatable, Sendable {
    let emoji: String?
    let count: String?
    let width: CGFloat
}

/// The extras' sizes SwiftUI measured, per row revision, readable from the measuring queue.
final class MacExtrasSizes: @unchecked Sendable {
    static let shared = MacExtrasSizes()

    private struct Entry {
        var revision: Int
        var ideal: CGFloat?
        var heights: [CGFloat: CGFloat]
    }

    private let lock = NSLock()
    private var entries: [String: Entry] = [:]

    func ideal(_ id: String, revision: Int) -> CGFloat? {
        lock.withLock { entries[id].flatMap { $0.revision == revision ? $0.ideal : nil } }
    }

    func height(_ id: String, revision: Int, width: CGFloat) -> CGFloat? {
        lock.withLock { entries[id].flatMap { $0.revision == revision ? $0.heights[width] : nil } }
    }

    func store(_ id: String, revision: Int, ideal: CGFloat) {
        lock.withLock {
            if entries[id]?.revision != revision { entries[id] = Entry(revision: revision, ideal: nil, heights: [:]) }
            entries[id]?.ideal = ideal
        }
    }

    func store(_ id: String, revision: Int, width: CGFloat, height: CGFloat) {
        lock.withLock {
            if entries[id]?.revision != revision { entries[id] = Entry(revision: revision, ideal: nil, heights: [:]) }
            entries[id]?.heights[width] = height
        }
    }
}

/// Measures the extras through SwiftUI, on the main thread: one hosting controller, its root swapped for each.
@MainActor final class MacExtrasSizer {
    private let host = NSHostingController(rootView: AnyView(EmptyView()))

    init() { host.sizingOptions = [] }

    func ideal(_ message: TimelineMessage, revision: Int) -> CGFloat {
        if let ideal = MacExtrasSizes.shared.ideal(message.id, revision: revision) { return ideal }
        host.rootView = AnyView(MacBubbleExtrasContent.sizing(message).fixedSize())
        let ideal = ceil(host.sizeThatFits(in: CGSize(width: CGFloat.greatestFiniteMagnitude, height: .greatestFiniteMagnitude)).width)
        MacExtrasSizes.shared.store(message.id, revision: revision, ideal: ideal)
        return ideal
    }

    func height(_ message: TimelineMessage, revision: Int, width: CGFloat) -> CGFloat {
        if let height = MacExtrasSizes.shared.height(message.id, revision: revision, width: width) { return height }
        #if DEBUG
        MacPerfProbe.count("extras.measure")
        #endif
        host.rootView = AnyView(MacBubbleExtrasContent.sizing(message).frame(width: width))
        let height = ceil(host.sizeThatFits(in: CGSize(width: width, height: .greatestFiniteMagnitude)).height)
        MacExtrasSizes.shared.store(message.id, revision: revision, width: width, height: height)
        return height
    }
}

/// Lays rows out. One measurer per thread: the main thread's measures the rows in sight, with SwiftUI for the extras;
/// the queue's everything else, from what SwiftUI measured before. TextKit 1's objects may be used off the main thread
/// when no view is attached and one thread uses them at a time, which the serial queue guarantees; Core Text is
/// thread-safe. The text stack is configured as the bubble's text view's (`BubbleTextView.TextStack`), so the two lay
/// lines out alike to the point; Core Text differs from it by up to a hundred points on long texts.
final class MacRowMeasurer: @unchecked Sendable {
    let metrics: MacTimelineMetrics
    let queue = DispatchQueue(label: "haus.timeline.measure", qos: .utility)
    /// The main thread's: measures the extras that have no size yet.
    private let sizer: MacExtrasSizer?
    /// Each row's natural (unwrapped) text width and its footer's, per revision: what decides its content width.
    /// Shared by both measurers, so the main thread finds what the queue measured.
    nonisolated(unsafe) private static var natural: [String: (revision: Int, text: CGFloat, footer: CGFloat)] = [:]
    private static let lock = NSLock()
    private let storage = NSTextStorage()
    private let layoutManager = NSLayoutManager()
    private let container = NSTextContainer()

    init(metrics: MacTimelineMetrics, sizer: MacExtrasSizer?) {
        self.metrics = metrics
        self.sizer = sizer
        container.lineFragmentPadding = 0
        layoutManager.addTextContainer(container)
        storage.addLayoutManager(layoutManager)
    }

    /// The text's size laid out `width` wide (unbounded when nil), as the bubble's text view lays it out.
    func measureText(_ text: NSAttributedString, width: CGFloat?) -> CGSize {
        let available = width ?? .greatestFiniteMagnitude
        storage.setAttributedString(text)
        container.size = NSSize(width: available, height: .greatestFiniteMagnitude)
        layoutManager.ensureLayout(for: container)
        let used = layoutManager.usedRect(for: container)
        return CGSize(width: min(available, ceil(used.width)), height: ceil(used.height))
    }

    /// The content width a row gets in a timeline of content width `available`: the widest of its text, its footer
    /// and its extras, capped; a photo fixes it. `known` is false while the extras' width is a guess.
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
        if let sizer { return MainActor.assumeIsolated { sizer.ideal(input.message, revision: input.revision) } }
        return MacExtrasSizes.shared.ideal(input.id, revision: input.revision)
    }

    private func extrasHeight(_ input: MacRowInput, width: CGFloat) -> CGFloat? {
        if let sizer { return MainActor.assumeIsolated { sizer.height(input.message, revision: input.revision, width: width) } }
        return MacExtrasSizes.shared.height(input.id, revision: input.revision, width: width)
    }

    private func naturalWidths(_ input: MacRowInput) -> (CGFloat, CGFloat) {
        Self.lock.lock()
        let cached = Self.natural[input.id]
        Self.lock.unlock()
        if let cached, cached.revision == input.revision { return (cached.text, cached.footer) }
        let text = input.hasText ? measureText(input.text, width: nil).width : 0
        let footer = footerWidth(input)
        Self.lock.lock()
        Self.natural[input.id] = (input.revision, text, footer)
        Self.lock.unlock()
        return (text, footer)
    }

    /// A single line's width, through Core Text.
    func lineWidth(_ string: String, _ font: NSFont) -> CGFloat {
        let line = CTLineCreateWithAttributedString(NSAttributedString(string: string, attributes: [.font: font]))
        return ceil(CTLineGetTypographicBounds(line, nil, nil, nil))
    }

    /// The footer's natural width: the star's slot (there on every message, so starring never widens the bubble), the
    /// time and the status slot, 4 pt apart.
    private func footerWidth(_ input: MacRowInput) -> CGFloat {
        var width = 4 + metrics.starSize.width
        if let footer = input.footer { width += 4 + lineWidth(footer, metrics.caption2) }
        if input.hasStatus { width += 4 + MacTimelineMetrics.statusSlot.width }
        return width
    }

    /// The key a record for `input` has in a timeline `tableWidth` wide.
    func key(_ input: MacRowInput, tableWidth: CGFloat) -> MacRowLayout.Key {
        let available = max(1, tableWidth - 2 * MacTimelineMetrics.sidePadding)
        return MacRowLayout.Key(id: input.id, revision: input.revision, contentWidth: contentWidth(for: input, available: available).width)
    }

    /// Lays one row out for a timeline `tableWidth` wide; reuses `previous` when its key still holds and it was not a
    /// guess this measurer can now do better than.
    func layout(_ input: MacRowInput, tableWidth: CGFloat, previous: MacRowLayout? = nil) -> MacRowLayout {
        typealias M = MacTimelineMetrics
        let available = max(1, tableWidth - 2 * M.sidePadding)
        let (contentWidth, widthKnown) = self.contentWidth(for: input, available: available)
        let key = MacRowLayout.Key(id: input.id, revision: input.revision, contentWidth: contentWidth)
        if let previous, previous.key == key, !(previous.provisional && sizer != nil) { return previous }
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

    /// The longest line of pills that fits: every pill, else one fewer and a "+N", and so on, as on the iPhone.
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

/// A row's input: the bubble's text with its font, colour and link runs, and what the layout reads. Safe off the main
/// thread: rows past the first screenful are built on the measuring queue (link detection and date formatting are most
/// of a reload).
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

    /// What `MacBubbleExtras` shows, and a guess at its height until SwiftUI measures it.
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
        return MacRowInput.Extras(fixedWidth: media ? MacTimelineMetrics.mediaContentWidth : nil, estimate: estimate)
    }
}
