import AppKit

// The star's slot is always there, so starring never moves anything.
final class MacFooterView: MacTimelineDrawnView {
    struct Content: Equatable {
        var isOutgoing = false
        var accent: AccentTheme = .indigo
        var isStarred = false
        var text: String?
        var glyph: MessageStatusGlyph?
    }

    var content = Content() { didSet { if content != oldValue { needsDisplay = true } } }

    struct Placement: Equatable {
        var glyph: CGRect?
        var text: CGRect?
        var star: CGRect?
    }

    // Laid out from the trailing edge: the receipt, the time, then the star, so the star appears without moving the rest.
    static func placement(_ content: Content, in bounds: CGRect, metrics: MacTimelineMetrics) -> Placement {
        var placement = Placement()
        let slot = MacTimelineMetrics.statusSlot
        var x = bounds.width
        if let glyph = content.glyph {
            x -= slot.width
            let width = MessageStatusArt.designWidth(glyph)
            placement.glyph = CGRect(x: x + slot.width - width, y: (bounds.height - slot.height) / 2, width: width, height: slot.height)
            x -= 4
        }
        if let text = content.text {
            let width = ceil((text as NSString).size(withAttributes: [.font: metrics.caption2]).width)
            x -= width
            placement.text = CGRect(x: x, y: (bounds.height - metrics.caption2Line) / 2, width: width, height: metrics.caption2Line)
            x -= 4
        }
        if content.isStarred {
            x -= metrics.starSize.width
            placement.star = CGRect(x: x, y: (bounds.height - metrics.starSize.height) / 2, width: metrics.starSize.width, height: metrics.starSize.height)
        }
        return placement
    }

    override func draw(_ dirtyRect: NSRect) {
        #if DEBUG
        debugNoteDraw(dirtyRect)
        #endif
        let metrics = MacTimelineMetrics.shared
        let color = content.isOutgoing ? content.accent.bubbleText.withAlphaComponent(0.75) : .secondaryLabelColor
        let placement = Self.placement(content, in: bounds, metrics: metrics)
        if let glyph = content.glyph, let rect = placement.glyph {
            Self.drawTinted(MessageStatusArt.image(glyph, scale: 1), in: rect, color: color)
        }
        if let text = content.text, let rect = placement.text {
            (text as NSString).draw(at: rect.origin, withAttributes: [.font: metrics.caption2, .foregroundColor: color])
        }
        if let rect = placement.star {
            Self.drawTinted(metrics.star, in: rect, color: color)
        }
    }

    static func drawTinted(_ image: NSImage, in rect: NSRect, color: NSColor) {
        guard let context = NSGraphicsContext.current?.cgContext,
              let cgImage = image.cgImage(forProposedRect: nil, context: NSGraphicsContext.current, hints: nil) else { return }
        context.saveGState()
        context.translateBy(x: rect.minX, y: rect.maxY)
        context.scaleBy(x: 1, y: -1)
        let local = CGRect(origin: .zero, size: rect.size)
        context.clip(to: local, mask: cgImage)
        context.setFillColor(color.cgColor)
        context.fill(local)
        context.restoreGState()
    }
}
