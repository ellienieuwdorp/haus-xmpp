import SwiftUI

/// Any emoji as a reaction, in a popover on the bubble: the quick reactions, the recent other ones (shared with the
/// iPhone's picker under the same preference), a search by name and the whole catalogue (`EmojiCatalog`). A popover
/// rather than the system Character Viewer, which types its choice into whatever text view holds the focus: the choice
/// would land in the composer, and nothing says when the viewer was closed without one.
struct MacEmojiPicker: View {
    let message: TimelineMessage
    let react: (String) -> Void
    @AppStorage("recentReactions") private var recentReactions = ""
    @Environment(\.appearance) private var appearance
    @State private var query = ""
    @FocusState private var searchFocused: Bool

    private var recents: [String] { recentReactions.split(separator: ",").map(String.init).filter { !$0.isEmpty } }
    private var selected: Set<String> { Set(message.reactions.filter(\.isSelected).map(\.emoji)) }
    private var results: [EmojiCatalog.Entry] { EmojiCatalog.search(query) }
    private static let columns = [GridItem(.adaptive(minimum: 32, maximum: 32), spacing: 2)]

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 2) {
                ForEach(TimelineReaction.choices, id: \.self) { button($0, size: 22) }
            }
            if let reason = message.reactionUnavailableReason {
                Text(reason).font(.caption).foregroundStyle(.secondary)
            }
            TextField("Search emoji", text: $query)
                .textFieldStyle(.roundedBorder)
                .focused($searchFocused)
                .onSubmit { if let first = results.first { choose(first.emoji) } }
            ScrollView {
                LazyVGrid(columns: Self.columns, alignment: .leading, spacing: 2) {
                    let showsRecents = query.isEmpty && !recents.isEmpty
                    if showsRecents {
                        Section {
                            ForEach(recents, id: \.self) { button($0, size: 20) }
                        } header: { header("Recent") }
                    }
                    Section {
                        ForEach(results, id: \.emoji) { entry in button(entry.emoji, size: 20, name: entry.name) }
                    } header: { if showsRecents { header("All") } }
                }
                .padding(.vertical, 2)
            }
            .frame(height: 220)
            .overlay {
                if results.isEmpty { Text("No emoji found").font(.callout).foregroundStyle(.secondary) }
            }
        }
        .padding(12)
        .frame(width: 300)
        .disabled(!message.canReact)
        .onAppear { searchFocused = true }
    }

    private func header(_ title: String) -> some View {
        Text(title).font(.caption.weight(.semibold)).foregroundStyle(.secondary)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.top, 4)
    }

    private func button(_ emoji: String, size: CGFloat, name: String? = nil) -> some View {
        let isSelected = selected.contains(emoji)
        return Button { choose(emoji) } label: {
            Text(emoji).font(.system(size: size))
                .frame(width: 32, height: 32)
                .background(isSelected ? Color(platform: appearance.accent.tint).opacity(0.2) : .clear, in: RoundedRectangle(cornerRadius: 6, style: .continuous))
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help(name ?? TimelineReaction.name(for: emoji))
        .accessibilityLabel(MessageActionMenu.reactionTitle(emoji, selected: isSelected))
    }

    private func choose(_ emoji: String) {
        guard message.canReact else { return }
        if !TimelineReaction.choices.contains(emoji) {
            recentReactions = ([emoji] + recents.filter { $0 != emoji }).prefix(6).joined(separator: ",")
        }
        react(emoji)
    }
}
