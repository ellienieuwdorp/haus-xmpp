import AppKit
import SwiftUI

/// The main window's split view: chats in the sidebar, the open chat as the content, and its details in an inspector.
/// Each pane is SwiftUI in a hosting controller that reports no sizes of its own (`sizingOptions` empty): the items'
/// thicknesses below are the only minimums, so a resize of the window lays each pane out once, at its new size, and
/// nothing SwiftUI measures can move a divider or the window's minimum.
@MainActor final class MacSplitController: NSSplitViewController {
    /// The sidebar's width range; it starts at `sidebarWidth.ideal`, then keeps the width it is given.
    static let sidebarWidth = (min: 260.0, ideal: 320.0, max: 360.0)
    /// Fixed, as the inspector is on the Mac.
    static let inspectorWidth = 320.0
    /// The narrowest the conversation gets: the composer, a bubble and its reactions still fit.
    static let conversationMinWidth = 320.0
    static let windowMinWidth = 720.0
    static let windowMinHeight = 480.0

    private let model: AppModel
    private let state: MacWindowState
    private var sidebarItem: NSSplitViewItem!
    private var inspectorItem: NSSplitViewItem!
    private var content: MacContentController!
    private var collapseObservation: NSKeyValueObservation?
    /// The inspector is opening or closing; a change of the window's state meanwhile waits until it has finished. AppKit's
    /// collapse animations do not take over from each other: an open that interrupts a close, which shrinks the window
    /// back, leaves the conversation's width pinned, and the window can no longer be resized.
    private var animatingInspector = false
    /// The inspector is being put in the window (`insertInspector`): its collapse changes nothing in the window's state.
    private var insertingInspector = false

    init(model: AppModel, state: MacWindowState) {
        self.model = model
        self.state = state
        super.init(nibName: nil, bundle: nil)
    }

    @available(*, unavailable) required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }

    private var showsInspector: Bool { state.inspectorShown && state.selection != nil }

    override func viewDidLoad() {
        let model = model, state = state
        let sidebar = Self.host(MacPane { MacChatList(model: model, window: state).id(model.accountID) })
        sidebar.view.frame.size.width = Self.sidebarWidth.ideal
        // The content pane alone gives the window its title and subtitle: the open chat's name and status line.
        content = MacContentController(host: Self.host(MacPane { MacDetailPane(model: model, window: state) }, bridging: [.title]))
        let inspector = MacInspectorController(model: model, state: state)

        sidebarItem = NSSplitViewItem(sidebarWithViewController: sidebar)
        sidebarItem.minimumThickness = Self.sidebarWidth.min
        sidebarItem.maximumThickness = Self.sidebarWidth.max
        // A narrower window stops at its minimum instead of folding the chats away.
        sidebarItem.canCollapseFromWindowResize = false
        let contentItem = NSSplitViewItem(viewController: content)
        contentItem.minimumThickness = Self.conversationMinWidth
        inspectorItem = NSSplitViewItem(inspectorWithViewController: inspector)
        inspectorItem.minimumThickness = Self.inspectorWidth
        inspectorItem.maximumThickness = Self.inspectorWidth
        inspectorItem.canCollapse = true
        inspectorItem.isCollapsed = !showsInspector
        addSplitViewItem(sidebarItem)
        addSplitViewItem(contentItem)
        addSplitViewItem(inspectorItem)
        super.viewDidLoad()
        splitView.autosaveName = MacMainWindowController.autosaveName + " Split"
        // Only once the item is in the split view: added before, AppKit installs the accessory's constraints on a view
        // outside its subtree and throws.
        sidebarItem.addTopAlignedAccessoryViewController(MacSidebarSearch(state: state))
        // The autosave restores the inspector as it was saved; whether it shows is the window's state.
        inspectorItem.isCollapsed = !showsInspector

        // The inspector follows the window's state; a collapse that came another way (View > Hide Inspector) goes back
        // into it.
        MacObservation.track(self) { split in split.applyInspector() }
        // Find Chat brings a folded sidebar back for its search field.
        MacObservation.track(self) { split in
            if split.state.searchRequests > 0, split.sidebarItem.isCollapsed { split.sidebarItem.animator().isCollapsed = false }
        }
        #if DEBUG
        // Each of the inspector's animation frames resizes the split view's items.
        NotificationCenter.default.addObserver(forName: NSSplitView.didResizeSubviewsNotification, object: splitView, queue: nil) { _ in
            MainActor.assumeIsolated { MacPerfProbe.count("split.resize") }
        }
        #endif
        collapseObservation = inspectorItem.observe(\.isCollapsed) { [weak self] _, _ in
            MainActor.assumeIsolated {
                guard let self, !self.insertingInspector else { return }
                let collapsed = self.inspectorItem.isCollapsed
                guard collapsed == self.showsInspector else { return }
                if collapsed { self.state.inspectorShown = false } else if self.state.selection != nil { self.state.inspectorShown = true }
            }
        }
    }

    override func viewDidAppear() {
        super.viewDidAppear()
        insertInspector()
    }

    /// A split view leaves an item that starts collapsed out of the window until it first expands, and the closed
    /// inspector can build a chat's details ahead only in the window (`MacInspectorController`). It expands and collapses
    /// once, unanimated and before anything is drawn, if the window is wide enough to take it without growing.
    private func insertInspector() {
        guard inspectorItem.isCollapsed, inspectorItem.viewController.view.window == nil,
              splitView.bounds.width >= (sidebarItem.isCollapsed ? 0 : sidebarItem.viewController.view.frame.width)
                + Self.conversationMinWidth + Self.inspectorWidth else { return }
        insertingInspector = true
        defer { insertingInspector = false }
        inspectorItem.isCollapsed = false
        splitView.layoutSubtreeIfNeeded()
        inspectorItem.isCollapsed = true
        splitView.layoutSubtreeIfNeeded()
    }

    private static func host<Content: View>(_ view: Content, bridging: NSHostingSceneBridgingOptions = []) -> NSHostingController<Content> {
        let host = NSHostingController(rootView: view)
        host.sizingOptions = []
        host.sceneBridgingOptions = bridging
        return host
    }

    private func applyInspector() {
        let shows = showsInspector
        guard !animatingInspector, inspectorItem.isCollapsed == shows else { return }
        guard view.window?.isVisible == true else {
            inspectorItem.isCollapsed = !shows
            inspectorSettled()
            return
        }
        // Opening, the conversation keeps the width it has while the column slides in over its trailing side, and is
        // laid out at its new width once, as the animation ends, not on each of its frames. Closing, it follows the
        // column: held wider than its pane then, it kept AppKit from animating the next open.
        content.heldWidth = shows ? content.view.bounds.width : nil
        animatingInspector = true
        NSAnimationContext.runAnimationGroup { _ in
            inspectorItem.animator().isCollapsed = !shows
        } completionHandler: { [weak self] in
            MainActor.assumeIsolated {
                guard let self else { return }
                self.animatingInspector = false
                self.content.heldWidth = nil
                self.inspectorSettled()
                // Shown or hidden again while it ran: only the latest state is animated to.
                self.applyInspector()
            }
        }
    }

    /// AppKit's inspector toggle, should anything send it, goes through the window's state, as the toolbar's Chat Details
    /// does: it gets the same hold, and no empty column shows without a chat.
    override func toggleInspector(_ sender: Any?) {
        if inspectorItem.isCollapsed { state.inspectorShown = state.selection != nil } else { state.inspectorShown = false }
    }

    /// A pushed page stays in the closed inspector until it has finished closing; then it opens on the chat's details
    /// again.
    private func inspectorSettled() {
        guard inspectorItem.isCollapsed, !showsInspector, !state.inspectorPath.isEmpty else { return }
        state.inspectorPath.removeAll()
    }
}

/// The conversation's pane: its hosting controller's view fills it, except while the inspector opens. Then it keeps the
/// width it had (`heldWidth`), and the pane clips it at the inspector's side; a hosting view laid out at each width of
/// the animation would run the conversation's layout on every frame.
@MainActor final class MacContentController: NSViewController {
    private let host: NSViewController
    var heldWidth: CGFloat? {
        didSet { if heldWidth != oldValue { view.needsLayout = true } }
    }

    init(host: NSViewController) {
        self.host = host
        super.init(nibName: nil, bundle: nil)
    }

    @available(*, unavailable) required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }

    override func loadView() {
        let view = PaneView()
        view.clipsToBounds = true
        view.controller = self
        addChild(host)
        view.addSubview(host.view)
        self.view = view
    }

    fileprivate func layoutHost() {
        let bounds = view.bounds
        let width = max(bounds.width, heldWidth ?? 0)
        // Pinned away from the inspector, whose side follows the layout direction.
        let x = view.userInterfaceLayoutDirection == .rightToLeft ? bounds.maxX - width : bounds.minX
        let frame = NSRect(x: x, y: bounds.minY, width: width, height: bounds.height)
        guard host.view.frame != frame else { return }
        #if DEBUG
        if frame.width != host.view.frame.width { MacPerfProbe.count("content.width") }
        #endif
        host.view.frame = frame
    }

    private final class PaneView: NSView {
        weak var controller: MacContentController?

        override func layout() {
            controller?.layoutHost()
            super.layout()
        }
    }
}

/// The inspector's pane, in a view that knows whether the column is on screen: a split view hides a collapsed item's
/// view once it has finished closing, and shows it again as it starts to open. The chat's details are built ahead, in
/// the closed column, once the user has paused for a moment after choosing the chat (or as the column first shows
/// them), and kept while that chat stays chosen, so opening the column only reveals them. The closed column never lays
/// them out again, as a resize of the window would on each of its steps.
@MainActor final class MacInspectorController: NSViewController {
    /// How long the user has given no input before the details are built ahead.
    private static let quiet: TimeInterval = 0.5
    private let model: AppModel
    private let state: MacWindowState
    private let presence = MacColumnPresence()
    private var prebuild: DispatchWorkItem?

    init(model: AppModel, state: MacWindowState) {
        self.model = model
        self.state = state
        super.init(nibName: nil, bundle: nil)
    }

    @available(*, unavailable) required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }

    override func loadView() {
        Self.watchInput()
        let view = PresenceView()
        view.changed = { [presence] present in presence.onScreen = present }
        view.movedToWindow = { [weak self] in
            guard let self else { return }
            self.schedulePrebuild(for: self.state.selection)
        }
        let model = model, state = state, presence = presence
        let host = NSHostingView(rootView: MacPane { MacInspectorPane(model: model, window: state, presence: presence) })
        host.sizingOptions = []
        view.addSubview(host)
        view.host = host
        self.view = view
        MacObservation.track(self) { inspector in
            if inspector.presence.onScreen { inspector.presence.shownChat = inspector.state.selection }
        }
        MacObservation.track(self) { inspector in inspector.schedulePrebuild(for: inspector.state.selection) }
    }

    private func schedulePrebuild(for chatID: String?, after delay: TimeInterval = quiet) {
        prebuild?.cancel()
        prebuild = nil
        guard let chatID, presence.shownChat != chatID else { return }
        let work = DispatchWorkItem { [weak self] in
            MainActor.assumeIsolated { self?.prebuildIfQuiet(chatID) }
        }
        prebuild = work
        DispatchQueue.main.asyncAfter(deadline: .now() + delay, execute: work)
    }

    /// Builds and lays out the details in the closed column, at the size the column opens to. Not while the user is
    /// typing, clicking or scrolling: the build is one pass of tens of milliseconds, and waits until it would not land
    /// among those.
    private func prebuildIfQuiet(_ chatID: String) {
        prebuild = nil
        guard state.selection == chatID, presence.shownChat != chatID, let view = view as? PresenceView else { return }
        // Out of the window, it waits until the column is in it (`movedToWindow`).
        guard view.window != nil else { return }
        // A button held down (a window's drag) or a tracking loop running (a control's, a resize's, a menu's) is input
        // now; and in a loop that runs in some other mode, the event being handled may be one it took.
        if NSEvent.pressedMouseButtons != 0 || RunLoop.current.currentMode == .eventTracking { Self.noteInput() }
        let current = NSApp.currentEvent.flatMap { Self.input.contains(NSEvent.EventTypeMask(type: $0.type)) ? $0.timestamp : nil }
        let quietFor = ProcessInfo.processInfo.systemUptime - max(Self.lastInput, current ?? 0)
        if quietFor < Self.quiet { return schedulePrebuild(for: chatID, after: Self.quiet - quietFor) }
        presence.shownChat = chatID
        view.layOutHidden()
        #if DEBUG
        Self.debugBuiltAhead = (chatID, ProcessInfo.processInfo.systemUptime)
        #endif
    }

    /// The events a build ahead waits after; not the pointer's moves, which lead to Chat Details as often as not.
    private static let input: NSEvent.EventTypeMask = [
        .keyDown, .keyUp, .flagsChanged, .scrollWheel, .leftMouseDown, .leftMouseUp, .leftMouseDragged, .rightMouseDown,
        .rightMouseUp, .rightMouseDragged, .otherMouseDown, .otherMouseUp, .otherMouseDragged, .magnify, .swipe, .rotate,
        .beginGesture, .endGesture, .smartMagnify, .pressure,
    ]
    /// When the app last handed out one of those events, or a tracking loop, a window's move or a menu ended (system
    /// uptime, as events' timestamps); a pointer move after it leaves it as it was.
    private static var lastInput: TimeInterval = 0
    private static var inputMonitor: Any?

    private static func watchInput() {
        guard inputMonitor == nil else { return }
        inputMonitor = NSEvent.addLocalMonitorForEvents(matching: input) { event in
            let press = event.type == .leftMouseDown || event.type == .rightMouseDown || event.type == .otherMouseDown
            MainActor.assumeIsolated {
                noteInput()
                // A press can start a tracking loop, which takes the drags and the release without handing them out and
                // runs in its own mode: this runs as it ends.
                if press { RunLoop.main.perform(inModes: [.default]) { MainActor.assumeIsolated { noteInput() } } }
            }
            return event
        }
        // A window's drag happens outside the app, and the menu bar's menus track without a press the app hands out.
        for name in [NSWindow.didMoveNotification, NSWindow.didEndLiveResizeNotification, NSMenu.didEndTrackingNotification] {
            NotificationCenter.default.addObserver(forName: name, object: nil, queue: .main) { _ in MainActor.assumeIsolated { noteInput() } }
        }
    }

    private static func noteInput() { lastInput = ProcessInfo.processInfo.systemUptime }

    #if DEBUG
    /// The chat whose details were last built ahead, and when (`prebuild-quiet`, `prebuild-tracking`).
    static var debugBuiltAhead: (chat: String, at: TimeInterval)?
    #endif

    /// The details fill the column while it shows. Hidden, they keep the size they had: a resize of the window does not
    /// lay them out.
    private final class PresenceView: NSView {
        var changed: (Bool) -> Void = { _ in }
        var movedToWindow: () -> Void = {}
        weak var host: NSView?
        private var reported: Bool?

        override func layout() {
            if let host, !isHiddenOrHasHiddenAncestor, host.frame != bounds { host.frame = bounds }
            super.layout()
        }

        /// The details built ahead get the column's size now, as it would open, and are laid out at it: the window's
        /// height and the inspector's width. A closed column is zero wide until it first opens.
        func layOutHidden() {
            guard let host, isHiddenOrHasHiddenAncestor, let height = window?.contentView?.bounds.height else { return }
            let size = NSSize(width: MacSplitController.inspectorWidth, height: height)
            if host.frame.size != size { host.frame = NSRect(origin: .zero, size: size) }
            host.layoutSubtreeIfNeeded()
        }

        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            report()
            if window != nil { movedToWindow() }
        }
        override func viewDidHide() { super.viewDidHide(); report() }
        override func viewDidUnhide() { super.viewDidUnhide(); needsLayout = true; report() }

        private func report() {
            let present = window != nil && !isHiddenOrHasHiddenAncestor
            guard present != reported else { return }
            reported = present
            // Called from AppKit's layout of the split view: SwiftUI's state changes after it.
            let changed = changed
            DispatchQueue.main.async { changed(present) }
        }
    }
}

/// Whether a split view column is on screen, from when it starts to open until it has finished closing, and the chat
/// it last showed.
@MainActor @Observable final class MacColumnPresence {
    var onScreen = false
    var shownChat: String?
}

/// The sidebar's search field, above the chats: it filters them by name or address (`MacWindowState.chatSearch`), and
/// Find Chat (⌥⌘F) puts the cursor in it.
@MainActor final class MacSidebarSearch: NSSplitViewItemAccessoryViewController {
    private let state: MacWindowState
    private let field = NSSearchField()
    /// The requests already answered. Those from before the field existed were for an earlier window; one that came as
    /// the window was made (Find Chat with it closed) waits until the field is in it.
    private var searchRequests: Int

    init(state: MacWindowState) {
        self.state = state
        searchRequests = state.searchRequests
        super.init(nibName: nil, bundle: nil)
    }

    @available(*, unavailable) required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }

    override func loadView() {
        field.placeholderString = "Search"
        field.sendsSearchStringImmediately = true
        field.target = self
        field.action = #selector(searchChanged)
        // The sidebar's own size, as its `.searchable` field had: the floating sidebar already insets its accessory.
        field.controlSize = .large
        field.translatesAutoresizingMaskIntoConstraints = false
        let view = NSView()
        view.addSubview(field)
        NSLayoutConstraint.activate([
            field.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            field.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            field.topAnchor.constraint(equalTo: view.topAnchor, constant: 4),
            field.bottomAnchor.constraint(equalTo: view.bottomAnchor, constant: -6),
        ])
        self.view = view
        // The chats scroll under the field and fade, as under a toolbar, with no line between.
        if #available(macOS 26.1, *) { preferredScrollEdgeEffectStyle = .soft }
        MacObservation.track(self) { search in search.update() }
    }

    override func viewDidAppear() {
        super.viewDidAppear()
        focusIfRequested()
    }

    private func update() {
        if field.stringValue != state.chatSearch { field.stringValue = state.chatSearch }
        focusIfRequested()
    }

    private func focusIfRequested() {
        guard state.searchRequests != searchRequests, let window = view.window else { return }
        searchRequests = state.searchRequests
        window.makeFirstResponder(field)
    }

    @objc private func searchChanged() { state.chatSearch = field.stringValue }
}
