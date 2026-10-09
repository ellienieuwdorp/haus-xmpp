import AppKit
import MessagingCore
import SwiftUI

/// What the main window shows, shared with the menu commands. One instance, for the one main window.
@Observable @MainActor final class MacWindowState {
    /// The open chat in the sidebar.
    var selection: String?
    var showingNewChat = false
    var showingAccount = false
    var inspectorShown = false
    var reviewingOwnDevices = false
    /// Bumped by Find (⌘F); the sidebar focuses its search field when it changes.
    var searchRequests = 0
    /// Captured from the main window's content, so the Dock icon can bring the window back after it was closed.
    @ObservationIgnored var openWindow: OpenWindowAction?
}

/// The process's side of the Mac app: it owns the model, so the connection outlives the window, and it turns
/// application events into the model's lifecycle.
@MainActor final class MacAppDelegate: NSObject, NSApplicationDelegate {
    static let mainWindowID = "main"

    let model = AppModel()
    let window = MacWindowState()
    private var observers: [any NSObjectProtocol] = []

    #if DEBUG
    override init() {
        MacUnobtrusive.setPolicy()
        super.init()
    }

    func applicationWillFinishLaunching(_ notification: Notification) { MacDebugHooks.prepareLaunch() }
    #endif

    func applicationDidFinishLaunching(_ notification: Notification) {
        PushRegistration.shared.installNotificationDelegate()
        observeActivation()
        Task { await model.prepare() }
        #if DEBUG
        MacDebugHooks.start(model: model, window: window)
        #endif
    }

    /// Phase 1 stand-in for the Mac lifecycle driver (lifecycle-signals.md, "Left for the Mac"): the transport stays
    /// wanted for as long as the process runs. Activating the app counts as an iOS activation (reconnect now, refresh),
    /// and leaving it records the last-seen time, as an iOS scene going `.inactive` does. Nothing here turns the
    /// transport off; quitting and sleeping without the bounded quiesce, and reading only while a window is key, are
    /// for the Mac lifecycle work.
    private func observeActivation() {
        let center = NotificationCenter.default
        observers.append(center.addObserver(forName: NSApplication.didBecomeActiveNotification, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.model.applyLifecycle([.change(.inFront, activated: true)]) }
        })
        observers.append(center.addObserver(forName: NSApplication.didResignActiveNotification, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.model.applyLifecycle([.interactionEnded(at: nil)]) }
        })
    }

    /// The app stays running, and connected, with no window open.
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { false }

    /// The Dock icon (or opening the app again) with no window on screen brings the main window back.
    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows: Bool) -> Bool {
        guard !hasVisibleWindows, let openWindow = window.openWindow else { return true }
        openWindow(id: Self.mainWindowID)
        return false
    }
}
