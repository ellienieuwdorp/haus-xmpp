import AppKit
import SwiftUI

@main
enum HausXMPPMacLaunch {
    @MainActor static func main() {
        if MacTestHost.isHosting {
            MacTestHost.run()
            return
        }
        HausXMPPMacApp.main()
    }
}

// The app delegate, not a window, owns the model, so closing the window leaves the app running and connected.
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

// Under XCTest the process only hosts the unit-test bundle: no app delegate, model, window, store, Keychain or network.
// The prohibited policy gives it no menu bar or focus; the Dock tile LaunchServices shows at launch goes once `main` runs.
@MainActor enum MacTestHost {
    static let isHosting = ["XCTestConfigurationFilePath", "XCTestSessionIdentifier", "XCTestBundlePath"]
        .contains { ProcessInfo.processInfo.environment[$0] != nil }

    static func run() {
        let app = NSApplication.shared
        app.setActivationPolicy(.prohibited)
        app.run()
    }
}
