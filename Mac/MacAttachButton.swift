import AppKit
import SwiftUI

/// The composer's attach button: a clear glass circle at the field's leading edge, the size of the field at one line,
/// whose menu offers Photos…, Choose File… and, with an iPhone or iPad nearby, Continuity Camera's items (Take Photo,
/// Scan Documents, Add Sketch). An AppKit menu, because only one can carry the system's import-from-device item.
struct MacAttachButton: View {
    let enabled: Bool
    let photos: () -> Void
    let files: () -> Void
    /// Makes the composer's text view first responder: Continuity Camera offers its items to, and later hands what it
    /// took to, the first responder that accepts images (`MacComposerTextView.validRequestor`).
    let prepareImport: () -> Void
    @State private var anchor = MacMenuAnchor.Box()

    var body: some View {
        Button(action: showMenu) {
            Image(systemName: "plus").font(.system(size: 18, weight: .semibold))
        }
        .buttonStyle(CircularGlassButtonStyle(diameter: 44, tinted: false))
        .background(MacMenuAnchor(box: anchor))
        .disabled(!enabled)
        .help("Attach")
        .accessibilityLabel("Attach")
        .accessibilityHint("Shows Photos, Choose File and your iPhone’s camera")
        .accessibilityIdentifier("attachFile")
    }

    private func showMenu() {
        guard let view = anchor.view else { return }
        prepareImport()
        let menu = NSMenu()
        menu.addItem(MacMenuAction.item("Photos…", symbol: "photo.on.rectangle", run: photos))
        menu.addItem(MacMenuAction.item("Choose File…", symbol: "doc", run: files))
        menu.addItem(.separator())
        // AppKit replaces this item with a section per nearby device; with none, the item stays hidden.
        let device = NSMenuItem(title: "Import from iPhone or iPad", action: nil, keyEquivalent: "")
        device.identifier = NSMenuItem.importFromDeviceIdentifier
        menu.addItem(device)
        // Above the button: the composer sits at the window's bottom edge.
        menu.popUp(positioning: nil, at: NSPoint(x: 0, y: view.bounds.height + 4 + menu.size.height), in: view)
    }
}

/// A plain view behind a SwiftUI control, so an AppKit menu can open from where the control is.
struct MacMenuAnchor: NSViewRepresentable {
    final class Box {
        weak var view: NSView?
    }

    let box: Box

    func makeNSView(context: Context) -> NSView {
        let view = NSView()
        box.view = view
        return view
    }

    func updateNSView(_ view: NSView, context: Context) { box.view = view }
}

/// A menu item that runs a closure; the item keeps its target alive.
final class MacMenuAction: NSObject {
    private let body: () -> Void

    private init(_ body: @escaping () -> Void) { self.body = body }

    @objc private func invoke() { body() }

    static func item(_ title: String, symbol: String? = nil, run: @escaping () -> Void) -> NSMenuItem {
        let action = MacMenuAction(run)
        let item = NSMenuItem(title: title, action: #selector(invoke), keyEquivalent: "")
        item.target = action
        item.representedObject = action
        if let symbol { item.image = NSImage(systemSymbolName: symbol, accessibilityDescription: nil) }
        return item
    }
}
