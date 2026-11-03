import AppKit
import SwiftUI

// Owns the open chat's rows and what the bars and menus read; `MacTimelineTableController` shows them. Each observed
// change reaches the table in a main-queue turn of its own, and the table measures, applies and positions in one turn
// (`commit`). Search and the starred filter load the whole stored history and never page.
@MainActor @Observable final class MacTimelineController {
    private(set) var isLoaded = false
    private(set) var items: [MacTimelineItem] = []
    @ObservationIgnored private(set) var rows: [TimelineRow] = []
    @ObservationIgnored private(set) var typing: TimelineTyping?
    @ObservationIgnored private(set) var loadingEarlier = false
    private(set) var isGroup = false
    // This and `dayChip` change from scroll and resize callbacks, so their views use `.animation(_:value:)`, never
    // `withAnimation`: an animated transaction during a window resize made SwiftUI re-widen the window every frame
    // until AppKit aborted.
    private(set) var showsJumpToNewest = false
    private(set) var highlightedID: String?
    private(set) var dayChip: TimelineScrollPolicy.DayChip?
    @ObservationIgnored private(set) var dayChipFade = 0.2
    private(set) var searching = false
    private(set) var query = ""
    private(set) var starredOnly = false
    private(set) var loadingAll = false
    // Kept when focus moves elsewhere, so coming back finds it.
    private(set) var focusedID: String?
    private(set) var hasKeyboardFocus = false
    @ObservationIgnored var onEscape: () -> Void = {}
    @ObservationIgnored var onTab: () -> Void = {}
    @ObservationIgnored var onShown: (TimelineMessage) -> Void = { _ in }
    @ObservationIgnored var onHidden: (String) -> Void = { _ in }

    @ObservationIgnored let table: MacTimelineTableController
    @ObservationIgnored private let model: AppModel
    @ObservationIgnored private let chatID: String
    @ObservationIgnored private let makePresenter: () -> ConversationPresenter
    @ObservationIgnored private var indexByID: [String: Int] = [:]
    @ObservationIgnored private var olderRequests = TimelineScrollPolicy.OlderHistoryRequests()
    // Only the latest registered observation applies, so an out-of-turn update leaves no second chain of observations.
    @ObservationIgnored private var observation = 0
    @ObservationIgnored private var readerMovedAt: ContinuousClock.Instant?
    @ObservationIgnored private var dayChipIdle: Task<Void, Never>?
    @ObservationIgnored private var highlightEnd: Task<Void, Never>?
    @ObservationIgnored private var revealing: Task<Void, Never>?
    @ObservationIgnored private var unfilteredPlace: MacTimelinePlace?
    @ObservationIgnored private var loadingAllTask: Task<Void, Never>?

    static let topMargin: CGFloat = 12

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

    // Called by the table as it commits, so what the bars and menus read never runs ahead of the screen.
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

    // Off the main thread, newest first, so rows built later read the links from `LinkScan`'s cache.
    private static func findLinks(in rows: [TimelineRow]) {
        let texts = rows.reversed().compactMap { $0.message.showsPlaceholder ? nil : $0.message.body }
        Task.detached(priority: .utility) {
            for text in texts { _ = LinkScan.links(in: text) }
        }
    }

    func update() {
        let next = observe()
        guard next != content || table.isApplying else { return }
        table.update(next)
    }

    func placement(for next: MacTimelineContent, wasNearBottom: Bool) -> TimelineScrollPolicy.Update.Placement {
        TimelineScrollPolicy.Update(previousTailID: rows.last?.message.id, rows: next.rows, wasNearBottom: wasNearBottom,
                                    typingChanged: typing != next.typing, typingLeft: typing != nil && next.typing == nil,
                                    canAnimate: false).placement
    }

    func setShowsJumpToNewest(_ shows: Bool) {
        guard shows != showsJumpToNewest else { return }
        showsJumpToNewest = shows
    }

    func scrolled(byReader: Bool, moving: Bool) {
        if byReader { requestOlderIfNeeded(byReader: true) }
        if moving || dayChip != nil { updateDayChip() }
    }

    func scrollEnded() { scheduleDayChipIdle() }

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

    // Counts as the reader's scroll for paging; no day chip when it only revealed a focused message the chip would
    // cover.
    private func readerMoved(showingDayChip: Bool = true) {
        readerMovedAt = .now
        table.noteReaderMoved()
        guard showingDayChip else { return }
        dayChipIdle?.cancel()
        updateDayChip(force: true)
        scheduleDayChipIdle()
    }

    enum KeyScroll { case pageUp, pageDown, top, bottom }

    // Page Up and Page Down keep a line of overlap, so the line at the edge stays in view; Home also asks for older
    // history.
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

    // A message older than the loaded window is paged in first, as far as the store and archive go; one that never
    // turns up leaves the timeline where it was. Filters close first: a result is shown in the whole conversation.
    func scrollTo(messageID id: String) {
        clearFilter()
        revealing?.cancel()
        revealing = Task { await reveal { id } }
    }

    // A quoted message not stored yet is looked for again after each page of history.
    func scrollTo(quotedMessage reference: String) {
        clearFilter()
        revealing?.cancel()
        revealing = Task { [model, chatID] in await reveal { await model.quotedMessageID(reference, in: chatID) } }
    }

    private func reveal(_ resolve: () async -> String?) async {
        var target = await resolve()
        // Each round raises the window a page or backfills archive pages, bounded by the window's ceiling. A round may
        // bring nothing yet, so only several empty rounds in a row, or the model saying nothing more can come, end the
        // search.
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

    var isFiltered: Bool { searching || starredOnly }

    private var searchTerm: String { searching ? query.trimmingCharacters(in: .whitespacesAndNewlines) : "" }

    func filtered(_ presenter: ConversationPresenter) -> ConversationPresenter {
        var presenter = presenter
        presenter.showingSearch = searching
        presenter.searchTerm = searchTerm
        presenter.starredOnly = starredOnly
        return presenter
    }

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

    // Closing search keeps the starred filter on, as on the iPhone.
    func closeFilter() {
        if searching { setSearching(false) } else { setStarredOnly(false) }
    }

    func clearFilter() {
        guard isFiltered else { return }
        searching = false
        query = ""
        starredOnly = false
        refilter(wasFiltered: true)
    }

    // A filtered list opens at its newest match; the whole timeline comes back with the reader's row where it was.
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

    // `loadOlderMessages` answers true without loading while a page is already coming in, so it is asked until the
    // window is at its ceiling.
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

    // The row's 2 pt top padding plus the header's 10.
    static let headerTop: CGFloat = 12
    static let chipHeight: CGFloat = 24
    static let chipLine: CGFloat = 8

    private func updateDayChip(force: Bool = false) {
        guard readerIsScrolling || force || dayChip != nil else { return }
        let rows = rows
        let chip = TimelineScrollPolicy.dayChip(rows: table.placedRows(), dayHeader: { rows[$0].dateHeader },
                                                line: Self.chipLine, headerTop: Self.headerTop, chipHeight: Self.chipHeight)
        guard chip != dayChip else { return }
        if (chip == nil) != (dayChip == nil) { dayChipFade = chip == nil ? 0.15 : 0.2 }
        dayChip = chip
    }

    private func scheduleDayChipIdle() {
        dayChipIdle?.cancel()
        dayChipIdle = Task { [weak self] in
            try? await Task.sleep(for: .seconds(1))
            guard !Task.isCancelled, let self, !self.table.isLiveScrolling else { return }
            self.dayChipFade = 0.3
            self.dayChip = nil
        }
    }

    static let focusMargin: CGFloat = 12

    // Tabbing in focuses the newest message in view, so Return acts at once; a click leaves the ring off until an arrow
    // key.
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

    // `id` is a bubble whose text had the keys. Up at the oldest loaded message asks for older history, as a scroll
    // does.
    func moveFocus(forward: Bool, from id: String? = nil) {
        let ids = rows.map(\.message.id)
        guard let next = TimelineMessageFocus.step(from: id ?? focusedID, forward: forward, ids: ids, placed: table.placedRows(), frameHeight: table.frameHeight) else { return }
        setFocused(next)
        reveal(next)
        readerMoved(showingDayChip: false)
        if !forward { requestOlderIfNeeded(byReader: true) }
    }

    func reveal(_ id: String) {
        table.reveal(id, margin: Self.focusMargin)
    }

    func openFocusedMenu() -> Bool {
        guard let focusedID, indexByID[focusedID] != nil else { return false }
        openMenu(for: focusedID)
        return true
    }

    func openMenu(for id: String) {
        setFocused(id)
        reveal(id)
        // Not inside the key's handling: the menu runs its own event loop.
        DispatchQueue.main.async { MainActor.assumeIsolated { self.table.openMenu(for: id) } }
    }

    func requestKeyboardFocus() { table.takeKeyboardFocus() }

    func bubbleTextFocused(_ id: String) {
        setFocused(id)
    }

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
    static weak var current: MacTimelineController?

    // An unobtrusive run's window is never key, so focus is given directly and reported as Tab would.
    func debugFocusByKey() {
        requestKeyboardFocus()
        keyboardFocusChanged(true, byKey: true)
    }

    // Positive moves towards older messages.
    func debugScroll(by delta: CGFloat) {
        table.scroll(by: delta)
        readerMoved()
    }

    func debugLoadOlder() async {
        _ = await model.loadOlderMessages()
    }

    // Drives the table's live-scroll state as the scroll view's notifications would.
    func debugLiveScroll(_ scrolling: Bool) {
        table.debugLiveScroll(scrolling)
    }
    #endif
}

struct MacTimelineContent: Equatable {
    var isLoaded = false
    var rows: [TimelineRow] = []
    var typing: TimelineTyping?
    var loadingEarlier = false
    var isGroup = false
}

enum MacTimelinePlace: Equatable {
    case newest
    case row(id: String, top: CGFloat)
}

enum MacTimelineItem: Identifiable, Equatable {
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
