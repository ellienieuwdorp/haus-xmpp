import SwiftUI
#if os(iOS)
import UIKit
#else
import AppKit
#endif

/// Applies the store's tint and light/dark choice. Used on the window root and again on each sheet
/// root, so a presentation's own bars, glass buttons and rows re-render with the choice made inside it.
private struct ThemedRoot: ViewModifier {
    @Environment(\.appearance) private var appearance

    func body(content: Content) -> some View {
        content
            .tint(Color(platform: appearance.accent.tint))
            .background { WindowInterfaceStyle(style: appearance.interfaceStyle) }
    }
}

#if os(iOS)
/// Light/dark is the window's trait override rather than `preferredColorScheme`: going from Dark back
/// to Automatic through the SwiftUI preference leaves an open sheet dark until it is dismissed
/// (iOS 26.5), while every presentation in the window follows the window's override. Set as the view
/// joins the window, so a stored Dark choice is in place before the first frame.
private struct WindowInterfaceStyle: UIViewRepresentable {
    let style: UIUserInterfaceStyle

    final class Anchor: UIView {
        var style = UIUserInterfaceStyle.unspecified { didSet { apply() } }
        override func didMoveToWindow() {
            super.didMoveToWindow()
            apply()
        }
        private func apply() {
            guard let window, window.overrideUserInterfaceStyle != style else { return }
            window.overrideUserInterfaceStyle = style
        }
    }

    func makeUIView(context: Context) -> Anchor {
        let anchor = Anchor()
        anchor.isUserInteractionEnabled = false
        anchor.style = style
        return anchor
    }

    func updateUIView(_ anchor: Anchor, context: Context) { anchor.style = style }
}
#else
/// On the Mac the choice is the application's appearance, so every window (main, Settings, sheets) and the menus follow
/// it together. Set as the view joins a window, so a stored Dark choice is in place before the first frame.
private struct WindowInterfaceStyle: NSViewRepresentable {
    let style: NSAppearance?

    final class Anchor: NSView {
        var style: NSAppearance? { didSet { apply() } }
        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            apply()
        }
        private func apply() {
            guard window != nil, NSApp.appearance?.name != style?.name else { return }
            NSApp.appearance = style
        }
    }

    func makeNSView(context: Context) -> Anchor {
        let anchor = Anchor()
        anchor.style = style
        return anchor
    }

    func updateNSView(_ anchor: Anchor, context: Context) { anchor.style = style }
}
#endif

extension View {
    func themedRoot() -> some View { modifier(ThemedRoot()) }
}

/// Message status marks, drawn rather than composed from SF Symbols so the double rings keep their
/// knock-out gap. Geometry is in points at the 12 pt design size: one ring is 12 across with a 1.1 pt
/// stroke; the double marks are 18 wide, the right ring at x 6 hiding the left one behind a 0.6 pt gap.
/// Read is told by fill, not colour. Every mark is a template image tinted by its surroundings.
/// Failed is a filled disc with the exclamation knocked out, tinted the same meta colour as the others
/// (Signal's rule: failure is told by shape and the retry action, not red). System red measured 1.3–2.3:1
/// on the sent-bubble fills; the meta colour is at least 3.2:1 on all of them.
enum MessageStatusArt {
    static let designHeight: CGFloat = 12
    static let slotWidth: CGFloat = 18
    private static let line: CGFloat = 1.1
    private static let gap: CGFloat = 0.6

    /// The mark's width at the design size; the double rings fill the whole slot.
    static func designWidth(_ glyph: MessageStatusGlyph) -> CGFloat {
        switch glyph {
        case .delivered, .read: slotWidth
        case .sending, .sent, .failed: designHeight
        }
    }

    static func image(_ glyph: MessageStatusGlyph, scale: CGFloat) -> PlatformImage {
        let size = CGSize(width: designWidth(glyph) * scale, height: designHeight * scale)
        #if os(iOS)
        let image = UIGraphicsImageRenderer(size: size).image { context in
            draw(glyph, in: context.cgContext, scale: scale)
        }
        return image.withRenderingMode(.alwaysTemplate)
        #else
        // Flipped, so the y-down geometry below draws the same way up as in UIKit.
        let image = NSImage(size: size, flipped: true) { _ in
            guard let cg = NSGraphicsContext.current?.cgContext else { return false }
            draw(glyph, in: cg, scale: scale)
            return true
        }
        image.isTemplate = true
        return image
        #endif
    }

    private static func draw(_ glyph: MessageStatusGlyph, in cg: CGContext, scale: CGFloat) {
        cg.scaleBy(x: scale, y: scale)
        cg.setLineCap(.round)
        cg.setLineJoin(.round)
        cg.setLineWidth(line)
        PlatformColor.black.set()
        switch glyph {
        case .sending: dashedRing(cg)
        case .sent: ring(cg, centreX: 6); check(cg, offsetX: 0)
        case .delivered:
            hidingRightDisc(cg) { ring(cg, centreX: 6) }
            ring(cg, centreX: 12); check(cg, offsetX: 6)
        case .read:
            hidingRightDisc(cg) { disc(cg, centreX: 6) }
            disc(cg, centreX: 12)
            cg.setBlendMode(.clear)
            check(cg, offsetX: 6)
        case .failed:
            disc(cg, centreX: 6)
            cg.setBlendMode(.clear)
            exclamation(cg)
        }
    }

    private static func circle(centreX: CGFloat, radius: CGFloat) -> CGRect {
        CGRect(x: centreX - radius, y: 6 - radius, width: radius * 2, height: radius * 2)
    }

    private static func ring(_ cg: CGContext, centreX: CGFloat) {
        cg.strokeEllipse(in: circle(centreX: centreX, radius: 6 - line / 2))
    }

    private static func disc(_ cg: CGContext, centreX: CGFloat) {
        cg.fillEllipse(in: circle(centreX: centreX, radius: 6))
    }

    /// Twelve dashes and twelve equal gaps around the ring.
    private static func dashedRing(_ cg: CGContext) {
        let radius = 6 - line / 2
        let segment = 2 * .pi * radius / 24
        cg.setLineCap(.butt)
        cg.setLineDash(phase: segment / 2, lengths: [segment, segment])
        cg.strokeEllipse(in: circle(centreX: 6, radius: radius))
    }

    /// A 1.4 pt round-capped bar over a dot, centred in the 12 pt disc.
    private static func exclamation(_ cg: CGContext) {
        cg.setLineWidth(1.4)
        cg.move(to: CGPoint(x: 6, y: 3.0))
        cg.addLine(to: CGPoint(x: 6, y: 6.6))
        cg.strokePath()
        cg.fillEllipse(in: CGRect(x: 6 - 0.8, y: 8.9 - 0.8, width: 1.6, height: 1.6))
    }

    private static func check(_ cg: CGContext, offsetX: CGFloat) {
        cg.move(to: CGPoint(x: 3.3 + offsetX, y: 6.0))
        cg.addLine(to: CGPoint(x: 5.2 + offsetX, y: 8.2))
        cg.addLine(to: CGPoint(x: 8.5 + offsetX, y: 3.7))
        cg.strokePath()
    }

    /// Draws the left mark only outside the right disc grown by the gap, so the two never touch.
    private static func hidingRightDisc(_ cg: CGContext, _ draw: () -> Void) {
        cg.saveGState()
        let path = CGMutablePath()
        path.addRect(CGRect(x: 0, y: 0, width: slotWidth, height: designHeight))
        path.addEllipse(in: circle(centreX: 12, radius: 6 + gap))
        cg.addPath(path)
        cg.clip(using: .evenOdd)
        draw()
        cg.restoreGState()
    }
}

#if os(iOS)
/// The bubble footer's status slot: a fixed 18 pt wide box (scaled with Dynamic Type like caption2)
/// that right-aligns the mark, so the footer never reflows between states. Sending marks spin unless
/// Reduce Motion is on or the send is only unconfirmed.
@MainActor
final class MessageStatusView: UIView {
    private let mark = UIImageView()
    private var glyph: MessageStatusGlyph?
    private static let spinKey = "messageStatusSpin"

    override init(frame: CGRect) {
        super.init(frame: frame)
        isAccessibilityElement = false
        mark.contentMode = .scaleToFill
        addSubview(mark)
        setContentCompressionResistancePriority(.required, for: .horizontal)
        setContentHuggingPriority(.required, for: .horizontal)
        registerForTraitChanges([UITraitPreferredContentSizeCategory.self]) { (view: MessageStatusView, _: UITraitCollection) in
            view.redraw()
        }
        NotificationCenter.default.addObserver(self, selector: #selector(reduceMotionChanged), name: UIAccessibility.reduceMotionStatusDidChangeNotification, object: nil)
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    private var scale: CGFloat {
        UIFontMetrics(forTextStyle: .caption2).scaledValue(for: MessageStatusArt.designHeight, compatibleWith: traitCollection) / MessageStatusArt.designHeight
    }

    override var intrinsicContentSize: CGSize {
        CGSize(width: MessageStatusArt.slotWidth * scale, height: MessageStatusArt.designHeight * scale)
    }

    func show(_ glyph: MessageStatusGlyph?) {
        guard glyph != self.glyph else { updateSpin(); return }
        self.glyph = glyph
        redraw()
    }

    /// Called from cell reuse: no animation survives into another message.
    func stopSpinning() { mark.layer.removeAnimation(forKey: Self.spinKey) }

    private func redraw() {
        invalidateIntrinsicContentSize()
        mark.image = glyph.map { MessageStatusArt.image($0, scale: scale) }
        setNeedsLayout()
        updateSpin()
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        guard let glyph else { mark.frame = .zero; return }
        let size = CGSize(width: MessageStatusArt.designWidth(glyph) * scale, height: MessageStatusArt.designHeight * scale)
        // Rotation turns about the mark's own centre, so the view is sized to the mark, not the slot.
        mark.bounds = CGRect(origin: .zero, size: size)
        mark.center = CGPoint(x: bounds.maxX - size.width / 2, y: bounds.midY)
    }

    override func didMoveToWindow() {
        super.didMoveToWindow()
        updateSpin()
    }

    @objc private func reduceMotionChanged() { updateSpin() }

    private func updateSpin() {
        let spins = glyph == .sending(spinning: true) && window != nil && !UIAccessibility.isReduceMotionEnabled
        guard spins else { stopSpinning(); return }
        guard mark.layer.animation(forKey: Self.spinKey) == nil else { return }
        let spin = CABasicAnimation(keyPath: "transform.rotation.z")
        spin.fromValue = 0
        spin.toValue = 2 * Double.pi
        spin.duration = 1
        spin.isCumulative = true
        spin.repeatCount = .infinity
        // Kept across backgrounding, which otherwise strips running animations.
        spin.isRemovedOnCompletion = false
        mark.layer.add(spin, forKey: Self.spinKey)
    }
}
#endif
