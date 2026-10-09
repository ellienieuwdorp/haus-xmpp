#if DEBUG
import AppKit
import Security
import SwiftUI

/// Launch arguments for checking the Mac app without driving its UI: captures of its own windows, a timed quit, the
/// window state a capture needs, and a storage self-check. Debug builds only; nothing here ships.
///
/// The app is sandboxed, so it cannot write to a directory named on the command line. Captures go there when it can
/// (an unsandboxed run); otherwise each file is written to standard output as one line,
/// `HAUS-FILE <relative path> <base64>`, which `scripts/mac-app.sh` unpacks into the directory.
///
/// - `-haus-capture <dir>`: once the chats (and a selected chat's messages) are loaded and laid out, every visible
///   window as `<n>-<name>.png`, rendered from its own views (`cacheDisplay`), at the screen's scale.
/// - `-haus-capture-frames <dir> <seconds>`: the main window at about 10 frames a second, `frame-0001.png` onwards.
/// - `-haus-quit-after <seconds>`: quits that long after launch.
/// - `-haus-select <chat>`, `-haus-inspector`, `-haus-sheet account|new-chat|own-devices`,
///   `-haus-settings general|appearance`, `-haus-close-window <seconds>`: what the window shows.
/// - `-haus-self-check`: the App Group container, the store in it, and a data-protection Keychain round trip.
/// - `-haus-lab-sign-in`: signs in with `HAUS_LAB_USERNAME` and `HAUS_LAB_PASSWORD` (a lab account; pass
///   `-lab-ui-test` and `HAUS_LAB_CA_DER` for the lab's certificate authority, as the iPhone's lab tests do).
/// - `-haus-sign-out`: signs the saved account out after launch, to leave a lab run's Mac clean.
/// - `-haus-dump-menus`: the main menu's items and shortcuts.
/// - `-haus-fresh-store`: with `XMPP_UI_TEST_STORE` set, empties that session's store and preferences at launch, so a
///   run starts as a new install would (`scripts/mac-app.sh run --fresh-store`). The shared App Group store is left
///   alone.
/// - `-haus-unobtrusive`: see `MacUnobtrusive`.
@MainActor enum MacDebugHooks {
    private static let arguments = ProcessInfo.processInfo.arguments

    static func value(after flag: String, offset: Int = 1) -> String? {
        guard let index = arguments.firstIndex(of: flag), arguments.indices.contains(index + offset) else { return nil }
        return arguments[index + offset]
    }

    static func has(_ flag: String) -> Bool { arguments.contains(flag) }

    /// Quits as the menu's Quit does. `NSApp.terminate` called inside a main-actor job would keep that job, and with it
    /// the main queue, waiting in AppKit's loop for `reply(toApplicationShouldTerminate:)`, so the quiesce that sends
    /// the reply could never run (seen: the app hung until killed). The menu's Quit comes from an event, outside any
    /// job; this asks for it from the run loop the same way.
    static func quit() {
        NSApp.perform(#selector(NSApplication.terminate(_:)), with: nil, afterDelay: 0)
    }

    /// From `applicationWillFinishLaunching`, before any window exists and before the model opens its store.
    static func prepareLaunch() {
        MacUnobtrusive.install()
        if has("-haus-fresh-store") { emptyTestStore() }
    }

    /// The UI test session's own store (`SharedStorage.directory(testSessionID:)`) and preferences suite.
    private static func emptyTestStore() {
        guard let value = ProcessInfo.processInfo.environment["XMPP_UI_TEST_STORE"], let id = UUID(uuidString: value)?.uuidString,
              let support = try? FileManager.default.url(for: .applicationSupportDirectory, in: .userDomainMask, appropriateFor: nil, create: false) else {
            log("fresh store: XMPP_UI_TEST_STORE is not a session ID; nothing emptied")
            return
        }
        let directory = support.appending(path: "Messaging/UITests/" + id, directoryHint: .isDirectory)
        if FileManager.default.fileExists(atPath: directory.path) {
            do { try FileManager.default.removeItem(at: directory) } catch { log("fresh store: could not empty the session's store: \(error)") }
        }
        UserDefaults.standard.removePersistentDomain(forName: "haus.xmpp.uitest." + id)
        log("fresh store: session \(id)")
    }

    static func start(model: AppModel, window: MacWindowState) {
        // An earlier build wrote relative capture directories into the container; take them out again.
        if sandboxed {
            for flag in ["-haus-capture", "-haus-capture-frames"] {
                if let directory = value(after: flag), !directory.hasPrefix("/") { try? FileManager.default.removeItem(atPath: directory) }
            }
        }
        if let seconds = value(after: "-haus-quit-after").flatMap(Double.init) {
            Task {
                try? await Task.sleep(for: .seconds(seconds))
                log("quit after \(seconds) s; windows \(NSApp.windows.filter(\.isVisible).map { $0.identifier?.rawValue ?? $0.title }), "
                    + "Dock badge \(NSApp.dockTile.badgeLabel ?? "none"), connected \(model.session.isReady)")
                quit()
            }
        }
        if has("-haus-dump-menus") {
            Task {
                try? await Task.sleep(for: .seconds(1))
                dumpMenus()
            }
        }
        Task {
            await model.prepare()
            if has("-haus-lab-sign-in") { await labSignIn(model) }
            if has("-haus-self-check") { await selfCheck(model) }
            if has("-haus-sign-out") {
                await model.signOut()
                log("signed out")
            }
            await waitUntil(seconds: 15) { model.hasLoadedChats }
            log("chats loaded: \(model.chats.map(\.id))")
            if NSApp.windows.isEmpty, let open = window.openWindow {
                log("no window after launch; opening the main window")
                open(id: MacAppDelegate.mainWindowID)
                try? await Task.sleep(for: .milliseconds(500))
                log("windows now: \(NSApp.windows.map { "\($0.identifier?.rawValue ?? "-") visible \($0.isVisible)" })")
            } else if NSApp.windows.isEmpty {
                log("no window after launch and no openWindow action")
            }
            if let chat = value(after: "-haus-select") {
                window.selection = chat
                await waitUntil(seconds: 10) { model.messagesLoadedFor == chat }
                log("selected \(chat): \(model.messagesLoadedFor == chat ? "\(model.messages.count) messages" : "not loaded")")
            }
            if has("-haus-inspector") { window.inspectorShown = true }
            switch value(after: "-haus-sheet") {
            case "account": window.showingAccount = true
            case "new-chat": window.showingNewChat = true
            case "own-devices": window.reviewingOwnDevices = true
            default: break
            }
            if let seconds = value(after: "-haus-close-window").flatMap(Double.init) {
                try? await Task.sleep(for: .seconds(seconds))
                let main = NSApp.windows.filter { $0.identifier?.rawValue.hasPrefix(MacAppDelegate.mainWindowID) == true }
                log("closing \(main.count) main window(s)")
                main.forEach { $0.performClose(nil) }
            }
            // Layout, avatar loads and the sheet's presentation settle.
            try? await Task.sleep(for: .seconds(value(after: "-haus-capture-delay").flatMap(Double.init) ?? 1.5))
            if has("-haus-dump-views"), let root = NSApp.windows.first?.contentView?.superview { dumpViews(root, depth: 0) }
            if let directory = value(after: "-haus-capture") { captureWindows(to: directory) }
            if let directory = value(after: "-haus-capture-frames"), let seconds = value(after: "-haus-capture-frames", offset: 2).flatMap(Double.init) {
                await captureFrames(to: directory, seconds: seconds)
            }
        }
    }

    // MARK: Captures

    private static func captureWindows(to directory: String) {
        let windows = NSApp.windows.filter { $0.isVisible && $0.contentView != nil }
        for (index, window) in windows.enumerated() {
            guard let png = render(window) else { continue }
            let name = window.identifier?.rawValue.split(separator: "-").first.map(String.init) ?? "window"
            let title = window.title.isEmpty ? name : window.title
            let file = String(format: "%02d-%@.png", index + 1, slug(window.isSheet ? "sheet-\(title)" : title))
            emit(png, directory: directory, file: file)
        }
        log("captured \(windows.count) window(s)")
    }

    private static func captureFrames(to directory: String, seconds: Double) async {
        let clock = ContinuousClock(), end = clock.now + .seconds(seconds)
        var frame = 0
        while clock.now < end {
            let started = clock.now
            if let window = NSApp.windows.first(where: { $0.isVisible && $0.identifier?.rawValue.hasPrefix(MacAppDelegate.mainWindowID) == true }),
               let png = render(window) {
                frame += 1
                emit(png, directory: directory, file: String(format: "frame-%04d.png", frame))
            }
            try? await Task.sleep(until: started + .milliseconds(100), clock: clock)
        }
        log("captured \(frame) frame(s)")
    }

    /// The window's frame view, so the title bar and toolbar are in the picture with the content. Liquid Glass is
    /// drawn by the window server, so `cacheDisplay` leaves every glass view (the sidebar, toolbar buttons) blank with
    /// its content missing. Each one is painted over with a flat stand-in for its material, and its content is
    /// rendered on top of that; glass therefore reads as a flat fill in captures.
    private static func render(_ window: NSWindow) -> Data? {
        guard let view = window.contentView?.superview ?? window.contentView else { return nil }
        view.layoutSubtreeIfNeeded()
        guard let base = view.bitmapImageRepForCachingDisplay(in: view.bounds),
              let output = view.bitmapImageRepForCachingDisplay(in: view.bounds),
              let context = NSGraphicsContext(bitmapImageRep: output) else { return nil }
        view.cacheDisplay(in: view.bounds, to: base)
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = context
        window.effectiveAppearance.performAsCurrentDrawingAppearance {
            // What shows through where nothing opaque is drawn (the window server's backdrop).
            NSColor.windowBackgroundColor.setFill()
            view.bounds.fill()
            base.draw(in: view.bounds, from: .zero, operation: .sourceOver, fraction: 1, respectFlipped: false, hints: nil)
            for glass in descendants(of: view) where glass is NSGlassEffectView && !glass.isHiddenOrHasHiddenAncestor && glass.bounds.width > 0 {
                let frame = glass.convert(glass.bounds, to: view)
                let small = min(frame.width, frame.height) < 60
                let shape = small ? NSBezierPath(ovalIn: frame) : NSBezierPath(roundedRect: frame.insetBy(dx: 6, dy: 6), xRadius: 16, yRadius: 16)
                (small ? NSColor.quaternaryLabelColor : NSColor.underPageBackgroundColor).setFill()
                shape.fill()
                for holder in glass.subviews {
                    for content in holder.subviews where !content.isHidden && content.bounds.width > 0 {
                        draw(content, into: view)
                        // Table rows (the sidebar's chats) are left out of their table's cached image; each row
                        // renders on its own, clipped to what its scroll view shows.
                        for row in descendants(of: content) where row is NSTableRowView {
                            guard let clip = row.enclosingScrollView?.contentView else { continue }
                            let visible = clip.convert(clip.bounds, to: view).intersection(row.convert(row.bounds, to: view))
                            guard !visible.isEmpty else { continue }
                            NSGraphicsContext.saveGraphicsState()
                            visible.clip()
                            draw(row, into: view)
                            NSGraphicsContext.restoreGraphicsState()
                        }
                    }
                }
            }
        }
        NSGraphicsContext.restoreGraphicsState()
        return output.representation(using: .png, properties: [:])
    }

    private static func draw(_ part: NSView, into view: NSView) {
        guard let rep = part.bitmapImageRepForCachingDisplay(in: part.bounds) else { return }
        part.cacheDisplay(in: part.bounds, to: rep)
        rep.draw(in: part.convert(part.bounds, to: view), from: .zero, operation: .sourceOver, fraction: 1, respectFlipped: false, hints: nil)
    }

    private static func descendants(of view: NSView) -> [NSView] {
        view.subviews.flatMap { [$0] + descendants(of: $0) }
    }

    /// Set by the system for a sandboxed process, whose relative paths resolve inside its own container.
    private static let sandboxed = ProcessInfo.processInfo.environment["APP_SANDBOX_CONTAINER_ID"] != nil

    private static func emit(_ data: Data, directory: String, file: String) {
        if !sandboxed {
            let folder = URL(filePath: directory, directoryHint: .isDirectory)
            if (try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)) != nil,
               (try? data.write(to: folder.appending(path: file))) != nil { return }
        }
        // Sandboxed: hand the file to whoever reads standard output.
        let line = "HAUS-FILE \(file) \(data.base64EncodedString())\n"
        FileHandle.standardOutput.write(Data(line.utf8))
    }

    private static func slug(_ text: String) -> String {
        let allowed = text.lowercased().map { $0.isLetter || $0.isNumber ? $0 : "-" }
        return String(allowed).split(separator: "-").joined(separator: "-")
    }

    // MARK: Checks

    private static func labSignIn(_ model: AppModel) async {
        let environment = ProcessInfo.processInfo.environment
        guard let username = environment["HAUS_LAB_USERNAME"], let password = environment["HAUS_LAB_PASSWORD"] else {
            log("lab sign-in: HAUS_LAB_USERNAME and HAUS_LAB_PASSWORD are not set")
            return
        }
        let connected = await model.connect(username: username, password: password)
        log("lab sign-in: \(connected ? "connected" : "failed: \(model.session.label)")")
    }

    /// What the plan asks of a signed build: the store opens inside the App Group container, SharedStorage's container
    /// probe passes, and a data-protection Keychain item round-trips (and the encryption key, once one exists, is
    /// readable from the app's access group).
    private static func selfCheck(_ model: AppModel) async {
        var report: [String] = []
        do {
            let container = try SharedStorage.groupContainer()
            report.append("group container: ok \(container.path)")
            let database = container.appending(path: "Messaging/messages.sqlite")
            report.append("store in group container: \(FileManager.default.fileExists(atPath: database.path) ? "yes" : "no") \(database.path)")
        } catch {
            let url = FileManager.default.containerURL(forSecurityApplicationGroupIdentifier: SharedStorage.group)
            var isDirectory: ObjCBool = false
            let exists = url.map { FileManager.default.fileExists(atPath: $0.path, isDirectory: &isDirectory) } ?? false
            let writable = url.map { FileManager.default.isWritableFile(atPath: $0.path) } ?? false
            var write = "not tried"
            if let url {
                let probe = url.appending(path: "self-check-\(UUID().uuidString)")
                do { try Data().write(to: probe); try FileManager.default.removeItem(at: probe); write = "ok" } catch { write = "\(error)" }
            }
            report.append("group container: FAILED \(error); url \(url?.path ?? "nil"), exists \(exists), directory \(isDirectory.boolValue), writable \(writable), probe write \(write)")
        }
        report.append("store opened: \(model.hasLoadedChats && model.error == nil ? "yes" : "no \(model.error ?? "not loaded")")")
        report.append("keychain round trip: \(keychainRoundTrip())")
        report.append("encryption key: \(encryptionKeyAccessGroup())")
        report.forEach { log("self-check \($0)") }
    }

    private static func keychainRoundTrip() -> String {
        let query = KeychainQuery.genericPassword(service: "haus.xmpp.self-check", account: UUID().uuidString)
        var item = query
        item[kSecValueData as String] = Data("self-check".utf8)
        item[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
        let added = SecItemAdd(item as CFDictionary, nil)
        guard added == errSecSuccess else { return "FAILED add \(added)" }
        defer { SecItemDelete(query as CFDictionary) }
        var lookup = query
        lookup[kSecReturnData as String] = true
        lookup[kSecReturnAttributes as String] = true
        var result: CFTypeRef?
        let status = SecItemCopyMatching(lookup as CFDictionary, &result)
        guard status == errSecSuccess, let attributes = result as? [String: Any],
              attributes[kSecValueData as String] as? Data == Data("self-check".utf8) else { return "FAILED read \(status)" }
        return "ok, access group \(attributes[kSecAttrAccessGroup as String] as? String ?? "?")"
    }

    private static func encryptionKeyAccessGroup() -> String {
        var lookup = KeychainQuery.genericPassword(service: "haus.xmpp.encryption-state", account: "primary")
        lookup[kSecReturnAttributes as String] = true
        var result: CFTypeRef?
        let status = SecItemCopyMatching(lookup as CFDictionary, &result)
        guard status == errSecSuccess, let attributes = result as? [String: Any] else {
            return status == errSecItemNotFound ? "none yet" : "FAILED \(status)"
        }
        return "present, access group \(attributes[kSecAttrAccessGroup as String] as? String ?? "?")"
    }

    private static func dumpViews(_ view: NSView, depth: Int) {
        guard depth < 18 else { return }
        let frame = view.convert(view.bounds, to: nil)
        log("view \(String(repeating: " ", count: depth))\(type(of: view)) \(Int(frame.minX)),\(Int(frame.minY)) \(Int(frame.width))x\(Int(frame.height)) layer \(view.layer.map { "\(type(of: $0))" } ?? "-")")
        for subview in view.subviews { dumpViews(subview, depth: depth + 1) }
    }

    private static func dumpMenus() {
        func walk(_ menu: NSMenu, depth: Int) {
            for item in menu.items where !item.isSeparatorItem {
                let key = item.keyEquivalent.isEmpty ? "" : " [\(item.keyEquivalentModifierMask.contains(.shift) ? "⇧" : "")⌘\(item.keyEquivalent)]"
                log("menu \(String(repeating: "  ", count: depth))\(item.title)\(key)")
                if let submenu = item.submenu, depth < 2 { walk(submenu, depth: depth + 1) }
            }
        }
        if let menu = NSApp.mainMenu { walk(menu, depth: 0) }
    }

    // MARK: Helpers

    private static func waitUntil(seconds: Double, _ condition: @MainActor () -> Bool) async {
        let clock = ContinuousClock(), end = clock.now + .seconds(seconds)
        while !condition(), clock.now < end { try? await Task.sleep(for: .milliseconds(100)) }
    }

    static func log(_ text: String) {
        FileHandle.standardOutput.write(Data("HAUS \(text)\n".utf8))
    }
}

/// Opens the Settings window when `-haus-settings` asks for it; Settings is opened through the environment, so this
/// sits on the main window's content.
struct MacDebugPresentation: ViewModifier {
    let window: MacWindowState
    @Environment(\.openSettings) private var openSettings

    func body(content: Content) -> some View {
        content.task {
            guard MacDebugHooks.has("-haus-settings") else { return }
            try? await Task.sleep(for: .milliseconds(300))
            openSettings()
        }
    }
}
#endif
