import MessageStore
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

    /// `.buttonStyle(.glassProminent)`. On the Mac, the bordered prominent push button: glass is for controls that
    /// float over content there, and a form's or sheet's main action is a push button.
    func prominentActionStyle() -> some View {
        #if os(iOS)
        buttonStyle(.glassProminent)
        #else
        buttonStyle(.borderedProminent)
        #endif
    }

    /// `.buttonStyle(.glass)`; the Mac's bordered push button, beside a `prominentActionStyle()` one.
    func secondaryActionStyle() -> some View {
        #if os(iOS)
        buttonStyle(.glass)
        #else
        buttonStyle(.bordered)
        #endif
    }

    /// A list row that is a button (an icon tile and a title) stays a row on the Mac, as a tapped row is on the
    /// iPhone, instead of becoming a bordered push button the width of its title. Nothing changes on iOS.
    func listRowButton() -> some View {
        #if os(iOS)
        self
        #else
        buttonStyle(ListRowButtonStyle())
        #endif
    }

    /// `.labelStyle(.iconOnly)` for a toolbar's Close: the iPhone's glyph-only bar button, and on the Mac, where a
    /// sheet's buttons sit at its bottom edge as push buttons, the word.
    func closeButtonLabel() -> some View {
        #if os(iOS)
        labelStyle(.iconOnly)
        #else
        labelStyle(.titleOnly)
        #endif
    }

    /// On the Mac, lets Quit, log out and shut down go ahead while this sheet is open. AppKit refuses to terminate
    /// while a modal window's `preventsApplicationTerminationWhenModal` is on, and SwiftUI leaves it on for some sheets,
    /// a form with Connect beside Cancel among them: Quit only beeps. For sheets whose unfinished input is not worth
    /// keeping the Mac up for. iOS has no such veto.
    func allowsQuitWhileOpen() -> some View {
        #if os(iOS)
        self
        #else
        background(TerminationPermission())
        #endif
    }
}

/// The iPhone's grouped `List`; on the Mac a grouped `Form`, whose rows, controls and section footers (wrapped in full,
/// where a Mac list cuts them to one line) are those of a Mac settings pane or inspector.
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
/// `listRowButton()`: the label across the row's width, the whole row the target, dimmed while pressed or disabled.
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

    /// Asks APNs for this app's device token; the application delegate receives it (`PushRegistration.received`).
    static func registerForRemoteNotifications() {
        #if os(iOS)
        UIApplication.shared.registerForRemoteNotifications()
        #else
        NSApp.registerForRemoteNotifications()
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

    /// The unread badge on the app's icon, through the notification centre: the badge a notification's `content.badge`
    /// sets from the extension, shown only where the user allows badges, and kept after the app quits. Where
    /// `dockTileOnly`, the Mac labels its own Dock tile instead, which needs no permission but lasts only while the app
    /// runs: before notifications are asked no extension runs, so nothing else writes the badge then. On the Mac each
    /// clears the other, so the Dock never shows two counts; iOS has only the notification centre's.
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
/// Clears `preventsApplicationTerminationWhenModal` on the sheet it joins (`allowsQuitWhileOpen`). SwiftUI sets the
/// sheet window's value as it presents the sheet, after the content has joined the window, so the value is cleared
/// again on the next pass of the main queue. Later updates of the sheet's content and toolbar leave it alone.
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

    /// Begins the activity at once. Its name goes to the log, so it names the work, never an account or a chat.
    ///
    /// On iOS, when background time runs out, the task ends there if no transport lock is held in this process: the
    /// app may then be suspended safely, and what the work had left resumes with it. While a lock is held the task is
    /// left running, so iOS ends the process (a background task not ended in time, 0x2182bad2), which frees the lock.
    /// Ending it instead would suspend the app holding the lock, which iOS also kills (0xdead10cc) and which keeps
    /// every extension run waiting until then; unlocking beneath the work that holds it would let two processes own
    /// the transport. A notification action decides the same way (`NotificationActionCenter.perform`).
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

    #if os(iOS)
    private func expire(_ name: String) {
        guard !MessageStore.processHoldsTransportLock else {
            return Self.log.error("background time ran out holding the transport lease: \(name, privacy: .public)")
        }
        Self.log.notice("background time ran out, lease free: \(name, privacy: .public)")
        end()
    }
    #endif

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
