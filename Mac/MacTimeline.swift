import AppKit
import SwiftUI

/// The open chat's timeline: a SwiftUI `ScrollView` over a `LazyVStack` of rows, positioned by
/// `MacTimelineController`. It opens at the newest message in its first frame, keeps the reader's row through updates
/// and resizes, pages in older history near the top, and has a jump-to-newest button, a floating day chip and the
/// scrolling keys (Page Up and Down, Home and End, ⌘↑ and ⌘↓) while it has keyboard focus.
struct MacTimeline<Row: View>: View {
    let controller: MacTimelineController
    /// One message's row.
    @ViewBuilder let row: (TimelineRow) -> Row
    /// The reader's row, written by SwiftUI as the reader scrolls and never by code: a scroll-to-row is ignored while
    /// the bound position holds a row code set.
    @State private var topID: String?

    var body: some View {
        ScrollViewReader { proxy in
            ScrollView {
                // Equal while it shows the same timeline: the rows follow the controller, not this view's updates.
                MacTimelineRows(controller: controller, row: row).equatable()
            }
            .coordinateSpace(.named(MacTimelineLayout.space))
            .modifier(ReaderPosition(id: $topID))
            .defaultScrollAnchor(.bottom, for: .initialOffset)
            .defaultScrollAnchor(.bottom, for: .sizeChanges)
            .onGeometryChange(for: CGSize.self) { $0.size } action: { controller.resized($0) }
            .onScrollGeometryChange(for: ScrollGeometry.self) { $0 } action: { _, geometry in controller.scrolled(geometry) }
            .onScrollPhaseChange { _, phase in controller.phaseChanged(phase) }
            .onAppear { controller.layout.proxy = proxy }
            .focusable()
            .focusEffectDisabled()
            .onKeyPress(keys: [.pageUp, .pageDown, .home, .end, .upArrow, .downArrow]) { press in
                switch press.key {
                case .pageUp: controller.scroll(.pageUp)
                case .pageDown: controller.scroll(.pageDown)
                case .home: controller.scroll(.top)
                case .end: controller.scroll(.bottom)
                case .upArrow where press.modifiers == .command: controller.scroll(.top)
                case .downArrow where press.modifiers == .command: controller.scroll(.bottom)
                default: return .ignored
                }
                return .handled
            }
            .overlay(alignment: .top) { MacDayChip(controller: controller) }
            .overlay(alignment: .bottomTrailing) { MacJumpToNewest(controller: controller) }
        }
    }
}

/// Binds the reader's row through `scrollPosition(id:anchor: .top)`, which keeps it through resizes and through content
/// changes while no gesture runs. `-haus-timeline-unbound` (DEBUG) leaves it out, to test the controller's hold alone.
private struct ReaderPosition: ViewModifier {
    @Binding var id: String?

    func body(content: Content) -> some View {
        #if DEBUG
        if MacDebugHooks.has("-haus-timeline-unbound") {
            content
        } else {
            content.scrollPosition(id: $id, anchor: .top)
        }
        #else
        content.scrollPosition(id: $id, anchor: .top)
        #endif
    }
}

/// The rows alone, so a change of the reader's position, which only the scroll view reads, never re-runs the list.
/// Equal for the same controller: the row builder reads what it needs when it runs, so a newer copy of it changes nothing.
private struct MacTimelineRows<Row: View>: View, Equatable {
    let controller: MacTimelineController
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
                        row(message).background { MacTimelineHighlight(controller: controller, id: message.message.id) }
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

    var body: some View {
        if controller.showsJumpToNewest {
            Button { controller.scroll(.bottom) } label: {
                Image(systemName: "chevron.down").font(.system(size: 15, weight: .semibold))
            }
            .buttonStyle(CircularGlassButtonStyle(diameter: 36, tinted: false))
            .accessibilityLabel("Scroll to Newest Message")
            .help("Scroll to the newest message")
            .padding(.trailing, 12).padding(.bottom, 8)
            .transition(.opacity.combined(with: .scale(scale: 0.8)))
        }
    }
}
