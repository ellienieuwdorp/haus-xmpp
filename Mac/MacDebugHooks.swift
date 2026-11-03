#if DEBUG
import AppKit
import MessageStore
import Security
import SQLite3
import MessagingCore
import OMEMO
import SwiftUI
import XMPPProtocol

// Debug-only launch arguments and tour steps for checking the Mac app without driving its UI. The sandboxed app cannot
// write to a directory named on the command line, so a sandboxed capture writes each file to standard output as
// `HAUS-FILE <relative path> <base64>` for the launcher to decode.
@MainActor enum MacDebugHooks {
    private static let arguments = ProcessInfo.processInfo.arguments

    static func value(after flag: String, offset: Int = 1) -> String? {
        guard let index = arguments.firstIndex(of: flag), arguments.indices.contains(index + offset) else { return nil }
        return arguments[index + offset]
    }

    static func has(_ flag: String) -> Bool { arguments.contains(flag) }

    // `NSApp.terminate` inside a main-actor job keeps the main queue waiting in AppKit's loop for
    // `reply(toApplicationShouldTerminate:)`, so the quiesce that sends the reply never runs and the app hangs. The
    // menu's Quit comes from an event, outside any job; this asks from the run loop the same way.
    static func quit() {
        NSApp.perform(#selector(NSApplication.terminate(_:)), with: nil, afterDelay: 0)
    }

    // Before any window exists and before the model opens its store.
    static func prepareLaunch() {
        MacUnobtrusive.install()
        if has("-haus-fresh-store") { emptyTestStore() }
        if has("-haus-connecting") { tour.connecting = true }
        if MacDebugNotificationLog.silencesTestSession {
            log("notifications: off in this test session; -haus-log-notifications logs them")
        }
        if let schema = value(after: "-haus-store-schema").flatMap(Int32.init) { stampTestStore(schema: schema) }
    }

    // The UI test session's own store, never the shared one.
    private static func testStoreDirectory() -> URL? {
        guard let value = ProcessInfo.processInfo.environment["XMPP_UI_TEST_STORE"], let id = UUID(uuidString: value)?.uuidString,
              let support = try? FileManager.default.url(for: .applicationSupportDirectory, in: .userDomainMask, appropriateFor: nil, create: false) else {
            return nil
        }
        return support.appending(path: "Messaging/UITests/" + id, directoryHint: .isDirectory)
    }

    private static func stampTestStore(schema: Int32) {
        guard let database = testStoreDirectory()?.appending(path: "messages.sqlite"),
              FileManager.default.fileExists(atPath: database.path) else {
            log("store schema: no test session store to stamp")
            return
        }
        var connection: OpaquePointer?
        defer { sqlite3_close(connection) }
        let result = sqlite3_open(database.path, &connection) == SQLITE_OK
            ? sqlite3_exec(connection, "PRAGMA user_version=\(schema)", nil, nil, nil) : SQLITE_CANTOPEN
        log("store schema: stamped \(schema), result \(result)")
    }

    private static func emptyTestStore() {
        guard let directory = testStoreDirectory() else { return log("fresh store: XMPP_UI_TEST_STORE is not a session ID; nothing emptied") }
        let id = directory.lastPathComponent
        if FileManager.default.fileExists(atPath: directory.path) {
            do { try FileManager.default.removeItem(at: directory) } catch { log("fresh store: could not empty the session's store: \(error)") }
        }
        UserDefaults.standard.removePersistentDomain(forName: "haus.xmpp.uitest." + id)
        // A transfer's folder and its preferences beside the session (`AccountTransfer.Locations.testSession`).
        try? FileManager.default.removeItem(at: directory.deletingLastPathComponent().appending(path: id + "-group"))
        UserDefaults.standard.removePersistentDomain(forName: "haus.xmpp.uitest.\(id).group")
        log("fresh store: session \(id)")
    }

    static func start(model: AppModel, window: MacWindowState, lifecycle: MacLifecycle) {
        // Sandboxed captures go to standard output, so a relative capture directory in the container is stale: remove
        // it.
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
        MacPushProbe.start()
        if has("-haus-dump-menus") {
            Task {
                try? await Task.sleep(for: .seconds(1))
                dumpMenus()
            }
        }
        Task {
            await model.prepare()
            if has("-haus-lab-sign-in") { await labSignIn(model) }
            await MacPushProbe.afterSignIn(model)
            if has("-haus-self-check") { await selfCheck(model) }
            if let text = value(after: "-haus-restore-transfer") {
                let file = FileManager.default.temporaryDirectory.appending(path: "restore.\(TransferArchive.fileExtension)")
                try? FileHandle.standardInput.readToEnd()?.write(to: file)
                defer { try? FileManager.default.removeItem(at: file) }
                if let code = TransferCode(text) {
                    let problem = await model.restoreTransfer(from: file, code: code)
                    log("restore transfer: \(problem ?? "restored"); account \(model.accountID)")
                } else { log("restore transfer: not a code") }
            }
            switch value(after: "-haus-transfer") {
            case "start":
                await model.startTransfer()
                if case let .moved(moved) = model.transferState { log("transfer: moved, \(moved.fileName), \(moved.fileSize) bytes") }
                else { log("transfer: not moved (\(model.error ?? "no error"))") }
            case "delete":
                await model.deleteMovedData()
                log("transfer: data deleted; account \(model.accountID.isEmpty ? "none" : model.accountID)")
            case "resume":
                await model.useDataHereAgain()
                log("transfer: using the data here again; account \(model.accountID)")
            default: break
            }
            if has("-haus-sign-out") {
                await model.signOut()
                log("signed out")
            }
            await waitUntil(seconds: 15) { model.hasLoadedChats }
            log("chats loaded: \(model.chats.map(\.id))")
            if let link = value(after: "-haus-share-sheet") { await MacShareDebug.run(link, model: model) }
            if mainWindow == nil {
                log("no main window after launch; opening it")
                window.showMainWindow()
            }
            if let size = value(after: "-haus-window-size")?.split(separator: "x").compactMap({ Double($0) }), size.count == 2, let main = mainWindow {
                main.setContentSize(NSSize(width: size[0], height: size[1]))
                log("window content size \(main.contentLayoutRect.size)")
            }
            // A sample chat linked by name only, as a link made without Contacts access: Contacts is never read.
            if let chat = value(after: "-haus-contact-link"), let name = value(after: "-haus-contact-link", offset: 2), model.isDemo {
                let linked = await model.contactLinks.link(chat, to: ContactCard(id: "sample-" + chat, name: name, thumbnail: nil, jabberAddresses: []),
                                                           source: .picker)
                log("contact link \(chat): \(linked ? "saved" : "failed")")
            }
            if let tour = value(after: "-haus-tour") {
                await runTour(tour, window: window, model: model)
                if let steps = value(after: "-haus-lifecycle-steps") {
                    await MacLifecycleDebug.run(steps, lifecycle: lifecycle, model: model, window: window)
                }
                return
            }
            // Sample conversations block locally, so a capture can show a blocked chat without a server.
            if let chat = value(after: "-haus-block"), model.isDemo { await model.block(chat) }
            if let chat = value(after: "-haus-select") {
                window.selection = chat
                await waitUntil(seconds: 10) { model.messagesLoadedFor == chat }
                log("selected \(chat): \(model.messagesLoadedFor == chat ? "\(model.messages.count) messages" : "not loaded")")
            }
            if has("-haus-inspector") { window.inspectorShown = true }
            if let page = value(after: "-haus-inspector-page") { showInspectorPage(page, window: window, model: model) }
            switch value(after: "-haus-sheet") {
            case "account": window.showingAccount = true
            case "new-chat": window.showingNewChat = true
            case "own-devices": window.reviewingOwnDevices = true
            case "restore": window.showingRestore = true
            default: break
            }
            if let seconds = value(after: "-haus-close-window").flatMap(Double.init) {
                try? await Task.sleep(for: .seconds(seconds))
                let main = NSApp.windows.filter { $0.identifier?.rawValue.hasPrefix(MacAppDelegate.mainWindowID) == true }
                log("closing \(main.count) main window(s)")
                main.forEach { $0.performClose(nil) }
            }
            if let steps = value(after: "-haus-lifecycle-steps") {
                await MacLifecycleDebug.run(steps, lifecycle: lifecycle, model: model, window: window)
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

    static var openSettings: OpenSettingsAction?

    @Observable @MainActor final class Tour {
        var settingsPane: MacSettingsView.Pane?
        // `serial` makes a repeated request a change.
        var messageRequest: MessageRequest?
        var hoveredMessage: String?
        var dropHighlight = false
        var connecting = false
        func setMessageRequest(_ request: MessageRequest) {
            messageRequest = request
        }

        func setHoveredMessage(_ id: String?) {
            hoveredMessage = id
        }
    }

    struct MessageRequest: Equatable {
        let verb: String
        let messageID: String
        let argument: String
        let serial: Int
    }

    static let tour = Tour()

    private static func showInspectorPage(_ page: String, window: MacWindowState, model: AppModel) {
        guard let chatID = window.selection else { return }
        window.inspectorPath = page == "encryption" ? [model.isGroup(chatID) ? .groupDetails(chatID) : .encryption(chatID)] : []
    }

    // Toggles faster than the inspector animates, in a window too narrow for it, so opening widens the window and an
    // interrupting close narrows it back; overlapping animations can leave the conversation's width pinned.
    private static func inspectorRace(_ argument: String, window: MacWindowState, main: NSWindow?) async {
        let size = argument.split(separator: "x").compactMap { Double($0) }
        guard size.count == 2, let main, window.selection != nil else {
            return log("tour inspector-race \(argument): needs <width>x<height>, the main window and a chat")
        }
        func resize(to width: Double) async -> Int {
            main.setContentSize(NSSize(width: width, height: size[1]))
            try? await Task.sleep(for: .seconds(0.5))
            return Int(main.contentRect(forFrameRect: main.frame).width)
        }
        if window.inspectorShown {
            window.inspectorShown = false
            try? await Task.sleep(for: .seconds(1))
        }
        _ = await resize(to: size[0])
        for shown in [true, false, true] {
            window.inspectorShown = shown
            try? await Task.sleep(for: .milliseconds(60))
        }
        try? await Task.sleep(for: .seconds(1))
        let opened = Int(main.contentRect(forFrameRect: main.frame).width)
        let wide = await resize(to: size[0] + 440)
        window.inspectorShown = false
        try? await Task.sleep(for: .seconds(1))
        let narrow = await resize(to: size[0] + 140)
        let stuck = wide != Int(size[0]) + 440 || narrow != Int(size[0]) + 140
        log("inspector-race \(argument): opened to \(opened), asked \(Int(size[0]) + 440) got \(wide), hidden asked \(Int(size[0]) + 140) "
            + "got \(narrow): \(stuck ? "STUCK" : "ok")")
    }

    // The build ahead waits for half a second with no key, click or scroll; a pointer move right after a key can hide
    // the key from it (`currentEvent` is the move). Events go on the app's own queue, never through the window server.
    private static func prebuildQuiet(_ chat: String, window: MacWindowState, main: NSWindow?) async {
        guard let main, !chat.isEmpty, window.selection != chat else {
            return log("tour prebuild-quiet \(chat): needs the main window and a chat other than the open one")
        }
        let uptime = { ProcessInfo.processInfo.systemUptime }
        func format(_ seconds: TimeInterval) -> String { String(format: "%.2f", seconds) }
        func post(_ event: NSEvent?, at time: TimeInterval) async -> TimeInterval {
            try? await Task.sleep(for: .seconds(max(0, time - uptime())))
            if let event { NSApp.postEvent(event, atStart: false) }
            return uptime()
        }
        let chosen = uptime()
        window.selection = chat
        let key = await post(NSEvent.keyEvent(with: .flagsChanged, location: .zero, modifierFlags: [], timestamp: uptime(), windowNumber: 0,
                                              context: nil, characters: "", charactersIgnoringModifiers: "", isARepeat: false, keyCode: 56), at: chosen + 0.4)
        let moved = await post(NSEvent.mouseEvent(with: .mouseMoved, location: .zero, modifierFlags: [], timestamp: uptime(), windowNumber: main.windowNumber,
                                                  context: nil, eventNumber: 0, clickCount: 0, pressure: 0), at: chosen + 0.45)
        while uptime() < chosen + 2, MacInspectorController.debugBuiltAhead.map({ $0.chat != chat || $0.at < chosen }) ?? true {
            try? await Task.sleep(for: .milliseconds(5))
        }
        let line = "key at \(format(key - chosen)) s, pointer move at \(format(moved - chosen)) s"
        guard let built = MacInspectorController.debugBuiltAhead, built.chat == chat, built.at >= chosen else {
            // A closed inspector that has not been in the window since launch (one too narrow for it) builds nothing.
            return log("prebuild-quiet \(chat): \(line), not built within 2 s")
        }
        let verdict = built.at < key ? "built before the key: no answer" : built.at - key < 0.5 ? "EARLY" : "ok"
        log("prebuild-quiet \(chat): \(line), built at \(format(built.at - chosen)) s, \(format(built.at - key)) s after the key: \(verdict)")
    }

    // A tracking loop takes a press's drags and release without the app handing them out, so the input monitor sees
    // only the press. The press goes through `sendEvent`; the drags and the release go on the app's queue for the
    // step's loop to take in the tracking mode, as a control would.
    private static func prebuildTracking(_ argument: String, window: MacWindowState, main: NSWindow?) async {
        let words = argument.split(separator: " ").map(String.init)
        let chat = words.first ?? "", release = words.dropFirst().first.flatMap(Double.init) ?? 0.45
        guard let main, !chat.isEmpty, window.selection != chat, release > 0.3 else {
            return log("tour prebuild-tracking \(argument): needs the main window, a chat other than the open one and a release after 0.3 s")
        }
        let uptime = { ProcessInfo.processInfo.systemUptime }
        func format(_ seconds: TimeInterval) -> String { String(format: "%.2f", seconds) }
        let chosen = uptime()
        window.selection = chat
        try? await Task.sleep(for: .seconds(max(0, chosen + 0.05 - uptime())))
        // From the run loop, as an event's handling runs, not from a main-queue job: the main queue, and with it the
        // build's deadline, runs during the loop only then.
        let (taken, released) = await withCheckedContinuation { (done: CheckedContinuation<(Int, TimeInterval), Never>) in
            RunLoop.main.perform(inModes: [.default]) {
                MainActor.assumeIsolated {
                    func mouse(_ type: NSEvent.EventType) -> NSEvent? {
                        NSEvent.mouseEvent(with: type, location: .zero, modifierFlags: [], timestamp: ProcessInfo.processInfo.systemUptime,
                                           windowNumber: 0, context: nil, eventNumber: 0, clickCount: 1, pressure: type == .leftMouseUp ? 0 : 1)
                    }
                    if let press = mouse(.leftMouseDown) { NSApp.sendEvent(press) }
                    let tracked: NSEvent.EventTypeMask = [.leftMouseDragged, .leftMouseUp]
                    var taken = 0
                    for (time, type) in [(0.1, NSEvent.EventType.leftMouseDragged), (0.2, .leftMouseDragged), (0.3, .leftMouseDragged), (release, .leftMouseUp)] {
                        let wait = chosen + time - ProcessInfo.processInfo.systemUptime
                        _ = NSApp.nextEvent(matching: tracked, until: Date(timeIntervalSinceNow: max(0, wait)), inMode: .eventTracking, dequeue: true)
                        guard let event = mouse(type) else { continue }
                        NSApp.postEvent(event, atStart: false)
                        if NSApp.nextEvent(matching: tracked, until: .distantFuture, inMode: .eventTracking, dequeue: true) != nil { taken += 1 }
                    }
                    done.resume(returning: (taken, ProcessInfo.processInfo.systemUptime))
                }
            }
        }
        try? await Task.sleep(for: .seconds(max(0, released + 0.01 - uptime())))
        if let move = NSEvent.mouseEvent(with: .mouseMoved, location: .zero, modifierFlags: [], timestamp: uptime(), windowNumber: main.windowNumber,
                                         context: nil, eventNumber: 0, clickCount: 0, pressure: 0) {
            NSApp.postEvent(move, atStart: false)
        }
        let moved = uptime()
        while uptime() < released + 2, MacInspectorController.debugBuiltAhead.map({ $0.chat != chat || $0.at < chosen }) ?? true {
            try? await Task.sleep(for: .milliseconds(5))
        }
        let line = "\(taken) of 4 drags and release taken by the loop, released at \(format(released - chosen)) s, pointer move at \(format(moved - chosen)) s"
        guard let built = MacInspectorController.debugBuiltAhead, built.chat == chat, built.at >= chosen else {
            return log("prebuild-tracking \(argument): \(line), not built within 2 s of the release")
        }
        let verdict = built.at < released ? "DURING the press" : built.at - released < 0.5 ? "EARLY" : "ok"
        log("prebuild-tracking \(argument): \(line), built at \(format(built.at - chosen)) s, \(format(built.at - released)) s after the release: \(verdict)")
    }

    private static func runTour(_ script: String, window: MacWindowState, model: AppModel) async {
        var frames: Task<Void, Never>?
        if let directory = value(after: "-haus-capture-frames"), let seconds = value(after: "-haus-capture-frames", offset: 2).flatMap(Double.init) {
            frames = Task { await captureFrames(to: directory, seconds: seconds) }
        }
        for step in script.split(separator: ";").map({ $0.trimmingCharacters(in: .whitespaces) }).filter({ !$0.isEmpty }) {
            let words = step.split(separator: " ", maxSplits: 1).map(String.init)
            let argument = words.count > 1 ? words[1] : ""
            if words[0] != "wait" { log("tour \(step)") }
            switch words[0] {
            case "wait": try? await Task.sleep(for: .seconds(Double(argument) ?? 1))
            case "select": window.selection = argument
            case "deselect": window.selection = nil
            case "inspector": window.inspectorShown = argument != "off"
            case "inspector-page": showInspectorPage(argument, window: window, model: model)
            case "inspector-race": await inspectorRace(argument.isEmpty ? "760x800" : argument, window: window, main: mainWindow)
            case "prebuild-quiet": await prebuildQuiet(argument, window: window, main: mainWindow)
            case "prebuild-tracking": await prebuildTracking(argument, window: window, main: mainWindow)
            case "settings":
                tour.settingsPane = MacSettingsView.Pane(rawValue: argument) ?? .general
                if otherWindows.isEmpty { openSettings?() }
            case "close-settings": otherWindows.forEach { $0.close() }
            case "type", "mark", "send", "key": composerStep(words[0], argument, model: model)
            case "reply" where argument == "newest", "edit" where argument == "newest": composerStep(words[0], argument, model: model)
            case "reply", "edit", "star", "retry", "unsend", "encryption", "report", "select-text", "react", "pick-emoji":
                let parts = argument.split(separator: " ", maxSplits: 1).map(String.init)
                tour.setMessageRequest(MessageRequest(verb: words[0], messageID: parts.first ?? "", argument: parts.count > 1 ? parts[1] : "",
                                                      serial: (tour.messageRequest?.serial ?? 0) + 1))
            case "hover": tour.setHoveredMessage(argument == "off" ? nil : argument)
            case "model-edit", "model-unsend", "model-retry", "receipt":
                let parts = argument.split(separator: " ", maxSplits: 1).map(String.init)
                let id = parts.first ?? "", rest = parts.count > 1 ? parts[1] : ""
                switch words[0] {
                case "model-edit": _ = await model.edit(messageID: id, body: rest)
                case "model-unsend": await model.unsend(messageID: id)
                case "model-retry": await model.retryMessage(id)
                default: await model.recordSampleReceipt(read: rest == "displayed", messageID: id)
                }
            case "size":
                let size = argument.split(separator: "x").compactMap { Double($0) }
                if size.count == 2 { mainWindow?.setContentSize(NSSize(width: size[0], height: size[1])) }
            case "menu": logMenu(for: argument, model: model, window: window)
            case "focus", "press", "ax", "rotors", "focus-timeline", "ax-press", "ax-action": await MacKeyboardDebug.step(words[0], argument, window: mainWindow)
            case "attach", "drop", "paste", "import", "remove-attachment", "copy-image", "save-over": MacAttachmentTour.step(words[0], argument, model: model)
            case "drop-highlight": tour.dropHighlight = argument != "off"
            case "connecting": tour.connecting = argument != "off"
            case "toolbar": if let window = mainWindow { logToolbar(window) }
            case "find", "find-close", "find-esc", "starred", "show-result": MacConversationFindTour.step(words[0], argument)
            case "minimums": if let window = mainWindow { logMinimums(window) }
            case "snap":
                guard let directory = value(after: "-haus-capture"), let window = mainWindow, let png = render(window) else { log("tour snap: needs -haus-capture <dir>"); break }
                emit(png, directory: directory, file: slug(argument) + ".png")
            case "snap-sheet":
                // The newest sheet over the main window, alone: the main window's captures draw a sheet blank.
                var sheet = mainWindow?.attachedSheet
                while let next = sheet?.attachedSheet { sheet = next }
                guard let directory = value(after: "-haus-capture-frames") ?? value(after: "-haus-capture"), let sheet, let png = render(sheet) else { log("tour snap-sheet: needs a sheet and a capture directory"); break }
                emit(png, directory: directory, file: slug(argument) + ".png")
            case "capture":
                guard let directory = value(after: "-haus-capture-frames"), let main = mainWindow, let png = renderWithOverlays(main) else { log("tour capture: needs -haus-capture-frames <dir> <seconds>"); break }
                emit(png, directory: directory, file: slug(argument) + ".png")
            case "scroll" where Double(argument.split(separator: " ").first ?? "") != nil:
                let parts = argument.split(separator: " ")
                if let window = mainWindow { await ScrollProbe.sweep(in: window, seconds: Double(parts[0]) ?? 10, paging: parts.dropFirst().first == "paging") }
            case "scroll", "scroll-to", "quote", "resize", "resize-sweep", "timeline", "knob", "drag", "swipe", "swipe-end", "bind-reader", "older", "mismatch", "arrive", "arrive-long",
                 "arrive-extras", "settle", "show-row", "hit-reaction", "reuse-media", "extras-cache", "update-race", "gesture-update",
                 "resize-drag", "edit-race", "overlay-resize":
                await MacTimelineDebug.step(words[0], argument, window: mainWindow)
            case "menus": logMenuBar(model: model, window: window)
            case "command": performMenuItem(argument)
            case "header": log("header: \(mainWindow.map { "'\($0.title)' / '\($0.subtitle)'" } ?? "no main window")")
            case "badge": log("Dock badge \(NSApp.dockTile.badgeLabel ?? "none"), \(model.debugBadgeReport)")
            case "block" where model.isDemo: await model.block(argument)
            case "unblock" where model.isDemo: for entry in model.blockEntries(for: argument) { await model.unblock(entry) }
            case "close-window": mainWindow?.performClose(nil)
            // Hidden, the inspector changes without animating: on a screen locked meanwhile, animations never end.
            case "hide": NSApp.hide(nil)
            case "unhide": NSApp.unhideWithoutActivation()
            case "stalls": MacTimelineDebug.StallProbe.shared.report(argument)
            case "perf", "display-count", "layers", "sidebar", "sidebar-sweep", "force-noop", "split", "split-watch": await MacPerfProbe.step(words[0], argument, window: mainWindow)
            case "appearance", "accent", "text-select", "text-rescale", "text-layers": MacBubbleTextTour.step(words[0], argument, window: mainWindow)
            case "store" where model.isLabAccount:
                log("store \(argument): \(await model.debugRetentionReport(argument)); \(await model.debugMessageReport(argument))")
            case "chat", "join", "devices", "messages", "device", "review", "own-review", "trust", "verify", "dont-trust", "compare", "remove", "confirm", "close-sheet":
                await MacDeviceReviewTour.step(words[0], argument, model: model, window: window, mainWindow: mainWindow)
            default: log("tour \(step): unknown")
            }
        }
        await frames?.value
        log("tour done; selected \(window.selection ?? "none"), messages loaded for \(model.messagesLoadedFor ?? "none")")
    }

    private static func composerStep(_ step: String, _ argument: String, model: AppModel) {
        guard let textView = MacComposerTour.textView, let intent = MacComposerTour.intent else { log("tour \(step): no composer"); return }
        switch step {
        case "type":
            textView.insertText(argument, replacementRange: textView.selectedRange())
        case "mark":
            textView.setMarkedText(argument, selectedRange: NSRange(location: (argument as NSString).length, length: 0),
                                   replacementRange: textView.selectedRange())
        case "send":
            // Unlike Return, the Send button does not wait for a composition to end.
            textView.actions?.send()
        case "key":
            let keys: [String: (Selector, NSEvent.ModifierFlags)] = [
                "return": (#selector(NSResponder.insertNewline(_:)), []), "shift-return": (#selector(NSResponder.insertNewline(_:)), .shift),
                "option-return": (#selector(NSResponder.insertNewlineIgnoringFieldEditor(_:)), .option),
                "escape": (#selector(NSResponder.cancelOperation(_:)), []), "up": (#selector(NSResponder.moveUp(_:)), []),
            ]
            if argument == "command-return" {
                textView.keyDown(with: NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: .command, timestamp: 0, windowNumber: textView.window?.windowNumber ?? 0,
                                                       context: nil, characters: "\r", charactersIgnoringModifiers: "\r", isARepeat: false, keyCode: 36)!)
            } else if let (selector, modifiers) = keys[argument] {
                if !textView.handleCommand(selector, modifiers: modifiers) { textView.doCommand(by: selector) }
            } else { log("tour key \(argument): unknown") }
        // `reply newest` and `edit newest`; by message ID they go through the bubble's menu.
        case "reply":
            if let message = model.messages.last(where: { !$0.isOutgoing && $0.unreadableReason == nil }) { intent.reply(to: message) } else { log("tour reply newest: no received message") }
        case "edit":
            let presenter = ConversationPresenter(source: model, chatID: model.messagesLoadedFor ?? "", title: "")
            if let message = presenter.newestEditable { intent.edit(message) } else { log("tour edit newest: nothing to edit") }
        default: break
        }
        let draft = MacComposerDrafts.state(account: model.accountID, chat: model.messagesLoadedFor ?? "").draft
        log("composer \(step) \(argument): field \(textView.string.count) characters, marked \(textView.hasMarkedText()), draft \(draft.count) characters, replying \(intent.replyingTo?.id ?? "-"), editing \(intent.editing?.id ?? "-")")
    }

    // The window is off-screen, so no display link runs: a 120 Hz timer's ticks stand in for refreshes, and a late tick
    // means the main thread was busy. Render-server work is not measured.
    @MainActor final class ScrollProbe: NSObject {
        private let scrollView: NSScrollView
        private let seconds: Double
        private var started: CFTimeInterval = 0
        private var last: CFTimeInterval = 0
        private var intervals: [Double] = []
        private var peak: UInt64 = 0
        private var timer: Timer?
        private var finished: CheckedContinuation<Void, Never>?

        private init(scrollView: NSScrollView, seconds: Double) {
            self.scrollView = scrollView
            self.seconds = seconds
        }

        // The timeline is the scroll view with the tallest document.
        static func sweep(in window: NSWindow, seconds: Double, paging: Bool) async {
            func scrollViews(in view: NSView) -> [NSScrollView] { ((view as? NSScrollView).map { [$0] } ?? []) + view.subviews.flatMap(scrollViews(in:)) }
            guard let root = window.contentView,
                  let scrollView = scrollViews(in: root).max(by: { ($0.documentView?.frame.height ?? 0) < ($1.documentView?.frame.height ?? 0) }) else {
                log("scroll: no scroll view")
                return
            }
            let probe = ScrollProbe(scrollView: scrollView, seconds: seconds)
            let before = footprint()
            log(String(format: "scroll: start, document %.0f pt, footprint %.1f MB", scrollView.documentView?.frame.height ?? 0, megabytes(before)))
            // As a gesture would, so the timeline pages in older history when the sweep nears the top.
            if paging { MacTimelineController.current?.debugLiveScroll(true) }
            await withCheckedContinuation { continuation in
                probe.finished = continuation
                probe.start()
            }
            if paging { MacTimelineController.current?.debugLiveScroll(false) }
            let after = footprint()
            let sorted = probe.intervals.sorted()
            let p95 = sorted.isEmpty ? 0 : sorted[min(sorted.count - 1, Int(Double(sorted.count) * 0.95))]
            log(String(format: "scroll: %d ticks, %d over 16.7 ms, %d over 33 ms, p95 %.1f ms, worst %.1f ms; document %.0f pt; footprint %.1f MB after, peak %.1f MB",
                       sorted.count, sorted.filter { $0 > 1 / 60.0 }.count, sorted.filter { $0 > 1 / 30.0 }.count, p95 * 1_000, (sorted.last ?? 0) * 1_000,
                       scrollView.documentView?.frame.height ?? 0, megabytes(after), megabytes(max(probe.peak, after))))
        }

        private func start() {
            started = CACurrentMediaTime()
            last = started
            let timer = Timer(timeInterval: 1 / 120.0, repeats: true) { [weak self] _ in MainActor.assumeIsolated { self?.tick() } }
            RunLoop.main.add(timer, forMode: .common)
            self.timer = timer
        }

        private func tick() {
            let now = CACurrentMediaTime()
            intervals.append(now - last)
            last = now
            if intervals.count.isMultiple(of: 60) { peak = max(peak, ScrollProbe.footprint()) }
            let progress = min(1, (now - started) / seconds)
            let clip = scrollView.contentView
            let range = Self.range(of: scrollView)
            let fromTop = (range.upperBound - range.lowerBound) * abs(1 - 2 * progress)
            let flipped = scrollView.documentView?.isFlipped ?? true
            clip.scroll(to: NSPoint(x: clip.bounds.minX, y: flipped ? range.lowerBound + fromTop : range.upperBound - fromTop))
            scrollView.reflectScrolledClipView(clip)
            guard progress >= 1 else { return }
            timer?.invalidate()
            finished?.resume()
            finished = nil
        }

        static func range(of scrollView: NSScrollView) -> ClosedRange<CGFloat> {
            let insets = scrollView.contentInsets
            let flipped = scrollView.documentView?.isFlipped ?? true
            let lowest = flipped ? -insets.top : -insets.bottom
            let highest = (scrollView.documentView?.frame.height ?? 0) - scrollView.contentView.bounds.height + (flipped ? insets.bottom : insets.top)
            return lowest...max(lowest, highest)
        }

        private static func megabytes(_ bytes: UInt64) -> Double { Double(bytes) / 1_048_576 }

        // As Activity Monitor's Memory column shows it.
        private static func footprint() -> UInt64 {
            var info = task_vm_info_data_t()
            var count = mach_msg_type_number_t(MemoryLayout<task_vm_info_data_t>.size / MemoryLayout<natural_t>.size)
            let result = withUnsafeMutablePointer(to: &info) {
                $0.withMemoryRebound(to: integer_t.self, capacity: Int(count)) { task_info(mach_task_self_, task_flavor_t(TASK_VM_INFO), $0, &count) }
            }
            return result == KERN_SUCCESS ? info.phys_footprint : 0
        }
    }

    private static func logMenu(for id: String, model: AppModel, window: MacWindowState) {
        let messages = window.selection.map { ConversationPresenter(source: model, chatID: $0, title: $0).timelineMessages } ?? []
        guard let message = messages.first(where: { $0.id == id }) else {
            log("menu \(id): not in the open chat, which has " + messages.map(\.id).joined(separator: ", "))
            return
        }
        let menu = MacMessageMenu(message: message)
        let reactions = menu.showsReactions ? menu.reactions.map { $0.emoji + ($0.isSelected ? "*" : "") }.joined() + "+" : "none"
        log("menu \(id): reactions \(reactions) (\(message.canReact ? "enabled" : message.reactionUnavailableReason ?? "disabled")); items "
            + (menu.items.map(MacMessageMenu.title(for:)) + (menu.attachment?.items.map(\.title) ?? [])).joined(separator: " | "))
        for link in message.links {
            log("menu \(id) on \(link.url.absoluteString): " + MacMessageMenu(message: message, link: link.url).items.map(MacMessageMenu.title(for:)).joined(separator: " | "))
        }
        if let preview = message.linkPreview {
            log("menu \(id) on its card: " + MacMessageMenu(message: message, link: preview.url).items.map(MacMessageMenu.title(for:)).joined(separator: " | "))
        }
    }

    // Validated first, so a disabled item is what a click would find disabled.
    private static func logMenuBar(model: AppModel, window: MacWindowState) {
        func walk(_ menu: NSMenu, path: String) {
            open(menu)
            let items = menu.items.filter { !$0.isSeparatorItem }.map { item -> String in
                if let submenu = item.submenu { walk(submenu, path: path + "/" + item.title) }
                return item.title + shortcut(item) + (item.isEnabled ? "" : " (off)") + (item.state == .on ? " (on)" : "")
            }
            log("menu bar \(path): " + items.joined(separator: " | "))
        }
        let message = MacMenuTargets.shared.messageCommands.last?.make()
        log("menu bar targets: chat \(MacChatCommands(model: model, window: window).selected?.chat.id ?? "none"); last message: reply \(message?.reply?.id ?? "none"), edit "
            + "\(message?.edit?.id ?? "none"), react \(message?.react?.id ?? "none"), star \(message?.star?.id ?? "none")")
        for title in ["File", "Edit", "View", "Chat", "Message", "Window"] {
            guard let menu = NSApp.mainMenu?.item(withTitle: title)?.submenu else { log("menu bar \(title): missing"); continue }
            walk(menu, path: title)
        }
    }

    private static func performMenuItem(_ path: String) {
        var titles = path.split(separator: "/").map(String.init)
        guard !titles.isEmpty, var menu = NSApp.mainMenu else { return }
        let last = titles.removeLast()
        for title in titles {
            open(menu)
            guard let submenu = menu.item(withTitle: title)?.submenu else { log("command \(path): no menu \(title)"); return }
            menu = submenu
        }
        open(menu)
        guard let index = menu.items.firstIndex(where: { $0.title == last }) else {
            log("command \(path): no item; the menu has " + menu.items.map(\.title).filter { !$0.isEmpty }.joined(separator: ", "))
            return
        }
        guard menu.items[index].isEnabled else { log("command \(path): disabled"); return }
        menu.performActionForItem(at: index)
        log("command \(path): performed")
    }

    // As before the menu shows: SwiftUI's menu delegate brings the items up to date, then each item is validated.
    static func open(_ menu: NSMenu) {
        menu.delegate?.menuNeedsUpdate?(menu)
        menu.update()
    }

    private static func shortcut(_ item: NSMenuItem) -> String {
        guard !item.keyEquivalent.isEmpty else { return "" }
        let flags = item.keyEquivalentModifierMask
        let key = switch item.keyEquivalent { case "\t": "⇥"; case "\u{19}": "⇥"; default: item.keyEquivalent.uppercased() }
        return " [" + (flags.contains(.control) ? "⌃" : "") + (flags.contains(.option) ? "⌥" : "") + (flags.contains(.shift) ? "⇧" : "")
            + (flags.contains(.command) ? "⌘" : "") + key + "]"
    }

    private static var mainWindow: NSWindow? {
        NSApp.windows.first { $0.isVisible && $0.identifier?.rawValue.hasPrefix(MacAppDelegate.mainWindowID) == true }
    }

    private static var otherWindows: [NSWindow] {
        NSApp.windows.filter { window in
            window.isVisible && !window.isSheet && !(window is NSPanel) && window.contentView != nil && !isRemote(window)
                && window.identifier?.rawValue.hasPrefix(MacAppDelegate.mainWindowID) != true
        }
    }

    // Windows the system draws from another process (the text input indicator) render blank, so captures skip them.
    private static func isRemote(_ window: NSWindow) -> Bool {
        window.contentView?.subviews.contains { String(describing: type(of: $0)) == "NSRemoteView" } == true
    }

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
            if let window = mainWindow { logSheets(of: window) }
            if let window = mainWindow, let png = renderWithOverlays(window) {
                frame += 1
                emit(png, directory: directory, file: String(format: "frame-%04d.png", frame))
            }
            try? await Task.sleep(until: started + .milliseconds(100), clock: clock)
        }
        log("captured \(frame) frame(s)")
    }

    private static var loggedSheets: Set<ObjectIdentifier> = []

    private static func logSheets(of window: NSWindow) {
        func texts(in view: NSView) -> [String] {
            let own: [String] = if let field = view as? NSTextField, !field.stringValue.isEmpty { [field.stringValue] }
                else if let button = view as? NSButton, !button.title.isEmpty { ["[\(button.title)]"] } else { [] }
            return own + view.subviews.flatMap(texts(in:))
        }
        for sheet in window.sheets where sheet.isVisible && loggedSheets.insert(ObjectIdentifier(sheet)).inserted {
            log("sheet: " + (sheet.contentView.map(texts(in:)) ?? []).joined(separator: " | "))
        }
    }

    // Liquid Glass is drawn by the window server, so `cacheDisplay` leaves glass views blank: each is painted with a
    // flat stand-in for its material and its content rendered on top, so glass reads as a flat fill in captures.
    static func render(_ window: NSWindow) -> Data? {
        renderRep(window)?.representation(using: .png, properties: [:])
    }

    // A sheet draws its content outside the views and would render blank, so its words are logged instead.
    private static func renderWithOverlays(_ window: NSWindow) -> Data? {
        guard let main = renderRep(window) else { return nil }
        let overlays = otherWindows.compactMap { renderRep($0) }
        // A popover's frame is glass and renders blank; its content alone renders, on a flat fill drawn below.
        let attached = (window.childWindows ?? []).filter { $0.isVisible && !$0.isSheet && !isRemote($0) }.compactMap { child -> (NSWindow, NSBitmapImageRep)? in
            guard let view = child.contentView, let rep = view.bitmapImageRepForCachingDisplay(in: view.bounds) else { return nil }
            cacheDisplay(view, to: rep)
            return (child, rep)
        }
        guard !overlays.isEmpty || !attached.isEmpty else { return main.representation(using: .png, properties: [:]) }
        guard let output = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: main.pixelsWide, pixelsHigh: main.pixelsHigh,
                                            bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
                                            colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0),
              let context = NSGraphicsContext(bitmapImageRep: output) else { return nil }
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = context
        let canvas = NSRect(x: 0, y: 0, width: main.pixelsWide, height: main.pixelsHigh)
        main.draw(in: canvas)
        for overlay in overlays {
            let size = NSSize(width: overlay.pixelsWide, height: overlay.pixelsHigh)
            let frame = NSRect(x: ((canvas.width - size.width) / 2).rounded(), y: max(0, ((canvas.height - size.height) / 2).rounded()),
                               width: size.width, height: size.height)
            NSGraphicsContext.saveGraphicsState()
            let shadow = NSShadow()
            shadow.shadowColor = NSColor.black.withAlphaComponent(0.35)
            shadow.shadowBlurRadius = 40
            shadow.shadowOffset = NSSize(width: 0, height: -12)
            shadow.set()
            NSColor.windowBackgroundColor.setFill()
            NSBezierPath(roundedRect: frame, xRadius: 24, yRadius: 24).fill()
            NSGraphicsContext.restoreGraphicsState()
            NSGraphicsContext.saveGraphicsState()
            NSBezierPath(roundedRect: frame, xRadius: 24, yRadius: 24).addClip()
            overlay.draw(in: frame)
            NSGraphicsContext.restoreGraphicsState()
        }
        let scale = CGFloat(main.pixelsWide) / max(1, window.frame.width)
        for (child, rep) in attached {
            // The system keeps a popover on a screen, which the off-screen window is not on: its height above the
            // window's bottom is right, its horizontal place is not, so it is kept inside the picture.
            let x = min(max(0, (child.frame.minX - window.frame.minX) * scale), canvas.width - CGFloat(rep.pixelsWide))
            let frame = NSRect(x: x, y: (child.frame.minY - window.frame.minY) * scale, width: CGFloat(rep.pixelsWide), height: CGFloat(rep.pixelsHigh))
            NSGraphicsContext.saveGraphicsState()
            let shadow = NSShadow()
            shadow.shadowColor = NSColor.black.withAlphaComponent(0.3)
            shadow.shadowBlurRadius = 24
            shadow.shadowOffset = NSSize(width: 0, height: -6)
            shadow.set()
            NSColor.windowBackgroundColor.setFill()
            NSBezierPath(roundedRect: frame, xRadius: 20, yRadius: 20).fill()
            NSGraphicsContext.restoreGraphicsState()
            NSGraphicsContext.saveGraphicsState()
            NSBezierPath(roundedRect: frame, xRadius: 20, yRadius: 20).addClip()
            rep.draw(in: frame)
            NSGraphicsContext.restoreGraphicsState()
        }
        NSGraphicsContext.restoreGraphicsState()
        return output.representation(using: .png, properties: [:])
    }

    private static func renderRep(_ window: NSWindow) -> NSBitmapImageRep? {
        guard let view = window.contentView?.superview ?? window.contentView else { return nil }
        view.layoutSubtreeIfNeeded()
        guard let base = view.bitmapImageRepForCachingDisplay(in: view.bounds),
              let output = view.bitmapImageRepForCachingDisplay(in: view.bounds),
              let context = NSGraphicsContext(bitmapImageRep: output) else { return nil }
        cacheDisplay(view, to: base)
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
                        // Vibrant text and fields are blended by the window server too and cache in the wrong colours
                        // (black labels in dark mode): the content draws in the plain appearance of the same mode.
                        let vibrant = content.appearance
                        content.appearance = NSAppearance(named: window.effectiveAppearance.bestMatch(from: [.aqua, .darkAqua]) ?? .aqua)
                        content.layoutSubtreeIfNeeded()
                        content.display()
                        defer { content.appearance = vibrant }
                        draw(content, into: view)
                        // Table rows (the sidebar's chats) are left out of their table's cached image; each row
                        // renders on its own, clipped to what its scroll view shows.
                        for row in descendants(of: content) where row is NSTableRowView {
                            guard let clip = row.enclosingScrollView?.contentView else { continue }
                            let visible = clip.convert(clip.bounds, to: view).intersection(row.convert(row.bounds, to: view))
                            guard !visible.isEmpty else { continue }
                            NSGraphicsContext.saveGraphicsState()
                            visible.clip()
                            if let selected = row as? NSTableRowView, selected.isSelected, let layer = row.layer {
                                // The selection is a vibrant fill too and caches as black: a flat stand-in (the
                                // inactive window's selection, as the window is never key here) under the row without
                                // it.
                                NSColor.unemphasizedSelectedContentBackgroundColor.setFill()
                                NSBezierPath(roundedRect: row.convert(row.bounds, to: view).insetBy(dx: 10, dy: 0), xRadius: 10, yRadius: 10).fill()
                                let fills = descendants(of: layer).filter { $0.backgroundColor != nil && $0.compositingFilter.map { "\($0)".contains("vibrant") } == true }
                                CATransaction.begin(); CATransaction.setDisableActions(true)
                                fills.forEach { $0.isHidden = true }
                                CATransaction.commit()
                                draw(row, into: view)
                                CATransaction.begin(); CATransaction.setDisableActions(true)
                                fills.forEach { $0.isHidden = false }
                                CATransaction.commit()
                            } else {
                                draw(row, into: view)
                            }
                            NSGraphicsContext.restoreGraphicsState()
                        }
                    }
                }
            }
        }
        NSGraphicsContext.restoreGraphicsState()
        return output
    }

    // The in-process render (`CALayer.render(in:)`) drops the whole hosting view around a layer composited `destIn`:
    // the mask of an opaque tinted glass shape (an enabled Send) or of a scroll edge's fade. The masks are hidden while
    // caching; their glass is blank in captures either way.
    private static func cacheDisplay(_ view: NSView, to rep: NSBitmapImageRep) {
        let masks = view.layer.map(descendants(of:))?.filter { layer in
            !layer.isHidden && layer.compositingFilter.map { "\($0)" } == "destIn"
        } ?? []
        CATransaction.begin(); CATransaction.setDisableActions(true)
        masks.forEach { $0.isHidden = true }
        CATransaction.commit()
        view.cacheDisplay(in: view.bounds, to: rep)
        CATransaction.begin(); CATransaction.setDisableActions(true)
        masks.forEach { $0.isHidden = false }
        CATransaction.commit()
    }

    private static func draw(_ part: NSView, into view: NSView) {
        guard let rep = part.bitmapImageRepForCachingDisplay(in: part.bounds) else { return }
        // Vibrant text and fills are masks the window server tints through a colour matrix, which `cacheDisplay` skips
        // (they come out black or white). Each is drawn on its own: the stand-in behind it through the same matrix, in
        // the layer's shape. Table rows are cached separately (`renderRep`), so their layers are skipped here.
        let rows = Set(descendants(of: part).compactMap { $0 is NSTableRowView ? $0.layer.map(ObjectIdentifier.init) : nil })
        let vibrant = part.layer.map { vibrantLayers(in: $0, skipping: rows) } ?? []
        CATransaction.begin(); CATransaction.setDisableActions(true)
        let hidden = vibrant.map(\.layer.isHidden)
        vibrant.forEach { $0.layer.isHidden = true }
        CATransaction.commit()
        cacheDisplay(part, to: rep)
        CATransaction.begin(); CATransaction.setDisableActions(true)
        for (item, wasHidden) in zip(vibrant, hidden) { item.layer.isHidden = wasHidden }
        CATransaction.commit()
        let fills = vibrant.filter { $0.layer.backgroundColor != nil }, marks = vibrant.filter { $0.layer.backgroundColor == nil }
        tint(fills, of: part, into: view)
        rep.draw(in: part.convert(part.bounds, to: view), from: .zero, operation: .sourceOver, fraction: 1, respectFlipped: false, hints: nil)
        tint(marks, of: part, into: view)
    }

    private static func tint(_ layers: [(layer: CALayer, matrix: [Float])], of part: NSView, into view: NSView) {
        guard let root = part.layer, let context = NSGraphicsContext.current?.cgContext else { return }
        let scale = part.window?.backingScaleFactor ?? 2
        for item in layers where !item.layer.isHidden && item.layer.bounds.width > 0 && item.layer.bounds.height > 0 {
            let layer = item.layer
            let width = Int((layer.bounds.width * scale).rounded(.up)), height = Int((layer.bounds.height * scale).rounded(.up))
            guard let shapeContext = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
                                               space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { continue }
            shapeContext.scaleBy(x: scale, y: scale)
            if !layer.isGeometryFlipped { shapeContext.translateBy(x: 0, y: layer.bounds.height); shapeContext.scaleBy(x: 1, y: -1) }
            layer.render(in: shapeContext)
            guard let shape = shapeContext.makeImage() else { continue }
            // A backing layer shares its view's coordinates.
            var frame = part.convert(root.convert(layer.bounds, from: layer), to: view)
            // A toolbar button's symbol is in a layer tree of its own, which converts to the window's origin: the
            // button's cached image has it already.
            guard frame.intersects(part.convert(part.bounds, to: view)) else { continue }
            if view.isFlipped { frame.origin.y = view.bounds.height - frame.maxY }
            // The matrix tints what lies behind the layer, here the stand-in already drawn there, in the layer's shape.
            let backdrop = pixel(of: context, at: CGPoint(x: frame.minX + 0.5, y: frame.minY + 0.5))
            let matrix = item.matrix
            func channel(_ row: Int) -> CGFloat {
                let value = matrix[row * 5] * backdrop[0] + matrix[row * 5 + 1] * backdrop[1] + matrix[row * 5 + 2] * backdrop[2] + matrix[row * 5 + 3] + matrix[row * 5 + 4]
                return CGFloat(min(1, max(0, value)))
            }
            context.saveGState()
            context.clip(to: frame, mask: shape)
            context.setFillColor(CGColor(srgbRed: channel(0), green: channel(1), blue: channel(2), alpha: channel(3)))
            context.fill(frame)
            context.restoreGState()
        }
    }

    // User space is y up; components are sRGB 0…1 without alpha.
    private static func pixel(of context: CGContext, at point: CGPoint) -> [Float] {
        let device = point.applying(context.userSpaceToDeviceSpaceTransform)
        guard let data = context.data, context.bitsPerPixel == 32 else { return [0.5, 0.5, 0.5] }
        let x = min(context.width - 1, max(0, Int(device.x))), y = min(context.height - 1, max(0, Int(device.y)))
        // Device space is y up from the bottom row; the buffer starts at the top row.
        let row = context.height - 1 - y
        let bytes = data.advanced(by: row * context.bytesPerRow + x * 4).assumingMemoryBound(to: UInt8.self)
        return [Float(bytes[0]) / 255, Float(bytes[1]) / 255, Float(bytes[2]) / 255]
    }

    // The matrix is 4 × 5, row-major, bias last in each row.
    private static func vibrantLayers(in root: CALayer, skipping skipped: Set<ObjectIdentifier>) -> [(layer: CALayer, matrix: [Float])] {
        var found: [(CALayer, [Float])] = []
        func walk(_ layer: CALayer) {
            guard !skipped.contains(ObjectIdentifier(layer)) else { return }
            if let filter = layer.filters?.first as? NSObject, "\(filter)".contains("vibrantColorMatrix") || (filter.value(forKey: "name") as? String) == "vibrantColorMatrix",
               let value = filter.value(forKey: "inputColorMatrix") as? NSValue {
                var matrix = [Float](repeating: 0, count: 20)
                matrix.withUnsafeMutableBytes { value.getValue($0.baseAddress!, size: $0.count) }
                found.append((layer, matrix))
                return
            }
            layer.sublayers?.forEach(walk)
        }
        walk(root)
        return found
    }

    private static func descendants(of view: NSView) -> [NSView] {
        view.subviews.flatMap { [$0] + descendants(of: $0) }
    }

    private static func descendants(of layer: CALayer) -> [CALayer] {
        (layer.sublayers ?? []).flatMap { [$0] + descendants(of: $0) }
    }

    // Set by the system for a sandboxed process, whose relative paths resolve inside its own container.
    private static let sandboxed = ProcessInfo.processInfo.environment["APP_SANDBOX_CONTAINER_ID"] != nil

    static func emit(_ data: Data, directory: String, file: String) {
        if !sandboxed {
            let folder = URL(filePath: directory, directoryHint: .isDirectory)
            if (try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)) != nil,
               (try? data.write(to: folder.appending(path: file))) != nil { return }
        }
        let line = "HAUS-FILE \(file) \(data.base64EncodedString())\n"
        FileHandle.standardOutput.write(Data(line.utf8))
    }

    private static func slug(_ text: String) -> String {
        let allowed = text.lowercased().map { $0.isLetter || $0.isNumber ? $0 : "-" }
        return String(allowed).split(separator: "-").joined(separator: "-")
    }

    private static func labSignIn(_ model: AppModel) async {
        let environment = ProcessInfo.processInfo.environment
        guard let username = environment["HAUS_LAB_USERNAME"], let password = environment["HAUS_LAB_PASSWORD"] else {
            log("lab sign-in: HAUS_LAB_USERNAME and HAUS_LAB_PASSWORD are not set")
            return
        }
        let connected = await model.connect(username: username, password: password)
        log("lab sign-in: \(connected ? "connected" : "failed: \(model.session.label)")")
    }

    // A signed build's storage: the store opens in the App Group container, the container probe passes, and a
    // data-protection Keychain item round-trips (the encryption key readable from the app's access group once it
    // exists).
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

    private static func logToolbar(_ window: NSWindow) {
        guard let toolbar = window.toolbar, let root = window.contentView?.superview else { return log("toolbar: none") }
        func views(_ view: NSView) -> [NSView] { [view] + view.subviews.flatMap(views) }
        let all = views(root)
        for item in toolbar.items {
            let view = item.view ?? all.first { ($0 as? NSButton)?.image != nil && ($0 as? NSButton)?.image === item.image }
            let frame = view.map { $0.convert($0.bounds, to: nil) }.map { "\(Int($0.minX)),\(Int($0.minY)) \(Int($0.width))x\(Int($0.height))" } ?? "no view"
            log("toolbar: \(item.itemIdentifier.rawValue) \(item.isHidden ? "hidden" : item.isVisible ? "shown" : "not shown") \(frame)")
        }
    }

    // The split view's panes report no minimum (`MacSplitController`): one that follows its own view's width makes
    // AppKit lay the window out again and again.
    private static func logMinimums(_ window: NSWindow) {
        log("minimums: window content \(window.contentLayoutRect.size), content min \(window.contentMinSize)")
        func walk(_ view: NSView) {
            let minimums = view.constraints.filter { $0.firstItem === view && ($0.identifier ?? "").hasPrefix("NSHostingView.min") }
            if !minimums.isEmpty {
                let values = minimums.map { "\($0.identifier?.replacingOccurrences(of: "NSHostingView.", with: "") ?? "") \(Int($0.constant))" }
                log("minimums: \(type(of: view)) \(Int(view.frame.width))x\(Int(view.frame.height)) \(values.joined(separator: ", "))")
            }
            view.subviews.forEach(walk)
        }
        if let root = window.contentView?.superview { walk(root) }
    }

    private static func dumpMenus() {
        func walk(_ menu: NSMenu, depth: Int) {
            for item in menu.items where !item.isSeparatorItem {
                let mask = item.keyEquivalentModifierMask
                let modifiers = (mask.contains(.control) ? "⌃" : "") + (mask.contains(.option) ? "⌥" : "") + (mask.contains(.shift) ? "⇧" : "")
                let key = item.keyEquivalent.isEmpty ? "" : " [\(modifiers)⌘\(item.keyEquivalent)]"
                log("menu \(String(repeating: "  ", count: depth))\(item.title)\(key)")
                if let submenu = item.submenu, depth < 2 { walk(submenu, depth: depth + 1) }
            }
        }
        if let menu = NSApp.mainMenu { walk(menu, depth: 0) }
    }

    private static func waitUntil(seconds: Double, _ condition: @MainActor () -> Bool) async {
        let clock = ContinuousClock(), end = clock.now + .seconds(seconds)
        while !condition(), clock.now < end { try? await Task.sleep(for: .milliseconds(100)) }
    }

    // Stamped with UTC time to line up with a lab peer's and the server's logs.
    static func log(_ text: String) {
        FileHandle.standardOutput.write(Data("HAUS \(stamp.string(from: Date())) \(text)\n".utf8))
    }

    private static let stamp: DateFormatter = {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(identifier: "UTC")
        formatter.dateFormat = "HH:mm:ss.SSS"
        return formatter
    }()
}

// Settings opens through the environment, so this sits on the main window's content.
struct MacDebugPresentation: ViewModifier {
    let model: AppModel
    let window: MacWindowState
    @Environment(\.openSettings) private var openSettings
    @State private var fingerprint: EncryptionDevice?
    @State private var backup: PreUpgradeSnapshot.Manifest?
    @State private var joiningGroup = false

    func body(content: Content) -> some View {
        content.task {
            MacDebugHooks.openSettings = openSettings
            switch MacDebugHooks.value(after: "-haus-sheet") {
            case "fingerprint": fingerprint = OwnDeviceReview.sampleDevices(account: model.accountID).last
            case "backup": backup = Self.sampleBackup
            case "group-join": joiningGroup = true
            default: break
            }
            guard MacDebugHooks.has("-haus-settings") else { return }
            try? await Task.sleep(for: .milliseconds(300))
            openSettings()
        }
        .sheet(item: $fingerprint) { device in
            DeviceFingerprintSheet(model: model, chatID: DemoSamples.alex, device: device, name: "Alex", allowsMaintenance: true) { _ in fingerprint = nil }
                .themedRoot()
        }
        .sheet(isPresented: Binding(get: { backup != nil }, set: { if !$0 { backup = nil } })) {
            if let backup { PreviousVersionBackupView(model: model, backup: backup).themedRoot() }
        }
        .sheet(isPresented: $joiningGroup) {
            NavigationStack {
                GroupJoinView(model: model, room: "trail@rooms.preview.local") { _ in joiningGroup = false }
                    .toolbar { ToolbarItem(placement: .cancellationAction) { Button("Cancel") { joiningGroup = false } } }
            }
            .frame(minWidth: 420, idealWidth: 460, minHeight: 360, idealHeight: 420)
            .themedRoot()
        }
    }

    // A day old, so the footer reads as for a fresh backup.
    private static var sampleBackup: PreUpgradeSnapshot.Manifest? {
        let json = """
        {"id": "sample", "takenAt": \(Date().addingTimeInterval(-86_400).timeIntervalSinceReferenceDate),
         "database": {"schemaVersion": 1, "rowCounts": {}}, "installation": "sample", "folders": [],
         "notificationsDisabled": false, "accountRecord": false, "pushRegistrations": []}
        """
        return try? JSONDecoder().decode(PreUpgradeSnapshot.Manifest.self, from: Data(json.utf8))
    }
}
#endif
