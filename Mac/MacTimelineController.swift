import AppKit
import SwiftUI

/// The open chat's timeline: the rows it shows, what the conversation's bars and menus read from it (the jump button,
/// the day chip, search and the starred filter, the message with keyboard focus), and the decisions the shared policies
/// make (`TimelineScrollPolicy`, `TimelineMessageFocus`). The table (`MacTimelineTableController`) shows the rows and
/// keeps the reader where these decisions say.
///
/// - **Updates.** The controller observes what the rows are built from and hands each change to the table in a
///   main-queue turn of its own; the table measures the new rows, then applies the change and positions the timeline in
///   one turn (`commit`). An arriving message follows a reader who was at the newest message or sent it; anywhere else
///   the reader's rows stay exactly where they are.
/// - **Paging**: older history is asked for when the reader's own scroll (or a key) comes within two screens of the
///   oldest loaded message (`TimelineScrollPolicy.OlderHistoryRequests`).
/// - **Search and the starred filter** list a slice of the chat, as on the iPhone (`ConversationPresenter`): opening one
///   asks for the whole history the store keeps, never pages, and closing it puts the reader back where they were.
@MainActor @Observable final class MacTimelineController {
    /// This chat's first page is loaded.
    private(set) var isLoaded = false
    /// What the table lists, oldest first: the loading row, the messages and the typing bubble.
    private(set) var items: [MacTimelineItem] = []
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
    /// Search is open: the timeline lists the messages whose text contains `query`, all of them while it is blank.
    private(set) var searching = false
    /// The search field's text as typed.
    private(set) var query = ""
    /// Only starred messages are listed; with search, the starred ones that match.
    private(set) var starredOnly = false
    /// A filter opened and the store is asked for the whole history it may list.
    private(set) var loadingAll = false
    /// The message the arrow keys moved to, ringed while the timeline has keyboard focus. Kept when focus moves
    /// elsewhere, so coming back finds it.
    private(set) var focusedID: String?
    /// The timeline, or a bubble's text in it, has keyboard focus.
    private(set) var hasKeyboardFocus = false
    /// Esc in the timeline or in a bubble's text: the conversation moves keyboard focus to the composer.
    @ObservationIgnored var onEscape: () -> Void = {}
    /// Tab in the timeline: the conversation moves keyboard focus on to the composer.
    @ObservationIgnored var onTab: () -> Void = {}
    /// Messages coming into sight and leaving it, for read markers and fetches on display.
    @ObservationIgnored var onShown: (TimelineMessage) -> Void = { _ in }
    @ObservationIgnored var onHidden: (String) -> Void = { _ in }

    @ObservationIgnored let table: MacTimelineTableController
    @ObservationIgnored private let model: AppModel
    @ObservationIgnored private let chatID: String
    @ObservationIgnored private let makePresenter: () -> ConversationPresenter
    @ObservationIgnored private var indexByID: [String: Int] = [:]
    @ObservationIgnored private var olderRequests = TimelineScrollPolicy.OlderHistoryRequests()
    /// Counts the observations registered: only the latest one's change applies an update, so an update applied out of
    /// turn never leaves a second chain of observations behind.
    @ObservationIgnored private var observation = 0
    @ObservationIgnored private var readerMovedAt: ContinuousClock.Instant?
    @ObservationIgnored private var dayChipIdle: Task<Void, Never>?
    @ObservationIgnored private var highlightEnd: Task<Void, Never>?
    @ObservationIgnored private var revealing: Task<Void, Never>?
    /// Where the reader was in the whole timeline when a filter opened, to return to when the last one closes.
    @ObservationIgnored private var unfilteredPlace: MacTimelinePlace?
    @ObservationIgnored private var loadingAllTask: Task<Void, Never>?

    /// The content's margin above the oldest row and below the newest.
    static let topMargin: CGFloat = 12

    /// `presenter` builds the conversation's presenter; everything it reads is observed, and a change is applied in the
    /// next main-queue turn.
    init(model: AppModel, chatID: String, presenter: @escaping () -> ConversationPresenter) {
        self.model = model
        self.chatID = chatID
        makePresenter = presenter
        table = MacTimelineTableController()
        table.timeline = self
        let content = observe()
        apply(content)
        table.reload(content, at: .newest)
        #if DEBUG
        Self.current = self
        #endif
    }

    // MARK: Updates

    /// Builds the content and observes everything it read; the first change to any of it schedules an update, unless
    /// a later call has registered its own observation since.
    private func observe() -> MacTimelineContent {
        observation += 1
        let token = observation
        return withObservationTracking {
            guard model.messagesLoadedFor == chatID else { return MacTimelineContent() }
            let presenter = filtered(makePresenter())
            return MacTimelineContent(isLoaded: true, rows: TimelineItems.rows(for: presenter.timelineMessages), typing: presenter.typing,
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

    var content: MacTimelineContent {
        MacTimelineContent(isLoaded: isLoaded, rows: rows, typing: typing, loadingEarlier: loadingEarlier, isGroup: isGroup)
    }

    /// Takes the content the table now shows. The table calls this as it commits a change, so what the bars and menus
    /// read never runs ahead of what is on screen.
    func apply(_ content: MacTimelineContent) {
        if content.rows != rows || content.typing != typing || content.loadingEarlier != loadingEarlier {
            if content.rows != rows {
                indexByID = Dictionary(content.rows.enumerated().map { ($1.message.id, $0) }, uniquingKeysWith: { first, _ in first })
                Self.findLinks(in: content.rows)
            }
            rows = content.rows
            typing = content.typing
            loadingEarlier = content.loadingEarlier
            items = (loadingEarlier ? [.loadingEarlier] : []) + rows.map(MacTimelineItem.message) + (typing.map { [.typing($0)] } ?? [])
        }
        if content.isGroup != isGroup { isGroup = content.isGroup }
        if content.isLoaded != isLoaded { isLoaded = content.isLoaded }
    }

    /// Finds the rows' links (`TimelineMessage.links`) away from the main thread, newest first, so a row built later
    /// reads them from `LinkScan`'s cache.
    private static func findLinks(in rows: [TimelineRow]) {
        let texts = rows.reversed().compactMap { $0.message.showsPlaceholder ? nil : $0.message.body }
        Task.detached(priority: .utility) {
            for text in texts { _ = LinkScan.links(in: text) }
        }
    }

    /// Hands the model's current content to the table, which applies it and keeps the reader where the policy says.
    func update() {
        let next = observe()
        guard next != content || table.isApplying else { return }
        table.update(next)
    }

    /// Where an update puts the reader: at the newest message when they were at it (or sent the message), else where
    /// they are.
    func placement(for next: MacTimelineContent, wasNearBottom: Bool) -> TimelineScrollPolicy.Update.Placement {
        TimelineScrollPolicy.Update(previousTailID: rows.last?.message.id, rows: next.rows, wasNearBottom: wasNearBottom,
                                    typingChanged: typing != next.typing, typingLeft: typing != nil && next.typing == nil,
                                    canAnimate: false).placement
    }

    // MARK: What the table reports

    func setShowsJumpToNewest(_ shows: Bool) {
        guard shows != showsJumpToNewest else { return }
        withAnimation(.easeOut(duration: 0.2)) { showsJumpToNewest = shows }
    }

    /// The reader's scroll moved the timeline: paging, and the day chip while it moves and for a second after.
    func scrolled(byReader: Bool, moving: Bool) {
        if byReader { requestOlderIfNeeded(byReader: true) }
        if moving || dayChip != nil { updateDayChip() }
    }

    func scrollEnded() { scheduleDayChipIdle() }

    /// The reader's own scroll, or a key or jump within the last half second.
    var readerIsScrolling: Bool {
        table.isLiveScrolling || readerMovedAt.map { ContinuousClock.now - $0 < .milliseconds(500) } ?? false
    }

    private func requestOlderIfNeeded(byReader: Bool) {
        // A filtered list ends where the loaded history ends; it never pages.
        guard !isFiltered, olderRequests.shouldRequest(oldestID: rows.first?.message.id, distanceFromTop: table.distanceFromTop,
                                                       viewportHeight: table.frameHeight, byReader: byReader) else { return }
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

    /// A key or a jump moved the timeline: it counts as the reader's scroll for paging and shows the day chip, unless
    /// it only brought a focused message into view, which the chip would cover.
    private func readerMoved(showingDayChip: Bool = true) {
        readerMovedAt = .now
        table.noteReaderMoved()
        guard showingDayChip else { return }
        dayChipIdle?.cancel()
        updateDayChip(force: true)
        scheduleDayChipIdle()
    }

    enum KeyScroll { case pageUp, pageDown, top, bottom }

    /// Page Up and Page Down move by the visible height less a line of overlap, so the line that was at the edge stays
    /// in view; Home goes to the oldest loaded message (and asks for older history), End to the newest.
    func scroll(_ key: KeyScroll) {
        let page = max(40, table.frameHeight - 40)
        switch key {
        case .pageUp: table.scroll(by: page)
        case .pageDown: table.scroll(by: -page)
        case .top: table.scrollToOldest()
        case .bottom: table.scrollToNewest()
        }
        readerMoved()
        if key == .top || key == .pageUp { requestOlderIfNeeded(byReader: true) }
    }

    // MARK: Jumping to a message

    /// Scrolls to a message and tints it for a moment. A message older than the loaded window is paged in first, as far
    /// as the store and the server's archive go; a message that never turns up leaves the timeline where it was. Search
    /// and the starred filter close first: a result is shown in the whole conversation.
    func scrollTo(messageID id: String) {
        clearFilter()
        revealing?.cancel()
        revealing = Task { await reveal { id } }
    }

    /// Scrolls to the message a reply quotes, from the reference the reply carries (`TimelineReply.messageID`). The
    /// store resolves it to a stored message; one not stored yet is looked for again after each page of history.
    func scrollTo(quotedMessage reference: String) {
        clearFilter()
        revealing?.cancel()
        revealing = Task { [model, chatID] in await reveal { await model.quotedMessageID(reference, in: chatID) } }
    }

    private func reveal(_ resolve: () async -> String?) async {
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
                await settle()
            }
            if target == nil { target = await resolve() }
        }
        await settle()
        guard !Task.isCancelled, let id = target, indexByID[id] != nil else {
            #if DEBUG
            MacDebugHooks.log("timeline: \(target ?? "quoted message") not found")
            #endif
            return
        }
        table.center(id)
        readerMoved()
        highlight(id)
    }

    /// Applies the model's content now and waits for the table to show it.
    private func settle() async {
        update()
        for _ in 0..<50 where table.isApplying {
            try? await Task.sleep(for: .milliseconds(10))
        }
    }

    private func highlight(_ id: String) {
        highlightEnd?.cancel()
        highlightedID = id
        table.highlightChanged()
        highlightEnd = Task { [weak self] in
            try? await Task.sleep(for: .seconds(1.2))
            guard !Task.isCancelled, let self else { return }
            self.highlightedID = nil
            self.table.highlightChanged()
        }
    }

    // MARK: Search and starred

    var isFiltered: Bool { searching || starredOnly }

    /// What search matches: the field's text without its surrounding spaces.
    private var searchTerm: String { searching ? query.trimmingCharacters(in: .whitespacesAndNewlines) : "" }

    /// What the presenter lists under the open filters.
    func filtered(_ presenter: ConversationPresenter) -> ConversationPresenter {
        var presenter = presenter
        presenter.showingSearch = searching
        presenter.searchTerm = searchTerm
        presenter.starredOnly = starredOnly
        return presenter
    }

    /// Opens or closes search; closing it empties the field, as on the iPhone.
    func setSearching(_ on: Bool) {
        guard on != searching else { return }
        let wasFiltered = isFiltered
        searching = on
        if !on { query = "" }
        refilter(wasFiltered: wasFiltered)
    }

    func setQuery(_ text: String) {
        guard searching, text != query else { return }
        let before = searchTerm
        query = text
        if searchTerm != before { refilter(wasFiltered: true) }
    }

    func setStarredOnly(_ on: Bool) {
        guard on != starredOnly else { return }
        let wasFiltered = isFiltered
        starredOnly = on
        refilter(wasFiltered: wasFiltered)
    }

    /// Esc: closes search, as its Done does, or with search closed the starred filter, as its Show All does. Closing
    /// search keeps the starred filter on, as on the iPhone.
    func closeFilter() {
        if searching { setSearching(false) } else { setStarredOnly(false) }
    }

    /// Closes search and the starred filter together.
    func clearFilter() {
        guard isFiltered else { return }
        searching = false
        query = ""
        starredOnly = false
        refilter(wasFiltered: true)
    }

    /// Lists what the filters now select. A filtered list opens at its newest match, as the chat opens at its newest
    /// message; the whole timeline comes back with the reader's row where it was when the first filter opened.
    private func refilter(wasFiltered: Bool) {
        if !wasFiltered, isFiltered {
            unfilteredPlace = table.readerPlace()
            loadAllHistory()
        }
        let next = observe()
        let restore = isFiltered ? nil : unfilteredPlace
        if !isFiltered { unfilteredPlace = nil }
        table.context.isFiltered = isFiltered
        apply(next)
        table.reload(next, at: restore ?? .newest)
        updateDayChip()
    }

    /// Search and the starred filter read the loaded messages, so they need the whole window rather than the newest
    /// pages, as on the iPhone. `loadOlderMessages` answers true without loading while a page is already coming in, so
    /// it is asked until it says the window is at its ceiling.
    private func loadAllHistory() {
        guard loadingAllTask == nil else { return }
        loadingAll = true
        loadingAllTask = Task { [model, chatID] in
            for _ in 0..<100 {
                guard !Task.isCancelled, isFiltered else { break }
                if model.messagesLoadedFor == chatID, await !model.loadOlderMessages(all: true) { break }
                try? await Task.sleep(for: .milliseconds(100))
            }
            loadingAll = false
            loadingAllTask = nil
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
        guard readerIsScrolling || force || dayChip != nil else { return }
        let rows = rows
        let chip = TimelineScrollPolicy.dayChip(rows: table.placedRows(), dayHeader: { rows[$0].dateHeader },
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
            guard !Task.isCancelled, let self, !self.table.isLiveScrolling else { return }
            withAnimation(.easeOut(duration: 0.3)) { self.dayChip = nil }
        }
    }

    // MARK: Keyboard focus

    /// How far a focused message keeps from the frame's edges when a key brings it into view.
    static let focusMargin: CGFloat = 12

    /// The timeline (or a bubble's text in it) gained or lost keyboard focus. Tabbing in focuses the newest message in
    /// view, so Return acts at once and the ring shows where the keys start; a click leaves the ring off until an arrow
    /// key.
    func keyboardFocusChanged(_ focused: Bool, byKey: Bool) {
        if hasKeyboardFocus != focused { hasKeyboardFocus = focused }
        table.focusChanged()
        guard focused, byKey, !table.isOnScreen(focusedID) else { return }
        setFocused(TimelineMessageFocus.step(from: nil, forward: false, ids: rows.map(\.message.id), placed: table.placedRows(), frameHeight: table.frameHeight))
    }

    private func setFocused(_ id: String?) {
        guard id != focusedID else { return }
        focusedID = id
        table.focusChanged()
    }

    /// Up or Down: focuses the message before or after the focused one (or `id`, a bubble whose text had the keys) and
    /// scrolls it into view. Up at the oldest loaded message asks for older history, as a scroll there does.
    func moveFocus(forward: Bool, from id: String? = nil) {
        let ids = rows.map(\.message.id)
        guard let next = TimelineMessageFocus.step(from: id ?? focusedID, forward: forward, ids: ids, placed: table.placedRows(), frameHeight: table.frameHeight) else { return }
        setFocused(next)
        reveal(next)
        readerMoved(showingDayChip: false)
        if !forward { requestOlderIfNeeded(byReader: true) }
    }

    /// Scrolls just far enough to show the whole row, or its start when it is taller than the frame.
    func reveal(_ id: String) {
        table.reveal(id, margin: Self.focusMargin)
    }

    /// Return or Space: the focused message's menu, below its bubble. False with no focused message listed.
    func openFocusedMenu() -> Bool {
        guard let focusedID, indexByID[focusedID] != nil else { return false }
        openMenu(for: focusedID)
        return true
    }

    /// Focuses the message and opens its menu below its bubble: Return or Space, or VoiceOver's Show Menu on the row.
    func openMenu(for id: String) {
        setFocused(id)
        reveal(id)
        // Not inside the key's handling: the menu runs its own event loop.
        DispatchQueue.main.async { MainActor.assumeIsolated { self.table.openMenu(for: id) } }
    }

    /// Gives the timeline keyboard focus: Shift-Tab from the composer and Tab from the find field come here.
    func requestKeyboardFocus() { table.takeKeyboardFocus() }

    /// A bubble's text took keyboard focus (a click, Select Text): the keys go on from that message.
    func bubbleTextFocused(_ id: String) {
        setFocused(id)
    }

    /// A key that a bubble's text passed on: Up and Down give the timeline keyboard focus and move on from that bubble,
    /// the scrolling keys scroll the timeline, and Esc goes to the composer.
    func bubbleTextKey(_ key: MacTimelineKey, in id: String) {
        switch key {
        case .scroll(let move):
            scroll(move)
        case .focus(let forward):
            requestKeyboardFocus()
            moveFocus(forward: forward, from: id)
        case .escape:
            onEscape()
        }
    }

    #if DEBUG
    /// The open chat's timeline, for the tour's scroll steps.
    static weak var current: MacTimelineController?

    /// The window of an unobtrusive run is never key: this gives the timeline focus and makes the report Tab into it
    /// would make.
    func debugFocusByKey() {
        requestKeyboardFocus()
        keyboardFocusChanged(true, byKey: true)
    }

    /// Moves the content by `delta` points as a reader's scroll would (positive towards older messages), for the tour.
    func debugScroll(by delta: CGFloat) {
        table.scroll(by: delta)
        readerMoved()
    }

    /// Asks for the next older page where the reader is, as reaching the paging lead would, for the tour.
    func debugLoadOlder() async {
        _ = await model.loadOlderMessages()
    }

    /// A sweep standing in for the reader's gesture (`MacDebugHooks.ScrollProbe` with `paging`).
    func debugReaderScrolling(_ scrolling: Bool) {
        table.debugReaderScrolling = scrolling
        if !scrolling { scrollEnded() }
    }
    #endif
}

/// What the timeline shows, oldest first.
struct MacTimelineContent: Equatable {
    var isLoaded = false
    var rows: [TimelineRow] = []
    var typing: TimelineTyping?
    var loadingEarlier = false
    var isGroup = false
}

/// Where the reader is, to come back to: the newest message, or a message's top edge this far below the frame's top.
enum MacTimelinePlace: Equatable {
    case newest
    case row(id: String, top: CGFloat)
}

/// One entry of the timeline, oldest first.
enum MacTimelineItem: Identifiable, Equatable {
    /// Above the oldest message while the server's older history is fetched.
    case loadingEarlier
    case message(TimelineRow)
    case typing(TimelineTyping)

    var id: String {
        switch self {
        case .loadingEarlier: TimelineItems.loadingEarlierID
        case .message(let row): row.message.id
        case .typing: TimelineItems.typingID
        }
    }
}
