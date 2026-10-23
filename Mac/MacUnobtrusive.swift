#if DEBUG
import AppKit
import ObjectiveC
import SwiftUI

/// `-haus-unobtrusive`: keeps a check run out of the way of whoever is using this Mac. The app gets no Dock icon or
/// menu bar, never stays active, and every window it opens is transparent, click-through, ordered behind everything
/// and moved far off-screen before it is first shown. The capture hooks still render those windows (`cacheDisplay`
/// draws the views, not the screen). Pass it on every scripted run. Debug builds only.
///
/// Anything the checks need from real focus (key window, activation, lock, idle) is simulated through the debug hooks
/// instead, since a window here is never key and always reports as occluded.
@MainActor enum MacUnobtrusive {
    static let isOn = ProcessInfo.processInfo.arguments.contains("-haus-unobtrusive")
    private static var observers: [any NSObjectProtocol] = []
    /// Far outside any arrangement of displays.
    private static let parking = NSPoint(x: -30_000, y: -30_000)

    /// From the app delegate's creation, as early as the app can run code: an accessory app gets no Dock icon, not
    /// even for the moment before it finishes launching.
    static func setPolicy() {
        guard isOn else { return }
        NSApplication.shared.setActivationPolicy(.accessory)
    }

    /// From `applicationWillFinishLaunching`, before any window exists.
    static func install() {
        guard isOn else { return }
        NSApp.setActivationPolicy(.accessory)
        allowWindowsOffScreen()
        refuseKeyWindows()
        let center = NotificationCenter.default
        // Nothing here asks to be activated, but SwiftUI's window opening can activate the app: hand the focus back
        // at once.
        observers.append(center.addObserver(forName: NSApplication.didBecomeActiveNotification, object: nil, queue: .main) { _ in
            MainActor.assumeIsolated {
                MacDebugHooks.log("unobtrusive: became active; deactivating")
                NSApp.deactivate()
            }
        })
        // Any window that slipped past the anchor (an alert, a window SwiftUI shows before its content) is hidden on
        // the next pass of the event loop.
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

    /// Sheets and child windows move with their parent, so only top-level windows are parked themselves.
    private static func isTopLevel(_ window: NSWindow) -> Bool { window.sheetParent == nil && window.parent == nil }

    static func hide(_ window: NSWindow) {
        window.alphaValue = 0
        window.ignoresMouseEvents = true
        window.collectionBehavior.insert([.transient, .ignoresCycle])
        window.isExcludedFromWindowsMenu = true
        if isTopLevel(window), window.frame.origin != parking { window.setFrameOrigin(parking) }
    }

    /// AppKit keeps a titled window's title bar on a screen (`constrainFrameRect(_:to:)`), which pulled a parked
    /// window back to the edge of the display. In this mode no window of the app should be constrained, so the
    /// constraint returns the frame it was given.
    private static func allowWindowsOffScreen() {
        let selector = #selector(NSWindow.constrainFrameRect(_:to:))
        guard let method = class_getInstanceMethod(NSWindow.self, selector) else { return }
        let unconstrained: @convention(block) (NSWindow, NSRect, NSScreen?) -> NSRect = { _, frame, _ in frame }
        method_setImplementation(method, imp_implementationWithBlock(unconstrained))
    }

    /// AppKit makes a sheet's parent the key window again when the sheet ends, and making a window key activates its
    /// app, which this mode never wants: a window here is shown without becoming key, and a request to make one key
    /// is dropped. The observer above still hands back any activation that comes another way.
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

    /// Hides its window the moment the content joins it, before the window is first ordered on screen.
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
