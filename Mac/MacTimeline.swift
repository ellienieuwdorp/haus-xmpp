import AppKit
import SwiftUI

/// The open chat's timeline: a SwiftUI `ScrollView` over a `LazyVStack` of rows, positioned by
/// `MacTimelineController`. It opens at the newest message in its first frame, keeps the reader's row through updates
/// and resizes, pages in older history near the top, and has a jump-to-newest button and a floating day chip.
///
/// It is one stop in the window's keyboard focus, between the sidebar (and the find bar) and the composer. With focus,
/// the scrolling keys work (Page Up and Down, Home and End, ⌘↑ and ⌘↓), ↑ and ↓ move a focus ring from message to
/// message, Return or Space opens the focused message's menu, and Esc goes to the composer (`onEscape`); the Message
/// menu acts on the focused message too. VoiceOver reads each message as one element and offers rotors over the
/// messages, their links and the starred ones.
struct MacTimeline<Row: View>: View {
    let controller: MacTimelineController
    /// The contact's name in a direct chat, for the rotors' entries.
    var contactName: String? = nil
    /// One message's row.
    @ViewBuilder let row: (TimelineRow) -> Row
    /// The reader's row, written by SwiftUI as the reader scrolls. Code sets it only for the layout pass that lands a
    /// page above the reader (`MacTimelineController.update`), or an offset for the pass that lands a long jump
    /// (`approach`), and clears it right after: a scroll-to-row is ignored while the bound position holds a row code set.
    @State private var position = ScrollPosition(idType: String.self)
    @FocusState private var focused: Bool
    @Namespace private var rotors

    var body: some View {
        ScrollViewReader { proxy in
            ScrollView {
                // Equal while it shows the same timeline: the rows follow the controller, not this view's updates.
                MacTimelineRows(controller: controller, rotors: rotors, row: row).equatable()
            }
            .coordinateSpace(.named(MacTimelineLayout.space))
            .modifier(ReaderPosition(position: $position))
            .defaultScrollAnchor(.bottom, for: .initialOffset)
            .defaultScrollAnchor(.bottom, for: .sizeChanges)
            .onGeometryChange(for: CGSize.self) { $0.size } action: { controller.resized($0) }
            .onScrollGeometryChange(for: ScrollGeometry.self) { $0 } action: { _, geometry in controller.scrolled(geometry) }
            .onScrollPhaseChange { _, phase in controller.phaseChanged(phase) }
            .onAppear {
                controller.layout.proxy = proxy
                controller.layout.scrollPosition = $position
            }
            .focusable()
            .focused($focused)
            // The focused message carries the ring; the scroll view itself would draw one around the whole timeline.
            .focusEffectDisabled()
            .onKeyPress(keys: [.pageUp, .pageDown, .home, .end, .upArrow, .downArrow, .return, .space, .escape]) { press in
                // Arrow keys also carry the numeric pad and function flags; only these four tell the keys apart.
                let modifiers = press.modifiers.intersection([.command, .shift, .option, .control])
                let plain = modifiers.isEmpty
                // Scrolls run in the next turn: while SwiftUI handles the key, the rows report no new frames, so a
                // scroll would correct itself against where they were before it.
                func later(_ action: @escaping @MainActor () -> Void) {
                    DispatchQueue.main.async { MainActor.assumeIsolated { action() } }
                }
                switch press.key {
                case .pageUp: later { controller.scroll(.pageUp) }
                case .pageDown: later { controller.scroll(.pageDown) }
                case .home: later { controller.scroll(.top) }
                case .end: later { controller.scroll(.bottom) }
                case .upArrow where modifiers == .command: later { controller.scroll(.top) }
                case .downArrow where modifiers == .command: later { controller.scroll(.bottom) }
                case .upArrow where plain: later { controller.moveFocus(forward: false) }
                case .downArrow where plain: later { controller.moveFocus(forward: true) }
                case .return where plain, .space where plain: return controller.openFocusedMenu() ? .handled : .ignored
                case .escape: controller.onEscape()
                default: return .ignored
                }
                return .handled
            }
            .onChange(of: focused) { _, focused in
                controller.keyboardFocusChanged(focused, byKey: NSApp.currentEvent?.type == .keyDown)
            }
            .onChange(of: controller.focusRequests) { _, _ in focused = true }
            .accessibilityLabel("Messages")
            .modifier(MacTimelineRotors(controller: controller, contactName: contactName, namespace: rotors))
            .overlay(alignment: .top) { MacDayChip(controller: controller) }
            .overlay(alignment: .bottomTrailing) { MacJumpToNewest(controller: controller) }
        }
    }
}

/// Binds the reader's row through `scrollPosition(_:anchor: .top)`, which keeps it through resizes and through content
/// changes while no gesture runs. `-haus-timeline-unbound` (DEBUG) leaves it out, to test the controller's hold alone.
private struct ReaderPosition: ViewModifier {
    @Binding var position: ScrollPosition

    func body(content: Content) -> some View {
        #if DEBUG
        if MacDebugHooks.has("-haus-timeline-unbound") {
            content
        } else {
            content.scrollPosition($position, anchor: .top)
        }
        #else
        content.scrollPosition($position, anchor: .top)
        #endif
    }
}

/// The rows alone, so a change of the reader's position, which only the scroll view reads, never re-runs the list.
/// Equal for the same controller: the row builder reads what it needs when it runs, so a newer copy of it changes nothing.
private struct MacTimelineRows<Row: View>: View, Equatable {
    let controller: MacTimelineController
    let rotors: Namespace.ID
    let row: (TimelineRow) -> Row

    nonisolated static func == (left: Self, right: Self) -> Bool { left.controller === right.controller }

    var body: some View {
        let layout = controller.layout
        LazyVStack(spacing: 0) {
            ForEach(controller.items) { item in
                Group {
                    switch item {
                    case .loadingEarlier: MacLoadingEarlierRow()
                    case .message(let message):
                        row(message)
                            .background { MacTimelineHighlight(controller: controller, id: message.message.id) }
                            .environment(\.timelineRow, MacTimelineRowContext(timeline: controller, id: message.message.id, rotors: rotors))
                    case .typing(let typing): MacTypingRow(typing: typing)
                    case .end: Color.clear.frame(height: MacTimelineController.topMargin)
                    }
                }
                .id(item.id)
                .reportsFrame(item.id, to: layout)
            }
        }
        .padding(.horizontal, 16)
        .padding(.top, MacTimelineController.topMargin)
        .scrollTargetLayout()
        .background { MacTimelineAnchor(layout: layout) }
        .environment(\.openQuotedMessage, OpenQuotedMessage(timeline: controller))
    }
}

private extension View {
    func reportsFrame(_ id: String, to layout: MacTimelineLayout) -> some View { modifier(FrameReport(id: id, layout: layout)) }
}

/// Keeps a row's frame in the scroll view's coordinates in `layout`, and whether it is laid out now.
private struct FrameReport: ViewModifier {
    let id: String
    let layout: MacTimelineLayout
    @State private var instance = UUID()

    func body(content: Content) -> some View {
        content
            .onGeometryChange(for: CGRect.self) { $0.frame(in: .named(MacTimelineLayout.space)) } action: { layout.report(id, $0) }
            .onAppear { layout.appeared(id, instance: instance) }
            .onDisappear { layout.disappeared(id, instance: instance) }
    }
}

/// The tint behind a message that was just scrolled to; each row reads only whether it is the one.
private struct MacTimelineHighlight: View {
    let controller: MacTimelineController
    let id: String
    @Environment(\.appearance) private var appearance

    var body: some View {
        if controller.highlightedID == id {
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .fill(Color(platform: appearance.accent.tint).opacity(0.15))
                .padding(.horizontal, -8)
        }
    }
}

/// Above the oldest message while the server's older history is fetched, as on the iPhone.
struct MacLoadingEarlierRow: View {
    static let label = "Loading earlier messages"

    var body: some View {
        HStack(spacing: 8) {
            ProgressView().controlSize(.small)
            Text(Self.label + "…").font(.footnote).foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, minHeight: 44)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(Self.label)
    }
}

/// The floating day: the inline day header's capsule over an opaque backing, so rows passing under it never show
/// through. Its own view, so its movement redraws nothing else.
private struct MacDayChip: View {
    let controller: MacTimelineController
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        if let chip = controller.dayChip {
            Text(chip.text)
                .font(.caption.weight(.semibold)).foregroundStyle(.secondary)
                .padding(.horizontal, 10).padding(.vertical, 4)
                .frame(height: MacTimelineController.chipHeight)
                .background(.quaternary, in: Capsule())
                .background(Color(nsColor: .textBackgroundColor), in: Capsule())
                .opacity(chip.opacity)
                // Reduce Motion: it fades where it rests instead of being pushed up.
                .offset(y: reduceMotion ? MacTimelineController.chipLine : chip.top)
                .allowsHitTesting(false)
                .accessibilityHidden(true)
                .transition(.opacity)
        }
    }
}

/// Back to the newest message, while the reader is well above it.
private struct MacJumpToNewest: View {
    let controller: MacTimelineController
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        if controller.showsJumpToNewest {
            Button { controller.scroll(.bottom) } label: {
                Image(systemName: "chevron.down").font(.system(size: 15, weight: .semibold))
            }
            .buttonStyle(CircularGlassButtonStyle(diameter: 36, tinted: false))
            .accessibilityLabel("Scroll to Newest Message")
            .help("Scroll to the newest message")
            .padding(.trailing, 12).padding(.bottom, 8)
            .transition(reduceMotion ? .opacity : .opacity.combined(with: .scale(scale: 0.8)))
        }
    }
}
