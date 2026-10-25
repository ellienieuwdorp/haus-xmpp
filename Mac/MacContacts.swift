import AppKit
import Contacts

/// "Add to Contacts" on the Mac, which has no system editor for a new or unknown contact: with access, the draft is
/// saved after the user confirmed exactly what it holds; without, a vCard of it opens in Contacts, which asks before
/// importing it.
enum MacContacts {
    /// Saves the draft as a new contact and returns it as saved (with its identifier), or nil on failure.
    static func add(_ draft: CNMutableContact, to store: CNContactStore = CNContactStore()) -> CNContact? {
        let request = CNSaveRequest()
        request.add(draft, toContainerWithIdentifier: nil)
        do { try store.execute(request) } catch { return nil }
        return draft.copy() as? CNContact
    }

    /// Writes the draft as a vCard in a temporary folder and opens it in Contacts.
    static func open(_ draft: CNMutableContact, named name: String) -> Bool {
        guard let data = try? CNContactVCardSerialization.data(with: [draft]) else { return false }
        let folder = FileManager.default.temporaryDirectory.appending(path: "contact-cards", directoryHint: .isDirectory)
        let safe = name.components(separatedBy: CharacterSet(charactersIn: "/:\\")).joined(separator: "-")
        let file = folder.appending(path: (safe.isEmpty ? "Contact" : safe) + ".vcf")
        do {
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            try data.write(to: file, options: .atomic)
        } catch { return false }
        guard let contacts = NSWorkspace.shared.urlForApplication(withBundleIdentifier: "com.apple.AddressBook") else { return NSWorkspace.shared.open(file) }
        NSWorkspace.shared.open([file], withApplicationAt: contacts, configuration: NSWorkspace.OpenConfiguration())
        return true
    }
}
