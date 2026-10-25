import Foundation
import MessageStore
import MessagingCore
import Observation
import OMEMO
import os
import UniformTypeIdentifiers
import XMPPProtocol
#if os(iOS)
import UIKit
#else
import AppKit
#endif

/// The share screen's state, from the moment the sheet opens until it closes. Everything it writes goes through the
/// composer's enqueue (`OutgoingEnqueue`) into the shared store, which needs no transport lease: what the user shared is
/// queued before anything is sent and stays queued whatever happens to this process. On the iPhone it then sends
/// itself, under the lease, while the sheet is up (`ShareSession`); on the Mac it rings the running app, which owns
/// the lease and sends. Nothing here migrates the store, accepts trust or sends plaintext.
@MainActor @Observable final class ShareModel {
    enum Phase: Equatable {
        case loading
        /// The share cannot go anywhere; the text says why and what to do.
        case unavailable(String)
        case ready
        case sending
        case finished
    }

    typealias Delivery = ShareRules.Delivery

    private(set) var phase = Phase.loading
    private(set) var chats: [ShareRules.Chat] = []
    private(set) var items: [SharedItem] = []
    /// Files the intake left out (over the limit) or could not read; the review card says so once.
    private(set) var skippedFiles = 0
    private(set) var unreadableItems = 0
    private(set) var prepared: [UUID: Preparation] = [:]
    var selection: [String] = []
    var text = ""
    var search = ""
    /// Set when a share-sheet suggestion named a known chat: the review card opens first.
    private(set) var suggested: String?
    private(set) var deliveries: [String: Delivery] = [:]
    /// A line under the results, when something needs saying (queued, or not sent).
    private(set) var outcomeNote: String?
    private(set) var avatars: [String: PlatformImage] = [:]

    enum Preparation: Equatable {
        case preparing
        case ready(size: Int)
        case failed(String)
    }

    private var root: URL?
    private var store: MessageStore?
    private var encryption: OMEMOService?
    private var account: NotificationAccount?
    private var accountID = ""
    private var previews = false
    private var blocklist = XMPPBlocklist()
    private var uploadService: XMPPUploadService?
    private var filesAccepted: Bool?
    private var roomMembers: [String: [String]] = [:]
    private var preparedFiles: [UUID: PreparedAttachment] = [:]
    private var preparation: Task<Void, Never>?
    private var sendTask: Task<Void, Never>?
    private var session: ShareSession?
    private var sessionTask: Task<[String: ShareItemState], Never>?
    private var closing = false
    private static let log = Logger(subsystem: "haus.xmpp.ios", category: "share")

    #if DEBUG
    static let queueOnlyKey = "debug.shareQueueOnly"
    #endif
    /// How long the iPhone waits for the lease after Send, and how long it may then stay connected.
    static let leaseWait: Duration = .seconds(3)
    static let sendBudget: Duration = .seconds(25)
    /// How long the Mac watches the queued rows for the running app's send.
    static let macWatch: Duration = .seconds(6)

    var files: [SharedItem] { items.filter(\.isFile) }
    var hasFiles: Bool { !files.isEmpty }
    var attachmentLimit: Int { min(AttachmentTransfer.maximumBytes, uploadService?.maximumFileSize ?? AttachmentTransfer.maximumBytes) }
    var listedChats: [ShareRules.Chat] { ShareRules.listed(chats, search: search) }
    var selectedChats: [ShareRules.Chat] { selection.compactMap { id in chats.first { $0.id == id } } }
    var isPreparing: Bool { prepared.values.contains(.preparing) }
    var canSend: Bool {
        phase == .ready && !isPreparing
            && ShareRules.canSend(files: readyFiles.count, unsendableFiles: unsendableFiles.count, text: text, recipients: selection.count)
    }
    /// A file that could not be prepared stays on the review card until the user removes it.
    var hasUnsendableFiles: Bool { !unsendableFiles.isEmpty }
    private var readyFiles: [SharedItem] { files.filter { if case .ready = prepared[$0.id] { true } else { false } } }
    private var unsendableFiles: [SharedItem] { files.filter { if case .failed = prepared[$0.id] { true } else { false } } }

    func unavailableReason(_ chat: ShareRules.Chat) -> String? {
        ShareRules.unavailableReason(chat, hasFiles: hasFiles, filesAccepted: filesAccepted, isBlocked: !chat.isGroup && blocklist.blocks(chat.id))
    }

    var atRecipientLimit: Bool { selection.count >= ShareRules.maximumRecipients }

    func toggle(_ chat: ShareRules.Chat) {
        if let index = selection.firstIndex(of: chat.id) { selection.remove(at: index); return }
        guard unavailableReason(chat) == nil, !atRecipientLimit else { return }
        selection.append(chat.id)
    }

    func remove(_ item: SharedItem) {
        items.removeAll { $0.id == item.id }
        prepared[item.id] = nil
        preparedFiles[item.id] = nil
        if let file = item.file { try? FileManager.default.removeItem(at: file.deletingLastPathComponent()) }
        // A chat that only lacked file support takes the rest.
        selection.removeAll { id in chats.first { $0.id == id }.map { unavailableReason($0) != nil } ?? true }
    }

    // MARK: Loading

    /// Opens what the notification extension opens, the same way: never a migration, never another install's data.
    func load(providers: [NSItemProvider], suggestedConversation: String?) async {
        SharedItemIntake.discardAll()
        do {
            let root = try await SharedStorage.directory(migrate: false)
            let account: NotificationAccount
            switch ShareAuthorization.check(groupRoot: root.deletingLastPathComponent()) {
            case .success(let current): account = current
            case .failure(let refusal): return unavailable(refusal.message)
            }
            let store: MessageStore
            do { store = try MessageStore(url: root.appending(path: "messages.sqlite"), schema: .currentOnly) }
            catch MessageStoreError.upgradeRequired { return unavailable("Open Haus XMPP once to finish updating, then share again.") }
            let key = try EncryptionKeychain.load(storageID: "primary", allowCreation: false)
            let encryption = OMEMOService(store: store, protection: try StateProtection(key: key))
            self.root = root; self.store = store; self.encryption = encryption; self.account = account
            accountID = account.accountID
            previews = try await store.notificationPreviewsEnabled(accountID: accountID)
            blocklist = BlockedAddresses.load(accountID: accountID)
            let uploads = UploadServiceMemory(defaults: SharedSession.groupDefaults ?? .standard)
            uploadService = uploads.load(account: accountID)
            filesAccepted = uploads.hasAnswer(account: accountID) ? uploadService != nil : nil
            roomMembers = (try? await encryption.knownGroupRooms(account: accountID)) ?? [:]
            let stored = try await store.chats(accountID: accountID).filter { $0.id != accountID }
            chats = stored.map { chat in
                ShareRules.Chat(id: chat.id, title: chat.title, isGroup: roomMembers[chat.id] != nil, isPinned: chat.isPinned,
                                avatarHash: chat.avatarHash, lastActivity: chat.lastMessage?.sentAt, encryption: .pending)
            }
        } catch {
            Self.log.error("share could not open storage: \(String(describing: type(of: error)), privacy: .public)")
            return unavailable(ShareAuthorization.Refusal.unreadable.message)
        }
        // The providers are read only by the intake from here on; their callbacks arrive on their own queues.
        nonisolated(unsafe) let providers = providers
        let intake = await SharedItemIntake.load(providers)
        items = intake.items
        skippedFiles = intake.skipped
        unreadableItems = intake.unreadable
        guard !items.isEmpty else { return unavailable("There's nothing here Haus XMPP can send.") }
        text = ShareRules.initialText(from: items)
        if let chat = ShareRules.suggestedChat(conversationIdentifier: suggestedConversation, accountID: accountID, chats: chats),
           unavailableReason(chat) == nil {
            suggested = chat.id
            selection = [chat.id]
        }
        phase = .ready
        startPreparation()
        await loadEncryption()
    }

    private func unavailable(_ message: String) { phase = .unavailable(message) }

    /// The account may still share from this sheet (`ShareAuthorization`); its record is refreshed, so a connection uses
    /// the password saved now. Otherwise the sheet says why and nothing is written.
    private func authorize() -> Bool {
        guard let root else { return false }
        switch ShareAuthorization.check(groupRoot: root.deletingLastPathComponent(), accountID: accountID) {
        case .success(let current):
            account = current
            return true
        case .failure(let refusal):
            unavailable(refusal.message)
            return false
        }
    }

    /// Each chat's stored state, read once per sheet. The encryption state is cached by revision, so this decodes it
    /// once, and nothing is fetched from the network.
    private func loadEncryption() async {
        guard let encryption else { return }
        let account = accountID
        for index in chats.indices {
            let chat = chats[index]
            let knowledge: EncryptionKnowledge
            if chat.isGroup {
                let devices = try? await encryption.cachedGroupDevices(account: account, room: chat.id)
                knowledge = devices.map { .stored(DeviceTrustFacts(GroupChatState(members: roomMembers[chat.id] ?? [], devices: $0), account: account)) } ?? .pending
            } else {
                let overview = try? await encryption.overview(account: account, peer: chat.id)
                knowledge = overview.map { .stored(DeviceTrustFacts($0, peer: chat.id)) } ?? .pending
            }
            let state = ChatCapabilities.derive(isDemo: false, isGroup: chat.isGroup, knowledge: knowledge, reviewPending: false,
                                                groupJoined: true, uploadAvailable: uploadService != nil, sessionReady: false).encryption
            chats[index] = ShareRules.Chat(id: chat.id, title: chat.title, isGroup: chat.isGroup, isPinned: chat.isPinned,
                                           avatarHash: chat.avatarHash, lastActivity: chat.lastActivity, encryption: state)
        }
        // A chat whose state turned out unavailable cannot stay selected.
        selection.removeAll { id in chats.first { $0.id == id }.map { unavailableReason($0) != nil } ?? true }
        if let suggested, !selection.contains(suggested) { self.suggested = nil }
    }

    /// A small decoded avatar for a row, once.
    func loadAvatar(_ chat: ShareRules.Chat) {
        guard avatars[chat.id] == nil, let hash = chat.avatarHash, let root else { return }
        let account = accountID
        Task {
            let image = await Task.detached(priority: .userInitiated) {
                AvatarStore.image(at: AvatarStore.url(root: root, account: account, hash: hash), pixels: 120)
            }.value
            if let image { avatars[chat.id] = PlatformImage(cgImage: image) }
        }
    }

    /// Images and video are re-encoded while the user picks a chat, one at a time, so Send has little left to do and a
    /// file too large for the server says so on the review card first.
    private func startPreparation() {
        for item in files { prepared[item.id] = .preparing }
        let files = files, limit = attachmentLimit
        preparation = Task {
            for item in files {
                guard !Task.isCancelled, let file = item.file else { return }
                do {
                    let ready = try await AttachmentPreparer.prepare(fileURL: file, name: item.name, type: item.type, limit: limit)
                    guard prepared[item.id] != nil else { continue }
                    preparedFiles[item.id] = ready
                    prepared[item.id] = .ready(size: ready.data.count)
                } catch {
                    guard prepared[item.id] != nil else { continue }
                    let reason = if case AttachmentPreparer.Failure.tooLarge = error { "Too large for this server" } else { "Can't be read" }
                    prepared[item.id] = .failed(reason)
                }
            }
        }
    }

    // MARK: Sending

    /// Queues everything for every chosen chat, then sends it (iPhone) or hands it to the running app (Mac). `finish` is
    /// called once nothing of this process's is left running and the sheet may close.
    func send() {
        guard canSend, let store, let encryption, let root, authorize() else { return }
        phase = .sending
        let recipients = selectedChats
        let files = readyFiles.compactMap { item in preparedFiles[item.id] }
        let body = text.trimmingCharacters(in: .whitespacesAndNewlines)
        let account = accountID, limit = attachmentLimit
        let attachmentFiles = AttachmentFiles(directory: root, account: account)
        for chat in recipients { deliveries[chat.id] = .sending }
        sendTask = Task {
            var queued: [String: [String]] = [:]
            var failed: Set<String> = []
            for prepared in files {
                for chat in recipients where !chat.isGroup {
                    do {
                        let message = try await OutgoingEnqueue.file(prepared, account: account, chatID: chat.id, limit: limit,
                                                                     store: store, files: attachmentFiles, encryption: encryption)
                        queued[chat.id, default: []].append(message.id)
                    } catch { failed.insert(chat.id) }
                }
            }
            preparedFiles = [:]
            if !body.isEmpty {
                for chat in recipients {
                    do { queued[chat.id, default: []].append(try await OutgoingEnqueue.text(body, account: account, chatID: chat.id, store: store).id) }
                    catch { failed.insert(chat.id) }
                }
            }
            for chat in recipients where queued[chat.id] == nil { deliveries[chat.id] = .failed }
            guard !queued.isEmpty else { return settle(queued, of: recipients, states: [:], unsaved: failed) }
            donate(to: recipients.filter { queued[$0.id] != nil })
            OutboxRing.ring()
            let states = await deliver(queued, rooms: Set(recipients.filter(\.isGroup).map(\.id)))
            settle(queued, of: recipients, states: states, unsaved: failed)
        }
    }

    /// The iPhone sends while the sheet is up, under the lease, when it is free; the Mac's running app sends. Either
    /// way the rows are already durable, so a lease held elsewhere, a lost connection or a dismissed sheet leaves them
    /// for the app's next connection.
    private func deliver(_ queued: [String: [String]], rooms: Set<String>) async -> [String: ShareItemState] {
        let ids = queued.values.flatMap { $0 }
        #if os(iOS)
        guard let store, let encryption, let root, let account else { return [:] }
        let session = ShareSession(store: store, encryption: encryption, files: AttachmentFiles(directory: root, account: accountID),
                                   account: Self.backgroundAccount(account), uploadService: uploadService)
        self.session = session
        #if DEBUG
        // `-haus-share-queue-only` on the app's last launch: lab runs check that a share queued here sends from the app.
        if SharedSession.groupDefaults?.bool(forKey: ShareModel.queueOnlyKey) == true { return await ShareStateReader(store: store, accountID: accountID).states(ids) }
        #endif
        let activity = ExpiringActivity { [weak self] in self?.cancelSending() }
        defer { activity.end() }
        // Signed out, moved or signed in again with other credentials while the lease was awaited: nothing connects, and
        // the rows wait for that account as the app's own queued messages do.
        guard await session.acquireLease(waitingUpTo: Self.leaseWait), !closing,
              (try? ShareAuthorization.check(groupRoot: root.deletingLastPathComponent(), accountID: accountID).get()) == account else {
            await session.end()
            return await session.states(ids)
        }
        let deadline = ContinuousClock.now + Self.sendBudget
        let task = Task { [weak self] in
            await session.send(messageIDs: ids, rooms: rooms, until: deadline) { states in
                await MainActor.run { self?.show(states, of: queued) }
            }
        }
        sessionTask = task
        let states = await task.value
        await session.end(presentation: presentation())
        return states
        #else
        // The Mac app keeps the lease while it runs and drains when rung; this only reads what it reports.
        guard let session = store.map({ ShareStateReader(store: $0, accountID: accountID) }) else { return [:] }
        let end = ContinuousClock.now + Self.macWatch
        var states = await session.states(ids)
        while states.values.contains(where: { $0 != .sent && $0 != .failed }), ContinuousClock.now < end, !closing {
            show(states, of: queued)
            try? await Task.sleep(for: .milliseconds(300))
            states = await session.states(ids)
        }
        return states
        #endif
    }

    private func show(_ states: [String: ShareItemState], of queued: [String: [String]]) {
        for (chat, ids) in queued {
            deliveries[chat] = ShareRules.delivery(ids.map { states[$0] ?? .queued }, finished: false)
        }
    }

    /// `unsaved`: chats for which an item could not be saved. Its data is gone with the sheet, so the result says to
    /// share it again rather than letting the rest's state stand for it.
    private func settle(_ queued: [String: [String]], of recipients: [ShareRules.Chat], states: [String: ShareItemState], unsaved: Set<String>) {
        let saved = Dictionary(recipients.map { chat in (chat.id, (queued[chat.id] ?? []).map { states[$0] ?? .queued }) },
                               uniquingKeysWith: { first, _ in first })
        (deliveries, outcomeNote) = ShareRules.outcome(saved, unsaved: unsaved)
        phase = .finished
    }

    /// The sheet is going away (Done, the host left, the activity expired): stop sending, end the connection and give
    /// the lease back. The rows stay queued for the app.
    func cancelSending() {
        closing = true
        preparation?.cancel()
        sessionTask?.cancel()
    }

    /// Waits until nothing of this share runs any more, the lease included. Then the sheet may close.
    func close() async {
        cancelSending()
        await sendTask?.value
        await session?.end()
        try? await store?.close()
        store = nil
        SharedItemIntake.discardAll()
    }

    private func donate(to recipients: [ShareRules.Chat]) {
        guard let root, OutgoingDonation.isAllowed(previews: previews, suggestions: ShareSuggestionSetting.isEnabled(accountID: accountID)) else { return }
        let account = accountID
        let titles = Dictionary(chats.map { ($0.id, $0.title) }, uniquingKeysWith: { first, _ in first })
        let conversations = recipients.map { chat in
            SuggestedConversation.outgoing(accountID: account, chatID: chat.id, title: chat.title, avatarHash: chat.avatarHash,
                                           roomMembers: chat.isGroup ? roomMembers[chat.id] ?? [] : nil, titles: titles)
        }
        Task.detached {
            await OutgoingDonation.donate(conversations) { AvatarStore.suggestionImageData(root: root, account: account, hash: $0) }
        }
    }

    #if os(iOS)
    /// What the share's connection received alerts as the notification extension would show it: the server pushes
    /// nothing for a connected session. Bounded, and only for the signed-in account.
    private func presentation() -> (@Sendable (MessageStore) async -> Void)? {
        guard let root, let account else { return nil }
        let accountID = accountID, donates = previews && ShareSuggestionSetting.isEnabled(accountID: accountID)
        let blocklist = blocklist
        return { store in
            let presenter = NotificationPresenter(posting: UserNotificationPoster(donates: donates, avatarData: { hash in
                AvatarStore.notificationImageData(root: root, account: accountID, hash: hash)
            }), addTimeout: .seconds(2), cleanupTimeout: .seconds(1))
            let run = Task {
                try await presenter.present(store: store, accountID: accountID, progress: NotificationRunProgress(), blocklist: blocklist,
                                            authorize: { guard try NotificationAccount.load() == account else { throw CancellationError() } })
            }
            let watchdog = Task { try? await Task.sleep(for: .seconds(3)); run.cancel() }
            _ = await run.result
            watchdog.cancel()
        }
    }

    private static func backgroundAccount(_ account: NotificationAccount) -> BackgroundAccount {
        BackgroundAccount(route: account.route, domain: account.domain, username: account.username, password: account.password,
                          requiresSCRAM: account.requiresSCRAM, resource: SharedSession.resource(accountID: account.accountID),
                          push: PushRegistrationState.sessionSubscription(saved: account.push,
                                                                          state: try? PushRegistrationState.load(accountID: account.accountID)),
                          leftForeground: SharedSession.leftForeground())
    }
    #endif
}

/// Read-only states of queued rows, for the Mac, whose app sends them.
private struct ShareStateReader: Sendable {
    let store: MessageStore
    let accountID: String

    func states(_ ids: [String]) async -> [String: ShareItemState] {
        var result: [String: ShareItemState] = [:]
        for id in ids { result[id] = ShareItemState(try? await store.message(accountID: accountID, messageID: id)) }
        return result
    }
}

#if os(iOS)
/// Asks the system for time to finish (`ProcessInfo.performExpiringActivity`, which extensions may use). When the time
/// runs out, `expired` runs so the share can end its connection and release the lease before the process is suspended.
private final class ExpiringActivity: @unchecked Sendable {
    private let done = DispatchSemaphore(value: 0)

    @MainActor init(expired: @escaping @MainActor () -> Void) {
        let done = done
        ProcessInfo.processInfo.performExpiringActivity(withReason: "Send what was shared") { expiring in
            if expiring {
                Task { @MainActor in expired() }
                return
            }
            // The activity lasts while this background thread waits.
            done.wait()
        }
    }

    func end() { done.signal() }
}
#endif
