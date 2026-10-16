import AppKit
import SwiftUI

/// Search and the starred filter above the open chat's timeline, as on the iPhone: the find bar (Edit > Find in
/// Conversation, ⌘F, or the details' Search tile) and the starred bar (View > Starred Messages, or the Starred tile).
/// The timeline lists what they select (`MacTimelineController.filtered`); Esc or Done closes the find bar, Show All the
/// starred bar.
struct MacConversationFindBars: View {
    let timeline: MacTimelineController
    /// Bumped by Find; the field takes keyboard focus on each change, and when the bar opens.
    let focusRequests: Int

    var body: some View {
        if timeline.searching || timeline.starredOnly {
            VStack(spacing: 0) {
                if timeline.searching { MacFindBar(timeline: timeline, focusRequests: focusRequests) }
                if timeline.searching && timeline.starredOnly { Divider() }
                if timeline.starredOnly { MacStarredBar(timeline: timeline) }
                Divider()
            }
            .background(.bar)
        }
    }
}

private struct MacFindBar: View {
    let timeline: MacTimelineController
    let focusRequests: Int

    /// The messages listed now; the stack holds them besides its loading, typing and end items.
    private var count: Int { timeline.items.count(where: { if case .message = $0 { true } else { false } }) }

    var body: some View {
        HStack(spacing: 10) {
            MacSearchField(text: Binding(get: { timeline.query }, set: { timeline.setQuery($0) }), prompt: "Search in Conversation",
                           focusRequests: focusRequests) { timeline.setSearching(false) }
                .frame(maxWidth: 320)
            // No minimum width on the field: with the inspector open it made the bar and the split view fight over the
            // column's width until the window stopped responding.
            status
            Spacer(minLength: 8)
            Button("Done") { timeline.setSearching(false) }
                .help("Close the search (Esc)")
        }
        .padding(.horizontal, 12).padding(.vertical, 6)
    }

    /// The iPhone's count line, or a spinner while the earlier messages search reads are still loading.
    @ViewBuilder private var status: some View {
        if timeline.loadingAll {
            HStack(spacing: 6) {
                ProgressView().controlSize(.small)
                Text(MacLoadingEarlierRow.label + "…").lineLimit(1)
            }
            .font(.callout).foregroundStyle(.secondary)
            .accessibilityElement(children: .ignore)
            .accessibilityLabel(MacLoadingEarlierRow.label)
        } else if !timeline.query.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            Text(count == 0 ? "No results in this conversation" : "\(count) \(count == 1 ? "message" : "messages") found")
                .font(.callout).foregroundStyle(.secondary)
                .lineLimit(1)
        }
    }
}

private struct MacStarredBar: View {
    let timeline: MacTimelineController

    var body: some View {
        HStack(spacing: 10) {
            Label("Starred Messages", systemImage: "star.fill")
                .font(.callout)
            if timeline.loadingAll && !timeline.searching {
                ProgressView().controlSize(.small)
                    .accessibilityLabel(MacLoadingEarlierRow.label)
            }
            Spacer(minLength: 8)
            Button("Show All") { timeline.setStarredOnly(false) }
                .help("Show every message in this chat")
        }
        .padding(.horizontal, 12).padding(.vertical, 6)
        .frame(minHeight: 34)
    }
}

/// A native search field. Esc closes the find bar (not only clears the field, as a plain search field would) unless
/// an input method is composing; keyboard focus moves into it when it appears and on each `focusRequests` change.
private struct MacSearchField: NSViewRepresentable {
    @Binding var text: String
    let prompt: String
    let focusRequests: Int
    let onCancel: () -> Void

    final class Coordinator: NSObject, NSSearchFieldDelegate {
        var parent: MacSearchField
        /// The request last acted on; none yet, so the field takes focus as it appears.
        var focusRequests: Int?

        init(_ parent: MacSearchField) { self.parent = parent }

        func controlTextDidChange(_ notification: Notification) {
            guard let field = notification.object as? NSSearchField else { return }
            parent.text = field.stringValue
        }

        func control(_ control: NSControl, textView: NSTextView, doCommandBy selector: Selector) -> Bool {
            guard selector == #selector(NSResponder.cancelOperation(_:)), !textView.hasMarkedText() else { return false }
            parent.onCancel()
            return true
        }
    }

    func makeCoordinator() -> Coordinator { Coordinator(self) }

    func makeNSView(context: Context) -> NSSearchField {
        let field = NSSearchField()
        field.placeholderString = prompt
        field.setAccessibilityLabel(prompt)
        field.sendsSearchStringImmediately = true
        field.delegate = context.coordinator
        return field
    }

    /// As wide as offered, as tall as the field's own line; left to itself, a hosted field's height follows the layout's
    /// proposal and a narrow column made the bar take the timeline's height.
    func sizeThatFits(_ proposal: ProposedViewSize, nsView field: NSSearchField, context: Context) -> CGSize? {
        let width = proposal.width.flatMap { $0.isFinite ? $0 : nil } ?? 200
        return CGSize(width: width, height: field.intrinsicContentSize.height)
    }

    func updateNSView(_ field: NSSearchField, context: Context) {
        context.coordinator.parent = self
        if field.stringValue != text { field.stringValue = text }
        guard context.coordinator.focusRequests != focusRequests else { return }
        context.coordinator.focusRequests = focusRequests
        // After this update: the field may not be in its window yet.
        DispatchQueue.main.async { field.window?.makeFirstResponder(field) }
    }
}

/// A filtered result: a click on it or its Show in Conversation action closes the filter and scrolls the whole timeline
/// to it, tinted for a moment. Links and attachments keep their own clicks; in the text, a drag still selects and a
/// click inside a selection keeps it (`FindResultClick`).
struct MacFindResult: ViewModifier {
    let timeline: MacTimelineController
    let id: String
    @State private var hovering = false

    func body(content: Content) -> some View {
        if timeline.isFiltered {
            content
                .background {
                    if hovering {
                        RoundedRectangle(cornerRadius: 10, style: .continuous).fill(.quaternary.opacity(0.6)).padding(.horizontal, -8)
                    }
                }
                .contentShape(Rectangle())
                .onHover { hovering = $0 }
                .onTapGesture { timeline.scrollTo(messageID: id) }
                .environment(\.findResultClick, FindResultClick(timeline: timeline, id: id))
                .help("Show in Conversation")
                .accessibilityAction(named: "Show in Conversation") { timeline.scrollTo(messageID: id) }
        } else {
            content
        }
    }
}

/// A filtered result's jump for a plain click on its bubble's text, which takes clicks before the row could see them.
/// Equal while it targets the same message, so setting it on each update never invalidates the bubble.
struct FindResultClick: Equatable {
    weak var timeline: MacTimelineController?
    var id: String?

    var isActive: Bool { timeline != nil && id != nil }

    @MainActor func callAsFunction() { if let id { timeline?.scrollTo(messageID: id) } }

    static func == (left: Self, right: Self) -> Bool { left.timeline === right.timeline && left.id == right.id }
}

extension EnvironmentValues {
    @Entry var findResultClick = FindResultClick()
}

/// The open chat's search and starred filter, for the menu commands; nil while no chat is shown.
struct MacConversationFindCommands {
    let find: () -> Void
    let starredOnly: Bool
    let setStarredOnly: (Bool) -> Void
}

extension FocusedValues {
    @Entry var conversationFind: MacConversationFindCommands?
}

#if DEBUG
/// The tour's search steps (`MacDebugHooks`): `find <text>` opens search with that text, `find-close` closes it,
/// `find-esc` does what Esc in the timeline does, `starred on|off` sets the starred filter, and
/// `show-result <message id>` does what a click on that result does.
@MainActor enum MacConversationFindTour {
    static func step(_ name: String, _ argument: String) {
        guard let timeline = MacTimelineController.current else { return MacDebugHooks.log("tour \(name): no open timeline") }
        switch name {
        case "find":
            timeline.setSearching(true)
            timeline.setQuery(argument)
        case "find-close": timeline.setSearching(false)
        case "find-esc": timeline.closeFilter()
        case "starred": timeline.setStarredOnly(argument != "off")
        case "show-result": timeline.scrollTo(messageID: argument)
        default: break
        }
        MacDebugHooks.log("find \(name) \(argument): searching \(timeline.searching), starred \(timeline.starredOnly), "
            + "\(timeline.rows.count) rows, loading all \(timeline.loadingAll)")
    }
}
#endif
