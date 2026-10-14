import SwiftUI
#if os(iOS)
import UIKit
#else
import AppKit
#endif

/// The single source of the user's accent and light/dark choice. Every screen, sheet and hosted
/// controller reads this one object, so a change made in Settings repaints the sheet that made it too.
/// Persists under the same keys the app always used, so stored preferences survive.
@Observable @MainActor final class AppearanceStore {
    static let shared = AppearanceStore()

    static let modes = ["automatic", "light", "dark"]

    var accent: AccentTheme { didSet { defaults.set(accent.rawValue, forKey: AccentTheme.storageKey) } }
    /// One of `modes`; "automatic" follows the system.
    var mode: String { didSet { defaults.set(mode, forKey: AppearanceView.modeKey) } }
    #if os(iOS)
    var interfaceStyle: UIUserInterfaceStyle {
        switch mode { case "light": .light; case "dark": .dark; default: .unspecified }
    }
    #else
    /// The app's appearance on the Mac; nil follows the system.
    var interfaceStyle: NSAppearance? {
        switch mode { case "light": NSAppearance(named: .aqua); case "dark": NSAppearance(named: .darkAqua); default: nil }
    }
    #endif

    @ObservationIgnored private let defaults: UserDefaults

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        accent = AccentTheme(rawValue: defaults.string(forKey: AccentTheme.storageKey) ?? "") ?? .indigo
        mode = defaults.string(forKey: AppearanceView.modeKey).flatMap { Self.modes.contains($0) ? $0 : nil } ?? "automatic"
    }
}

private struct AppearanceStoreKey: EnvironmentKey {
    // Views hosted in their own UIHostingController (composer, message menu) have no inherited
    // environment; they fall back to the same shared store instead of a copy.
    static var defaultValue: AppearanceStore { MainActor.assumeIsolated { .shared } }
}

extension EnvironmentValues {
    var appearance: AppearanceStore {
        get { self[AppearanceStoreKey.self] }
        set { self[AppearanceStoreKey.self] = newValue }
    }
}

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

/// User-selectable accent. Light accents use dark text on the sent bubble; every pair below is measured
/// against WCAG 2 in both appearances: 4.5:1 for glyphs and links on the background and 4.5:1 for text on
/// the bubble. Message status glyphs carry no accent colour: they take the bubble's metadata colour.
enum AccentTheme: String, CaseIterable, Identifiable {
    case indigo, lime, crab, sky, rose, graphite

    static let storageKey = "accentTheme"
    /// The live selection. Reads go through the observable store, so a SwiftUI body that reads this repaints on change.
    @MainActor static var current: AccentTheme { AppearanceStore.shared.accent }

    var id: String { rawValue }
    var title: String { rawValue.prefix(1).uppercased() + rawValue.dropFirst() }

    /// Glyphs, links, buttons: at least 4.5:1 on both system backgrounds in each appearance.
    var tint: PlatformColor {
        switch self {
        case .indigo: return .systemIndigo
        case .lime: return .dynamic(light: PlatformColor(red: 0.22, green: 0.47, blue: 0.05, alpha: 1), dark: PlatformColor(red: 0.65, green: 0.88, blue: 0.39, alpha: 1))
        case .crab: return .dynamic(light: PlatformColor(red: 0.74, green: 0.26, blue: 0.11, alpha: 1), dark: PlatformColor(red: 0.96, green: 0.51, blue: 0.36, alpha: 1))
        case .sky: return .dynamic(light: PlatformColor(red: 0, green: 0.42, blue: 0.52, alpha: 1), dark: .systemTeal)
        case .rose: return .dynamic(light: PlatformColor(red: 0.78, green: 0.12, blue: 0.36, alpha: 1), dark: .systemPink)
        case .graphite: return .dynamic(light: PlatformColor(red: 0.36, green: 0.36, blue: 0.38, alpha: 1), dark: .systemGray)
        }
    }
    /// Sent-bubble fill: dark fills carry white text, light fills dark text, both at 4.5:1 in either appearance.
    var bubble: PlatformColor {
        switch self {
        case .indigo: return PlatformColor(red: 0.345, green: 0.337, blue: 0.839, alpha: 1)
        case .lime: return PlatformColor(red: 0.65, green: 0.88, blue: 0.39, alpha: 1)
        case .crab: return PlatformColor(red: 0.96, green: 0.51, blue: 0.36, alpha: 1)
        case .sky: return .systemTeal
        case .rose: return PlatformColor(red: 0.84, green: 0.15, blue: 0.40, alpha: 1)
        case .graphite: return PlatformColor(red: 0.42, green: 0.42, blue: 0.44, alpha: 1)
        }
    }
    /// Text on the sent bubble.
    var bubbleText: PlatformColor {
        switch self {
        case .lime: return PlatformColor(red: 0.06, green: 0.13, blue: 0, alpha: 1)
        case .crab: return PlatformColor(red: 0.16, green: 0.04, blue: 0, alpha: 1)
        case .sky: return PlatformColor(red: 0, green: 0.10, blue: 0.16, alpha: 1)
        default: return .white
        }
    }
    var swatch: Color { Color(platform: bubble) }
    /// The reply-quote panel and the link preview card inside a bubble. On a sent bubble a tint of its text colour; on
    /// the neutral received bubble a quiet shade in light mode and a quiet lift in dark mode, where a shade would
    /// vanish into the dark bubble.
    func panelFill(outgoing: Bool) -> PlatformColor {
        outgoing ? bubbleText.withAlphaComponent(bubbleText == .white ? 0.18 : 0.08)
            : .dynamic(light: PlatformColor.black.withAlphaComponent(0.06), dark: PlatformColor.white.withAlphaComponent(0.08))
    }
}

/// The one avatar circle: a verified image when the contact has one, otherwise their initial in a
/// hue keyed by address (`key`) so the same chat looks the same in every screen.
struct ChatAvatar: View {
    let key: String
    let name: String
    var image: PlatformImage? = nil
    var isGroup = false
    let size: CGFloat

    var body: some View {
        ZStack {
            if let image {
                Image(platformImage: image).resizable().scaledToFill()
            } else {
                Circle().fill(key.isEmpty ? Color.placeholderGray : Color(platform: AvatarPalette.color(for: key)))
                if isGroup {
                    Image(systemName: "person.2.fill").font(.system(size: size * 0.42, weight: .medium))
                } else if let initial = name.first {
                    Text(String(initial).uppercased()).font(.system(size: size * 0.42, weight: .semibold))
                } else {
                    Image(systemName: "person.fill").font(.system(size: size * 0.42))
                }
            }
        }
        .foregroundStyle(.white)
        .frame(width: size, height: size)
        .clipShape(Circle())
        .accessibilityHidden(true)
    }
}

/// Stable per-name avatar colour so a contact keeps its hue across launches.
enum AvatarPalette {
    static let colors: [PlatformColor] = [
        PlatformColor(red: 0.36, green: 0.48, blue: 0.84, alpha: 1), PlatformColor(red: 0.79, green: 0.42, blue: 0.55, alpha: 1),
        PlatformColor(red: 0.83, green: 0.54, blue: 0.29, alpha: 1), PlatformColor(red: 0.25, green: 0.64, blue: 0.54, alpha: 1),
        PlatformColor(red: 0.29, green: 0.61, blue: 0.79, alpha: 1), PlatformColor(red: 0.60, green: 0.42, blue: 0.82, alpha: 1),
        PlatformColor(red: 0.72, green: 0.53, blue: 0.23, alpha: 1), PlatformColor(red: 0.35, green: 0.63, blue: 0.35, alpha: 1),
    ]
    static func color(for name: String) -> PlatformColor {
        var hash: UInt32 = 2_166_136_261
        for scalar in name.lowercased().unicodeScalars { hash = (hash ^ scalar.value) &* 16_777_619 }
        return colors[Int(hash % UInt32(colors.count))]
    }
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
