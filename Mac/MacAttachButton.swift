import AppKit
import SwiftUI

// An AppKit menu, because only one can carry the system's import-from-device item.
struct MacAttachButton: View {
    let enabled: Bool
    var focus: FocusState<MacComposerControl?>.Binding
    let photos: () -> Void
    let files: () -> Void
    // Continuity Camera offers its items to, and hands what it took to, the first responder that accepts images.
    let prepareImport: () -> Void
    @State private var anchor = MacMenuAnchor.Box()

    var body: some View {
        Button(action: showMenu) {
            // Dimmed here as well: the style's opacity does not reach a circle drawn straight into the composer's glass
            // container, as this one is, only one nested in the field's glass, as Send is.
            Image(systemName: "plus").font(.system(size: 18, weight: .semibold)).opacity(enabled ? 1 : 0.35)
        }
        .buttonStyle(CircularGlassButtonStyle(diameter: 44, tinted: false))
        .focused(focus, equals: .attach)
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
