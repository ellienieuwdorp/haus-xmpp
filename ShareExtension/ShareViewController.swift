import Intents
import SwiftUI
#if os(iOS)
import UIKit
#else
import AppKit
#endif

#if os(iOS)
// Leaving the host (an app switch, a lock) or swiping the sheet away ends the share's connection, gives the transport
// lease back and closes SQLite until the host returns; what was queued stays queued.
final class ShareViewController: UIViewController {
    private let model = ShareModel()
    private let appearance = AppearanceStore(defaults: SharedSession.groupDefaults ?? .standard)
    private var observers: [any NSObjectProtocol] = []
    private var closing = false

    override func viewDidLoad() {
        super.viewDidLoad()
        let root = ShareRootView(model: model, close: { [weak self] in self?.finish() })
            .environment(\.appearance, appearance)
            .tint(Color(platform: appearance.accent.tint))
        let host = UIHostingController(rootView: root)
        addChild(host)
        host.view.frame = view.bounds
        host.view.autoresizingMask = [.flexibleWidth, .flexibleHeight]
        view.addSubview(host.view)
        host.didMove(toParent: self)
        let center = NotificationCenter.default
        observers.append(center.addObserver(forName: .NSExtensionHostDidEnterBackground, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.leave() }
        })
        observers.append(center.addObserver(forName: .NSExtensionHostWillEnterForeground, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.model.resume() }
        })
        let providers = SharedItemIntake.providers(of: extensionContext?.inputItems as? [NSExtensionItem] ?? [])
        // Set only when the user picked one of the share sheet's suggested chats.
        let suggested = (extensionContext?.intent as? INSendMessageIntent)?.conversationIdentifier
        Task { await model.load(providers: providers, suggestedConversation: suggested) }
    }

    override func viewWillAppear(_ animated: Bool) {
        super.viewWillAppear(animated)
        model.resume()
    }

    // Swiping the sheet away calls nothing else here.
    override func viewDidDisappear(_ animated: Bool) {
        super.viewDidDisappear(animated)
        if !closing { leave() }
    }

    override func accessibilityPerformEscape() -> Bool { finish(); return true }

    private func leave() { Task { await model.suspend() } }

    private func finish() {
        guard !closing else { return }
        closing = true
        Task {
            await model.close()
            extensionContext?.completeRequest(returningItems: nil)
        }
    }
}
#else
// `NSExtensionContext.intent` is iOS only, so the Mac cannot preselect a suggested chat and the picker always shows.
final class ShareViewController: NSViewController {
    private let model = ShareModel()
    private let appearance = AppearanceStore(defaults: SharedSession.groupDefaults ?? .standard)
    private var closing = false

    override func loadView() {
        let root = ShareRootView(model: model, close: { [weak self] in self?.finish() })
            .environment(\.appearance, appearance)
            .tint(Color(platform: appearance.accent.tint))
            .frame(minWidth: 380, idealWidth: 420, minHeight: 460, idealHeight: 540)
        let host = NSHostingView(rootView: root)
        host.frame = NSRect(x: 0, y: 0, width: 420, height: 540)
        view = host
        preferredContentSize = NSSize(width: 420, height: 540)
    }

    override func viewDidLoad() {
        super.viewDidLoad()
        let providers = SharedItemIntake.providers(of: extensionContext?.inputItems as? [NSExtensionItem] ?? [])
        Task { await model.load(providers: providers, suggestedConversation: nil) }
    }

    private func finish() {
        guard !closing else { return }
        closing = true
        Task {
            await model.close()
            extensionContext?.completeRequest(returningItems: nil)
        }
    }
}
#endif
