#if DEBUG
import AppKit
import MessagingCore
import SwiftUI
import UniformTypeIdentifiers

/// `-haus-share-sheet <link>`: the Share extension's screen and model, hosted in a window of the signed app, for checks of
/// the Mac share flow without a signed extension or a click. The share carries the link and a generated photo
/// (`-haus-share-link-only`: the link alone).
/// `-haus-share-to <chat>` opens it on that chat's review card, as a share-sheet suggestion does on the iPhone;
/// `-haus-share-send` then sends, which queues through the composer's enqueue, rings this app and waits for its outbox
/// pass, exactly as from the extension. Each stage is captured into `-haus-capture`'s directory. Debug builds only.
@MainActor enum MacShareDebug {
    static func run(_ link: String, model app: AppModel) async {
        guard let url = URL(string: link) else { MacDebugHooks.log("share sheet: not a link"); return }
        let photo = FileManager.default.temporaryDirectory.appending(path: "Share harness photo.png")
        if let data = samplePhoto() { try? data.write(to: photo) }
        // `-haus-share-link-only`: the link alone, for a lab whose upload service this Mac does not trust.
        let photoProvider = MacDebugHooks.has("-haus-share-link-only") ? nil : NSItemProvider(contentsOf: photo)
        let providers = [NSItemProvider(object: url as NSURL), photoProvider].compactMap { $0 }
        let share = ShareModel()
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 420, height: 540), styleMask: [.titled], backing: .buffered, defer: false)
        window.title = "Share"
        window.contentView = NSHostingView(rootView: ShareRootView(model: share, close: {}).environment(\.appearance, AppearanceStore.shared)
            .tint(Color(platform: AppearanceStore.shared.accent.tint)))
        window.orderFront(nil)
        let target = MacDebugHooks.value(after: "-haus-share-to")
        // The extension reads the server's upload answer the app copied once its discovery settled.
        let discovered = ContinuousClock.now + .seconds(15)
        while !app.canSendAttachments, ContinuousClock.now < discovered { try? await Task.sleep(for: .milliseconds(200)) }
        if let target, !app.chats.contains(where: { $0.id == target }) {
            MacDebugHooks.log("share sheet: created chat \(await app.createChat(target) ?? "none")")
        }
        await share.load(providers: providers, suggestedConversation: target.map { NotificationIdentity.thread(accountID: app.accountID, chatID: $0) })
        MacDebugHooks.log("share sheet: \(share.phase), \(share.chats.count) chats, \(share.items.count) items, selection \(share.selection)")
        await settle()
        capture(window, "share-1-\(target == nil ? "picker" : "review")")
        guard MacDebugHooks.has("-haus-share-send") else { return }
        await waitUntil(seconds: 20) { share.canSend }
        share.send()
        await waitUntil(seconds: 30) { share.phase == .finished }
        MacDebugHooks.log("share sheet: app error \(app.error ?? "none")")
        MacDebugHooks.log("share sheet: \(share.phase), deliveries \(share.deliveries.mapValues { "\($0)" }), note \(share.outcomeNote ?? "none")")
        await settle()
        capture(window, "share-2-result")
        await share.close()
    }

    private static func capture(_ window: NSWindow, _ name: String) {
        guard let directory = MacDebugHooks.value(after: "-haus-capture"), let png = MacDebugHooks.render(window) else { return }
        MacDebugHooks.emit(png, directory: directory, file: name + ".png")
    }

    private static func settle() async { try? await Task.sleep(for: .seconds(1.5)) }

    private static func waitUntil(seconds: Double, _ condition: @MainActor () -> Bool) async {
        let end = ContinuousClock.now + .seconds(seconds)
        while !condition(), ContinuousClock.now < end { try? await Task.sleep(for: .milliseconds(100)) }
    }

    /// A synthetic gradient, so the capture shows no real picture.
    private static func samplePhoto() -> Data? {
        guard let context = CGContext(data: nil, width: 800, height: 600, bitsPerComponent: 8, bytesPerRow: 0,
                                      space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return nil }
        for x in stride(from: 0, to: 800, by: 20) {
            context.setFillColor(red: CGFloat(x) / 800, green: 0.4, blue: 1 - CGFloat(x) / 800, alpha: 1)
            context.fill(CGRect(x: x, y: 0, width: 20, height: 600))
        }
        guard let image = context.makeImage() else { return nil }
        return NSBitmapImageRep(cgImage: image).representation(using: .png, properties: [:])
    }
}
#endif
