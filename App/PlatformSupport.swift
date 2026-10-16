import OSLog
import SwiftUI
import UserNotifications
#if os(iOS)
import UIKit
#else
import AppKit
#endif

// The small seams that let the shared app code build for iOS and macOS. Each one is the iOS call it replaced, unchanged,
// on iOS; the macOS side is the nearest Mac equivalent. Anything larger than a seam lives in a platform's own view
// files (the iPhone's UIKit views, the Mac's views in Mac/), not here.

#if os(iOS)
typealias PlatformColor = UIColor
typealias PlatformImage = UIImage
#else
typealias PlatformColor = NSColor
typealias PlatformImage = NSImage
#endif

extension Color {
    init(platform color: PlatformColor) {
        #if os(iOS)
        self.init(uiColor: color)
        #else
        self.init(nsColor: color)
        #endif
    }
}

extension Image {
    init(platformImage image: PlatformImage) {
        #if os(iOS)
        self.init(uiImage: image)
        #else
        self.init(nsImage: image)
        #endif
    }
}

extension PlatformColor {
    /// One colour per appearance, resolved by the view or layer that draws it.
    static func dynamic(light: PlatformColor, dark: PlatformColor) -> PlatformColor {
        #if os(iOS)
        UIColor { $0.userInterfaceStyle == .dark ? dark : light }
        #else
        NSColor(name: nil) { $0.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua ? dark : light }
        #endif
    }
}

#if os(macOS)
extension NSImage {
    /// `UIImage(cgImage:)`: the image at its pixel size, one point per pixel.
    convenience init(cgImage: CGImage) {
        self.init(cgImage: cgImage, size: .zero)
    }
}
#endif

/// The system colours the shared screens name, with the Mac's nearest equivalent where macOS has no such colour.
extension Color {
    /// iOS `systemGroupedBackground`: the page behind grouped lists and sheets.
    static var groupedBackground: Color {
        #if os(iOS)
        Color(.systemGroupedBackground)
        #else
        Color(nsColor: .windowBackgroundColor)
        #endif
    }

    /// iOS `secondarySystemGroupedBackground`: a card or tile on the grouped background.
    static var secondaryGroupedBackground: Color {
        #if os(iOS)
        Color(.secondarySystemGroupedBackground)
        #else
        Color(nsColor: .controlBackgroundColor)
        #endif
    }

    /// iOS `tertiarySystemFill`: the received bubble's fill.
    static var tertiaryFill: Color {
        #if os(iOS)
        Color(uiColor: .tertiarySystemFill)
        #else
        Color(nsColor: .tertiarySystemFill)
        #endif
    }

    /// iOS `systemGray3`: an avatar circle with no address to colour it by.
    static var placeholderGray: Color {
        #if os(iOS)
        Color(.systemGray3)
        #else
        Color(nsColor: .systemGray)
        #endif
    }
}

extension Color {
    /// iOS `secondaryLabel`.
    static var secondaryLabel: Color {
        #if os(iOS)
        Color(uiColor: .secondaryLabel)
        #else
        Color(nsColor: .secondaryLabelColor)
        #endif
    }
}

#if os(iOS)
typealias PlatformKeyboard = UIKeyboardType
#else
/// The iPhone keyboards the shared fields ask for; a Mac has one keyboard and ignores them.
enum PlatformKeyboard { case emailAddress, URL, numberPad }
#endif

/// The iOS-only modifiers the shared screens use, as no-ops (or the nearest Mac style) on the Mac.
extension View {
    /// `navigationBarTitleDisplayMode(.inline)`. Mac titles are always inline.
    func inlineNavigationTitle() -> some View {
        #if os(iOS)
        navigationBarTitleDisplayMode(.inline)
        #else
        self
        #endif
    }

    /// `textInputAutocapitalization(.never)`, for addresses, hosts and nicknames.
    func noAutocapitalization() -> some View {
        #if os(iOS)
        textInputAutocapitalization(.never)
        #else
        self
        #endif
    }

    /// `textInputAutocapitalization(.characters)`, for codes.
    func capitalizedCharacters() -> some View {
        #if os(iOS)
        textInputAutocapitalization(.characters)
        #else
        self
        #endif
    }

    /// `keyboardType(_:)`.
    func keyboard(_ type: PlatformKeyboard) -> some View {
        #if os(iOS)
        keyboardType(type)
        #else
        self
        #endif
    }

    /// `.listStyle(.insetGrouped)`; the Mac's inset list.
    func groupedListStyle() -> some View {
        #if os(iOS)
        listStyle(.insetGrouped)
        #else
        listStyle(.inset)
        #endif
    }
}

extension ToolbarItemPlacement {
    /// `.topBarLeading`; the toolbar's navigation area on the Mac.
    static var barLeading: ToolbarItemPlacement {
        #if os(iOS)
        .topBarLeading
        #else
        .navigation
        #endif
    }

    /// `.topBarTrailing`; the toolbar's primary action area on the Mac.
    static var barTrailing: ToolbarItemPlacement {
        #if os(iOS)
        .topBarTrailing
        #else
        .primaryAction
        #endif
    }
}

/// Process state the model reads where it used to ask `UIApplication`.
@MainActor enum PlatformApplication {
    /// True when iOS launched or left the app in the background (a notification action). A Mac app is never launched
    /// that way: an action there reaches a running process, or launches it like the Dock icon does.
    static var isInBackground: Bool {
        #if os(iOS)
        UIApplication.shared.applicationState == .background
        #else
        false
        #endif
    }

    /// The system's notification settings for this app: the app's page in iOS Settings, or System Settings >
    /// Notifications on the Mac.
    static var notificationSettingsURL: URL? {
        #if os(iOS)
        URL(string: UIApplication.openNotificationSettingsURLString)
        #else
        URL(string: "x-apple.systempreferences:com.apple.Notifications-Settings.extension?id=" + (Bundle.main.bundleIdentifier ?? ""))
        #endif
    }

    /// The unread badge on the app's icon. iOS sets it through the notification centre, which needs badge permission;
    /// the Mac sets its Dock tile, which needs none (and the Mac asks for no notification permission yet).
    static func setBadgeCount(_ count: Int) async {
        #if os(iOS)
        try? await UNUserNotificationCenter.current().setBadgeCount(count)
        #else
        NSApp.dockTile.badgeLabel = count > 0 ? String(count) : nil
        #endif
    }

    static var didBecomeActiveNotification: Notification.Name {
        #if os(iOS)
        UIApplication.didBecomeActiveNotification
        #else
        NSApplication.didBecomeActiveNotification
        #endif
    }

    /// The app's icon, for the About screen. On the Mac it comes with its shape; on iOS it is the square artwork, which
    /// the iPhone target bundles as a plain image (an app icon set cannot be loaded by name).
    static var iconImage: PlatformImage? {
        #if os(iOS)
        Bundle.main.path(forResource: "AppIcon", ofType: "png").flatMap(UIImage.init(contentsOfFile:))
        #else
        NSApp.applicationIconImage
        #endif
    }
}

/// The general pasteboard.
@MainActor enum PlatformPasteboard {
    /// `UIPasteboard.general.string = text`.
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
/// The Mac's Save panel for a file the app made, which it then copies there. iOS saves through the share sheet.
@MainActor enum PlatformFileSave {
    /// False when the user cancelled; throws when the copy failed.
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

/// Keeps the process running through one bounded piece of work: a UIKit background task on iOS, and on the Mac a
/// `ProcessInfo` activity that keeps App Nap away until the work ends or `macLimit` passes, whichever is first.
@MainActor final class BackgroundActivity {
    /// How long a Mac activity may hold off App Nap if the work never ends it.
    static let macLimit: Duration = .seconds(60)
    private static let log = Logger(subsystem: "haus.xmpp.ios", category: "lifecycle")

    #if os(iOS)
    private var task: UIBackgroundTaskIdentifier
    #else
    private var activity: (any NSObjectProtocol)?
    #endif

    /// Begins the activity at once. On iOS a task still running when background time runs out is left running, so iOS
    /// ends the process: work that holds the transport lease is never cut short with the lease kept, or the lease given
    /// up beneath it. Its name goes to the log, so it names the work, never an account or a chat.
    init(_ name: String) {
        #if os(iOS)
        task = UIApplication.shared.beginBackgroundTask(withName: name) {
            Self.log.error("background time ran out: \(name, privacy: .public)")
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

    /// Mac only: an activity for work that should finish promptly once started but needs no protection from
    /// suspension (archive catch-up, the outbox drain). nil on iOS, where the scene's own lifetime covers that work
    /// and no background task is begun for it.
    static func burst(_ name: String) -> BackgroundActivity? {
        #if os(macOS)
        BackgroundActivity(name)
        #else
        nil
        #endif
    }

    /// Ends the activity; later calls do nothing.
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
