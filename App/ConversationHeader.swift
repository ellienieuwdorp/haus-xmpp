import SwiftUI

// Avatar, name and last seen in one capsule of interactive glass that hugs them up to `maxWidth`, past which the name
// truncates. The capsule is the bar's 44 pt, so at large text sizes the last seen gives way to the name alone.
struct ConversationHeaderPill: View {
    static let avatarSize: CGFloat = 40
    let avatar: ChatAvatar
    let title: String
    let lastSeen: String?
    let maxWidth: CGFloat

    // The back and options buttons, the bar's margins and the gaps between them take 140 pt of the bar.
    static func widthLimit(inBar width: CGFloat) -> CGFloat { max(width - 140, 120) }

    var body: some View {
        CappedWidth(maxWidth: maxWidth) {
            HStack(spacing: 8) {
                avatar
                text.dynamicTypeSize(...DynamicTypeSize.accessibility1)
            }
            .padding(.leading, 2)
            .padding(.trailing, 16)
            .frame(height: 44)
            .contentShape([.interaction, .hoverEffect], Capsule())
            .glassEffect(.regular.interactive(), in: Capsule())
        }
        .animation(.easeInOut(duration: 0.2), value: lastSeen)
    }

    @ViewBuilder private var text: some View {
        if let lastSeen {
            ViewThatFits(in: .vertical) {
                VStack(alignment: .leading, spacing: 1) {
                    Text(title).font(.subheadline.weight(.semibold)).foregroundStyle(.primary).lineLimit(1)
                    Text(lastSeen).font(.caption).foregroundStyle(.secondary).lineLimit(1)
                        .contentTransition(.opacity)
                }
                name
            }
            .transition(.opacity)
        } else {
            name.transition(.opacity)
        }
    }

    private var name: some View { Text(title).font(.headline).foregroundStyle(.primary).lineLimit(1) }
}

// Offers its content `maxWidth` whatever the bar proposes, so the bar never squeezes the name, and takes the size the
// content hugs to.
private struct CappedWidth: Layout {
    let maxWidth: CGFloat

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        subviews.first?.sizeThatFits(ProposedViewSize(width: maxWidth, height: proposal.height)) ?? .zero
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        subviews.first?.place(at: bounds.origin, proposal: ProposedViewSize(width: maxWidth, height: bounds.height))
    }
}

// The timeline ignores the top safe area and keeps its own insets, so a bar that minimizes while it scrolls would move
// the safe area under the anchored messages.
struct FixedNavigationBar: ViewModifier {
    func body(content: Content) -> some View {
        if #available(iOS 27, *) {
            content.toolbarMinimizationBehavior(.never, for: .navigationBar)
        } else {
            content
        }
    }
}
