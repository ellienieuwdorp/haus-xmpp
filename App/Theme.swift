import SwiftUI
import UIKit

/// User-selectable accent. Light accents use dark text on the sent bubble.
enum AccentTheme: String, CaseIterable, Identifiable {
    case indigo, lime, crab, sky, rose, graphite

    static let storageKey = "accentTheme"
    static var current: AccentTheme {
        AccentTheme(rawValue: UserDefaults.standard.string(forKey: storageKey) ?? "") ?? .indigo
    }

    var id: String { rawValue }
    var title: String { rawValue.prefix(1).uppercased() + rawValue.dropFirst() }

    /// Glyphs, links, buttons. Kept dark enough to read on white.
    var tint: UIColor {
        switch self {
        case .indigo: return .systemIndigo
        case .lime: return UIColor { $0.userInterfaceStyle == .dark ? UIColor(red: 0.65, green: 0.88, blue: 0.39, alpha: 1) : UIColor(red: 0.31, green: 0.60, blue: 0.11, alpha: 1) }
        case .crab: return UIColor { $0.userInterfaceStyle == .dark ? UIColor(red: 0.96, green: 0.51, blue: 0.36, alpha: 1) : UIColor(red: 0.85, green: 0.33, blue: 0.18, alpha: 1) }
        case .sky: return .systemTeal
        case .rose: return .systemPink
        case .graphite: return .systemGray
        }
    }
    /// Sent-bubble fill.
    var bubble: UIColor {
        switch self {
        case .indigo: return .systemIndigo
        case .lime: return UIColor(red: 0.65, green: 0.88, blue: 0.39, alpha: 1)
        case .crab: return UIColor(red: 0.96, green: 0.51, blue: 0.36, alpha: 1)
        case .sky: return .systemTeal
        case .rose: return .systemPink
        case .graphite: return .systemGray
        }
    }
    /// Text on the sent bubble.
    var bubbleText: UIColor {
        switch self {
        case .lime: return UIColor(red: 0.06, green: 0.13, blue: 0, alpha: 1)
        case .crab: return UIColor(red: 0.16, green: 0.04, blue: 0, alpha: 1)
        default: return .white
        }
    }
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
