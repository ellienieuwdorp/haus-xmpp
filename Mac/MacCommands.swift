import AppKit
import SwiftUI

/// Menu commands of the main window. Settings (⌘,) comes with the Settings scene.
struct MacCommands: Commands {
    let window: MacWindowState
    @Environment(\.openWindow) private var openWindow

    var body: some Commands {
        // Kept for the Dock icon, which reopens the main window after it was closed (or never shown: a launch in the
        // background opens no window). Commands are built at launch, before any window exists.
        let _ = { if window.openWindow == nil { window.openWindow = openWindow } }()
        CommandGroup(replacing: .appInfo) {
            Button("About Haus XMPP") { MacAboutPanel.show() }
        }
        CommandGroup(replacing: .newItem) {
            Button("New Chat") {
                showMainWindow()
                window.showingNewChat = true
            }
            .keyboardShortcut("n")
        }
        // Find searches the chat list for now; the full Mac conversation view will take ⌘F inside a chat.
        CommandGroup(after: .textEditing) {
            Button("Find Chat…") {
                showMainWindow()
                window.searchRequests += 1
            }
            .keyboardShortcut("f")
        }
        // File > Import from iPhone or iPad: Continuity Camera into the open chat's composer, as the attach menu offers.
        ImportFromDevicesCommands()
        // The app has no help book; Help offers the support site and mail instead of "Help isn't available".
        CommandGroup(replacing: .help) {
            Button("Haus XMPP Support") { NSWorkspace.shared.open(AppInfo.support) }
            Button("Contact Support…") { NSWorkspace.shared.open(AppInfo.supportMail) }
        }
    }

    /// The commands work with the main window closed too: they bring it back first.
    private func showMainWindow() {
        openWindow(id: MacAppDelegate.mainWindowID)
    }
}

/// The standard About panel (name, icon, version and the Info.plist copyright) with the licence notice and the
/// source, privacy and support links as its credits. The licence texts are in Settings > About.
enum MacAboutPanel {
    @MainActor static func show() {
        NSApp.orderFrontStandardAboutPanel(options: [.credits: credits])
    }

    private static var credits: NSAttributedString {
        let paragraph = NSMutableParagraphStyle()
        paragraph.alignment = .center
        paragraph.paragraphSpacing = 6
        let base: [NSAttributedString.Key: Any] = [
            .font: NSFont.systemFont(ofSize: NSFont.smallSystemFontSize),
            .foregroundColor: NSColor.secondaryLabelColor,
            .paragraphStyle: paragraph
        ]
        let text = NSMutableAttributedString(string: AppInfo.warranty + "\n", attributes: base)
        let links = [("Source code", AppInfo.sourceCode), ("Privacy policy", AppInfo.privacyPolicy), ("Support", AppInfo.support)]
        for (index, link) in links.enumerated() {
            if index > 0 { text.append(NSAttributedString(string: " · ", attributes: base)) }
            var attributes = base
            attributes[.link] = link.1
            text.append(NSAttributedString(string: link.0, attributes: attributes))
        }
        return text
    }
}
