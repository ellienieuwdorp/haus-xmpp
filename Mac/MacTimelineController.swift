import AppKit
import SwiftUI

/// The open chat's timeline: the rows it shows and the scrolling that SwiftUI's own anchors leave undone.
///
/// The scroll view binds the reader's row through `scrollPosition(id:anchor: .top)`, which keeps it through a resize
/// and through a content change while no scroll gesture runs. Three things it does not do are done here, after each
/// update and before the next frame is drawn:
///
/// - **Holding the reader's row through an older page.** During a gesture, and after a scroll this controller made,
///   SwiftUI keeps the absolute offset, so a page landing above the reader pushes their row a page down. The row and its
///   distance from the top edge are noted before the update, layout is forced after it, and the row is scrolled back.
/// - **Following the newest message** when the reader was at the bottom or sent the message: a scroll to the end,
///   repeated after each layout pass until it holds (rows measured on arrival move the end), at most four times.
/// - **Paging**: older history is asked for when the reader's own scroll comes within two screens of the oldest loaded
///   message (`TimelineScrollPolicy.OlderHistoryRequests`).
///
/// The rows are not read from the model inside a view update: the controller observes what they are built from and
/// applies a change in its own main-queue turn, so it can look at the reader's row before the change and correct the
/// position after it. Position corrections go through `ScrollViewProxy`, never by moving the clip view (the next scroll
/// event would undo that), and never from inside a view update (the proxy may not be used there).
@MainActor @Observable final class MacTimelineController {
    /// This chat's first page is loaded. The scroll view is built only from then on, so its initial offset is the tail
    /// of real content.
    private(set) var isLoaded = false
    /// What the stack lists, top to bottom. One list, so a scroll can reach any item before the lazy stack builds it.
    private(set) var items: [MacTimelineItem] = [.end]
    @ObservationIgnored private(set) var rows: [TimelineRow] = []
    @ObservationIgnored private(set) var typing: TimelineTyping?
    @ObservationIgnored private(set) var loadingEarlier = false
    private(set) var isGroup = false
    /// The reader is far enough above the newest message for the jump button.
    private(set) var showsJumpToNewest = false
    /// A message just scrolled to, tinted for a moment so the eye finds it.
    private(set) var highlightedID: String?
    /// The day of the topmost message while the reader scrolls; nil at rest and at the top of history.
    private(set) var dayChip: TimelineScrollPolicy.DayChip?

    /// Where the scroll view laid things out. Not observed: it changes on every scrolled frame.
    @ObservationIgnored let layout = MacTimelineLayout()
    @ObservationIgnored private let model: AppModel
    @ObservationIgnored private let chatID: String
    @ObservationIgnored private let makePresenter: () -> ConversationPresenter
    @ObservationIgnored private var indexByID: [String: Int] = [:]
    @ObservationIgnored private var olderRequests = TimelineScrollPolicy.OlderHistoryRequests()
    /// Counts the observations registered: only the latest one's change applies an update, so an update applied out of
    /// turn (a jump paging history in) never leaves a second chain of observations behind.
    @ObservationIgnored private var observation = 0
    @ObservationIgnored private var readerMovedAt: ContinuousClock.Instant?
    @ObservationIgnored private var scrolling = false
    /// An update is being applied: the geometry it reports on the way is between two layouts and never pages.
    @ObservationIgnored private var applying = false
    @ObservationIgnored private var dayChipIdle: Task<Void, Never>?
    @ObservationIgnored private var highlightEnd: Task<Void, Never>?
    @ObservationIgnored private var revealing: Task<Void, Never>?
    /// Set from opening until the timeline first rests at its end with the frame's insets in place, or the reader moves
    /// it. SwiftUI may place the initial offset before the toolbar's and the composer's insets arrive, which leaves a
    /// chat slightly taller than the frame at its top, its newest message under the composer.
    @ObservationIgnored private var settlingAtOpen = true
    @ObservationIgnored private var settleAttempts = 0

    /// The bottom spacer's ID: the end of the content, below the typing bubble.
    nonisolated static let endID = "end\u{0}"
    /// The content's margin above the oldest row and inside the end spacer.
    static let topMargin: CGFloat = 12

    /// `presenter` builds the conversation's presenter; everything it reads is observed, and a change is applied in the
    /// next main-queue turn.
    init(model: AppModel, chatID: String, presenter: @escaping () -> ConversationPresenter) {
        self.model = model
        self.chatID = chatID
        makePresenter = presenter
        apply(observe())
        #if DEBUG
        Self.current = self
        #endif
    }

    // MARK: Updates

    /// What the timeline shows, built from the model.
    private struct Content: Equatable {
        var isLoaded = false
        var rows: [TimelineRow] = []
        var typing: TimelineTyping?
        var loadingEarlier = false
        var isGroup = false
    }

    /// Builds the content and observes everything it read; the first change to any of it schedules an update, unless
    /// a later call has registered its own observation since.
    private func observe() -> Content {
        observation += 1
        let token = observation
        return withObservationTracking {
            guard model.messagesLoadedFor == chatID else { return Content() }
            let presenter = makePresenter()
            return Content(isLoaded: true, rows: TimelineItems.rows(for: presenter.timelineMessages), typing: presenter.typing,
                           loadingEarlier: presenter.loadingEarlier, isGroup: presenter.isGroup)
        } onChange: { [weak self] in
            // Called as the model is about to change, inside whatever is changing it: apply in a turn of our own.
            DispatchQueue.main.async {
                MainActor.assumeIsolated {
                    guard let self, self.observation == token else { return }
                    self.update()
                }
            }
        }
    }

    private var current: Content { Content(isLoaded: isLoaded, rows: rows, typing: typing, loadingEarlier: loadingEarlier, isGroup: isGroup) }

    private func apply(_ content: Content) {
        if content.rows != rows || content.typing != typing || content.loadingEarlier != loadingEarlier {
            if content.rows != rows {
                indexByID = Dictionary(content.rows.enumerated().map { ($1.message.id, $0) }, uniquingKeysWith: { first, _ in first })
            }
            rows = content.rows
            typing = content.typing
            loadingEarlier = content.loadingEarlier
            items = (loadingEarlier ? [.loadingEarlier] : []) + rows.map(MacTimelineItem.message) + (typing.map { [.typing($0)] } ?? []) + [.end]
        }
        if content.isGroup != isGroup { isGroup = content.isGroup }
        if content.isLoaded != isLoaded { isLoaded = content.isLoaded }
    }

    /// Applies the model's current content and keeps the reader where the policy says.
    private func update() {
        let next = observe()
        guard next != current else { return }
        // The scroll view is built with this content (or taken down), so there is no position to keep.
        guard isLoaded, next.isLoaded, layout.isAttached else {
            apply(next)
            return
        }
        // A scroll since the last layout pass may not have reported its rows yet.
        layout.forceLayout()
        let wasNearBottom = layout.distanceFromBottom < TimelineScrollPolicy.nearBottomDistance
        let placement = TimelineScrollPolicy.Update(previousTailID: rows.last?.message.id, rows: next.rows, wasNearBottom: wasNearBottom,
                                                    typingChanged: typing != next.typing, typingLeft: typing != nil && next.typing == nil,
                                                    canAnimate: false).placement
        let before = placedRows()
        let reader = TimelineScrollPolicy.readerRow(before, visibleTop: 0, visibleBottom: layout.height)
        applying = true
        defer { applying = false }
        apply(next)
        // Lay the new rows out now, so the correction happens before the next frame is drawn.
        layout.forceLayout()
        switch placement {
        case .keepAnchor:
            if let reader {
                #if DEBUG
                let moved = layout.frame(of: reader.id).map { $0.minY - reader.top }
                #endif
                let anchor = hold(reader, among: before)
                #if DEBUG
                MacTimelineDebug.held(anchor, movedByUpdate: moved, by: self)
                #else
                _ = anchor
                #endif
            }
        case .newestAtOnce, .slideToNewest, .followNewest:
            scrollToNewest()
        }
    }

    // MARK: Positions

    /// The rows the scroll view has laid out, top to bottom.
    func placedRows() -> [TimelineScrollPolicy.PlacedRow] {
        layout.frames.compactMap { id, frame -> TimelineScrollPolicy.PlacedRow? in
            guard let index = indexByID[id] else { return nil }
            return TimelineScrollPolicy.PlacedRow(id: id, index: index, top: frame.minY, bottom: frame.maxY, dayHeader: rows[index].dateHeader)
        }
        .sorted { $0.index < $1.index }
    }

    func readerRow() -> TimelineScrollPolicy.PlacedRow? {
        TimelineScrollPolicy.readerRow(placedRows(), visibleTop: 0, visibleBottom: layout.height)
    }

    /// Puts the reader's row back at the distance from the top edge it had before an update. Every row moves with it,
    /// so the correction goes through the first row from the reader's on that a scroll can put back exactly (inside the
    /// frame) and that the update left the same height: an older page from the same day takes the day header off the
    /// row that opened the loaded window, and holding that row's top edge would lift its bubble by the header's height.
    @discardableResult
    private func hold(_ reader: TimelineScrollPolicy.PlacedRow, among before: [TimelineScrollPolicy.PlacedRow]) -> TimelineScrollPolicy.PlacedRow {
        let height = layout.height
        let candidates = before.filter { $0.index >= reader.index && $0.top >= 0 && $0.bottom <= height }
        // The first scroll brings the rows back into layout (a page landing mid-gesture pushes them off), so their new
        // heights can be compared.
        let first = candidates.first ?? reader
        place(first.id, top: first.top)
        let unchanged = candidates.first { row in
            layout.frame(of: row.id).map { abs($0.height - (row.bottom - row.top)) <= 0.5 } ?? false
        }
        guard let unchanged, unchanged != first else { return first }
        place(unchanged.id, top: unchanged.top)
        return unchanged
    }

    /// Scrolls so the row's top edge is at `target` (which must keep the row inside the frame, `reachableTop`), through
    /// SwiftUI: a scroll to the row with the unit-point anchor that should put it there, corrected by what it missed. A
    /// row that is not laid out is first brought to the top edge. Returns whether the row ended within half a point.
    @discardableResult
    func place(_ id: String, top target: CGFloat) -> Bool {
        guard let proxy = layout.proxy else { return false }
        var aim = target
        var aimed = false
        for _ in 0..<4 {
            guard let now = layout.frame(of: id) else {
                proxy.scrollTo(id, anchor: .top)
                layout.forceLayout()
                aimed = false
                continue
            }
            let miss = target - now.minY
            if abs(miss) <= 0.5 { return true }
            if aimed { aim += miss }
            guard let y = TimelineScrollPolicy.anchorY(placingTopAt: aim, rowHeight: now.height, frameHeight: layout.height) else { return false }
            proxy.scrollTo(id, anchor: UnitPoint(x: 0.5, y: min(1, max(0, y))))
            layout.forceLayout()
            #if DEBUG
            if MacDebugHooks.has("-haus-timeline-trace") {
                MacDebugHooks.log("place \(id) target \(target) was \(now.minY) h \(now.height) aim \(aim) y \(y) -> \(layout.frame(of: id)?.minY ?? -1)")
            }
            #endif
            aimed = true
        }
        return layout.frame(of: id).map { abs(target - $0.minY) <= 0.5 } ?? false
    }

    /// Lands on the newest message (or the typing bubble): the end spacer's bottom on the frame's bottom. The first
    /// scroll lands on estimated heights and measuring the rows it brings moves the end again, so it repeats until the
    /// end is in place, at most four passes.
    func scrollToNewest() {
        guard let proxy = layout.proxy else { return }
        for _ in 0..<4 {
            if let end = layout.frame(of: Self.endID), abs(end.maxY - layout.height) <= 0.5 { break }
            proxy.scrollTo(Self.endID, anchor: .bottom)
            layout.forceLayout()
        }
        #if DEBUG
        if MacDebugHooks.has("-haus-timeline-trace") { MacDebugHooks.log("newest: end \(layout.frame(of: Self.endID)?.maxY ?? -1) of \(layout.height)") }
        #endif
    }

    // MARK: Reader input

    /// The frame's new size. Its height changes with the window and with whatever sits below the timeline (the composer
    /// growing or shrinking by a line, a reply bar). SwiftUI keeps the reader's top row, and the end only when the reader
    /// was exactly at it; a reader who was within `nearBottomDistance` of the end keeps the newest message in view, as an
    /// arriving message would follow them. The size arrives after the change, so the distance before it is the distance
    /// now less the change.
    func resized(_ size: CGSize) {
        let change = size.height - layout.size.height
        let wasNearBottom = layout.size.height > 0 && layout.distanceFromBottom + change < TimelineScrollPolicy.nearBottomDistance
        layout.size = size
        guard change != 0, wasNearBottom, isLoaded else { return }
        // Never from inside the layout pass reporting the size: the proxy may not be used there.
        DispatchQueue.main.async {
            MainActor.assumeIsolated {
                guard self.layout.isAttached, self.layout.distanceFromBottom > 0.5 else { return }
                self.scrollToNewest()
            }
        }
    }

    /// Every change of the scroll view's geometry: the jump button, paging and the day chip follow it.
    func scrolled(_ geometry: ScrollGeometry) {
        layout.geometry = geometry
        let jump = TimelineScrollPolicy.showsJumpToNewest(distanceFromBottom: layout.distanceFromBottom, viewportHeight: layout.height)
        if jump != showsJumpToNewest { withAnimation(.easeOut(duration: 0.2)) { showsJumpToNewest = jump } }
        if !applying { requestOlderIfNeeded() }
        updateDayChip()
        settleAtOpen(geometry)
    }

    /// Puts a just-opened timeline at its end once the insets are known (`settlingAtOpen`). Measured from the scroll
    /// geometry, which carries the insets, rather than from row frames that may not be laid out yet.
    private func settleAtOpen(_ geometry: ScrollGeometry) {
        guard settlingAtOpen, layout.isAttached, geometry.contentInsets.top > 0 || geometry.contentInsets.bottom > 0 else { return }
        let toEnd = geometry.contentSize.height - geometry.contentOffset.y - geometry.contentInsets.top - geometry.containerSize.height
        guard toEnd > 0.5, settleAttempts < 3 else {
            settlingAtOpen = false
            return
        }
        settleAttempts += 1
        // Never from inside the layout pass reporting the geometry: the proxy may not be used there.
        DispatchQueue.main.async {
            MainActor.assumeIsolated {
                guard self.settlingAtOpen else { return }
                self.scrollToNewest()
            }
        }
    }

    func phaseChanged(_ phase: ScrollPhase) {
        scrolling = phase.isScrolling
        if scrolling {
            settlingAtOpen = false
            dayChipIdle?.cancel()
            updateDayChip()
        } else {
            scheduleDayChipIdle()
        }
    }

    private var readerIsScrolling: Bool {
        scrolling || readerMovedAt.map { ContinuousClock.now - $0 < .milliseconds(500) } ?? false
    }

    /// From the top of the content to the visible top: from the oldest row when it is laid out (current after a forced
    /// layout pass), else from the scroll geometry.
    private var distanceFromTop: CGFloat {
        if let first = loadingEarlier ? TimelineItems.loadingEarlierID : rows.first?.message.id, let frame = layout.frame(of: first) {
            return -frame.minY
        }
        return layout.geometry.map { $0.contentOffset.y + $0.contentInsets.top } ?? .infinity
    }

    private func requestOlderIfNeeded() {
        guard olderRequests.shouldRequest(oldestID: rows.first?.message.id, distanceFromTop: distanceFromTop,
                                          viewportHeight: layout.height, byReader: readerIsScrolling) else { return }
        // Never applied from inside this callback: the page comes back from the store in a later turn.
        Task {
            var again = true
            while again {
                let oldest = model.messages.first?.id
                let more = await model.loadOlderMessages()
                // The rows follow the model in a turn of their own, so the model says whether older messages came.
                again = olderRequests.finished(oldestID: rows.first?.message.id, broughtOlder: model.messages.first?.id != oldest, mayBringMore: more)
            }
        }
    }

    /// A key or a jump moved the timeline: it counts as the reader's scroll for paging and shows the day chip.
    private func readerMoved() {
        readerMovedAt = .now
        settlingAtOpen = false
        dayChipIdle?.cancel()
        updateDayChip(force: true)
        scheduleDayChipIdle()
    }

    enum KeyScroll { case pageUp, pageDown, top, bottom }

    /// Page Up and Page Down move by the visible height less a line of overlap, so the line that was at the edge stays
    /// in view; Home goes to the oldest loaded message (and asks for older history), End to the newest.
    func scroll(_ key: KeyScroll) {
        let page = max(40, layout.height - 40)
        switch key {
        case .pageUp: scroll(by: page)
        case .pageDown: scroll(by: -page)
        case .top:
            guard let first = loadingEarlier ? TimelineItems.loadingEarlierID : rows.first?.message.id else { return }
            // Where the content's top margin puts it when scrolled all the way up.
            place(first, top: Self.topMargin)
        case .bottom:
            scrollToNewest()
        }
        readerMoved()
        if key == .top || key == .pageUp { requestOlderIfNeeded() }
    }

    /// Moves the content by `delta` (positive moves it down, towards older messages). Each step goes through the
    /// laid-out row a scroll can carry furthest (`TimelineScrollPolicy.scrollStep`), and steps repeat (bringing new rows
    /// into layout) until the distance is covered or an end is reached.
    private func scroll(by delta: CGFloat) {
        var remaining = delta
        for _ in 0..<4 where abs(remaining) > 0.5 {
            guard let step = TimelineScrollPolicy.scrollStep(placedRows(), by: remaining, frameHeight: layout.height) else { return }
            place(step.row.id, top: step.top)
            guard let after = layout.frame(of: step.row.id)?.minY, abs(after - step.row.top) > 0.5 else { return }
            remaining -= after - step.row.top
        }
    }

    // MARK: Jumping to a message

    /// Scrolls to a message and tints it for a moment. A message older than the loaded window is paged in first, as far
    /// as the store and the server's archive go; a message that never turns up leaves the timeline where it was.
    func scrollTo(messageID id: String) {
        revealing?.cancel()
        revealing = Task { await reveal { id } }
    }

    /// Scrolls to the message a reply quotes, from the reference the reply carries (`TimelineReply.messageID`). The
    /// store resolves it to a stored message; one not stored yet is looked for again after each page of history.
    func scrollTo(quotedMessage reference: String) {
        revealing?.cancel()
        revealing = Task { [model, chatID] in await reveal { await model.quotedMessageID(reference, in: chatID) } }
    }

    private func reveal(_ resolve: () async -> String?) async {
        settlingAtOpen = false
        var target = await resolve()
        // Each round raises the window by a page or backfills a few archive pages; the window's ceiling bounds the rounds.
        // A round may bring nothing yet (a raised window over a store holding no more, before the archive is asked),
        // so only a few such rounds in a row, or the model saying nothing more can come, end the search.
        var idle = 0
        for _ in 0..<40 {
            guard !Task.isCancelled, model.messagesLoadedFor == chatID else { break }
            if let target, indexByID[target] != nil || model.messages.contains(where: { $0.id == target }) { break }
            let oldest = model.messages.first?.id
            let more = await model.loadOlderMessages()
            // A window raise has reloaded by now; an archive backfill pages in over time.
            let clock = ContinuousClock()
            var deadline = clock.now + .seconds(1)
            while model.messages.first?.id == oldest, !Task.isCancelled {
                if model.isBackfilling(chat: chatID) { deadline = clock.now + .seconds(1) }
                guard clock.now < deadline else { break }
                try? await Task.sleep(for: .milliseconds(100))
            }
            if model.messages.first?.id == oldest {
                idle += 1
                guard more, idle < 3 else { break }
            } else {
                idle = 0
                update()
            }
            if target == nil { target = await resolve() }
        }
        update()
        guard !Task.isCancelled, let id = target, indexByID[id] != nil, let proxy = layout.proxy else {
            #if DEBUG
            MacDebugHooks.log("timeline: \(target ?? "quoted message") not found")
            #endif
            return
        }
        proxy.scrollTo(id, anchor: .center)
        layout.forceLayout()
        if let frame = layout.frame(of: id) {
            // Centred below the toolbar, or at the top when taller.
            let centred = max(0, (layout.height - frame.height) / 2)
            place(id, top: TimelineScrollPolicy.reachableTop(centred, rowHeight: frame.height, frameHeight: layout.height))
        }
        readerMoved()
        highlight(id)
    }

    private func highlight(_ id: String) {
        highlightEnd?.cancel()
        highlightedID = id
        highlightEnd = Task { [weak self] in
            try? await Task.sleep(for: .seconds(1.2))
            guard !Task.isCancelled else { return }
            withAnimation(.easeOut(duration: 0.6)) { self?.highlightedID = nil }
        }
    }

    // MARK: Day chip

    /// Where the header capsule sits in a row that opens a day: the row's 2 pt top padding plus the header's 10.
    static let headerTop: CGFloat = 12
    static let chipHeight: CGFloat = 24
    /// Where the chip rests, just below the toolbar.
    static let chipLine: CGFloat = 8

    /// The chip shows while the reader scrolls and for a second after the timeline comes to rest.
    private func updateDayChip(force: Bool = false) {
        guard scrolling || force || dayChip != nil else { return }
        let rows = rows
        let chip = TimelineScrollPolicy.dayChip(rows: placedRows(), dayHeader: { rows[$0].dateHeader },
                                                line: Self.chipLine, headerTop: Self.headerTop, chipHeight: Self.chipHeight)
        guard chip != dayChip else { return }
        if (chip == nil) != (dayChip == nil) {
            withAnimation(.easeOut(duration: chip == nil ? 0.15 : 0.2)) { dayChip = chip }
        } else {
            dayChip = chip
        }
    }

    private func scheduleDayChipIdle() {
        dayChipIdle?.cancel()
        dayChipIdle = Task { [weak self] in
            try? await Task.sleep(for: .seconds(1))
            guard !Task.isCancelled, let self, !self.scrolling else { return }
            withAnimation(.easeOut(duration: 0.3)) { self.dayChip = nil }
        }
    }

    #if DEBUG
    /// The open chat's timeline, for the tour's scroll steps.
    static weak var current: MacTimelineController?

    /// Moves the content by `delta` points as a reader's scroll would (positive towards older messages), for the tour.
    func debugScroll(by delta: CGFloat) {
        scroll(by: delta)
        readerMoved()
    }
    #endif
}

/// One entry of the timeline's stack.
enum MacTimelineItem: Identifiable, Equatable {
    /// Above the oldest message while the server's older history is fetched.
    case loadingEarlier
    case message(TimelineRow)
    case typing(TimelineTyping)
    /// The end of the content, with the bottom margin inside it: scrolled to the bottom edge, the timeline is at its end.
    case end

    var id: String {
        switch self {
        case .loadingEarlier: TimelineItems.loadingEarlierID
        case .message(let row): row.message.id
        case .typing: TimelineItems.typingID
        case .end: MacTimelineController.endID
        }
    }
}

/// What the scroll view laid out, in the coordinates of its frame. SwiftUI lays the scroll view out below the toolbar;
/// content scrolled up under the toolbar has negative positions (the scroll geometry's top inset). Written from layout
/// callbacks and read by the controller; not observed, so writing never invalidates a view.
@MainActor final class MacTimelineLayout {
    /// The coordinate space rows report their frames in: the scroll view's frame.
    nonisolated static let space = "timeline"

    /// The last frame each row reported, by message ID (and the typing bubble, the loading row and the end spacer by
    /// theirs). A row reports only when its frame changes, so one that scrolls out and back to the same place reports
    /// nothing: frames are kept, and `shown` says which rows are laid out now.
    private var reported: [String: CGRect] = [:]
    /// The rows laid out now, each with the view instance that appeared last: the lazy stack may build a row again
    /// before the old instance's disappearance arrives, and that one must not hide the new one.
    private var shown: [String: UUID] = [:]
    var geometry: ScrollGeometry?
    var size: CGSize = .zero
    var proxy: ScrollViewProxy?
    /// A view inside the scroll view's content, for forcing a layout pass.
    weak var anchorView: NSView?

    /// The frames of the rows laid out now.
    var frames: [String: CGRect] { reported.filter { shown[$0.key] != nil } }

    func frame(of id: String) -> CGRect? { shown[id] == nil ? nil : reported[id] }

    func report(_ id: String, _ frame: CGRect) { reported[id] = frame }

    func appeared(_ id: String, instance: UUID) { shown[id] = instance }

    func disappeared(_ id: String, instance: UUID) {
        guard shown[id] == instance else { return }
        shown[id] = nil
    }

    var isAttached: Bool { proxy != nil && anchorView?.window != nil }

    /// The frame's height: what is on screen between the toolbar and whatever is below the timeline.
    var height: CGFloat { max(1, size.height) }

    /// From the newest content's bottom edge to the frame's bottom; zero or less at the end. Read from the laid-out end
    /// spacer, which is current right after a forced layout pass (the scroll geometry can lag a programmatic move).
    var distanceFromBottom: CGFloat {
        if let end = frame(of: MacTimelineController.endID) { return end.maxY - height }
        guard let geometry else { return .infinity }
        // The container is the frame, between the insets; the offset counts from above the top inset.
        return geometry.contentSize.height - geometry.contentOffset.y - geometry.contentInsets.top - geometry.containerSize.height
    }

    /// Runs SwiftUI's pending update and layout now, so the rows' frames are current before anything is corrected.
    func forceLayout() {
        var hosts: [NSView] = []
        var view = anchorView?.superview
        while let current = view {
            if NSStringFromClass(type(of: current)).contains("NSHostingView") { hosts.append(current) }
            view = current.superview
        }
        guard let root = hosts.last ?? anchorView?.window?.contentView else { return }
        for host in hosts { host.needsLayout = true }
        root.needsLayout = true
        root.layoutSubtreeIfNeeded()
    }
}

/// Hands the controller a view inside the scroll view's content, for forcing layout passes.
struct MacTimelineAnchor: NSViewRepresentable {
    let layout: MacTimelineLayout

    func makeNSView(context: Context) -> NSView {
        let view = NSView()
        layout.anchorView = view
        return view
    }

    func updateNSView(_ view: NSView, context: Context) { layout.anchorView = view }
}

/// Jumps to a quoted message in the open conversation's timeline. Equal while it targets the same timeline, so setting
/// it again on each update never invalidates the bubbles that read it.
struct OpenQuotedMessage: Equatable {
    weak var timeline: MacTimelineController?

    /// `reference` is the quote's `TimelineReply.messageID`.
    @MainActor func callAsFunction(_ reference: String) { timeline?.scrollTo(quotedMessage: reference) }

    static func == (left: Self, right: Self) -> Bool { left.timeline === right.timeline }
}

extension EnvironmentValues {
    @Entry var openQuotedMessage = OpenQuotedMessage()
}
