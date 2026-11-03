import AppKit
import SwiftUI

// Each pane is SwiftUI in a hosting controller that reports no sizes (`sizingOptions` empty): the items' thicknesses
// are the only minimums, so a window resize lays each pane out once and nothing SwiftUI measures moves a divider.
@MainActor final class MacSplitController: NSSplitViewController {
    static let sidebarWidth = (min: 260.0, ideal: 320.0, max: 360.0)
    static let inspectorWidth = 320.0
    static let conversationMinWidth = 320.0
    static let windowMinWidth = 720.0
    static let windowMinHeight = 480.0

    private let model: AppModel
    private let state: MacWindowState
    private var sidebarItem: NSSplitViewItem!
    private var inspectorItem: NSSplitViewItem!
    private var content: MacContentController!
    private var collapseObservation: NSKeyValueObservation?
    // AppKit's collapse animations do not take over from each other: an open interrupting a close leaves the
    // conversation's width pinned and the window unresizable, so state changes wait until the animation has finished.
    private var animatingInspector = false
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
        inspectorItem.isCollapsed = !showsInspector

        // A collapse that came another way (View > Hide Inspector) goes back into the window's state.
        MacObservation.track(self) { split in split.applyInspector() }
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

    // A split view leaves an item that starts collapsed out of the window until it first expands, and details build
    // ahead only in the window: expand and collapse once, unanimated, if the window is wide enough without growing.
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
        // Opening, the conversation keeps its width while the column slides over it, laid out once at the end.
        // Closing, it follows the column: held wider than its pane, it would keep AppKit from animating the next open.
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
                self.applyInspector()
            }
        }
    }

    // Through the window's state, as Chat Details goes, so it gets the same hold and no empty column shows.
    override func toggleInspector(_ sender: Any?) {
        if inspectorItem.isCollapsed { state.inspectorShown = state.selection != nil } else { state.inspectorShown = false }
    }

    private func inspectorSettled() {
        guard inspectorItem.isCollapsed, !showsInspector, !state.inspectorPath.isEmpty else { return }
        state.inspectorPath.removeAll()
    }
}

// While the inspector opens, the hosting view keeps its width (`heldWidth`) and the pane clips it: laying it out at
// each width of the animation would run the conversation's layout every frame.
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

// A split view hides a collapsed item's view once closed and shows it as it starts to open. The details build ahead in
// the closed column after a pause in input, so opening only reveals them, and are not laid out again on window resizes.
@MainActor final class MacInspectorController: NSViewController {
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

    // One pass of tens of milliseconds, so it waits until it would not land among typing, clicks or scrolls.
    private func prebuildIfQuiet(_ chatID: String) {
        prebuild = nil
        guard state.selection == chatID, presence.shownChat != chatID, let view = view as? PresenceView else { return }
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

    // Not the pointer's moves, which lead to Chat Details as often as not.
    private static let input: NSEvent.EventTypeMask = [
        .keyDown, .keyUp, .flagsChanged, .scrollWheel, .leftMouseDown, .leftMouseUp, .leftMouseDragged, .rightMouseDown,
        .rightMouseUp, .rightMouseDragged, .otherMouseDown, .otherMouseUp, .otherMouseDragged, .magnify, .swipe, .rotate,
        .beginGesture, .endGesture, .smartMagnify, .pressure,
    ]
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
    static var debugBuiltAhead: (chat: String, at: TimeInterval)?
    #endif

    private final class PresenceView: NSView {
        var changed: (Bool) -> Void = { _ in }
        var movedToWindow: () -> Void = {}
        weak var host: NSView?
        private var reported: Bool?

        override func layout() {
            if let host, !isHiddenOrHasHiddenAncestor, host.frame != bounds { host.frame = bounds }
            super.layout()
        }

        // A closed column is zero wide until it first opens: use the window's height and the inspector's width.
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

@MainActor @Observable final class MacColumnPresence {
    var onScreen = false
    var shownChat: String?
}

@MainActor final class MacSidebarSearch: NSSplitViewItemAccessoryViewController {
    private let state: MacWindowState
    private let field = NSSearchField()
    // Requests from before the field existed were for an earlier window; one made with the window waits for the field.
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
