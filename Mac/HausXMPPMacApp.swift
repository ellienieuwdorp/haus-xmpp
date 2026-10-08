import SwiftUI

/// The Mac app: one main window (a split view of chats, the open chat and its details), a Settings window, and the
/// menu commands. The process, not the window, owns the model, so closing the window leaves the app running and
/// connected; the Dock icon brings the window back (`MacAppDelegate`).
@main
struct HausXMPPMacApp: App {
    @NSApplicationDelegateAdaptor(MacAppDelegate.self) private var delegate
    @State private var appearance = AppearanceStore.shared

    var body: some Scene {
        // `Window`, not `WindowGroup`: one main window until the model can serve several (Phase 4), and no File > New
        // Window.
        Window("Haus XMPP", id: MacAppDelegate.mainWindowID) {
            MacRootView(model: delegate.model, window: delegate.window)
                .themedRoot()
                .environment(\.appearance, appearance)
        }
        .defaultSize(width: 1080, height: 720)
        .commands { MacCommands(window: delegate.window) }

        Settings {
            MacSettingsView(model: delegate.model)
                .themedRoot()
                .environment(\.appearance, appearance)
        }
    }
}
