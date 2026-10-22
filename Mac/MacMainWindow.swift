import AppKit
import Observation
import SwiftUI

/// The one main window, made by the app delegate: an AppKit window whose content is a split view controller
/// (`MacSplitController`) with a SwiftUI pane in each item, under an AppKit toolbar (`MacToolbar`). Closing it releases
/// the window and everything in it; the model, the connection and the window's state (`MacWindowState`) stay with the
/// delegate, and the next `show` builds it again around them.
@MainActor final class MacMainWindowController: NSWindowController, NSWindowDelegate {
    private static let frameName = "Main Window"
    private let model: AppModel
    private let state: MacWindowState
    private let closed: () -> Void

    init(model: AppModel, state: MacWindowState, closed: @escaping () -> Void) {
        self.model = model
        self.state = state
        self.closed = closed
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 1080, height: 720),
                              styleMask: [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView],
                              backing: .buffered, defer: true)
        window.identifier = NSUserInterfaceItemIdentifier(MacAppDelegate.mainWindowID)
        window.title = "Haus XMPP"
        window.isReleasedWhenClosed = false
        window.tabbingMode = .disallowed
        // Tab goes from the sidebar's search field to the chats, the timeline and the composer, as the panes are placed.
        window.autorecalculatesKeyViewLoop = true
        window.collectionBehavior.insert(.fullScreenPrimary)
        super.init(window: window)
        window.delegate = self
        window.contentViewController = MacShellController(model: model, state: state)
        window.contentMinSize = NSSize(width: MacSplitController.windowMinWidth, height: MacSplitController.windowMinHeight)
        // Setting the content view controller sizes the window to its view; the saved frame, else the default size.
        window.setContentSize(NSSize(width: 1080, height: 720))
        if !window.setFrameUsingName(Self.frameName) { window.center() }
        window.setFrameAutosaveName(Self.frameName)
    }

    @available(*, unavailable) required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }

    func show() {
        guard let window else { return }
        #if DEBUG
        if MacUnobtrusive.isOn { MacUnobtrusive.hide(window) }
        #endif
        if window.isMiniaturized { window.deminiaturize(nil) }
        showWindow(nil)
    }

    func windowDidBecomeKey(_ notification: Notification) { state.isKey = true }
    func windowDidResignKey(_ notification: Notification) { state.isKey = false }

    /// Nothing is on screen to read any more: the open chat closes, and the delegate lets the window go.
    func windowWillClose(_ notification: Notification) {
        state.isKey = false
        if let chatID = state.selection { model.closeChat(chatID) }
        closed()
    }
}

/// The window's content: the split view, or in its place the transfer, upgrade or key-recovery screen until that is
/// settled, as the iPhone's root does. A zero-sized SwiftUI view beside them presents the window's sheets and alerts
/// and follows its routes (`MacWindowPresenter`), so neither pane that resizes with the window carries them.
@MainActor final class MacShellController: NSViewController {
    private let model: AppModel
    private let state: MacWindowState
    private var split: MacSplitController?
    private var blocking: NSViewController?
    private var toolbar: MacToolbar?

    init(model: AppModel, state: MacWindowState) {
        self.model = model
        self.state = state
        super.init(nibName: nil, bundle: nil)
    }

    @available(*, unavailable) required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }

    override func loadView() {
        let view = NSView(frame: NSRect(x: 0, y: 0, width: 1080, height: 720))
        let presenter = NSHostingView(rootView: MacPane { MacWindowPresenter(model: self.model, window: self.state) })
        presenter.sizingOptions = []
        presenter.frame = .zero
        view.addSubview(presenter)
        self.view = view
        MacObservation.track(self) { shell in shell.showContent(blocked: shell.isBlocked) }
    }

    override func viewWillAppear() {
        super.viewWillAppear()
        guard toolbar == nil, let window = view.window else { return }
        let toolbar = MacToolbar(model: model, state: state)
        toolbar.install(in: window)
        toolbar.toolbar.isVisible = split != nil
        self.toolbar = toolbar
    }

    private var isBlocked: Bool { model.transferState != .none || model.upgradeState != .none || model.keyRecovery != nil }

    private func showContent(blocked: Bool) {
        if blocked, blocking == nil {
            let host = NSHostingController(rootView: MacPane { MacBlockingView(model: self.model) })
            host.sizingOptions = []
            replace(split, with: host)
            split = nil
            blocking = host
        } else if !blocked, split == nil {
            let split = MacSplitController(model: model, state: state)
            replace(blocking, with: split)
            blocking = nil
            self.split = split
        }
        toolbar?.toolbar.isVisible = !blocked
    }

    private func replace(_ old: NSViewController?, with new: NSViewController) {
        old?.view.removeFromSuperview()
        old?.removeFromParent()
        addChild(new)
        new.view.frame = view.bounds
        new.view.autoresizingMask = [.width, .height]
        view.addSubview(new.view, positioned: .below, relativeTo: view.subviews.first)
    }
}

/// The upgrade, transfer and key-recovery screens, which replace everything until they are settled.
private struct MacBlockingView: View {
    let model: AppModel

    var body: some View {
        Group {
            if model.transferState != .none {
                TransferBlockingView(model: model)
            } else if model.upgradeState != .none {
                UpgradeBlockingView(model: model)
            } else if model.keyRecovery != nil {
                KeyRecoveryView(model: model)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

/// A SwiftUI root inside the AppKit window: the app's theme and appearance, as the scenes' roots have them.
struct MacPane<Content: View>: View {
    @ViewBuilder let content: Content

    var body: some View {
        content
            .themedRoot()
            .environment(\.appearance, AppearanceStore.shared)
    }
}

/// Runs AppKit updates from observable state: `apply` now, then again after each change to what it read, for as long as
/// `owner` lives.
@MainActor enum MacObservation {
    static func track<Owner: AnyObject & Sendable>(_ owner: Owner, _ apply: @escaping @MainActor (Owner) -> Void) {
        withObservationTracking {
            apply(owner)
        } onChange: { [weak owner] in
            // Called as the value is about to change: the update runs once it has.
            Task { @MainActor in
                guard let owner else { return }
                track(owner, apply)
            }
        }
    }
}
