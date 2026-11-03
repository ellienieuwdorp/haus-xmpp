import AppKit
import MessagingCore
import SwiftUI

@Observable @MainActor final class MacWindowState {
    var selection: String?
    var showingNewChat = false
    var showingAccount = false
    var inspectorShown = false
    var inspectorPath: [ChatRoute] = []
    var reviewingOwnDevices = false
    var showingRestore = false
    var blockRequest: BlockRequest?
    var chatSearch = ""
    var searchRequests = 0
    var isKey = false
    @ObservationIgnored var showMainWindow: () -> Void = {}
}

// Owns the model and the lifecycle driver, so the connection outlives the window.
@MainActor final class MacAppDelegate: NSObject, NSApplicationDelegate {
    static let mainWindowID = "main"

    let model = AppModel()
    let window = MacWindowState()
    private(set) lazy var lifecycle = MacLifecycle(model: model)
    private var mainWindow: MacMainWindowController?

    #if DEBUG
    override init() {
        MacUnobtrusive.setPolicy()
        super.init()
    }
    #endif

    // Set before launching finishes, so a launch by a click on a notification (or its Reply or Mark as Read) delivers
    // it.
    func applicationWillFinishLaunching(_ notification: Notification) {
        #if DEBUG
        MacDebugHooks.prepareLaunch()
        #endif
        PushRegistration.shared.installNotificationDelegate()
        // The share extension draws its send button in the accent chosen here.
        AppearanceStore.shared.mirror = SharedSession.groupDefaults
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

    // Closing the last window must not quit, disconnect or release the lease.
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { false }

    // Quit, log out and shut down quiesce the transport first (a final `<a/>`), bounded.
    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply { lifecycle.shouldTerminate() }

    // A notification click lands here too; the system activates the app for the click itself.
    private func showMainWindow() {
        if mainWindow == nil {
            mainWindow = MacMainWindowController(model: model, state: window) { [weak self] in
                // Released only once AppKit has finished closing the window.
                DispatchQueue.main.async { self?.mainWindow = nil }
            }
        }
        mainWindow?.show()
    }

    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows: Bool) -> Bool {
        guard !hasVisibleWindows else { return true }
        showMainWindow()
        return false
    }
}
