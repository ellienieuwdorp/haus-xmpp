import SwiftUI

/// A fixed circle keeps symbol layout independent of button state and text baselines.
struct CircularGlassButtonStyle: ButtonStyle {
    let diameter: CGFloat
    @Environment(\.isEnabled) private var isEnabled

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .foregroundStyle(.white)
            .frame(width: diameter, height: diameter, alignment: .center)
            .contentShape(Circle())
            .glassEffect(.regular.tint(.accentColor).interactive(), in: Circle())
            .opacity(isEnabled ? (configuration.isPressed ? 0.8 : 1) : 0.35)
    }
}
