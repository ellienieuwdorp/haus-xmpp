import Contacts
import MessageStore
import SwiftUI
#if os(iOS)
import ContactsUI
#endif

/// What a chat's Contact row is asked to start from elsewhere: the Mac's chat menus.
struct ContactRowRequest: Equatable {
    enum Kind { case link, add, unlink }
    let chatID: String
    let kind: Kind
}

/// A direct chat's Contact row in its details (the iPhone's screen, the Mac's inspector): link the chat to a contact on
/// this device, add it to Contacts, or unlink it. Contacts access is asked for only here, when the user starts linking
/// or adding. What each choice means is said in its confirmation, not in a footer.
struct ChatContactRow: View {
    @Bindable var model: AppModel
    let chatID: String
    @State private var prompt: Prompt?
    @State private var choosing = false
    @Environment(\.openURL) private var openURL
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize

    private enum Prompt: Equatable {
        /// The one contact whose Jabber address is this chat's.
        case suggestion(ContactCard)
        /// No Contacts access: link by name only, or allow access.
        case withoutAccess
        case unlink
        /// The Mac with access: what "Add to Contacts" will write.
        case add
        /// The Mac without access: open a contact card in Contacts instead.
        case openCard
    }

    private var center: ContactLinkCenter { model.contactLinks }
    private var chatName: String { model.chatName(for: chatID) }

    var body: some View {
        let link = center.links[chatID], status = center.status(for: chatID)
        Menu {
            if let link {
                if status == .missing {
                    Text(center.access == .limited ? "Contact not shared with Haus" : "Contact not found")
                }
                if link.imageHash != nil, model.avatars[chatID] != nil {
                    Toggle("Use Contact Photo", systemImage: "person.crop.circle", isOn: Binding(
                        get: { link.usesContactPhoto },
                        set: { uses in Task { await center.setUsesContactPhoto(uses, for: chatID) } }))
                }
                Button(status == .missing ? "Link Again…" : "Link to Another Contact…", systemImage: "person.crop.circle.badge.plus") {
                    Task { await startLinking() }
                }
                Button("Unlink Contact", systemImage: "person.crop.circle.badge.minus", role: .destructive) { prompt = .unlink }
            } else {
                Button("Link to Contact…", systemImage: "person.crop.circle.badge.plus") { Task { await startLinking() } }
                Button("Add to Contacts…", systemImage: "person.badge.plus") { Task { await startAdding() } }
            }
        } label: {
            let large = dynamicTypeSize.isAccessibilitySize
            HStack {
                Label {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Contact").foregroundStyle(.primary)
                        if large { value(link: link, status: status) }
                    }
                } icon: {
                    DetailsIconTile(systemName: "person.crop.circle")
                }
                Spacer(minLength: 8)
                if !large { value(link: link, status: status).lineLimit(1) }
                Image(systemName: "chevron.up.chevron.down").imageScale(.small).foregroundStyle(.tertiary).accessibilityHidden(true)
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel("Contact")
        .accessibilityValue(accessibilityValue(link: link, status: status))
        .accessibilityIdentifier("chatContact")
        .confirmationDialog(promptTitle, isPresented: Binding(get: { prompt != nil }, set: { if !$0 { prompt = nil } }),
                            titleVisibility: .visible, presenting: prompt) { prompt in
            promptActions(prompt)
        } message: { prompt in
            Text(promptMessage(prompt))
        }
        .sheet(isPresented: $choosing) {
            ContactLinkPicker(center: center, chatName: chatName) { card in
                Task { await center.link(chatID, to: card, source: .picker) }
            }
        }
        .task(id: center.request) {
            guard let request = center.request, request.chatID == chatID else { return }
            center.request = nil
            switch request.kind {
            case .link: await startLinking()
            case .add: await startAdding()
            case .unlink: if center.links[chatID] != nil { prompt = .unlink }
            }
        }
    }

    @ViewBuilder private func value(link: ContactLink?, status: ContactLinkCenter.Status?) -> some View {
        if status == .missing {
            Text("Not found").foregroundStyle(.orange)
        } else {
            Text(link?.name ?? (link == nil ? "Not linked" : "Linked")).foregroundStyle(.secondary)
        }
    }

    private func accessibilityValue(link: ContactLink?, status: ContactLinkCenter.Status?) -> String {
        guard let link else { return "Not linked" }
        let name = link.name ?? "Linked"
        return status == .missing ? "\(name), contact not found" : name
    }

    // MARK: Flows

    private func startLinking() async {
        if center.access == .notDetermined { _ = await center.requestAccess() }
        guard center.access.readsContacts else { prompt = .withoutAccess; return }
        if let suggestion = await center.suggestion(for: chatID) { prompt = .suggestion(suggestion) } else { choosing = true }
    }

    private func startAdding() async {
        if center.access == .notDetermined { _ = await center.requestAccess() }
        let draft = ContactDraft.contact(name: chatName, jid: chatID, photo: model.verifiedAvatarData(for: chatID))
        #if os(iOS)
        ContactSystemViews.addToContacts(draft) { contact in
            Task { await center.link(chatID, to: ContactCard(contact), source: .created) }
        }
        #else
        prompt = center.access == .full ? .add : .openCard
        #endif
    }

    // MARK: Confirmations

    private var promptTitle: String {
        switch prompt {
        case .suggestion(let card): "Link to \(card.name.isEmpty ? "This Contact" : card.name)?"
        case .withoutAccess:
            #if os(iOS)
            "Link Without Contacts Access?"
            #else
            "Allow Haus to Use Contacts?"
            #endif
        case .unlink: "Unlink \(chatName)?"
        case .add: "Add \(chatName) to Contacts?"
        case .openCard: "Open a Contact Card?"
        case nil: ""
        }
    }

    private func promptMessage(_ prompt: Prompt) -> String {
        switch prompt {
        case .suggestion(let card):
            "\(card.name.isEmpty ? "This contact" : card.name) has \(chatID) as a Jabber address in Contacts. The chat will show the contact's name. Links stay on this \(ThisDevice.noun)."
        case .withoutAccess:
            #if os(iOS)
            "Haus will show the contact's name in this chat and its notifications. iOS won't connect the chat to the contact unless you allow Haus to use Contacts in Settings."
            #else
            "To link this chat to a contact, allow Haus to use Contacts in System Settings > Privacy & Security > Contacts."
            #endif
        case .unlink:
            "The chat goes back to showing its own name, and suggestions for it are cleared. Nothing changes in Contacts."
        case .add:
            "Haus will create a contact named “\(chatName)” with the Jabber address \(chatID) and the link xmpp:\(chatID)."
        case .openCard:
            "Haus can't use Contacts. It can open a card for \(chatID) in the Contacts app, which asks before adding it."
        }
    }

    @ViewBuilder private func promptActions(_ prompt: Prompt) -> some View {
        switch prompt {
        case .suggestion(let card):
            Button("Link") { Task { await center.link(chatID, to: card, source: .imAddress) } }
            Button("Choose Another Contact…") { choosing = true }
            Button("Cancel", role: .cancel) {}
        case .withoutAccess:
            #if os(iOS)
            Button("Choose Contact…") {
                ContactSystemViews.pickContact { contact in Task { await center.link(chatID, to: ContactCard(contact), source: .picker) } }
            }
            #endif
            #if os(iOS)
            Button("Open Settings") { if let url = PlatformApplication.contactsSettingsURL { openURL(url) } }
            #else
            Button("Open System Settings") { if let url = PlatformApplication.contactsSettingsURL { openURL(url) } }
            #endif
            Button("Cancel", role: .cancel) {}
        case .unlink:
            Button("Unlink", role: .destructive) { Task { await center.unlink(chatID) } }
            Button("Cancel", role: .cancel) {}
        case .add:
            #if os(macOS)
            Button("Add to Contacts") {
                let draft = ContactDraft.contact(name: chatName, jid: chatID, photo: model.verifiedAvatarData(for: chatID))
                guard let saved = MacContacts.add(draft) else { model.error = "Couldn’t add \(chatName) to Contacts."; return }
                Task { await center.link(chatID, to: ContactCard(saved), source: .created) }
            }
            #endif
            Button("Cancel", role: .cancel) {}
        case .openCard:
            #if os(macOS)
            Button("Open in Contacts") {
                let draft = ContactDraft.contact(name: chatName, jid: chatID, photo: model.verifiedAvatarData(for: chatID))
                if !MacContacts.open(draft, named: chatName) { model.error = "Couldn’t open a contact card for \(chatName)." }
            }
            Button("Open System Settings") { if let url = PlatformApplication.contactsSettingsURL { openURL(url) } }
            #endif
            Button("Cancel", role: .cancel) {}
        }
    }
}

/// The contacts this app can read, to link a chat to one. With limited access (iOS) it also offers the system's search
/// of contacts not yet shared with Haus (`ContactAccessButton`) and a way to share more; a contact shared from either
/// is linked straight away, as that is the one the user tapped.
struct ContactLinkPicker: View {
    let center: ContactLinkCenter
    let chatName: String
    let onChoose: (ContactCard) -> Void
    @Environment(\.dismiss) private var dismiss
    @State private var cards: [ContactCard]?
    @State private var query = ""
    @State private var sharingMore = false

    private var shown: [ContactCard] {
        let all = cards ?? []
        let query = query.trimmingCharacters(in: .whitespaces)
        guard !query.isEmpty else { return all }
        return all.filter { $0.name.localizedStandardContains(query) || $0.jabberAddresses.contains { $0.localizedStandardContains(query) } }
    }

    var body: some View {
        NavigationStack {
            List {
                #if os(iOS)
                if center.access == .limited {
                    Section {
                        ContactAccessButton(queryString: query.isEmpty ? chatName : query) { identifiers in
                            Task { await choose(sharedIdentifiers: identifiers) }
                        }
                    }
                }
                #endif
                Section {
                    ForEach(shown) { card in
                        Button { choose(card) } label: {
                            HStack(spacing: 12) {
                                ChatAvatar(key: card.id, name: card.name.isEmpty ? "?" : card.name, size: 36).accessibilityHidden(true)
                                Text(card.name.isEmpty ? "No Name" : card.name).foregroundStyle(.primary).lineLimit(1)
                                Spacer(minLength: 0)
                            }
                            .frame(minHeight: 44)
                            .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                        .accessibilityIdentifier("contactCandidate")
                    }
                }
            }
            .overlay {
                if cards != nil, shown.isEmpty, query.isEmpty {
                    ContentUnavailableView(center.access == .limited ? "No Contacts Shared" : "No Contacts", systemImage: "person.crop.circle",
                                           description: Text(center.access == .limited ? "Search to find a contact and share it with Haus." : ""))
                }
            }
            .searchable(text: $query, prompt: "Search")
            .navigationTitle("Link to Contact")
            .inlineNavigationTitle()
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
                #if os(iOS)
                if center.access == .limited {
                    ToolbarItem(placement: .primaryAction) {
                        Button("Share More Contacts", systemImage: "person.crop.circle.badge.plus") { sharingMore = true }
                    }
                }
                #endif
            }
            #if os(iOS)
            .contactAccessPicker(isPresented: $sharingMore) { identifiers in
                Task { await choose(sharedIdentifiers: identifiers) }
            }
            #endif
        }
        #if os(macOS)
        .frame(minWidth: 360, idealWidth: 400, minHeight: 440, idealHeight: 520)
        #endif
        .task { cards = await center.readableCards() }
    }

    private func choose(_ card: ContactCard) {
        onChoose(card)
        dismiss()
    }

    /// Contacts the user just shared with Haus: one is linked; several only refresh the list to pick from.
    private func choose(sharedIdentifiers identifiers: [String]) async {
        cards = await center.readableCards()
        guard identifiers.count == 1, let card = cards?.first(where: { $0.id == identifiers[0] }) else { return }
        choose(card)
    }
}
