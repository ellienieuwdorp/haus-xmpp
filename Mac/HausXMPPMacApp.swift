import SwiftUI

/// The Mac app: one main window (a split view of chats, the open chat and its details), a Settings window, and the
/// menu commands. The process, not the window, owns the model, so closing the window leaves the app running and
/// connected; the Dock icon brings the window back. The main window is AppKit's, made by the app delegate
/// (`MacMainWindowController`); Settings is the one scene.
@main
struct HausXMPPMacApp: App {
    @NSApplicationDelegateAdaptor(MacAppDelegate.self) private var delegate
    @State private var appearance = AppearanceStore.shared

    var body: some Scene {
        Settings {
            MacSettingsView(model: delegate.model)
                .themedRoot()
                .environment(\.appearance, appearance)
                #if DEBUG
                .modifier(MacScenePhaseLog(window: "settings"))
                #endif
        }
        .commands { MacCommands(model: delegate.model, window: delegate.window) }
    }
}
