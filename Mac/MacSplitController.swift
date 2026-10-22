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
    private var collapseObservation: NSKeyValueObservation?

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
        let content = Self.host(MacPane { MacDetailPane(model: model, window: state) }, bridging: [.title])
        let inspector = Self.host(MacPane { MacInspectorPane(model: model, window: state) })

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
        splitView.autosaveName = "Main Split"
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
        collapseObservation = inspectorItem.observe(\.isCollapsed) { [weak self] _, _ in
            MainActor.assumeIsolated {
                guard let self else { return }
                let collapsed = self.inspectorItem.isCollapsed
                guard collapsed == self.showsInspector else { return }
                if collapsed { self.state.inspectorShown = false } else if self.state.selection != nil { self.state.inspectorShown = true }
            }
        }
    }

    private static func host<Content: View>(_ view: Content, bridging: NSHostingSceneBridgingOptions = []) -> NSHostingController<Content> {
        let host = NSHostingController(rootView: view)
        host.sizingOptions = []
        host.sceneBridgingOptions = bridging
        return host
    }

    private func applyInspector() {
        let shows = showsInspector
        guard inspectorItem.isCollapsed == shows else { return }
        guard view.window?.isVisible == true else {
            inspectorItem.isCollapsed = !shows
            inspectorSettled()
            return
        }
        NSAnimationContext.runAnimationGroup { _ in
            inspectorItem.animator().isCollapsed = !shows
        } completionHandler: { [weak self] in
            MainActor.assumeIsolated { self?.inspectorSettled() }
        }
    }

    /// A pushed page stays in the closed inspector until it has finished closing; then it opens on the chat's details
    /// again.
    private func inspectorSettled() {
        guard inspectorItem.isCollapsed, !showsInspector, !state.inspectorPath.isEmpty else { return }
        state.inspectorPath.removeAll()
    }
}

/// The sidebar's search field, above the chats: it filters them by name or address (`MacWindowState.chatSearch`), and
/// Find Chat (⌥⌘F) puts the cursor in it.
@MainActor final class MacSidebarSearch: NSSplitViewItemAccessoryViewController {
    private let state: MacWindowState
    private let field = NSSearchField()
    private var searchRequests = 0

    init(state: MacWindowState) {
        self.state = state
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
        searchRequests = state.searchRequests
        MacObservation.track(self) { search in search.update() }
    }

    private func update() {
        if field.stringValue != state.chatSearch { field.stringValue = state.chatSearch }
        guard state.searchRequests != searchRequests else { return }
        searchRequests = state.searchRequests
        view.window?.makeFirstResponder(field)
    }

    @objc private func searchChanged() { state.chatSearch = field.stringValue }
}
