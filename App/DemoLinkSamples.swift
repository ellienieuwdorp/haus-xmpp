import CoreGraphics
import Foundation
import MessageStore
import UniformTypeIdentifiers

/// The sample chat with links and link previews: a received preview with a large image, an own sent preview with a
/// small thumbnail, a text-only preview, and a phone number, an email address and an `xmpp:` link. Every preview is
/// carried with its message, as a sender's XEP-0511 metadata or our frozen own preview, and every image is drawn here,
/// so the sample needs no network and no asset ships (the demo never fetches, `LinkPreviewPolicy`).
enum DemoLinkSamples {
    static let chatID = "sam@preview.local"
    static let title = "Sam"

    /// From `start` a minute apart; the caller dates it before the other sample chats, so it lists last.
    static func messages(account: String, start: Date) -> [StoredMessage] {
        func message(_ index: Int, outgoing: Bool, _ body: String, preview: StoredLinkPreview? = nil) -> StoredMessage {
            let id = "sample-links-\(index)"
            return StoredMessage(id: id, accountID: account, chatID: chatID, senderID: outgoing ? account : chatID, body: body,
                                 sentAt: start.addingTimeInterval(Double(index) * 60), isOutgoing: outgoing,
                                 wireID: outgoing ? id : nil, linkPreview: preview)
        }
        let library = "https://example.org/library/opening"
        let trail = "https://example.com/trails/ridge-loop"
        let cake = "https://example.net/recipes/plum-cake"
        let libraryImage = libraryImage(), trailImage = trailImage()
        return [
            message(0, outgoing: false, "The new library opens on Saturday 📚 \(library)", preview: StoredLinkPreview(
                url: library, title: "The new city library opens its doors",
                summary: "Three floors of books, a rooftop reading garden and a café by the canal.",
                imageData: libraryImage, imageType: libraryImage.map { _ in "image/jpeg" }, imageAlt: "The library lit up at dusk", source: .sender)),
            message(1, outgoing: true, "Here’s the walk for Sunday \(trail)", preview: StoredLinkPreview(
                url: trail, title: "Ridge Loop · 12 km", summary: "A moderate loop with views over the whole valley.",
                imageData: trailImage, imageType: trailImage.map { _ in "image/jpeg" }, imageAlt: "A trail map of the loop", source: .own)),
            message(2, outgoing: false, "And for afterwards: \(cake)", preview: StoredLinkPreview(
                url: cake, title: "Plum cake with almonds", summary: "A simple sheet cake for late-summer plums. Serves twelve.", source: .sender)),
            message(3, outgoing: false, "Table’s booked. The café is on +31 20 555 0134 if we’re late, or mail bookings@example.org"),
            message(4, outgoing: true, "I asked Alex as well: xmpp:alex@preview.local"),
        ]
    }

    /// 600 × 315 px (1.9:1): a large card. A building's lit windows against an evening sky.
    private static func libraryImage() -> Data? {
        draw(width: 600, height: 315) { context, width, height in
            gradient(context, [(0.98, 0.62, 0.38), (0.55, 0.36, 0.72)], from: CGPoint(x: 0, y: height), to: CGPoint(x: 0, y: 0))
            context.setFillColor(CGColor(srgbRed: 1, green: 0.88, blue: 0.6, alpha: 0.9))
            context.fillEllipse(in: CGRect(x: 430, y: 170, width: 90, height: 90))
            context.setFillColor(CGColor(srgbRed: 0.16, green: 0.14, blue: 0.26, alpha: 1))
            context.fill(CGRect(x: 90, y: 0, width: 300, height: 190))
            context.fill(CGRect(x: 0, y: 0, width: width, height: 34))
            context.setFillColor(CGColor(srgbRed: 1, green: 0.84, blue: 0.5, alpha: 1))
            for row in 0..<4 {
                for column in 0..<7 where (row + column) % 3 != 0 {
                    context.fill(CGRect(x: 110 + column * 40, y: 52 + row * 34, width: 22, height: 18))
                }
            }
        }
    }

    /// 240 × 240 px: below the large card's 300 px, so a small thumbnail. A ridge with a dotted path.
    private static func trailImage() -> Data? {
        draw(width: 240, height: 240) { context, width, height in
            gradient(context, [(0.62, 0.84, 0.95), (0.86, 0.94, 0.88)], from: CGPoint(x: 0, y: height), to: CGPoint(x: 0, y: 0))
            context.setFillColor(CGColor(srgbRed: 0.24, green: 0.55, blue: 0.36, alpha: 1))
            context.move(to: CGPoint(x: 0, y: 0))
            context.addLines(between: [CGPoint(x: 0, y: 90), CGPoint(x: 80, y: 170), CGPoint(x: 130, y: 120), CGPoint(x: 180, y: 190),
                                       CGPoint(x: width, y: 110), CGPoint(x: width, y: 0)])
            context.fillPath()
            context.setStrokeColor(CGColor(srgbRed: 1, green: 0.96, blue: 0.85, alpha: 1))
            context.setLineWidth(6)
            context.setLineCap(.round)
            context.setLineDash(phase: 0, lengths: [2, 14])
            context.addLines(between: [CGPoint(x: 30, y: 20), CGPoint(x: 70, y: 70), CGPoint(x: 60, y: 110), CGPoint(x: 120, y: 105),
                                       CGPoint(x: 175, y: 160)])
            context.strokePath()
        }
    }

    private static func gradient(_ context: CGContext, _ colors: [(Double, Double, Double)], from start: CGPoint, to end: CGPoint) {
        let colors = colors.map { CGColor(srgbRed: $0.0, green: $0.1, blue: $0.2, alpha: 1) } as CFArray
        guard let gradient = CGGradient(colorsSpace: CGColorSpace(name: CGColorSpace.sRGB), colors: colors, locations: nil) else { return }
        context.drawLinearGradient(gradient, start: start, end: end, options: [])
    }

    /// A JPEG of what `body` draws into a y-up sRGB bitmap; within the 64 KiB a carried preview image may have.
    private static func draw(width: Int, height: Int, _ body: (CGContext, Int, Int) -> Void) -> Data? {
        guard let space = CGColorSpace(name: CGColorSpace.sRGB),
              let context = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0, space: space,
                                      bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue) else { return nil }
        body(context, width, height)
        guard let image = context.makeImage() else { return nil }
        return LinkPreviewImaging.encode(image, type: .jpeg, quality: 0.8)
    }
}
