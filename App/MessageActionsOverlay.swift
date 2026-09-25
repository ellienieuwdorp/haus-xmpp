import OSLog
import SwiftUI
import UIKit
import XMPPProtocol

/// One list of what a message can do. The long-press overlay and VoiceOver custom actions both read it.
struct MessageAction: Identifiable {
    enum Kind: String { case reply, copy, selectText, star, retry, edit, unsend }
    let kind: Kind
    let title: String
    let symbol: String
    let perform: () -> Void
    var id: Kind { kind }
}

/// What the overlay needs from the pressed bubble. Frames are window coordinates and ignore the press squeeze.
struct MessageActionsContext {
    let message: TimelineMessage
    let bubble: UIView
    let bubbleFrame: CGRect
    /// The bubble's outline in its own bounds: the lifted shadow follows a fixed path instead of an offscreen pass.
    let bubbleShape: CGPath
    /// How far the press squeeze had shrunk the live bubble, about its centre, when the overlay took its place.
    var sourceScale: CGFloat
    let reactions: UIView?
    let reactionsFrame: CGRect
    let actions: [MessageAction]
    let react: (String) -> Void
    /// Hides the live bubble while its snapshot is on screen, so a moved snapshot never shows a twin.
    let setSourceHidden: (Bool) -> Void
    /// Where the live bubble is when the menu closes (the keyboard may have moved it); nil once its cell shows another message.
    let currentBubbleFrame: () -> CGRect?
}

/// A live blur, the bubble at its real size, quick reactions above it and the action list below.
/// Replaces UIContextMenuInteraction, which cannot host a tappable accessory above its preview.
/// The overlay's view is attached straight to the window rather than presented: a presentation resigns the composer
/// on the spot, which snaps the keyboard away without animation and moves the whole timeline in one frame, and it
/// defers the overlay's first render by a runloop turn. The view animates itself so the bubble starts where the
/// squeezed live one is and ends wherever the live one is by then.
@MainActor
enum MessageActionsOverlay {
    /// Instruments intervals for the press path (os_signpost, category MessageMenu). Nothing on it renders offscreen.
    static let signposter = OSSignposter(subsystem: "haus.xmpp.ios", category: "MessageMenu")
    /// The open overlay; a window keeps only its view.
    private static var current: UIViewController?
    /// Built hidden while the press squeeze runs, so the squeeze's end only has to unhide it.
    private static var prepared: (messageID: String, controller: UIHostingController<MessageActionsOverlayView>)?

    /// Builds the overlay for a press that may become a menu, hidden and laid out in `window`, so opening it later
    /// costs no hosting-controller setup or first SwiftUI pass. Does nothing while a menu is open.
    static func prepare(in window: UIWindow, context: MessageActionsContext) {
        guard current == nil else { return }
        let preparing = signposter.beginInterval("prepare")
        defer { signposter.endInterval("prepare", preparing) }
        discardPrepared()
        let controller = makeController(in: window, context: context)
        controller.view.isHidden = true
        window.addSubview(controller.view)
        controller.view.layoutIfNeeded()
        prepared = (context.message.id, controller)
    }

    /// Drops a prepared overlay whose press ended without a menu.
    static func discardPrepared() {
        prepared?.controller.view.removeFromSuperview()
        prepared = nil
    }

    /// `willDismiss` runs when the overlay starts to close, with the chosen action's kind, and returns true when the
    /// timeline is about to put the live bubble back where it was at the press (the keyboard is coming back); the
    /// snapshot then springs to that frame instead of the one the live bubble has at that moment.
    /// `onDismiss` runs once the overlay is gone and before the chosen action runs; it receives that action's kind.
    /// Returns false, having touched nothing, when the presenter has no window or a menu is already open.
    @discardableResult
    static func present(from presenter: UIViewController, context: MessageActionsContext,
                        willDismiss: @escaping (MessageAction.Kind?) -> Bool = { _ in false },
                        onDismiss: @escaping (MessageAction.Kind?) -> Void = { _ in }) -> Bool {
        guard current == nil, let window = presenter.view.window else { discardPrepared(); return false }
        let presenting = signposter.beginInterval("present")
        defer { signposter.endInterval("present", presenting) }
        let controller: UIHostingController<MessageActionsOverlayView>
        if let prepared, prepared.messageID == context.message.id, prepared.controller.view.window === window {
            controller = prepared.controller
        } else {
            discardPrepared()
            controller = makeController(in: window, context: context)
            window.addSubview(controller.view)
        }
        prepared = nil
        // The snapshot takes the live bubble's place in the same frame, so the blur never holds a twin of it.
        context.setSourceHidden(true)
        var view = controller.rootView
        view.context = context
        view.willDismiss = willDismiss
        view.finish = { [weak controller] action in
            controller?.view.removeFromSuperview()
            current = nil
            UIAccessibility.post(notification: .screenChanged, argument: nil)
            onDismiss(action?.kind)
            action?.perform()
        }
        view.armed = true
        controller.rootView = view
        controller.view.isHidden = false
        current = controller
        // Commit the armed pass (and with it the entrance spring) now, before the timeline puts the keyboard away:
        // left to the next pass it would run inside the keyboard's animation block and every snapshot would fly in
        // from its initial frame. (Not performWithoutAnimation: the blur's own fade starts in this pass.)
        controller.view.layoutIfNeeded()
        UIAccessibility.post(notification: .screenChanged, argument: controller.view)
        return true
    }

    private static func makeController(in window: UIWindow, context: MessageActionsContext) -> UIHostingController<MessageActionsOverlayView> {
        let view = MessageActionsOverlayView(context: context, safeArea: window.safeAreaInsets, windowSize: window.bounds.size)
        let controller = UIHostingController(rootView: view)
        controller.view.backgroundColor = .clear
        controller.view.frame = window.bounds
        controller.view.autoresizingMask = [.flexibleWidth, .flexibleHeight]
        controller.view.accessibilityViewIsModal = true
        return controller
    }
}

struct MessageActionsOverlayView: View {
    var context: MessageActionsContext
    let safeArea: UIEdgeInsets
    let windowSize: CGSize
    /// False while the overlay is built hidden during the press squeeze; turning true starts the entrance.
    var armed = false
    var willDismiss: (MessageAction.Kind?) -> Bool = { _ in false }
    var finish: (MessageAction?) -> Void = { _ in }

    private enum Stage: Equatable {
        /// Over the live bubble as the press left it: squeezed, and wherever the keyboard had it.
        case source
        /// Clamped between the pill and the menu.
        case open
        /// Back over the live bubble, which has moved by this much since the press; nil fades out in place.
        case closing(CGSize?)
    }
    @State private var stage = Stage.source
    /// Blur, scrim and pill are in (each animates its own ramp).
    @State private var shown = false
    /// The bubble's pop on arrival: up a few percent on a quick spring, then back to rest on a softer one.
    @State private var lifted = false
    /// Set as the close begins, before the keyboard can come back, so the layout stops following it.
    @State private var dismissing = false
    /// The quick reactions have slid up; never reset, so they stay put while the pill fades out.
    @State private var pillIn = false
    /// 0.1 s when the bubble has to travel, so the pill arrives after it starts moving.
    @State private var pillDelay: Double = 0
    @State private var choosingEmoji = false
    @State private var keyboardHeight: CGFloat = 0
    @AppStorage("recentReactions") private var recentReactions = ""
    private var accent: String { AccentTheme.current.rawValue }
    @Environment(\.colorScheme) private var colorScheme

    private static let gap: CGFloat = 14
    private static let pillHeight: CGFloat = 52
    /// The entrance spring for the bubble, the menu riding under it and the pill riding over it: Signal's 0.4 s preview
    /// spring, a touch less damped (0.75, about 3 % overshoot) and leaving with a normalised velocity of one travel per
    /// second, so the first frame after the squeeze already moves instead of easing out of rest.
    private static let enter = Animation.interpolatingSpring(Spring(duration: 0.4, bounce: 0.25), initialVelocity: 1)
    /// The arrival pop on top of the move: 1.03 on a quick lively spring, then down to 1 on a softer one.
    private static let liftScale: CGFloat = 1.03
    private static let liftUp = Animation.spring(duration: 0.18, bounce: 0.35)
    private static let liftDown = Animation.spring(duration: 0.32, bounce: 0.3)
    /// No overshoot on the way back: the snapshot must land exactly on the live bubble before it reappears.
    private static let leave = Animation.interpolatingSpring(Spring(duration: 0.3, bounce: 0), initialVelocity: 1)
    /// Menu opacity on its own short curve: 0.3 in the first frame, so it is visible while it grows with the bubble.
    private static let menuFade = Animation.easeOut(duration: 0.25)
    private static let menuStartScale: CGFloat = 0.2
    private static let menuStartOpacity: Double = 0.3
    private var reduceMotion: Bool { UIAccessibility.isReduceMotionEnabled }
    private var message: TimelineMessage { context.message }
    private var tint: Color { Color(uiColor: (AccentTheme(rawValue: accent) ?? .indigo).tint) }
    private var recents: [String] { recentReactions.split(separator: ",").map(String.init).filter { !$0.isEmpty } }
    private var closing: Bool { if case .closing = stage { true } else { false } }

    private struct Layout {
        /// The bubble and its reaction pills where the press found them.
        let block: CGRect
        let fitScale: CGFloat
        let groupTop: CGFloat
        let bubbleTop: CGFloat
        let menuTop: CGFloat
        var shifts: Bool { abs(bubbleTop - block.minY) > 1 || fitScale < 1 }
    }

    private func layout(in size: CGSize) -> Layout {
        let rowHeight = max(44, ceil(UIFont.preferredFont(forTextStyle: .body).lineHeight) + 22)
        let menuHeight = CGFloat(context.actions.count) * rowHeight
        let reasonHeight: CGFloat = message.reactionUnavailableReason == nil ? 0 : 22
        let recentsHeight: CGFloat = choosingEmoji && !recents.isEmpty ? 44 : 0
        let block = context.reactions == nil ? context.bubbleFrame : context.bubbleFrame.union(context.reactionsFrame)
        let top = safeArea.top + 8
        let bottom = size.height - max(safeArea.bottom, keyboardHeight) - 8
        let fitScale = min(1, max(0.3, (bottom - top - Self.pillHeight - reasonHeight - recentsHeight - menuHeight - 2 * Self.gap) / block.height))
        let groupHeight = Self.pillHeight + reasonHeight + recentsHeight + Self.gap + block.height * fitScale + Self.gap + (choosingEmoji ? 0 : menuHeight)
        let groupTop = min(max(top, block.minY - Self.pillHeight - reasonHeight - Self.gap), max(top, bottom - groupHeight))
        let bubbleTop = groupTop + Self.pillHeight + reasonHeight + recentsHeight + Self.gap
        return Layout(block: block, fitScale: fitScale, groupTop: groupTop, bubbleTop: bubbleTop, menuTop: bubbleTop + block.height * fitScale + Self.gap)
    }

    var body: some View {
        GeometryReader { geo in
            let layout = layout(in: geo.size)
            let alignment: Alignment = message.isOutgoing ? .trailing : .leading
            let menuAnchor: UnitPoint = message.isOutgoing ? .topTrailing : .topLeading

            ZStack(alignment: .topLeading) {
                LiveBlur(active: shown)
                    .frame(width: geo.size.width, height: geo.size.height)
                    .allowsHitTesting(false)
                Color.clear
                    .frame(width: geo.size.width, height: geo.size.height)
                    .contentShape(Rectangle())
                    .onTapGesture { dismiss(nil) }
                    .accessibilityAddTraits(.isButton).accessibilityLabel("Dismiss")
                // Pill and menu ride the bubble's spring from where it was pressed to where it opens; the pill's emoji
                // slide up into it and the menu grows from the bubble's corner. Opacity alone keeps its own short curve.
                VStack(alignment: message.isOutgoing ? .trailing : .leading, spacing: 6) {
                    reactionPill
                    if let reason = message.reactionUnavailableReason {
                        Text(reason).font(.caption).foregroundStyle(.secondary).lineLimit(1)
                            .padding(.horizontal, 12).accessibilityIdentifier("reactionUnavailableReason")
                    }
                    if choosingEmoji, !recents.isEmpty { recentsRow }
                }
                .opacity(shown ? 1 : 0)
                .animation(shown ? .easeOut(duration: 0.15).delay(pillDelay) : .easeOut(duration: 0.25), value: shown)
                .frame(width: geo.size.width - 32, alignment: alignment)
                .offset(x: 16, y: layout.groupTop + ride(layout))
                snapshot(context.bubble, frame: context.bubbleFrame, layout: layout, shadow: context.bubbleShape)
                if let reactions = context.reactions {
                    snapshot(reactions, frame: context.reactionsFrame, layout: layout, shadow: nil)
                }
                if !choosingEmoji {
                    // `.animation(_:value:)` sits right after the opacity, so it times the opacity alone; the scale and the
                    // offset outside it take the entrance spring from the transaction that changes the stage.
                    menu
                        .opacity(stage == .open ? 1 : closing ? 0 : Self.menuStartOpacity)
                        .animation(Self.menuFade, value: stage)
                        .scaleEffect(stage == .open ? 1 : Self.menuStartScale, anchor: menuAnchor)
                        .frame(width: geo.size.width - 32, alignment: alignment)
                        .offset(x: 16, y: menuTop(layout))
                        .transition(.scale(scale: 0.9, anchor: menuAnchor).combined(with: .opacity))
                }
            }
            .animation(reduceMotion ? nil : Self.enter, value: choosingEmoji)
            .gesture(DragGesture(minimumDistance: 30).onEnded { _ in dismiss(nil) })
        }
        .ignoresSafeArea()
        // Built hidden during the squeeze, the overlay starts only when the press is confirmed.
        .onAppear { if armed { enter() } }
        .onChange(of: armed) { if armed { enter() } }
        // The bubble is a picture taken at the press; in a new appearance it would stay in the old one.
        .onChange(of: colorScheme) { dismiss(nil) }
        .onReceive(NotificationCenter.default.publisher(for: UIResponder.keyboardWillChangeFrameNotification)) { note in
            guard let frame = (note.userInfo?[UIResponder.keyboardFrameEndUserInfoKey] as? NSValue)?.cgRectValue,
                  !dismissing, let screen = (note.object as? UIScreen) ?? UIScreen.main as UIScreen? else { return }
            keyboardHeight = max(0, screen.bounds.height - frame.minY)
        }
    }

    /// How far the pill and the menu sit from their open places in this stage: they travel with the bubble.
    private func ride(_ layout: Layout) -> CGFloat {
        switch stage {
        case .source: layout.block.minY - layout.bubbleTop
        case .open, .closing(.none): 0
        case .closing(.some(let moved)): layout.block.minY + moved.height - layout.bubbleTop
        }
    }

    /// The menu hangs under the bubble's block: at the press, open, and back over the live bubble.
    private func menuTop(_ layout: Layout) -> CGFloat {
        switch stage {
        case .source: layout.block.maxY + Self.gap
        case .open, .closing(.none): layout.menuTop
        case .closing(.some(let moved)): layout.block.maxY + moved.height + Self.gap
        }
    }

    /// The first frame shows the snapshot exactly over the squeezed live bubble with the menu at a fifth of its size
    /// under it; from there one spring carries the bubble to its clamped place and the pill and menu with it, while
    /// the blur fades in and the bubble pops once on arrival. No timers: each part runs its own curve.
    private func enter() {
        guard stage == .source, !shown else { return }
        pillIn = true
        if reduceMotion { stage = .open; shown = true; return }
        pillDelay = layout(in: windowSize).shifts ? 0.1 : 0
        withAnimation(Self.enter) { stage = .open }
        shown = true
        withAnimation(Self.liftUp) { lifted = true } completion: {
            guard !dismissing else { return }
            withAnimation(Self.liftDown) { lifted = false }
        }
    }

    /// Springs the snapshot back onto the live bubble, wherever it is now (or where the returning keyboard is about to
    /// put it), then shows the live bubble and removes the overlay.
    private func dismiss(_ action: MessageAction?) {
        // A prepared overlay that was never armed is still hidden: nothing to close.
        guard armed, !dismissing else { return }
        dismissing = true
        let bounds = CGRect(origin: .zero, size: windowSize)
        let returnsToPress = willDismiss(action?.kind)
        let moved = returnsToPress ? CGSize.zero : context.currentBubbleFrame().flatMap { live -> CGSize? in
            guard live.intersects(bounds) else { return nil }
            return CGSize(width: live.minX - context.bubbleFrame.minX, height: live.minY - context.bubbleFrame.minY)
        }
        shown = false
        if lifted { withAnimation(Self.leave) { lifted = false } }
        let done = {
            context.setSourceHidden(false)
            finish(action)
        }
        if reduceMotion {
            stage = .closing(moved)
            done()
            return
        }
        withAnimation(Self.leave, completionCriteria: .logicallyComplete) { stage = .closing(moved) } completion: { done() }
    }

    /// The snapshot at the stage's place. The squeeze scales about the bubble's centre (the reaction pills with it);
    /// a fit scale (bubble taller than the screen) keeps the outer top corner fixed so the group stays against its side.
    private func snapshot(_ view: UIView, frame: CGRect, layout: Layout, shadow: CGPath?) -> some View {
        let outerTop: UnitPoint = message.isOutgoing ? .topTrailing : .topLeading
        let centre = UnitPoint(x: (context.bubbleFrame.midX - frame.minX) / max(1, frame.width),
                               y: (context.bubbleFrame.midY - frame.minY) / max(1, frame.height))
        let squeeze = stage == .source ? context.sourceScale : 1
        let fit: CGFloat
        let origin: CGPoint
        switch stage {
        case .source:
            fit = 1
            origin = frame.origin
        case .open, .closing(.none):
            fit = layout.fitScale
            origin = CGPoint(x: frame.minX, y: layout.bubbleTop + (frame.minY - layout.block.minY) * layout.fitScale)
        case .closing(.some(let moved)):
            fit = 1
            origin = CGPoint(x: frame.minX + moved.width, y: frame.minY + moved.height)
        }
        return SnapshotHost(view: view, shadowPath: shadow, lifted: stage == .open)
            .frame(width: frame.width, height: frame.height)
            .scaleEffect(squeeze, anchor: centre)
            // Its own modifier: the pop runs on its own springs on top of the move, neither retargets the other.
            .scaleEffect(lifted ? Self.liftScale : 1, anchor: centre)
            .scaleEffect(fit, anchor: outerTop)
            .offset(x: origin.x, y: origin.y)
            .opacity(stage == .closing(nil) ? 0 : 1)
    }

    private var reactionPill: some View {
        let selected = Set(message.reactions.filter(\.isSelected).map(\.emoji))
        return HStack(spacing: 2) {
            ForEach(Array(TimelineReaction.choices.enumerated()), id: \.element) { index, emoji in
                reactionButton(emoji, selected: selected.contains(emoji))
                    .modifier(SlideIn(index: index, delay: pillDelay, active: pillIn))
            }
            Button { choosingEmoji.toggle() } label: {
                Image(systemName: "plus").font(.system(size: 15, weight: .semibold)).foregroundStyle(.secondary)
                    .frame(width: 36, height: 36).background(Color.primary.opacity(0.08), in: Circle())
            }
            .buttonStyle(.plain).frame(width: 44, height: 44)
            .disabled(!message.canReact)
            .accessibilityLabel("More reactions").accessibilityIdentifier("moreReactions")
            .modifier(SlideIn(index: TimelineReaction.choices.count, delay: pillDelay, active: pillIn))
        }
        .padding(.horizontal, 6)
        .frame(height: Self.pillHeight)
        .clipShape(Capsule())
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
                Button { dismiss(action) } label: {
                    HStack {
                        Text(action.title).font(.body).foregroundStyle(action.kind == .unsend ? AnyShapeStyle(.red) : AnyShapeStyle(.primary))
                        Spacer(minLength: 12)
                        Image(systemName: action.symbol).font(.body).foregroundStyle(action.kind == .unsend ? AnyShapeStyle(.red) : AnyShapeStyle(.primary))
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

/// Signal's reaction bar entrance: each emoji rises 24 pt into the pill, 10 ms after its neighbour, over 0.2 s ease-in.
private struct SlideIn: ViewModifier {
    let index: Int
    let delay: Double
    let active: Bool
    func body(content: Content) -> some View {
        content
            .offset(y: active ? 0 : 24)
            .opacity(active ? 1 : 0)
            .animation(UIAccessibility.isReduceMotionEnabled ? nil : .easeIn(duration: 0.2).delay(delay + Double(index) * 0.01), value: active)
    }
}

/// A live blur: its effect animates (never its alpha, which UIKit forbids for effect views), so the timeline and the
/// navigation bar stay live and recognisable under it and nothing is rasterised on the press path. The 20 % scrim is a
/// sibling view whose alpha rides the same curve: a background colour on the effect view's content view is not animated
/// when the effect changes in the same block, so it appeared at full strength in the overlay's first frame.
private struct LiveBlur: UIViewRepresentable {
    let active: Bool

    func makeUIView(context: Context) -> BlurScrimView { BlurScrimView() }

    func updateUIView(_ view: BlurScrimView, context: Context) { view.setActive(active) }
}

private final class BlurScrimView: UIView {
    private static let scrimColor = UIColor { $0.userInterfaceStyle == .dark ? UIColor(white: 1, alpha: 0.2) : UIColor(white: 0, alpha: 0.2) }
    private let blur = UIVisualEffectView(effect: nil)
    private let scrim = UIView()
    private var active = false

    init() {
        super.init(frame: .zero)
        isUserInteractionEnabled = false
        for view in [blur, scrim] as [UIView] {
            view.frame = bounds
            view.autoresizingMask = [.flexibleWidth, .flexibleHeight]
            view.isUserInteractionEnabled = false
            addSubview(view)
        }
        scrim.backgroundColor = Self.scrimColor
        scrim.alpha = 0
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    /// Blur and scrim fade in together over 0.2 s and out over 0.3 s (the length of the return spring), each from
    /// wherever it is now.
    func setActive(_ active: Bool) {
        guard active != self.active else { return }
        self.active = active
        UIView.animate(withDuration: active ? 0.2 : 0.3, delay: 0, options: [.curveEaseOut, .beginFromCurrentState]) {
            self.blur.effect = active ? UIBlurEffect(style: .regular) : nil
            self.scrim.alpha = active ? 1 : 0
        }
    }
}

/// Hosts a snapshot view; the bubble's lift shadow is a layer shadow on a fixed path, faded with Core Animation, so
/// the spring moves a cached layer instead of re-rendering a SwiftUI shadow every frame.
private struct SnapshotHost: UIViewRepresentable {
    let view: UIView
    let shadowPath: CGPath?
    let lifted: Bool

    func makeUIView(context: Context) -> UIView {
        let host = UIView(frame: view.bounds)
        view.frame = host.bounds
        view.autoresizingMask = [.flexibleWidth, .flexibleHeight]
        host.addSubview(view)
        if let shadowPath {
            host.layer.shadowPath = shadowPath
            host.layer.shadowColor = UIColor.black.cgColor
            host.layer.shadowRadius = 14
            host.layer.shadowOffset = CGSize(width: 0, height: 12)
            host.layer.shadowOpacity = 0
        }
        return host
    }

    func updateUIView(_ host: UIView, context: Context) {
        guard shadowPath != nil else { return }
        let target: Float = lifted ? 0.18 : 0
        guard host.layer.shadowOpacity != target else { return }
        let fade = CABasicAnimation(keyPath: "shadowOpacity")
        fade.fromValue = host.layer.presentation()?.shadowOpacity ?? host.layer.shadowOpacity
        fade.toValue = target
        fade.duration = 0.4
        fade.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
        host.layer.shadowOpacity = target
        host.layer.add(fade, forKey: "shadowOpacity")
    }
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
