import MessageStore
import OSLog
import SwiftUI
import UserNotifications
#if os(iOS)
import UIKit
#else
import AppKit
#endif

// Seams that let shared code build for iOS and macOS: each is the exact iOS call on iOS and the nearest Mac equivalent
// there. Anything larger belongs in a platform's own view files.

#if os(iOS)
typealias PlatformKeyboard = UIKeyboardType
#else
enum PlatformKeyboard { case emailAddress, URL, numberPad }
#endif

extension View {
    func inlineNavigationTitle() -> some View {
        #if os(iOS)
        navigationBarTitleDisplayMode(.inline)
        #else
        self
        #endif
    }

    func noAutocapitalization() -> some View {
        #if os(iOS)
        textInputAutocapitalization(.never)
        #else
        self
        #endif
    }

    func capitalizedCharacters() -> some View {
        #if os(iOS)
        textInputAutocapitalization(.characters)
        #else
        self
        #endif
    }

    func keyboard(_ type: PlatformKeyboard) -> some View {
        #if os(iOS)
        keyboardType(type)
        #else
        self
        #endif
    }

    func groupedListStyle() -> some View {
        #if os(iOS)
        listStyle(.insetGrouped)
        #else
        listStyle(.inset)
        #endif
    }

    // On the Mac a form's or sheet's main action is a push button; glass is for controls floating over content.
    func prominentActionStyle() -> some View {
        #if os(iOS)
        buttonStyle(.glassProminent)
        #else
        buttonStyle(.borderedProminent)
        #endif
    }

    func secondaryActionStyle() -> some View {
        #if os(iOS)
        buttonStyle(.glass)
        #else
        buttonStyle(.bordered)
        #endif
    }

    // Otherwise a Mac row button becomes a bordered push button the width of its title.
    func listRowButton() -> some View {
        #if os(iOS)
        self
        #else
        buttonStyle(ListRowButtonStyle())
        #endif
    }

    func closeButtonLabel() -> some View {
        #if os(iOS)
        labelStyle(.iconOnly)
        #else
        labelStyle(.titleOnly)
        #endif
    }

    // AppKit refuses to terminate while a modal window's `preventsApplicationTerminationWhenModal` is on, and SwiftUI
    // leaves it on for some sheets: Quit only beeps.
    func allowsQuitWhileOpen() -> some View {
        #if os(iOS)
        self
        #else
        background(TerminationPermission())
        #endif
    }
}

// A Mac grouped `Form` wraps section footers in full, where a Mac list cuts them to one line.
struct GroupedList<Content: View>: View {
    @ViewBuilder let content: Content

    var body: some View {
        #if os(iOS)
        List { content }
        #else
        Form { content }.formStyle(.grouped)
        #endif
    }
}

#if os(macOS)
private struct ListRowButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        Row(configuration: configuration)
    }

    private struct Row: View {
        let configuration: Configuration
        @Environment(\.isEnabled) private var isEnabled

        var body: some View {
            configuration.label
                .frame(maxWidth: .infinity, alignment: .leading)
                .contentShape(Rectangle())
                .opacity(!isEnabled ? 0.4 : configuration.isPressed ? 0.6 : 1)
        }
    }
}
#endif

extension ToolbarItemPlacement {
    static var barLeading: ToolbarItemPlacement {
        #if os(iOS)
        .topBarLeading
        #else
        .navigation
        #endif
    }

    static var barTrailing: ToolbarItemPlacement {
        #if os(iOS)
        .topBarTrailing
        #else
        .primaryAction
        #endif
    }
}

@MainActor enum PlatformApplication {
    // A Mac app is never launched into the background: an action reaches a running process or launches it like the Dock
    // icon.
    static var isInBackground: Bool {
        #if os(iOS)
        UIApplication.shared.applicationState == .background
        #else
        false
        #endif
    }

    static func registerForRemoteNotifications() {
        #if os(iOS)
        UIApplication.shared.registerForRemoteNotifications()
        #else
        NSApp.registerForRemoteNotifications()
        #endif
    }

    static var notificationSettingsURL: URL? {
        #if os(iOS)
        URL(string: UIApplication.openNotificationSettingsURLString)
        #else
        URL(string: "x-apple.systempreferences:com.apple.Notifications-Settings.extension?id=" + (Bundle.main.bundleIdentifier ?? ""))
        #endif
    }

    static var contactsSettingsURL: URL? {
        #if os(iOS)
        URL(string: UIApplication.openSettingsURLString)
        #else
        URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Contacts")
        #endif
    }

    // The notification centre's badge outlives the app but needs badge permission, and before notifications are asked
    // no extension runs; `dockTileOnly` labels the Mac's Dock tile instead. The centre's path clears that label, so the
    // Dock never shows two counts.
    static func setBadgeCount(_ count: Int, dockTileOnly: Bool) async {
        #if os(macOS)
        NSApp.dockTile.badgeLabel = dockTileOnly && count > 0 ? String(count) : nil
        if dockTileOnly { return }
        #endif
        try? await UNUserNotificationCenter.current().setBadgeCount(count)
    }

    static var didBecomeActiveNotification: Notification.Name {
        #if os(iOS)
        UIApplication.didBecomeActiveNotification
        #else
        NSApplication.didBecomeActiveNotification
        #endif
    }

    // An app icon set cannot be loaded by name, so the iPhone target bundles the artwork as a plain image.
    static var iconImage: PlatformImage? {
        #if os(iOS)
        Bundle.main.path(forResource: "AppIcon", ofType: "png").flatMap(UIImage.init(contentsOfFile:))
        #else
        NSApp.applicationIconImage
        #endif
    }
}

@MainActor enum PlatformPasteboard {
    static func copy(_ text: String) {
        #if os(iOS)
        UIPasteboard.general.string = text
        #else
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
        #endif
    }
}

#if os(macOS)
// SwiftUI sets the sheet window's value while presenting, after the content joined the window, so it is cleared again
// on the next main-queue pass.
private struct TerminationPermission: NSViewRepresentable {
    final class Anchor: NSView {
        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            guard let window else { return }
            window.preventsApplicationTerminationWhenModal = false
            DispatchQueue.main.async { [weak window] in window?.preventsApplicationTerminationWhenModal = false }
        }
    }

    func makeNSView(context: Context) -> Anchor { Anchor() }

    func updateNSView(_ anchor: Anchor, context: Context) {}
}

@MainActor enum PlatformFileSave {
    static func save(_ file: URL) throws -> Bool {
        let panel = NSSavePanel()
        panel.nameFieldStringValue = file.lastPathComponent
        panel.canCreateDirectories = true
        guard panel.runModal() == .OK, let destination = panel.url else { return false }
        if FileManager.default.fileExists(atPath: destination.path) { try FileManager.default.removeItem(at: destination) }
        try FileManager.default.copyItem(at: file, to: destination)
        return true
    }
}
#endif

@MainActor final class BackgroundActivity {
    static let macLimit: Duration = .seconds(60)
    private static let log = Logger(subsystem: "haus.xmpp.ios", category: "lifecycle")

    #if os(iOS)
    private var task: UIBackgroundTaskIdentifier
    #else
    private var activity: (any NSObjectProtocol)?
    #endif

    // The name is logged: it names the work, never an account or chat. On iOS expiry ends the task only if no transport
    // lock is held here; otherwise iOS ends the process (0x2182bad2), freeing the lock, because a suspended holder is
    // killed (0xdead10cc) and blocks every extension run until then.
    init(_ name: String) {
        #if os(iOS)
        task = .invalid
        task = UIApplication.shared.beginBackgroundTask(withName: name) { [self] in
            MainActor.assumeIsolated { expire(name) }
        }
        if task == .invalid { Self.log.error("background time refused: \(name, privacy: .public)") }
        #else
        activity = ProcessInfo.processInfo.beginActivity(options: [.userInitiatedAllowingIdleSystemSleep], reason: name)
        Task { [weak self] in
            try? await Task.sleep(for: Self.macLimit)
            self?.end()
        }
        #endif
    }

    // nil on iOS, where the scene's own lifetime covers this work.
    static func burst(_ name: String) -> BackgroundActivity? {
        #if os(macOS)
        BackgroundActivity(name)
        #else
        nil
        #endif
    }

    #if os(iOS)
    private func expire(_ name: String) {
        guard !MessageStore.processHoldsTransportLock else {
            return Self.log.error("background time ran out holding the transport lease: \(name, privacy: .public)")
        }
        Self.log.notice("background time ran out, lease free: \(name, privacy: .public)")
        end()
    }
    #endif

    func end() {
        #if os(iOS)
        guard task != .invalid else { return }
        UIApplication.shared.endBackgroundTask(task)
        task = .invalid
        #else
        guard let activity else { return }
        ProcessInfo.processInfo.endActivity(activity)
        self.activity = nil
        #endif
    }
}
