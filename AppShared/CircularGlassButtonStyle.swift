import SwiftUI

// A fixed circle keeps the symbol's layout independent of button state; the hit target is at least 44 pt.
struct CircularGlassButtonStyle: ButtonStyle {
    let diameter: CGFloat
    var tinted = true
    @Environment(\.isEnabled) private var isEnabled
    @Environment(\.appearance) private var appearance

    func makeBody(configuration: Configuration) -> some View {
        let theme = appearance.accent
        configuration.label
            .foregroundStyle(tinted ? Color(platform: theme.bubbleText) : Color(platform: theme.tint))
            .frame(width: diameter, height: diameter, alignment: .center)
            .glassEffect(tinted ? .regular.tint(Color(platform: theme.bubble)).interactive() : .regular.interactive(), in: Circle())
            .frame(width: max(diameter, 44), height: max(diameter, 44))
            .contentShape(Circle())
            .opacity(isEnabled ? (configuration.isPressed ? 0.8 : 1) : 0.35)
    }
}
