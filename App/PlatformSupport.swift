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
}

/// Keeps the process running through one bounded piece of work: a UIKit background task on iOS, and on the Mac a
/// `ProcessInfo` activity that keeps App Nap away until the work ends or `macLimit` passes, whichever is first.
@MainActor final class BackgroundActivity {
    /// How long a Mac activity may hold off App Nap if the work never ends it.
    static let macLimit: Duration = .seconds(60)

    #if os(iOS)
    private var task: UIBackgroundTaskIdentifier
    #else
    private var activity: (any NSObjectProtocol)?
    #endif

    /// Begins the activity at once.
    init(_ name: String) {
        #if os(iOS)
        task = UIApplication.shared.beginBackgroundTask(withName: name)
        #else
        activity = ProcessInfo.processInfo.beginActivity(options: [.userInitiatedAllowingIdleSystemSleep], reason: name)
        Task { [weak self] in
            try? await Task.sleep(for: Self.macLimit)
            self?.end()
        }
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
