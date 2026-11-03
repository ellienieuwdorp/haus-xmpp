import SwiftUI

// The app delegate, not a window, owns the model, so closing the window leaves the app running and connected.
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
