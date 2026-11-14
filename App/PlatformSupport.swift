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

    // UIKit reports a huge value until the app is really in the background; iOS then grants about 30 s.
    static var backgroundTimeRemaining: Duration? {
        #if os(iOS)
        let remaining = UIApplication.shared.backgroundTimeRemaining
        return remaining > 600 ? .seconds(30) : .milliseconds(Int(remaining * 1000))
        #else
        nil
        #endif
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

    private let name: String
    #if os(iOS)
    private var task: UIBackgroundTaskIdentifier
    private let onExpire: (@MainActor () -> Void)?
    // Counted with `StorageParking` from init, even when iOS refused the time.
    private var ended = false
    #else
    private var activity: (any NSObjectProtocol)?
    #endif

    // The name is logged, so it names the work, never an account or chat. On iOS expiry runs `onExpire`, then ends the
    // task only while no transport lock is held; otherwise iOS ends the process (0x2182bad2), freeing the lock. A
    // suspended holder is killed too (0xdead10cc), and unlocking under live work would let two processes own it.
    init(_ name: String, onExpire: (@MainActor () -> Void)? = nil) {
        self.name = name
        #if os(iOS)
        self.onExpire = onExpire
        task = .invalid
        task = UIApplication.shared.beginBackgroundTask(withName: name) { [self] in
            MainActor.assumeIsolated { expire(name) }
        }
        StorageParking.shared.hold(granted: task != .invalid)
        if task == .invalid { Self.log.error("background time refused: \(name, privacy: .public)") }
        else { Self.log.notice("background activity began: \(name, privacy: .public)") }
        #else
        activity = ProcessInfo.processInfo.beginActivity(options: [.userInitiatedAllowingIdleSystemSleep], reason: name)
        Task { [weak self] in
            try? await Task.sleep(for: Self.macLimit)
            self?.end()
        }
        #endif
    }

    static func during(_ name: String, _ work: () async -> Void) async {
        let activity = BackgroundActivity(name)
        defer { activity.end() }
        await work()
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
        onExpire?()
        guard !MessageStore.processHoldsTransportLock else {
            return Self.log.error("background time ran out holding the transport lease: \(name, privacy: .public)")
        }
        Self.log.notice("background time ran out, lease free: \(name, privacy: .public)")
        end()
    }
    #endif

    // On iOS the last end away from the front waits for `StorageParking`.
    func end() {
        #if os(iOS)
        guard !ended else { return }
        ended = true
        let task = task, name = name
        self.task = .invalid
        StorageParking.shared.release {
            guard task != .invalid else { return }
            UIApplication.shared.endBackgroundTask(task)
            Self.log.notice("background activity ended: \(name, privacy: .public)")
        }
        #else
        guard let activity else { return }
        ProcessInfo.processInfo.endActivity(activity)
        self.activity = nil
        #endif
    }
}

// iOS ends an app suspended holding a file lock in the App Group (0xdead10cc); an idle WAL connection locks the database
// and its -shm. So the last background time away from the front ends only once every store has closed SQLite and may
// not reopen until the front or new background time. A failed or late park keeps the time. The Mac never parks.
@MainActor final class StorageParking {
    static let shared = StorageParking()
    private static let log = Logger(subsystem: "haus.xmpp.ios", category: "lifecycle")
    let deadline: Duration = .seconds(2)
    var clock: any Clock<Duration> = ContinuousClock()
    private(set) var holders = 0
    // Background time a failed park keeps until the front or another background time.
    var kept: Int { waiting.count }
    private var inFront = true
    var parkStores: @MainActor () async -> Bool = { await MessageStore.parkAll() }
    // Background time whose end waits for a park.
    private var waiting: [@MainActor () -> Void] = []
    private var parking: Task<Void, Never>?
    // Counts every reopening, so a park that overlapped one parks again.
    private var reopenings = 0

    func sceneChanged(active: Bool) {
        inFront = active
        if active { resume() }
    }

    // Refused time still counts, so its release balances, but cannot replace time a failed park is keeping.
    func hold(granted: Bool) {
        holders += 1
        allowReopening()
        if granted { endWaiting() }
    }

    // For a move to the background that ended no background time: parks unless something still holds time.
    func parkIfIdle() {
        guard holders == 0, !inFront, parking == nil else { return }
        parking = Task { await park() }
    }

    // `finish` ends the background time, at once unless it is the last held away from the front.
    func release(_ finish: @escaping @MainActor () -> Void) {
        holders -= 1
        guard holders == 0, !inFront else { return finish() }
        waiting.append(finish)
        if parking == nil { parking = Task { await park() } }
    }

    // Returns once no park is under way.
    func settled() async {
        while let parking { await parking.value }
    }

    // Storage may reopen, and background time a park was holding back ends: the front or newer time covers the work.
    private func resume() {
        allowReopening()
        endWaiting()
    }

    private func allowReopening() {
        reopenings += 1
        MessageStore.reopeningAllowed = true
    }

    private func endWaiting() {
        let finished = waiting
        waiting = []
        for finish in finished { finish() }
    }

    private func park() async {
        defer { parking = nil }
        var parked = false, started = reopenings - 1
        // Background time begun meanwhile may have reopened a store and ended again: then parking starts over.
        while started != reopenings {
            // Background time still held, or the front, keeps storage open; its own end parks again.
            guard holders == 0, !inFront else { return resume() }
            started = reopenings
            MessageStore.reopeningAllowed = false
            parked = await parkWithinDeadline()
        }
        guard holders == 0, !inFront else { return resume() }
        guard parked else { return Self.log.fault("storage not parked in time or refused: background time kept") }
        guard !MessageStore.processHasOpenConnection else { return Self.log.fault("a SQLite connection is still open: background time kept") }
        Self.log.notice("storage parked")
        endWaiting()
    }

    private func parkWithinDeadline() async -> Bool {
        let race = ParkingRace()
        let parkStores = self.parkStores, clock = self.clock, deadline = self.deadline
        return await withCheckedContinuation { continuation in
            race.continuation = continuation
            let timer = Task { @MainActor in
                guard (try? await clock.sleep(for: deadline)) != nil else { return }
                race.finish(false)
            }
            Task { @MainActor in
                let parked = await parkStores()
                timer.cancel()
                race.finish(parked)
            }
        }
    }
}

@MainActor private final class ParkingRace {
    var continuation: CheckedContinuation<Bool, Never>?
    func finish(_ parked: Bool) {
        continuation?.resume(returning: parked)
        continuation = nil
    }
}
