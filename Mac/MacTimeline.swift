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
        ZStack {
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
        // Only its coming and going; it follows the rows unanimated.
        .animation(.easeOut(duration: controller.dayChipFade), value: controller.dayChip != nil)
    }
}

/// Back to the newest message, while the reader is well above it.
private struct MacJumpToNewest: View {
    let controller: MacTimelineController
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        ZStack {
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
        .animation(.easeOut(duration: 0.2), value: controller.showsJumpToNewest)
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

/// The timeline's scroller, whose knob eases to its new length and place when the content's height changes under it
/// (an older page coming in above the reader, heights landing from the queue, an arrival) instead of jumping there.
/// The easing is an offset from where the scroll view puts the knob, fading to nothing over a fraction of a second, so
/// the reader's own scrolling moves the knob at once, as always, during it too. A change counts when the knob's length
/// changes: scrolling alone never changes it. A click or drag on the scroller, a live resize, Reduce Motion and a
/// hidden scroller show the knob where it is at once; the display link runs only while an easing does.
final class MacTimelineScroller: NSScroller {
    private static let duration: CFTimeInterval = 0.3

    override class var isCompatibleWithOverlayScrollers: Bool { self == MacTimelineScroller.self }

    /// Where the scroll view puts the knob.
    private var value: Double = 0
    private var proportion: CGFloat = 0
    /// Where the knob showed against that when the easing started.
    private var valueOffset: Double = 0
    private var proportionOffset: CGFloat = 0
    /// Where the knob showed before the scroll view's latest move of it: the scroll view moves it, then sets its length.
    private var valueBefore: Double = 0
    private var started: CFTimeInterval = 0
    /// The easing started in this turn of the run loop.
    private var starting = false
    private var link: CADisplayLink?
    private var tracking = false

    override var doubleValue: Double {
        get { super.doubleValue }
        set {
            valueBefore = super.doubleValue
            // The timeline putting the reader's row back after the change that started the easing, in the same turn
            // (an arrival below them, heights changing under them): part of that change, so the knob eases from where
            // it showed before it rather than jumping by the correction first.
            if starting { valueOffset = valueBefore - newValue }
            value = newValue
            show()
        }
    }

    override var knobProportion: CGFloat {
        get { super.knobProportion }
        set {
            let shown = super.knobProportion
            let changed = proportion > 0 && abs(newValue - proportion) > 0.0001
            proportion = newValue
            if changed, eases {
                valueOffset = valueBefore - value
                proportionOffset = shown - newValue
                started = CACurrentMediaTime()
                if !starting {
                    starting = true
                    RunLoop.main.perform(inModes: [.common]) { [weak self] in
                        MainActor.assumeIsolated { self?.starting = false }
                    }
                }
                if link == nil {
                    let link = displayLink(target: self, selector: #selector(step))
                    link.add(to: .main, forMode: .common)
                    self.link = link
                }
            } else if changed {
                // An easing under way stops too, rather than carrying its offset onto the new geometry.
                stop()
            }
            show()
        }
    }

    /// Not off every screen either, nor hidden, where the display link never fires and the knob would wait mid-way.
    private var eases: Bool {
        guard !tracking, !isHiddenOrHasHiddenAncestor, let window, window.screen != nil, !window.inLiveResize else { return false }
        return !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
    }

    /// How much of the offset is left: an ease-out over the duration.
    private var remaining: Double {
        guard link != nil else { return 0 }
        let progress = (CACurrentMediaTime() - started) / Self.duration
        return progress >= 1 ? 0 : pow(1 - progress, 3)
    }

    private func show() {
        let remaining = remaining
        super.doubleValue = min(1, max(0, value + valueOffset * remaining))
        super.knobProportion = min(1, max(0, proportion + proportionOffset * CGFloat(remaining)))
    }

    @objc private func step(_ link: CADisplayLink) {
        if remaining == 0 { settle() } else { show() }
    }

    /// The knob where the scroll view puts it, at once.
    private func settle() {
        stop()
        show()
    }

    private func stop() {
        link?.invalidate()
        link = nil
        starting = false
        valueOffset = 0
        proportionOffset = 0
    }

    /// A press is told apart against the knob as it shows, so one on the knob still easing drags it. The drag moves the
    /// content to where the scroller says, which is where the knob shows only once it is settled: it settles as the
    /// drag starts, then stays where the pointer puts it until the drag ends. Handed on whole to the scroller's own
    /// tracking, whose press calls `trackKnob` for the knob.
    override func mouseDown(with event: NSEvent) {
        whileTracking { super.mouseDown(with: event) }
    }

    override func trackKnob(with event: NSEvent) {
        settle()
        whileTracking { super.trackKnob(with: event) }
    }

    private func whileTracking(_ track: () -> Void) {
        let was = tracking
        tracking = true
        defer { tracking = was }
        track()
    }

    /// The slot with round ends, as the knob's: it stops below the toolbar and above the composer, mid-window, where
    /// square ends looked cut off.
    override func drawKnobSlot(in slotRect: NSRect, highlight flag: Bool) {
        let radius = slotRect.width / 2
        NSGraphicsContext.saveGraphicsState()
        NSBezierPath(roundedRect: slotRect, xRadius: radius, yRadius: radius).addClip()
        super.drawKnobSlot(in: slotRect, highlight: flag)
        NSGraphicsContext.restoreGraphicsState()
    }

    override func viewWillMove(toWindow newWindow: NSWindow?) {
        super.viewWillMove(toWindow: newWindow)
        if newWindow == nil { settle() }
    }

    /// Hidden (the scroll view hides it once everything fits), it has nothing to show an easing on, and its display
    /// link, which may not call again until it shows, would be kept.
    override func viewDidHide() {
        super.viewDidHide()
        settle()
    }
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
///   screenful, and the rows of a change that is cheap to measure, are measured on the main thread so the first frame
///   is right. The queue guesses the height of what SwiftUI draws (quotes, files, cards); the main thread measures
///   those before they scroll in (`measureAhead`). `heightOfRow` only looks a height up, or estimates one for a row
///   not measured yet. Every record is published in one step with its row's height (`publish`): a cell shows only the
///   record its row's height is from, or a newer one cut to it while that height waits for a gesture to end.
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
    /// Each message's revision, bumped when its row in `entries` changes; a record holds for one revision. An update
    /// measured on the queue keeps its rows' new revisions to itself until it applies (`commit`).
    private var revisions: [String: Int] = [:]
    private var revisionCounter = 0
    /// The published record per message, at some width: the one its cell shows and its row's height in the table is
    /// from. Changed only together with that height (`publish`, or a table update that takes it); rows not measured yet
    /// have none and an estimated height.
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
    /// An update whose rows the queue is measuring, not applied yet; a change that arrives meanwhile waits for it.
    private var pendingUpdate: PendingUpdate?
    private var updateTokens = 0
    var isApplying: Bool { pendingUpdate != nil }
    private var updateWaiting = false
    /// A change that would move the rows in sight arrived during a scroll gesture: it waits for the gesture to end.
    private var heldUpdate = false
    /// Records measured at the current width whose heights the table cannot take yet: they would move the rows in sight
    /// during a scroll gesture, or were made as the table asked for their rows' views. Published when that allows.
    private var staged: [String: MacRowLayout] = [:]
    private(set) var isLiveScrolling = false
    /// The messages whose published records guess their extras' height or stand in for a newer one: what `measureAhead`
    /// looks at.
    private var unsettled: Set<String> = []
    /// `measureAhead` is running (a height it notes scrolls, which asks for it again), or will in a later turn.
    private var measuringAhead = false
    private var measureAheadScheduled = false
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
    let replySwipe = MacReplySwipe()
    private var scrollMonitor: Any?
    private var resignObservers: [NSObjectProtocol] = []
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
        replySwipe.cellAt = { [weak self] point in self?.replySwipeCell(at: point) }
        replySwipe.mayStart = { [weak self] in self.map { !$0.isLiveScrolling && NSEvent.pressedMouseButtons == 0 } ?? false }
        replySwipe.ended = { [weak self] in self?.updateHover() }
    }

    required init?(coder: NSCoder) { fatalError("not used") }

    override func loadView() {
        let root = MacTimelineRootView()
        root.endedLiveResize = { [weak self] in self?.liveResizeEnded() }
        scrollView.contentView = MacTimelineClipView()
        scrollView.verticalScroller = MacTimelineScroller()
        scrollView.hasVerticalScroller = true
        scrollView.hasHorizontalScroller = false
        scrollView.autohidesScrollers = true
        scrollView.drawsBackground = true
        scrollView.backgroundColor = .textBackgroundColor
        scrollView.contentView.drawsBackground = true
        scrollView.contentView.backgroundColor = .textBackgroundColor
        scrollView.automaticallyAdjustsContentInsets = false
        // The scroller is inset by the content insets and then by these: it runs from the toolbar and the bars under
        // it down to the composer, the frame's whole height, without the margins kept inside the frame.
        let margin = MacTimelineController.topMargin
        scrollView.scrollerInsets = NSEdgeInsets(top: -margin, left: 0, bottom: -(margin - 1), right: 0)
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
        // The reply swipe sees the window's scroll events before the scroll view does: an override of `scrollWheel`
        // would cost the table its responsive scrolling.
        scrollMonitor = NSEvent.addLocalMonitorForEvents(matching: .scrollWheel) { [weak self] event in
            // A local monitor runs on the main thread, with the event being sent.
            nonisolated(unsafe) let scroll = event
            let keeps = MainActor.assumeIsolated { self?.scrollWheel(scroll) == true }
            return keeps ? nil : event
        }
        // A swipe whose end may never reach the table ends when the app, or the table's window, stops taking input
        // (Settings opening over it, say). The window is compared when it resigns, as the view may have moved since.
        resignObservers = [
            NotificationCenter.default.addObserver(forName: NSApplication.didResignActiveNotification, object: nil, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated { self?.replySwipe.cancel() }
            },
            NotificationCenter.default.addObserver(forName: NSWindow.didResignKeyNotification, object: nil, queue: .main) { [weak self] notification in
                nonisolated(unsafe) let window = notification.object as AnyObject?
                MainActor.assumeIsolated {
                    guard let self, let window, window === self.view.window else { return }
                    self.replySwipe.cancel()
                }
            },
        ]
    }

    override func viewDidDisappear() {
        super.viewDidDisappear()
        firstResponderObservation = nil
        if let scrollMonitor { NSEvent.removeMonitor(scrollMonitor) }
        scrollMonitor = nil
        resignObservers.forEach(NotificationCenter.default.removeObserver)
        resignObservers = []
        replySwipe.cancel()
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

    /// The rows a jump lands among, measured now, so the target lands where it is put: a frame's height of rows from it
    /// up, and below it a frame's height of rows, whose heights place it. What that costs is bounded by the text a frame
    /// shows, not by a count of rows. Rows further away without a current record are on the queue (or are guesses
    /// `measureAhead` takes), and the rows in sight are kept where they are when those land.
    private func measureForJump(around row: Int) {
        guard row < entries.count else { return }
        var measured: [MacRowLayout] = []
        func height(_ index: Int) -> CGFloat {
            guard case .message(let message) = entries[index] else { return tableView(table, heightOfRow: index) }
            let id = message.message.id
            guard !isCurrent(id) else { return layouts[id]?.height ?? 0 }
            let layout = mainMeasurer.layout(input(message), tableWidth: width, previous: staged[id] ?? layouts[id])
            measured.append(layout)
            return layout.height
        }
        var above: CGFloat = 0
        var index = row
        while index < entries.count, above < frameHeight {
            above += height(index)
            index += 1
        }
        var below: CGFloat = 0
        index = row - 1
        while index >= 0, below < frameHeight {
            below += height(index)
            index -= 1
        }
        // The jump places the reader itself.
        publish(measured, keepingRows: false)
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

    /// Makes `layout` its message's published record, at the current width. Only where the table takes its height in the
    /// same step: `publish`, a reload, an update's commit, or a stand-in of the height the row already has.
    private func store(_ layout: MacRowLayout) {
        let id = layout.key.id
        layouts[id] = layout
        layoutWidths[id] = width
        if layout.provisional || layout.isStandIn { unsettled.insert(id) } else { unsettled.remove(id) }
    }

    /// Whether a message's record is the one to show at the current width.
    private func isCurrent(_ id: String) -> Bool {
        guard let layout = layouts[id] else { return false }
        return layoutWidths[id] == width && !layout.provisional && !layout.isStandIn && layout.key.revision == revisions[id] ?? 0
    }

    private func input(_ row: TimelineRow) -> MacRowInput {
        let id = row.message.id
        let revision = revisions[id] ?? 0
        if let input = inputs[id], input.revision == revision { return input }
        let input = MacBubbleTextBuilder.input(row, revision: revision, isGroup: isGroup, accent: context.accent, body: MacTimelineMetrics.shared.body)
        inputs[id] = input
        return input
    }

    /// The messages whose rows changed since `old`.
    private func changedMessages(from old: [Entry], to new: [Entry]) -> [String] {
        var previous: [String: TimelineRow] = [:]
        for entry in old { if case .message(let row) = entry { previous[row.message.id] = row } }
        return new.compactMap { entry in
            guard case .message(let row) = entry, let before = previous[row.message.id], before != row else { return nil }
            return row.message.id
        }
    }

    /// The messages listed again after leaving the table (behind a filter, or out of the loaded history) whose rows
    /// changed meanwhile: their input, record and natural widths are kept from before, under the revision they left
    /// with.
    private func returningMessages(from old: [Entry], to new: [Entry]) -> [String] {
        let listed = Set(old.map(\.id))
        return new.compactMap { entry in
            guard case .message(let row) = entry, !listed.contains(row.message.id), let input = inputs[row.message.id],
                  input.message != row.message || input.header != row.dateHeader || input.startsRun != row.startsRun else { return nil }
            return row.message.id
        }
    }

    /// New revisions for `ids`, not yet given to them.
    private func newRevisions(_ ids: [String]) -> [String: Int] {
        var next: [String: Int] = [:]
        for id in ids {
            revisionCounter += 1
            next[id] = revisionCounter
        }
        return next
    }

    private func bumpRevisions(_ ids: [String]) {
        revisions.merge(newRevisions(ids)) { $1 }
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
        replySwipe.cancel()
        let next = entries(content)
        bumpRevisions(changedMessages(from: entries, to: next) + returningMessages(from: entries, to: next))
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
        // An update measuring now was worked out against the rows replaced here: its records are dropped as they land.
        pendingUpdate = nil
        staged = [:]
        width = currentWidth
        layouts = layouts.filter { indexByID[$0.key] != nil }
        layoutWidths = layoutWidths.filter { indexByID[$0.key] != nil }
        unsettled = unsettled.filter { layouts[$0] != nil }
        // The first screenful here, from where the reader lands: the first frame shows real heights.
        var start = 0
        if case .row(let id, _) = target, let row = indexByID[id] { start = max(0, row - 20) }
        let viewport = max(scrollView.contentSize.height, 400) + 400
        var filled: CGFloat = 0
        var index = start
        while index < entries.count, filled < viewport || index <= start + 20 {
            if case .message(let row) = entries[index] {
                // Published here: the table takes every row's height as it reloads.
                if !isCurrent(row.message.id) { store(mainMeasurer.layout(input(row), tableWidth: width, previous: layouts[row.message.id])) }
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

    /// Every row without a current record, on the queue: in batches applied as they land, or `inOneGo`, as a resize
    /// ends, in one update with one restore of the reader's rows.
    private func measureRest(inOneGo: Bool = false) {
        let pending = entries.compactMap { entry -> (row: TimelineRow, revision: Int)? in
            guard case .message(let row) = entry, !isCurrent(row.message.id) else { return nil }
            return (row, revisions[row.message.id] ?? 0)
        }
        guard !pending.isEmpty else { return }
        let isGroup = isGroup, accent = context.accent
        nonisolated(unsafe) let body = MacTimelineMetrics.shared.body
        let generation = generation, generations = generations, width = width, measurer = queueMeasurer
        let previous = layouts
        let batch = inOneGo ? pending.count : 150
        measurer.queue.async {
            var offset = 0
            while offset < pending.count, generations.current == generation {
                let slice = pending[offset..<min(pending.count, offset + batch)]
                let results = slice.map { item in
                    let input = MacBubbleTextBuilder.input(item.row, revision: item.revision, isGroup: isGroup, accent: accent, body: body)
                    return measurer.layout(input, tableWidth: width, previous: previous[input.id])
                }
                DispatchQueue.main.async {
                    MainActor.assumeIsolated { self.land(results, generation: generation) }
                }
                offset += batch
            }
        }
    }

    /// Records measured off the main thread: published when still current.
    private func land(_ results: [MacRowLayout], generation: Int) {
        guard generation == self.generation else { return }
        #if DEBUG
        let perfStart = MacPerfProbe.clock()
        defer { MacPerfProbe.add("table.land", since: perfStart) }
        #endif
        var landed: [MacRowLayout] = []
        for layout in results {
            let id = layout.key.id
            guard indexByID[id] != nil, revisions[id] ?? 0 == layout.key.revision else { continue }
            if inputs[id]?.revision != layout.input.revision { inputs[id] = layout.input }
            // A record made on the main thread knows the extras' size; the queue's may only guess it. A staged one is
            // for this width and revision, whatever width the queue's guess gives the extras.
            if let known = staged[id] ?? layouts[id], !known.provisional, !known.isStandIn,
               known.key == layout.key || staged[id] != nil && layout.provisional {
                if staged[id] == nil { layoutWidths[id] = width }
                continue
            }
            landed.append(layout)
        }
        publish(landed)
        measureAhead()
    }

    /// Publishes new records, each in one step with its row's height in the table, so a cell never shows a record its
    /// row's height is not from. A record as tall as its row's published one is published at once; any other with its
    /// height noted in one zero-duration update, the rows in sight kept where they are (unless `keepingRows` is false:
    /// the caller places the reader), except when no height can be noted now:
    /// - during a scroll gesture, for a row below the topmost in the clip view, whose height would move the rows in
    ///   sight: until the gesture ends, or the row reaches the top;
    /// - while the table asks for the row's view (`asViewIsMade`): until the next turn.
    ///
    /// Such a record waits in `staged`. Meanwhile its cell shows the row's published record if that differs from it only
    /// in guessing the extras' height (which the extras' view crops them to), else a stand-in: the new record cut to the
    /// row's height.
    private func publish(_ records: [MacRowLayout], keepingRows: Bool = true, asViewIsMade: Bool = false) {
        guard !records.isEmpty else { return }
        let top = isLiveScrolling ? topRowInSight : nil
        // A gesture's offset is the reader's: nothing is restored then.
        let anchor = keepingRows && !asViewIsMade && !isLiveScrolling ? captureAnchor() : nil
        var changed = IndexSet(), shown = IndexSet(), publishableNext = false
        for record in records {
            let id = record.key.id
            guard let index = indexByID[id], record.key.revision == revisions[id] ?? 0 else { continue }
            let published = layouts[id]
            let underGesture = top.map { index < $0 } ?? false
            if record.height == published?.height {
                staged[id] = nil
                store(record)
                shown.insert(index)
            } else if asViewIsMade || underGesture {
                staged[id] = record
                if !underGesture { publishableNext = true }
                if showsMeanwhile(published, record) { continue }
                store(record.standIn(height: published?.height ?? table.rect(ofRow: index).height))
                shown.insert(index)
            } else {
                staged[id] = nil
                store(record)
                changed.insert(index)
            }
        }
        if asViewIsMade {
            // The cell is configured as it is made; a record the gesture holds waits for its end, not the next turn.
            if publishableNext { scheduleMeasureAhead() }
            return
        }
        reconfigure(shown)
        guard !changed.isEmpty else { return }
        noteHeights(of: changed)
        reconfigure(changed)
        updateFiller()
        #if DEBUG
        if MacDebugHooks.has("-haus-timeline-trace") {
            MacDebugHooks.log("timeline trace: heights noted \(Array(changed.prefix(8))) anchor \(anchor?.id ?? "-") \(anchor?.offset ?? 0) now \(anchor.flatMap { indexByID[$0.id] }.map { table.rect(ofRow: $0).minY - clip.minY } ?? 0)")
        }
        #endif
        // A gesture's offset is the reader's; a change published then moves nothing in sight.
        if !isLiveScrolling { restore(anchor) }
    }

    /// Whether a row's cell goes on showing its published record while `record` waits: a guess of the same content at
    /// this width, which differs from it in the extras' size alone (and the extras' view crops them to the guess), or a
    /// stand-in for it already.
    private func showsMeanwhile(_ published: MacRowLayout?, _ record: MacRowLayout) -> Bool {
        guard let published, published.key.revision == record.key.revision, layoutWidths[record.key.id] == width else { return false }
        if published.isStandIn { return published.key == record.key && published.provisional == record.provisional }
        return published.provisional
    }

    /// The staged records that can be published now: all once a gesture has ended; during one, those whose rows are at
    /// the top of the clip view or above.
    private func publishStaged() {
        guard !staged.isEmpty else { return }
        var records = Array(staged.values)
        if isLiveScrolling {
            let top = topRowInSight
            records = records.filter { indexByID[$0.key.id].map { $0 >= top } ?? true }
            guard !records.isEmpty else { return }
        }
        for record in records { staged[record.key.id] = nil }
        publish(records)
    }

    /// The topmost row in the clip view, under the toolbar too. A row's height moves only the rows above it, so a change
    /// in this row or above moves nothing that shows, and an insertion or a removal above it neither.
    private var topRowInSight: Int { NSMaxRange(table.rows(in: clip)) - 1 }

    /// Settles the rows near the frame. First the staged records that can be published now (`publishStaged`); then the
    /// rows whose records guess their extras' height (the queue cannot size SwiftUI), or stand in for one no longer
    /// waiting, measured on the main thread before they scroll in, so no row shows a guess: nearest the clip view first,
    /// out to three frames above and below, about 3 ms' worth per pass (at least one row), in later turns until none is
    /// left. During a gesture only the rows from the top of the clip view up are taken, as their heights move nothing in
    /// sight; the rest wait for it to end. With nothing staged or unsettled, it costs nothing.
    private func measureAhead() {
        guard !staged.isEmpty || !unsettled.isEmpty, isViewLoaded, !measuringAhead, width > 0 else { return }
        measuringAhead = true
        defer { measuringAhead = false }
        publishStaged()
        // Not while the width settles: the pass at its end measures the rows again.
        guard !unsettled.isEmpty, !view.inLiveResize, endPass == nil else { return }
        let clip = clip
        let inSight = table.rows(in: clip)
        let band = table.rows(in: clip.insetBy(dx: 0, dy: -3 * clip.height))
        let top = topRowInSight
        func distance(_ index: Int) -> Int {
            index >= NSMaxRange(inSight) ? 2 * (index - NSMaxRange(inSight)) + 1 : index < inSight.location ? 2 * (inSight.location - index) + 2 : 0
        }
        var near: [(index: Int, id: String)] = []
        for id in unsettled {
            guard let index = indexByID[id] else {
                unsettled.remove(id)
                continue
            }
            // Measured already; its height waits for the gesture.
            guard staged[id] == nil else { continue }
            if NSLocationInRange(index, band), !isLiveScrolling || index >= top { near.append((index, id)) }
        }
        near.sort { distance($0.index) < distance($1.index) }
        // One budget for the pass, the rows in sight included: one it leaves shows its guess, cropped, a turn longer.
        let deadline = CACurrentMediaTime() + 0.003
        var measured: [MacRowLayout] = []
        var left: Int?
        for (index, id) in near {
            guard case .message(let row) = entries[index] else { continue }
            guard measured.isEmpty || CACurrentMediaTime() < deadline else {
                left = index
                break
            }
            measured.append(mainMeasurer.layout(input(row), tableWidth: width, previous: layouts[id]))
        }
        publish(measured)
        // During a gesture its next frame asks again, but a row left in sight is not kept waiting for one.
        guard let left, !isLiveScrolling || NSLocationInRange(left, inSight) else { return }
        scheduleMeasureAhead()
    }

    private func scheduleMeasureAhead() {
        guard !measureAheadScheduled else { return }
        measureAheadScheduled = true
        DispatchQueue.main.async {
            MainActor.assumeIsolated {
                self.measureAheadScheduled = false
                self.measureAhead()
            }
        }
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

    /// An update whose rows the queue is measuring. Only its own records apply it (`token`), only at the generation they
    /// were measured for, and not while a gesture scrolls over what it changes.
    private struct PendingUpdate {
        let token: Int
        let generation: Int
        /// The lowest row it changes, in the rows before it.
        let lowestTouched: Int?
        /// The rows before and after it, for the perf probe.
        let counts: (Int, Int)
        let commit: ([MacRowLayout]) -> Void
        /// Its records, landed during a gesture over the rows it changes: applied when the gesture ends.
        var results: [MacRowLayout]?
    }

    /// The most a change is measured on the main thread, in the turn it arrives in, in `measuringCost`'s characters:
    /// about 2 ms of layout. A costlier change (an older page, a long message) is measured on the queue.
    private static let mainThreadBudget = 600

    /// Roughly what laying a row out costs, in characters laid out: its text (up to three times for a long one, all in
    /// proportion to its length), and its extras, which SwiftUI sizes at a millisecond or so.
    private static func measuringCost(_ row: TimelineRow) -> Int {
        row.message.displayedText.utf16.count + (MacBubbleTextBuilder.extras(row.message) == nil ? 20 : 300)
    }

    /// A change of the model's content: rows inserted or removed in order, rows changed in place. The new and changed
    /// rows are measured first (here when that is cheap, else on the queue), then applied in one update with the reader
    /// kept.
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
        let changedIDs = changedMessages(from: old, to: new)
        // Rows below the lowest change are the same before and after it, so its index holds in either.
        let lowestTouched = ([removed.first, inserted.first, changedTyping ? 1 : nil] + changedIDs.map { indexByID[$0] }).compactMap { $0 }.min()
        // A gesture keeps what it scrolls over: a change at or below the top of the screen waits for it to end.
        if isLiveScrolling, let lowestTouched, lowestTouched <= topRowInSight {
            heldUpdate = true
            return
        }
        // The changed rows' new revisions stay the update's own until it applies: until then the table lists the rows as
        // they were, and a cell made for one meanwhile builds its input and natural widths under its old revision.
        let revised = newRevisions(changedIDs + returningMessages(from: old, to: new))
        let changedSet = Set(changedIDs)
        let measure = new.enumerated().compactMap { index, entry -> (row: TimelineRow, revision: Int)? in
            guard case .message(let row) = entry, inserted.contains(index) || changedSet.contains(row.message.id) else { return nil }
            return (row, revised[row.message.id] ?? revisions[row.message.id] ?? 0)
        }
        let commit: ([MacRowLayout]) -> Void = { [weak self] results in
            self?.commit(content, entries: new, removed: removed, inserted: inserted, changedIDs: changedIDs, changedTyping: changedTyping,
                         revisions: revised, results: results)
        }
        let isGroup = content.isGroup, accent = context.accent
        if measure.reduce(0, { $0 + Self.measuringCost($1.row) }) <= Self.mainThreadBudget {
            #if DEBUG
            MacPerfProbe.beginUpdate(from: old.count, to: new.count)
            #endif
            let body = MacTimelineMetrics.shared.body
            commit(measure.map { row, revision in
                let input = inputs[row.message.id].flatMap { $0.revision == revision ? $0 : nil }
                    ?? MacBubbleTextBuilder.input(row, revision: revision, isGroup: isGroup, accent: accent, body: body)
                return mainMeasurer.layout(input, tableWidth: width)
            })
            return
        }
        // Measured on the queue, inputs and all, and applied when the records land.
        updateTokens += 1
        let token = updateTokens
        pendingUpdate = PendingUpdate(token: token, generation: generation, lowestTouched: lowestTouched, counts: (old.count, new.count), commit: commit)
        let rows = measure
        nonisolated(unsafe) let body = MacTimelineMetrics.shared.body
        let width = width, measurer = queueMeasurer
        measurer.queue.async {
            let results = rows.map { row, revision in
                measurer.layout(MacBubbleTextBuilder.input(row, revision: revision, isGroup: isGroup, accent: accent, body: body), tableWidth: width)
            }
            DispatchQueue.main.async {
                MainActor.assumeIsolated { self.land(results, ofUpdate: token) }
            }
        }
    }

    /// An update's records, back from the queue. Those of an update a reload dropped change nothing; the model's newest
    /// content is applied again instead, unless a later update is on its way with it.
    private func land(_ results: [MacRowLayout], ofUpdate token: Int) {
        guard var pending = pendingUpdate, pending.token == token else {
            if pendingUpdate == nil { timeline?.update() }
            return
        }
        guard pending.generation == generation else {
            // Measured for another width: measured again.
            pendingUpdate = nil
            timeline?.update()
            return
        }
        // The gesture may have started since the update was asked for.
        if isLiveScrolling, let lowest = pending.lowestTouched, lowest <= topRowInSight {
            pending.results = results
            pendingUpdate = pending
            return
        }
        pendingUpdate = nil
        #if DEBUG
        MacPerfProbe.beginUpdate(from: pending.counts.0, to: pending.counts.1)
        #endif
        pending.commit(results)
    }

    /// The update whose records landed during the gesture that just ended.
    private func applyHeldUpdate() {
        guard let pending = pendingUpdate, let results = pending.results else { return }
        pendingUpdate = nil
        guard pending.generation == generation else {
            timeline?.update()
            return
        }
        #if DEBUG
        MacPerfProbe.beginUpdate(from: pending.counts.0, to: pending.counts.1)
        #endif
        pending.commit(results)
    }

    /// Applies a measured change in one table update, then places the reader: at the newest message when the policy
    /// follows it, else with the rows in sight exactly where they were.
    private func commit(_ content: MacTimelineContent, entries next: [Entry], removed: IndexSet, inserted: IndexSet, changedIDs: [String],
                        changedTyping: Bool, revisions revised: [String: Int], results: [MacRowLayout]) {
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
        // The new content's revisions, inputs and records, published with the rows the table takes in the update below.
        revisions.merge(revised) { $1 }
        isGroup = content.isGroup
        for layout in results {
            let id = layout.key.id
            staged[id] = nil
            store(layout)
            inputs[id] = layout.input
        }
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
        // During a gesture only a change that moves nothing in sight lands (`update`, `land`), and the offset is the
        // reader's: nothing is corrected.
        if !isLiveScrolling {
            switch placement {
            case .newestAtOnce, .slideToNewest, .followNewest:
                scroll(toDistanceFromBottom: 0)
                followsEnd = true
            case .keepAnchor:
                // One exact compensation: the lowest row in sight back where it was.
                if let anchor, let row = indexByID[anchor.id] { scroll(toY: table.rect(ofRow: row).minY - anchor.offset) }
            }
        }
        adjusting = false
        noteRestingPlace()
        // The rows the change brought into sight are measured there (`measureAhead`), their extras too if the queue
        // guessed them.
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
        // Measured for the old width.
        staged = [:]
        let visible = table.rows(in: clip)
        var measured: [MacRowLayout] = [], hosted = IndexSet()
        for index in visible.location..<min(entries.count, NSMaxRange(visible)) {
            switch entries[index] {
            case .message(let row):
                let id = row.message.id
                let old = layouts[id]
                let layout = mainMeasurer.layout(input(row), tableWidth: next, previous: old)
                if let old, !old.isStandIn, layout.key == old.key, layout.provisional == old.provisional {
                    layoutWidths[id] = next
                } else {
                    measured.append(layout)
                }
            case .typing, .loading:
                hosted.insert(index)
            case .filler:
                break
            }
        }
        if !hosted.isEmpty { noteHeights(of: hosted) }
        // Bottom-anchored: the lowest row in sight stays, the rows above it move; the reader's row is kept below.
        publish(measured, keepingRows: false)
        updateFiller()
        // A gesture's offset is the reader's: its rows' heights wait for it (`publish`), and nothing scrolls.
        if !isLiveScrolling { keepPlace() }
        if !view.inLiveResize { scheduleEndPass() }
    }

    private func liveResizeEnded() {
        endPass?.cancel()
        endPass = nil
        measureRest(inOneGo: true)
    }

    /// A width that keeps changing outside a live resize (the sidebar's animation) measures every row once, when it
    /// settles.
    private func scheduleEndPass() {
        endPass?.cancel()
        let work = DispatchWorkItem { [weak self] in
            MainActor.assumeIsolated {
                self?.endPass = nil
                self?.measureRest(inOneGo: true)
            }
        }
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
        // The records held for the gesture first, then the update held with them, against the heights they settle.
        publishStaged()
        applyHeldUpdate()
        if heldUpdate {
            heldUpdate = false
            timeline?.update()
        }
        measureAhead()
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
        #endif
        guard let timeline else { return }
        let distance = distanceFromBottom
        let byReader = !adjusting && (isLiveScrolling || Self.scrollInput)
        if byReader {
            followsEnd = distance < TimelineScrollPolicy.nearBottomDistance
            if !isLiveScrolling { noteRestingPlace() }
        }
        // The frame's new size (the window, the sidebar): the reader stays where they were.
        if clip.size != clipSize {
            let first = clipSize == .zero
            clipSize = clip.size
            if !first, !adjusting, !isLiveScrolling { keepPlace() }
        }
        timeline.setShowsJumpToNewest(!followsEnd && TimelineScrollPolicy.showsJumpToNewest(distanceFromBottom: distance, viewportHeight: frameHeight))
        timeline.scrolled(byReader: byReader, moving: byReader || timeline.readerIsScrolling)
        updateShown()
        if !isLiveScrolling { updateHover() }
        if !adjusting { measureAhead() }
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

    // MARK: Reply swipe

    /// A scroll event of this window, for the reply swipe; true when it keeps it from the scroll view.
    private func scrollWheel(_ event: NSEvent) -> Bool {
        guard let window = view.window else { return false }
        guard event.window === window else {
            if event.window != nil { scrolledElsewhere(event) }
            return false
        }
        return handleScroll(event, at: table.convert(event.locationInWindow, from: nil)) { window.sendEvent($0) }
    }

    /// A scroll event of another of the app's windows. The pointer stays put while two fingers scroll, so the fingers'
    /// events go to another window only once a gesture here is over or a window came up under the pointer: either way
    /// the end of a swipe here would never come, and it ends now. Momentum is left alone: an earlier gesture's may still
    /// be running down in that window when the fingers touch here.
    func scrolledElsewhere(_ event: NSEvent) {
        if !event.phase.isEmpty { replySwipe.cancel() }
    }

    /// `point` is in the table's coordinates; `pass` hands an event held back to the scroll view.
    func handleScroll(_ event: NSEvent, at point: NSPoint, pass: (NSEvent) -> Void) -> Bool {
        replySwipe.handle(event, at: point, pass: pass)
    }

    /// The message row in sight under `point`, if a swipe there replies to its message.
    private func replySwipeCell(at point: NSPoint) -> MacTimelineMessageCell? {
        guard table.visibleRect.contains(point), visibleFrame.contains(point) else { return nil }
        let row = table.row(at: point)
        guard row >= 0, let cell = table.view(atColumn: 0, row: row, makeIfNecessary: false) as? MacTimelineMessageCell,
              cell.ownsReplySwipe(at: table.convert(point, to: cell)) else { return nil }
        return cell
    }

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

    /// A rough height for a row not measured yet, until its record lands from the queue.
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
            if !isCurrent(id) {
                // Unmeasured, measured at another width or for older content, or with a guess for its extras, and about
                // to show: measured here. The table cannot take a height while it asks for a view, so a record of
                // another height than the row's waits for the next turn (or the gesture's end), and the cell shows
                // what `publish` says meanwhile.
                publish([mainMeasurer.layout(input(message), tableWidth: width, previous: staged[id] ?? layouts[id])], asViewIsMade: true)
            }
            guard let layout = layouts[id] else { return nil }
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
    /// The tour's stand-in for a gesture: what a scroll view's live scroll notifications start and end.
    func debugLiveScroll(_ scrolling: Bool) {
        guard scrolling != isLiveScrolling else { return }
        if scrolling { liveScrollStarted() } else { liveScrollEnded() }
    }

    /// The table's state for the tour's reports.
    var debugReport: String {
        String(format: "from bottom %.1f, frame %.1f, top inset %.1f, bottom inset %.1f, clip y %.1f, document %.1f, width %.0f",
               distanceFromBottom, frameHeight, bars.top, bars.bottom, clip.minY, table.bounds.height, width)
    }

    var debugClipY: CGFloat { clip.minY }

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

    /// Where the tour's `swipe` puts the pointer for a message, brought into sight: the middle of its bubble, in the
    /// table's coordinates.
    func debugSwipePoint(of id: String) -> NSPoint? {
        guard let row = indexByID[id] else { return nil }
        reveal(id, margin: MacTimelineController.focusMargin)
        table.layoutSubtreeIfNeeded()
        guard let cell = table.view(atColumn: 0, row: row, makeIfNecessary: true) as? MacTimelineMessageCell else { return nil }
        let bubble = cell.bubbleFrame
        return table.convert(NSPoint(x: bubble.midX, y: bubble.midY), from: cell)
    }

    /// A message's cell put back at once, as its reuse for another message does.
    func debugResetSwipe(of id: String) {
        guard let row = indexByID[id], let cell = table.view(atColumn: 0, row: row, makeIfNecessary: false) as? MacTimelineMessageCell else { return }
        cell.endSwipe(animated: false)
    }

    /// The bubble's travel, the reply arrow and the toolbar of a message's cell.
    func debugSwipeState(of id: String) -> String {
        guard let row = indexByID[id], let cell = table.view(atColumn: 0, row: row, makeIfNecessary: false) as? MacTimelineMessageCell else { return "\(id) has no cell" }
        return cell.debugSwipeState
    }

    /// The tour's `hover <id>|off`: each cell in sight shows its toolbar as the pointer would.
    func debugHoverChanged() {
        table.enumerateAvailableRowViews { rowView, _ in
            (rowView.view(atColumn: 0) as? MacTimelineMessageCell)?.updateToolbarVisibility()
        }
    }

    /// The published records against the table: the cells whose record is not as tall as their row, those showing a
    /// guess or a stand-in, the listed rows whose height in the table is not their published record's, and the records
    /// staged.
    struct DebugGeometry {
        var cells = 0
        var cellsOff: [String] = []
        var shownGuesses: [String] = []
        var shownStandIns: [String] = []
        var rowsOff: [String] = []
        var staged = 0
    }

    func debugGeometry() -> DebugGeometry {
        var geometry = DebugGeometry(staged: staged.count)
        table.enumerateAvailableRowViews { rowView, _ in
            guard let cell = rowView.view(atColumn: 0) as? MacTimelineMessageCell, let record = cell.layoutRecord else { return }
            geometry.cells += 1
            let id = record.key.id
            if abs(record.height - rowView.frame.height) > 0.5 { geometry.cellsOff.append("\(id) \(record.height)/\(rowView.frame.height)") }
            if record.provisional { geometry.shownGuesses.append(id) }
            if record.isStandIn { geometry.shownStandIns.append(id) }
        }
        for (index, entry) in entries.enumerated() {
            guard case .message(let row) = entry, let record = layouts[row.message.id] else { continue }
            let height = table.rect(ofRow: index).height
            if abs(height - record.height) > 0.5 { geometry.rowsOff.append("\(row.message.id) \(height)/\(record.height)") }
        }
        return geometry
    }

    /// The row records' agreement with what a live bubble text view lays out, at the current width; then each cell in
    /// the table: the record it shows against its row's height, records that still guess their extras' height or stand
    /// in for a staged one, the extras' hosting view against what SwiftUI fits in it, every row's height against its
    /// record, and the records staged.
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
        var extrasOff: [String] = [], staleFooters: [String] = []
        let sizer = NSHostingController(rootView: AnyView(EmptyView()))
        sizer.sizingOptions = []
        table.enumerateAvailableRowViews { rowView, _ in
            guard let cell = rowView.view(atColumn: 0) as? MacTimelineMessageCell, let record = cell.layoutRecord else { return }
            let id = record.key.id
            if let stale = cell.debugStaleFooter { staleFooters.append("\(id) \(stale)") }
            if cell.debugExtras != nil, let message = cell.message, let frame = record.extrasFrame, !record.provisional, !record.isStandIn {
                // What SwiftUI fits them in now, sized afresh, past every cache.
                let width = record.key.contentWidth
                sizer.rootView = AnyView(MacBubbleExtrasContent.sizing(message).frame(width: width))
                let fits = MacTimelineMetrics.bubbleTop + ceil(sizer.sizeThatFits(in: CGSize(width: width, height: .greatestFiniteMagnitude)).height)
                if abs(fits - frame.height) > 0.5 { extrasOff.append("\(id) \(frame.height)/\(fits)") }
            }
        }
        let provisional = layouts.values.filter(\.provisional).count
        let geometry = debugGeometry()
        return "\(rows) texts, worst \(worst) pt" + (failures.isEmpty ? "" : ", off: " + failures.joined(separator: "; "))
            + "; \(geometry.cells) cells, \(geometry.cellsOff.count) off their rows' heights \(geometry.cellsOff.prefix(4)), "
            + "\(geometry.shownGuesses.count) showing guesses \(geometry.shownGuesses.prefix(4)), \(geometry.shownStandIns.count) standing in "
            + "\(geometry.shownStandIns.prefix(4)), extras off \(extrasOff.prefix(4)), \(staleFooters.count) footers stale \(staleFooters.prefix(4)); \(geometry.rowsOff.count) rows off their records "
            + "\(geometry.rowsOff.prefix(4)); \(provisional) guessed records, \(geometry.staged) staged, live scroll \(isLiveScrolling ? 1 : 0)"
    }

    /// The tour's `edit-race`: whether a message's published record, its input and its cell's text are `edited`, and
    /// whether the record is laid out as a measurer with no caches lays the row out now.
    func debugText(of id: String, edited: String) -> String {
        func which(_ text: String?) -> String { text.map { $0 == edited ? "edited" : "old" } ?? "none" }
        guard let index = indexByID[id], case .message(let row) = entries[index], let record = layouts[id] else { return "\(id) not listed" }
        let cell = table.view(atColumn: 0, row: index, makeIfNecessary: false) as? MacTimelineMessageCell
        let fresh = MacRowMeasurer(metrics: .shared, sizer: MacExtrasSizer(), natural: MacNaturalWidths())
            .layout(MacBubbleTextBuilder.input(row, revision: 0, isGroup: isGroup, accent: context.accent, body: MacTimelineMetrics.shared.body), tableWidth: width)
        let afresh = fresh.key.contentWidth == record.key.contentWidth && fresh.height == record.height
        return "record \(which(record.input.text.string)) \(afresh ? "as afresh" : "not as afresh (\(record.key.contentWidth) wide, \(record.height) tall, afresh \(fresh.key.contentWidth), \(fresh.height))"), "
            + "input \(which(inputs[id]?.text.string)), cell \(which(cell?.textView.string))"
    }

    /// A row's cell made again, as the table makes one for a row that scrolls into sight.
    func debugRemake(_ id: String) {
        guard let row = indexByID[id] else { return }
        table.reloadData(forRowIndexes: IndexSet(integer: row), columnIndexes: IndexSet(integer: 0))
    }

    /// The whole table again where the reader is, as a new accent reloads it.
    func debugReload() {
        reloadAll(at: readerPlace())
    }

    /// The tour's `hit-reaction <id>`: the window's hit test at the message's first pill, then that view's mouse-down
    /// handed to it in process, as a click on the pill would be.
    func debugHitReaction(_ id: String) -> String {
        reveal(id, margin: MacTimelineController.focusMargin)
        view.window?.contentView?.layoutSubtreeIfNeeded()
        guard let row = indexByID[id], let cell = table.view(atColumn: 0, row: row, makeIfNecessary: true) as? MacTimelineMessageCell,
              let pill = cell.debugReactionPill, let window = view.window, let content = window.contentView else { return "\(id) shows no pill" }
        let hit = content.hitTest(content.superview?.convert(pill.point, from: nil) ?? pill.point)
        guard let hit, hit === pill.view else { return "the pill's point hits \(hit.map { String(describing: type(of: $0)) } ?? "nothing")" }
        guard let event = NSEvent.mouseEvent(with: .leftMouseDown, location: pill.point, modifierFlags: [], timestamp: ProcessInfo.processInfo.systemUptime,
                                             windowNumber: window.windowNumber, context: nil, eventNumber: 0, clickCount: 1, pressure: 1) else { return "no event" }
        hit.mouseDown(with: event)
        return "the pill's point hits the pills; clicked \(pill.emoji)"
    }

    /// The tour's `reuse-media`: one cell shows a photo, then is given another message's photo, as a reused cell is.
    /// Each picture is a flat colour, so the sampled middle says which shows: the second's, or its placeholder while it
    /// decodes, never the first's.
    func debugReuseMedia() async -> String {
        func file(_ color: NSColor, _ name: String) -> URL? {
            let image = NSImage(size: NSSize(width: 64, height: 48), flipped: false) { rect in
                color.setFill()
                rect.fill()
                return true
            }
            guard let tiff = image.tiffRepresentation, let png = NSBitmapImageRep(data: tiff)?.representation(using: .png, properties: [:]) else { return nil }
            let url = FileManager.default.temporaryDirectory.appending(path: "\(name)-\(UUID().uuidString).png")
            return (try? png.write(to: url)) == nil ? nil : url
        }
        guard let red = file(.systemRed, "reuse-red"), let blue = file(.systemBlue, "reuse-blue") else { return "no files" }
        defer { [red, blue].forEach { try? FileManager.default.removeItem(at: $0) } }
        func row(_ id: String, _ url: URL) -> TimelineRow {
            let attachment = TimelineAttachment(name: "\(id).png", mediaType: "image/png", size: 100, width: 64, height: 48, localURL: url)
            return TimelineRow(message: TimelineMessage(id: id, body: "", isOutgoing: false, isStarred: false, attachment: attachment, sentAt: .now),
                               dateHeader: nil, startsRun: true, endsRun: true)
        }
        let first = row("debug-reuse-red", red), second = row("debug-reuse-blue", blue)
        let cell = MacTimelineMessageCell(drawsWhole: true, context: context)
        // Behind the opaque scroll view: in the window, so SwiftUI draws it, and never in sight.
        view.addSubview(cell, positioned: .below, relativeTo: scrollView)
        defer { cell.removeFromSuperview() }
        func show(_ row: TimelineRow) async -> String {
            let layout = mainMeasurer.layout(MacBubbleTextBuilder.input(row, revision: 0, isGroup: false, accent: context.accent, body: MacTimelineMetrics.shared.body),
                                             tableWidth: max(400, width))
            cell.frame = NSRect(x: 0, y: 0, width: max(400, width), height: layout.height)
            cell.configure(layout, message: row.message)
            cell.layoutSubtreeIfNeeded()
            try? await Task.sleep(for: .milliseconds(600))
            guard let frame = layout.extrasFrame, let rep = cell.bitmapImageRepForCachingDisplay(in: cell.bounds) else { return "nothing" }
            cell.cacheDisplay(in: cell.bounds, to: rep)
            let scale = CGFloat(rep.pixelsWide) / cell.bounds.width
            guard let color = rep.colorAt(x: Int(frame.midX * scale), y: Int(frame.midY * scale))?.usingColorSpace(.sRGB) else { return "nothing" }
            if color.redComponent > 0.6, color.greenComponent < 0.45, color.blueComponent < 0.45 { return "red" }
            if color.blueComponent > 0.6, color.redComponent < 0.45 { return "blue" }
            return "placeholder"
        }
        let shown = await show(first)
        let reused = await show(second)
        return "the first photo shows \(shown), the reused cell's second shows \(reused) (red is the first's: stale)"
    }

    /// The tour's `extras-cache`: a quote measured, then measured again once it says more, for the same message at the
    /// same revision, as a chat opened again starts its revisions over.
    func debugExtrasCache() -> String {
        func message(_ quote: String) -> TimelineMessage {
            TimelineMessage(id: "debug-extras-cache-\(generation)", body: "", isOutgoing: false, isStarred: false, sentAt: .now,
                            reply: TimelineReply(author: "Alex", body: quote))
        }
        let short = message("Short"), long = message(String(repeating: "A quote that says a good deal more than the first one did. ", count: 4))
        let sizer = MacExtrasSizer()
        let before = sizer.height(short, content: MacExtrasSizes.Content(short), width: 300)
        let after = sizer.height(long, content: MacExtrasSizes.Content(long), width: 300)
        return "a short quote \(before) pt, the same message's longer quote \(after) pt (the same height again would be the first's: stale)"
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
