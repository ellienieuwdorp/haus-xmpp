import AppKit
import QuickLook
import SwiftUI

/// The open chat. The timeline (`MacTimeline`) opens at the newest message in its first frame, follows the bottom while
/// the reader is there, keeps the reader's row through older pages and resizes, and pages in older history near the top;
/// the composer (`MacComposer`) sits below it. A bubble's right-click menu has the shared menu's Copy and Report. Links
/// in bubbles open through `LinkOpening`, and preview cards show as on the iPhone. Photos and videos show as framed
/// stills and files as a line; a click opens one in Quick Look, or asks for its download when it is not on this Mac yet.
/// Search and the starred filter list a slice of the chat under bars at the top (`MacConversationFindBars`); search
/// hides the composer, as on the iPhone.
struct MacConversationView: View {
    @Bindable var model: AppModel
    let chatID: String
    /// Opens the chat's details, where its devices are reviewed.
    var showDetails: () -> Void = {}
    /// The timeline's rows and scroll position; made when the view first appears.
    @State private var timeline: MacTimelineController?
    /// Rows laid out in the viewport now (LazyVStack's prefetch may add a row just past the edge), so the start of
    /// reading marks the newest one the user can see. Not observed: rows scrolling in and out must not rebuild the
    /// whole timeline, and only the `readingStarts` change reads it.
    @State private var visibleRows = VisibleRows()
    /// A message's Report, waiting for its confirmation.
    @State private var blockRequest: BlockRequest?
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
    /// Bumped by Find; the find bar's field takes focus on each change.
    @State private var findRequests = 0

    private var title: String { AppModel.displayName(for: chatID, title: model.chats.first { $0.id == chatID }?.title) }
    private var presenter: ConversationPresenter { ConversationPresenter(source: model, chatID: chatID, title: title) }

    var body: some View {
        let presenter = presenter
        Group {
            // Built only once this chat's first page is loaded, so the scroll view's initial offset is the tail of
            // real content, not of an empty stack.
            if let timeline, timeline.isLoaded {
                self.timeline(timeline, presenter: presenter)
            } else {
                Color.clear
            }
        }
        .onAppear {
            guard timeline == nil else { return }
            let model = model, chatID = chatID
            timeline = MacTimelineController(model: model, chatID: chatID) {
                ConversationPresenter(source: model, chatID: chatID,
                                      title: AppModel.displayName(for: chatID, title: model.chats.first { $0.id == chatID }?.title))
            }
        }
        // Its own view, so only it reads the messages: this view's body never reruns for a new message.
        .overlay { if let timeline { MacEmptyNotice(timeline: timeline, presenter: presenter) } }
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
        .safeAreaInset(edge: .top, spacing: 0) {
            if let timeline { MacConversationFindBars(timeline: timeline, focusRequests: findRequests) }
        }
        .safeAreaInset(edge: .bottom, spacing: 0) {
            // A blocked chat says so and offers Unblock in place of the composer. The timeline's frame ends above it,
            // so the timeline follows the composer's height as it does the window's (`MacTimelineController.resized`).
            if model.isBlocked(chatID) {
                BlockedChatBar(model: model, chatID: chatID, name: title)
                    .padding(.horizontal, 16).padding(.vertical, 10)
            } else if timeline?.searching != true {
                MacComposer(model: model, chatID: chatID, intent: composerIntent)
            }
        }
        .focusedSceneValue(\.conversationFind, timeline.map { timeline in
            MacConversationFindCommands(find: find, starredOnly: timeline.starredOnly, setStarredOnly: { timeline.setStarredOnly($0) })
        })
        .onChange(of: model.conversationIntent, initial: true) { _, intent in
            // The details' Search and Starred tiles leave what they want opened here, as on the iPhone. Applied in a turn
            // of its own: the timeline scrolls as the filter changes, which it may not do inside a view update.
            switch intent {
            case .search(let id) where id == chatID:
                model.conversationIntent = nil
                DispatchQueue.main.async { find() }
            case .starred(let id) where id == chatID:
                model.conversationIntent = nil
                DispatchQueue.main.async { timeline?.setStarredOnly(true) }
            default: break
            }
        }
        // A reply or an edit needs the composer, which search hides; as on the iPhone, it closes search.
        .onChange(of: composerIntent.focusRequests) { _, _ in timeline?.setSearching(false) }
        .blockConfirmation(model: model, request: $blockRequest)
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

    /// A click on a photo, video or file: Quick Look once it is here, else its download (a file waiting for a click, or
    /// a failed one).
    private func openAttachment(of message: TimelineMessage) {
        guard let attachment = message.attachment, !message.showsPlaceholder else { return }
        if let url = attachment.localURL { quickLook = url } else if attachment.download.canRequest { model.downloadAttachment(message.id) }
    }

    /// Opens search, or moves keyboard focus back into its field when it is open.
    private func find() {
        timeline?.setSearching(true)
        findRequests += 1
    }

    private func copied(_ text: String, because reason: String) {
        copy(text)
        copiedReason = reason
    }

    private func copy(_ text: String) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
    }

    private func timeline(_ timeline: MacTimelineController, presenter: ConversationPresenter) -> some View {
        MacTimeline(controller: timeline) { row in
            MacTimelineRow(row: row, isGroup: timeline.isGroup, report: { id in
                blockRequest = BlockRequest(kind: .report, chatID: chatID, name: title, messageID: id)
            }, openAttachment: { openAttachment(of: row.message) })
                .modifier(MacFindResult(timeline: timeline, id: row.message.id))
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
        // Esc in the timeline closes search and the starred filter.
        .onExitCommand(perform: timeline.isFiltered ? { timeline.clearFilter() } : nil)
        // The user started reading this chat (the app active, its window key and visible, the screen unlocked, the user
        // not idle): what was already on screen counts as seen now (critique G3).
        .onChange(of: model.readingStarts) { _, _ in
            guard let shown = timeline.rows.last(where: { visibleRows.ids.contains($0.message.id) && presenter.marksDisplayed($0.message.id) }) else { return }
            markIfReading(shown.message.id, presenter: presenter)
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

/// What an empty timeline says (`ConversationPresenter.emptyNotice`) under the open filters; a filter that has found
/// nothing yet waits for the earlier messages it is loading.
private struct MacEmptyNotice: View {
    let timeline: MacTimelineController
    let presenter: ConversationPresenter

    var body: some View {
        if let notice = timeline.filtered(presenter).emptyNotice {
            if timeline.loadingAll {
                ProgressView().controlSize(.small)
            } else {
                ContentUnavailableView(notice.title, systemImage: notice.systemImage)
            }
        }
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
