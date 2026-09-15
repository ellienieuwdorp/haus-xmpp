import SwiftUI

/// A fixed circle keeps symbol layout independent of button state and text baselines.
/// The hit target is always at least 44pt, even for a smaller visible circle.
struct CircularGlassButtonStyle: ButtonStyle {
    let diameter: CGFloat
    /// Accent-filled circle with bubble text; `false` gives a clear glass circle with an accent glyph.
    var tinted = true
    @Environment(\.isEnabled) private var isEnabled
    @AppStorage(AccentTheme.storageKey) private var accent = ""

    func makeBody(configuration: Configuration) -> some View {
        let theme = AccentTheme(rawValue: accent) ?? .indigo
        configuration.label
            .foregroundStyle(tinted ? Color(uiColor: theme.bubbleText) : Color(uiColor: theme.tint))
            .frame(width: diameter, height: diameter, alignment: .center)
            .glassEffect(tinted ? .regular.tint(Color(uiColor: theme.bubble)).interactive() : .regular.interactive(), in: Circle())
            .frame(width: max(diameter, 44), height: max(diameter, 44))
            .contentShape(Circle())
            .opacity(isEnabled ? (configuration.isPressed ? 0.8 : 1) : 0.35)
    }
}
