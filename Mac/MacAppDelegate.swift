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
    /// The pages pushed in the inspector over the chat's details (devices and encryption, group details).
    var inspectorPath: [ChatRoute] = []
    var reviewingOwnDevices = false
    /// Restore from a transfer, from the signed-out sidebar.
    var showingRestore = false
    /// A Block or Report chosen from a chat's menu (the sidebar's or the menu bar's), waiting for its confirmation.
    var blockRequest: BlockRequest?
    /// What the sidebar's search field filters the chats by.
    var chatSearch = ""
    /// Bumped by Find Chat (⌥⌘F); the sidebar focuses its search field when it changes.
    var searchRequests = 0
    /// The main window is the key window: the Chat and Message menus act on it only then.
    var isKey = false
    /// Opens the main window, or brings it back from the Dock; set by the app delegate, which owns the window.
    @ObservationIgnored var showMainWindow: () -> Void = {}
}

/// The process's side of the Mac app: it owns the model, so the connection outlives the window, and its lifecycle
/// owner (`MacLifecycle`), so application, window, power and idle events reach the model once per process.
@MainActor final class MacAppDelegate: NSObject, NSApplicationDelegate {
    static let mainWindowID = "main"

    let model = AppModel()
    let window = MacWindowState()
    private(set) lazy var lifecycle = MacLifecycle(model: model)
    /// The main window while it is open; closing it lets it go.
    private var mainWindow: MacMainWindowController?

    #if DEBUG
    override init() {
        MacUnobtrusive.setPolicy()
        super.init()
    }
    #endif

    /// The notification centre's delegate is set before launching finishes, so a launch by a click on a notification,
    /// or on its Reply or Mark as Read, delivers that response to it.
    func applicationWillFinishLaunching(_ notification: Notification) {
        #if DEBUG
        MacDebugHooks.prepareLaunch()
        #endif
        PushRegistration.shared.installNotificationDelegate()
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        MacAttachmentActions.removeExports()
        #if DEBUG
        MacLifecycleDebug.attach(to: lifecycle)
        #endif
        lifecycle.install()
        window.showMainWindow = { [weak self] in self?.showMainWindow() }
        model.onNotificationRoute = { [weak self] in self?.showMainWindow() }
        showMainWindow()
        Task { await model.prepare() }
        #if DEBUG
        MacDebugHooks.start(model: model, window: window, lifecycle: lifecycle)
        #endif
    }

    /// APNs tokens, asked for by `PushRegistration.request`.
    func application(_ application: NSApplication, didRegisterForRemoteNotificationsWithDeviceToken deviceToken: Data) {
        PushRegistration.shared.received(deviceToken)
        #if DEBUG
        MacPushProbe.received(token: deviceToken)
        #endif
    }

    func application(_ application: NSApplication, didFailToRegisterForRemoteNotificationsWithError error: any Error) {
        PushRegistration.shared.registrationFailed()
        #if DEBUG
        MacPushProbe.failed(error)
        #endif
    }

    /// The app stays running, and connected, with no window open.
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { false }

    /// Quit, log out and shut down: the transport quiesces first (a final `<a/>`), bounded, then the app goes.
    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply { lifecycle.shouldTerminate() }

    /// Opens the main window, made again if it was closed, or brings it out of the Dock if it was minimised. A
    /// notification click comes here too (the window then selects the chat); the system activates the app for the
    /// click itself.
    private func showMainWindow() {
        if mainWindow == nil {
            mainWindow = MacMainWindowController(model: model, state: window) { [weak self] in
                // After the close has finished with the window.
                DispatchQueue.main.async { self?.mainWindow = nil }
            }
        }
        mainWindow?.show()
    }

    /// The Dock icon (or opening the app again) with no window on screen brings the main window back.
    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows: Bool) -> Bool {
        guard !hasVisibleWindows else { return true }
        showMainWindow()
        return false
    }
}
