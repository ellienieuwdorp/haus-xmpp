#if DEBUG
import AppKit
import ObjectiveC
import SwiftUI

// `-haus-unobtrusive` (Debug): no Dock icon or menu bar, never active, windows click-through and parked off-screen
// before first shown; captures still render (`cacheDisplay` draws views). No window is key, so focus is simulated.
@MainActor enum MacUnobtrusive {
    static let isOn = ProcessInfo.processInfo.arguments.contains("-haus-unobtrusive")
    private static var observers: [any NSObjectProtocol] = []
    private static let parking = NSPoint(x: -30_000, y: -30_000)

    // Called from the app delegate's init, so the accessory app gets no Dock icon even before launch finishes.
    static func setPolicy() {
        guard isOn else { return }
        NSApplication.shared.setActivationPolicy(.accessory)
    }

    static func install() {
        guard isOn else { return }
        NSApp.setActivationPolicy(.accessory)
        allowWindowsOffScreen()
        refuseKeyWindows()
        let center = NotificationCenter.default
        // SwiftUI's window opening can activate the app: hand the focus back at once.
        observers.append(center.addObserver(forName: NSApplication.didBecomeActiveNotification, object: nil, queue: .main) { _ in
            MainActor.assumeIsolated {
                MacDebugHooks.log("unobtrusive: became active; deactivating")
                NSApp.deactivate()
            }
        })
        // Windows that slipped past the anchor (an alert, one SwiftUI shows before its content) hide on the next pass.
        for name in [NSApplication.didUpdateNotification, NSWindow.didBecomeKeyNotification, NSWindow.didBecomeMainNotification,
                     NSWindow.didMoveNotification, NSWindow.didResizeNotification] {
            observers.append(center.addObserver(forName: name, object: nil, queue: .main) { _ in
                MainActor.assumeIsolated { hideVisibleWindows() }
            })
        }
    }

    private static var hiding = false

    private static func hideVisibleWindows() {
        // Parking a window posts `didMove` synchronously.
        guard !hiding else { return }
        hiding = true
        defer { hiding = false }
        for window in NSApp.windows where window.isVisible {
            if window.alphaValue > 0 || !window.ignoresMouseEvents {
                hide(window)
                if window.sheetParent == nil { window.orderBack(nil) }
                MacDebugHooks.log("unobtrusive: hid \(window.identifier?.rawValue ?? window.title) (\(type(of: window)), \(window.frame.size)) at \(window.frame.origin)")
            } else if isTopLevel(window), window.frame.origin != parking {
                window.setFrameOrigin(parking)
            }
        }
    }

    private static func isTopLevel(_ window: NSWindow) -> Bool { window.sheetParent == nil && window.parent == nil }

    static func hide(_ window: NSWindow) {
        window.alphaValue = 0
        window.ignoresMouseEvents = true
        window.collectionBehavior.insert([.transient, .ignoresCycle])
        window.isExcludedFromWindowsMenu = true
        if isTopLevel(window), window.frame.origin != parking { window.setFrameOrigin(parking) }
    }

    // AppKit's `constrainFrameRect(_:to:)` keeps a titled window's title bar on a screen, which would pull a parked
    // window back; here it returns the frame unchanged.
    private static func allowWindowsOffScreen() {
        let selector = #selector(NSWindow.constrainFrameRect(_:to:))
        guard let method = class_getInstanceMethod(NSWindow.self, selector) else { return }
        let unconstrained: @convention(block) (NSWindow, NSRect, NSScreen?) -> NSRect = { _, frame, _ in frame }
        method_setImplementation(method, imp_implementationWithBlock(unconstrained))
    }

    // Ending a sheet makes its parent key, and making a window key activates the app, so key requests are dropped.
    private static func refuseKeyWindows() {
        let makeKey: @convention(block) (NSWindow) -> Void = { _ in }
        let makeKeyAndOrderFront: @convention(block) (NSWindow, Any?) -> Void = { window, sender in window.orderFront(sender) }
        if let method = class_getInstanceMethod(NSWindow.self, #selector(NSWindow.makeKey)) {
            method_setImplementation(method, imp_implementationWithBlock(makeKey))
        }
        if let method = class_getInstanceMethod(NSWindow.self, #selector(NSWindow.makeKeyAndOrderFront(_:))) {
            method_setImplementation(method, imp_implementationWithBlock(makeKeyAndOrderFront))
        }
    }

    struct Anchor: NSViewRepresentable {
        final class View: NSView {
            override func viewDidMoveToWindow() {
                super.viewDidMoveToWindow()
                guard let window else { return }
                MainActor.assumeIsolated {
                    guard MacUnobtrusive.isOn else { return }
                    MacUnobtrusive.hide(window)
                }
            }
        }
        func makeNSView(context: Context) -> View { View() }
        func updateNSView(_ view: View, context: Context) {}
    }
}
#endif
