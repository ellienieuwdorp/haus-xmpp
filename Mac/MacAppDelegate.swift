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

/// The process's side of the Mac app: it owns the model, so the connection outlives the window, and its lifecycle
/// owner (`MacLifecycle`), so application, window, power and idle events reach the model once per process.
@MainActor final class MacAppDelegate: NSObject, NSApplicationDelegate {
    static let mainWindowID = "main"

    let model = AppModel()
    let window = MacWindowState()
    private(set) lazy var lifecycle = MacLifecycle(model: model)

    #if DEBUG
    override init() {
        MacUnobtrusive.setPolicy()
        super.init()
    }

    func applicationWillFinishLaunching(_ notification: Notification) { MacDebugHooks.prepareLaunch() }
    #endif

    func applicationDidFinishLaunching(_ notification: Notification) {
        PushRegistration.shared.installNotificationDelegate()
        #if DEBUG
        MacLifecycleDebug.attach(to: lifecycle)
        #endif
        lifecycle.install()
        Task { await model.prepare() }
        #if DEBUG
        MacDebugHooks.start(model: model, window: window, lifecycle: lifecycle)
        #endif
    }

    /// The app stays running, and connected, with no window open.
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { false }

    /// Quit, log out and shut down: the transport quiesces first (a final `<a/>`), bounded, then the app goes.
    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply { lifecycle.shouldTerminate() }

    /// The Dock icon (or opening the app again) with no window on screen brings the main window back.
    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows: Bool) -> Bool {
        guard !hasVisibleWindows, let openWindow = window.openWindow else { return true }
        openWindow(id: Self.mainWindowID)
        return false
    }
}
