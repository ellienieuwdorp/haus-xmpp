import SwiftUI
import XMPPProtocol

extension View {
    /// The block and report confirmation for `request`; nothing reaches the server until a button in it is chosen.
    func blockConfirmation(model: AppModel, request: Binding<BlockRequest?>) -> some View {
        modifier(BlockConfirmation(model: model, request: request))
    }
}

private struct BlockConfirmation: ViewModifier {
    let model: AppModel
    @Binding var request: BlockRequest?

    private var title: String {
        guard let request else { return "" }
        switch request.kind {
        case .block: return BlockingCopy.blockTitle(request.name)
        case .report: return BlockingCopy.reportTitle(request.name, message: request.messageID != nil)
        }
    }

    func body(content: Content) -> some View {
        content.confirmationDialog(title, isPresented: Binding(get: { request != nil }, set: { if !$0 { request = nil } }),
                                   titleVisibility: .visible, presenting: request) { request in
            switch request.kind {
            case .block:
                Button("Block", role: .destructive) { Task { await model.block(request.chatID) } }
            case .report:
                Button("Report Spam", role: .destructive) { Task { await model.block(request.chatID, report: .spam, messageID: request.messageID) } }
                Button("Report Abuse", role: .destructive) { Task { await model.block(request.chatID, report: .abuse, messageID: request.messageID) } }
            }
            Button("Cancel", role: .cancel) {}
        } message: { request in
            switch request.kind {
            case .block:
                Text(BlockingCopy.blockMessage(request.name, domain: model.accountDomain))
            case .report:
                Text(BlockingCopy.reportMessage(request.name, domain: model.accountDomain,
                                                quotesMessage: request.messageID != nil && (model.blockingSupport.archive || model.isDemo),
                                                serverHandlesReports: model.blockingSupport.reporting || model.isDemo))
            }
        }
    }
}

/// Block, Report and Unblock for a direct chat, at the end of its details (the iPhone's screen and the Mac's inspector).
/// A server without XEP-0191, or no connection, leaves the actions disabled with the reason in a row below them.
struct ChatBlockingSection: View {
    @Bindable var model: AppModel
    let chatID: String
    let name: String
    @State private var request: BlockRequest?

    var body: some View {
        let availability = model.blockingAvailability
        Section {
            Group {
                if model.isBlocked(chatID) {
                    // An entry for the whole domain blocks the chat too; unblocking the chat lifts what blocks it.
                    action("Unblock \(name)", role: nil) {
                        Task { for entry in model.blockEntries(for: chatID) { await model.unblock(entry) } }
                    }
                    .accessibilityIdentifier("unblockContact")
                } else {
                    action("Block \(name)", role: .destructive) {
                        request = BlockRequest(kind: .block, chatID: chatID, name: name)
                    }
                    .accessibilityIdentifier("blockContact")
                    action("Report \(name)", role: .destructive) {
                        request = BlockRequest(kind: .report, chatID: chatID, name: name)
                    }
                    .accessibilityIdentifier("reportContact")
                }
            }
            .disabled(!availability.isAvailable)
            // Its own row, so the reason stays readable while the actions above it are dimmed.
            if let reason = availability.reason {
                Text(reason).font(.footnote).foregroundStyle(.secondary)
                    .accessibilityIdentifier("blockingUnavailable")
            }
        }
        .blockConfirmation(model: model, request: $request)
    }

    private func action(_ title: String, role: ButtonRole?, perform: @escaping () -> Void) -> some View {
        Button(role: role, action: perform) {
            Text(title).frame(maxWidth: .infinity, alignment: .leading).contentShape(Rectangle())
        }
        #if os(macOS)
        // A list row in the inspector, as on the iPhone, rather than a bordered push button.
        .buttonStyle(.borderless)
        #endif
        .foregroundStyle(role == .destructive ? AnyShapeStyle(.red) : AnyShapeStyle(.tint))
    }
}

/// In place of the composer while the chat is blocked: sending would be refused by the server anyway.
struct BlockedChatBar: View {
    @Bindable var model: AppModel
    let chatID: String
    let name: String

    var body: some View {
        HStack(spacing: 12) {
            Text("You blocked \(name).").font(.subheadline).foregroundStyle(.secondary)
                .frame(maxWidth: .infinity, alignment: .leading)
            Button("Unblock") {
                Task { for entry in model.blockEntries(for: chatID) { await model.unblock(entry) } }
            }
            .font(.subheadline.weight(.semibold))
            .frame(minHeight: 44)
            .disabled(!model.blockingAvailability.isAvailable)
            .accessibilityIdentifier("unblockFromChat")
        }
        .padding(.leading, 16).padding(.trailing, 12)
        .frame(minHeight: 48)
        .glassEffect(.regular, in: Capsule())
        .accessibilityElement(children: .contain)
    }
}

/// Settings › Blocked: the account's list as the server holds it, with Unblock on each entry. Entries that are no chat
/// (a whole domain, one resource) show their address.
struct BlockedContactsView: View {
    @Bindable var model: AppModel

    private var entries: [String] { model.blocklist.addresses.sorted() }

    var body: some View {
        List {
            if let reason = model.blockingAvailability.reason, !entries.isEmpty {
                Section { Text(reason).foregroundStyle(.secondary) }
            }
            Section {
                ForEach(entries, id: \.self) { address in
                    let name = model.chatName(for: address)
                    HStack(spacing: 12) {
                        ChatAvatar(key: address, name: name, image: model.avatar(for: address), size: 36)
                            .accessibilityHidden(true)
                        VStack(alignment: .leading, spacing: 1) {
                            Text(name).lineLimit(1)
                            Text(address).font(.footnote).foregroundStyle(.secondary).lineLimit(1).truncationMode(.middle)
                        }
                        .accessibilityElement(children: .combine)
                        Spacer(minLength: 8)
                        Button("Unblock") { Task { await model.unblock(address) } }
                            .buttonStyle(.borderless)
                            .frame(minHeight: 44)
                            .disabled(!model.blockingAvailability.isAvailable)
                            .accessibilityLabel("Unblock \(name)")
                    }
                }
            }
        }
        .groupedListStyle()
        .overlay {
            if entries.isEmpty { ContentUnavailableView("No Blocked Contacts", systemImage: "hand.raised") }
        }
        .navigationTitle("Blocked")
        .toolbarTitleDisplayMode(.inline)
    }
}
