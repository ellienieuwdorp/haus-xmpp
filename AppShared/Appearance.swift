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
    static let modeKey = "appearanceMode"

    var accent: AccentTheme {
        didSet {
            defaults.set(accent.rawValue, forKey: AccentTheme.storageKey)
            mirror?.set(accent.rawValue, forKey: AccentTheme.storageKey)
        }
    }
    /// The App Group copy of the accent, which the share extension draws its send button with. Only the app sets it;
    /// setting it writes the current choice.
    @ObservationIgnored var mirror: UserDefaults? { didSet { mirror?.set(accent.rawValue, forKey: AccentTheme.storageKey) } }
    /// One of `modes`; "automatic" follows the system.
    var mode: String { didSet { defaults.set(mode, forKey: Self.modeKey) } }
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
        mode = defaults.string(forKey: Self.modeKey).flatMap { Self.modes.contains($0) ? $0 : nil } ?? "automatic"
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
