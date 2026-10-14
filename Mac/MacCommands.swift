import SwiftUI

/// Menu commands of the main window. Settings (⌘,) comes with the Settings scene.
struct MacCommands: Commands {
    let window: MacWindowState
    @Environment(\.openWindow) private var openWindow

    var body: some Commands {
        // Kept for the Dock icon, which reopens the main window after it was closed (or never shown: a launch in the
        // background opens no window). Commands are built at launch, before any window exists.
        let _ = { if window.openWindow == nil { window.openWindow = openWindow } }()
        CommandGroup(replacing: .newItem) {
            Button("New Chat") {
                showMainWindow()
                window.showingNewChat = true
            }
            .keyboardShortcut("n")
        }
        // Find searches the chat list for now; Phase 2's conversation view takes ⌘F inside a chat.
        CommandGroup(after: .textEditing) {
            Button("Find Chat…") {
                showMainWindow()
                window.searchRequests += 1
            }
            .keyboardShortcut("f")
        }
    }

    /// The commands work with the main window closed too: they bring it back first.
    private func showMainWindow() {
        openWindow(id: MacAppDelegate.mainWindowID)
    }
}
