import SwiftUI

/// React, Reply and More beside a bubble, on its outer side, while the pointer is over the message. It floats in the
/// gutter as an overlay, so showing it never moves anything. VoiceOver and the keyboard skip it: the row's actions and
/// the menu Return opens hold the same.
struct MacMessageToolbar<MenuContent: View>: View {
    let message: TimelineMessage
    let react: () -> Void
    let reply: (() -> Void)?
    @ViewBuilder let menu: () -> MenuContent

    private static var side: CGFloat { MacMessageToolbarSize.side }

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
            .focusable(false)
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
        .focusable(false)
        .help(help)
        .accessibilityLabel(title)
    }
}

enum MacMessageToolbarSize {
    static let side: CGFloat = 24
    /// With all three buttons and the capsule's padding, for deciding where it fits.
    static let maximumWidth: CGFloat = 3 * side + 4
}
