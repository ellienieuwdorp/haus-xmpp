import AppKit
import MessageStore
import QuickLook
import SwiftUI

/// The open chat, read-only. A placeholder until the Mac has its own timeline and composer: it shows the rows the
/// shared presenter builds, in a SwiftUI `LazyVStack` that opens at the newest message in its first frame (scrolling
/// there after layout shows a visible jump) and follows the bottom while the reader is there. No paging, no prepend
/// hold, no composer yet. A bubble's right-click menu, its hover toolbar and its VoiceOver actions perform the shared
/// menu's actions (`MacMessageHandlers`), with the iPhone's retry and unsend dialogs. Links in bubbles open
/// through `LinkOpening`, and preview cards show as on the iPhone. Photos and videos show as framed stills and files
/// as a line; a click opens one in Quick Look, or asks for its download when it is not on this Mac yet.
struct MacConversationView: View {
    @Bindable var model: AppModel
    let chatID: String
    /// Opens the chat's details, where its devices are reviewed.
    var showDetails: () -> Void = {}
    @State private var nearBottom = true
    /// Rows laid out in the viewport now (LazyVStack's prefetch may add a row just past the edge), so the start of
    /// reading marks the newest one the user can see. Not observed: rows scrolling in and out must not rebuild the
    /// whole timeline, and only the `readingStarts` change reads it.
    @State private var visibleRows = VisibleRows()
    /// A message's Report, waiting for its confirmation.
    @State private var blockRequest: BlockRequest?
    @State private var retryMessageID: String?
    @State private var unsendMessageID: String?
    /// A phone link was clicked: Call, Send Message or Copy.
    @State private var phoneLink: PhoneLink?
    /// A link could not be opened, so it was copied; the alert says why.
    @State private var copiedReason: String?
    /// An `xmpp:…?join` link to a group this account is not in: the join flow, with its address filled in.
    @State private var joiningGroup: String?
    /// The file shown in Quick Look.
    @State private var quickLook: URL?
    /// The composer's reply or edit, set by message actions.
    @State private var composerIntent = MacComposerIntent()

    private var title: String { AppModel.displayName(for: chatID, title: model.chats.first { $0.id == chatID }?.title) }
    private var presenter: ConversationPresenter { ConversationPresenter(source: model, chatID: chatID, title: title) }
    private var isGroup: Bool { model.isGroup(chatID) }
    /// Where Encryption details goes: the inspector's page for this chat's devices, or a group's details.
    private var encryptionRoute: ChatRoute { isGroup ? .groupDetails(chatID) : .encryption(chatID) }

    /// The failed message the retry dialog is for was a file failed when encryption was set up again: its key is gone,
    /// so the store refuses a retry and the dialog only explains.
    private var retryIsImpossible: Bool {
        retryMessageID.flatMap { id in model.messages.first { $0.id == id }?.rejection } == MessageStore.encryptionResetRejection
    }

    var body: some View {
        let presenter = presenter
        Group {
            // Built only once this chat's first page is loaded, so the scroll view's initial offset is the tail of
            // real content, not of an empty stack.
            if model.messagesLoadedFor == chatID {
                timeline(presenter)
            } else {
                Color.clear
            }
        }
        .overlay {
            if let notice = presenter.emptyNotice {
                ContentUnavailableView(notice.title, systemImage: notice.systemImage)
            }
        }
        .safeAreaInset(edge: .top) {
            // Messages from a device nobody decided on wait, encrypted, until the user reviews it (the iPhone shows a
            // card in the chat); the review itself is on the details' Devices & Encryption page.
            if !model.isDemo, model.trustSummary(for: chatID).needsReview {
                HStack(spacing: 10) {
                    Image(systemName: "exclamationmark.shield").foregroundStyle(.orange)
                    Text("New messages wait until you review this chat's devices.").font(.callout)
                    Spacer(minLength: 8)
                    Button("Review Devices…", action: showDetails)
                }
                .padding(.horizontal, 14).padding(.vertical, 8)
                .background(.orange.opacity(0.12), in: RoundedRectangle(cornerRadius: 10, style: .continuous))
                .padding(.horizontal, 16).padding(.top, 8)
            }
        }
        .safeAreaInset(edge: .bottom) {
            // Where the composer will be: a blocked chat says so and offers Unblock.
            if model.isBlocked(chatID) {
                BlockedChatBar(model: model, chatID: chatID, name: title)
                    .padding(.horizontal, 16).padding(.vertical, 10)
            }
        }
        .blockConfirmation(model: model, request: $blockRequest)
        .confirmationDialog(retryIsImpossible ? "This file can’t be sent" : "Send this message again?", isPresented: Binding(
            get: { retryMessageID != nil }, set: { if !$0 { retryMessageID = nil } }
        ), titleVisibility: .visible, presenting: retryMessageID) { id in
            if retryIsImpossible {
                Button("OK", role: .cancel) { retryMessageID = nil }
            } else {
                Button("Send again") {
                    Task { await model.retryMessage(id) }
                    retryMessageID = nil
                }
                Button("Cancel", role: .cancel) { retryMessageID = nil }
            }
        } message: { id in
            if retryIsImpossible {
                Text(RejectionCopy.reason(MessageStore.encryptionResetRejection, isGroup: isGroup))
            } else if let rejection = model.messages.first(where: { $0.id == id })?.rejection {
                Text("It wasn't delivered. \(RejectionCopy.reason(rejection, isGroup: isGroup)) Sending again only helps once that has changed.")
            } else {
                Text("The recipient may already have it. Sending again could create a duplicate.")
            }
        }
        .confirmationDialog("Unsend this message?", isPresented: Binding(
            get: { unsendMessageID != nil }, set: { if !$0 { unsendMessageID = nil } }
        ), titleVisibility: .visible, presenting: unsendMessageID) { id in
            Button("Unsend", role: .destructive) {
                Task { await model.unsend(messageID: id) }
                if composerIntent.editing?.id == id { composerIntent.cancelEditing() }
                unsendMessageID = nil
            }
            Button("Cancel", role: .cancel) { unsendMessageID = nil }
        } message: { _ in
            Text("It disappears here. \(title) may still see it if their app doesn't support unsending.")
        }
        .background(Color(nsColor: .textBackgroundColor))
        .navigationTitle(title)
        .navigationSubtitle(model.trustSummary(for: chatID).pill)
        .toolbar {
            // The contact's picture before the name, as the iPhone's header shows it; a click opens the details.
            ToolbarItem(placement: .navigation) {
                Button(action: showDetails) {
                    ChatAvatar(key: chatID, name: title, image: model.avatars[chatID], isGroup: model.isGroup(chatID), size: 28)
                }
                .buttonStyle(.plain)
                .help("Show the chat's details")
                .accessibilityLabel("Chat Details")
                .task(id: "\(chatID)|\(model.session.isReady)") { await model.loadAvatar(for: chatID) }
            }
            .sharedBackgroundVisibility(.hidden)
        }
        .quickLookPreview($quickLook)
        #if DEBUG
        // A tour step performing a message action as its menu item would (`MacDebugHooks`).
        .onChange(of: MacDebugHooks.tour.messageRequest) { _, request in
            guard let request, let message = presenter.timelineMessages.first(where: { $0.id == request.messageID }) else { return }
            // No Copy: a run must leave the Mac's pasteboard alone.
            let kinds: [String: MessageAction.Kind] = ["reply": .reply, "edit": .edit, "star": .star, "retry": .retry, "unsend": .unsend,
                                                       "encryption": .encryptionDetails, "report": .report]
            if request.verb == "react" { messageHandlers.react(request.argument, message) }
            if let kind = kinds[request.verb] { perform(kind, on: message, link: nil) }
            MacDebugHooks.log("composer intent: replying to \(composerIntent.replyingTo?.id ?? "none"), editing \(composerIntent.editing?.id ?? "none")")
        }
        #endif
        // Closed by the root when the selection moves on or the window closes: SwiftUI may build the detail column more
        // than once for one selection, and a late disappearance would close the chat the new view just opened.
        .task(id: [chatID, model.accountID]) { await model.openChat(chatID) }
        .environment(\.openURL, OpenURLAction { url in open(url); return .handled })
        .confirmationDialog(phoneLink?.number ?? "", isPresented: Binding(get: { phoneLink != nil }, set: { if !$0 { phoneLink = nil } }),
                            titleVisibility: .visible, presenting: phoneLink) { link in
            Button("Call") { NSWorkspace.shared.open(link.call) }
            Button("Send message") { NSWorkspace.shared.open(link.message) }
            Button("Copy") { copy(link.number) }
        }
        .alert("Copied", isPresented: Binding(get: { copiedReason != nil }, set: { if !$0 { copiedReason = nil } }), presenting: copiedReason) { _ in
            Button("OK") {}
        } message: { Text($0) }
        .sheet(isPresented: Binding(get: { joiningGroup != nil }, set: { if !$0 { joiningGroup = nil } })) {
            NavigationStack {
                GroupJoinView(model: model, room: joiningGroup ?? "") { room in
                    joiningGroup = nil
                    model.requestRoute(.chat(room))
                }
                .toolbar { ToolbarItem(placement: .cancellationAction) { Button("Cancel") { joiningGroup = nil } } }
            }
            .frame(minWidth: 420, idealWidth: 460, minHeight: 360, idealHeight: 420)
            .themedRoot()
        }
    }

    /// Performs a link from a bubble or a card. Where it goes is `LinkOpening`'s decision, shared with the iPhone; web
    /// pages always open in the default browser.
    private func open(_ url: URL) {
        switch LinkOpening.destination(for: url, inAppBrowser: false) {
        case .web(let page, _), .map(let page):
            NSWorkspace.shared.open(page)
        case .phone(let number, let call, let message):
            phoneLink = PhoneLink(number: number, call: call, message: message)
        case .mail(let mail, let address):
            if !NSWorkspace.shared.open(mail) { copied(address, because: "No mail app is set up on this Mac, so the address was copied.") }
        case .chat(let address):
            guard address != chatID else { return }
            if model.isGroup(address) { model.requestRoute(.chat(address)); return }
            Task { if let chat = await model.createChat(address) { model.requestRoute(.chat(chat)) } }
        case .group(let room):
            if !model.isGroup(room) { joiningGroup = room } else if room != chatID { model.requestRoute(.chat(room)) }
        case .unsupported:
            copied(LinkOpening.copyText(for: url), because: "This link can’t be opened here, so it was copied.")
        }
    }

    /// What a bubble's menu, toolbar and VoiceOver actions do here; the iPhone's `ConversationView` does the same.
    private var messageHandlers: MacMessageHandlers {
        MacMessageHandlers(perform: { kind, message, link in perform(kind, on: message, link: link) },
                           react: { emoji, message in Task { await model.toggleReaction(emoji, messageID: message.id) } })
    }

    private func perform(_ kind: MessageAction.Kind, on message: TimelineMessage, link: URL?) {
        switch kind {
        case .reply:
            guard let stored = model.messages.first(where: { $0.id == message.id }) else { return }
            composerIntent.reply(to: stored)
        case .edit:
            guard let stored = model.messages.first(where: { $0.id == message.id }) else { return }
            composerIntent.edit(stored)
        case .copy: copy(message.body)
        case .star: Task { await model.toggleStar(message.id) }
        case .retry: retryMessageID = message.id
        case .unsend: unsendMessageID = message.id
        case .encryptionDetails: model.requestRoute(encryptionRoute)
        case .report: blockRequest = BlockRequest(kind: .report, chatID: chatID, name: title, messageID: message.id)
        // The menu's first link item: Call for a phone number, what a click does otherwise.
        case .openLink:
            guard let link else { return }
            if case .phone(_, let call, _) = LinkOpening.destination(for: link, inAppBrowser: false) { NSWorkspace.shared.open(call) } else { open(link) }
        case .messageNumber:
            guard let link, case .phone(_, _, let message) = LinkOpening.destination(for: link, inAppBrowser: false) else { return }
            NSWorkspace.shared.open(message)
        case .copyLink: if let link { copy(LinkOpening.copyText(for: link)) }
        // The row selects its own text; the menus share a link through the system's share menu.
        case .selectText, .shareLink: break
        }
    }

    /// A click on a photo, video or file: Quick Look once it is here, else its download (a file waiting for a click, or
    /// a failed one).
    private func openAttachment(of message: TimelineMessage) {
        guard let attachment = message.attachment, !message.showsPlaceholder else { return }
        if let url = attachment.localURL { quickLook = url } else if attachment.download.canRequest { model.downloadAttachment(message.id) }
    }

    private func copied(_ text: String, because reason: String) {
        copy(text)
        copiedReason = reason
    }

    private func copy(_ text: String) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
    }

    private func timeline(_ presenter: ConversationPresenter) -> some View {
        let rows = TimelineItems.rows(for: presenter.timelineMessages)
        let typing = presenter.typing
        let tail = rows.last?.message.id
        return ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(spacing: 0) {
                    ForEach(rows, id: \.message.id) { row in
                        MacTimelineRow(row: row, isGroup: presenter.isGroup, handlers: messageHandlers, openAttachment: { openAttachment(of: row.message) })
                            .id(row.message.id)
                            .onAppear {
                                visibleRows.ids.insert(row.message.id)
                                markIfReading(row.message.id, presenter: presenter)
                                // Fetched on display, never at insert, under the model's policy (setting, contact, demo).
                                if row.message.wantsLinkPreview { model.linkPreviewDisplayed(row.message.id) }
                                // As on the iPhone: a file not on disk yet is fetched on sight when its chat allows it.
                                if row.message.attachment?.localURL == nil, row.message.attachment != nil, !row.message.showsPlaceholder {
                                    model.attachmentDisplayed(row.message.id)
                                }
                            }
                            .onDisappear { visibleRows.ids.remove(row.message.id) }
                    }
                    if let typing {
                        MacTypingRow(typing: typing).id(TimelineItems.typingID)
                    }
                }
                .padding(.horizontal, 16)
                .padding(.vertical, 12)
                .scrollTargetLayout()
            }
            .defaultScrollAnchor(.bottom, for: .initialOffset)
            .onScrollGeometryChange(for: Bool.self) { geometry in
                geometry.contentSize.height - geometry.contentOffset.y - geometry.containerSize.height < TimelineScrollPolicy.nearBottomDistance
            } action: { _, isNear in nearBottom = isNear }
            // Rule 3, simplified: a new tail (or the typing bubble) follows when the reader was at the bottom or sent it.
            .onChange(of: [tail, typing == nil ? nil : TimelineItems.typingID]) { _, _ in
                let ownSend = rows.last?.message.isOutgoing ?? false
                guard nearBottom || ownSend else { return }
                let target = typing == nil ? tail : TimelineItems.typingID
                if let target { proxy.scrollTo(target, anchor: .bottom) }
            }
            // The user started reading this chat (the app active, its window key and visible, the screen unlocked,
            // the user not idle): what was already on screen counts as seen now (critique G3).
            .onChange(of: model.readingStarts) { _, _ in
                guard let shown = rows.last(where: { visibleRows.ids.contains($0.message.id) && presenter.marksDisplayed($0.message.id) }) else { return }
                markIfReading(shown.message.id, presenter: presenter)
            }
        }
    }

    /// The newest received message marks the chat read when it shows. The model marks it only while the user reads
    /// this chat (`LifecycleSignals.readsOpenChat`, from `MacLifecycle`), so a row appearing in a window behind other
    /// apps marks nothing; the start of reading marks it then.
    private func markIfReading(_ id: String, presenter: ConversationPresenter) {
        guard presenter.marksDisplayed(id) else { return }
        Task { await model.markDisplayed(id) }
    }
}

/// A clicked phone link's choices.
private struct PhoneLink {
    let number: String
    let call: URL
    let message: URL
}

/// A plain reference holder, so changing it never invalidates the view that owns it.
@MainActor private final class VisibleRows {
    var ids: Set<String> = []
}
