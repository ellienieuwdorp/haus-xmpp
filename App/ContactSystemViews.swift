import Contacts
import ContactsUI
import UIKit

/// The iPhone's system Contacts screens for linking, presented by UIKit from the frontmost view controller: both refuse
/// to work as children of a SwiftUI sheet. The Mac has neither (`ChatContactRow`).
@MainActor
enum ContactSystemViews {
    /// The out-of-process picker: it needs no Contacts access and shows the whole address book; the app receives only
    /// the contact the user picks. `onPick` is not called when the user cancels.
    static func pickContact(onPick: @escaping @MainActor (CNContact) -> Void) {
        let picker = CNContactPickerViewController()
        // Only what a link reads, so the contact card never offers to open an address or number.
        picker.displayedPropertyKeys = [CNContactInstantMessageAddressesKey]
        let delegate = PickerDelegate(onPick: onPick)
        picker.delegate = delegate
        objc_setAssociatedObject(picker, &PickerDelegate.key, delegate, .OBJC_ASSOCIATION_RETAIN_NONATOMIC)
        present(picker)
    }

    /// The system's card for a contact that is not in Contacts yet, with Create New Contact and Add to Existing Contact.
    /// `onSave` receives the saved contact; it is not called when the user closes the card.
    static func addToContacts(_ draft: CNMutableContact, onSave: @escaping @MainActor (CNContact) -> Void) {
        let card = CNContactViewController(forUnknownContact: draft)
        card.contactStore = CNContactStore()
        card.allowsActions = false
        let delegate = EditorDelegate(onSave: onSave)
        card.delegate = delegate
        let navigation = UINavigationController(rootViewController: card)
        card.navigationItem.leftBarButtonItem = UIBarButtonItem(systemItem: .close, primaryAction: UIAction { [weak navigation] _ in
            navigation?.dismiss(animated: true)
        })
        delegate.navigation = navigation
        objc_setAssociatedObject(navigation, &EditorDelegate.key, delegate, .OBJC_ASSOCIATION_RETAIN_NONATOMIC)
        present(navigation)
    }

    private static func present(_ controller: UIViewController) {
        let scene = UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first { $0.activationState == .foregroundActive }
            ?? UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first
        guard var top = scene?.keyWindow?.rootViewController ?? scene?.windows.first?.rootViewController else { return }
        while let presented = top.presentedViewController, !presented.isBeingDismissed { top = presented }
        top.present(controller, animated: true)
    }

    @MainActor private final class PickerDelegate: NSObject, @preconcurrency CNContactPickerDelegate {
        nonisolated(unsafe) static var key: UInt8 = 0
        let onPick: @MainActor (CNContact) -> Void
        init(onPick: @escaping @MainActor (CNContact) -> Void) { self.onPick = onPick }
        func contactPicker(_ picker: CNContactPickerViewController, didSelect contact: CNContact) {
            onPick(contact)
        }
    }

    @MainActor private final class EditorDelegate: NSObject, @preconcurrency CNContactViewControllerDelegate {
        nonisolated(unsafe) static var key: UInt8 = 0
        let onSave: @MainActor (CNContact) -> Void
        weak var navigation: UINavigationController?
        init(onSave: @escaping @MainActor (CNContact) -> Void) { self.onSave = onSave }
        func contactViewController(_ viewController: CNContactViewController, didCompleteWith contact: CNContact?) {
            if let contact { onSave(contact) }
            // Creating a contact pushes an editor onto the card; finishing it ends the whole flow.
            navigation?.presentingViewController?.dismiss(animated: true)
        }
    }
}
