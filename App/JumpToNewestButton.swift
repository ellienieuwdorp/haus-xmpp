import SwiftUI
import UIKit

// Rides the composer's top edge, so it follows the keyboard, the attachment panel and a growing draft; while search
// hides the composer it sits above the keyboard. The host is the button's own size and ignores touches while hidden,
// so it never takes one from the timeline.
@MainActor final class JumpToNewestControl {
    static let side: CGFloat = 44

    private let state = JumpToNewestState()
    private lazy var host = UIHostingController(rootView: JumpToNewestButton(state: state))
    private var aboveComposer: NSLayoutConstraint?
    private var aboveKeyboard: NSLayoutConstraint?
    private var trailing: NSLayoutConstraint?

    var isShown: Bool { state.shown }

    func install(in parent: UIViewController, container: UIView, riding composer: UIView, action: @escaping () -> Void) {
        state.action = action
        host.safeAreaRegions = []
        host.view.backgroundColor = .clear
        host.view.translatesAutoresizingMaskIntoConstraints = false
        host.view.isUserInteractionEnabled = false
        parent.addChild(host)
        container.insertSubview(host.view, belowSubview: composer)
        let above = host.view.bottomAnchor.constraint(equalTo: composer.topAnchor)
        aboveComposer = above
        aboveKeyboard = host.view.bottomAnchor.constraint(equalTo: container.keyboardLayoutGuide.topAnchor, constant: -8)
        let trailing = host.view.trailingAnchor.constraint(equalTo: composer.trailingAnchor, constant: -ComposerSideMargins().trailing)
        self.trailing = trailing
        NSLayoutConstraint.activate([
            above, trailing,
            host.view.widthAnchor.constraint(equalToConstant: Self.side),
            host.view.heightAnchor.constraint(equalToConstant: Self.side),
        ])
        host.didMove(toParent: parent)
    }

    // The composer's trailing margin, so the circle lines up with its edge. Laid out at once, so inside the keyboard's
    // animation the circle moves with it.
    func alignTrailing(_ margin: CGFloat, in container: UIView) {
        guard let trailing, abs(trailing.constant + margin) > 0.5 else { return }
        trailing.constant = -margin
        container.layoutIfNeeded()
    }

    func ridesComposer(_ rides: Bool) {
        guard aboveComposer?.isActive != rides else { return }
        aboveComposer?.isActive = rides
        aboveKeyboard?.isActive = !rides
    }

    func show(_ shown: Bool) {
        guard shown != state.shown else { return }
        state.shown = shown
        host.view.isUserInteractionEnabled = shown
    }
}

@MainActor @Observable final class JumpToNewestState {
    var shown = false
    @ObservationIgnored var action: () -> Void = {}
}

private struct JumpToNewestButton: View {
    let state: JumpToNewestState
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        ZStack {
            if state.shown {
                Button { state.action() } label: {
                    Image(systemName: "chevron.down").font(.system(size: 17, weight: .semibold))
                }
                .buttonStyle(CircularGlassButtonStyle(diameter: JumpToNewestControl.side, tinted: false))
                .accessibilityLabel("Scroll to Newest Message")
                .accessibilityIdentifier("jumpToNewest")
                .transition(reduceMotion ? .opacity : .opacity.combined(with: .scale(scale: 0.8)))
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .animation(.easeOut(duration: 0.2), value: state.shown)
    }
}
