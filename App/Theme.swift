import SwiftUI
import UIKit

/// The single source of the user's accent and light/dark choice. Every screen, sheet and hosted
/// controller reads this one object, so a change made in Settings repaints the sheet that made it too.
/// Persists under the same keys the app always used, so stored preferences survive.
@Observable @MainActor final class AppearanceStore {
    static let shared = AppearanceStore()

    static let modes = ["automatic", "light", "dark"]

    var accent: AccentTheme { didSet { defaults.set(accent.rawValue, forKey: AccentTheme.storageKey) } }
    /// One of `modes`; "automatic" follows the system.
    var mode: String { didSet { defaults.set(mode, forKey: AppearanceView.modeKey) } }
    var colorScheme: ColorScheme? { AppearanceView.colorScheme(for: mode) }
    var interfaceStyle: UIUserInterfaceStyle {
        switch mode { case "light": .light; case "dark": .dark; default: .unspecified }
    }

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
            .tint(Color(uiColor: appearance.accent.tint))
            .background { WindowInterfaceStyle(style: appearance.interfaceStyle) }
    }
}

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

extension View {
    func themedRoot() -> some View { modifier(ThemedRoot()) }
}

/// User-selectable accent. Light accents use dark text on the sent bubble; every pair below is measured
/// against WCAG 2 in both appearances: 4.5:1 for glyphs and links on the background, 4.5:1 for text on
/// the bubble, 3:1 for the read-receipt glyph.
enum AccentTheme: String, CaseIterable, Identifiable {
    case indigo, lime, crab, sky, rose, graphite

    static let storageKey = "accentTheme"
    /// The live selection. Reads go through the observable store, so a SwiftUI body that reads this repaints on change.
    @MainActor static var current: AccentTheme { AppearanceStore.shared.accent }

    var id: String { rawValue }
    var title: String { rawValue.prefix(1).uppercased() + rawValue.dropFirst() }

    /// Glyphs, links, buttons: at least 4.5:1 on both system backgrounds in each appearance.
    var tint: UIColor {
        switch self {
        case .indigo: return .systemIndigo
        case .lime: return UIColor { $0.userInterfaceStyle == .dark ? UIColor(red: 0.65, green: 0.88, blue: 0.39, alpha: 1) : UIColor(red: 0.22, green: 0.47, blue: 0.05, alpha: 1) }
        case .crab: return UIColor { $0.userInterfaceStyle == .dark ? UIColor(red: 0.96, green: 0.51, blue: 0.36, alpha: 1) : UIColor(red: 0.74, green: 0.26, blue: 0.11, alpha: 1) }
        case .sky: return UIColor { $0.userInterfaceStyle == .dark ? .systemTeal : UIColor(red: 0, green: 0.42, blue: 0.52, alpha: 1) }
        case .rose: return UIColor { $0.userInterfaceStyle == .dark ? .systemPink : UIColor(red: 0.78, green: 0.12, blue: 0.36, alpha: 1) }
        case .graphite: return UIColor { $0.userInterfaceStyle == .dark ? .systemGray : UIColor(red: 0.36, green: 0.36, blue: 0.38, alpha: 1) }
        }
    }
    /// Sent-bubble fill: dark fills carry white text, light fills dark text, both at 4.5:1 in either appearance.
    var bubble: UIColor {
        switch self {
        case .indigo: return UIColor(red: 0.345, green: 0.337, blue: 0.839, alpha: 1)
        case .lime: return UIColor(red: 0.65, green: 0.88, blue: 0.39, alpha: 1)
        case .crab: return UIColor(red: 0.96, green: 0.51, blue: 0.36, alpha: 1)
        case .sky: return .systemTeal
        case .rose: return UIColor(red: 0.84, green: 0.15, blue: 0.40, alpha: 1)
        case .graphite: return UIColor(red: 0.42, green: 0.42, blue: 0.44, alpha: 1)
        }
    }
    /// Text on the sent bubble.
    var bubbleText: UIColor {
        switch self {
        case .lime: return UIColor(red: 0.06, green: 0.13, blue: 0, alpha: 1)
        case .crab: return UIColor(red: 0.16, green: 0.04, blue: 0, alpha: 1)
        case .sky: return UIColor(red: 0, green: 0.10, blue: 0.16, alpha: 1)
        default: return .white
        }
    }
    /// The two "read" blues: one sits on dark fills and dark backgrounds, the other on light ones, each above 3:1.
    private static let readBlueOnDark = UIColor(red: 0.50, green: 0.88, blue: 1, alpha: 1)
    private static let readBlueOnLight = UIColor(red: 0, green: 0.24, blue: 0.66, alpha: 1)
    /// The read-receipt glyph on the sent bubble: the blue that contrasts with this accent's fill.
    var readReceipt: UIColor { bubbleText == .white ? Self.readBlueOnDark : Self.readBlueOnLight }
    /// The read-receipt glyph on the chat list, where it sits on the system background rather than the fill.
    static let listReadReceipt = UIColor { $0.userInterfaceStyle == .dark ? readBlueOnDark : readBlueOnLight }
    var swatch: Color { Color(uiColor: bubble) }
}

/// The one avatar circle: a verified image when the contact has one, otherwise their initial in a
/// hue keyed by address (`key`) so the same chat looks the same in every screen.
struct ChatAvatar: View {
    let key: String
    let name: String
    var image: UIImage? = nil
    var isGroup = false
    let size: CGFloat

    var body: some View {
        ZStack {
            if let image {
                Image(uiImage: image).resizable().scaledToFill()
            } else {
                Circle().fill(key.isEmpty ? Color(.systemGray3) : Color(uiColor: AvatarPalette.color(for: key)))
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
    static let colors: [UIColor] = [
        UIColor(red: 0.36, green: 0.48, blue: 0.84, alpha: 1), UIColor(red: 0.79, green: 0.42, blue: 0.55, alpha: 1),
        UIColor(red: 0.83, green: 0.54, blue: 0.29, alpha: 1), UIColor(red: 0.25, green: 0.64, blue: 0.54, alpha: 1),
        UIColor(red: 0.29, green: 0.61, blue: 0.79, alpha: 1), UIColor(red: 0.60, green: 0.42, blue: 0.82, alpha: 1),
        UIColor(red: 0.72, green: 0.53, blue: 0.23, alpha: 1), UIColor(red: 0.35, green: 0.63, blue: 0.35, alpha: 1),
    ]
    static func color(for name: String) -> UIColor {
        var hash: UInt32 = 2_166_136_261
        for scalar in name.lowercased().unicodeScalars { hash = (hash ^ scalar.value) &* 16_777_619 }
        return colors[Int(hash % UInt32(colors.count))]
    }
}

extension UIImage {
    /// SF Symbols has no double check; two checkmarks overlapped by about half a glyph read as one.
    static func doubleCheck(_ configuration: UIImage.SymbolConfiguration?) -> UIImage? {
        guard let check = UIImage(systemName: "checkmark", withConfiguration: configuration) else { return nil }
        let offset = (check.size.width * 0.45).rounded()
        let size = CGSize(width: check.size.width + offset, height: check.size.height)
        return UIGraphicsImageRenderer(size: size).image { _ in
            check.draw(at: .zero)
            check.draw(at: CGPoint(x: offset, y: 0))
        }.withBaselineOffset(fromBottom: check.baselineOffsetFromBottom ?? 0).withRenderingMode(.alwaysTemplate)
    }
}
