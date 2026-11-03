import SwiftUI
import UIKit

struct ConversationSearchBar: UIViewRepresentable {
    @Binding var query: String
    var onCancel: () -> Void

    func makeCoordinator() -> Coordinator { Coordinator(self) }

    func makeUIView(context: Context) -> UISearchBar {
        let bar = UISearchBar()
        bar.searchBarStyle = .minimal
        bar.placeholder = "Search messages"
        bar.showsCancelButton = true
        bar.autocapitalizationType = .none
        bar.autocorrectionType = .no
        bar.searchTextField.accessibilityIdentifier = "messageSearch"
        bar.delegate = context.coordinator
        return bar
    }

    func updateUIView(_ bar: UISearchBar, context: Context) {
        context.coordinator.parent = self
        if bar.text != query { bar.text = query }
        if !context.coordinator.focused {
            context.coordinator.focused = true
            DispatchQueue.main.async { [weak bar] in bar?.becomeFirstResponder() }
        }
    }

    // UISearchBar's fitting height grows with Dynamic Type and carries 10 pt above and below the field; the glass
    // group pads itself, so trim that to 4 pt each side.
    func sizeThatFits(_ proposal: ProposedViewSize, uiView bar: UISearchBar, context: Context) -> CGSize? {
        guard let width = proposal.width, width.isFinite else { return nil }
        let fitted = bar.systemLayoutSizeFitting(CGSize(width: width, height: UIView.layoutFittingCompressedSize.height),
                                                 withHorizontalFittingPriority: .required, verticalFittingPriority: .fittingSizeLevel)
        return CGSize(width: width, height: max(Self.minimumHeight, ceil(fitted.height) - Self.trimmedMargin))
    }

    static let trimmedMargin: CGFloat = 12
    static let minimumHeight: CGFloat = 52

    @MainActor final class Coordinator: NSObject, UISearchBarDelegate {
        var parent: ConversationSearchBar
        var focused = false
        init(_ parent: ConversationSearchBar) { self.parent = parent }
        func searchBar(_ searchBar: UISearchBar, textDidChange searchText: String) { parent.query = searchText }
        func searchBarCancelButtonClicked(_ searchBar: UISearchBar) {
            searchBar.resignFirstResponder()
            parent.onCancel()
        }
        func searchBarSearchButtonClicked(_ searchBar: UISearchBar) { searchBar.resignFirstResponder() }
    }
}
