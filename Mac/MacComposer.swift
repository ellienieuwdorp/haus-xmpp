import AppKit
import ImageIO
import PhotosUI
import SwiftUI
import XMPPProtocol

/// A chat's draft, kept apart from everything the timeline reads, so typing redraws the composer and never the
/// messages. One per chat while the app runs (`MacComposerDrafts`), outliving the composer: a send that fails after the
/// user moved to another chat puts its text back where they will find it.
@MainActor @Observable final class MacComposerState {
    var draft = ""
    /// True from Send until the files and the text are queued; the tray is frozen meanwhile.
    var sending = false
    /// Files waiting for Send, in the order they were picked, pasted or dropped (`MacAttachmentIntake`).
    var tray: [MacTrayItem] = []
    /// The tray's files being prepared, one after another so they land in order.
    @ObservationIgnored var preparation: Task<Void, Never>?
    /// The text view showing this draft, which the attach menu makes first responder for Continuity Camera.
    @ObservationIgnored weak var textView: MacComposerTextView?
    /// The card for the first link in the draft; Send freezes it into the message.
    @ObservationIgnored let linkPreview = ComposerLinkPreview()
    /// The edit a successful Send just finished: its draft was already cleared, and anything typed since stays.
    @ObservationIgnored var finishedEdit: String?
    /// The edit whose text the draft holds, so the composer coming back after search hid it keeps what was typed since.
    @ObservationIgnored var loadedEdit: String?
}

/// Each chat's composer state while the app runs, so switching chats and coming back finds the draft where it was.
/// Kept in memory only, so a draft never reaches the disk, and for one account: another account's chats start empty.
@MainActor enum MacComposerDrafts {
    private static var account = ""
    private static var states: [String: MacComposerState] = [:]

    static func state(account: String, chat: String) -> MacComposerState {
        if account != self.account {
            self.account = account
            states = [:]
        }
        if let state = states[chat] { return state }
        // Chats left empty, with nothing on its way, have nothing to come back to.
        states = states.filter { !$0.value.draft.isEmpty || !$0.value.tray.isEmpty || $0.value.sending }
        let state = MacComposerState()
        states[chat] = state
        return state
    }
}

extension MacComposer {
    /// An edit ends with its chat: its text is the message's, not a draft to come back to. Called as the conversation
    /// closes, not as the composer goes: search hides the composer and keeps the edit, as on the iPhone.
    static func endEditing(_ intent: MacComposerIntent, account: String, chatID: String) {
        guard intent.editing != nil else { return }
        intent.cancelEditing()
        let state = MacComposerDrafts.state(account: account, chat: chatID)
        state.draft = ""
        state.loadedEdit = nil
    }
}

/// The composer under the Mac conversation: the reply or edit bar, the attach button, the tray of files, the link
/// preview card, the text field and Send. Return sends, Shift-Return and Option-Return start a new line, Esc cancels a
/// reply or an edit, and Up-arrow in an empty field edits the newest message that offers Edit. Sends as the iPhone
/// composer does: the same gating, the same files-then-caption plan (`ComposerPlan`), the same reply, preview and edit
/// handling, and typing notifications from the draft (`AppModel.draftChanged`).
struct MacComposer: View {
    let model: AppModel
    let chatID: String
    @Bindable var intent: MacComposerIntent
    /// Shift-Tab from the field, past the composer's own controls: keyboard focus goes back to the timeline above.
    let focusTimeline: (() -> Void)?
    @State private var state: MacComposerState
    @FocusState private var control: MacComposerControl?
    @State private var choosingPhotos = false
    @State private var photoItems: [PhotosPickerItem] = []
    @State private var choosingFiles = false
    @Environment(\.appearance) private var appearance

    init(model: AppModel, chatID: String, intent: MacComposerIntent, focusTimeline: (() -> Void)? = nil) {
        self.model = model
        self.chatID = chatID
        self.intent = intent
        self.focusTimeline = focusTimeline
        // Restored without announcing it: the peer hears typing only once the user changes the draft.
        _state = State(initialValue: MacComposerDrafts.state(account: model.accountID, chat: chatID))
    }

    /// Built bare, so the bars read only what an author line needs.
    private var presenter: ConversationPresenter {
        ConversationPresenter(source: model, chatID: chatID, title: AppModel.displayName(for: chatID, title: model.chats.first { $0.id == chatID }?.title))
    }

    private var tint: Color { Color(platform: appearance.accent.tint) }

    private var placeholder: String {
        if !model.isDemo, model.encryptionNeedsReview { return "Sending paused until you review" }
        guard showsTray else { return "Message" }
        return ComposerPlan.trayPlaceholder(reply: intent.replyingTo) { model.canReplyWithFilesAlone(to: $0, in: chatID) }
    }

    /// Where the iPhone shows its attach button: a direct chat on a server that takes uploads (any sample chat).
    private var showsAttach: Bool { !model.isGroup(chatID) && model.canSendAttachments }
    private var attachEnabled: Bool { intent.editing == nil && !state.sending && !model.isSending }
    /// Paste and drop add files whenever the button shows, except while an edit rewrites text.
    private var canAttach: Bool { showsAttach && intent.editing == nil }
    /// The tray is set aside while an edit rewrites text.
    private var showsTray: Bool { intent.editing == nil && !state.tray.isEmpty }
    private var preparing: Bool { state.tray.contains { $0.prepared == nil } }

    private var canSend: Bool {
        guard !model.isSending, !state.sending, model.canSend(to: chatID) else { return false }
        // Send waits for every file in the tray, so none is left behind for a message of its own.
        if showsTray, preparing { return false }
        return ComposerPlan.hasContent(draft: state.draft, editing: intent.editing, hasFiles: showsTray)
    }

    /// What the link preview card follows, as on the iPhone: the draft, the setting (never in the sample
    /// conversations), whether the chat can carry a preview (modern OMEMO), and whether this message may carry one (not
    /// with files, not an edit).
    private var linkPreviewInput: LinkPreviewInput {
        #if DEBUG
        if MacComposerTour.samplePreview { return LinkPreviewInput(draft: state.draft, enabled: true, suppressed: showsTray || intent.editing != nil) }
        #endif
        return LinkPreviewInput(draft: state.draft, enabled: LinkSettings.shared.fetchPreviews && !model.isDemo && model.linkPreviewsTravel(to: chatID),
                                suppressed: showsTray || intent.editing != nil)
    }

    private var linkPreviewSource: any ComposerLinkPreviewSource {
        #if DEBUG
        if MacComposerTour.samplePreview { return MacComposerTour.SamplePreviewSource.shared }
        #endif
        return model
    }

    var body: some View {
        GlassEffectContainer(spacing: 8) {
            VStack(spacing: 8) {
                if let message = intent.editing ?? intent.replyingTo {
                    contextBar(message, isEdit: intent.editing != nil)
                }
                HStack(alignment: .bottom, spacing: 8) {
                    if showsAttach {
                        MacAttachButton(enabled: attachEnabled, focus: $control,
                                        photos: { choosingPhotos = true }, files: { choosingFiles = true },
                                        prepareImport: { state.textView?.focus() })
                    }
                    VStack(alignment: .leading, spacing: 0) {
                        if state.linkPreview.state != .none {
                            MacComposerLinkPreviewCard(state: state.linkPreview.state, focus: $control) { state.linkPreview.remove() }
                        }
                        if showsTray {
                            MacAttachmentTray(items: state.tray, frozen: state.sending, focus: $control) { id in state.tray.removeAll { $0.id == id } }
                        }
                        HStack(alignment: .bottom, spacing: 4) {
                            field
                            sendButton
                        }
                        .frame(minHeight: 44)
                    }
                    // A capsule at one line; the same radius keeps eight lines, the tray and the card readable.
                    .glassEffect(.regular, in: RoundedRectangle(cornerRadius: 22, style: .continuous))
                }
            }
        }
        .padding(.horizontal, 16).padding(.vertical, 10)
        .onChange(of: state.draft) { _, draft in model.draftChanged(draft, in: chatID) }
        .photosPicker(isPresented: $choosingPhotos, selection: $photoItems, maxSelectionCount: max(1, ComposerPlan.trayLimit - state.tray.count),
                      selectionBehavior: .ordered, matching: .any(of: [.images, .videos]))
        .onChange(of: photoItems) { _, items in
            guard !items.isEmpty else { return }
            photoItems = []
            MacAttachmentIntake.add(MacAttachmentIntake.jobs(forPhotos: items, limit: model.attachmentLimit), to: state, model: model)
        }
        .fileImporter(isPresented: $choosingFiles, allowedContentTypes: [.item], allowsMultipleSelection: true) { result in
            guard case .success(let urls) = result else { return }
            MacAttachmentIntake.add(MacAttachmentIntake.jobs(for: .files(urls), limit: model.attachmentLimit), to: state, model: model)
        }
        // Also on appearing: an edit started while the composer was away (search, a blocked chat) brings its text
        // along, one still open keeps what was typed, and one that ended meanwhile leaves the field as it would have.
        .onChange(of: intent.editing?.id, initial: true) { previous, _ in
            if let message = intent.editing {
                if state.loadedEdit != message.id { state.draft = message.body }
            } else if let ended = previous ?? state.loadedEdit, state.finishedEdit != ended {
                // A cancelled edit leaves an empty field, as on the iPhone.
                state.draft = ""
            }
            state.loadedEdit = intent.editing?.id
            state.finishedEdit = nil
        }
        .onChange(of: linkPreviewInput, initial: true) { _, input in
            state.linkPreview.update(draft: input.draft, enabled: input.enabled, suppressed: input.suppressed, source: linkPreviewSource)
        }
        #if DEBUG
        .onAppear { MacComposerTour.intent = intent }
        #endif
    }

    private var field: some View {
        MacComposerTextField(state: state, placeholder: placeholder, actions: keyActions, focusRequests: intent.focusRequests)
            .overlay(alignment: .topLeading) {
                if state.draft.isEmpty {
                    Text(placeholder)
                        .font(Font(MacComposerTextField.font))
                        .foregroundStyle(Color(nsColor: .placeholderTextColor))
                        .lineLimit(1)
                        .padding(.top, MacComposerTextField.verticalInset)
                        .allowsHitTesting(false)
                        .accessibilityHidden(true)
                }
            }
            .padding(.leading, 16)
    }

    private var sendTinted: Bool {
        #if DEBUG
        if MacComposerTour.untintedSend { return false }
        #endif
        return true
    }

    /// The fixed 30 pt circle at the field's trailing edge; its glyph turns into a checkmark for an edit.
    private var sendButton: some View {
        Button(action: send) {
            Image(systemName: intent.editing == nil ? "arrow.up" : "checkmark").font(.system(size: 14, weight: .bold))
        }
        .buttonStyle(CircularGlassButtonStyle(diameter: 30, tinted: sendTinted))
        .disabled(!canSend)
        .help(intent.editing == nil ? "Send" : "Save Edit")
        .accessibilityLabel(intent.editing == nil ? "Send" : "Save Edit")
        .accessibilityIdentifier("sendMessage")
    }

    /// The strip above the field: the message a send quotes, or the one it rewrites.
    private func contextBar(_ message: ChatMessage, isEdit: Bool) -> some View {
        HStack(spacing: 10) {
            RoundedRectangle(cornerRadius: 2).fill(tint).frame(width: 3)
            VStack(alignment: .leading, spacing: 1) {
                Text(isEdit ? "Editing message" : "Replying to \(presenter.authorName(message.senderID))")
                    .font(.callout.weight(.semibold)).foregroundStyle(tint)
                Text(message.quoteText).font(.callout).foregroundStyle(.secondary).lineLimit(1)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            if !isEdit, let still = replyStill(message) { MacQuoteStill(attachment: still, tint: .secondary) }
            Button { cancel(isEdit: isEdit) } label: {
                Image(systemName: "xmark").font(.system(size: 12, weight: .semibold)).foregroundStyle(.secondary)
                    .frame(width: 28, height: 28).contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .focused($control, equals: .cancelBar)
            .help(isEdit ? "Cancel Edit (Esc)" : "Cancel Reply (Esc)")
            .accessibilityLabel(isEdit ? "Cancel edit" : "Cancel reply")
            .accessibilityIdentifier(isEdit ? "cancelEdit" : "cancelReply")
        }
        .fixedSize(horizontal: false, vertical: true)
        .padding(.leading, 14).padding(.trailing, 8).padding(.vertical, 6)
        .glassEffect(.regular, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
        .accessibilityElement(children: .contain)
    }

    /// The quoted photo or video, for a small still beside the quote (its file once on disk); nil shows the text alone.
    private func replyStill(_ source: ChatMessage) -> TimelineAttachment? {
        guard let attachment = source.attachment, attachment.isImage || attachment.isVideo else { return nil }
        return TimelineAttachment(name: attachment.name, mediaType: attachment.mediaType, size: attachment.size, width: attachment.width,
                                  height: attachment.height, localURL: model.attachmentFiles[source.id])
    }

    private var keyActions: MacComposerKeyActions {
        MacComposerKeyActions(send: send, editLast: editLast, cancel: cancelCurrent, attach: attach, canAttach: { canAttach },
                              focusPrevious: focusTimeline.map { focusTimeline in { focusBeforeField(else: focusTimeline) } })
    }

    /// Shift-Tab from the field: with Full Keyboard Access, the control just before it, as the key view loop would
    /// reach it (from there SwiftUI moves focus on itself); else, or with none, the timeline.
    private func focusBeforeField(else focusTimeline: () -> Void) {
        if NSApp.isFullKeyboardAccessEnabled, let previous = controlBeforeField { control = previous } else { focusTimeline() }
    }

    /// The composer's controls in reverse reading order: the tray's last remove button, the link preview's, Attach,
    /// then the reply or edit bar's cancel button.
    private var controlBeforeField: MacComposerControl? {
        if showsTray, !state.sending, let last = state.tray.last { return .removeAttachment(last.id) }
        if state.linkPreview.state != .none { return .removeLinkPreview }
        if showsAttach, attachEnabled { return .attach }
        if (intent.editing ?? intent.replyingTo) != nil { return .cancelBar }
        return nil
    }

    private func cancel(isEdit: Bool) {
        if isEdit { intent.cancelEditing() } else { intent.cancelReply() }
        intent.focusComposer()
    }

    private func cancelCurrent() -> Bool {
        if intent.editing != nil { intent.cancelEditing(); return true }
        if intent.replyingTo != nil { intent.cancelReply(); return true }
        return false
    }

    private func editLast() -> Bool {
        guard let message = presenter.newestEditable else { return false }
        intent.edit(message)
        return true
    }

    /// Files and images pasted, dropped or imported from an iPhone into the field arrive here and join the tray. Where
    /// the chat cannot take files, the text view pastes or drops them as text would.
    private func attach(_ attachments: MacComposerAttachments) -> Bool {
        guard canAttach else { return false }
        MacAttachmentIntake.add(MacAttachmentIntake.jobs(for: attachments, limit: model.attachmentLimit), to: state, model: model)
        return true
    }

    private func send() {
        guard canSend else { return }
        let state = state, intent = intent
        let text = state.draft
        let account = model.accountID
        let chatID = chatID
        // Cleared now, not once the send settles: anything typed meanwhile would otherwise leave the sent text behind.
        // A failure puts the text back if the field is still empty, also when the user has moved to another chat
        // (the state is the chat's, not this view's); a failed edit only while it is still open.
        state.draft = ""
        intent.focusComposer()
        if let editing = intent.editing {
            Task {
                if await model.edit(messageID: editing.id, body: text), model.accountID == account {
                    if intent.editing?.id == editing.id {
                        state.finishedEdit = editing.id
                        intent.cancelEditing()
                    }
                } else if intent.editing?.id == editing.id, state.draft.isEmpty, model.accountID == account {
                    state.draft = text
                }
            }
            return
        }
        let reply = intent.replyingTo
        // What the card shows now goes with the text; a fetch still running is not waited for.
        let linkPreview = state.linkPreview.frozen(for: text, suppressed: showsTray)
        let files = state.tray.compactMap { item in item.prepared.map { (id: item.id, prepared: $0) } }
        let plan = ComposerPlan.ReplyPlan(caption: text, reply: reply) { model.canReplyWithFilesAlone(to: $0, in: chatID) }
        state.sending = true
        Task {
            defer { state.sending = false }
            let sent = await ComposerPlan.dispatch(files, caption: text, sendFile: { file in
                guard model.accountID == account,
                      await model.sendAttachment(file.prepared, to: chatID, replyingTo: file.id == files.first?.id ? plan.firstFile : nil) else { return false }
                state.tray.removeAll { $0.id == file.id }
                return true
            }, sendCaption: { text in
                model.accountID == account ? await model.send(text, to: chatID, replyingTo: plan.caption, linkPreview: linkPreview) : false
            })
            guard model.accountID == account else { return }
            if plan.clearsReply(after: sent) {
                if intent.replyingTo?.id == reply?.id { intent.cancelReply() }
            } else if state.draft.isEmpty {
                state.draft = text
            }
        }
    }
}

/// A control of the composer's that keyboard focus can be moved to: Shift-Tab from the field reaches the one before it.
enum MacComposerControl: Hashable {
    case cancelBar
    case attach
    case removeLinkPreview
    case removeAttachment(UUID)
}

private struct LinkPreviewInput: Equatable {
    let draft: String
    let enabled: Bool
    let suppressed: Bool
}

/// The preview of the link being typed, above the text inside the composer's glass, as on the iPhone: the host with
/// an activity indicator while it loads, then the small-thumbnail card, with a button that removes it.
struct MacComposerLinkPreviewCard: View {
    let state: ComposerLinkPreview.State
    var focus: FocusState<MacComposerControl?>.Binding
    let onRemove: () -> Void
    /// Decoded once per card image, not on every composer render; its slot is held from the start.
    @State private var thumbnail: CGImage?

    private var thumbnailData: Data? {
        guard case .ready(let content) = state else { return nil }
        return content.thumbnail
    }

    var body: some View {
        HStack(spacing: 10) {
            switch state {
            case .loading(let url):
                let host = LinkDetection.displayHost(for: url) ?? url.absoluteString
                ProgressView().controlSize(.small).frame(width: TimelineReply.thumbnailSide, height: TimelineReply.thumbnailSide)
                Text(host)
                    .font(.callout).foregroundStyle(.secondary).lineLimit(1)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .accessibilityLabel("Loading link preview for \(host)")
            case .ready(let content):
                if content.thumbnail != nil {
                    Color.clear.frame(width: 40, height: 40)
                        .overlay { if let thumbnail { Image(decorative: thumbnail, scale: 1).resizable().scaledToFill() } }
                        .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
                        .accessibilityHidden(true)
                }
                VStack(alignment: .leading, spacing: 1) {
                    if let title = content.title { Text(title).font(.callout.weight(.semibold)).lineLimit(2) }
                    if let summary = content.summary { Text(summary).font(.caption).foregroundStyle(.secondary).lineLimit(1) }
                    Text(content.host).font(.caption).foregroundStyle(.secondary).lineLimit(1)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .accessibilityElement(children: .ignore)
                .accessibilityLabel("Link preview: " + [content.title, content.host].compactMap { $0 }.joined(separator: ", "))
            case .none:
                EmptyView()
            }
            Button(action: onRemove) {
                Image(systemName: "xmark").font(.system(size: 11, weight: .semibold)).foregroundStyle(.secondary)
                    .frame(width: 28, height: 28).contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .focused(focus, equals: .removeLinkPreview)
            .help("Remove Link Preview")
            .accessibilityLabel("Remove link preview")
            .accessibilityIdentifier("removeLinkPreview")
        }
        .padding(.leading, 8).padding(.trailing, 4).padding(.vertical, 6)
        .background(Color.tertiaryFill, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
        .padding(.horizontal, 8).padding(.top, 8)
        .accessibilityIdentifier("composerLinkPreview")
        .onChange(of: thumbnailData, initial: true) { _, data in
            thumbnail = data.flatMap { CGImageSourceCreateWithData($0 as CFData, nil) }.flatMap { CGImageSourceCreateImageAtIndex($0, 0, nil) }
        }
    }
}

#if DEBUG
/// What `-haus-tour`'s composer steps act on (`MacDebugHooks`): the open chat's text view and intent.
@MainActor enum MacComposerTour {
    static weak var textView: MacComposerTextView?
    static weak var intent: MacComposerIntent?
    /// `-haus-sample-link-preview`: the composer shows a canned card for any link, also in the sample conversations,
    /// without fetching anything.
    static let samplePreview = MacDebugHooks.has("-haus-sample-link-preview")
    /// `-haus-untinted-send`: Send in the clear variant of its style. The window cache leaves glass out anyway, and an
    /// enabled accent-tinted circle leaves the conversation's whole hosting view out of a capture.
    static let untintedSend = MacDebugHooks.has("-haus-untinted-send")

    final class SamplePreviewSource: ComposerLinkPreviewSource {
        static let shared = SamplePreviewSource()
        let linkPreviewUploadHosts: Set<String> = []

        func composerLinkPreview(for url: URL) async -> ComposerLinkPreview.Content? {
            ComposerLinkPreview.Content(url: url, host: LinkDetection.displayHost(for: url) ?? url.absoluteString, title: "Harbour walk this Saturday",
                                        summary: "Meet at the old lighthouse at ten; the route follows the quay.", thumbnail: Self.thumbnail)
        }

        /// A small gradient JPEG standing in for a page's image.
        private static let thumbnail: Data? = {
            let side = 96
            guard let context = CGContext(data: nil, width: side, height: side, bitsPerComponent: 8, bytesPerRow: 0,
                                          space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue),
                  let gradient = CGGradient(colorsSpace: nil, colors: [CGColor(red: 0.2, green: 0.45, blue: 0.8, alpha: 1),
                                                                       CGColor(red: 0.95, green: 0.7, blue: 0.35, alpha: 1)] as CFArray, locations: nil)
            else { return nil }
            context.drawLinearGradient(gradient, start: .zero, end: CGPoint(x: side, y: side), options: [])
            guard let image = context.makeImage() else { return nil }
            return NSBitmapImageRep(cgImage: image).representation(using: .jpeg, properties: [:])
        }()
    }
}
#endif
