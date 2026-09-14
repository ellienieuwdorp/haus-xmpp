import SwiftUI
import UIKit

/// Keep familiar iOS search behavior, clear control, keyboard and cancellation together.
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
