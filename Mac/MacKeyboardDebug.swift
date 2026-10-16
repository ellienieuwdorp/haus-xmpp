#if DEBUG
import AppKit

/// The keyboard and VoiceOver tour steps (`-haus-tour`; see `MacDebugHooks`). Debug builds only.
///
/// Keys are key events handed to the main window in process (`NSWindow.sendEvent`), as AppKit hands it one from the
/// event queue; nothing is posted through the window server. The accessibility steps read the window's accessibility
/// tree in process, element by element, as an assistive app reads it through its own API (Accessibility Inspector's
/// hierarchy), without asking for any permission.
@MainActor enum MacKeyboardDebug {
    static func step(_ name: String, _ argument: String, window: NSWindow?) async {
        guard let window else { return MacDebugHooks.log("tour \(name): no main window") }
        if ["focus", "press", "ax", "rotors"].contains(name) { await buildAccessibilityTree() }
        switch name {
        case "press":
            for key in argument.split(separator: " ").map(String.init) {
                guard press(key, in: window) else { return MacDebugHooks.log("tour press \(key): unknown key") }
                // SwiftUI moves its focus and runs key handlers in later turns of the main queue.
                try? await Task.sleep(for: .milliseconds(150))
            }
            logFocus(in: window, after: "press \(argument)")
        case "focus":
            logFocus(in: window, after: "focus")
        case "ax":
            dump(window, matching: argument)
        case "rotors":
            logRotors(in: window)
        case "ax-press":
            await pressElement(matching: [argument], in: window)
        case "focus-timeline":
            MacTimelineController.current?.debugFocusByKey()
        default: break
        }
    }

    private static var treeBuilt = false

    /// SwiftUI builds its accessibility elements only once an assistive app asks for them, which it does by setting
    /// `AXEnhancedUserInterface` or `AXManualAccessibility` on the app; the steps set them themselves, the first time.
    private static func buildAccessibilityTree() async {
        guard !treeBuilt else { return }
        treeBuilt = true
        for attribute in ["AXEnhancedUserInterface", "AXManualAccessibility"] {
            (NSApp as AnyObject).accessibilitySetValue(true, forAttribute: NSAccessibility.Attribute(rawValue: attribute))
        }
        try? await Task.sleep(for: .milliseconds(500))
    }

    // MARK: Keys

    private static let keys: [String: (code: UInt16, characters: String, flags: NSEvent.ModifierFlags)] = [
        "tab": (48, "\t", []), "shift-tab": (48, "\u{19}", .shift),
        "up": (126, "\u{F700}", [.numericPad, .function]), "down": (125, "\u{F701}", [.numericPad, .function]),
        "command-up": (126, "\u{F700}", [.command, .numericPad, .function]), "command-down": (125, "\u{F701}", [.command, .numericPad, .function]),
        "shift-up": (126, "\u{F700}", [.shift, .numericPad, .function]),
        "page-up": (116, "\u{F72C}", .function), "page-down": (121, "\u{F72D}", .function),
        "home": (115, "\u{F729}", .function), "end": (119, "\u{F72B}", .function),
        "return": (36, "\r", []), "space": (49, " ", []), "escape": (53, "\u{1B}", []),
        "command-r": (15, "r", .command),
    ]

    private static func press(_ name: String, in window: NSWindow) -> Bool {
        guard let key = keys[name] else { return false }
        for type in [NSEvent.EventType.keyDown, .keyUp] {
            guard let event = NSEvent.keyEvent(with: type, location: .zero, modifierFlags: key.flags, timestamp: ProcessInfo.processInfo.systemUptime,
                                               windowNumber: window.windowNumber, context: nil, characters: key.characters,
                                               charactersIgnoringModifiers: key.characters,
                                               isARepeat: false, keyCode: key.code) else { return false }
            // A command key goes to the menus first, as the event queue would send it, each brought up to date as the
            // menu bar keeps them (nothing refreshes them in a run that is never active).
            if type == .keyDown, key.flags.contains(.command), let main = NSApp.mainMenu {
                func update(_ menu: NSMenu) {
                    MacDebugHooks.open(menu)
                    menu.items.compactMap(\.submenu).forEach(update)
                }
                update(main)
                if main.performKeyEquivalent(with: event) { continue }
            }
            window.sendEvent(event)
        }
        return true
    }

    // MARK: Focus

    /// Who has the keyboard: the window's first responder, the timeline's own state, and the element accessibility
    /// reports as focused.
    static func logFocus(in window: NSWindow, after what: String) {
        let responder = window.firstResponder
        let name: String = switch responder {
        case let view as MacComposerTextView where view === MacComposerTour.textView: "composer (draft \(view.string.count) characters)"
        case let view as BubbleTextView: "bubble text '\(view.string.prefix(30))'"
        case let field as NSTextView where field.isFieldEditor: "field editor of \(field.delegate.map { String(describing: type(of: $0)) } ?? "-")"
            + " '\(field.string)'"
        case let view?: String(describing: type(of: view))
        case nil: "none"
        }
        let timeline = MacTimelineController.current
        let focused = focusedElement(in: window).map(describe) ?? "none"
        let ids = timeline?.rows.map(\.message.id) ?? []
        let index = timeline?.focusedID.flatMap(ids.firstIndex(of:)).map { " (\($0 + 1) of \(ids.count))" } ?? ""
        let intent = MacComposerTour.intent.map { "replying \($0.replyingTo?.id ?? "-"), editing \($0.editing?.id ?? "-")" } ?? "no composer"
        MacDebugHooks.log("focus after \(what): responder \(name); timeline focused \(timeline?.hasKeyboardFocus ?? false), message "
            + "\(timeline?.focusedID ?? "none")\(index); composer \(intent); accessibility focus \(focused); "
            + "full keyboard access \(NSApp.isFullKeyboardAccessEnabled ? "on" : "off")")
    }

    private static func focusedElement(in window: NSWindow) -> Element? {
        var found: Element?
        walk(root(of: window), depth: 0) { element, _ in
            if found == nil, isFocused(element), role(element) != .window { found = element }
            return found == nil
        }
        return found
    }

    // MARK: Accessibility tree

    /// Every element with something to say (a label, title or value, or actions), indented by depth. With a
    /// text, only the elements whose description contains it, and only the first 400 lines.
    private static func dump(_ window: NSWindow, matching filter: String) {
        var lines = 0, visited = 0
        walk(root(of: window), depth: 0) { element, depth in
            visited += 1
            let text = describe(element)
            let speaks = label(element)?.isEmpty == false || title(element)?.isEmpty == false || value(element) != nil
                || actions(element).isEmpty == false
            guard speaks, filter.isEmpty || text.localizedCaseInsensitiveContains(filter) else { return true }
            lines += 1
            MacDebugHooks.log("ax " + String(repeating: "  ", count: min(depth, 30)) + text)
            return lines < 400
        }
        MacDebugHooks.log("ax: \(lines) of \(visited) element(s)")
    }

    /// Performs the press action of the first element, in the newest sheet over the window or else in the window,
    /// whose accessibility identifier is one of the texts (or starts with one ending in a dot) or, for a button
    /// lacking an identifier, whose description contains one, as VoiceOver's VO-Space would. Logs what it pressed and returns whether it found one.
    @discardableResult static func pressElement(matching texts: [String], in window: NSWindow) async -> Bool {
        await buildAccessibilityTree()
        let label = texts.joined(separator: "|")
        var sheets: [NSWindow] = []
        var top: NSWindow? = window.attachedSheet
        while let sheet = top { sheets.insert(sheet, at: 0); top = sheet.attachedSheet }
        for candidate in sheets + [window] {
            var found: Element?
            walk(root(of: candidate), depth: 0) { element, _ in
                let identifier: String? = ask(element, "accessibilityIdentifier")
                let matches = texts.contains { text in
                    if let identifier, !identifier.isEmpty { return identifier == text || text.hasSuffix(".") && identifier.hasPrefix(text) }
                    return role(element) == .button && describe(element).localizedCaseInsensitiveContains(text)
                }
                if matches, element.responds(to: NSSelectorFromString("accessibilityPerformPress")) { found = element }
                return found == nil
            }
            if let found {
                let selector = NSSelectorFromString("accessibilityPerformPress")
                let pressed = found.method(for: selector).map { unsafeBitCast($0, to: (@convention(c) (AnyObject, Selector) -> Bool).self)(found, selector) } ?? false
                MacDebugHooks.log("ax-press '\(label)': \(describe(found))\(candidate === window ? "" : " in a sheet"), pressed \(pressed)")
                return true
            }
        }
        MacDebugHooks.log("ax-press '\(label)': no element")
        return false
    }

    /// The window's content view: the window itself lists no children until an assistive app has asked for them.
    private static func root(of window: NSWindow) -> Element { window.contentView ?? window }

    /// Depth first; `visit` returns false to stop.
    private static func walk(_ root: Element, depth: Int, visit: (Element, Int) -> Bool) {
        var stopped = false
        func go(_ element: Element, _ depth: Int) {
            guard !stopped, depth < 60 else { return }
            if !visit(element, depth) { stopped = true; return }
            for case let child as Element in children(element) { go(child, depth + 1) }
        }
        go(root, depth)
    }

    private static func describe(_ element: Element) -> String {
        var parts = [role(element)?.rawValue ?? "?"]
        if let label = label(element), !label.isEmpty { parts.append("label '\(label.prefix(200))'") }
        if let title = title(element), !title.isEmpty { parts.append("title '\(title.prefix(80))'") }
        if let value = value(element) { parts.append("value '\(String(describing: value).prefix(80))'") }
        if let subrole = subrole(element) { parts.append("subrole \(subrole)") }
        let actions = actions(element)
        if !actions.isEmpty { parts.append("actions [" + actions.joined(separator: ", ") + "]") }
        let rotors = rotors(element)
        if !rotors.isEmpty { parts.append("rotors [" + rotors.map(rotorName).joined(separator: ", ") + "]") }
        if isFocused(element) { parts.append("FOCUSED") }
        return parts.joined(separator: " ")
    }

    /// An element of the tree: AppKit's views and cells, and SwiftUI's own nodes, which answer the same messages
    /// without declaring the protocol, so each is asked only what it answers.
    private typealias Element = NSObject

    private static func ask<T>(_ element: Element, _ selector: String) -> T? {
        let selector = NSSelectorFromString(selector)
        guard element.responds(to: selector) else { return nil }
        return element.perform(selector)?.takeUnretainedValue() as? T
    }

    private static func role(_ element: Element) -> NSAccessibility.Role? { (ask(element, "accessibilityRole") as String?).map(NSAccessibility.Role.init) }
    private static func subrole(_ element: Element) -> String? { ask(element, "accessibilitySubrole") }
    private static func label(_ element: Element) -> String? { ask(element, "accessibilityLabel") }
    private static func title(_ element: Element) -> String? { ask(element, "accessibilityTitle") }
    private static func value(_ element: Element) -> Any? { ask(element, "accessibilityValue") as AnyObject? }
    private static func children(_ element: Element) -> [Any] { ask(element, "accessibilityChildren") ?? [] }
    private static func actions(_ element: Element) -> [String] { (ask(element, "accessibilityCustomActions") as [NSAccessibilityCustomAction]?)?.map(\.name) ?? [] }
    private static func rotors(_ element: Element) -> [NSAccessibilityCustomRotor] { ask(element, "accessibilityCustomRotors") ?? [] }
    private static func isFocused(_ element: Element) -> Bool {
        let selector = NSSelectorFromString("isAccessibilityFocused")
        guard element.responds(to: selector), let method = element.method(for: selector) else { return false }
        return unsafeBitCast(method, to: (@convention(c) (AnyObject, Selector) -> Bool).self)(element, selector)
    }

    private static func rotorName(_ rotor: NSAccessibilityCustomRotor) -> String {
        rotor.type == .custom ? rotor.label : "system \(rotor.type.rawValue)"
    }

    // MARK: Rotors

    /// Each custom rotor in the window, with the entries VoiceOver would step through: up to 40, each as the element it
    /// lands on describes itself.
    private static func logRotors(in window: NSWindow) {
        walk(root(of: window), depth: 0) { element, _ in
            for rotor in rotors(element) {
                var entries: [String] = []
                let search = NSAccessibilityCustomRotor.SearchParameters()
                search.searchDirection = .next
                while entries.count < 40, let result = rotor.itemSearchDelegate?.rotor(rotor, resultFor: search) {
                    let target = result.targetElement.flatMap { $0 as? Element }.map(describe) ?? "resolved when VoiceOver moves there"
                    entries.append("'\(result.customLabel ?? "")' -> \(target.prefix(90))")
                    search.currentItem = result
                }
                MacDebugHooks.log("rotor \(rotorName(rotor)) on \(role(element)?.rawValue ?? "?"): \(entries.count) entries")
                entries.forEach { MacDebugHooks.log("rotor   \($0)") }
            }
            return true
        }
    }
}
#endif
