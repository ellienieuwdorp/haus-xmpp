import SwiftUI
import UIKit
import XMPPProtocol

/// One list of what a message can do. The long-press overlay and VoiceOver custom actions both read it.
struct MessageAction: Identifiable {
    enum Kind: String { case reply, copy, selectText, star, retry }
    let kind: Kind
    let title: String
    let symbol: String
    let perform: () -> Void
    var id: Kind { kind }
}

/// What the overlay needs from the pressed bubble; frames are window coordinates.
struct MessageActionsContext {
    let message: TimelineMessage
    let bubble: UIView
    let bubbleFrame: CGRect
    let reactions: UIView?
    let reactionsFrame: CGRect
    let actions: [MessageAction]
    let react: (String) -> Void
    /// Hides the live bubble while its snapshot is on screen, so a moved snapshot never shows a twin.
    let setSourceHidden: (Bool) -> Void
}

/// Full-screen blur, the bubble at its real size, quick reactions above it and the action list below.
/// Replaces UIContextMenuInteraction, which cannot host a tappable accessory above its preview.
/// The controller is presented and dismissed without UIKit animation; the view animates itself so the
/// bubble starts and ends exactly where the live one is and pops the way the system menu does.
@MainActor
enum MessageActionsOverlay {
    static func present(from presenter: UIViewController, context: MessageActionsContext) {
        let window = presenter.view.window
        let safeArea = window?.safeAreaInsets ?? .zero
        // A real screenshot blurred by us: system materials tint as much as they blur, and the design
        // wants the timeline recognisable behind an 18 pt Gaussian blur and a light scrim.
        let backdrop = window.map { w in UIGraphicsImageRenderer(bounds: w.bounds).image { _ in w.drawHierarchy(in: w.bounds, afterScreenUpdates: false) } }
        let controller = UIHostingController(rootView: MessageActionsOverlayView(context: context, backdrop: backdrop, safeArea: safeArea, finish: { _ in }))
        controller.rootView.finish = { [weak controller] completion in controller?.dismiss(animated: false, completion: completion) }
        controller.view.backgroundColor = .clear
        controller.modalPresentationStyle = .overFullScreen
        presenter.present(controller, animated: false)
    }
}

struct MessageActionsOverlayView: View {
    let context: MessageActionsContext
    let backdrop: UIImage?
    let safeArea: UIEdgeInsets
    var finish: ((() -> Void)?) -> Void
    /// Blur, pill and menu are in; the bubble sits at its clamped position.
    @State private var entered = false
    /// The brief lift at the start of the press, like the system menu's preview.
    @State private var lifted = false
    @State private var choosingEmoji = false
    @State private var keyboardHeight: CGFloat = 0
    @AppStorage("recentReactions") private var recentReactions = ""
    @AppStorage(AccentTheme.storageKey) private var accent = ""
    @Environment(\.colorScheme) private var colorScheme

    private static let gap: CGFloat = 14
    private static let pillHeight: CGFloat = 52
    private static let enter = Animation.spring(duration: 0.38, bounce: 0.28)
    private static let leave = Animation.spring(duration: 0.24, bounce: 0)
    private var reduceMotion: Bool { UIAccessibility.isReduceMotionEnabled }
    private var message: TimelineMessage { context.message }
    private var tint: Color { Color(uiColor: (AccentTheme(rawValue: accent) ?? .indigo).tint) }
    private var recents: [String] { recentReactions.split(separator: ",").map(String.init).filter { !$0.isEmpty } }

    var body: some View {
        GeometryReader { geo in
            let rowHeight = max(44, ceil(UIFont.preferredFont(forTextStyle: .body).lineHeight) + 22)
            let menuHeight = CGFloat(context.actions.count) * rowHeight
            let reasonHeight: CGFloat = message.reactionUnavailableReason == nil ? 0 : 22
            let recentsHeight: CGFloat = choosingEmoji && !recents.isEmpty ? 44 : 0
            let block = context.reactions == nil ? context.bubbleFrame : context.bubbleFrame.union(context.reactionsFrame)
            let top = safeArea.top + 8
            let bottom = geo.size.height - max(safeArea.bottom, keyboardHeight) - 8
            let fitScale = min(1, max(0.3, (bottom - top - Self.pillHeight - reasonHeight - recentsHeight - menuHeight - 2 * Self.gap) / block.height))
            let groupHeight = Self.pillHeight + reasonHeight + recentsHeight + Self.gap + block.height * fitScale + Self.gap + (choosingEmoji ? 0 : menuHeight)
            let groupTop = min(max(top, block.minY - Self.pillHeight - reasonHeight - Self.gap), max(top, bottom - groupHeight))
            let bubbleTop = entered ? groupTop + Self.pillHeight + reasonHeight + recentsHeight + Self.gap : block.minY
            let scale = entered ? fitScale : 1
            let alignment: Alignment = message.isOutgoing ? .trailing : .leading
            let pillAnchor: UnitPoint = message.isOutgoing ? .bottomTrailing : .bottomLeading
            let menuAnchor: UnitPoint = message.isOutgoing ? .topTrailing : .topLeading

            ZStack(alignment: .topLeading) {
                backdropView(size: geo.size)
                    .opacity(entered ? 1 : 0)
                    .contentShape(Rectangle())
                    .onTapGesture { dismiss(nil) }
                    .accessibilityAddTraits(.isButton).accessibilityLabel("Dismiss")
                // Pill and menu live at their final positions and only scale from the bubble's edge.
                VStack(alignment: message.isOutgoing ? .trailing : .leading, spacing: 6) {
                    reactionPill
                    if let reason = message.reactionUnavailableReason {
                        Text(reason).font(.caption).foregroundStyle(.secondary).lineLimit(1)
                            .padding(.horizontal, 12).accessibilityIdentifier("reactionUnavailableReason")
                    }
                    if choosingEmoji, !recents.isEmpty { recentsRow }
                }
                .scaleEffect(entered ? 1 : 0.5, anchor: pillAnchor)
                .opacity(entered ? 1 : 0)
                .frame(width: geo.size.width - 32, alignment: alignment)
                .offset(x: 16, y: groupTop)
                snapshot(context.bubble, frame: context.bubbleFrame, scale: scale, anchor: block.minY, top: bubbleTop)
                    .shadow(color: .black.opacity(entered ? 0.18 : 0), radius: 14, y: 12)
                if let reactions = context.reactions {
                    snapshot(reactions, frame: context.reactionsFrame, scale: scale, anchor: block.minY, top: bubbleTop)
                }
                if !choosingEmoji {
                    menu
                        .scaleEffect(entered ? 1 : 0.5, anchor: menuAnchor)
                        .opacity(entered ? 1 : 0)
                        .frame(width: geo.size.width - 32, alignment: alignment)
                        .offset(x: 16, y: groupTop + Self.pillHeight + reasonHeight + recentsHeight + Self.gap + block.height * fitScale + Self.gap)
                        .transition(.scale(scale: 0.9, anchor: menuAnchor).combined(with: .opacity))
                }
            }
            .animation(reduceMotion ? nil : Self.enter, value: choosingEmoji)
            .gesture(DragGesture(minimumDistance: 30).onEnded { _ in dismiss(nil) })
        }
        .ignoresSafeArea()
        .onAppear(perform: enter)
        .onReceive(NotificationCenter.default.publisher(for: UIResponder.keyboardWillChangeFrameNotification)) { note in
            guard let frame = (note.userInfo?[UIResponder.keyboardFrameEndUserInfoKey] as? NSValue)?.cgRectValue,
                  let screen = (note.object as? UIScreen) ?? UIScreen.main as UIScreen? else { return }
            keyboardHeight = max(0, screen.bounds.height - frame.minY)
        }
    }

    /// The snapshot already covers the live bubble exactly, so hiding the live one is invisible.
    /// Then: lift the bubble, and let the blur, pill and menu spring in around it.
    private func enter() {
        context.setSourceHidden(true)
        if reduceMotion { entered = true; return }
        withAnimation(.spring(duration: 0.18, bounce: 0.35)) { lifted = true }
        withAnimation(Self.enter) { entered = true }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.16) {
            withAnimation(.spring(duration: 0.3, bounce: 0.25)) { lifted = false }
        }
    }

    /// Reverses the entrance, then removes the controller and shows the live bubble again.
    private func dismiss(_ completion: (() -> Void)?) {
        if reduceMotion { entered = false } else { withAnimation(Self.leave) { entered = false } }
        DispatchQueue.main.asyncAfter(deadline: .now() + (reduceMotion ? 0 : 0.24)) {
            context.setSourceHidden(false)
            finish(completion)
        }
    }

    @ViewBuilder private func backdropView(size: CGSize) -> some View {
        ZStack {
            if let backdrop {
                // Oversize, blur, then clip, so the blur's soft edge falls outside the screen.
                Image(uiImage: backdrop).resizable()
                    .frame(width: size.width + 80, height: size.height + 80)
                    .blur(radius: 18)
                    .frame(width: size.width, height: size.height)
                    .clipped()
            } else {
                Color(uiColor: .systemBackground)
            }
            (colorScheme == .dark ? Color.black.opacity(0.45) : Color.white.opacity(0.35))
        }
        .frame(width: size.width, height: size.height)
    }

    /// The lift grows from the bubble's centre; a fit scale (bubble taller than the screen) keeps the
    /// outer edge fixed so the group stays against its side of the timeline.
    private func snapshot(_ view: UIView, frame: CGRect, scale: CGFloat, anchor: CGFloat, top: CGFloat) -> some View {
        SnapshotView(view: view)
            .frame(width: frame.width, height: frame.height)
            .scaleEffect(lifted ? 1.05 : 1, anchor: .center)
            .scaleEffect(scale, anchor: message.isOutgoing ? .topTrailing : .topLeading)
            .offset(x: frame.minX, y: top + (frame.minY - anchor) * scale)
    }

    private var reactionPill: some View {
        let selected = Set(message.reactions.filter(\.isSelected).map(\.emoji))
        return HStack(spacing: 2) {
            ForEach(TimelineReaction.choices, id: \.self) { emoji in
                reactionButton(emoji, selected: selected.contains(emoji))
            }
            Button { choosingEmoji.toggle() } label: {
                Image(systemName: "plus").font(.system(size: 15, weight: .semibold)).foregroundStyle(.secondary)
                    .frame(width: 36, height: 36).background(Color.primary.opacity(0.08), in: Circle())
            }
            .buttonStyle(.plain).frame(width: 44, height: 44)
            .disabled(!message.canReact)
            .accessibilityLabel("More reactions").accessibilityIdentifier("moreReactions")
        }
        .padding(.horizontal, 6)
        .frame(height: Self.pillHeight)
        .glassEffect(.regular, in: Capsule())
        .opacity(message.canReact ? 1 : 0.45)
    }

    private var recentsRow: some View {
        HStack(spacing: 2) {
            ForEach(recents, id: \.self) { emoji in reactionButton(emoji, selected: message.reactions.contains { $0.emoji == emoji && $0.isSelected }) }
            EmojiKeyboardField { emoji in react(emoji) }.frame(width: 1, height: 1).opacity(0.02)
        }
        .padding(.horizontal, 6).frame(height: 44).glassEffect(.regular, in: Capsule())
    }

    private func reactionButton(_ emoji: String, selected: Bool) -> some View {
        Button { react(emoji) } label: {
            Text(emoji).font(.system(size: 26))
                .frame(width: 44, height: 44)
                .background(selected ? tint.opacity(0.2) : .clear, in: Circle())
        }
        .buttonStyle(.plain)
        .disabled(!message.canReact)
        .accessibilityIdentifier(emoji)
        .accessibilityLabel("\(selected ? "Remove" : "Add") \(TimelineReaction.name(for: emoji)) reaction")
    }

    private var menu: some View {
        VStack(spacing: 0) {
            ForEach(context.actions) { action in
                Button { dismiss(action.perform) } label: {
                    HStack {
                        Text(action.title).font(.body).foregroundStyle(.primary)
                        Spacer(minLength: 12)
                        Image(systemName: action.symbol).font(.body).foregroundStyle(.primary)
                    }
                    .padding(.horizontal, 16).frame(minHeight: 44)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityLabel(action.title)
                if action.id != context.actions.last?.id { Divider().padding(.leading, 16) }
            }
        }
        .frame(width: 250)
        .glassEffect(.regular, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
    }

    private func react(_ emoji: String) {
        guard message.canReact, MessageContent.isEmoji(emoji) else { return }
        if !TimelineReaction.choices.contains(emoji) {
            recentReactions = ([emoji] + recents.filter { $0 != emoji }).prefix(6).joined(separator: ",")
        }
        context.react(emoji)
        dismiss(nil)
    }
}

private struct SnapshotView: UIViewRepresentable {
    let view: UIView
    func makeUIView(context: Context) -> UIView { view }
    func updateUIView(_ uiView: UIView, context: Context) {}
}

/// A hidden field that raises the emoji keyboard when the user has one, else the plain keyboard filtered to emoji.
private struct EmojiKeyboardField: UIViewRepresentable {
    let onEmoji: (String) -> Void

    func makeUIView(context: Context) -> EmojiTextField {
        let field = EmojiTextField()
        field.addTarget(context.coordinator, action: #selector(Coordinator.changed(_:)), for: .editingChanged)
        field.autocorrectionType = .no
        field.accessibilityLabel = "Emoji"
        DispatchQueue.main.async { field.becomeFirstResponder() }
        return field
    }
    func updateUIView(_ uiView: EmojiTextField, context: Context) {}
    func makeCoordinator() -> Coordinator { Coordinator(onEmoji: onEmoji) }

    final class Coordinator: NSObject {
        let onEmoji: (String) -> Void
        init(onEmoji: @escaping (String) -> Void) { self.onEmoji = onEmoji }
        @objc func changed(_ field: UITextField) {
            guard let emoji = field.text?.map(String.init).first(where: MessageContent.isEmoji) else { field.text = ""; return }
            field.text = ""
            onEmoji(emoji)
        }
    }
}

private final class EmojiTextField: UITextField {
    override var textInputContextIdentifier: String? { "" }
    override var textInputMode: UITextInputMode? {
        UITextInputMode.activeInputModes.first { $0.primaryLanguage == "emoji" } ?? super.textInputMode
    }
}
