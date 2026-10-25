import MessagingCore
import SwiftUI
import UniformTypeIdentifiers

/// The share screen: a chat picker, then a review card with the files and the message text, then each chat's result.
/// A share-sheet suggestion skips the picker. The same views serve the iPhone sheet and the Mac popover.
struct ShareRootView: View {
    @Bindable var model: ShareModel
    let close: () -> Void
    @State private var path: [ShareRoute] = []

    enum ShareRoute: Hashable { case review }

    var body: some View {
        NavigationStack(path: $path) {
            content
                .navigationTitle("Send to")
                .toolbar {
                    ToolbarItem(placement: .cancellationAction) {
                        Button("Cancel", action: close)
                            .keyboardShortcut(.cancelAction)
                    }
                }
                .navigationDestination(for: ShareRoute.self) { _ in ShareReviewView(model: model, close: close) }
        }
        .onChange(of: model.phase) { _, phase in
            // A suggestion opens the review card directly; Back still leads to the picker to add chats.
            if phase == .ready, model.suggested != nil, path.isEmpty { path = [.review] }
        }
    }

    @ViewBuilder private var content: some View {
        switch model.phase {
        case .loading:
            ProgressView().controlSize(.large).frame(maxWidth: .infinity, maxHeight: .infinity)
                .accessibilityLabel("Loading chats")
        case .unavailable(let message):
            ContentUnavailableView {
                Label("Can't share", systemImage: "square.and.arrow.up.trianglebadge.exclamationmark")
            } description: {
                Text(message)
            } actions: {
                Button("Close", action: close)
            }
        case .ready, .sending, .finished:
            SharePickerView(model: model, next: { path = [.review] })
        }
    }
}

/// Pinned and recent chats with a search field; up to five can be chosen. A chat that cannot take this share is shown
/// greyed with the reason, never hidden.
struct SharePickerView: View {
    @Bindable var model: ShareModel
    let next: () -> Void

    var body: some View {
        List {
            let chats = model.listedChats
            if chats.isEmpty {
                Text(model.search.isEmpty ? "No chats yet. Start one in Haus XMPP." : "No chats match “\(model.search)”.")
                    .foregroundStyle(.secondary)
            }
            ForEach(chats) { chat in
                ShareChatRow(model: model, chat: chat)
            }
        }
        .searchable(text: $model.search, prompt: "Search chats")
        .safeAreaInset(edge: .bottom) {
            if !model.selection.isEmpty { selectionBar }
        }
        .disabled(model.phase != .ready)
    }

    /// The chosen chats and the arrow to the review card, as WhatsApp's forward sheet does it.
    private var selectionBar: some View {
        HStack(spacing: 12) {
            Text(ShareCopy.names(model.selectedChats))
                .font(.subheadline)
                .lineLimit(2)
                .frame(maxWidth: .infinity, alignment: .leading)
                .accessibilityLabel("Sending to \(ShareCopy.names(model.selectedChats))")
            Button(action: next) {
                Image(systemName: "arrow.right").font(.system(size: 18, weight: .semibold))
            }
            .buttonStyle(CircularGlassButtonStyle(diameter: 44))
            .accessibilityLabel("Next")
            .accessibilityIdentifier("shareNext")
            .keyboardShortcut(.defaultAction)
        }
        .padding(.horizontal, 16).padding(.vertical, 8)
        .glassEffect(.regular, in: .rect(cornerRadius: 28))
        .padding(.horizontal, 12).padding(.bottom, 8)
    }
}

struct ShareChatRow: View {
    @Bindable var model: ShareModel
    let chat: ShareRules.Chat
    @ScaledMetric(relativeTo: .body) private var scaledAvatar: CGFloat = 40
    @Environment(\.appearance) private var appearance
    @Environment(\.dynamicTypeSize) private var typeSize
    /// The avatar grows with the text only so far: at accessibility sizes the name needs the width.
    private var avatarSize: CGFloat { min(scaledAvatar, 52) }

    private var selected: Bool { model.selection.contains(chat.id) }
    private var reason: String? { model.unavailableReason(chat) }
    private var trust: ConversationTrust { ConversationTrust(chat.encryption, isGroup: chat.isGroup, members: 0) }

    var body: some View {
        Button { model.toggle(chat) } label: {
            HStack(spacing: 12) {
                ChatAvatar(key: chat.id, name: chat.displayTitle, image: model.avatars[chat.id], isGroup: chat.isGroup, size: avatarSize)
                VStack(alignment: .leading, spacing: 2) {
                    Text(chat.displayTitle).font(.body).foregroundStyle(.primary).lineLimit(typeSize.isAccessibilitySize ? 3 : 1)
                    if let reason {
                        Text(reason).font(.footnote).foregroundStyle(.secondary).lineLimit(2)
                    } else if trust.level != .pending {
                        HStack(spacing: 3) { Image(systemName: trust.icon).imageScale(.small); Text(trust.pill) }
                            .font(.footnote)
                            .foregroundStyle(trust.color)
                    }
                }
                Spacer(minLength: 8)
                Image(systemName: selected ? "checkmark.circle.fill" : "circle")
                    .font(.title2)
                    .dynamicTypeSize(...DynamicTypeSize.xxxLarge)
                    .foregroundStyle(selected ? Color(platform: appearance.accent.tint) : Color.secondary.opacity(0.5))
            }
            .frame(minHeight: 52)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .disabled(reason != nil || (!selected && model.atRecipientLimit))
        .opacity(reason == nil ? 1 : 0.5)
        .onAppear { model.loadAvatar(chat) }
        .accessibilityElement(children: .ignore)
        .accessibilityIdentifier("shareChat.\(chat.id)")
        .accessibilityLabel(ShareCopy.rowLabel(chat, trust: trust, reason: reason))
        .accessibilityAddTraits(selected ? [.isButton, .isSelected] : .isButton)
        .accessibilityHint(reason == nil && !selected && model.atRecipientLimit ? "You can send to \(ShareRules.maximumRecipients) chats at most." : "")
    }
}

/// The files, the message text and what happens to it, then each chat's result.
struct ShareReviewView: View {
    @Bindable var model: ShareModel
    let close: () -> Void
    @FocusState private var editing: Bool

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                if !model.files.isEmpty { strip }
                if model.skippedFiles > 0 || model.unreadableItems > 0 {
                    Label(ShareCopy.leftOut(skipped: model.skippedFiles, unreadable: model.unreadableItems), systemImage: "info.circle")
                        .font(.footnote).foregroundStyle(.secondary)
                }
                if model.phase == .ready { composer } else { results }
            }
            .padding(16)
        }
        .scrollDismissesKeyboard(.interactively)
        .background(Color.groupedBackground)
        .navigationTitle(ShareCopy.title(model.selectedChats))
        #if os(iOS)
        .navigationBarTitleDisplayMode(.inline)
        .navigationBarBackButtonHidden(model.phase != .ready)
        #endif
        .toolbar {
            if model.phase != .ready {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done", action: close).keyboardShortcut(.defaultAction).accessibilityIdentifier("shareDone")
                }
            }
        }
        .onAppear { if model.files.isEmpty { editing = true } }
    }

    private var strip: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 10) {
                ForEach(model.files) { item in ShareFileTile(model: model, item: item) }
            }
        }
    }

    private var composer: some View {
        VStack(alignment: .leading, spacing: 16) {
            ShareEncryptionCard(chats: model.selectedChats)
            HStack(alignment: .bottom, spacing: 10) {
                TextField(model.files.isEmpty ? "Message" : "Add a caption…", text: $model.text, axis: .vertical)
                    .lineLimit(1...8)
                    .textFieldStyle(.plain)
                    .focused($editing)
                    .padding(.horizontal, 14).padding(.vertical, 10)
                    .background(Color.secondaryGroupedBackground, in: .rect(cornerRadius: 20))
                    .accessibilityLabel(model.files.isEmpty ? "Message" : "Caption")
                    .accessibilityIdentifier("shareText")
                Button { model.send() } label: {
                    if model.isPreparing { ProgressView() }
                    else { Image(systemName: "paperplane.fill").font(.system(size: 17, weight: .semibold)) }
                }
                .buttonStyle(CircularGlassButtonStyle(diameter: 40))
                .disabled(!model.canSend)
                .accessibilityLabel(model.isPreparing ? "Preparing files" : "Send")
                .accessibilityIdentifier("shareSend")
                .keyboardShortcut(.return, modifiers: .command)
            }
            if model.text.utf8.count > OutgoingEnqueue.maximumTextBytes {
                Text("This message is too long to send.").font(.footnote).foregroundStyle(.secondary)
            }
            if model.hasUnsendableFiles {
                Text("Remove the files that can't be sent to share the rest.").font(.footnote).foregroundStyle(.secondary)
            }
        }
    }

    private var results: some View {
        VStack(alignment: .leading, spacing: 0) {
            ForEach(model.selectedChats) { chat in
                ShareResultRow(chat: chat, delivery: model.deliveries[chat.id] ?? .sending, finished: model.phase == .finished)
                if chat.id != model.selectedChats.last?.id { Divider().padding(.leading, 44) }
            }
            if let note = model.outcomeNote, model.phase == .finished {
                Text(note).font(.footnote).foregroundStyle(.secondary).padding(.top, 12)
            }
        }
        .padding(.horizontal, 14).padding(.vertical, 6)
        .background(Color.secondaryGroupedBackground, in: .rect(cornerRadius: 16))
    }
}

struct ShareFileTile: View {
    @Bindable var model: ShareModel
    let item: SharedItem
    @State private var preview: PlatformImage?
    @ScaledMetric(relativeTo: .body) private var side: CGFloat = 76

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            ZStack(alignment: .topTrailing) {
                ZStack {
                    RoundedRectangle(cornerRadius: 12).fill(Color.secondaryGroupedBackground)
                    if let preview {
                        Image(platformImage: preview).resizable().scaledToFill()
                    } else {
                        Image(systemName: icon).font(.title2).foregroundStyle(.secondary)
                    }
                    if item.kind == .video, preview != nil {
                        Image(systemName: "play.fill").font(.caption).foregroundStyle(.white).padding(5)
                            .background(.black.opacity(0.45), in: Circle())
                    }
                }
                .frame(width: side, height: side)
                .clipShape(RoundedRectangle(cornerRadius: 12))
                if model.phase == .ready {
                    Button { model.remove(item) } label: {
                        Image(systemName: "xmark").font(.system(size: 11, weight: .bold))
                            .frame(width: 22, height: 22)
                            .background(.ultraThinMaterial, in: Circle())
                    }
                    .buttonStyle(.plain)
                    .frame(width: 44, height: 44)
                    .contentShape(Rectangle())
                    .offset(x: 12, y: -12)
                    .accessibilityLabel("Remove \(item.name)")
                }
            }
            Text(status).font(.caption2).foregroundStyle(isProblem ? Color.orange : .secondary).lineLimit(2)
                .frame(width: side, alignment: .leading)
        }
        .accessibilityElement(children: .contain)
        .accessibilityLabel("\(kindLabel), \(status)")
        .task(id: item.id) {
            guard preview == nil, let file = item.file, item.kind == .image || item.kind == .video else { return }
            preview = await AttachmentThumbnails.image(for: file, mediaType: item.kind == .video ? "video/mp4" : "image/jpeg", maxPixels: 240)
        }
    }

    private var icon: String {
        switch item.kind {
        case .image: "photo"
        case .video: "video"
        default: item.type?.conforms(to: .pdf) == true ? "doc.richtext" : "doc"
        }
    }
    private var kindLabel: String {
        switch item.kind {
        case .image: "Photo"
        case .video: "Video"
        default: item.name
        }
    }
    private var isProblem: Bool { if case .failed = model.prepared[item.id] { true } else { false } }
    private var status: String {
        switch model.prepared[item.id] {
        case .preparing?, nil: "Preparing…"
        case .ready(let size)?: ByteCountFormatter.string(fromByteCount: Int64(size), countStyle: .file)
        case .failed(let reason)?: reason
        }
    }
}

/// What happens to this share's encryption, in words, from the chats' stored states. The app sends nothing
/// unencrypted, so a chat that cannot be encrypted never takes the share at all.
struct ShareEncryptionCard: View {
    let chats: [ShareRules.Chat]

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Label("Sent only end-to-end encrypted with OMEMO.", systemImage: "lock.fill")
            ForEach(chats.filter { $0.encryption == .needsReview }) { chat in
                Label("\(chat.displayTitle) has a device to review. This waits in Haus XMPP until you review it there.",
                      systemImage: "exclamationmark.shield")
                    .foregroundStyle(.orange)
            }
        }
        .font(.footnote)
        .foregroundStyle(.secondary)
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(14)
        .background(Color.secondaryGroupedBackground, in: .rect(cornerRadius: 16))
        .accessibilityElement(children: .combine)
    }
}

struct ShareResultRow: View {
    let chat: ShareRules.Chat
    let delivery: ShareModel.Delivery
    let finished: Bool

    var body: some View {
        HStack(spacing: 12) {
            Group {
                switch delivery {
                case .sending: ProgressView()
                case .sent: Image(systemName: "checkmark.circle.fill").foregroundStyle(.green)
                case .queued: Image(systemName: "clock").foregroundStyle(.secondary)
                case .failed, .incomplete: Image(systemName: "exclamationmark.circle").foregroundStyle(.orange)
                }
            }
            .font(.title3)
            .frame(width: 32)
            VStack(alignment: .leading, spacing: 2) {
                Text(chat.displayTitle).lineLimit(1)
                Text(ShareCopy.delivery(delivery)).font(.footnote).foregroundStyle(.secondary)
            }
            Spacer(minLength: 0)
        }
        .frame(minHeight: 52)
        .accessibilityElement(children: .ignore)
        .accessibilityIdentifier("shareResult.\(chat.id)")
        .accessibilityLabel(chat.displayTitle)
        .accessibilityValue(ShareCopy.delivery(delivery))
    }
}

enum ShareCopy {
    static func names(_ chats: [ShareRules.Chat]) -> String {
        ListFormatter.localizedString(byJoining: chats.map(\.displayTitle))
    }

    static func title(_ chats: [ShareRules.Chat]) -> String {
        guard let first = chats.first else { return "Send" }
        return chats.count == 1 ? first.displayTitle : "\(first.displayTitle) and \(chats.count - 1) more"
    }

    static func rowLabel(_ chat: ShareRules.Chat, trust: ConversationTrust, reason: String?) -> String {
        let kind = chat.isGroup ? "group" : nil
        let state = reason ?? (trust.level == .pending ? nil : trust.pill.lowercased())
        return [chat.displayTitle, kind, state].compactMap { $0 }.joined(separator: ", ")
    }

    static func delivery(_ delivery: ShareModel.Delivery) -> String {
        switch delivery {
        case .sending: "Sending…"
        case .sent: "Sent"
        case .queued: "Queued"
        case .failed: "Not sent"
        case .incomplete: "Not all saved"
        }
    }

    static func leftOut(skipped: Int, unreadable: Int) -> String {
        var parts: [String] = []
        if skipped > 0 { parts.append("Only the first \(SharedItemIntake.maximumFiles) files are shared.") }
        if unreadable > 0 { parts.append(unreadable == 1 ? "One item couldn't be read." : "\(unreadable) items couldn't be read.") }
        return parts.joined(separator: " ")
    }
}
