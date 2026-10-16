#if DEBUG
import AppKit

/// The keyboard and VoiceOver tour steps (`-haus-tour`; see `MacDebugHooks`). Debug builds only.
///
/// Keys are key events handed to the main window in process (`NSWindow.sendEvent`), as AppKit hands it a key from the
/// event queue, never posted through the window server. The accessibility steps read the window's accessibility tree
/// through the `NSAccessibility` protocol, which is what an assistive app reads through its own API (Accessibility
/// Inspector's hierarchy), without asking for any permission.
@MainActor enum MacKeyboardDebug {
    static func step(_ name: String, _ argument: String, window: NSWindow?) async {
        guard let window else { return MacDebugHooks.log("tour \(name): no main window") }
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
        default: break
        }
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
                                               charactersIgnoringModifiers: key.flags.contains(.shift) && name == "shift-tab" ? "\u{19}" : key.characters,
                                               isARepeat: false, keyCode: key.code) else { return false }
            // A command key goes to the menus first, as the event queue would send it.
            if type == .keyDown, key.flags.contains(.command), NSApp.mainMenu?.performKeyEquivalent(with: event) == true { continue }
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
        case let view?: String(describing: type(of: view))
        case nil: "none"
        }
        let timeline = MacTimelineController.current
        let focused = focusedElement(in: window).map(describe) ?? "none"
        MacDebugHooks.log("focus after \(what): responder \(name); timeline focused \(timeline?.hasKeyboardFocus ?? false), message "
            + "\(timeline?.focusedID ?? "none"); accessibility focus \(focused)")
    }

    private static func focusedElement(in window: NSWindow) -> NSAccessibilityProtocol? {
        var found: NSAccessibilityProtocol?
        walk(root(of: window), depth: 0) { element, _ in
            if found == nil, element.isAccessibilityFocused(), role(element) != .window { found = element }
            return found == nil
        }
        return found
    }

    // MARK: Accessibility tree

    /// Every element with something to say (a label, title or value, actions or rotors), indented by depth. With a
    /// text, only the elements whose description contains it, and only the first 400 lines.
    private static func dump(_ window: NSWindow, matching filter: String) {
        var lines = 0
        walk(root(of: window), depth: 0) { element, depth in
            let text = describe(element)
            let speaks = label(element)?.isEmpty == false || title(element)?.isEmpty == false || value(element) != nil
                || actions(element).isEmpty == false
            guard speaks, filter.isEmpty || text.localizedCaseInsensitiveContains(filter) else { return true }
            lines += 1
            MacDebugHooks.log("ax " + String(repeating: "  ", count: min(depth, 30)) + text)
            return lines < 400
        }
        MacDebugHooks.log("ax: \(lines) element(s)")
    }

    /// The window's content view: the window itself lists no children until an assistive app has asked for them.
    private static func root(of window: NSWindow) -> NSAccessibilityProtocol { window.contentView ?? window }

    /// Depth first; `visit` returns false to stop.
    private static func walk(_ root: NSAccessibilityProtocol, depth: Int, visit: (NSAccessibilityProtocol, Int) -> Bool) {
        var stopped = false
        func go(_ element: NSAccessibilityProtocol, _ depth: Int) {
            guard !stopped, depth < 60 else { return }
            if !visit(element, depth) { stopped = true; return }
            for child in children(element) {
                guard let child = child as? NSAccessibilityProtocol else { continue }
                go(child, depth + 1)
            }
        }
        go(root, depth)
    }

    private static func describe(_ element: NSAccessibilityProtocol) -> String {
        var parts = [role(element)?.rawValue ?? "?"]
        if let label = label(element), !label.isEmpty { parts.append("label '\(label.prefix(200))'") }
        if let title = title(element), !title.isEmpty { parts.append("title '\(title.prefix(80))'") }
        if let value = value(element) { parts.append("value '\(String(describing: value).prefix(80))'") }
        if let subrole = element.accessibilitySubrole() { parts.append("subrole \(subrole.rawValue)") }
        let actions = actions(element)
        if !actions.isEmpty { parts.append("actions [" + actions.joined(separator: ", ") + "]") }
        let rotors = rotors(element)
        if !rotors.isEmpty { parts.append("rotors [" + rotors.map(rotorName).joined(separator: ", ") + "]") }
        if element.isAccessibilityFocused() { parts.append("FOCUSED") }
        return parts.joined(separator: " ")
    }

    private static func role(_ element: NSAccessibilityProtocol) -> NSAccessibility.Role? { element.accessibilityRole() }
    private static func label(_ element: NSAccessibilityProtocol) -> String? { element.accessibilityLabel() }
    private static func title(_ element: NSAccessibilityProtocol) -> String? { element.accessibilityTitle() }
    private static func value(_ element: NSAccessibilityProtocol) -> Any? { element.accessibilityValue() }
    private static func children(_ element: NSAccessibilityProtocol) -> [Any] { element.accessibilityChildren() ?? [] }
    private static func actions(_ element: NSAccessibilityProtocol) -> [String] { (element.accessibilityCustomActions() ?? []).map(\.name) }
    private static func rotors(_ element: NSAccessibilityProtocol) -> [NSAccessibilityCustomRotor] { element.accessibilityCustomRotors() }

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
                    let target = (result.targetElement as? NSAccessibilityProtocol).map(describe) ?? "?"
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
