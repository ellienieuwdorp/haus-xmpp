import SwiftUI
import UIKit

// Concentric with the display corners over the home indicator (44 pt controls at 28 pt), tighter above a keyboard.
enum ComposerGeometry {
    static let aboveKeyboard: CGFloat = 8
    static let corner: CGFloat = 28
    // Close to the keyboard's own spring, so glass resized by SwiftUI keeps pace with the frame UIKit moves.
    static let keyboardSpring = Animation.interpolatingSpring(mass: 3, stiffness: 1000, damping: 500, initialVelocity: 0)

    static func bottom(safeBottom: CGFloat) -> CGFloat {
        if safeBottom <= 0 { return aboveKeyboard }
        if safeBottom > 40 { return safeBottom + aboveKeyboard }
        return min(corner, safeBottom)
    }

    // `overlap`: the bottom safe area the composer still covers, eased through so a dismiss by hand never jumps.
    static func sides(left: CGFloat, right: CGFloat, overlap: CGFloat, width: CGFloat) -> (left: CGFloat, right: CGFloat) {
        let open: CGFloat = width >= 430 ? 16 : 12
        let free = max(open, min(corner, overlap))
        return (left > 0 ? left : free, right > 0 ? right : free)
    }
}

// Read by SwiftUI so the glass resizes in its own animation; a host resized in the keyboard's would jump to the end.
@MainActor @Observable final class ComposerSideMargins {
    var leading: CGFloat = 12
    var trailing: CGFloat = 12
}

private struct ComposerSides: View {
    let margins: ComposerSideMargins
    let content: AnyView

    var body: some View { content.padding(.leading, margins.leading).padding(.trailing, margins.trailing) }
}

@MainActor final class ComposerDock {
    private let margins = ComposerSideMargins()
    private var aboveCorner: NSLayoutConstraint?

    // The guide leaves out the home indicator; the host stops at the higher of the keyboard gap and the corner margin.
    func install(_ host: UIView, height: NSLayoutConstraint, in container: UIView, under scrollView: UIScrollView) {
        // Automatic is not soft on iOS 27. The effect's height comes from the glass in the host; an empty view adds none.
        scrollView.bottomEdgeEffect.style = .soft
        let interaction = UIScrollEdgeElementContainerInteraction()
        interaction.scrollView = scrollView
        interaction.edge = .bottom
        host.addInteraction(interaction)
        container.addSubview(host)
        container.keyboardLayoutGuide.usesBottomSafeArea = false
        let aboveCorner = host.bottomAnchor.constraint(lessThanOrEqualTo: container.bottomAnchor, constant: -ComposerGeometry.aboveKeyboard)
        let down = host.bottomAnchor.constraint(equalTo: container.bottomAnchor)
        down.priority = .defaultLow
        self.aboveCorner = aboveCorner
        NSLayoutConstraint.activate([
            host.leadingAnchor.constraint(equalTo: container.leadingAnchor),
            host.trailingAnchor.constraint(equalTo: container.trailingAnchor),
            host.bottomAnchor.constraint(lessThanOrEqualTo: container.keyboardLayoutGuide.topAnchor, constant: -ComposerGeometry.aboveKeyboard),
            aboveCorner, down, height,
        ])
    }

    var trailingMargin: CGFloat { margins.trailing }

    func sides(of composer: AnyView) -> some View { ComposerSides(margins: margins, content: composer) }

    func safeAreaChanged(in view: UIView) {
        aboveCorner?.constant = -ComposerGeometry.bottom(safeBottom: view.safeAreaInsets.bottom)
    }

    // From layout: inside the keyboard's animation with its spring, frame by frame during a dismiss by hand.
    func followKeyboard(in view: UIView) {
        let safe = view.safeAreaInsets
        let keyboard = max(0, view.bounds.maxY - view.keyboardLayoutGuide.layoutFrame.minY)
        let sides = ComposerGeometry.sides(left: safe.left, right: safe.right, overlap: max(0, safe.bottom - keyboard), width: view.bounds.width)
        let rightToLeft = view.effectiveUserInterfaceLayoutDirection == .rightToLeft
        let leading = rightToLeft ? sides.right : sides.left, trailing = rightToLeft ? sides.left : sides.right
        guard abs(leading - margins.leading) > 0.5 || abs(trailing - margins.trailing) > 0.5 else { return }
        let apply = { [margins] in margins.leading = leading; margins.trailing = trailing }
        if UIView.inheritedAnimationDuration > 0 { withAnimation(ComposerGeometry.keyboardSpring, apply) } else { apply() }
    }
}
