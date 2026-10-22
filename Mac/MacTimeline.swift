import AppKit
import SwiftUI

/// The open chat's timeline: an AppKit table (`MacTimelineTableController`) under the toolbar and the composer, with the
/// floating day chip and the jump-to-newest button over it. It opens at the newest message in its first frame, keeps
/// the reader's rows through updates and resizes, pages in older history near the top, and is one stop in the window's
/// keyboard focus, between the sidebar (and the find bar) and the composer: with focus the scrolling keys work (Page Up
/// and Down, Home and End, ⌘↑ and ⌘↓), ↑ and ↓ move a focus ring from message to message, Return or Space opens the
/// focused message's menu, and Esc goes to the composer. VoiceOver reads each message as one element with the bubble's
/// actions, and offers rotors over the messages, their links and the starred ones.
struct MacTimeline: View {
    let controller: MacTimelineController
    /// The contact's name in a direct chat, which VoiceOver reads as the sender of what they sent.
    let contactName: String?
    let handlers: MacMessageHandlers
    let openAttachment: (TimelineMessage) -> Void
    let openLink: (URL) -> Void
    @Environment(\.appearance) private var appearance

    var body: some View {
        ZStack {
            // Under the toolbar and the composer, whose heights become the table's insets; not under the sidebar.
            MacTimelineTable(controller: controller, accent: appearance.accent, contactName: contactName, handlers: handlers,
                             openAttachment: openAttachment, openLink: openLink)
                .ignoresSafeArea(.container, edges: .vertical)
            Color.clear
                .overlay(alignment: .top) { MacDayChip(controller: controller) }
                .overlay(alignment: .bottomTrailing) { MacJumpToNewest(controller: controller) }
        }
    }
}

private struct MacTimelineTable: NSViewControllerRepresentable {
    let controller: MacTimelineController
    let accent: AccentTheme
    let contactName: String?
    let handlers: MacMessageHandlers
    let openAttachment: (TimelineMessage) -> Void
    let openLink: (URL) -> Void

    func makeNSViewController(context: Context) -> MacTimelineTableController {
        update(controller.table)
        return controller.table
    }

    func updateNSViewController(_ table: MacTimelineTableController, context: Context) { update(table) }

    private func update(_ table: MacTimelineTableController) {
        let cells = table.context
        cells.handlers = handlers
        cells.openAttachment = openAttachment
        cells.openLink = openLink
        cells.contactName = contactName
        table.setAccent(accent)
    }
}

/// The floating day: the inline day header's capsule over an opaque backing, so rows passing under it never show
/// through. Its own view, so its movement redraws nothing else.
private struct MacDayChip: View {
    let controller: MacTimelineController
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        if let chip = controller.dayChip {
            Text(chip.text)
                .font(.caption.weight(.semibold)).foregroundStyle(.secondary)
                .padding(.horizontal, 10).padding(.vertical, 4)
                .frame(height: MacTimelineController.chipHeight)
                .background(.quaternary, in: Capsule())
                .background(Color(nsColor: .textBackgroundColor), in: Capsule())
                .opacity(chip.opacity)
                // Reduce Motion: it fades where it rests instead of being pushed up.
                .offset(y: reduceMotion ? MacTimelineController.chipLine : chip.top)
                .allowsHitTesting(false)
                .accessibilityHidden(true)
                .transition(.opacity)
        }
    }
}

/// Back to the newest message, while the reader is well above it.
private struct MacJumpToNewest: View {
    let controller: MacTimelineController
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        if controller.showsJumpToNewest {
            Button { controller.scroll(.bottom) } label: {
                Image(systemName: "chevron.down").font(.system(size: 15, weight: .semibold))
            }
            .buttonStyle(CircularGlassButtonStyle(diameter: 36, tinted: false))
            .accessibilityLabel("Scroll to Newest Message")
            .help("Scroll to the newest message")
            .padding(.trailing, 12).padding(.bottom, 8)
            .transition(reduceMotion ? .opacity : .opacity.combined(with: .scale(scale: 0.8)))
        }
    }
}

// MARK: - Table

/// Responsive scrolling needs an opaque document view and no `scrollWheel` override. Not flipped, with the newest
/// message in row 0 at the bottom (`MacTimelineTableController`).
final class MacTimelineTableView: NSTableView, @preconcurrency NSAccessibilityElementLoading {
    weak var timeline: MacTimelineTableController?

    override var isFlipped: Bool { false }
    override var isOpaque: Bool { true }
    override class var isCompatibleWithResponsiveScrolling: Bool { true }
    override var acceptsFirstResponder: Bool { true }

    override func keyDown(with event: NSEvent) {
        if timeline?.handleKey(event) != true { super.keyDown(with: event) }
    }

    override func mouseMoved(with event: NSEvent) {
        super.mouseMoved(with: event)
        timeline?.updateHover()
    }

    override func mouseEntered(with event: NSEvent) {
        super.mouseEntered(with: event)
        timeline?.updateHover()
    }

    override func mouseExited(with event: NSEvent) {
        super.mouseExited(with: event)
        timeline?.updateHover(outside: true)
    }

    private var hoverArea: NSTrackingArea?

    /// One tracking area for the whole table: the bubble under the pointer, its hover toolbar and its text's cursor.
    /// It follows the visible rect by itself, so it is made once; the table asks again on every scrolled frame.
    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        guard hoverArea == nil else { return }
        let area = NSTrackingArea(rect: .zero, options: [.mouseMoved, .mouseEnteredAndExited, .activeInActiveApp, .inVisibleRect], owner: self)
        addTrackingArea(area)
        hoverArea = area
    }

    override func accessibilityLabel() -> String? { "Messages" }

    /// The rows in reading order, oldest first, as they show (the table holds them newest first), without the filler
    /// under the newest message.
    private func readingOrder(_ rows: [Any]?) -> [Any]? {
        rows.map { rows in
            rows.filter { Self.rowIndex($0) != 0 }.reversed()
        }
    }

    override func accessibilityChildren() -> [Any]? { readingOrder(super.accessibilityChildren()) }
    override func accessibilityChildrenInNavigationOrder() -> [any NSAccessibilityElementProtocol]? {
        readingOrder(super.accessibilityChildrenInNavigationOrder())?.compactMap { $0 as? any NSAccessibilityElementProtocol }
    }

    @objc(accessibilityRows) func readingRows() -> [Any]? {
        readingOrder(super.accessibilityChildren())?.filter { ($0 as? NSObject)?.accessibilityAttributeValue(.role) as? String == NSAccessibility.Role.row.rawValue }
    }

    /// A row element's index; the table's row elements answer only the older attribute API.
    private static func rowIndex(_ row: Any) -> Int? {
        guard let row = row as? NSObject, row.accessibilityAttributeValue(.role) as? String == NSAccessibility.Role.row.rawValue else { return nil }
        return row.accessibilityAttributeValue(.index) as? Int
    }

    @objc(accessibilityVisibleRows) func readingVisibleRows() -> [Any]? {
        let visible = rows(in: visibleRect)
        return readingRows()?.filter { row in
            Self.rowIndex(row).map { NSLocationInRange($0, visible) } ?? false
        }
    }

    override func accessibilityCustomRotors() -> [NSAccessibilityCustomRotor] { timeline?.rotors ?? [] }

    func accessibilityElement(withToken token: any NSAccessibilityLoadingToken) -> (any NSAccessibilityElementProtocol)? {
        guard let id = (token as AnyObject) as? NSString, let element = timeline?.element(for: id as String) else { return nil }
        let loaded: any NSAccessibilityElementProtocol = element
        return loaded
    }
}

final class MacTimelineClipView: NSClipView {
    override class var isCompatibleWithResponsiveScrolling: Bool { true }
}

/// The root view, which hears the window's live resize end.
final class MacTimelineRootView: NSView {
    var endedLiveResize: () -> Void = {}

    override func viewDidEndLiveResize() {
        super.viewDidEndLiveResize()
        endedLiveResize()
    }
}

/// The current generation, readable from the measuring queue: a pass for an older one stops early.
final class MacTimelineGeneration: @unchecked Sendable {
    private let lock = NSLock()
    private var value = 0
    var current: Int { lock.withLock { value } }
    func bump() -> Int { lock.withLock { value += 1; return value } }
}

/// The timeline as a view-based `NSTableView`, as Telegram's Mac app builds it.
///
/// - **Geometry.** The table is not flipped and its rows are reversed: row 0 is the newest message, at the bottom of
///   the document. Older pages are rows inserted at high indices, above the reader, and the clip view's origin
///   (measured up from the bottom) does not move, so the reader's rows stay where they are with no correction. A row
///   changing height moves only the rows above it, so a resize keeps the lowest visible row in place.
/// - **Arrivals.** A new message is a row inserted at index 0: everything above it moves up by its height. At the
///   bottom that is the follow; scrolled up, the clip view's origin moves by exactly what moved the reader's rows, in
///   the same turn. Never during a scroll gesture: a change below the top of the screen waits for the gesture (and its
///   momentum) to end.
/// - **Heights** come only from cached records (`MacRowLayout`), measured on a serial `.utility` queue; the first
///   screenful, and the rows of a small change, are measured on the main thread so the first frame is right.
///   `heightOfRow` only looks a height up, or estimates one for a row above the reader not measured yet.
/// - **Resizes.** During a live resize only the rows in sight are measured again at each width; once it ends every row
///   is, on the queue, and the heights are applied in one go with the reader's rows kept. Above the bubble's width cap
///   nothing changes height.
/// - **Scrolling** is observed through the clip view's bounds changes, with constant work, publishing only derived
///   changes.
@MainActor final class MacTimelineTableController: NSViewController, NSTableViewDataSource, NSTableViewDelegate, @preconcurrency NSAccessibilityCustomRotorItemSearchDelegate {
    weak var timeline: MacTimelineController?
    let context = MacTimelineCellContext()
    let scrollView = NSScrollView()
    let table = MacTimelineTableView()
    private let mainMeasurer: MacRowMeasurer
    private let queueMeasurer: MacRowMeasurer

    /// One row of the table.
    private enum Entry: Equatable {
        /// Below the newest message: the room a timeline shorter than the frame leaves, so its messages start at the top
        /// as in any list. Always there, at least a point tall (a row cannot be shorter), which the bottom inset takes back.
        case filler
        case loading
        case message(TimelineRow)
        case typing(TimelineTyping)

        var id: String {
            switch self {
            case .filler: "filler\u{0}"
            case .loading: TimelineItems.loadingEarlierID
            case .message(let row): row.message.id
            case .typing: TimelineItems.typingID
            }
        }
    }

    /// Newest first: `entries[0]` is the bottom row.
    private var entries: [Entry] = []
    private var indexByID: [String: Int] = [:]
    /// Each message's revision, bumped when its row changes; a record holds for one revision.
    private var revisions: [String: Int] = [:]
    private var revisionCounter = 0
    /// The applied record per message, at some width; rows not measured yet have none and an estimated height.
    private var layouts: [String: MacRowLayout] = [:]
    /// The table width each record was last made or checked for.
    private var layoutWidths: [String: CGFloat] = [:]
    /// Each message's input (its attributed text), built once per revision.
    private var inputs: [String: MacRowInput] = [:]
    /// The typing and loading rows' heights, by what they show and the width.
    private var hostedHeights: [String: CGFloat] = [:]
    private let hostedSizer = NSHostingController(rootView: AnyView(EmptyView()))
    private var isGroup = false
    /// The width every applied record was laid out for, or will be once the pass for it lands.
    private var width: CGFloat = 0
    /// Bumped by every width change and reload: a measuring pass for an older one is dropped.
    private let generations = MacTimelineGeneration()
    private var generation = 0
    /// An update is measured on the queue and not applied yet; a change that arrives meanwhile waits for it.
    private(set) var isApplying = false
    private var pendingCommit: (([MacRowLayout]) -> Void)?
    private var updateWaiting = false
    /// A change that would move the rows in sight arrived during a scroll gesture: it waits for the gesture to end.
    private var heldUpdate = false
    /// Heights that landed during a scroll gesture for rows below the top of the screen.
    private var heldNotes = IndexSet()
    private(set) var isLiveScrolling = false
    #if DEBUG
    var debugReaderScrolling = false
    #endif
    /// The reader is at the newest message, or near it: set by every scroll, kept through content changes and resizes,
    /// which move the newest message under a reader who stays where they are.
    private var followsEnd = true
    /// The timeline is moving itself (an update, a jump, new insets): the scrolls it makes are not the reader's.
    private var adjusting = false
    /// Away from the newest message, the reader's row and its distance from the frame's top edge where they last left
    /// it: what a resize keeps, as the window, the sidebar or the composer change the frame under them.
    private var restingPlace: (id: String, top: CGFloat)?
    private var clipSize = CGSize.zero
    /// The toolbar's and the bars' heights over the top of the table, and the composer's under it.
    private var bars = NSEdgeInsets()
    private var bannerBar: CGFloat = 0
    private var findBars: CGFloat = 0
    private var bottomBar: CGFloat = 0
    private var endPass: DispatchWorkItem?
    private var widthPending = false
    private var shownIDs: Set<String> = []
    private var hovered: MacTimelineMessageCell?
    private var firstResponderObservation: NSKeyValueObservation?
    private var tableHasFocus = false
    /// Where a reload asked for before the view was laid out puts the reader once it is.
    private var pendingReload: MacTimelinePlace? = .newest

    init() {
        let natural = MacNaturalWidths()
        mainMeasurer = MacRowMeasurer(metrics: .shared, sizer: MacExtrasSizer(), natural: natural)
        queueMeasurer = MacRowMeasurer(metrics: .shared, sizer: nil, natural: natural)
        super.init(nibName: nil, bundle: nil)
        hostedSizer.sizingOptions = []
        context.textKey = { [weak self] key, id in self?.timeline?.bubbleTextKey(key, in: id) }
        context.textFocused = { [weak self] id in self?.timeline?.bubbleTextFocused(id) }
        context.showResult = { [weak self] id in self?.timeline?.scrollTo(messageID: id) }
        context.openQuote = { [weak self] reference in self?.timeline?.scrollTo(quotedMessage: reference) }
        context.openMenu = { [weak self] id in self?.timeline?.openMenu(for: id) }
    }

    required init?(coder: NSCoder) { fatalError("not used") }

    override func loadView() {
        let root = MacTimelineRootView()
        root.endedLiveResize = { [weak self] in self?.liveResizeEnded() }
        scrollView.contentView = MacTimelineClipView()
        scrollView.hasVerticalScroller = true
        scrollView.hasHorizontalScroller = false
        scrollView.autohidesScrollers = true
        scrollView.drawsBackground = true
        scrollView.backgroundColor = .textBackgroundColor
        scrollView.contentView.drawsBackground = true
        scrollView.contentView.backgroundColor = .textBackgroundColor
        scrollView.automaticallyAdjustsContentInsets = false
        scrollView.verticalScrollElasticity = .allowed

        let column = NSTableColumn(identifier: NSUserInterfaceItemIdentifier("message"))
        column.resizingMask = .autoresizingMask
        table.addTableColumn(column)
        table.headerView = nil
        table.intercellSpacing = .zero
        table.usesAutomaticRowHeights = false
        table.columnAutoresizingStyle = .uniformColumnAutoresizingStyle
        table.selectionHighlightStyle = .none
        table.backgroundColor = .textBackgroundColor
        table.gridStyleMask = []
        table.allowsColumnReordering = false
        table.allowsEmptySelection = true
        table.focusRingType = .none
        table.style = .plain
        table.dataSource = self
        table.delegate = self
        table.timeline = self
        table.target = self
        table.action = #selector(rowClicked)
        scrollView.documentView = table

        scrollView.frame = root.bounds
        scrollView.autoresizingMask = [.width, .height]
        root.addSubview(scrollView)
        view = root

        scrollView.contentView.postsBoundsChangedNotifications = true
        NotificationCenter.default.addObserver(self, selector: #selector(clipBoundsChanged), name: NSView.boundsDidChangeNotification, object: scrollView.contentView)
        table.postsFrameChangedNotifications = true
        NotificationCenter.default.addObserver(self, selector: #selector(tableFrameChanged), name: NSView.frameDidChangeNotification, object: table)
        NotificationCenter.default.addObserver(self, selector: #selector(liveScrollStarted), name: NSScrollView.willStartLiveScrollNotification, object: scrollView)
        NotificationCenter.default.addObserver(self, selector: #selector(liveScrollEnded), name: NSScrollView.didEndLiveScrollNotification, object: scrollView)
    }

    override func viewDidAppear() {
        super.viewDidAppear()
        firstResponderObservation = view.window?.observe(\.firstResponder, options: [.new]) { [weak self] window, _ in
            MainActor.assumeIsolated { self?.firstResponderChanged(window.firstResponder) }
        }
        updateInsets()
        applyWidth()
        if followsEnd { scrollToNewest() }
    }

    override func viewDidDisappear() {
        super.viewDidDisappear()
        firstResponderObservation = nil
    }

    // MARK: Insets

    /// The bars over the top of the timeline (the device banner and the find bars) and the composer, or the bar that
    /// stands in for it, under it; the toolbar's height comes from the window.
    func setBars(banner: CGFloat? = nil, find: CGFloat? = nil, bottom: CGFloat? = nil) {
        if let banner { bannerBar = banner }
        if let find { findBars = find }
        if let bottom { bottomBar = bottom }
        guard isViewLoaded else { return }
        updateInsets()
    }

    override func viewDidLayout() {
        super.viewDidLayout()
        updateInsets()
        if let place = pendingReload, table.bounds.width > 0 {
            pendingReload = nil
            reloadAll(at: place)
        }
        applyWidth()
    }

    /// The titlebar and toolbar's height: the window's content less its content layout rect. Taken from the window, not
    /// from this view's frame, which is mid-update while SwiftUI lays a resize out.
    private var toolbarHeight: CGFloat {
        guard let window = view.window, let content = window.contentView else { return 0 }
        return max(0, content.bounds.height - window.contentLayoutRect.height)
    }

    private func updateInsets() {
        let next = NSEdgeInsets(top: toolbarHeight + bannerBar + findBars, left: 0, bottom: bottomBar, right: 0)
        guard next.top != bars.top || next.bottom != bars.bottom else { return }
        let margin = MacTimelineController.topMargin
        adjusting = true
        bars = next
        scrollView.contentInsets = NSEdgeInsets(top: next.top + margin, left: 0, bottom: next.bottom + margin - 1, right: 0)
        scrollView.scrollerInsets = NSEdgeInsets(top: next.top, left: 0, bottom: next.bottom, right: 0)
        updateFiller()
        // A taller composer or a find bar opening leaves the reader's row where it was, or the newest message above it.
        keepPlace()
        adjusting = false
        clipBoundsChanged()
    }

    // MARK: Positions

    /// The clip view's bounds in the table's coordinates.
    private var clip: CGRect { scrollView.contentView.bounds }

    /// What is on screen between the toolbar and the bars above and the composer below, in the table's coordinates.
    private var visibleFrame: CGRect {
        let clip = clip
        return CGRect(x: clip.minX, y: clip.minY + bars.bottom, width: clip.width, height: max(1, clip.height - bars.top - bars.bottom))
    }

    /// The height of what is on screen.
    var frameHeight: CGFloat { visibleFrame.height }

    /// How far above the newest message the frame's bottom is, the margin below it included: zero at the end. Not
    /// flipped: the clip view's origin rises from minus the bottom inset at the newest message.
    var distanceFromBottom: CGFloat { clip.minY + scrollView.contentInsets.bottom }

    /// From the top of the oldest row to the frame's top edge.
    var distanceFromTop: CGFloat { table.bounds.height - visibleFrame.maxY }

    private func scroll(toY y: CGFloat) {
        let clipView = scrollView.contentView
        let lowest = -scrollView.contentInsets.bottom
        let highest = max(lowest, table.bounds.height + scrollView.contentInsets.top - clipView.bounds.height)
        let target = min(highest, max(lowest, y))
        guard abs(target - clipView.bounds.minY) > 0.01 else { return }
        clipView.scroll(to: NSPoint(x: 0, y: target))
        scrollView.reflectScrolledClipView(clipView)
    }

    private func scroll(toDistanceFromBottom distance: CGFloat) {
        scroll(toY: distance - scrollView.contentInsets.bottom)
    }

    func scrollToNewest() {
        adjust { scroll(toDistanceFromBottom: 0) }
        followsEnd = true
    }

    func scrollToOldest() {
        adjust { scroll(toY: .greatestFiniteMagnitude) }
    }

    /// Moves the content by `delta` (positive moves it down, towards older messages).
    func scroll(by delta: CGFloat) {
        adjust { scroll(toY: clip.minY + delta) }
    }

    /// Runs a move of the timeline's own, then notes where it left the reader.
    private func adjust(_ move: () -> Void) {
        let was = adjusting
        adjusting = true
        move()
        adjusting = was
        if !was {
            followsEnd = distanceFromBottom < TimelineScrollPolicy.nearBottomDistance
            noteRestingPlace()
            clipBoundsChanged()
        }
    }

    private func noteRestingPlace() {
        restingPlace = followsEnd ? nil : readerRow().map { ($0.id, $0.top) }
    }

    /// After the frame changed under the reader: at the newest message when they follow it, else their row where it
    /// was below the frame's top edge.
    private func keepPlace() {
        let was = adjusting
        adjusting = true
        defer { adjusting = was }
        if followsEnd {
            scroll(toDistanceFromBottom: 0)
        } else if let rest = restingPlace, let row = indexByID[rest.id] {
            let height = table.rect(ofRow: row).height
            place(row: row, top: TimelineScrollPolicy.reachableTop(rest.top, rowHeight: height, frameHeight: frameHeight))
        }
    }

    /// A row's top and bottom edges below the frame's top edge.
    private func frameEdges(ofRow row: Int) -> (top: CGFloat, bottom: CGFloat) {
        let rect = table.rect(ofRow: row)
        let top = visibleFrame.maxY
        return (top - rect.maxY, top - rect.minY)
    }

    /// The message rows laid out in the frame, top to bottom, in its coordinates, with their places among the messages
    /// oldest first, as the shared policies read them.
    func placedRows() -> [TimelineScrollPolicy.PlacedRow] {
        let range = table.rows(in: visibleFrame)
        guard range.length > 0, let timeline else { return [] }
        let count = timeline.rows.count
        let first = firstMessageRow
        return (range.location..<min(entries.count, NSMaxRange(range))).reversed().compactMap { row in
            guard case .message(let message) = entries[row] else { return nil }
            let edges = frameEdges(ofRow: row)
            return TimelineScrollPolicy.PlacedRow(id: message.message.id, index: count - 1 - (row - first), top: edges.top,
                                                  bottom: edges.bottom, dayHeader: message.dateHeader)
        }
    }

    func isOnScreen(_ id: String?) -> Bool {
        guard let id, let row = indexByID[id] else { return false }
        let edges = frameEdges(ofRow: row)
        return edges.bottom > 0 && edges.top < frameHeight
    }

    /// Puts the row's top edge `top` below the frame's top edge, as near as the content allows.
    private func place(row: Int, top: CGFloat) {
        let rect = table.rect(ofRow: row)
        scroll(toY: rect.maxY + top + bars.top - clip.height)
    }

    /// Where the reader is now: the newest message, or the reader's row and its distance from the frame's top edge.
    func readerPlace() -> MacTimelinePlace {
        guard distanceFromBottom >= TimelineScrollPolicy.nearBottomDistance,
              let reader = TimelineScrollPolicy.readerRow(placedRows(), visibleTop: 0, visibleBottom: frameHeight) else { return .newest }
        return .row(id: reader.id, top: reader.top)
    }

    func readerRow() -> TimelineScrollPolicy.PlacedRow? {
        TimelineScrollPolicy.readerRow(placedRows(), visibleTop: 0, visibleBottom: frameHeight)
    }

    /// The lowest row in sight and how far its bottom edge is above the clip view's origin: what changes below the
    /// reader are compensated against.
    private struct Anchor {
        let id: String
        let offset: CGFloat
    }

    private func captureAnchor() -> Anchor? {
        let range = table.rows(in: visibleFrame)
        guard range.length > 0 else { return nil }
        // A message: the typing bubble can go with the change.
        var row = range.location
        while row < min(entries.count, NSMaxRange(range)) - 1, !isMessage(row) { row += 1 }
        guard row < entries.count else { return nil }
        return Anchor(id: entries[row].id, offset: table.rect(ofRow: row).minY - clip.minY)
    }

    private func restore(_ anchor: Anchor?) {
        guard let anchor, let row = indexByID[anchor.id] else { return }
        adjust { scroll(toY: table.rect(ofRow: row).minY - anchor.offset) }
    }

    /// Centres a message in the frame, or puts its top at the frame's top when it is taller; for a jump.
    func center(_ id: String) {
        guard let row = indexByID[id] else { return }
        measureForJump(around: row)
        let height = table.rect(ofRow: row).height
        let top = TimelineScrollPolicy.reachableTop(max(0, (frameHeight - height) / 2), rowHeight: height, frameHeight: frameHeight)
        adjust { place(row: row, top: top) }
    }

    /// Scrolls just far enough to show the whole row, `margin` clear of the edges, or its start when it is taller.
    func reveal(_ id: String, margin: CGFloat) {
        guard let row = indexByID[id] else { return }
        measureForJump(around: row)
        let edges = frameEdges(ofRow: row)
        guard let top = TimelineMessageFocus.revealTop(top: edges.top, bottom: edges.bottom, frameHeight: frameHeight, margin: margin) else { return }
        adjust { place(row: row, top: TimelineScrollPolicy.reachableTop(top, rowHeight: edges.bottom - edges.top, frameHeight: frameHeight)) }
    }

    /// The rows a jump lands among, measured now: a row's place depends on the heights of every row below it, and an
    /// estimate there would put the target off.
    private func measureForJump(around row: Int) {
        var changed = IndexSet()
        let upper = min(entries.count - 1, row + 30)
        guard upper >= 0 else { return }
        for index in 0...upper {
            guard case .message(let message) = entries[index], !isCurrent(message.message.id) else { continue }
            let old = layouts[message.message.id]
            let layout = mainMeasurer.layout(input(message), tableWidth: width, previous: old)
            store(layout, width: width)
            if old?.height != layout.height { changed.insert(index) }
        }
        guard !changed.isEmpty else { return }
        noteHeights(of: changed)
        reconfigure(changed)
    }

    /// The newest message's row: above the filler and the typing bubble.
    private var firstMessageRow: Int { entries.count > 1 && entries[1].id == TimelineItems.typingID ? 2 : 1 }

    private func isMessage(_ row: Int) -> Bool {
        if case .message = entries[row] { true } else { false }
    }

    func noteReaderMoved() {
        followsEnd = distanceFromBottom < TimelineScrollPolicy.nearBottomDistance
    }

    // MARK: Content

    private func entries(_ content: MacTimelineContent) -> [Entry] {
        [.filler] + (content.typing.map { [.typing($0)] } ?? []) + content.rows.reversed().map(Entry.message) + (content.loadingEarlier ? [.loading] : [])
    }

    private func reindex() {
        indexByID = Dictionary(entries.enumerated().map { ($1.id, $0) }, uniquingKeysWith: { first, _ in first })
    }

    private func store(_ layout: MacRowLayout, width: CGFloat) {
        layouts[layout.key.id] = layout
        layoutWidths[layout.key.id] = width
    }

    /// Whether a message's record is the one to show at the current width.
    private func isCurrent(_ id: String) -> Bool {
        guard let layout = layouts[id] else { return false }
        return layoutWidths[id] == width && !layout.provisional && layout.key.revision == revisions[id] ?? 0
    }

    private func input(_ row: TimelineRow) -> MacRowInput {
        let id = row.message.id
        let revision = revisions[id] ?? 0
        if let input = inputs[id], input.revision == revision { return input }
        let input = MacBubbleTextBuilder.input(row, revision: revision, isGroup: isGroup, accent: context.accent, body: MacTimelineMetrics.shared.body)
        inputs[id] = input
        return input
    }

    /// Bumps the revision of each message whose row changed since `old`.
    private func noteChanges(from old: [Entry], to new: [Entry]) -> [String] {
        var previous: [String: TimelineRow] = [:]
        for entry in old { if case .message(let row) = entry { previous[row.message.id] = row } }
        var changed: [String] = []
        for entry in new {
            guard case .message(let row) = entry, let before = previous[row.message.id], before != row else { continue }
            revisionCounter += 1
            revisions[row.message.id] = revisionCounter
            changed.append(row.message.id)
        }
        return changed
    }

    /// A new accent recolours every bubble: each message's input is built again; no height changes.
    func setAccent(_ accent: AccentTheme) {
        guard accent != context.accent else { return }
        context.accent = accent
        for entry in entries {
            guard case .message(let row) = entry else { continue }
            revisionCounter += 1
            revisions[row.message.id] = revisionCounter
        }
        guard isViewLoaded, pendingReload == nil else { return }
        reloadAll(at: readerPlace())
    }

    /// The whole table again: a chat opening, a filter changing what it lists, or a change that is no insertion or
    /// removal of rows in order. The rows around where the reader lands are measured here, the rest on the queue.
    func reload(_ content: MacTimelineContent, at place: MacTimelinePlace) {
        let next = entries(content)
        _ = noteChanges(from: entries, to: next)
        isGroup = content.isGroup
        entries = next
        reindex()
        guard isViewLoaded, table.bounds.width > 0 else {
            pendingReload = place
            return
        }
        reloadAll(at: place)
    }

    private func reloadAll(at target: MacTimelinePlace) {
        #if DEBUG
        let perfStart = MacPerfProbe.clock()
        defer { MacPerfProbe.add("table.reload", since: perfStart) }
        #endif
        generation = generations.bump()
        isApplying = false
        width = currentWidth
        layouts = layouts.filter { indexByID[$0.key] != nil }
        layoutWidths = layoutWidths.filter { indexByID[$0.key] != nil }
        // The first screenful here, from where the reader lands: the first frame shows real heights.
        var start = 0
        if case .row(let id, _) = target, let row = indexByID[id] { start = max(0, row - 20) }
        let viewport = max(scrollView.contentSize.height, 400) + 400
        var filled: CGFloat = 0
        var index = start
        while index < entries.count, filled < viewport || index <= start + 20 {
            if case .message(let row) = entries[index] {
                if !isCurrent(row.message.id) { store(mainMeasurer.layout(input(row), tableWidth: width, previous: layouts[row.message.id]), width: width) }
                filled += layouts[row.message.id]?.height ?? 0
            }
            index += 1
        }
        adjusting = true
        table.reloadData()
        updateFiller()
        switch target {
        case .newest:
            scroll(toDistanceFromBottom: 0)
            followsEnd = true
        case .row(let id, let top):
            if let row = indexByID[id] {
                // Its place depends on the height of every row below it.
                measureForJump(around: row)
                place(row: row, top: top)
                followsEnd = distanceFromBottom < TimelineScrollPolicy.nearBottomDistance
            } else {
                scroll(toDistanceFromBottom: 0)
                followsEnd = true
            }
        }
        adjusting = false
        noteRestingPlace()
        clipBoundsChanged()
        measureRest()
    }

    /// Every row without a current record, on the queue, in batches applied as they land.
    private func measureRest() {
        let pending = entries.compactMap { entry -> (row: TimelineRow, revision: Int)? in
            guard case .message(let row) = entry, !isCurrent(row.message.id) else { return nil }
            return (row, revisions[row.message.id] ?? 0)
        }
        guard !pending.isEmpty else { return }
        let isGroup = isGroup, accent = context.accent
        nonisolated(unsafe) let body = MacTimelineMetrics.shared.body
        let generation = generation, generations = generations, width = width, measurer = queueMeasurer
        let previous = layouts
        measurer.queue.async {
            var offset = 0
            while offset < pending.count, generations.current == generation {
                let slice = pending[offset..<min(pending.count, offset + 150)]
                let results = slice.map { item in
                    let input = MacBubbleTextBuilder.input(item.row, revision: item.revision, isGroup: isGroup, accent: accent, body: body)
                    return measurer.layout(input, tableWidth: width, previous: previous[input.id])
                }
                DispatchQueue.main.async {
                    MainActor.assumeIsolated { self.land(results, generation: generation) }
                }
                offset += 150
            }
        }
    }

    /// Records measured off the main thread: kept when still current, their rows' heights noted in one go.
    private func land(_ results: [MacRowLayout], generation: Int) {
        guard generation == self.generation else { return }
        #if DEBUG
        let perfStart = MacPerfProbe.clock()
        defer { MacPerfProbe.add("table.land", since: perfStart) }
        #endif
        var changed = IndexSet()
        for layout in results {
            let id = layout.key.id
            guard let index = indexByID[id], revisions[id] ?? 0 == layout.key.revision else { continue }
            if inputs[id]?.revision != layout.input.revision { inputs[id] = layout.input }
            let old = layouts[id]
            // A record made on the main thread knows the extras' size; the queue's may only guess it.
            if let old, old.key == layout.key, !old.provisional {
                layoutWidths[id] = width
                continue
            }
            store(layout, width: width)
            if old?.height != layout.height { changed.insert(index) }
        }
        noteHeights(changed)
    }

    /// Heights changed: noted in one zero-duration update, the rows in sight kept where they are. During a scroll
    /// gesture, a change below the top of the screen waits for the gesture to end.
    private func noteHeights(_ indexes: IndexSet) {
        guard !indexes.isEmpty else { return }
        let top = NSMaxRange(table.rows(in: visibleFrame))
        if isLiveScrolling, let first = indexes.first, first < top {
            heldNotes.formUnion(indexes)
            return
        }
        let anchor = captureAnchor()
        noteHeights(of: indexes)
        reconfigure(indexes)
        updateFiller()
        #if DEBUG
        if MacDebugHooks.has("-haus-timeline-trace") {
            MacDebugHooks.log("timeline trace: heights noted \(Array(indexes.prefix(8))) anchor \(anchor?.id ?? "-") \(anchor?.offset ?? 0) now \(anchor.flatMap { indexByID[$0.id] }.map { table.rect(ofRow: $0).minY - clip.minY } ?? 0)")
        }
        #endif
        restore(anchor)
    }

    /// Notes new heights in a zero-duration update and has the table take them at once.
    private func noteHeights(of indexes: IndexSet) {
        NSAnimationContext.runAnimationGroup { context in
            context.duration = 0
            context.allowsImplicitAnimation = false
            table.noteHeightOfRows(withIndexesChanged: indexes)
        }
        cacheHeights(of: indexes)
    }

    /// The table estimates a noted row's height until something asks for that row's rect, and lays every row above
    /// it out on the estimate: a compensation worked out then would be off by the difference, and the rows would move
    /// again once the table took the real height.
    private func cacheHeights(of indexes: IndexSet) {
        for index in indexes where index < table.numberOfRows { _ = table.rect(ofRow: index) }
    }

    private func reconfigure(_ indexes: IndexSet) {
        for index in indexes where index < entries.count {
            guard case .message(let row) = entries[index], let layout = layouts[row.message.id],
                  let cell = table.view(atColumn: 0, row: index, makeIfNecessary: false) as? MacTimelineMessageCell else { continue }
            if cell.identifier != (layout.drawsWhole ? MacTimelineMessageCell.identifier : MacTimelineMessageCell.longIdentifier) {
                table.reloadData(forRowIndexes: IndexSet(integer: index), columnIndexes: IndexSet(integer: 0))
            } else {
                configure(cell, row: index, layout: layout, message: row.message)
            }
        }
    }

    // MARK: Filler

    private var fillerHeight: CGFloat = 1

    /// Sizes the filler to the room the rows leave in the frame: nothing once they fill it. A timeline of more than 60
    /// rows always does (no row is under 40 pt), so long ones never add their heights up.
    private func updateFiller() {
        var next: CGFloat = 1
        if entries.count <= 60 {
            let area = clip.height - scrollView.contentInsets.top - scrollView.contentInsets.bottom - 1
            let rows = (1..<max(1, entries.count)).reduce(CGFloat(0)) { $0 + tableView(table, heightOfRow: $1) }
            next = max(1, ceil(area - rows) + 1)
        }
        guard next != fillerHeight, !entries.isEmpty else { return }
        fillerHeight = next
        noteHeights(of: IndexSet(integer: 0))
    }

    // MARK: Updates

    /// A change of the model's content: rows inserted or removed in order, rows changed in place. The new and changed
    /// rows are measured first (a few here, more on the queue), then applied in one update with the reader kept.
    func update(_ content: MacTimelineContent) {
        guard isViewLoaded, view.window != nil, timeline?.isLoaded == true, content.isLoaded else {
            timeline?.apply(content)
            reload(content, at: .newest)
            return
        }
        if isApplying {
            updateWaiting = true
            return
        }
        let old = entries
        let new = entries(content)
        let oldIDs = old.map(\.id), newIDs = new.map(\.id)
        let newSet = Set(newIDs), oldSet = Set(oldIDs)
        let removed = IndexSet(oldIDs.indices.filter { !newSet.contains(oldIDs[$0]) })
        let inserted = IndexSet(newIDs.indices.filter { !oldSet.contains(newIDs[$0]) })
        guard oldIDs.enumerated().filter({ !removed.contains($0.offset) }).map(\.element)
                == newIDs.enumerated().filter({ !inserted.contains($0.offset) }).map(\.element) else {
            // Reordered: the whole table again, the reader's row kept.
            let place = readerPlace()
            timeline?.apply(content)
            reload(content, at: place)
            return
        }
        var changedTyping = false
        if old.count > 1, new.count > 1, case .typing = old[1], case .typing = new[1], old[1] != new[1] { changedTyping = true }
        // A gesture keeps what it scrolls over: a change at or below the top of the screen waits for it to end.
        if isLiveScrolling {
            let top = NSMaxRange(table.rows(in: visibleFrame))
            let newByID = Dictionary(new.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
            let changedRows = old.indices.filter { index in
                guard case .message = old[index], let entry = newByID[old[index].id] else { return false }
                return entry != old[index]
            }
            let touched = (removed.first.map { [$0] } ?? []) + (inserted.first.map { [$0] } ?? []) + changedRows + (changedTyping ? [1] : [])
            if let lowest = touched.min(), lowest < top {
                heldUpdate = true
                return
            }
        }
        let changedIDs = noteChanges(from: old, to: new)
        let changedSet = Set(changedIDs)
        isGroup = content.isGroup
        let measure = new.enumerated().compactMap { index, entry -> TimelineRow? in
            guard case .message(let row) = entry, inserted.contains(index) || changedSet.contains(row.message.id) else { return nil }
            return row
        }
        let commit: ([MacRowLayout]) -> Void = { [weak self] results in
            self?.commit(content, entries: new, removed: removed, inserted: inserted, changedIDs: changedIDs, changedTyping: changedTyping, results: results)
        }
        if measure.count <= 30 {
            #if DEBUG
            MacPerfProbe.beginUpdate(from: old.count, to: new.count)
            #endif
            commit(measure.map { mainMeasurer.layout(input($0), tableWidth: width) })
            return
        }
        // Many rows (an older page): measured on the queue, and applied when they land.
        isApplying = true
        pendingCommit = commit
        let inputs = measure.map(input)
        let width = width, measurer = queueMeasurer, generation = generation, generations = generations
        let counts = (old.count, new.count)
        measurer.queue.async {
            let results = inputs.map { measurer.layout($0, tableWidth: width) }
            DispatchQueue.main.async {
                MainActor.assumeIsolated {
                    let commit = self.pendingCommit
                    self.pendingCommit = nil
                    guard generations.current == generation, self.isApplying, let commit else {
                        self.isApplying = false
                        self.timeline?.update()
                        return
                    }
                    #if DEBUG
                    MacPerfProbe.beginUpdate(from: counts.0, to: counts.1)
                    #endif
                    commit(results)
                }
            }
        }
    }

    /// Applies a measured change in one table update, then places the reader: at the newest message when the policy
    /// follows it, else with the rows in sight exactly where they were.
    private func commit(_ content: MacTimelineContent, entries next: [Entry], removed: IndexSet, inserted: IndexSet, changedIDs: [String],
                        changedTyping: Bool, results: [MacRowLayout]) {
        isApplying = false
        defer {
            #if DEBUG
            MacPerfProbe.endUpdate()
            #endif
            if updateWaiting {
                updateWaiting = false
                timeline?.update()
            }
        }
        let wasNearBottom = followsEnd || distanceFromBottom < TimelineScrollPolicy.nearBottomDistance
        let placement = timeline?.placement(for: content, wasNearBottom: wasNearBottom) ?? .keepAnchor
        #if DEBUG
        let reader = readerRow()
        #endif
        let anchor = captureAnchor()
        let measuredWidth = width
        for layout in results { store(layout, width: measuredWidth) }
        timeline?.apply(content)
        entries = next
        reindex()
        #if DEBUG
        MacPerfProbe.mark("measure")
        #endif
        adjusting = true
        let changed = IndexSet(changedIDs.compactMap { indexByID[$0] } + (changedTyping ? [1] : []))
        NSAnimationContext.runAnimationGroup { context in
            context.duration = 0
            context.allowsImplicitAnimation = false
            table.beginUpdates()
            if !removed.isEmpty { table.removeRows(at: removed, withAnimation: []) }
            if !inserted.isEmpty { table.insertRows(at: inserted, withAnimation: []) }
            if !changed.isEmpty { table.reloadData(forRowIndexes: changed, columnIndexes: IndexSet(integer: 0)) }
            table.endUpdates()
        }
        // The changed and inserted rows' heights, taken now (`cacheHeights`), before the compensation is worked out.
        noteHeights(of: changed.union(inserted))
        updateFiller()
        #if DEBUG
        MacPerfProbe.mark("apply")
        #endif
        switch placement {
        case .newestAtOnce, .slideToNewest, .followNewest:
            scroll(toDistanceFromBottom: 0)
            followsEnd = true
        case .keepAnchor:
            // One exact compensation: the lowest row in sight back where it was.
            if let anchor, let row = indexByID[anchor.id] { scroll(toY: table.rect(ofRow: row).minY - anchor.offset) }
        }
        adjusting = false
        noteRestingPlace()
        clipBoundsChanged()
        #if DEBUG
        if case .keepAnchor = placement, let reader { MacTimelineDebug.held(reader, by: self) }
        #endif
    }

    // MARK: Width

    private var currentWidth: CGFloat { table.bounds.width > 0 ? table.bounds.width : max(1, scrollView.contentSize.width) }

    /// The table's frame changes in the middle of a resize chain (window, hosting view, scroll view, clip view, table,
    /// column), and noting heights there re-enters it: the table sizes itself to its column, which has the old width
    /// still. The new width is taken once the chain is done: in this view's layout, or in a run-loop block before the
    /// frame commits.
    @objc private func tableFrameChanged() {
        guard !widthPending else { return }
        widthPending = true
        RunLoop.main.perform(inModes: [.common]) { [weak self] in
            MainActor.assumeIsolated { self?.applyWidth() }
        }
    }

    private func applyWidth() {
        widthPending = false
        let next = table.bounds.width
        guard next > 0, abs(next - width) >= 0.5 else { return }
        widthChanged(to: next)
    }

    /// A new width: the rows in sight measured again now, the rest once the resize ends. Above the bubble cap every
    /// record's key holds and nothing changes.
    private func widthChanged(to next: CGFloat) {
        #if DEBUG
        let perfStart = MacPerfProbe.clock()
        defer { MacPerfProbe.add("table.width", since: perfStart) }
        #endif
        width = next
        generation = generations.bump()
        hostedHeights.removeAll()
        let visible = table.rows(in: clip)
        var heights = IndexSet(), keys = IndexSet()
        for index in visible.location..<min(entries.count, NSMaxRange(visible)) {
            switch entries[index] {
            case .message(let row):
                let id = row.message.id
                let old = layouts[id]
                let layout = mainMeasurer.layout(input(row), tableWidth: next, previous: old)
                layoutWidths[id] = next
                guard layout.key != old?.key || layout.provisional != old?.provisional else { continue }
                store(layout, width: next)
                keys.insert(index)
                if old?.height != layout.height { heights.insert(index) }
            case .typing, .loading:
                heights.insert(index)
            case .filler:
                break
            }
        }
        if !heights.isEmpty {
            // Bottom-anchored: the lowest row in sight stays, the rows above it move.
            noteHeights(of: heights)
        }
        reconfigure(keys)
        updateFiller()
        keepPlace()
        if !view.inLiveResize { scheduleEndPass() }
    }

    private func liveResizeEnded() {
        endPass?.cancel()
        endPass = nil
        measureRest()
    }

    /// A width that keeps changing outside a live resize (the sidebar's animation) measures every row once, when it
    /// settles.
    private func scheduleEndPass() {
        endPass?.cancel()
        let work = DispatchWorkItem { [weak self] in MainActor.assumeIsolated { self?.measureRest() } }
        endPass = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.15, execute: work)
    }

    // MARK: Scrolling

    @objc private func liveScrollStarted() {
        isLiveScrolling = true
        updateHover(outside: true)
    }

    @objc private func liveScrollEnded() {
        isLiveScrolling = false
        noteRestingPlace()
        timeline?.scrollEnded()
        if !heldNotes.isEmpty {
            let notes = heldNotes
            heldNotes = IndexSet()
            noteHeights(notes)
        }
        if heldUpdate {
            heldUpdate = false
            timeline?.update()
        }
        updateHover()
    }

    /// The event being handled moves the scroll view: a scroll wheel, which may report no phase (a mouse's notched
    /// wheel), or a click or drag on the scroller.
    private static var scrollInput: Bool {
        guard let event = NSApp.currentEvent, ProcessInfo.processInfo.systemUptime - event.timestamp < 0.1 else { return false }
        switch event.type {
        case .scrollWheel: return true
        case .leftMouseDown, .leftMouseDragged: return event.window?.contentView?.hitTest(event.locationInWindow) is NSScroller
        default: return false
        }
    }

    /// Every scrolled frame: whether the reader follows the newest message, the jump button, paging, the day chip and
    /// the rows in sight, in constant time.
    @objc private func clipBoundsChanged() {
        #if DEBUG
        if MacDebugHooks.has("-haus-timeline-trace") {
            MacDebugHooks.log(String(format: "timeline trace: clip y %.1f height %.1f, follows %d, adjusting %d, live scroll %d, document %.0f",
                                     clip.minY, clip.height, followsEnd ? 1 : 0, adjusting ? 1 : 0, isLiveScrolling ? 1 : 0, table.bounds.height))
        }
        #endif
        #if DEBUG
        let perfStart = MacPerfProbe.clock()
        defer { MacPerfProbe.add("table.scrolled", since: perfStart) }
        let debugScrolling = debugReaderScrolling
        #else
        let debugScrolling = false
        #endif
        guard let timeline else { return }
        let distance = distanceFromBottom
        let byReader = !adjusting && (isLiveScrolling || Self.scrollInput || debugScrolling)
        if byReader {
            followsEnd = distance < TimelineScrollPolicy.nearBottomDistance
            if !isLiveScrolling { noteRestingPlace() }
        }
        // The frame's new size (the window, the sidebar): the reader stays where they were.
        if clip.size != clipSize {
            let first = clipSize == .zero
            clipSize = clip.size
            if !first, !adjusting { keepPlace() }
        }
        timeline.setShowsJumpToNewest(!followsEnd && TimelineScrollPolicy.showsJumpToNewest(distanceFromBottom: distance, viewportHeight: frameHeight))
        timeline.scrolled(byReader: byReader, moving: byReader || timeline.readerIsScrolling)
        updateShown()
        if !isLiveScrolling { updateHover() }
    }

    /// The messages in sight now: those coming in are reported once, as they would appear.
    private func updateShown() {
        let range = table.rows(in: visibleFrame)
        var now = Set<String>()
        var appeared: [TimelineMessage] = []
        for row in range.location..<min(entries.count, NSMaxRange(range)) {
            guard case .message(let message) = entries[row] else { continue }
            now.insert(message.message.id)
            if !shownIDs.contains(message.message.id) { appeared.append(message.message) }
        }
        let gone = shownIDs.subtracting(now)
        shownIDs = now
        // Oldest first, as rows appear in a list.
        for message in appeared.reversed() { timeline?.onShown(message) }
        for id in gone { timeline?.onHidden(id) }
    }

    var visibleMessageIDs: Set<String> { shownIDs }

    // MARK: Hover

    /// The bubble under the pointer shows its toolbar and its text's cursor; nothing hovers while a gesture scrolls.
    func updateHover(outside: Bool = false) {
        var cell: MacTimelineMessageCell?
        if !outside, !isLiveScrolling, let window = view.window {
            let point = table.convert(window.mouseLocationOutsideOfEventStream, from: nil)
            if table.visibleRect.contains(point), visibleFrame.contains(point) {
                let row = table.row(at: point)
                if row >= 0 { cell = table.view(atColumn: 0, row: row, makeIfNecessary: false) as? MacTimelineMessageCell }
            }
        }
        guard cell !== hovered else { return }
        hovered?.hovering = false
        hovered = cell
        cell?.hovering = true
    }

    // MARK: Keyboard

    private func firstResponderChanged(_ responder: NSResponder?) {
        let inTable = responder === table || (responder as? NSView)?.isDescendant(of: table) == true
        let tableFocused = responder === table
        let ringChanged = tableFocused != tableHasFocus
        tableHasFocus = tableFocused
        if timeline?.hasKeyboardFocus != inTable || tableFocused && ringChanged {
            timeline?.keyboardFocusChanged(inTable, byKey: tableFocused && NSApp.currentEvent?.type == .keyDown)
        } else if ringChanged {
            focusChanged()
        }
    }

    func takeKeyboardFocus() {
        view.window?.makeFirstResponder(table)
    }

    /// The focus ring follows the focused message while the table itself has keyboard focus.
    func focusChanged() {
        let ringID = tableHasFocus ? timeline?.focusedID : nil
        table.enumerateAvailableRowViews { rowView, _ in
            guard let cell = rowView.view(atColumn: 0) as? MacTimelineMessageCell else { return }
            cell.showsFocusRing = cell.message?.id == ringID && ringID != nil
        }
    }

    func highlightChanged() {
        let id = timeline?.highlightedID
        table.enumerateAvailableRowViews { rowView, _ in
            guard let cell = rowView.view(atColumn: 0) as? MacTimelineMessageCell else { return }
            cell.highlighted = cell.message?.id == id && id != nil
        }
    }

    /// The timeline's keys, from the table: the scrolling keys, ↑ and ↓ between messages, Return or Space for the
    /// focused message's menu, Esc to the composer and Tab on to it.
    func handleKey(_ event: NSEvent) -> Bool {
        guard let timeline else { return false }
        // Arrow keys also carry the numeric pad and function flags; only these four tell the keys apart.
        let modifiers = event.modifierFlags.intersection([.command, .shift, .option, .control])
        let plain = modifiers.isEmpty
        switch Int(event.keyCode) {
        case 116: timeline.scroll(.pageUp)
        case 121: timeline.scroll(.pageDown)
        case 115: timeline.scroll(.top)
        case 119: timeline.scroll(.bottom)
        case 126 where modifiers == .command: timeline.scroll(.top)
        case 125 where modifiers == .command: timeline.scroll(.bottom)
        case 126 where plain: timeline.moveFocus(forward: false)
        case 125 where plain: timeline.moveFocus(forward: true)
        case 36 where plain, 76 where plain, 49 where plain: return timeline.openFocusedMenu()
        case 53: timeline.onEscape()
        case 48 where plain: timeline.onTab()
        case 48 where modifiers == .shift: view.window?.selectPreviousKeyView(table)
        default: return false
        }
        return true
    }

    /// The focused message's menu, below its bubble's leading corner as a menu opened from a control hangs below it:
    /// the bubble's own, followed by what a click on the bubble does, which a keyboard cannot otherwise reach.
    func openMenu(for id: String) {
        guard let row = indexByID[id], let cell = table.view(atColumn: 0, row: row, makeIfNecessary: true) as? MacTimelineMessageCell else { return }
        let menu = cell.keyboardMenu()
        #if DEBUG
        // A menu runs its own event loop, which nothing ends in a scripted run: the tour reads it instead.
        if MacUnobtrusive.isOn {
            MacDebugHooks.log("keyboard menu \(id): " + MacKeyboardMenuItems.titles(of: menu))
            return
        }
        #endif
        let bubble = cell.bubbleFrame
        menu.popUp(positioning: nil, at: NSPoint(x: bubble.minX, y: bubble.maxY + 4), in: cell)
    }

    @objc private func rowClicked() {
        let row = table.clickedRow
        guard context.isFiltered, row >= 0, row < entries.count, case .message(let message) = entries[row] else { return }
        timeline?.scrollTo(messageID: message.message.id)
    }

    // MARK: Accessibility

    private(set) lazy var rotors: [NSAccessibilityCustomRotor] = [
        NSAccessibilityCustomRotor(label: "Messages", itemSearchDelegate: self),
        NSAccessibilityCustomRotor(rotorType: .link, itemSearchDelegate: self),
        NSAccessibilityCustomRotor(label: "Starred Messages", itemSearchDelegate: self),
    ]

    /// The rotors' entries, oldest first: every message, every link in them (titled as the row's actions title them),
    /// or the starred messages. Each resolves to its message's element when VoiceOver moves to it, which scrolls it in.
    private func rotorEntries(_ rotor: NSAccessibilityCustomRotor) -> [(token: String, label: String)] {
        guard let timeline else { return [] }
        let messages = timeline.rows.map(\.message)
        let contactName = context.contactName
        if rotor.type == .link {
            return messages.flatMap { message in
                message.links.enumerated().map { ("\(message.id)\u{0}\($0.offset)", MessageActionMenu.linkAccessibilityTitle(for: $0.element)) }
            }
        }
        let listed = rotor.label == "Starred Messages" ? messages.filter(\.isStarred) : messages
        return listed.map { ($0.id, MacTimelineRotorLabel.label(for: $0, contactName: contactName)) }
    }

    func rotor(_ rotor: NSAccessibilityCustomRotor, resultFor searchParameters: NSAccessibilityCustomRotor.SearchParameters) -> NSAccessibilityCustomRotor.ItemResult? {
        let entries = rotorEntries(rotor)
        guard !entries.isEmpty else { return nil }
        let current = (searchParameters.currentItem?.itemLoadingToken as? String).flatMap { token in entries.firstIndex { $0.token == token } }
        let index: Int
        switch (searchParameters.searchDirection, current) {
        case (.previous, let current?): index = current - 1
        case (.previous, nil): index = entries.count - 1
        case (_, let current?): index = current + 1
        case (_, nil): index = 0
        }
        guard entries.indices.contains(index) else { return nil }
        return NSAccessibilityCustomRotor.ItemResult(itemLoadingToken: entries[index].token as NSString, customLabel: entries[index].label)
    }

    /// The element of the message a rotor entry names, scrolled into view.
    func element(for token: String) -> MacTimelineMessageElement? {
        let id = String(token.split(separator: "\u{0}", maxSplits: 1).first ?? "")
        guard indexByID[id] != nil else { return nil }
        reveal(id, margin: MacTimelineController.focusMargin)
        guard let row = indexByID[id], let cell = table.view(atColumn: 0, row: row, makeIfNecessary: true) as? MacTimelineMessageCell else { return nil }
        return cell.element
    }

    // MARK: Table

    func numberOfRows(in tableView: NSTableView) -> Int { entries.count }

    func tableView(_ tableView: NSTableView, heightOfRow row: Int) -> CGFloat {
        guard row < entries.count else { return 1 }
        switch entries[row] {
        case .message(let message): return layouts[message.message.id]?.height ?? estimate(message)
        case .typing(let typing): return hostedHeight(typing.accessibilityLabel + (typing.author ?? ""), MacTypingRow(typing: typing))
        case .loading: return hostedHeight("loading", MacLoadingEarlierRow())
        case .filler: return fillerHeight
        }
    }

    /// A rough height for a row not measured yet; only rows above the reader are ever unmeasured.
    private func estimate(_ row: TimelineRow) -> CGFloat {
        let textWidth = max(96, MacTimelineMetrics.cap(contentWidth: max(1, width - 32)) - 24)
        let lines = max(1, ceil(CGFloat(row.message.body.count) * 7 / textWidth)) + CGFloat(row.message.body.filter(\.isNewline).count)
        let extras: CGFloat = MacBubbleTextBuilder.extras(row.message)?.estimate ?? 0
        return 2 + (row.dateHeader == nil ? 0 : 46) + (row.startsRun ? 6 : 0) + 8 + extras + lines * 16 + 4 + 13 + 6 + (row.message.reactions.isEmpty ? 0 : 19)
    }

    private func hostedHeight(_ key: String, _ view: some View) -> CGFloat {
        if let height = hostedHeights[key] { return height }
        hostedSizer.rootView = AnyView(view.frame(width: max(1, width)))
        let height = max(1, ceil(hostedSizer.sizeThatFits(in: CGSize(width: max(1, width), height: .greatestFiniteMagnitude)).height))
        hostedHeights[key] = height
        return height
    }

    func tableView(_ tableView: NSTableView, rowViewForRow row: Int) -> NSTableRowView? {
        tableView.makeView(withIdentifier: MacTimelineRowView.identifier, owner: nil) as? MacTimelineRowView ?? {
            let view = MacTimelineRowView()
            view.identifier = MacTimelineRowView.identifier
            return view
        }()
    }

    func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
        guard row < entries.count else { return nil }
        switch entries[row] {
        case .typing(let typing):
            return hostedCell(AnyView(MacTypingRow(typing: typing)))
        case .loading:
            return hostedCell(AnyView(MacLoadingEarlierRow()))
        case .filler:
            return nil
        case .message(let message):
            #if DEBUG
            let perfStart = MacPerfProbe.clock()
            defer { MacPerfProbe.add("cell.configure", since: perfStart) }
            #endif
            let id = message.message.id
            var layout = layouts[id]
            let input = input(message)
            if !isCurrent(id) {
                // Unmeasured (or measured at another width, or with a guess for its extras) and about to show: measured
                // here; its height is noted in the next turn, the rows in sight kept.
                let measured = mainMeasurer.layout(input, tableWidth: width, previous: layout)
                let moved = measured.height != (layout?.height ?? estimate(message))
                store(measured, width: width)
                layout = measured
                if moved {
                    DispatchQueue.main.async {
                        MainActor.assumeIsolated {
                            guard let index = self.indexByID[id] else { return }
                            self.noteHeights(IndexSet(integer: index))
                        }
                    }
                }
            }
            guard let layout else { return nil }
            let identifier = layout.drawsWhole ? MacTimelineMessageCell.identifier : MacTimelineMessageCell.longIdentifier
            let cell = tableView.makeView(withIdentifier: identifier, owner: nil) as? MacTimelineMessageCell
                ?? MacTimelineMessageCell(drawsWhole: layout.drawsWhole, context: context)
            configure(cell, row: row, layout: layout, message: message.message)
            return cell
        }
    }

    private func configure(_ cell: MacTimelineMessageCell, row: Int, layout: MacRowLayout, message: TimelineMessage) {
        cell.configure(layout, message: message)
        cell.highlighted = timeline?.highlightedID == message.id
        cell.showsFocusRing = tableHasFocus && timeline?.focusedID == message.id
        if cell === hovered, hovered?.message?.id != message.id { cell.hovering = false }
        #if DEBUG
        cell.updateToolbarVisibility()
        #endif
    }

    private func hostedCell(_ view: AnyView) -> NSView {
        let cell = table.makeView(withIdentifier: MacTimelineHostedCell.identifier, owner: nil) as? MacTimelineHostedCell ?? MacTimelineHostedCell()
        cell.show(view)
        return cell
    }

    func tableView(_ tableView: NSTableView, shouldSelectRow row: Int) -> Bool { false }

    func tableView(_ tableView: NSTableView, didRemove rowView: NSTableRowView, forRow row: Int) {
        guard let cell = rowView.view(atColumn: 0) as? MacTimelineMessageCell, cell === hovered else { return }
        hovered = nil
        cell.hovering = false
    }

    // MARK: Debug

    #if DEBUG
    /// The table's state for the tour's reports.
    var debugReport: String {
        String(format: "from bottom %.1f, frame %.1f, top inset %.1f, bottom inset %.1f, clip y %.1f, document %.1f, width %.0f",
               distanceFromBottom, frameHeight, bars.top, bars.bottom, clip.minY, table.bounds.height, width)
    }

    /// The frame-relative top of a message's row, for the drift checks.
    func debugTop(of id: String) -> CGFloat? {
        indexByID[id].map { frameEdges(ofRow: $0).top }
    }

    /// A row's record height, its height in the table, and the rows below it.
    func debugHeights(of id: String) -> String {
        guard let row = indexByID[id] else { return "\(id) not listed" }
        // The filler's and the typing bubble's ids end in a NUL, which a log must not carry.
        let below = (0..<row).map { "\(entries[$0].id.replacingOccurrences(of: "\u{0}", with: "").prefix(14)) \(table.rect(ofRow: $0).height)/\(layouts[entries[$0].id]?.height ?? -1)" }
        let differing = entries.indices.compactMap { index -> String? in
            guard case .message(let message) = entries[index], let record = layouts[message.message.id] else { return nil }
            let height = table.rect(ofRow: index).height
            return abs(height - record.height) > 0.1 ? "\(message.message.id) \(height)/\(record.height)" : nil
        }
        return "\(id) row \(row) record \(layouts[id]?.height ?? -1) table \(table.rect(ofRow: row).height); below: \(below.joined(separator: ", ")); differing: \(differing.joined(separator: ", "))"
    }

    /// The tour's row steps (`select-text`, `pick-emoji`) on a message in sight.
    func debugRequest(_ verb: String, messageID: String) {
        guard let row = indexByID[messageID] else { return MacDebugHooks.log("tour \(verb): \(messageID) is not listed") }
        reveal(messageID, margin: MacTimelineController.focusMargin)
        (table.view(atColumn: 0, row: row, makeIfNecessary: true) as? MacTimelineMessageCell)?.debugRequest(verb)
    }

    /// The tour's `hover <id>|off`: each cell in sight shows its toolbar as the pointer would.
    func debugHoverChanged() {
        table.enumerateAvailableRowViews { rowView, _ in
            (rowView.view(atColumn: 0) as? MacTimelineMessageCell)?.updateToolbarVisibility()
        }
    }

    /// The row records' agreement with what a live bubble text view lays out, at the current width.
    func debugMismatch() -> String {
        var worst: CGFloat = 0, rows = 0, failures: [String] = []
        for entry in entries {
            guard case .message(let row) = entry, let layout = layouts[row.message.id], let frame = layout.textFrame else { continue }
            let live = BubbleTextView.make(layout.input.text, drawsWhole: layout.drawsWhole)
            live.frame = NSRect(x: 0, y: 0, width: frame.width, height: frame.height)
            guard let manager = live.layoutManager, let container = live.textContainer else { continue }
            manager.ensureLayout(for: container)
            let height = ceil(manager.usedRect(for: container).height)
            let delta = abs(height - frame.height)
            worst = max(worst, delta)
            rows += 1
            if delta > 0.5, failures.count < 5 { failures.append("\(row.message.id) \(frame.height) vs \(height)") }
        }
        return "\(rows) texts, worst \(worst) pt" + (failures.isEmpty ? "" : ", off: " + failures.joined(separator: "; "))
    }
    #endif
}

/// The rotors' entry for a message: who and what, then the time, short enough for the rotor's list.
enum MacTimelineRotorLabel {
    static func label(for message: TimelineMessage, contactName: String?) -> String {
        let speaker = message.isOutgoing ? "You" : message.senderName(contactName: contactName) ?? "Contact"
        let content = message.displayedText.isEmpty ? message.attachment.map { "\($0.kindLabel) \($0.name)" } ?? "" : message.displayedText
        let time = message.sentAt?.formatted(date: .omitted, time: .shortened)
        return [content.isEmpty ? speaker : "\(speaker): \(content)", time].compactMap { $0 }.joined(separator: ", ")
    }
}
