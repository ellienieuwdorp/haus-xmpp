import AppKit
import Contacts

// The Mac has no system editor for a new contact: with access the confirmed draft is saved; without, a vCard
// of it opens in Contacts, which asks before importing it.
enum MacContacts {
    static func add(_ draft: CNMutableContact, to store: CNContactStore = CNContactStore()) -> CNContact? {
        let request = CNSaveRequest()
        request.add(draft, toContainerWithIdentifier: nil)
        do { try store.execute(request) } catch { return nil }
        return draft.copy() as? CNContact
    }

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
