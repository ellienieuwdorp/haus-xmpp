import SwiftUI

/// React, Reply and More beside a bubble, on its outer side, while the pointer is over the message. It floats in the
/// gutter as an overlay, so showing it never moves anything. VoiceOver skips it: the row's actions hold the same.
struct MacMessageToolbar<MenuContent: View>: View {
    let message: TimelineMessage
    let react: () -> Void
    let reply: (() -> Void)?
    @ViewBuilder let menu: () -> MenuContent

    private static var side: CGFloat { 24 }

    var body: some View {
        HStack(spacing: 0) {
            if !message.showsPlaceholder {
                button("React", symbol: "face.smiling", help: message.reactionUnavailableReason ?? "React", action: react)
                    .disabled(!message.canReact)
            }
            if let reply { button("Reply", symbol: "arrowshape.turn.up.left", help: "Reply", action: reply) }
            Menu(content: menu) {
                Image(systemName: "ellipsis").frame(width: Self.side, height: Self.side).contentShape(Rectangle())
            }
            .menuStyle(.button)
            .menuIndicator(.hidden)
            .buttonStyle(.plain)
            .frame(width: Self.side, height: Self.side)
            .help("More")
        }
        .font(.system(size: 13, weight: .medium))
        // Plain buttons in one quiet colour: a borderless menu would take the accent and the other two would not.
        .foregroundStyle(Color.secondaryLabel)
        .padding(2)
        .glassEffect(.regular, in: Capsule())
        .accessibilityHidden(true)
    }

    private func button(_ title: String, symbol: String, help: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: symbol).frame(width: Self.side, height: Self.side).contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help(help)
        .accessibilityLabel(title)
    }
}
