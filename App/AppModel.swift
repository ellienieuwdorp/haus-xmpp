import Foundation
import Network
import os
import SwiftUI
import UIKit
import UserNotifications
import Observation
import MessageStore
import XMPPProtocol
import MessagingCore
import OMEMO

struct ChatSummary: Identifiable {
    let id: String
    let title: String
    let preview: String
    let isPinned: Bool
    var avatarHash: String? = nil
    var lastMessageAt: Date? = nil
    var lastMessageIsOutgoing = false
    var lastMessageState: OutgoingTransportState? = nil
    var lastMessageReceipt: MessageEventKind? = nil
    /// Local notification level and mute; never sent to the server.
    var notification = ChatNotificationSetting()
    /// Incoming messages after the chat's read pointer; shown as a count pill in the row.
    var unreadCount = 0
    /// Title for display: the stored title, or the address local part when the title is just the address.
    var displayTitle: String { AppModel.displayName(for: id, title: title) }
}

typealias ChatMessage = StoredMessage

@MainActor @Observable
final class AppModel {
    private(set) var chats: [ChatSummary] = []
    /// The chat list has been read from storage for the current account. Until then the Chats screen shows nothing:
    /// a cold start of a signed-in account must not flash the "no conversations" state before its rows arrive.
    private(set) var hasLoadedChats = false
    private(set) var messages: [ChatMessage] = []
    /// The chat whose messages `messages` currently holds; nil while a load is pending.
    private(set) var messagesLoadedFor: String?
    /// How many of the open chat's newest messages are loaded; scrolling to the top and searching raise it.
    // ponytail: each page re-reads the whole window and search stops at the ceiling; page by cursor and search in the store when chats outgrow it.
    @ObservationIgnored private var timelineWindow = AppModel.timelinePage
    @ObservationIgnored private var loadingOlder = false
    private static let timelinePage = 100, timelineCeiling = 1000
    /// Archive pages (100 messages each) one reach-top asks the server for, and the one idle backfill after catch-up.
    private static let backfillPagesPerScroll = 5, opportunisticBackfillPages = 3
    /// Newest pages of recently seen chats, so pushing one shows its tail in the first frame. In memory, one account.
    @ObservationIgnored private var timelinePages = TimelinePageCache()
    @ObservationIgnored private var prefetchingPages = false
    private(set) var messageReactions: [String: [AuthenticatedReaction]] = [:]
    /// The peer's strongest receipt per own message in the open chat: delivered or displayed.
    private(set) var messageReceipts: [String: MessageEventKind] = [:]
    private(set) var accountPreferences = AccountPreferences()
    private(set) var groupChats: [String: GroupChatState] = [:]
    /// Chat → who is typing there (XEP-0085). In memory only; it expires on its own.
    private(set) var typing: [String: [String]] = [:] { didSet { syncOpenChatTyping() } }
    /// The open chat's entry in `typing`, observed on its own so typing in another chat never re-renders the conversation.
    private(set) var openChatTyping: [String]?
    /// The open 1:1 chat's contact activity for the header subtitle; nil when unknown. In memory only, cleared whenever
    /// the open chat changes.
    private(set) var openChatLastSeen: LastSeen?
    /// Contacts' presence, the roster and the subscription policy. In memory only, never stored.
    @ObservationIgnored private var lastSeenTracker = LastSeenTracker()
    @ObservationIgnored private var typingTracker = TypingTracker()
    @ObservationIgnored private var typingExpiry: Task<Void, Never>?
    /// What we last told the open chat's peer about our own typing.
    @ObservationIgnored private var ownTyping: (chat: String, sender: TypingSender)?
    @ObservationIgnored private var ownTypingPause: Task<Void, Never>?
    @ObservationIgnored private var ownTypingSend: Task<Void, Never>?
    private(set) var reactableGroupMessages: Set<String> = []
    /// Verified avatar thumbnails by chat address, plus the account's own under its address.
    private(set) var avatars: [String: UIImage] = [:]
    /// Addresses whose avatar was checked on this session; a PEP notify clears its entry.
    @ObservationIgnored private var avatarChecked: Set<String> = []
    @ObservationIgnored private var storageRoot: URL?
    /// Where this launch stands with the previous version's data (docs/development/pre-upgrade-snapshot.md). Anything
    /// but `.none` replaces the app with a blocking screen and keeps storage closed.
    private(set) var upgradeState: UpgradeState = .none
    /// The snapshot of the previous version's data, while one exists: Settings offers restoring or deleting it.
    private(set) var previousVersionBackup: PreUpgradeSnapshot.Manifest?
    /// A backup folder is there but its manifest cannot be read: Settings offers only deleting it.
    private(set) var previousVersionBackupUnreadable = false
    /// A restore owns the store's lease until it closes the store; a background transition meanwhile must not release it.
    @ObservationIgnored private var restoringData = false
    @ObservationIgnored private var snapshots: PreUpgradeSnapshot?
    @ObservationIgnored private var openingStorage = false
    private(set) var accountID = "" {
        didSet {
            if accountID != oldValue {
                timelinePages.removeAll()
                pushWanted = accountID.isEmpty || !preferences.bool(forKey: "pushOff." + accountID)
                pushStatus = .off
            }
            ForegroundNotificationState.shared.accountID = isDemo ? "" : accountID
        }
    }
    /// The only connection state views read. Chat trust is derived from stored devices, not from this.
    private(set) var session: SessionState = .offline(reason: nil)
    var isConnected: Bool { session.isConnected }
    var encryptionReady: Bool { session.isReady }
    /// The reconciler is working towards a usable session; the Chats bar shows a small spinner.
    var isSettlingConnection: Bool { wantsConnection && !session.isReady && !connectionNeedsAttention }
    var connectionNeedsAttention: Bool { if case .needsAttention = session { true } else { false } }
    /// Set when saved credentials were rejected; RootView presents the sign-in sheet.
    var signInRequested = false
    /// Chat Details asks the conversation below it to open search or starred after popping back.
    var conversationIntent: ConversationIntent?
    private(set) var isSending = false
    private(set) var receivedCount = 0
    var error: String?
    private(set) var pushStatus = PushStatus.off
    /// False once push was turned off in Settings for this account (kept per account, on this installation).
    private(set) var pushWanted = true
    /// Bumped by every turn on/off in Settings, so a setup still in flight cannot enable what was just turned off.
    @ObservationIgnored private var pushIntent = 0
    /// The push setup after sign-in or a Settings tap (`reconcilePush`), off the sign-in path. Each one waits for the
    /// previous, so two never generate or register at once; resetSession cancels it and forgetAccount joins it.
    @ObservationIgnored private var pushTask: Task<Void, Never>?
    private(set) var notificationRoute: NotificationChatRoute?
    /// A push onto the Chats stack asked for by a view that owns no navigation path (a bubble's
    /// "Encryption details" action). RootView appends it and clears it.
    var requestedRoute: ChatRoute?
    @ObservationIgnored private var sessionAccount: NotificationAccount?
    @ObservationIgnored private var lifecycleTask: Task<Void, Never>?
    @ObservationIgnored private var foreground = true
    @ObservationIgnored private var quiescing = false
    /// The icon badge last set by the app; nil after a lifecycle change, so the next load sets it whatever it holds.
    @ObservationIgnored private var appBadge: Int?
    @ObservationIgnored private var activeEncryptionOperations = 0
    @ObservationIgnored private var acquiringOwnership = false
    @ObservationIgnored private var hasTransportOwnership = false
    @ObservationIgnored private var reconnectTask: Task<Void, Never>?
    @ObservationIgnored private var reconnectAttempt = 0
    @ObservationIgnored private var userWantsOffline = false
    @ObservationIgnored private var authenticationRejected = false
    @ObservationIgnored private var reportedSetupFailure: String?
    @ObservationIgnored private let pathMonitor = NWPathMonitor()
    /// The chat the encryption projection describes. Set as a chat opens, before its store read returns, and kept
    /// across pop-back, disconnect and reconnect; only another chat or account replaces it.
    private(set) var encryptionOverviewChatID: String?
    /// That chat's stored (then refreshed) devices; nil until the store answered. Views read `encryptionOverview(for:)`.
    private(set) var encryptionOverview: EncryptionOverview?
    /// Encryption problems: the Devices footer, sends held for a fingerprint decision, and group refresh failures.
    private(set) var encryptionAttention = EncryptionAttention()
    /// What the last device refresh saw on the server, and any refresh or decryption problem, for the Devices screen footer.
    var encryptionDiagnostics: String { encryptionAttention.diagnostics }
    /// The chat whose devices were re-fetched on which connection generation, with that refresh's footer line.
    /// Opening a chat or popping back reuses it; a reconnect (new generation) fetches once more.
    @ObservationIgnored private var refreshFence: [String: (generation: UUID, note: String)] = [:]
    /// The open chat's encryption in words, derived from stored devices. Read-only: problems are written to
    /// `encryptionAttention`, so a transient problem never rewrites the pill or re-shows a dismissed review card.
    var encryptionStatus: String { encryptionOverviewChatID.map { trustSummary(for: $0).subtitle } ?? "" }
    /// The open chat needs a fingerprint decision: stored undecided devices, retained ciphertext, or a send held for trust.
    var encryptionNeedsReview: Bool { encryptionOverviewChatID.map { chatCapabilities($0).encryption == .needsReview } ?? false }
    /// The open chat holds messages sent in the other OMEMO version from a device waiting for a fingerprint decision.
    /// Sending is not affected, so this only asks for a review; it never pauses the composer.
    var encryptionIncomingReview: Bool {
        guard let chat = encryptionOverviewChatID, !isGroup(chat) else { return false }
        return encryptionOverview(for: chat)?.needsIncomingReview ?? false
    }
    @ObservationIgnored private var encryption: OMEMOService?
    var isDemo: Bool { accountID == "preview.local" }

    @ObservationIgnored private var store: MessageStore?
    @ObservationIgnored private var outboxSender: OutboxSender?
    @ObservationIgnored private var outboxRequested = false
    @ObservationIgnored private var drainTask: Task<Void, Never>?
    /// One connection's setup after `.online` (`ConnectionSetup`), off the event loop; joined like `drainTask`.
    @ObservationIgnored private var setupTask: Task<Void, Never>?
    /// Non-nil while a connection's archive walk runs after `.ready`; the Chats bar keeps its spinner.
    private(set) var catchUp: CatchUpProgress?
    var isCatchingUp: Bool { catchUp != nil }
    /// Numbers-only timings of the current connection's setup, for the lab measurement.
    private static let syncLog = Logger(subsystem: "haus.xmpp.ios", category: "sync")
    @ObservationIgnored private var onlineAt: ContinuousClock.Instant?
    @ObservationIgnored private var firstMessageLogged = false
    @ObservationIgnored private var liveStoredLogged = false
    @ObservationIgnored private var catchUpByArchive: [String: CatchUpProgress] = [:]
    /// Older archive history for one archive (`ArchiveSynchronizer.backfill`); joined like `setupTask`.
    @ObservationIgnored private var backfillTask: Task<Void, Never>?
    /// The archive (account or room JID) a backfill is fetching right now; the open chat shows its header.
    private(set) var backfillingArchive: String?
    /// Per connection: the idle backfill after catch-up runs at most once.
    @ObservationIgnored private var opportunisticBackfillDone = false
    /// Per connection: this connection's forward walk has finished, so the single archive query is free.
    @ObservationIgnored private var archiveWalkFinished = false
    /// Per connection: archives (account or room JID) with nothing more to backfill, or whose server refused, so a
    /// reach-top, which fires on every scroll frame near the top, does not ask again.
    @ObservationIgnored private var backfillSettled: Set<String> = []
    /// A reach-top does not start the next backfill run before this instant: one gesture is one request.
    @ObservationIgnored private var backfillResumesAt: ContinuousClock.Instant?
    @ObservationIgnored private var client: XMPPClient?
    @ObservationIgnored private var eventTask: Task<Void, Never>?
    @ObservationIgnored private var openChatID: String? {
        didSet { syncOpenChatTyping(); syncOpenChatLastSeen(); ForegroundNotificationState.shared.openChatID = openChatID }
    }
    @ObservationIgnored private var encryptionDetailsChatID: String?
    /// The chat whose Devices footer a held send's reason belongs to: the open conversation, or the chat whose
    /// details pages cover it.
    private var encryptionShownChatID: String? { openChatID ?? encryptionOverviewChatID }
    @ObservationIgnored private var generation = UUID()
    /// `prepare()` runs once; a notification action on a background launch joins it.
    @ObservationIgnored private var preparation: Task<Void, Never>?
    @ObservationIgnored private var backgroundLaunchObserver: (any NSObjectProtocol)?
    /// Notification permission as last read; foreground banners are posted only with it.
    @ObservationIgnored private var mayPostNotifications = false
    /// The transport a Reply or Mark as Read took; nil when no action runs.
    @ObservationIgnored private var actionSession: NotificationActionSession?
    /// Finished outbox passes, so an action can tell that a pass ran after its reply was queued.
    @ObservationIgnored private var drainPasses = 0
    @ObservationIgnored private var pushTokenTask: Task<Void, Never>?
    @ObservationIgnored private var notificationTapTask: Task<Void, Never>?
    /// Owns the durable-disposition rule for the current stream; replaced with the client.
    @ObservationIgnored private var inbound: InboundProcessor?
    /// One XEP-0490 publication run at a time; a read made meanwhile asks for one more.
    @ObservationIgnored private var publishingReadState = false
    @ObservationIgnored private var readStateChangedWhilePublishing = false
    /// Local plaintext files of the open chat's attachments, by message ID, once downloaded or sent.
    private(set) var attachmentFiles: [String: URL] = [:]
    /// The account's upload service as last discovered; persisted per account so the attach button survives launch
    /// and reconnect. Observed: the composer's attach button follows it.
    private var uploadService: XMPPUploadService?
    private var uploads: UploadServiceMemory { UploadServiceMemory(defaults: preferences) }
    private var files: AttachmentFiles? { storageDirectory.map { AttachmentFiles(directory: $0, account: accountID) } }
    @ObservationIgnored private var uploader: AttachmentUploader?
    @ObservationIgnored private var storageDirectory: URL?
    @ObservationIgnored private var uploadTask: Task<Void, Never>?
    @ObservationIgnored private var uploadFailures = UploadFailureBudget()
    @ObservationIgnored private var downloading: Set<String> = []
    /// Bytes a chosen file may have before it is refused; the server's limit when it publishes one.
    var attachmentLimit: Int { min(AttachmentTransfer.maximumBytes, uploadService?.maximumFileSize ?? AttachmentTransfer.maximumBytes) }
    /// The server offered uploads on its last completed discovery. Never gated on the socket: a file is sealed and
    /// queued offline, and its upload starts once the session is ready.
    var canSendAttachments: Bool { isDemo || uploadService != nil }
    @ObservationIgnored private let testSessionID: String? = {
        #if DEBUG
        guard let value = ProcessInfo.processInfo.environment["XMPP_UI_TEST_STORE"],
              let id = UUID(uuidString: value) else { return nil }
        return id.uuidString
        #else
        return nil
        #endif
    }()
    @ObservationIgnored private lazy var preferences: UserDefaults = {
        guard let testSessionID else { return .standard }
        return UserDefaults(suiteName: "haus.xmpp.uitest." + testSessionID) ?? .standard
    }()
    /// Where the resource and the last foreground time live: the App Group, which the extension reads too.
    @ObservationIgnored private lazy var sessionDefaults: UserDefaults? = testSessionID == nil ? SharedSession.groupDefaults : preferences

    init() {
        // The saved account is known before storage opens, so the first frame already carries the account avatar
        // and the Chats stack is not rebuilt (its identity is the account) once `prepare()` reads the same value.
        // Read in normal form but not rewritten: preferences change only after the pre-upgrade snapshot (`openStorage`).
        accountID = preferences.string(forKey: "lastAccount").map { JID.normalizedBare($0) ?? $0 } ?? ""
        NotificationActionCenter.shared.handler = { [weak self] request, budget in
            await self?.performNotificationAction(request, budget: budget) ?? .rejected
        }
        NotificationActionCenter.shared.abort = { [weak self] in self?.abortNotificationAction() ?? false }
    }

    /// Opens storage and the saved account once. Every caller (the root view, a notification action on a background
    /// launch) returns only after it finished.
    func prepare() async {
        if let preparation { await preparation.value; return }
        let task = Task { await prepareOnce() }
        preparation = task
        await task.value
    }

    private func prepareOnce() async {
        // A launch into the background (a notification action) must not connect: the scene is not in front. Its
        // first activation then counts as a return to the foreground even if the scene phase was never seen to change.
        if UIApplication.shared.applicationState == .background {
            foreground = false
            backgroundLaunchObserver = NotificationCenter.default.addObserver(forName: UIApplication.didBecomeActiveNotification,
                                                                              object: nil, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated {
                    guard let self else { return }
                    if let observer = self.backgroundLaunchObserver { NotificationCenter.default.removeObserver(observer) }
                    self.backgroundLaunchObserver = nil
                    if !self.foreground { self.setForeground(true) }
                }
            }
        }
        refreshNotificationPermission()
        if testSessionID == nil {
            let tokens = PushRegistration.unsolicitedTokens()
            pushTokenTask = Task { [weak self] in
                for await token in tokens {
                    guard !Task.isCancelled else { return }
                    await self?.receivePushToken(token)
                }
            }
        }
        pathMonitor.pathUpdateHandler = { [weak self] path in
            guard path.status == .satisfied else { return }
            Task { @MainActor in self?.networkBecameReachable() }
        }
        pathMonitor.start(queue: .global(qos: .utility))
        await openStorage()
    }

    /// Opens storage and the saved account. Before anything the previous build wrote is migrated or rewritten, the
    /// snapshot of it is taken; while that is not possible (a launch into the background, the lease held elsewhere, a
    /// failed snapshot, restored data waiting for the previous build) storage stays closed and nothing connects.
    private func openStorage(withoutSnapshot: Bool = false) async {
        guard store == nil, !openingStorage else { return }
        openingStorage = true
        defer { openingStorage = false }
        do {
            let directory = try await SharedStorage.directory(testSessionID: testSessionID, migrate: true)
            storageRoot = directory
            let opened: MessageStore
            if testSessionID == nil {
                // Never opened any other way: a plain open would migrate without the snapshot.
                guard let locations = PreUpgradeSnapshot.Locations.production(messaging: directory) else { throw CocoaError(.fileReadNoPermission) }
                let snapshots = PreUpgradeSnapshot(locations: locations)
                self.snapshots = snapshots
                if upgradeState != .restoring { upgradeState = .preparing }
                // Rewrites the previous build's spellings (preferences, folders, push registrations) only once `ready`.
                let opening = try await snapshots.open(upgradeAllowed: UIApplication.shared.applicationState != .background,
                                                       withoutSnapshot: withoutSnapshot, now: Date())
                readBackupStatus()
                switch opening {
                case .ready(let store): opened = store
                case .restored(let restored): upgradeState = .restored(restored); return
                case .busy: upgradeState = .waitingForLease; retryOpeningStorage(); return
                case .deferred: upgradeState = .deferred; return
                case .snapshotFailed(let reason):
                    Self.syncLog.error("pre-upgrade snapshot failed: \(reason, privacy: .public)")
                    upgradeState = .snapshotFailed(reason); return
                }
                if let backup = previousVersionBackup {
                    Self.syncLog.notice("pre-upgrade snapshot present: taken \(backup.takenAt, privacy: .public) schema \(backup.database.schemaVersion, privacy: .public)")
                }
                upgradeState = .none
            } else {
                // A UI test session's own store and preferences: nothing a previous build left.
                opened = try MessageStore(url: directory.appending(path: "messages.sqlite"))
                AccountIdentityMigration.migratePreferences(preferences)
                AccountIdentityMigration.moveFiles(directory: directory, defaults: preferences)
            }
            store = opened
            storageDirectory = directory
            let uploader = AttachmentUploader(scope: testSessionID ?? "primary")
            uploader.onFinish = { [weak self] taskID, succeeded in Task { @MainActor in await self?.uploadFinished(taskID: taskID, succeeded: succeeded) } }
            self.uploader = uploader
            if let store {
                outboxSender = OutboxSender(store: store)
                let allowCreation = try await !store.hasAnyEncryptionState()
                let wrappingKey = try EncryptionKeychain.load(storageID: testSessionID ?? "primary", allowCreation: allowCreation)
                encryption = OMEMOService(store: store, protection: try StateProtection(key: wrappingKey))
            }
            accountID = preferences.string(forKey: "lastAccount") ?? ""
            uploadService = uploads.load(account: accountID)
            if ProcessInfo.processInfo.arguments.contains("-demo") { await loadDemo() }
            else {
                if let store, try await NotificationDiagnostics.exportIfRequested(store: store, directory: directory) {
                    pushStatus = .inspected
                    return
                }
                await refresh()
                if let openChatID { await loadEncryptionDetails(for: openChatID, refreshFromServer: false) }
                if testSessionID == nil, let saved = try NotificationAccount.load() {
                    sessionAccount = saved
                    if saved.push != nil { pushStatus = .on }
                    reconcile()
                    await queueSavedReplies()
                }
            }
        } catch {
            if upgradeState != .none { upgradeState = .none }
            self.error = "Could not open local message storage."
            hasLoadedChats = true // nothing more will arrive; show the empty state behind the alert rather than a blank screen
        }
    }

    func loadDemo() async {
        await forgetAccount()
        let token = generation
        let account = "preview.local"
        selectAccount(account)
        guard generation == token, let store else { return }
        do {
            // Each chat's sent messages show one receipt state: read (Alex, whose last message is sent so the list shows it too), delivered (Maya), accepted (Notes).
            let samples: [(String, String, [String], MessageEventKind?)] = [
                ("alex@preview.local", "Alex", ["Found a quiet spot by the water. Coffee tomorrow?", "That sounds perfect. Around ten?", "Ten it is ☕️", "See you there!"], .displayed),
                ("maya@preview.local", "Maya", ["A little reminder to take the scenic route.", "Always. See you this weekend!"], .delivered),
                ("notes@preview.local", "Notes to self", ["A place for the things worth keeping. Try starring this message.", "Starred things stay at the top of the list."], nil)
            ]
            for (chatID, title, bodies, receipt) in samples {
                try await store.upsertChat(accountID: account, chatID: chatID, title: title)
                for (index, body) in bodies.enumerated() {
                    let outgoing = !index.isMultiple(of: 2)
                    // An own wire ID lets sample messages show receipts and be unsent or edited (projection only, nothing is sent).
                    let id = "sample-\(chatID)-\(index)"
                    try await store.insertMessage(StoredMessage(
                        id: id, accountID: account, chatID: chatID,
                        senderID: outgoing ? account : chatID, body: body,
                        sentAt: Date(timeIntervalSince1970: 1_789_380_000 + Double(index)), isOutgoing: outgoing, wireID: outgoing ? id : nil
                    ))
                    if outgoing, let receipt {
                        try await store.recordReceipt(accountID: account, event: MessageEvent(id: id + "-receipt", chatID: chatID, actorID: chatID, targetWireID: id,
                                                                                            kind: receipt, payload: "{}", updatedAt: Date(timeIntervalSince1970: 1_789_380_010)))
                    }
                }
            }
            // Long enough to cross several timeline pages; only tests and scroll checks ask for it.
            if ProcessInfo.processInfo.arguments.contains("-demo-long") {
                let chatID = "history@preview.local"
                try await store.upsertChat(accountID: account, chatID: chatID, title: "History")
                for index in 1...250 {
                    try await store.insertMessage(StoredMessage(id: "sample-history-\(index)", accountID: account, chatID: chatID, senderID: index.isMultiple(of: 3) ? account : chatID,
                                                                body: "History message \(index)" + (index.isMultiple(of: 7) ? ", with a second sentence so some bubbles wrap onto another line." : ""),
                                                                sentAt: Date(timeIntervalSince1970: 1_789_300_000 + Double(index) * 60), isOutgoing: index.isMultiple(of: 3)))
                }
            }
            // Two placeholders in Alex's chat, for tests and screenshots: an own send from another device that did
            // not encrypt for this one, and an incoming message that could not be read. Recorded exactly as the
            // receive path records them, so they are never content, never reactable and never counted.
            if ProcessInfo.processInfo.arguments.contains("-demo-unreadable") {
                try await store.recordUnreadableMessage(UnreadableMessage(accountID: account, chatID: "alex@preview.local", senderID: account, isOutgoing: true,
                    sentAt: Date(timeIntervalSince1970: 1_789_380_004), reason: .notForThisDevice, key: .archive(archive: account, id: "sample-unreadable-1")))
                try await store.recordUnreadableMessage(UnreadableMessage(accountID: account, chatID: "alex@preview.local", senderID: "alex@preview.local", isOutgoing: false,
                    sentAt: Date(timeIntervalSince1970: 1_789_380_005), reason: .decryptFailed, key: .archive(archive: account, id: "sample-unreadable-2")))
            }
            // One muted chat, so the list's muted glyph shows in sample captures.
            try await store.setChatNotificationSetting(accountID: account, chatID: "maya@preview.local", ChatNotificationSetting(mutedUntil: ChatNotificationSetting.always))
            // A peer who is typing, for tests and screenshots; nothing expires it.
            if ProcessInfo.processInfo.arguments.contains("-demo-typing") { typing = ["alex@preview.local": ["alex@preview.local"]] }
            // One sample photo, drawn here so no asset ships: exercises the bubble thumbnail and the viewer.
            if let files {
                let size = CGSize(width: 1200, height: 900)
                let photo = UIGraphicsImageRenderer(size: size).jpegData(withCompressionQuality: 0.8) { context in
                    let colors = [UIColor.systemTeal.cgColor, UIColor.systemIndigo.cgColor] as CFArray
                    guard let gradient = CGGradient(colorsSpace: nil, colors: colors, locations: nil) else { return }
                    context.cgContext.drawLinearGradient(gradient, start: .zero, end: CGPoint(x: size.width, y: size.height), options: [])
                }
                let attachment = StoredAttachment(name: "waterfront.jpg", mediaType: "image/jpeg", size: photo.count, width: 1200, height: 900,
                                                  hash: Data.sha256(photo).hexString, secret: Data([0])) // never opened: the file is already cached
                try files.write(photo, to: files.cacheURL(attachment, messageID: "sample-photo"))
                try await store.insertMessage(StoredMessage(id: "sample-photo", accountID: account, chatID: "alex@preview.local", senderID: "alex@preview.local", body: "",
                                                            sentAt: Date(timeIntervalSince1970: 1_789_380_000.5), isOutgoing: false, attachment: attachment))
            }
            // Sample history is read history; only `-demo-unread` leaves something new, for screenshots of the count pill.
            for chat in try await store.chats(accountID: account) { try await store.markChatRead(accountID: account, chatID: chat.id) }
            if ProcessInfo.processInfo.arguments.contains("-demo-unread") {
                let unread = [("maya@preview.local", "Also, bring the map 🗺️"), ("maya@preview.local", "The trail opens at nine."), ("alex@preview.local", "Bringing pastries 🥐")]
                for (index, (chatID, body)) in unread.enumerated() {
                    try await store.insertMessage(StoredMessage(id: "sample-unread-\(index)", accountID: account, chatID: chatID, senderID: chatID, body: body,
                                                                sentAt: Date(timeIntervalSince1970: 1_789_380_100 + Double(index)), isOutgoing: false))
                }
            }
            guard generation == token else { return }
            await refresh()
        } catch { if generation == token { self.error = "Could not load sample conversations." } }
    }

    /// Domains served by the development lab; they keep the disposable-account safeguards.
    static let labDomains: Set<String> = ["localhost", "staging.example.net"]
    var accountDomain: String { accountID.split(separator: "@", maxSplits: 1).last.map(String.init) ?? DevelopmentEndpoint.domain }
    var isLabAccount: Bool { Self.labDomains.contains(accountDomain) }

    /// `address` is a lab username or a full `name@domain`. Without `server` the domain's SRV records choose the endpoint
    /// (lab domains keep their direct-TLS endpoint on 5223); with one, only that endpoint is used.
    func connect(username address: String, password: String, server: XMPPEndpoint? = nil, savedEndpoint: NotificationAccount? = nil) async -> Bool {
        let parts = address.trimmingCharacters(in: .whitespacesAndNewlines).split(separator: "@", maxSplits: 1).map(String.init)
        // One spelling for the account from here on (RFC 7622 normal form): the bound JID, every key and comparison.
        let username = parts.first.flatMap(JID.normalizedLocalpart) ?? ""
        let requestedDomain = savedEndpoint?.domain ?? (parts.count == 2 ? JID.normalizedDomainpart(parts[1]) ?? "" : DevelopmentEndpoint.domain)
        let localPattern = parts.count == 2 ? #"^[^@/\s]{1,64}$"# : #"^[a-z0-9][a-z0-9._-]{0,63}$"#
        let domainPattern = #"^(localhost|[a-z0-9]([a-z0-9-]{0,61}[a-z0-9])?(\.[a-z0-9]([a-z0-9-]{0,61}[a-z0-9])?)+)$"#
        guard foreground, !quiescing, !session.isConnecting else { return false }
        guard username.range(of: localPattern, options: .regularExpression) != nil,
              requestedDomain.range(of: domainPattern, options: .regularExpression) != nil else {
            error = "Enter an address such as name@example.org."
            return false
        }
        let manual = savedEndpoint == nil
        if manual { userWantsOffline = false; authenticationRejected = false; reconnectAttempt = 0 }
        let fixedEndpoint = server ?? (Self.labDomains.contains(requestedDomain)
            ? XMPPEndpoint(host: requestedDomain == "localhost" ? DevelopmentEndpoint.host : requestedDomain, port: 5223, security: .directTLS) : nil)
        if let sessionAccount, sessionAccount.accountID != username + "@" + requestedDomain {
            await forgetAccount()
            guard foreground, !quiescing else { return false }
        }
        let priorEvents = eventTask
        let priorSetup = setupTask
        let priorBackfill = backfillTask
        let previous = resetSession()
        let token = generation
        session = .connecting(step: "Connecting…")
        let connection = XMPPClient(labCertificateAuthority: DevelopmentEndpoint.certificateAuthority)
        client = connection
        // Assign account before consuming events; scoped refresh rejects stale results.
        // A discovered endpoint is unknown until the first connection succeeds; the record is saved only after that.
        let endpoint = savedEndpoint ?? Self.retainingSavedState(previous: sessionAccount, replacement: NotificationAccount(accountID: username + "@" + requestedDomain,
            host: fixedEndpoint?.host ?? "", port: fixedEndpoint?.port ?? 0, security: fixedEndpoint?.security ?? .directTLS,
            discoversEndpoint: fixedEndpoint == nil, domain: requestedDomain, username: username, password: password, push: nil))
        let account = endpoint.accountID
        sessionAccount = endpoint
        selectAccount(account)
        await previous?.disconnectAndWait()
        await priorEvents?.value
        await priorSetup?.value
        await priorBackfill?.value
        if backfillTask == priorBackfill { backfillTask = nil }
        await drainTask?.value
        guard generation == token else { return false }
        await refresh()
        guard generation == token else { return false }
        startNotificationNavigation()
        eventTask = Task { [weak self] in
            for await event in connection.events {
                guard let self, self.generation == token else { break }
                await self.handle(event, token: token)
            }
            // A full buffer drops the client's disconnect event and finishes the stream instead; without
            // this the session would stay "connected" with nothing left to reconnect it.
            guard let self, self.generation == token else { return }
            await self.handle(.state(.disconnected("Event consumer could not keep up")), token: token)
        }
        do {
            guard let store, let encryption else { throw MessageStoreError.invalidValue }
            try await acquireForegroundOwnership(store, token: token)
            await dismissOpenChatNotifications(store: store, account: account)
            try await store.recoverInterruptedSubmissions(accountID: account)
            guard generation == token else { return false }
            try await connection.configureStreamManagement(persistence: StreamPersistence(store: store, accountID: account, encryption: encryption))
            try await connection.configureResource(SharedSession.resource(accountID: account, defaults: sessionDefaults))
            guard generation == token else { return false }
            let connectedSession = try await connection.connect(route: endpoint.route, domain: endpoint.domain, username: username,
                                                                password: password, requireSCRAM: endpoint.requiresSCRAM)
            guard generation == token, accountID == endpoint.accountID, let current = sessionAccount,
                  current.accountID == endpoint.accountID else { await connection.disconnect(); return false }
            // Authentication has succeeded. Only now may a manually entered password replace saved credentials, so the
            // next launch and every reconnect can sign in unattended, first through the endpoint that just worked.
            let connected = current.connected(connectedSession)
            sessionAccount = connected
            do { try connected.save() }
            catch {
                self.error = "Connected, but the password could not be saved. You will be asked for it on the next launch."
            }
            // `.online` was emitted before `connect` returned, so this runs alongside the setup task. Not awaited: the
            // sign-in sheet closes now, and the permission prompt, APNs and the gateway round trips follow on their own.
            startPushSetup(client: connection, session: connected, token: token, interactive: manual)
            return true
        } catch {
            guard generation == token else { await connection.disconnect(); return false }
            let message = Self.failureMessage(for: error)
            session = .offline(reason: message)
            // A server that signs in another account is not retried either: the entered address needs a look.
            if Self.isAuthenticationFailure(error) || error is XMPPIdentityError {
                authenticationRejected = true
                signInRequested = true
            }
            if manual { self.error = message }
            reconcile()
            return false
        }
    }

    nonisolated static func isAuthenticationFailure(_ error: any Error) -> Bool {
        switch error as? XMPPClientError {
        case .authenticationFailed, .authenticationUnavailable, .authenticationDowngrade: true
        default: false
        }
    }

    nonisolated static func failureMessage(for error: any Error) -> String {
        switch error {
        case XMPPClientError.authenticationFailed: "The password was not accepted."
        case XMPPClientError.authenticationUnavailable: "The server does not offer a sign-in method this app supports."
        case XMPPClientError.authenticationDowngrade:
            "The server no longer offers SCRAM sign-in, which this account used before, so the password was not sent. Sign out and in again only if the server’s operator made this change."
        case XMPPClientError.authenticationRetryable: "The server could not check the password right now."
        case XMPPClientError.encryptionUnavailable: "The server did not offer an encrypted connection."
        case XMPPClientError.serviceNotOffered: "This domain does not offer XMPP service."
        case XMPPClientError.unexpectedProtocol: "The server sent a reply this app cannot accept."
        case XMPPClientError.timedOut: "The server did not respond."
        case MessageStoreError.transportOwnedElsewhere: "Another process is still using this account’s storage. Try again in a moment."
        case is CancellationError: "Connection cancelled."
        case XMPPIdentityError.boundAccountMismatch: "The server signed in a different account than the one entered."
        default: "Could not reach the server."
        }
    }

    /// Reconnect delay for the given consecutive failure count: immediate, then 1, 2, 4 … 60 s with jitter.
    nonisolated static func reconnectDelay(attempt: Int) -> Duration {
        guard attempt > 0 else { return .zero }
        let base = min(60.0, pow(2.0, Double(attempt - 1)))
        return .seconds(base * Double.random(in: 1.0...1.25))
    }

    /// Desired state: connected whenever the app is in front with an account whose password still works.
    private var wantsConnection: Bool {
        foreground && !quiescing && !userWantsOffline && !authenticationRejected && sessionAccount != nil && !isDemo && upgradeState == .none
    }

    /// The single place that turns "should be connected" into a `connect()` call. Every input
    /// change (scene, network path, sign-in, disconnect) only updates state and calls this.
    private func reconcile() {
        guard wantsConnection, session.isConnectable, reconnectTask == nil, let saved = sessionAccount else { return }
        let delay = Self.reconnectDelay(attempt: reconnectAttempt)
        reconnectTask = Task { [weak self] in
            try? await Task.sleep(for: delay)
            guard let self, !Task.isCancelled else { return }
            await self.lifecycleTask?.value
            self.reconnectTask = nil
            guard self.wantsConnection, self.session.isConnectable, self.sessionAccount == saved else { return }
            self.reconnectAttempt += 1
            _ = await self.connect(username: saved.username, password: saved.password, savedEndpoint: saved)
        }
    }

    private func networkBecameReachable() {
        guard wantsConnection, session.isConnectable else { return }
        reconnectAttempt = 0
        reconnectTask?.cancel(); reconnectTask = nil
        reconcile()
    }

    /// Disconnect and forget the selected account so the app returns to its signed-out state.
    func signOut() async {
        let account = accountID
        await forgetAccount()
        // Replies saved before the upgrade for this account are not sent after it signed out.
        if !account.isEmpty { try? snapshots?.removeSavedReplies(of: account) }
        uploads.forget(account: account)
        selectAccount("")
        preferences.removeObject(forKey: "lastAccount")
    }

    /// Go offline until the next sign-in; credentials stay so the next launch reconnects.
    func disconnect() async {
        userWantsOffline = true
        reconnectTask?.cancel(); reconnectTask = nil
        await quiesceTransport()
    }

    /// Erase credentials and the push subscription for the current account.
    private func forgetAccount() async {
        quiescing = true
        generation = UUID() // Invalidate pending permission/registration before removing credentials.
        let token = generation
        let account = accountID
        let enabled = testSessionID == nil ? sessionAccount?.push : nil
        let connection = client
        var localFailure: String?
        if testSessionID == nil {
            do { try NotificationAccount.remove() }
            catch NotificationAccount.Failure.credentialsRemain(backgroundDisabled: true) {
                localFailure = "Background access is disabled, but saved credentials could not be erased. Try signing out again."
            } catch {
                localFailure = "Background credentials could not be safely removed. Please retry signing out."
            }
            UNUserNotificationCenter.current().removeAllDeliveredNotifications()
            UNUserNotificationCenter.current().removeAllPendingNotificationRequests()
            appBadge = nil
            setAppBadge(0)
            // Donated communication interactions name this account's contacts, rooms and avatars: they go with it.
            await CommunicationHistory.deleteAll()
        }
        sessionAccount = nil
        pushStatus = .off
        // A setup in flight stops at its next generation check; wait for it so its register or enable cannot land
        // after this revocation and disable. Sign-out cannot happen while the permission prompt is on screen.
        pushTask?.cancel()
        await pushTask?.value
        var turnedOff: PushRegistrationState?
        if testSessionID == nil {
            do {
                turnedOff = try PushRegistrationState.turningOff(accountID: account, saved: try PushRegistrationState.load(accountID: account),
                                                                 enabled: enabled)
                try turnedOff?.save()
            } catch { self.error = "Signed out locally, but remote notification cleanup still needs attention." }
        }
        if turnedOff != nil, let connection, isConnected, generation == token {
            activeEncryptionOperations += 1
            defer { activeEncryptionOperations -= 1 }
            do { try await settlePushCleanup(client: connection, account: account, token: token) }
            catch {
                if generation == token { self.error = "Signed out locally. Remote notification cleanup could not be confirmed." }
            }
        }
        guard generation == token else { return }
        await quiesceTransport()
        if let localFailure { self.error = localFailure }
    }

    /// Re-entering credentials for the same account does not revoke an existing server subscription: its identity stays
    /// available for background handoff and explicit logout. Nor does it lift the SCRAM pin, so a server that drops SCRAM
    /// cannot get PLAIN by making the user type the password again; only signing out does. A discovered endpoint that
    /// worked stays the first to try. Nothing crosses accounts.
    static func retainingSavedState(previous: NotificationAccount?, replacement: NotificationAccount) -> NotificationAccount {
        guard let previous, previous.accountID == replacement.accountID, previous.domain == replacement.domain,
              previous.username == replacement.username else { return replacement }
        let keepEndpoint = replacement.discoversEndpoint && previous.discoversEndpoint && !previous.host.isEmpty
        let endpoint = keepEndpoint ? previous : replacement
        return NotificationAccount(accountID: replacement.accountID, host: endpoint.host, port: endpoint.port, security: endpoint.security,
            discoversEndpoint: replacement.discoversEndpoint, requiresSCRAM: previous.requiresSCRAM || replacement.requiresSCRAM,
            domain: replacement.domain, username: replacement.username, password: replacement.password, push: replacement.push ?? previous.push)
    }

    /// Serialize scene transitions; never release the lease with a suspended writer alive.
    func setForeground(_ active: Bool) {
        foreground = active
        // The extension may set the icon badge while the app is away: the next chat-list load sets it again.
        appBadge = nil
        if !active { quiescing = true }
        let previous = lifecycleTask
        lifecycleTask = Task { [weak self] in
            await previous?.value
            guard let self else { return }
            if active {
                guard self.foreground else { return }
                self.returnedToForegroundForUpgrade()
                self.refreshNotificationPermission()
                self.reconnectAttempt = 0
                self.reconcile()
                if let client = self.client { try? await client.setClientActive(true) }
                await self.refresh()
            } else {
                let task = UIApplication.shared.beginBackgroundTask(withName: "Finish encrypted synchronization")
                // The session hibernates (up to days with push): it must read as away, not "Online", until it resumes.
                if let client = self.client, self.isConnected { try? await client.setAvailability(self.awayAvailability) }
                await self.quiesceTransport()
                if task != .invalid { UIApplication.shared.endBackgroundTask(task) }
            }
        }
    }

    // MARK: Previous version's data

    /// A launch into the background left an upgrade for the foreground, or the lease was busy.
    private func returnedToForegroundForUpgrade() {
        if store == nil, upgradeState == .deferred || upgradeState == .waitingForLease {
            Task { await openStorage() }
        }
    }

    private func readBackupStatus() {
        guard let snapshots else { return }
        previousVersionBackup = snapshots.manifest
        previousVersionBackupUnreadable = snapshots.status(.previousVersion) == .unreadable
    }

    /// The lease was held by another process (a notification run): try again shortly, never taking it by force.
    private func retryOpeningStorage() {
        Task { [weak self] in
            try? await Task.sleep(for: .seconds(2))
            guard let self, self.upgradeState == .waitingForLease, self.foreground else { return }
            await self.openStorage()
        }
    }

    /// Blocking screen: "Try again" after a failed snapshot.
    func retryUpgrade() async {
        guard store == nil, case .snapshotFailed = upgradeState else { return }
        upgradeState = .preparing
        await openStorage()
    }

    /// Blocking screen, after its confirmation: migrate although the snapshot could not be taken.
    func upgradeWithoutBackup() async {
        guard store == nil, case .snapshotFailed = upgradeState else { return }
        upgradeState = .preparing
        await openStorage(withoutSnapshot: true)
    }

    /// Restored screen, first choice (the default): this version's kept data goes back in place, with its messages
    /// and encryption sessions; the previous build's data, if it ran, becomes the backup.
    func returnToThisVersion() async {
        guard store == nil, case let .restored(state) = upgradeState, let snapshots else { return }
        upgradeState = .returning
        do {
            if try await snapshots.returnToThisVersion(now: Date()) == .busy {
                upgradeState = .restored(state)
                self.error = "A notification is being processed. Try again in a moment."
                return
            }
        } catch where !FileManager.default.fileExists(atPath: snapshots.locations.returnJournal.path) {
            // Nothing was put back.
            Self.syncLog.error("return refused: \(String(describing: error), privacy: .public)")
            upgradeState = .restored(snapshots.restoredState())
            self.error = "This version’s data could not be put back: " + PreUpgradeSnapshot.describe(error)
            return
        } catch {
            // Part way: its journal finishes it on this open or the next launch.
            Self.syncLog.error("return interrupted: \(String(describing: error), privacy: .public)")
        }
        upgradeState = .preparing
        await openStorage()
    }

    /// Restored screen, second choice, after its confirmation: this version's kept data is deleted and the restored
    /// data is upgraded again, after a fresh snapshot of it (taken first when the previous version ran on it).
    func upgradeRestoredData() async {
        guard store == nil, case let .restored(state) = upgradeState, let snapshots else { return }
        upgradeState = .preparing
        do {
            if try await snapshots.upgradeRestoredData(now: Date()) == .busy {
                upgradeState = .restored(state)
                self.error = "A notification is being processed. Try again in a moment."
                return
            }
        } catch {
            Self.syncLog.error("upgrade of the restored data refused: \(String(describing: error), privacy: .public)")
            upgradeState = .restored(snapshots.restoredState())
            self.error = "The previous version’s data could not be backed up: " + PreUpgradeSnapshot.describe(error)
            return
        }
        await openStorage()
    }

    /// Chats where this version sent encrypted messages since the backup was taken: their sessions moved on, and a
    /// restore puts back the older session state the peers no longer match.
    func chatsWithEncryptedSendsSinceBackup() async -> [String] {
        guard let store, let backup = previousVersionBackup, !accountID.isEmpty else { return [] }
        return (try? await store.chatsWithEncryptedSends(accountID: accountID, since: backup.takenAt)) ?? []
    }

    /// Settings, after its confirmation.
    func deletePreviousVersionBackup() {
        guard let snapshots else { return }
        do { try snapshots.delete() }
        catch { self.error = "The backup could not be deleted. Try again." }
        readBackupStatus()
    }

    /// Settings, after its confirmation: puts the previous version's data back and stops. The transport is quiesced
    /// as the background transition does it, but the lease is kept (or taken, never by force) so that the store is
    /// closed and swapped under it. Afterwards nothing reconnects or migrates until the user chooses.
    func restorePreviousVersion() async {
        guard let snapshots, let store, upgradeState == .none, previousVersionBackup != nil else { return }
        upgradeState = .restoring
        restoringData = true
        defer { restoringData = false }
        // Copying this version's data can take a moment; leaving the app meanwhile must not suspend it half way.
        let background = UIApplication.shared.beginBackgroundTask(withName: "Restore previous version's data")
        defer { if background != .invalid { UIApplication.shared.endBackgroundTask(background) } }
        reconnectTask?.cancel(); reconnectTask = nil
        await stopTransportWork()
        quiescing = true
        var leased = await store.holdsTransportOwnership
        for _ in 0..<40 where !leased {
            do { try await store.acquireTransportOwnership(); leased = true }
            catch MessageStoreError.transportOwnedElsewhere { try? await Task.sleep(for: .milliseconds(250)) }
            catch { break }
        }
        guard leased else {
            hasTransportOwnership = false
            quiescing = false
            upgradeState = .none
            self.error = "A notification is being processed. Try restoring again in a moment."
            reconcile()
            return
        }
        do {
            let restored = try await snapshots.restore(store: store, now: Date())
            Self.syncLog.notice("restored the previous version's data taken \(restored.takenAt, privacy: .public)")
            closeStorageAfterRestore()
            upgradeState = .restored(snapshots.restoredState())
        } catch where !FileManager.default.fileExists(atPath: snapshots.locations.journal.path) {
            // Nothing changed: the backup did not verify, or the store could not be handed over.
            Self.syncLog.error("restore refused before any change: \(String(describing: error), privacy: .public)")
            // Whatever the lease is now, not what it was: a background transition during the restore left it alone,
            // and the restore gives it up here if the app is no longer in front.
            hasTransportOwnership = await store.holdsTransportOwnership
            if hasTransportOwnership, !foreground {
                hasTransportOwnership = false
                try? await store.releaseTransportOwnership()
            }
            quiescing = false
            upgradeState = .none
            self.error = "The backup could not be restored: " + PreUpgradeSnapshot.describe(error)
            reconcile()
        } catch {
            // Part way: the journal finishes it, now or on the next launch.
            Self.syncLog.error("restore interrupted: \(String(describing: error), privacy: .public)")
            try? await store.close()
            closeStorageAfterRestore()
            await openStorage()
            if self.store == nil, upgradeState == .restoring || upgradeState == .preparing {
                upgradeState = .snapshotFailed("Restoring did not finish. Quit and reopen Haus XMPP to finish it.")
            }
        }
    }

    private func closeStorageAfterRestore() {
        generation = UUID()
        hasTransportOwnership = false
        sessionAccount = nil
        pushStatus = .off
        outboxSender = nil
        encryption = nil
        store = nil
        chats = []
        messages = []
    }

    /// The scene left the foreground: from now on background sessions report this as the last time the user was here.
    func leftForeground() {
        // Nothing the previous build left is rewritten, or added to, before its snapshot exists.
        guard store != nil else { return }
        SharedSession.recordLeftForeground(defaults: sessionDefaults)
    }

    /// How a session this app runs away from the foreground (going to the background, a notification action) presents.
    private var awayAvailability: XMPPAvailability {
        BackgroundSession.availability(sharesLastSeen: accountPreferences.lastSeen, leftForeground: SharedSession.leftForeground(defaults: sessionDefaults))
    }

    private func quiesceTransport() async {
        await stopTransportWork()
        // A restore holds the lease until it closes the store, and releases it itself if it is refused.
        guard !restoringData else { return }
        hasTransportOwnership = false
        try? await store?.releaseTransportOwnership()
    }

    /// Everything the background transition stops, without giving up the lease: blocks new transport, crypto and
    /// setup work, disconnects, and joins every reader, consumer, sender and UI crypto mutation.
    private func stopTransportWork() async {
        quiescing = true
        defer { quiescing = false }
        let events = eventTask
        let setup = setupTask
        let backfill = backfillTask
        let drain = drainTask
        let previous = resetSession()
        await previous?.disconnectAndWait()
        await events?.value
        // Setup's archive walk, initialize, rejoin and pending retry are all structured children of it.
        await setup?.value
        await backfill?.value
        if backfillTask == backfill { backfillTask = nil }
        await drain?.value
        // Includes already-started UI trust/repair/discovery work and an acquisition that
        // was suspended in the store actor when the scene changed.
        while activeEncryptionOperations > 0 || acquiringOwnership {
            try? await Task.sleep(for: .milliseconds(10))
        }
    }

    /// Right after the lease is ours: an extension run that held it may have posted for the chat already on screen
    /// (its candidates were read before the chat opened). Every such run is over now, so what it posted is delivered.
    private func dismissOpenChatNotifications(store: MessageStore, account: String) async {
        guard let chatID = openChatID, !isDemo, accountID == account, hasTransportOwnership else { return }
        try? await store.dismissReactionNotifications(accountID: account, chatID: chatID)
        await DeliveredNotificationCleaner.removeThread(accountID: account, chatID: chatID)
    }

    private func acquireForegroundOwnership(_ store: MessageStore, token: UUID) async throws {
        acquiringOwnership = true
        defer { acquiringOwnership = false }
        for attempt in 0..<120 {
            guard foreground, !quiescing, generation == token else { throw CancellationError() }
            do {
                try await store.acquireTransportOwnership()
                guard foreground, !quiescing, generation == token else { throw CancellationError() }
                hasTransportOwnership = true
                return
            }
            catch MessageStoreError.transportOwnedElsewhere {
                guard attempt < 119 else { throw MessageStoreError.transportOwnedElsewhere }
                try await Task.sleep(for: .milliseconds(250))
            }
        }
    }

    /// Settings: turn push on (again), or retry a failed setup. Asks for notification permission if it was never asked.
    func enableNotifications() async {
        guard !accountID.isEmpty, testSessionID == nil, !isDemo else { return }
        setPushWanted(true, account: accountID)
        pushIntent += 1
        if pushStatus != .on { pushStatus = .settingUp }
        let token = generation
        guard let client, let session = sessionAccount, isConnected else {
            // The next connection finishes the setup; asked now, permission needs no prompt then.
            if await Self.notificationAuthorization() == .notDetermined {
                _ = try? await UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound, .badge])
                refreshNotificationPermission()
            }
            if generation == token, pushWanted { pushStatus = .settingUp }
            return
        }
        startPushSetup(client: client, session: session, token: token, interactive: true)
        await pushTask?.value
    }

    /// Settings: turn push off. Revokes the gateway registration and disables it at the account server; offline, or
    /// on a failure, both wait in the saved registration state for the next connection.
    func disableNotifications() async {
        guard !accountID.isEmpty, testSessionID == nil, !isDemo else { return }
        let account = accountID
        setPushWanted(false, account: account)
        pushIntent += 1
        pushStatus = .off
        let token = generation
        do {
            let enabled = sessionAccount?.accountID == account ? sessionAccount?.push : nil
            guard let state = try PushRegistrationState.turningOff(accountID: account, saved: try PushRegistrationState.load(accountID: account),
                                                                   enabled: enabled) else { return }
            try state.save()
            if let session = sessionAccount, session.accountID == account, session.push != nil {
                // The extension's guard declines from now on.
                let saved = session.replacingPush(nil)
                try saved.save()
                sessionAccount = saved
            }
            guard let client, isConnected, hasTransportOwnership, foreground, !quiescing, generation == token else { return }
            activeEncryptionOperations += 1
            defer { activeEncryptionOperations -= 1 }
            try await settlePushCleanup(client: client, account: account, token: token)
        } catch {
            if generation == token, accountID == account { Self.syncLog.error("push revocation will retry on reconnect") }
        }
    }

    /// Queues `reconcilePush` behind any setup still running (a reconnect during the permission prompt waits for the
    /// answer, then sets up without asking again).
    private func startPushSetup(client: XMPPClient, session: NotificationAccount, token: UUID, interactive: Bool) {
        let previous = pushTask
        pushTask = Task { [weak self] in
            await previous?.value
            guard let self, self.generation == token, !Task.isCancelled else { return }
            await self.reconcilePush(client: client, session: session, token: token, interactive: interactive)
        }
    }

    /// Runs after every authenticated connection: finishes a stored revocation and disable, then (unless push is turned
    /// off) makes sure this installation is registered with the gateway and enabled at the account server.
    /// `interactive` is true for a manual sign-in or a tap in Settings, the only moments that may show the permission
    /// prompt. Only the transport work counts as an encryption operation, so a background transition never waits for
    /// a prompt the user has not answered, nor for APNs.
    private func reconcilePush(client: XMPPClient, session: NotificationAccount, token: UUID, interactive: Bool) async {
        guard testSessionID == nil, !isDemo, hasTransportOwnership, foreground, !quiescing, generation == token else { return }
        let account = session.accountID, intent = pushIntent
        do {
            let supported: Bool
            do {
                activeEncryptionOperations += 1
                defer { activeEncryptionOperations -= 1 }
                try await settlePushCleanup(client: client, account: account, token: token)
                guard generation == token, pushIntent == intent else { return }
                guard pushWanted else { pushStatus = .off; return }
                supported = try await client.supportsPushNotifications()
            }
            guard generation == token, pushIntent == intent else { return }
            guard supported else { pushStatus = .unsupported; return }
            var authorization = await Self.notificationAuthorization()
            if authorization == .notDetermined, interactive {
                // Asks on the first sign-in only (a reconnect at launch never prompts).
                if pushStatus != .on { pushStatus = .settingUp }
                _ = try? await UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound, .badge])
                refreshNotificationPermission()
                authorization = await Self.notificationAuthorization()
            }
            guard generation == token, pushIntent == intent else { return }
            if let stop = PushStatus.gate(for: authorization, interactive: false) { pushStatus = stop; return }
            if pushStatus != .on { pushStatus = .settingUp }
            let deviceToken = try await PushRegistration.request()
            refreshNotificationPermission()
            guard generation == token, pushIntent == intent, pushWanted, foreground, !quiescing, hasTransportOwnership,
                  accountID == account else { return }
            activeEncryptionOperations += 1
            defer { activeEncryptionOperations -= 1 }
            let push = try await currentSubscription(client: client, account: account, token: token)
            guard generation == token, pushIntent == intent, var latest = sessionAccount, latest.accountID == account else { return }
            if latest.push != push {
                latest = latest.replacingPush(push)
                // Save before enabling: an immediately arriving push can safely find its account.
                try latest.save()
                sessionAccount = latest
            }
            try stagePushToken(deviceToken, account: account, configuration: push)
            try await sendPendingPushRegistration(client: client, account: account, token: token)
            guard generation == token, pushIntent == intent else { return }
            try await client.enablePush(push)
            guard generation == token, pushIntent == intent else { return }
            pushStatus = .on
            writePushDiagnostics(push: push, deviceToken: deviceToken)
        } catch {
            guard generation == token, pushIntent == intent else { return }
            pushStatus = PushStatus.settled(after: error, wanted: pushWanted)
            Self.syncLog.error("push setup stopped: \(String(describing: self.pushStatus), privacy: .public)")
        }
    }

    /// This installation's subscription at the current push service. The first setup generates one; a subscription
    /// saved at another service (the retired staging gateway) is disabled at the account server before a new one
    /// replaces it, so the two are never enabled together.
    private func currentSubscription(client: XMPPClient, account: String, token: UUID) async throws -> XMPPPushConfiguration {
        let service = PushService.serviceJID
        let saved = try PushRegistrationState.load(accountID: account)
        // A subscription enabled before the registration journal existed lives only in the saved account.
        let enabled = saved?.configuration ?? (sessionAccount?.accountID == account ? sessionAccount?.push : nil)
        switch PushSubscription.plan(saved: enabled, serviceJID: service) {
        case .keep(let push):
            return push
        case .replace(let old):
            try await retire(old, client: client, account: account, journal: saved?.journal, token: token)
            fallthrough
        case .create:
            guard generation == token else { throw CancellationError() }
            let push = try PushSubscription.generate(serviceJID: service)
            try PushRegistrationState(accountID: account, configuration: push, journal: PushRegistrationJournal()).save()
            return push
        }
    }

    /// Best effort at the old gateway; at the account server only a transport failure stops the migration (the next
    /// connection repeats it, since the old subscription stays saved until the new one replaces it). A server that
    /// answers with an error holds no such registration.
    private func retire(_ old: XMPPPushConfiguration, client: XMPPClient, account: String, journal: PushRegistrationJournal?,
                        token: UUID) async throws {
        if var journal, journal.acknowledgedRevision > 0 || journal.pending != nil {
            if let revoke = try? journal.stageRevocation() {
                _ = try? await client.updatePushRegistration(revoke, configuration: old, environment: PushService.environment ?? .sandbox)
            }
        }
        guard generation == token else { throw CancellationError() }
        do { try await client.disablePush(serviceJID: old.serviceJID, node: old.node) }
        catch where PushCleanup.disableSettles(error) { }
        guard generation == token else { throw CancellationError() }
        if var session = sessionAccount, session.accountID == account, session.push == old {
            session = session.replacingPush(nil)
            try session.save()
            sessionAccount = session
        }
    }

    /// Finishes a turned-off subscription: sends its stored revocation to the gateway, then disables it at the account
    /// server. Each step is stored separately and cleared only when confirmed (or when `PushCleanup` says nothing is
    /// left), so a failure of either leaves it for the next connection, whether or not push is wanted.
    private func settlePushCleanup(client: XMPPClient, account: String, token: UUID) async throws {
        guard let state = try PushRegistrationState.load(accountID: account) else { return }
        var failure: (any Error)?
        if state.journal.pending?.action == .revoke {
            do {
                try await sendPendingPushRegistration(client: client, account: account, token: token)
            } catch {
                let retired = state.configuration.serviceJID.lowercased() != PushService.serviceJID
                if generation == token, PushCleanup.revocationSettles(error, retired: retired),
                   var latest = try PushRegistrationState.load(accountID: account), latest.configuration == state.configuration,
                   let pending = latest.journal.pending, pending.action == .revoke {
                    latest.journal.abandonPending(pending)
                    try latest.save()
                } else { failure = error }
            }
        }
        guard generation == token else { throw CancellationError() }
        // The disable goes ahead even when the revocation must be retried: it is what stops the account server publishing.
        if state.disablePending {
            do {
                do { try await client.disablePush(serviceJID: state.configuration.serviceJID, node: state.configuration.node) }
                catch where PushCleanup.disableSettles(error) { }
                guard generation == token else { throw CancellationError() }
                if var latest = try PushRegistrationState.load(accountID: account), latest.configuration == state.configuration,
                   latest.disablePending {
                    latest.disablePending = false
                    try latest.save()
                }
            } catch { failure = failure ?? error }
        }
        if let failure { throw failure }
    }

    private func setPushWanted(_ wanted: Bool, account: String) {
        if wanted { preferences.removeObject(forKey: "pushOff." + account) } else { preferences.set(true, forKey: "pushOff." + account) }
        if account == accountID { pushWanted = wanted }
    }

    private func writePushDiagnostics(push: XMPPPushConfiguration, deviceToken: Data) {
        #if DEBUG
        guard ProcessInfo.processInfo.arguments.contains("-push-diagnostics") else { return }
        do {
            let directory = try FileManager.default.url(for: .documentDirectory, in: .userDomainMask, appropriateFor: nil, create: true)
            let data = try JSONEncoder().encode(["node": push.node, "device_token": deviceToken.map { String(format: "%02x", $0) }.joined()])
            try data.write(to: directory.appending(path: "push-registration.json"), options: [.atomic, .completeFileProtectionUntilFirstUserAuthentication])
            var privateFile = directory.appending(path: "push-registration.json")
            var values = URLResourceValues(); values.isExcludedFromBackup = true
            try privateFile.setResourceValues(values)
        } catch {}
        #endif
    }

    private func stagePushToken(_ token: Data, account: String, configuration: XMPPPushConfiguration) throws {
        guard PushRegistration.isLatestToken(token) else { throw CancellationError() }
        var state = try PushRegistrationState.load(accountID: account)
            ?? PushRegistrationState(accountID: account, configuration: configuration, journal: PushRegistrationJournal())
        guard state.configuration == configuration else { throw XMPPNotificationError.invalidConfiguration }
        try state.journal.stageFreshRegistration(deviceToken: token.map { String(format: "%02x", $0) }.joined())
        try state.save()
    }

    private func receivePushToken(_ deviceToken: Data) async {
        guard testSessionID == nil, pushWanted, let session = sessionAccount, let push = session.push else { return }
        let token = generation, intent = pushIntent
        // A turn-off in Settings during this refresh wins: nothing below may enable or report on it.
        func current() -> Bool { generation == token && pushIntent == intent && pushWanted }
        do {
            // A callback while offline still becomes durable work for this account's next
            // authenticated connection. Logout clears sessionAccount before any suspension.
            try stagePushToken(deviceToken, account: session.accountID, configuration: push)
            guard foreground, !quiescing, hasTransportOwnership, isConnected, let client else { return }
            activeEncryptionOperations += 1
            defer { activeEncryptionOperations -= 1 }
            try await sendPendingPushRegistration(client: client, account: session.accountID, token: token)
            guard current() else { return }
            try await client.enablePush(push)
            if current() { pushStatus = .on }
        } catch {
            if current() { pushStatus = PushStatus.after(error) }
        }
    }

    private func sendPendingPushRegistration(client: XMPPClient, account: String, token: UUID) async throws {
        guard let environment = PushService.environment else { throw XMPPNotificationError.invalidConfiguration }
        for attempt in 0..<2 {
            guard generation == token, accountID == account else { throw CancellationError() }
            guard let state = try PushRegistrationState.load(accountID: account), let operation = state.journal.pending else { return }
            do {
                let result = try await client.updatePushRegistration(operation, configuration: state.configuration, environment: environment)
                guard generation == token, accountID == account else { throw CancellationError() }
                guard var latest = try PushRegistrationState.load(accountID: account), latest.configuration == state.configuration else { throw CancellationError() }
                guard latest.journal.acknowledge(result, for: operation) else { throw CancellationError() }
                try latest.save()
                return
            } catch XMPPIQError.stanza(condition: "conflict") where attempt == 0 {
                let remote = try await client.pushRegistrationStatus(configuration: state.configuration)
                guard generation == token, accountID == account else { throw CancellationError() }
                guard var latest = try PushRegistrationState.load(accountID: account), latest.configuration == state.configuration,
                      latest.journal.pending == operation else { throw CancellationError() }
                try latest.journal.rebasePending(after: remote)
                try latest.save()
            }
        }
    }

    private func selectAccount(_ account: String) {
        // A reconnect of the same account keeps the open chat; refresh() reloads everything else.
        guard account != accountID else { preferences.set(account, forKey: "lastAccount"); return }
        accountID = account
        groupChats = [:]
        reactableGroupMessages = []
        avatars = [:]
        avatarChecked = []
        chats = []
        hasLoadedChats = account.isEmpty // no account has no stored chats to wait for: sign-out shows its empty state at once
        messages = []
        messageReactions = [:]; messageReceipts = [:]
        attachmentFiles = [:]
        openChatID = nil
        requestedRoute = nil
        encryptionOverviewChatID = nil; encryptionOverview = nil; encryptionDetailsChatID = nil
        refreshFence = [:]; encryptionAttention = EncryptionAttention()
        uploadService = uploads.load(account: account)
        resetTyping()
        lastSeenTracker = LastSeenTracker()
        preferences.set(account, forKey: "lastAccount")
    }

    // MARK: Attachments

    /// Seals the file once, stores everything the send will ever need, then queues the message.
    /// The message stays unsendable until the background PUT succeeds; nothing is regenerated.
    /// Never with a caption: Conversations shows a file only when the body is exactly its link, so a caption
    /// goes as its own message after the files.
    func sendAttachment(_ prepared: PreparedAttachment, to chatID: String) async -> Bool {
        guard !isSending, let store, let files, !accountID.isEmpty else { return false }
        guard !isGroup(chatID) else { error = "Files can't be sent to groups yet."; return false }
        guard prepared.data.count <= attachmentLimit else {
            error = AttachmentPreparer.Failure.tooLarge(limit: attachmentLimit).localizedDescription; return false
        }
        isSending = true
        defer { isSending = false }
        let account = accountID
        let id = UUID().uuidString
        if isDemo {
            // Sample chats project only, like sample text: the file is cached and nothing is uploaded.
            let attachment = StoredAttachment(name: prepared.name, mediaType: prepared.mediaType, size: prepared.data.count, width: prepared.width,
                                              height: prepared.height, hash: Data.sha256(prepared.data).hexString, secret: Data([0]))
            do {
                try files.write(prepared.data, to: files.cacheURL(attachment, messageID: id))
                try await store.insertMessage(StoredMessage(id: id, accountID: account, chatID: chatID, senderID: account, body: "", isOutgoing: true, attachment: attachment))
                await refresh()
                return true
            } catch { self.error = "Could not save the file."; return false }
        }
        guard let encryption else { return false }
        do {
            let sealed = try AttachmentTransfer.seal(prepared.data)
            let attachment = StoredAttachment(name: prepared.name, mediaType: prepared.mediaType, size: prepared.data.count,
                                              width: prepared.width, height: prepared.height, hash: Data.sha256(prepared.data).hexString,
                                              cipherHash: Data.sha256(sealed.ciphertext).hexString,
                                              secret: try encryption.sealAttachmentSecret(account: account, key: sealed.key, iv: sealed.iv), uploadState: .pending)
            try files.write(sealed.ciphertext, to: files.stagingURL(messageID: id))
            try files.write(prepared.data, to: files.cacheURL(attachment, messageID: id))
            let message = StoredMessage(id: id, accountID: account, chatID: chatID, senderID: account, body: "", isOutgoing: true,
                                        encryptionProfile: "pending", attachment: attachment)
            try await store.enqueueOutgoing(message)
            await refresh()
            startUploads()
            return true
        } catch {
            if accountID == account { self.error = (error as? LocalizedError)?.errorDescription ?? "Could not save the file." }
            return false
        }
    }

    /// One slot request and one PUT per pending file that has no task in flight.
    private func startUploads() {
        guard uploadTask == nil, session.isReady, hasTransportOwnership, foreground, !quiescing,
              let client, let store, let uploader, let service = uploadService, let files else { return }
        let account = accountID, token = generation
        uploadTask = Task { [weak self] in
            defer { self?.uploadTask = nil }
            guard let pending = try? await store.attachmentsAwaitingUpload(accountID: account) else { return }
            for message in pending where message.attachment?.uploadTaskID == nil {
                guard let attachment = message.attachment, self?.generation == token else { return }
                let staged = files.stagingURL(messageID: message.id)
                guard let size = try? FileManager.default.attributesOfItem(atPath: staged.path)[.size] as? Int else {
                    // The staged ciphertext is gone (a cleared cache); the message can never be sent as is.
                    try? await store.failQueuedOutgoing(accountID: account, messageID: message.id)
                    continue
                }
                do {
                    let slot = try await client.requestUploadSlot(service: service, filename: attachment.name, size: size, contentType: "application/octet-stream")
                    let taskID = uploader.start(file: staged, slot: slot, size: size, contentType: "application/octet-stream")
                    try await store.setAttachmentUploadTask(accountID: account, messageID: message.id, taskID: taskID, url: slot.get.absoluteString)
                } catch {
                    // A dropped connection is not the server refusing; the reconnect starts uploads again.
                    let dropped = error is CancellationError || [XMPPClientError.notConnected, .connectionClosed].contains { $0 == error as? XMPPClientError }
                    guard let self, self.generation == token, !dropped else { continue }
                    await self.uploadFailed(message, account: account)
                }
            }
        }
    }

    /// Counts a refused slot or PUT. Below the budget the file is tried again shortly with a fresh slot; at the
    /// budget it is failed, so it shows Not sent with Retry and stops holding back what was queued after it.
    private func uploadFailed(_ message: StoredMessage, account: String) async {
        guard let store, accountID == account, let name = message.attachment?.name else { return }
        guard uploadFailures.recordFailure(message.id) else {
            error = "Could not upload \(name). It will be retried."
            Task { [weak self] in
                try? await Task.sleep(for: .seconds(5))
                self?.startUploads()
            }
            return
        }
        guard (try? await store.failQueuedOutgoing(accountID: account, messageID: message.id)) != nil else { return }
        error = "Could not upload \(name), so it was not sent. Retry it from the message."
        await refresh()
        startOutbox()
    }

    /// Tasks the system dropped while we were gone get a fresh slot; running ones are left alone.
    private func reconcileUploads() async {
        guard let store, let uploader, !accountID.isEmpty else { return }
        let running = await uploader.runningTaskIDs()
        let pending = (try? await store.attachmentsAwaitingUpload(accountID: accountID)) ?? []
        let stranded = pending.filter { message in message.attachment?.uploadTaskID.map { !running.contains($0) } ?? true }
        if uploadService == nil, !stranded.isEmpty {
            // The server no longer offers uploads, so these files would hold their chats forever.
            for message in stranded { try? await store.failQueuedOutgoing(accountID: accountID, messageID: message.id) }
            error = "This server no longer accepts files, so \(stranded.count == 1 ? "a file was" : "\(stranded.count) files were") not sent."
            await refresh()
            startOutbox()
            return
        }
        for message in pending {
            if let taskID = message.attachment?.uploadTaskID, !running.contains(taskID) {
                try? await store.setAttachmentUploadTask(accountID: accountID, messageID: message.id, taskID: nil, url: nil)
            }
        }
        startUploads()
    }

    private func uploadFinished(taskID: Int, succeeded: Bool) async {
        guard let store, let files, !accountID.isEmpty,
              let message = ((try? await store.attachmentsAwaitingUpload(accountID: accountID)) ?? []).first(where: { $0.attachment?.uploadTaskID == taskID }) else { return }
        if succeeded {
            uploadFailures.reset(message.id)
            try? await store.markAttachmentUploaded(accountID: accountID, messageID: message.id)
            try? FileManager.default.removeItem(at: files.stagingURL(messageID: message.id))
            await refresh()
            startOutbox()
        } else {
            try? await store.setAttachmentUploadTask(accountID: accountID, messageID: message.id, taskID: nil, url: nil)
            // A slot expired, the network dropped or the server refused the PUT: a new slot, within the budget.
            await uploadFailed(message, account: accountID)
        }
    }

    /// Received files of the open chat are fetched on sight and verified before they exist locally.
    private func loadAttachments(_ storedMessages: [StoredMessage], chat: String) {
        guard let files, let encryption else { return }
        for message in storedMessages {
            guard let attachment = message.attachment, attachmentFiles[message.id] == nil else { continue }
            if let cached = files.cached(attachment, messageID: message.id) { attachmentFiles[message.id] = cached; continue }
            guard attachment.url != nil, attachment.uploadState == nil, !downloading.contains(message.id) else { continue }
            downloading.insert(message.id)
            let account = accountID
            Task { [weak self] in
                defer { self?.downloading.remove(message.id) }
                do {
                    let secret = try encryption.openAttachmentSecret(account: account, secret: attachment.secret, sealedAs: attachment.sealedAccount)
                    let bytes = try await AttachmentDownloader.fetch(attachment, secret: secret)
                    let destination = files.cacheURL(attachment, messageID: message.id)
                    try files.write(bytes, to: destination)
                    guard let self, self.accountID == account, self.openChatID == chat else { return }
                    attachmentFiles[message.id] = destination
                } catch {
                    Logger(subsystem: "haus.xmpp.ios", category: "attachments").error("Download of \(attachment.name, privacy: .public) failed: \(String(describing: error), privacy: .public)")
                }
            }
        }
    }

    private func resetSession() -> XMPPClient? {
        generation = UUID()
        drainTask?.cancel()
        // Cancelled, not cleared: connect() and quiesceTransport() join the handle.
        setupTask?.cancel()
        // Its transport work counts as an encryption operation, which quiesceTransport waits for; a permission prompt
        // still on screen does not, so nothing here waits for it.
        pushTask?.cancel()
        catchUp = nil
        // Cancelled, not cleared, like the setup task: a new connection's walk must never meet an old backfill.
        backfillTask?.cancel()
        backfillingArchive = nil
        opportunisticBackfillDone = false
        archiveWalkFinished = false
        backfillSettled = []
        backfillResumesAt = nil
        eventTask?.cancel()
        eventTask = nil
        let previous = client
        client = nil
        reconnectTask?.cancel(); reconnectTask = nil
        session = .offline(reason: nil)
        inbound = nil
        for room in groupChats.keys { groupChats[room]?.joined = false }
        resetTyping()
        resetPresence()
        return previous
    }

    private func handle(_ event: XMPPEvent, token: UUID) async {
        let account = accountID
        switch event {
        case .state(let state):
            switch state {
            case .connecting: session = .connecting(step: "Connecting…")
            case .authenticating: session = .connecting(step: "Signing in…")
            case .binding: session = .connecting(step: "Opening session…")
            case .online:
                session = .connected(settingUp: ConnectionSetup.featuresStep)
                onlineAt = .now
                firstMessageLogged = false
                liveStoredLogged = false
                catchUpByArchive = [:]
                let resumed = await client?.sessionResumed ?? false
                Self.syncLog.notice("online resumed=\(resumed, privacy: .public)")
                // The client answers XEP-0012 queries to our full address only while the account shares last seen.
                await client?.setSharesLastActivity(accountPreferences.lastSeen)
                // A resumed session gets no probe answers: keep who was available on the previous stream.
                lastSeenTracker.beginConnection(resumed: resumed)
                syncOpenChatLastSeen()
                guard generation == token else { return }
                guard let encryption, let client, let store else { return }
                let identityExists: Bool
                do { identityExists = try await store.encryptionState(accountID: account) != nil }
                catch { identityExists = true } // the setup task's initialize reports the real problem
                guard generation == token else { return }
                if !identityExists {
                    // A brand-new account has no encryption state yet, and the live consumer cannot persist
                    // anything without it: publish the identity before letting the setup run concurrently.
                    session = .connected(settingUp: ConnectionSetup.keysStep)
                    do { try await encryption.initialize(account: account, transport: client) }
                    catch {
                        guard generation == token else { return }
                        await reportSetupFailure(step: ConnectionSetup.keysStep, detail: ConnectionSetup.detail(error), client: client, token: token)
                        return
                    }
                    guard generation == token else { return }
                }
                // The event loop returns at once and keeps persisting and acknowledging live stanzas while setup
                // runs; OMEMO's operation gate serialises the two per crypto operation.
                setupTask = Task { [weak self] in
                    guard let self else { return }
                    await self.runConnectionSetup(account: account, client: client, encryption: encryption, store: store,
                                                  identityExists: identityExists, token: token)
                    if self.generation == token { self.setupTask = nil }
                }
            case .disconnected(let reason):
                Self.syncLog.notice("disconnected: \(reason ?? "closed", privacy: .public)")
                // Its client calls fail with the connection anyway; cancelling makes the exit prompt.
                setupTask?.cancel()
                catchUp = nil
                backfillTask?.cancel()
                archiveWalkFinished = false
                for room in groupChats.keys { groupChats[room]?.joined = false }
                // Chat states and presence belong to the stream that carried them.
                resetTyping()
                resetPresence()
                drainTask?.cancel()
                if case .needsAttention = session {} else { session = .offline(reason: reason) }
                reconcile()
            }
        case .chatState(let update):
            // A state never creates a chat: only listed chats (joined groups among them) show one.
            guard chats.contains(where: { $0.id == update.chat }) else { return }
            typingTracker.apply(update.state, chat: update.chat, participant: update.participant ?? update.chat, settles: update.ridesOnMessage, now: .now)
            publishTyping()
        case .reaction, .retraction, .receipt, .encryptedMessage, .encryptedGroupMessage, .streamManagementBarrier, .displayedSync:
            guard let encryption, let client else { return }
            if case .encryptedMessage = event { receivedCount += 1 }
            // A real message ends its sender's typing, even from a client that sends no `active` with it.
            if case .encryptedMessage(let message) = event, message.provenance == .direct, let sender = message.from.split(separator: "/").first.map(String.init) {
                typingTracker.messageArrived(chat: sender, participant: sender, now: .now); publishTyping()
            }
            if case .encryptedGroupMessage(let message) = event {
                typingTracker.messageArrived(chat: message.room, participant: message.sender, now: .now); publishTyping()
            }
            // One processor per connection: it owns the "may acknowledge" rule for this stream.
            if inbound?.client !== client { inbound = InboundProcessor(encryption: encryption, client: client, account: account) }
            guard let inbound else { return }
            do {
                let outcome = try await inbound.process(event)
                guard generation == token else { return }
                // An XEP-0490 item older than our pointer leaves our newer state pending: answer it now.
                if case .displayedSync = event { publishReadState() }
                switch outcome {
                case .stored:
                    await flushEncryptionControls(account: account, client: client)
                    guard generation == token else { return }
                    refreshSoon()
                case .retained(let problem):
                    // The ciphertext is kept; the chat-list load marks its chat for review. The reason is a footnote.
                    encryptionAttention.note(problem)
                    await refresh()
                    guard generation == token else { return }
                    if let openChatID { await loadEncryptionDetails(for: openChatID, refreshFromServer: false) }
                case .excluded(let reason):
                    // Not content, not review: the placeholder row is the record; the reason is a footnote in Devices.
                    encryptionAttention.note(reason == .notForThisDevice
                        ? "A message from another device was not encrypted for this iPhone; it is shown as a placeholder."
                        : "An encrypted message could not be read; it is shown as a placeholder.")
                    refreshSoon()
                case .acknowledged, .ignored: break
                }
            } catch InboundProcessor.Failure.unsavedInbound {
                guard generation == token else { return }
                self.error = "An incoming message could not be saved. Reconnect after checking local storage."
            } catch {
                guard generation == token else { return }
                if case .streamManagementBarrier = event { self.error = "Could not save synchronization progress. Reconnect to recover safely." }
                // Otherwise the processor withholds acknowledgement; the next barrier ends the stream.
            }
        case .groupPresence(let room):
            await updateGroupPresence(room, token: token)
        case .omemoDevices(let owner, let profile, _):
            if owner == account, let encryption, let client {
                try? await encryption.maintainLocalAdvertisement(account: account, profile: profile, transport: client)
            }
            // A device list is what a keys-pending row waited for; only this owner's rows can be unblocked by it.
            if let encryption, let client, let store, isConnected,
               !((try? await store.pendingEncryptedIncoming(accountID: account, reasons: [.keysPending], sender: owner)) ?? []).isEmpty {
                try? await encryption.retryPendingIncoming(account: account, transport: client, reasons: [.keysPending], sender: owner)
                guard generation == token else { return }
                await flushEncryptionControls(account: account, client: client)
                guard generation == token else { return }
                refreshSoon()
            }
            if let openChatID, owner == openChatID || owner == accountID || groupChats[openChatID]?.members.contains(owner) == true {
                await loadEncryptionDetails(for: openChatID, force: true)
            }
        case .avatarMetadata(let owner, _):
            // The server pushed a change; re-fetch through the one lazy path so the hash check applies.
            avatarChecked.remove(owner)
            if owner == account || chats.contains(where: { $0.id == owner }) { await loadAvatar(for: owner) }
        case .encryptionFailure:
            encryptionAttention.note("An encrypted message could not be opened")
        case .contactPresence(let presence):
            // Our own other resources and groups are dropped; only listed 1:1 chats reach the header.
            guard !isDemo, lastSeenTracker.apply(presence, account: account, isContact: !isGroup(presence.contact), now: .now),
                  presence.contact == openChatID else { return }
            syncOpenChatLastSeen()
            // A probe answer says offline without a time: ask the server when the contact was last active.
            if !presence.available { requestLastSeen(for: presence.contact) }
        case .subscription(let event):
            guard event.kind == .subscribe, !isDemo, event.from != account, let client else { return }
            // Unsubscribe/unsubscribed need no answer; the roster push that follows records the change.
            switch lastSeenTracker.answerSubscribe(from: event.from, sharesLastSeen: accountPreferences.lastSeen, isDirectChat: isDirectChat(event.from)) {
            case .approve(let alsoSubscribe):
                try? await client.sendSubscription(.subscribed, to: event.from)
                if alsoSubscribe { try? await client.sendSubscription(.subscribe, to: event.from) }
            case .deny:
                try? await client.sendSubscription(.unsubscribed, to: event.from)
            case .leavePending:
                break // A stranger's request waits on the server; it is redelivered on every login.
            }
        case .rosterItems(let items, let replacesAll):
            guard !isDemo else { return }
            lastSeenTracker.applyRoster(items, replacesAll: replacesAll)
            // While the account does not share last seen, nobody keeps a subscription to our presence: the
            // roster fetched on each connection (and any push) is revoked, so a switch turned off offline or on
            // another device takes effect on the next connection.
            if !accountPreferences.lastSeen { await revokePresenceSharing(items.filter { $0.subscription == .from || $0.subscription == .both }.map(\.jid), token: token) }
            guard generation == token, let openChatID, replacesAll || items.contains(where: { $0.jid == openChatID }) else { return }
            requestLastSeen(for: openChatID)
        case .streamAcknowledged:
            refreshSoon()
        case .message:
            // Encrypted conversations do not render unauthenticated plaintext injected by a peer
            // or server as though it had passed OMEMO authentication.
            encryptionAttention.note("An unencrypted message was blocked")

        }
    }

    func isGroup(_ chatID: String) -> Bool { groupChats[chatID] != nil }

    /// Lazily checks one contact's avatar (or the account's own when `chatID == accountID`) once per
    /// session: XEP-0084 metadata, the bytes only when the hash changed, vCard when PEP has nothing.
    /// Bytes are hash-verified by the client and decoded within a pixel budget before anything shows.
    func loadAvatar(for chatID: String) async {
        guard !isDemo, !isGroup(chatID), session.isReady, let client, let store, let storageRoot,
              !avatarChecked.contains(chatID) else { return }
        let account = accountID
        let token = generation
        avatarChecked.insert(chatID)
        let stored = chatID == account ? preferences.string(forKey: "avatar.\(account)") : chats.first { $0.id == chatID }?.avatarHash
        do {
            var hash: String?
            var fetched: (hash: String, data: Data)?
            do {
                if let metadata = try await client.fetchAvatarMetadata(for: chatID) {
                    hash = metadata.id
                    if metadata.id != stored { fetched = (metadata.id, try await client.fetchAvatarData(for: chatID, id: metadata.id)) }
                }
            } catch XMPPIQError.stanza {
                // No PEP node, no PEP at all, or a presence-gated node we may not read: XEP-0153 vCard
                // (servers mirror PEP avatars into it, XEP-0398) is the one place left to look.
                if let photo = try await client.fetchVCardPhoto(for: chatID) {
                    hash = photo.id
                    if photo.id != stored { fetched = (photo.id, photo.data) }
                }
            }
            guard generation == token, accountID == account else { return }
            if let fetched {
                try AvatarStore.save(fetched.data, root: storageRoot, account: account, hash: fetched.hash)
                if let image = AvatarStore.image(root: storageRoot, account: account, hash: fetched.hash) {
                    avatars[chatID] = image
                    // The communication-notification copy: pre-scaled here, so the extension never decodes an image.
                    AvatarStore.saveNotificationImage(root: storageRoot, account: account, hash: fetched.hash)
                } else {
                    try? FileManager.default.removeItem(at: AvatarStore.url(root: storageRoot, account: account, hash: fetched.hash))
                    hash = nil
                }
            }
            if hash == nil { avatars[chatID] = nil }
            if chatID == account { preferences.set(hash, forKey: "avatar.\(account)") }
            else if hash != stored { try await store.setAvatarHash(accountID: account, chatID: chatID, hash: hash) }
        } catch XMPPIQError.requestLimit {
            avatarChecked.remove(chatID) // the row's next appearance retries once the IQ window has room
        } catch {
            // Keep whatever is stored; a failed fetch is not a removed avatar.
        }
    }

    /// Thumbnails for stored hashes not yet in memory, e.g. after launch or an account switch.
    private func loadStoredAvatars(_ stored: [StoredChat]) {
        guard let storageRoot else { return }
        let account = accountID
        var wanted = stored.compactMap { chat in chat.avatarHash.map { (chat.id, $0) } }
        if let own = preferences.string(forKey: "avatar.\(account)") { wanted.append((account, own)) }
        // ponytail: decoded on the main actor; the files are ≤512 KiB and become 256 px thumbnails. Move off-main if the list ever stutters.
        for (id, hash) in wanted where avatars[id] == nil {
            avatars[id] = AvatarStore.image(root: storageRoot, account: account, hash: hash)
            // Avatars stored before communication notifications get their pre-scaled copy once (a stat when it exists).
            if avatars[id] != nil { AvatarStore.saveNotificationImage(root: storageRoot, account: account, hash: hash) }
        }
    }
    func canSend(to chatID: String) -> Bool {
        guard isGroup(chatID) else { return true }
        return isConnected && encryptionReady && groupChats[chatID]?.joined == true
    }

    /// The room's chat ID (its address in normal form), or nil with `error` set.
    func joinGroup(room: String, nickname: String) async -> String? {
        guard hasTransportOwnership, foreground, !quiescing, isConnected, encryptionReady,
              let client, let encryption, let store else { error = "Connect before joining a group."; return nil }
        // In normal form, the spelling the room's presence and messages arrive with; not a valid room address fails below.
        let room = JID(room.trimmingCharacters(in: .whitespacesAndNewlines)).flatMap { $0.localpart != nil && $0.resourcepart == nil ? $0.bare : nil } ?? ""
        let nickname = nickname.trimmingCharacters(in: .whitespacesAndNewlines)
        let domain = accountDomain
        let roomAllowed = isLabAccount ? room.hasSuffix("@rooms." + domain) : (room.contains("@") && !room.hasPrefix("@") && !room.hasSuffix("@"))
        guard roomAllowed, !room.contains("/"), !room.contains(where: { $0.isWhitespace }),
              !nickname.isEmpty else { error = isLabAccount ? "Enter a group address at rooms.\(domain) and a nickname." : "Enter a group address such as room@conference.example.org and a nickname."; return nil }
        activeEncryptionOperations += 1
        defer { activeEncryptionOperations -= 1 }
        let account = accountID, token = generation
        do {
            let overview = try await encryption.refreshGroupDevices(account: account, room: room, transport: client)
            guard generation == token, foreground, !quiescing else { return nil }
            groupChats[room] = GroupChatState(members: overview.room.members, devices: overview.devices)
            _ = try await client.joinGroupRoom(room, nickname: nickname)
            let confirmed = try await client.groupRoomSnapshot(room)
            guard generation == token, foreground, !quiescing else { return nil }
            preferences.set(nickname, forKey: "groupNickname.\(account).\(room)")
            groupChats[room]?.joined = confirmed?.joined == true
            try await store.upsertChat(accountID: account, chatID: room, title: String(room.prefix { $0 != "@" }))
            // On the device only, where a commit (app or extension) can tell a mention of this nickname.
            try await store.setGroupNickname(accountID: account, room: room, nickname: nickname)
            guard generation == token else { return nil }
            await refresh()
            return room
        } catch {
            if generation == token { self.error = groupFailure(error) }
            return nil
        }
    }

    /// Builds `ConnectionSetup`'s operations from this model's calls and applies its events under the
    /// generation fence. Every operation runs inside the setup task; none spawns an unstructured task.
    private func runConnectionSetup(account: String, client: XMPPClient, encryption: OMEMOService, store: MessageStore,
                                    identityExists: Bool, token: UUID) async {
        let operations = ConnectionSetup.Operations(
            features: { [domain = accountDomain] in
                try await ConnectionSetup.discoverFeatures(server: { try await client.discoveryFeatures(for: domain) },
                                                           account: { try await client.discoveryFeatures() })
            },
            enableCarbons: { try await client.setCarbonsEnabled() },
            discoverUploads: { [weak self] in
                // Optional: a server without XEP-0363 just has no attach button. Only a completed answer changes
                // what the button remembers; a discovery that throws keeps the last one.
                let discovery: Result<XMPPUploadService?, any Error>
                do { discovery = .success(try await client.uploadService()) } catch { discovery = .failure(error) }
                await self?.settleUploadDiscovery(discovery, account: account, token: token)
            },
            initializeEncryption: { try await encryption.initialize(account: account, transport: client) },
            rejoinGroups: { [weak self] in
                guard let self else { throw CancellationError() }
                try await self.rejoinKnownGroups(account: account, client: client, encryption: encryption, token: token)
                // `.ready` started the outbox before the rooms were joined; group messages queued while
                // offline need a joined room, so ask for one more pass.
                await self.startOutbox()
            },
            catchUp: { progress in
                let outcome = try await ArchiveSynchronizer(store: store).synchronize(account: account, client: client, encryption: encryption) {
                    await progress(CatchUpProgress(archive: $0.archive, pages: $0.pages, messages: $0.messages))
                }
                // A refused or unanswered archive query keeps the connection; that archive's checkpoint stands and the
                // next connection walks it again. Not a setup failure, so nothing is shown.
                if !outcome.isComplete {
                    Logger(subsystem: "haus.xmpp.ios", category: "sync").notice("catch-up incomplete: own=\(outcome.ownArchiveComplete, privacy: .public) rooms=\(outcome.unfinishedRooms.count, privacy: .public)")
                }
            },
            retryPending: { try? await encryption.retryPendingIncoming(account: account, transport: client) })
        await ConnectionSetup(identityExists: identityExists).run(operations: operations) { [weak self] event in
            await self?.applySetupEvent(event, account: account, client: client, token: token)
        }
    }

    private func settleUploadDiscovery(_ discovery: Result<XMPPUploadService?, any Error>, account: String, token: UUID) {
        guard generation == token else { return }
        uploadService = uploads.settle(account: account, previous: uploadService, discovery: discovery)
    }

    /// True while this connection's setup may still change state. `.disconnected` cancels the setup task without
    /// changing the generation, so the generation alone would let a late `.step` or `.ready` overwrite the
    /// offline state and stop the reconciler from reconnecting (neither state is connectable).
    private func setupIsCurrent(_ token: UUID) -> Bool { generation == token && !Task.isCancelled }

    private func applySetupEvent(_ event: ConnectionSetup.Event, account: String, client: XMPPClient, token: UUID) async {
        // Runs in the setup child's task on the main actor, so a `.disconnected` handled before this job ran has
        // already cancelled it.
        guard setupIsCurrent(token) else { return }
        switch event {
        case .step(let step):
            if !session.isReady { session = .connected(settingUp: step) }
        case .ready:
            session = .ready
            reconnectAttempt = 0
            reportedSetupFailure = nil
            Self.syncLog.notice("ready +\(self.syncElapsed(), privacy: .public) ms")
            // Roster pushes are answered only after a fetch on this stream. Its result arrives as a
            // `.rosterItems` event, which then revokes and asks (see there).
            try? await client.fetchRoster()
            guard setupIsCurrent(token) else { return }
            await flushEncryptionControls(account: account, client: client, logsLiveStore: false)
            await refresh()
            guard setupIsCurrent(token) else { return }
            startOutbox()
            await reconcileUploads()
            if let openChatID { await loadEncryptionDetails(for: openChatID) }
            avatarChecked = []
            await loadAvatar(for: account)
        case .catchingUp(let progress):
            // First, before anything else reads it: a finished walk is `catchUp == nil`.
            catchUp = progress
            if let progress {
                catchUpByArchive[progress.archive ?? ""] = progress
                if progress.messages >= 1 { logFirstMessage() }
            } else {
                let pages = catchUpByArchive.values.reduce(0) { $0 + $1.pages }
                let messages = catchUpByArchive.values.reduce(0) { $0 + $1.messages }
                Self.syncLog.notice("catch-up finished +\(self.syncElapsed(), privacy: .public) ms pages=\(pages, privacy: .public) messages=\(messages, privacy: .public)")
                archiveWalkFinished = true
                requestOpportunisticBackfill()
                // XEP-0490 after the walk, so the ids other devices published name messages we now hold.
                syncReadState(account: account, client: client, token: token)
            }
        case .failed(let step, let detail):
            catchUp = nil
            if step == ConnectionSetup.archiveStep { Self.syncLog.notice("catch-up failed +\(self.syncElapsed(), privacy: .public) ms") }
            await reportSetupFailure(step: step, detail: detail, client: client, token: token)
        }
    }

    /// A half-alive session is a connection failure: mark it, end it, and let the reconciler retry.
    private func reportSetupFailure(step: String, detail: String, client: XMPPClient, token: UUID) async {
        let wasReady = session.isReady
        Logger(subsystem: "haus.xmpp.ios", category: "encryption").error("Encryption setup failed at \(step, privacy: .public): \(detail, privacy: .public)")
        session = .needsAttention(step: step, detail: detail)
        encryptionAttention.note("Setup failed at \(step): \(detail)")
        if reportedSetupFailure != detail {
            reportedSetupFailure = detail
            self.error = wasReady ? "Could not finish synchronizing (\(step): \(detail))."
                : "Could not prepare encryption (\(step): \(detail)). Your queued messages have not been sent."
        }
        await refresh()
        guard generation == token else { return }
        await client.disconnect()
    }

    private func syncElapsed() -> Int {
        guard let onlineAt else { return -1 }
        return Int((ContinuousClock.now - onlineAt) / .milliseconds(1))
    }

    private func logFirstMessage() {
        guard !firstMessageLogged else { return }
        firstMessageLogged = true
        Self.syncLog.notice("first message +\(self.syncElapsed(), privacy: .public) ms")
    }

    private func rejoinKnownGroups(account: String, client: XMPPClient, encryption: OMEMOService, token: UUID) async throws {
        let rooms = try await encryption.knownGroupRooms(account: account)
        for (room, members) in rooms.sorted(by: { $0.key < $1.key }) {
            guard setupIsCurrent(token), foreground, !quiescing else { throw CancellationError() }
            // Keep the cached devices (and a past join failure) across the rejoin; only the transport state restarts.
            groupChats[room, default: GroupChatState()].members = members
            let nickname = preferences.string(forKey: "groupNickname.\(account).\(room)") ?? String(account.prefix { $0 != "@" })
            // Rooms joined before the store kept the nickname learn it here; mention detection is best effort.
            try? await store?.setGroupNickname(accountID: account, room: room, nickname: nickname)
            do {
                let snapshot = try await client.joinGroupRoom(room, nickname: nickname)
                guard setupIsCurrent(token) else { throw CancellationError() }
                groupChats[room]?.joined = snapshot.joined
            } catch {
                guard setupIsCurrent(token) else { throw CancellationError() }
                groupChats[room]?.issue = groupFailure(error)
                // No send is allowed until this room's own authenticated presence is received.
                // Archive synchronization separately fails closed if room provenance is unavailable.
            }
        }
    }

    private func updateGroupPresence(_ room: String, token: UUID) async {
        guard groupChats[room] != nil, let client else { return }
        do {
            let value = try await client.groupRoomSnapshot(room)
            guard generation == token else { return }
            guard let snapshot = value else { groupChats[room]?.joined = false; return }
            groupChats[room]?.members = snapshot.members
            groupChats[room]?.joined = snapshot.joined
            groupChats[room]?.issue = nil
            if openChatID == room { await loadGroupDetails(room: room, refreshFromServer: false) }
            if snapshot.joined { startOutbox() }
        } catch {
            guard generation == token else { return }
            groupChats[room]?.joined = false
            groupChats[room]?.issue = groupFailure(error)
        }
    }

    /// Group devices from the store first, then from the server. The pill follows the cached devices; joining only
    /// gates sending. `force` defaults to true for the group page and its Refresh button; opening the chat passes
    /// false, so pop-back reuses this connection's refresh and a reconnect fetches once more. A failed refresh
    /// writes the diagnostics footer only.
    func loadGroupDetails(room: String, refreshFromServer: Bool = true, force: Bool = true) async {
        guard foreground, !quiescing, let encryption, isGroup(room) else { return }
        activeEncryptionOperations += 1
        defer { activeEncryptionOperations -= 1 }
        let account = accountID, token = generation
        do {
            let cached = try await encryption.cachedGroupDevices(account: account, room: room)
            guard generation == token, accountID == account else { return }
            groupChats[room]?.devices = cached
            groupChats[room]?.devicesLoaded = true
        } catch {
            guard generation == token, accountID == account, !(error is CancellationError) else { return }
            encryptionAttention.groupDevices(room, problem: "Stored group devices could not be read: \(groupFailure(error))")
        }
        // Only for the group page's own fingerprint row; a missing identity is created on the next connect.
        if let identity = try? await encryption.localIdentity(account: account, profile: .modern), generation == token, accountID == account {
            groupChats[room]?.localDeviceID = identity.deviceID
            groupChats[room]?.localFingerprint = identity.fingerprint
        }
        guard refreshFromServer, force || refreshFence[room]?.generation != token,
              hasTransportOwnership, isConnected, encryptionReady, let client else { return }
        do {
            let overview = try await encryption.refreshGroupDevices(account: account, room: room, transport: client)
            // Device refresh persists policy after its room snapshot. Own presence may
            // change during those awaits; display the transport's current join state.
            let current = try await client.groupRoomSnapshot(room)
            guard generation == token else { return }
            groupChats[room]?.members = current?.members ?? overview.room.members
            groupChats[room]?.joined = current?.joined == true
            groupChats[room]?.issue = nil
            let devices = try await encryption.cachedGroupDevices(account: account, room: room)
            guard generation == token, accountID == account else { return }
            groupChats[room]?.devices = devices
            groupChats[room]?.devicesLoaded = true
            let note = "Last group refresh: \(devices.filter(\.active).count) active devices"
            refreshFence[room] = (token, note)
            encryptionAttention.groupDevices(room, problem: nil)
            encryptionAttention.note(note)
        } catch {
            guard generation == token, accountID == account, !(error is CancellationError) else { return }
            // Read-only text under the Group Details pill and in the footer; the cached trust keeps deciding the pill.
            encryptionAttention.groupDevices(room, problem: "Last group refresh failed: \(groupFailure(error))")
        }
    }

    private func groupFailure(_ error: any Error) -> String {
        switch error as? XMPPGroupError {
        case .unsupportedRoom: return "This group must be members-only and share its members’ addresses."
        case .incompleteMembership: return "The group could not confirm its complete member list or your membership."
        case .membershipChanged: return "Group membership changed. Refresh the group and try again."
        case .notJoined: return "This account has not joined the group yet."
        default: return (error as? OMEMOError)?.errorDescription ?? "Could not open this group. Check its address and your membership."
        }
    }

    /// The chat's ID (the address in normal form), or nil with `error` set.
    func createChat(_ recipient: String) async -> String? {
        // `Bob@Example.org` is the chat the server's `bob@example.org` replies land in.
        let address = JID(recipient.trimmingCharacters(in: .whitespacesAndNewlines))
        guard !accountID.isEmpty, let address, address.localpart != nil, address.resourcepart == nil, let store else {
            error = "Enter a contact address such as bob@localhost."
            return nil
        }
        let recipient = address.bare
        guard isDemo || !isLabAccount || recipient.hasSuffix("@" + accountDomain) else {
            error = "Lab accounts only message other accounts on the same lab server."
            return nil
        }
        do {
            try await store.upsertChat(accountID: accountID, chatID: recipient, title: recipient)
            await refresh()
            return recipient
        } catch { self.error = "Could not create conversation."; return nil }
    }

    func send(_ body: String, to chatID: String, replyingTo source: ChatMessage? = nil) async -> Bool {
        guard !isSending, let store, !accountID.isEmpty,
              !body.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              body.utf8.count <= 16_384 else { return false }
        isSending = true
        defer { isSending = false }
        let account = accountID
        let sample = isDemo
        guard sample || isGroup(chatID) || !isLabAccount || chatID.hasSuffix("@" + accountDomain) else { return false }
        if isGroup(chatID), !canSend(to: chatID) { error = "Wait until this account has joined the group before sending."; return false }
        if let source, source.accountID != account || source.chatID != chatID { return false }
        let reply = source.map { MessageReply(messageID: $0.id, senderID: $0.senderID, body: $0.body, wireID: !isGroup(chatID) && $0.isOutgoing && $0.transportState != nil ? $0.id : nil) }
        let message = StoredMessage(id: UUID().uuidString, accountID: account, chatID: chatID,
                                    senderID: account, body: body, isOutgoing: true, reply: reply, encryptionProfile: sample ? nil : "pending")
        do {
            try XMPPClient.validateMessage(to: chatID, body: body, id: message.id, reply: Self.wireReply(message.reply))
        } catch {
            self.error = "This message or quoted text is too long or contains unsupported characters. Your text is still in the composer."
            return false
        }
        do {
            if sample { try await store.insertMessage(message) }
            else { try await store.enqueueOutgoing(message) }
            await refresh()
            startOutbox()
            return true // Accepted durably, not delivered.
        } catch {
            if accountID == account { self.error = "Could not save the message. Your text is still in the composer." }
            return false
        }
    }

    func retryMessage(_ id: String) async {
        guard let store else { return }
        do {
            try await store.retryOutgoing(accountID: accountID, messageID: id)
            uploadFailures.reset(id)
            await refresh()
            // A file that gave up uploading goes back to the uploader; everything else to the outbox.
            startUploads()
            startOutbox()
        } catch { self.error = "This message could not be queued again." }
    }

    private nonisolated static func wireReply(_ reply: MessageReply?) -> XMPPReply? {
        reply.map { XMPPReply(id: $0.wireID, to: $0.senderID, body: $0.body) }
    }

    func canReact(to message: StoredMessage) -> Bool {
        guard message.accountID == accountID, message.chatID == openChatID,
              message.encryptionProfile == "modern" || message.encryptionProfile == "legacy" else { return false }
        if isGroup(message.chatID) { return message.encryptionProfile == "modern" && canSend(to: message.chatID) && reactableGroupMessages.contains(message.id) }
        if encryptionOverview?.profile == .modern { return message.wireIDAuthenticated && message.wireID != nil }
        // Legacy peers (Conversations) only speak unencrypted XEP-0444; queued like everything else.
        return encryptionOverview?.profile == .legacy && message.wireID != nil
    }

    func toggleReaction(_ emoji: String, messageID: String) async {
        guard hasTransportOwnership, foreground, !quiescing else { return }
        activeEncryptionOperations += 1
        defer { activeEncryptionOperations -= 1 }
        guard let encryption, let message = messages.first(where: { $0.id == messageID }), canReact(to: message) else { return }
        let account = accountID, token = generation
        let mine = messageReactions[messageID]?.first(where: { $0.actorID == account })?.reactions ?? []
        do {
            _ = try await encryption.queueReactions(account: account, chatID: message.chatID, messageID: messageID,
                                                     reactions: mine.contains(emoji) ? [] : [emoji])
            guard generation == token else { return }
            await refresh(.openChat)
            startOutbox()
        } catch {
            if generation == token { self.error = (error as? OMEMOError)?.errorDescription ?? "Could not save your reaction." }
        }
    }

    /// Own direct messages with a resolvable reference can be unsent or rewritten; sample chats project only.
    func canRevise(_ message: StoredMessage) -> Bool {
        guard message.accountID == accountID, message.chatID == openChatID, message.isOutgoing, !message.isRetracted, message.unreadableReason == nil,
              !isGroup(message.chatID) else { return false }
        if isDemo { return true }
        // ponytail: rooms wait for the group envelope path; mirrors the direct-chat half of canReact.
        return canReact(to: message)
    }

    func unsend(messageID: String) async { await revise(messageID: messageID, body: nil) }
    func edit(messageID: String, body: String) async -> Bool { await revise(messageID: messageID, body: body) }

    @discardableResult private func revise(messageID: String, body: String?) async -> Bool {
        guard let store, let message = messages.first(where: { $0.id == messageID }), canRevise(message) else { return false }
        if let body {
            guard !body.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty, body.utf8.count <= 16_384, body != message.body else { return false }
        }
        let account = accountID, token = generation
        do {
            if isDemo {
                guard let wireID = message.wireID else { return false }
                let kind: MessageEventKind = body == nil ? .retraction : .correction
                try await store.recordEvent(accountID: account, event: MessageEvent(id: UUID().uuidString, chatID: message.chatID, actorID: account, targetWireID: wireID,
                    kind: kind, payload: body.map { try MessageEvent.correctionPayload($0) } ?? "{}", updatedAt: Date()))
            } else {
                guard hasTransportOwnership, foreground, !quiescing, let encryption else { return false }
                activeEncryptionOperations += 1
                defer { activeEncryptionOperations -= 1 }
                if let body { _ = try await encryption.queueCorrection(account: account, chatID: message.chatID, messageID: messageID, body: body) }
                else { _ = try await encryption.queueRetraction(account: account, chatID: message.chatID, messageID: messageID) }
            }
            guard generation == token else { return false }
            await refresh()
            startOutbox()
            return true
        } catch {
            if generation == token { self.error = (error as? OMEMOError)?.errorDescription ?? (body == nil ? "Could not unsend this message." : "Could not save your edit.") }
            return false
        }
    }

    private func startOutbox() {
        outboxRequested = true
        guard hasTransportOwnership, foreground, !quiescing, drainTask == nil, session.isReady, !isDemo,
              let client, let outboxSender, let encryption, let store else { return }
        outboxRequested = false
        let joinedGroups = Set(groupChats.filter { $0.value.joined }.map(\.key))
        let account = accountID
        let token = generation
        drainTask = Task { [weak self] in
            do {
                let drain = OutboxDrain(account: account, client: client, encryption: encryption, store: store,
                                        sender: outboxSender, joinedGroups: joinedGroups)
                let heldForTrust = try await drain.run(OutboxDrain.Hooks(
                    hold: { [weak self] blocked in
                        guard let self, self.generation == token else { return [] }
                        return self.encryptionAttention.hold(blocked, shownChat: self.encryptionShownChatID)
                    },
                    groupPrepared: { [weak self] room in
                        if let self, self.generation == token { self.groupChats[room]?.issue = nil }
                    },
                    groupFailed: { [weak self] room, error in
                        guard let self, self.generation == token else { return [] }
                        self.groupChats[room]?.issue = self.groupFailure(error)
                        return self.encryptionAttention.hold([room: self.groupFailure(error)], shownChat: self.encryptionShownChatID)
                    },
                    didChange: { [weak self] in await self?.refresh() }))
                if let self, self.generation == token { self.encryptionAttention.settlePass(heldForTrust: heldForTrust) }
                await self?.refresh()
            } catch {
                if let self, self.generation == token {
                    // Not tied to one chat, so it cannot mark one for review; the held chats keep their marks, and a
                    // trust problem shows through the stored devices re-read below.
                    self.encryptionAttention.note((error as? OMEMOError)?.errorDescription ?? "Encryption could not be prepared. Messages remain saved.")
                    if let chat = self.openChatID { await self.loadEncryptionDetails(for: chat, refreshFromServer: false) }
                }
            }
            guard let self else { return }
            self.drainTask = nil
            self.drainPasses += 1
            // A different account/session may have become ready while this attempt settled.
            if self.outboxRequested || self.generation != token { self.startOutbox() }
            // Catch-up often finishes while the first drain of a connection is still running; the
            // deferred history fetch runs now instead of waiting for the next connection.
            if self.generation == token { self.requestOpportunisticBackfill() }
        }
    }

    /// Once per connection, after the archive walk and while no outbox drain is running: fetch a few pages of
    /// older history so a new install shows more than the newest page without a scroll.
    private func requestOpportunisticBackfill() {
        guard archiveWalkFinished, !opportunisticBackfillDone, foreground, !quiescing, drainTask == nil else { return }
        opportunisticBackfillDone = true
        requestBackfill(archive: nil, pages: AppModel.opportunisticBackfillPages)
    }

    private func startNotificationNavigation() {
        guard notificationTapTask == nil, testSessionID == nil, store != nil,
              !ProcessInfo.processInfo.arguments.contains("--inspect-notification"), !isDemo else { return }
        let taps = NotificationNavigation.shared.taps
        notificationTapTask = Task { [weak self] in
            for await destination in taps {
                guard !Task.isCancelled else { return }
                await self?.routeNotification(destination)
            }
        }
    }

    func consumeNotificationRoute(_ id: UUID) {
        if notificationRoute?.id == id { notificationRoute = nil }
    }

    /// Pushes a page onto the Chats stack from a view without a navigation path; RootView performs it.
    func requestRoute(_ route: ChatRoute) { requestedRoute = route }

    private func routeNotification(_ destination: NotificationDestination) async {
        guard testSessionID == nil, !isDemo,
              !ProcessInfo.processInfo.arguments.contains("--inspect-notification"), let store else { return }
        // A tap never prompts for another account, creates a chat or changes endpoints.
        guard let account = authorizedNotificationAccount(),
              let message = try? await destination.resolve(accountID: account, store: store),
              authorizedNotificationAccount() == account else { return }
        notificationRoute = NotificationChatRoute(accountID: account, chatID: message.chatID)
    }

    /// The synchronous half of opening, run before the pushed screen's first frame: resets the open chat's projection
    /// and shows its cached page while the chat list still shows the same newest message. A chat already shown stays.
    func prepareChat(_ chatID: String) {
        guard openChatID != chatID || messagesLoadedFor != chatID else { return }
        openChatID = chatID; timelineWindow = AppModel.timelinePage; messages = []; messagesLoadedFor = nil; messageReactions = [:]; messageReceipts = [:]; attachmentFiles = [:]
        if let page = timelinePages.page(for: chats.first { $0.id == chatID }, account: accountID) { publishTimeline(page, chat: chatID) }
    }

    func openChat(_ chatID: String) async {
        prepareChat(chatID)
        // The chat is on screen: its delivered notifications have done their job.
        if !isDemo { let account = accountID; Task { await DeliveredNotificationCleaner.removeThread(accountID: account, chatID: chatID) } }
        // Reactions have no read state: an opened chat shows them, so waiting reaction alerts go (plan D8). Only under the
        // transport lease: without it an extension run may be posting them right now, and the lease acquisition repeats
        // this for the open chat once that run is over (`dismissOpenChatNotifications`).
        if foreground, hasTransportOwnership, !quiescing, let store {
            let account = accountID
            Task { try? await store.dismissReactionNotifications(accountID: account, chatID: chatID) }
        }
        // Keep the same chat's devices across pop-back and reconnect; another chat starts pending until its store read.
        if encryptionOverviewChatID != chatID { encryptionOverviewChatID = chatID; encryptionOverview = nil }
        encryptionDetailsChatID = chatID
        // First paint without a cached page: the whole window now, before the chat list, so the refresh below
        // publishes the same rows and the timeline has nothing to change.
        let account = accountID
        if messagesLoadedFor != chatID, let store, let page = try? await loadTimeline(store: store, account: account, chat: chatID, isGroup: isGroup(chatID), limit: timelineWindow),
           accountID == account, openChatID == chatID, messagesLoadedFor != chatID { publishTimeline(page, chat: chatID) }
        await refresh()
        // The chat may only now be listed (a new conversation); then ask about its contact in the background.
        syncOpenChatLastSeen()
        if openChatID == chatID { requestLastSeen(for: chatID) }
        if !isDemo { await loadEncryptionDetails(for: chatID) }
    }

    /// Publishes the chat's stored devices at once (no network, offline too), then re-fetches them from the server
    /// at most once per connection: opening the chat again or popping back reuses the result, a reconnect fetches
    /// once more. `force` (the Refresh button, a server device-list push) and a version switch always fetch.
    /// A failed fetch writes the diagnostics footer only; the stored trust keeps deciding the pill.
    func loadEncryptionDetails(for chatID: String, refreshFromServer: Bool = true, profile: XMPPOMEMOProfile? = nil, force: Bool = false) async {
        guard foreground, !quiescing else { return }
        activeEncryptionOperations += 1
        defer { activeEncryptionOperations -= 1 }
        guard let encryption, !isDemo else { return }
        if isGroup(chatID) { await loadGroupDetails(room: chatID, refreshFromServer: refreshFromServer, force: force); return }
        let account = accountID
        let token = generation
        // The pushed details pages cover the conversation, which clears openChatID; the latest request is the fence.
        encryptionDetailsChatID = chatID
        var isCurrent: Bool { accountID == account && generation == token && encryptionDetailsChatID == chatID }
        // A version switch shows the requested version's devices only once they are fetched.
        if profile == nil {
            do {
                let stored = try await encryption.overview(account: account, peer: chatID)
                guard isCurrent else { return }
                encryptionOverviewChatID = chatID
                encryptionOverview = stored
            } catch {
                guard isCurrent else { return }
                encryptionAttention.note(Self.storedDevicesUnreadable)
            }
        }
        guard refreshFromServer else { return }
        if !force, profile == nil, let fence = refreshFence[chatID], fence.generation == token {
            encryptionAttention.note(fence.note)
            return
        }
        guard hasTransportOwnership, encryptionReady, isConnected, let client else {
            if !encryptionDiagnostics.hasPrefix("Setup failed"), encryptionOverview(for: chatID) != nil {
                encryptionAttention.note(isConnected ? "Not refreshed: encryption setup has not completed on this connection." : "Not refreshed: offline.")
            }
            return
        }
        do {
            let overview = try await encryption.refreshDevices(account: account, peer: chatID, profile: profile, transport: client)
            guard isCurrent else { return }
            encryptionOverviewChatID = chatID
            encryptionOverview = overview
            let summary = [chatID, account].map { owner -> String in
                let name = owner == account ? "you" : AppModel.displayName(for: owner, title: nil)
                let advertised = overview.advertisedDevices[owner] ?? 0
                let missing = overview.unavailableDevices[owner] ?? 0
                let active = overview.devices.filter { $0.jid == owner && $0.active && $0.profile == overview.profile
                    && !(owner == account && $0.deviceID == overview.localDeviceID) }.count
                return "\(name): \(advertised) advertised, \(active) usable" + (missing > 0 ? ", \(missing) without keys" : "")
            }.joined(separator: " · ")
            let note = "Last refresh (\(overview.profile.label)): \(summary)"
            refreshFence[chatID] = (token, note)
            encryptionAttention.note(note)
            Logger(subsystem: "haus.xmpp.ios", category: "encryption").info("Device refresh: \(summary, privacy: .public)")
        } catch {
            guard isCurrent else { return }
            let detail: String
            if case .stanza(let condition)? = error as? XMPPIQError { detail = condition } else { detail = String(describing: error).prefix(80).description }
            Logger(subsystem: "haus.xmpp.ios", category: "encryption").error("Device refresh for \(chatID, privacy: .private) failed: \(detail, privacy: .public)")
            let friendly: String
            switch detail {
            case "remote-server-not-found", "remote-server-timeout": friendly = "Their server could not be reached. Try again in a moment."
            case "forbidden", "not-authorized", "not-allowed": friendly = "Their server refused to share their devices."
            default: friendly = "Could not fetch encryption devices."
            }
            encryptionAttention.note("Last refresh failed (\(detail)). \((error as? OMEMOError)?.errorDescription ?? friendly)")
        }
    }

    /// The store has no readable devices for this account (it has not set up encryption yet, or the keys are unavailable).
    static let storedDevicesUnreadable = "No stored devices yet. They appear after this account connects."

    /// What is known about a chat's devices: pending until the store answered, then stored, then refreshed on this connection.
    func encryptionKnowledge(for chatID: String) -> EncryptionKnowledge {
        let refreshed = refreshFence[chatID]?.generation == generation
        if let group = groupChats[chatID] {
            guard group.devicesLoaded else { return .pending }
            let facts = DeviceTrustFacts(group, account: accountID)
            return refreshed ? .refreshed(facts) : .stored(facts)
        }
        guard let overview = encryptionOverview(for: chatID) else { return .pending }
        let facts = DeviceTrustFacts(overview, peer: chatID)
        return refreshed ? .refreshed(facts) : .stored(facts)
    }

    /// The stored overview when it belongs to `chatID`; nil while another chat's is loaded or the store has not answered.
    func encryptionOverview(for chatID: String) -> EncryptionOverview? {
        encryptionOverviewChatID == chatID ? encryptionOverview : nil
    }

    func setDeviceTrust(_ device: EncryptionDevice, trust: DeviceTrust, chatID: String) async {
        guard hasTransportOwnership, foreground, !quiescing else { return }
        activeEncryptionOperations += 1
        defer { activeEncryptionOperations -= 1 }
        guard let encryption else { return }
        let account = accountID
        let token = generation
        do {
            try await encryption.setTrust(account: account, deviceID: device.id, trust: trust)
            guard generation == token else { return }
            encryptionAttention.trustDecided(in: chatID)
            // A group re-fetches on this connection too: its recipients are re-validated against the room.
            await loadEncryptionDetails(for: chatID, refreshFromServer: isGroup(chatID), force: isGroup(chatID))
            guard generation == token else { return }
            if let client, isConnected {
                // A trust decision can only unblock rows that waited for trust; keys-pending rows wait for device lists.
                try? await encryption.retryPendingIncoming(account: account, transport: client, reasons: [.trustPending])
                guard generation == token else { return }
                // Released messages leave the retained rows: the other version's waiting devices go with them.
                if !isGroup(chatID) { await loadEncryptionDetails(for: chatID, refreshFromServer: false) }
                await flushEncryptionControls(account: account, client: client)
                await refresh()
                startOutbox()
            }
        } catch { if generation == token { self.error = "This device changed. Refresh its fingerprint before reviewing it again." } }
    }

    func repairDeviceSession(_ device: EncryptionDevice, chatID: String) async {
        guard hasTransportOwnership, foreground, !quiescing else { return }
        activeEncryptionOperations += 1
        defer { activeEncryptionOperations -= 1 }
        guard let encryption, let client, isConnected else { return }
        let account = accountID, token = generation
        do {
            try await encryption.repairSession(account: account, deviceID: device.id, transport: client)
            guard generation == token else { return }
            await flushEncryptionControls(account: account, client: client)
            await loadEncryptionDetails(for: chatID, refreshFromServer: false)
            startOutbox()
        } catch {
            if generation == token { self.error = (error as? OMEMOError)?.errorDescription ?? "Could not repair this session. Your identity and saved messages are unchanged." }
        }
    }

    func retireDevice(_ device: EncryptionDevice, chatID: String) async {
        guard hasTransportOwnership, foreground, !quiescing else { return }
        activeEncryptionOperations += 1
        defer { activeEncryptionOperations -= 1 }
        guard let encryption, let client, isConnected else { return }
        let account = accountID, token = generation
        do {
            try await encryption.retireOwnDevice(account: account, deviceID: device.id, transport: client)
            guard generation == token else { return }
            // The server's device list just changed, so the per-connection fence must not skip the re-fetch.
            await loadEncryptionDetails(for: chatID, force: true)
        } catch {
            if generation == token { self.error = (error as? OMEMOError)?.errorDescription ?? "Could not remove this device. Refresh its fingerprint and try again." }
        }
    }
    /// `logsLiveStore`: the event loop calls this after every stored live message; during catch-up the first
    /// one is logged for the lab measurement (not a general metric).
    private func flushEncryptionControls(account: String, client: XMPPClient, logsLiveStore: Bool = true) async {
        guard accountID == account, self.client === client else { return }
        if logsLiveStore, catchUp != nil, !liveStoredLogged {
            liveStoredLogged = true
            logFirstMessage()
            Self.syncLog.notice("live stored +\(self.syncElapsed(), privacy: .public) ms")
        }
        try? await encryption?.flushBundlePublications(account: account, transport: client)
        // Key transports are ordinary durable updates; the outbox drain sends them.
        startOutbox()
    }

    /// The reader reached the oldest loaded message. A full window means the store may hold more; otherwise the
    /// store is exhausted for this chat and the server's older archive pages are the next source.
    func loadOlderMessages(all: Bool = false) async {
        guard !loadingOlder, let chat = openChatID else { return }
        if all || messages.count >= timelineWindow {
            guard timelineWindow < AppModel.timelineCeiling else { return }
            loadingOlder = true
            defer { loadingOlder = false }
            timelineWindow = all ? AppModel.timelineCeiling : min(AppModel.timelineCeiling, timelineWindow + AppModel.timelinePage)
            await refresh(.openChat)
            return
        }
        // The window is not raised here: each committed page reloads the same window, which fills further, and the
        // next reach-top raises it as above.
        requestBackfill(archive: isGroup(chat) ? chat : nil, pages: AppModel.backfillPagesPerScroll)
    }

    /// True while the archive holding `chat` (the account's own for a direct chat, the room's for a group) backfills.
    func isBackfilling(chat: String) -> Bool { backfillingArchive != nil && backfillingArchive == (isGroup(chat) ? chat : accountID) }

    /// Starts one bounded backfill of older archive pages. This connection's forward walk must have finished and no
    /// other backfill may run: `XMPPClient` allows one archive query at a time. `resetSession` cancels it, and
    /// `connect` and `quiesceTransport` join it before the next connection or the lease release. The loading cell shows
    /// only once the store says there is something to fetch, so a chat with no older history never flashes it.
    private func requestBackfill(archive: String?, pages: Int) {
        let archiveID = archive ?? accountID
        guard foreground, !quiescing, hasTransportOwnership, session.isReady, archiveWalkFinished, catchUp == nil, backfillTask == nil, !isDemo,
              !backfillSettled.contains(archiveID), backfillResumesAt.map({ ContinuousClock.now >= $0 }) ?? true,
              let client, let encryption, let store else { return }
        let account = accountID
        let token = generation
        let started = ContinuousClock.now
        let synchronizer = ArchiveSynchronizer(store: store)
        backfillTask = Task { [weak self] in
            let kind = archive == nil ? "direct" : "room"
            var settled = false
            do {
                let pending = try await synchronizer.hasPendingBackfill(account: account, archive: archive)
                if pending, let model = self, model.generation == token, !Task.isCancelled {
                    model.backfillingArchive = archiveID
                    let outcome = try await synchronizer.backfill(account: account, archive: archive, pageBudget: pages,
                                                                  client: client, encryption: encryption) { [weak self] progress in
                        await self?.backfillPageCommitted(progress, token: token)
                    }
                    // Only a spent budget leaves more to ask for on this connection; a refusal is retried on the next one.
                    settled = outcome != .budgetExhausted
                    let elapsed = Int((ContinuousClock.now - started) / .milliseconds(1))
                    Self.syncLog.notice("backfill \(kind, privacy: .public) \(String(describing: outcome), privacy: .public) +\(elapsed, privacy: .public) ms")
                } else {
                    settled = !pending
                    if !pending { Self.syncLog.notice("backfill \(kind, privacy: .public) nothing pending") }
                }
            } catch {
                // The synchronizer disconnected if a page was abandoned; the reconciler reconnects.
                Self.syncLog.error("backfill \(kind, privacy: .public) failed: \(String(String(describing: error).prefix(120)), privacy: .public)")
            }
            guard let self, self.generation == token else { return }
            if settled { self.backfillSettled.insert(archiveID) }
            self.backfillResumesAt = ContinuousClock.now + .seconds(1)
            let showed = self.backfillingArchive != nil
            self.backfillingArchive = nil
            self.backfillTask = nil
            // Older pages can add chats (and placeholders) the list has not shown yet.
            if showed { self.refreshSoon() }
        }
    }

    /// The store holds a new page of older messages: reload the open chat's window, which now reaches further back.
    private func backfillPageCommitted(_ progress: ArchiveSyncProgress, token: UUID) {
        guard generation == token else { return }
        Self.syncLog.notice("backfill page pages=\(progress.pages, privacy: .public) messages=\(progress.messages, privacy: .public)")
        refreshSoon(.openChat)
    }

    func closeChat(_ chatID: String) {
        if ownTyping?.chat == chatID { sendOwnTyping(ownTyping?.sender.left(), to: chatID); ownTyping = nil; ownTypingPause?.cancel() }
        guard openChatID == chatID else { return }
        // Kept so coming back, or popping back from Chat Details, shows the same tail in the first frame.
        if messagesLoadedFor == chatID {
            timelinePages.store(TimelinePage(messages: Array(messages.suffix(AppModel.timelinePage)), reactions: messageReactions, receipts: messageReceipts,
                                             reactableGroupMessages: reactableGroupMessages), for: chats.first { $0.id == chatID }, account: accountID)
        }
        openChatID = nil; messages = []; messagesLoadedFor = nil; messageReactions = [:]; messageReceipts = [:]; attachmentFiles = [:]
    }

    // MARK: Typing

    /// The composer's draft in `chatID` changed: the peer hears composing, then paused after a quiet spell, or active once it empties.
    func draftChanged(_ draft: String, in chatID: String) {
        guard canSendChatState(to: chatID) else { return }
        if ownTyping?.chat != chatID { ownTyping = (chatID, TypingSender()) }
        let isEmpty = draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        sendOwnTyping(ownTyping?.sender.draftChanged(isEmpty: isEmpty, now: .now), to: chatID)
        ownTypingPause?.cancel()
        guard !isEmpty else { return }
        ownTypingPause = Task { [weak self] in
            try? await Task.sleep(for: .seconds(TypingSender.pauseAfter))
            guard let self, !Task.isCancelled, ownTyping?.chat == chatID else { return }
            sendOwnTyping(ownTyping?.sender.idle(), to: chatID)
        }
    }

    /// Only a listed chat we could send a message to right now; never the sample data, and not while sending is paused for review.
    private func canSendChatState(to chatID: String) -> Bool {
        !isDemo && session.isReady && hasTransportOwnership && foreground && !quiescing && chatCapabilities(chatID).encryption != .needsReview
            && chatID != accountID && chats.contains(where: { $0.id == chatID }) && canSend(to: chatID)
            && (isGroup(chatID) || !isLabAccount || chatID.hasSuffix("@" + accountDomain))
    }

    /// Chained, so states reach the wire in the order they were decided.
    private func sendOwnTyping(_ state: XMPPChatState.State?, to chatID: String) {
        guard let state, let client, canSendChatState(to: chatID) else { return }
        let group = isGroup(chatID), previous = ownTypingSend
        ownTypingSend = Task { await previous?.value; try? await client.sendChatState(state, to: chatID, groupchat: group) }
    }

    private func publishTyping() {
        guard !isDemo else { return } // the sample typing stays put
        typingTracker.expire(now: .now)
        let current = typingTracker.typing
        if current != typing { typing = current }
        typingExpiry?.cancel()
        guard let next = typingTracker.nextExpiry else { return }
        typingExpiry = Task { [weak self] in
            try? await Task.sleep(for: .seconds(max(0.05, next.timeIntervalSinceNow)))
            guard !Task.isCancelled else { return }
            self?.publishTyping()
        }
    }

    private func syncOpenChatTyping() {
        let open = openChatID.flatMap { typing[$0] }
        if open != openChatTyping { openChatTyping = open }
    }

    /// The demo's fixed header samples; a real chat starts unknown until presence says otherwise.
    private static let demoLastSeen: [String: LastSeen] = [
        "alex@preview.local": .online,
        "maya@preview.local": .lastSeen(Date(timeIntervalSince1970: 1_789_380_000)),
    ]

    private func syncOpenChatLastSeen() {
        let open = openChatID.flatMap { chat in
            isDemo ? AppModel.demoLastSeen[chat] : isDirectChat(chat) ? lastSeenTracker.lastSeen(for: chat) : nil
        }
        if open != openChatLastSeen { openChatLastSeen = open }
    }

    /// A listed 1:1 chat with someone else: the only chats whose presence we track and whose requests we approve.
    private func isDirectChat(_ chatID: String) -> Bool {
        chatID != accountID && !isGroup(chatID) && chats.contains(where: { $0.id == chatID })
    }

    /// A new stream re-learns who is available; the last departure and last-activity answer stay so the header
    /// does not blank across a reconnect.
    private func resetPresence() {
        lastSeenTracker.resetConnection()
        syncOpenChatLastSeen()
    }

    /// Asks about a 1:1 contact without holding up the caller: a presence subscription once per connection, or a
    /// XEP-0012 query at most once a minute while the contact shows no available resource. Asking does not depend
    /// on our own switch. A refused or failed query leaves the header unknown and shows no error.
    private func requestLastSeen(for chatID: String) {
        guard !isDemo, session.isReady, foreground, !quiescing, let client, isDirectChat(chatID) else { return }
        let token = generation
        switch lastSeenTracker.askStep(for: chatID, now: .now) {
        case .nothing: return
        case .subscribe:
            Task { try? await client.sendSubscription(.subscribe, to: chatID) }
        case .queryLastActivity:
            Task { [weak self] in
                guard let seconds = try? await client.lastActivity(of: chatID), let self, self.generation == token else { return }
                self.lastSeenTracker.recordLastActivity(seconds: seconds, of: chatID, now: .now)
                self.syncOpenChatLastSeen()
            }
        }
    }

    /// Withdraws our presence from `contacts` (RFC 6121 §3.2). Stops at the first failure; the next connection's
    /// roster load retries while the switch stays off.
    private func revokePresenceSharing(_ contacts: [String], token: UUID) async {
        guard let client, !contacts.isEmpty else { return }
        for contact in contacts where contact != accountID {
            guard generation == token, !accountPreferences.lastSeen else { return }
            do { try await client.sendSubscription(.unsubscribed, to: contact) } catch { return }
        }
    }

    private func resetTyping() {
        typingTracker = TypingTracker()
        typingExpiry?.cancel()
        if !typing.isEmpty { typing = [:] }
        ownTyping = nil
        ownTypingPause?.cancel()
    }

    var notificationPreviewsEnabled = true

    func setNotificationPreviews(_ enabled: Bool) async { await updatePreferences { $0.notificationPreviews = enabled } }

    /// Every per-account switch is one row written under the transport lease; the store enforces the receipt switches.
    func updatePreferences(_ change: (inout AccountPreferences) -> Void) async {
        guard foreground, !quiescing, let store, !accountID.isEmpty else { return }
        let account = accountID
        let token = generation
        activeEncryptionOperations += 1
        defer { activeEncryptionOperations -= 1 }
        var updated = accountPreferences
        change(&updated)
        do {
            if !hasTransportOwnership { try await acquireForegroundOwnership(store, token: token) }
            guard generation == token else { return }
            try await store.setAccountPreferences(accountID: account, updated)
            // Previews off: names and avatars donated while they were on leave the system too. The lease is held, so
            // no extension run is donating meanwhile, and later runs read the new setting.
            if CommunicationHistory.purgesDonations(from: accountPreferences, to: updated) { await CommunicationHistory.deleteAll() }
            guard accountID == account else { return }
            let sharedLastSeen = accountPreferences.lastSeen
            accountPreferences = updated; notificationPreviewsEnabled = updated.notificationPreviews
            guard updated.lastSeen != sharedLastSeen, generation == token, let client else { return }
            // On only answers queries again; contacts we chat with are approved as they ask. Off revokes every
            // subscription to our presence now, or on the next connection's roster load when offline.
            await client.setSharesLastActivity(updated.lastSeen)
            if !updated.lastSeen, session.isReady, lastSeenTracker.rosterLoaded {
                await revokePresenceSharing(lastSeenTracker.sharingWith, token: token)
            }
        } catch { self.error = "Could not save preferences." }
    }

    /// The timeline showed the newest received message while the app is in front: the chat is read up to it on this
    /// device (published with XEP-0490), and the peer gets a read marker when the read-receipts switch allows.
    func markDisplayed(_ messageID: String) async {
        guard foreground, !quiescing, let store,
              let message = messages.first(where: { $0.id == messageID }), !message.isOutgoing, message.chatID == openChatID else { return }
        let account = accountID, token = generation
        // Local-first and independent of the read-receipts switch, which governs only what the peer is told.
        if (try? await store.markRead(accountID: account, chatID: message.chatID, throughMessageID: messageID)) == true, generation == token {
            refreshSoon(.chats)
            publishReadState()
        }
        guard hasTransportOwnership, !isDemo, let encryption, generation == token,
              message.encryptionProfile == "modern" || message.encryptionProfile == "legacy" else { return }
        activeEncryptionOperations += 1
        defer { activeEncryptionOperations -= 1 }
        let queued = (try? await encryption.queueReceipt(account: account, chatID: message.chatID, messageID: messageID, kind: .marker)) ?? nil
        guard queued != nil, generation == token else { return }
        startOutbox()
    }

    /// The chat list's Read action: everything in the chat counts as read here and on the account's other devices.
    /// The peer is not sent a read marker: nothing was shown.
    func markChatRead(_ chatID: String) async {
        guard let store else { return }
        let account = accountID
        guard (try? await store.markChatRead(accountID: account, chatID: chatID)) == true, accountID == account else { return }
        await refresh(.chats)
        publishReadState()
    }

    /// Publishes this device's pending reads (XEP-0490) while the session is ready. Counted as an operation so a
    /// background transition joins it; what fails stays pending in the store for the next connection.
    private func publishReadState() {
        guard !isDemo, session.isReady, !quiescing, let client, let store else { return }
        guard !publishingReadState else { readStateChangedWhilePublishing = true; return }
        publishingReadState = true
        let account = accountID, token = generation
        activeEncryptionOperations += 1
        Task {
            defer { publishingReadState = false; activeEncryptionOperations -= 1 }
            repeat {
                readStateChangedWhilePublishing = false
                guard generation == token, !quiescing else { return }
                do { try await ReadSync(store: store).push(account: account, client: client) }
                catch { Self.syncLog.notice("read state not published: \(ConnectionSetup.detail(error), privacy: .public)"); return }
            } while readStateChangedWhilePublishing
        }
    }

    /// After catch-up: apply what the account's other devices read (XEP-0490 items), then publish our own reads.
    private func syncReadState(account: String, client: XMPPClient, token: UUID) {
        guard !isDemo, let store, let encryption else { return }
        activeEncryptionOperations += 1
        Task {
            defer { activeEncryptionOperations -= 1 }
            do {
                if try await ReadSync(store: store).pull(account: account, client: client, encryption: encryption), generation == token { refreshSoon(.chats) }
            } catch { Self.syncLog.notice("read state not fetched: \(ConnectionSetup.detail(error), privacy: .public)") }
            guard generation == token else { return }
            publishReadState()
            await DeliveredNotificationCleaner.removeCatchUpPlaceholders(accountID: account)
        }
    }

    /// Notification Center keeps only unread messages: requests for messages now at or below their chat's pointer go.
    private func removeReadNotifications(account: String, store: MessageStore) {
        guard !isDemo else { return }
        activeEncryptionOperations += 1
        Task {
            defer { activeEncryptionOperations -= 1 }
            try? await DeliveredNotificationCleaner.removeRead(accountID: account, store: store)
        }
    }

    func toggleStar(_ id: String) async {
        guard let message = messages.first(where: { $0.id == id }), let store else { return }
        do {
            try await store.setStarred(accountID: accountID, messageID: id, starred: !message.isStarred)
            await refresh(.openChat)
        } catch { self.error = "Could not update starred message." }
    }

    func togglePin(_ chat: ChatSummary) async {
        guard let store else { return }
        do {
            try await store.setPinned(accountID: accountID, chatID: chat.id, pinned: !chat.isPinned)
            await refresh(.chats)
        } catch { self.error = "Could not update pinned conversation." }
    }

    func notificationSetting(for chatID: String) -> ChatNotificationSetting {
        chats.first { $0.id == chatID }?.notification ?? ChatNotificationSetting()
    }

    /// Local only (plan D7): the store keeps it and the notification commit reads it; nothing reaches the server.
    private func setChatNotifications(_ chatID: String, _ setting: ChatNotificationSetting) async {
        guard let store else { return }
        do {
            try await store.setChatNotificationSetting(accountID: accountID, chatID: chatID, setting)
            await refresh(.chats)
        } catch { self.error = "Could not update notifications for this chat." }
    }

    /// Keeps the level, so unmuting a mentions-only group returns to mentions only.
    func muteChat(_ chatID: String, for duration: MuteDuration) async {
        var setting = notificationSetting(for: chatID)
        setting.mutedUntil = duration.until(from: .now)
        await setChatNotifications(chatID, setting)
    }

    func unmuteChat(_ chatID: String) async {
        var setting = notificationSetting(for: chatID)
        setting.mutedUntil = nil
        await setChatNotifications(chatID, setting)
    }

    /// Choosing a level is choosing to be notified again: it also ends a mute.
    func setNotificationLevel(_ chatID: String, _ level: ChatNotificationLevel) async {
        await setChatNotifications(chatID, ChatNotificationSetting(level: isGroup(chatID) ? level : .all))
    }

    @ObservationIgnored private lazy var reload = CoalescedReload { [weak self] scope in await self?.load(scope) }

    /// Returns after a load that started after this call; concurrent calls share one follow-up load.
    private func refresh(_ scope: CoalescedReload.Scope = .all) async { await reload.request(scope) }

    /// The event loop handles one event at a time, so awaiting there would serialise a burst into one load each.
    /// Counted as an operation so a background transition still joins it before releasing the lease.
    private func refreshSoon(_ scope: CoalescedReload.Scope = .all) {
        activeEncryptionOperations += 1
        Task { await refresh(scope); activeEncryptionOperations -= 1 }
    }

    /// One chat's newest messages with their projected events: what a timeline load publishes, and a cache entry.
    struct TimelinePage {
        var messages: [ChatMessage]
        var reactions: [String: [AuthenticatedReaction]] = [:]
        var receipts: [String: MessageEventKind] = [:]
        var reactableGroupMessages: Set<String> = []
    }

    /// The newest pages of recently opened and top-listed chats. A page is shown only while the chat list still
    /// describes the same newest message; the real load then replaces it in place.
    struct TimelinePageCache {
        /// What the chat list shows about a chat's newest message.
        struct Tail: Equatable {
            let lastMessageAt: Date?, preview: String, isOutgoing: Bool, state: OutgoingTransportState?, receipt: MessageEventKind?
            init(_ chat: ChatSummary) {
                lastMessageAt = chat.lastMessageAt; preview = chat.preview; isOutgoing = chat.lastMessageIsOutgoing
                state = chat.lastMessageState; receipt = chat.lastMessageReceipt
            }
        }
        static let prefetchCount = 8, capacity = 12
        private var account = ""
        private var entries: [String: (tail: Tail, page: TimelinePage)] = [:]
        /// Least recently stored or shown first.
        private var order: [String] = []

        mutating func page(for chat: ChatSummary?, account: String) -> TimelinePage? {
            guard let chat, account == self.account, let entry = entries[chat.id] else { return nil }
            guard entry.tail == Tail(chat) else { remove(chat.id); return nil }
            touch(chat.id)
            return entry.page
        }

        /// Keeps a page only when its newest message is the one the chat list shows, so a kept page never lags the list.
        mutating func store(_ page: TimelinePage, for chat: ChatSummary?, account: String) {
            switchAccount(account)
            guard let chat else { return }
            guard page.messages.last?.sentAt == chat.lastMessageAt, (page.messages.last?.isOutgoing ?? false) == chat.lastMessageIsOutgoing else { remove(chat.id); return }
            entries[chat.id] = (Tail(chat), page)
            touch(chat.id)
            while order.count > Self.capacity { entries[order.removeFirst()] = nil }
        }

        /// Drops pages the chat list has moved past; returns the top chats that still need one.
        mutating func missing(from chats: [ChatSummary], account: String, excluding open: String?) -> [ChatSummary] {
            switchAccount(account)
            for chat in chats where entries[chat.id].map({ $0.tail != Tail(chat) }) ?? false { remove(chat.id) }
            return chats.prefix(Self.prefetchCount).filter { $0.id != open && entries[$0.id] == nil }
        }

        mutating func removeAll() { account = ""; entries = [:]; order = [] }

        private mutating func switchAccount(_ account: String) {
            guard account != self.account else { return }
            removeAll()
            self.account = account
        }
        private mutating func remove(_ id: String) { entries[id] = nil; order.removeAll { $0 == id } }
        private mutating func touch(_ id: String) { order.removeAll { $0 == id }; order.append(id) }
    }

    /// Reads one chat's newest messages with their projected events; the caller checks its fences, then publishes.
    private func loadTimeline(store: MessageStore, account: String, chat: String, isGroup: Bool, limit: Int) async throws -> TimelinePage {
        let storedMessages = try await store.messages(accountID: account, chatID: chat, limit: limit)
        var reactions: [String: [AuthenticatedReaction]] = [:], receipts: [String: MessageEventKind] = [:]
        // One bounded query for the timeline: reactions, delivery and read receipts, retractions and corrections together.
        let events = try await store.eventsForChat(accountID: account, chatID: chat, messageIDs: Set(storedMessages.map(\.id)))
        for (id, events) in events {
            let projected = events.compactMap(AuthenticatedReaction.init)
            if !projected.isEmpty { reactions[id] = projected }
            if events.contains(where: { $0.kind == .displayed }) { receipts[id] = .displayed }
            else if events.contains(where: { $0.kind == .delivered }) { receipts[id] = .delivered }
        }
        var groupReactionTargets = Set<String>()
        if isGroup {
            for message in storedMessages where message.encryptionProfile == "modern" {
                if let reference = try await store.reactionReference(accountID: account, messageID: message.id),
                   try await store.reactionTarget(accountID: account, chatID: chat, wireID: reference)?.id == message.id {
                    groupReactionTargets.insert(message.id)
                }
            }
        }
        return TimelinePage(messages: storedMessages.map { $0.applying(events[$0.id] ?? []) }, reactions: reactions, receipts: receipts,
                            reactableGroupMessages: groupReactionTargets)
    }

    private func publishTimeline(_ page: TimelinePage, chat: String) {
        messages = page.messages
        messagesLoadedFor = chat
        messageReactions = page.reactions
        messageReceipts = page.receipts
        reactableGroupMessages = page.reactableGroupMessages
        // Unsent messages carry no attachment any more, so their files are not fetched.
        loadAttachments(page.messages, chat: chat)
    }

    /// After a chat-list load, the top chats' newest pages, one chat at a time so an open waits on at most one read.
    /// Counted as an operation so a background transition joins it; it stops at the next chat once quiescing.
    private func prefetchTimelinePages(store: MessageStore, account: String) {
        guard !prefetchingPages, foreground, !quiescing, accountID == account else { return }
        let wanted = timelinePages.missing(from: chats, account: account, excluding: openChatID)
        guard !wanted.isEmpty else { return }
        prefetchingPages = true
        activeEncryptionOperations += 1
        Task {
            defer { prefetchingPages = false; activeEncryptionOperations -= 1 }
            for chat in wanted {
                guard foreground, !quiescing, accountID == account, openChatID != chat.id else { continue }
                guard let page = try? await loadTimeline(store: store, account: account, chat: chat.id, isGroup: isGroup(chat.id), limit: AppModel.timelinePage),
                      accountID == account else { continue }
                timelinePages.store(page, for: chat, account: account)
                // The newest photos and videos too, so their bubbles are not placeholders in the first frame.
                for message in page.messages.suffix(12) {
                    guard let attachment = message.attachment, attachment.mediaType.hasPrefix("image/") || attachment.mediaType.hasPrefix("video/"),
                          let url = files?.cached(attachment, messageID: message.id) else { continue }
                    _ = await AttachmentThumbnails.image(for: url, mediaType: attachment.mediaType)
                }
            }
        }
    }

    private func load(_ scope: CoalescedReload.Scope) async {
        guard let store else { return }
        let account = accountID
        // Typing that a message ended goes in the same update that shows the message, so the bubble takes its place.
        // ponytail: a load already running when the message was stored flushes early (the indicator then goes a moment
        // before the message shows); track stored message IDs if that is ever visible.
        defer { typingTracker.flushSettled(); publishTyping() }
        do {
            if scope.contains(.chats) {
                try await loadChats(store: store, account: account)
                prefetchTimelinePages(store: store, account: account)
            }
            guard scope.contains(.openChat), accountID == account, let selected = openChatID else { return }
            // Every chat-list load, join and rejoin mirrors the known rooms into groupChats.
            let page = try await loadTimeline(store: store, account: account, chat: selected, isGroup: isGroup(selected), limit: timelineWindow)
            // A chat opened meanwhile requests its own load.
            guard accountID == account, openChatID == selected else { return }
            publishTimeline(page, chat: selected)
        } catch { self.error = "Could not read local conversations." }
    }

    /// The chat list does not depend on which chat is open, so only the account fences it.
    private func loadChats(store: MessageStore, account: String) async throws {
        let storedChats = try await store.chats(accountID: account)
        let pending = try await encryption?.pendingConversations(account: account) ?? [:]
        let rooms: [String: [String]]
        if let encryption, !isDemo, !account.isEmpty, try await store.encryptionState(accountID: account) != nil {
            rooms = try await encryption.knownGroupRooms(account: account)
        } else { rooms = [:] }
        let existingChatIDs = Set(storedChats.map(\.id))
        for peer in pending.keys where !existingChatIDs.contains(peer) {
            // A retained first-contact message needs a discoverable review entry and
            // a durable conversation for pinning or queuing a reply before approval.
            try await store.upsertChat(accountID: account, chatID: peer, title: peer)
        }
        guard accountID == account else { return }
        accountPreferences = try await store.accountPreferences(accountID: account)
        notificationPreviewsEnabled = accountPreferences.notificationPreviews
        if foreground, hasTransportOwnership, !quiescing {
            try await presentForegroundNotifications(store: store, account: account)
        }
        guard accountID == account else { return }
        for (room, members) in rooms {
            var value = groupChats[room] ?? GroupChatState()
            value.members = members
            groupChats[room] = value
        }
        let known = Set(storedChats.map(\.id))
        loadStoredAvatars(storedChats)
        let reviewPreview = "Encrypted message needs attention"
        var summaries = storedChats.map { ChatSummary(id: $0.id, title: $0.title,
            preview: pending[$0.id] != nil ? reviewPreview : ($0.lastMessage.map { last in
                last.isRetracted ? "Message unsent"
                    : last.unreadableReason.map(UnreadableCopy.preview) ?? (last.body.isEmpty ? (last.attachment?.kindLabel ?? "") : last.body) } ?? ""),
            isPinned: $0.isPinned, avatarHash: $0.avatarHash,
            lastMessageAt: $0.lastMessage?.sentAt, lastMessageIsOutgoing: $0.lastMessage?.isOutgoing ?? false,
            lastMessageState: $0.lastMessage?.transportState, lastMessageReceipt: $0.lastMessageReceipt, notification: $0.notification, unreadCount: $0.unreadCount) }
        summaries += pending.keys.filter { !known.contains($0) }.sorted().map {
            ChatSummary(id: $0, title: $0, preview: reviewPreview, isPinned: false)
        }
        // A pointer moved (here, on another device, or before this launch): its chat's notifications may go.
        let previousUnread = Dictionary(chats.map { ($0.id, $0.unreadCount) }, uniquingKeysWith: max)
        if !hasLoadedChats || summaries.contains(where: { $0.unreadCount < (previousUnread[$0.id] ?? 0) }) {
            removeReadNotifications(account: account, store: store)
        }
        // A reorder (pin, new activity) animates; List only does so inside an explicit transaction.
        withAnimation(summaries.map(\.id) == chats.map(\.id) ? nil : .default) { chats = summaries }
        hasLoadedChats = true
        updateAppBadge(summaries)
    }

    /// The icon badge: unread messages outside muted chats (`NotificationBadge`, the extension's rule too). Every
    /// change of unread totals or mute reloads the chat list, so this follows reads here, reads on other devices
    /// (markers and XEP-0490) and mute changes.
    private func updateAppBadge(_ summaries: [ChatSummary]) {
        guard !accountID.isEmpty else { return }
        setAppBadge(NotificationBadge.count(unread: Dictionary(summaries.map { ($0.id, $0.unreadCount) }, uniquingKeysWith: max),
                                            settings: Dictionary(summaries.map { ($0.id, $0.notification) }, uniquingKeysWith: { first, _ in first })))
    }

    private func setAppBadge(_ count: Int) {
        guard appBadge != count else { return }
        appBadge = count
        Task { try? await UNUserNotificationCenter.current().setBadgeCount(count) }
    }
}

// MARK: Notification actions and foreground banners (wave 2, stream E; docs/development/notification-actions.md)

/// The transport one Reply or Mark as Read took. In front of the app it is the app's own live session; in the
/// background it is the store's lease plus a short-lived connection of its own, which the watchdog ends at the
/// budget's deadline.
@MainActor private final class NotificationActionSession {
    let account: String
    let isForeground: Bool
    let budget: NotificationActionBudget
    var client: XMPPClient?
    var consumer: Task<Void, Never>?
    var watchdog: Task<Void, Never>?
    /// Ends the lifecycle slot this action holds, so a scene transition queued behind it can run.
    var releaseLifecycle: AsyncStream<Void>.Continuation?
    /// True from the moment the kernel lease was taken until it was released; `acquiringLease` covers the call in
    /// flight, whose lock may already be held before the main actor hears of it.
    var holdsLease = false
    var acquiringLease = false
    /// The deadline passed or the system is ending the background time: nothing new starts on the network.
    private(set) var aborted = false
    /// Bound and past `initialize`, as the app's `.ready`: only then is anything sealed or sent.
    var ready = false
    var joinedRooms: Set<String> = []
    /// After a fresh bind: the push re-enable and room rejoins, running alongside the reply; teardown waits for it.
    var restoration: Task<Void, Never>?

    init(account: String, isForeground: Bool, budget: NotificationActionBudget) {
        self.account = account; self.isForeground = isForeground; self.budget = budget
    }

    /// Past the deadline, or aborted: stop before the next network step.
    var isOver: Bool { aborted || ContinuousClock.now >= budget.deadline }

    /// The budget ran out or the system is ending the background task: close the connection so every call returns.
    func abort() {
        aborted = true
        guard let client else { return }
        Task { await client.disconnect() }
    }
}

@MainActor private final class ActionWaitCompletion { var finished = false }

extension AppModel: NotificationActionEnvironment {
    /// After the reply was written: how long to wait for the server's stream-management acknowledgement.
    private static let acknowledgementWait: Duration = .seconds(3)
    /// In front of the app, how long a reply waits for the live session's outbox pass.
    private static let foregroundReplyWait: Duration = .seconds(10)

    /// A notification's Reply or Mark as Read, possibly on a launch into the background. `NotificationActionCenter`
    /// holds the background task and measured `budget` from the delegate callback, so `prepare()` counts against it.
    func performNotificationAction(_ request: NotificationActionRequest, budget: NotificationActionBudget) async -> NotificationActionOutcome {
        await prepare()
        let outcome: NotificationActionOutcome
        if case let .reply(text) = request.kind, await saveReplyForUpgrade(text, to: request.destination) { outcome = .replySavedForUpgrade }
        else { outcome = await NotificationActionHandler.perform(request, budget: budget, in: self) }
        Self.syncLog.notice("notification action: \(outcome.rawValue, privacy: .public)")
        return outcome
    }

    /// A reply on a launch into the background while the previous version's data still waits for its snapshot and
    /// upgrade (which only run in front): nothing may touch that data yet, so the text is kept and queued by
    /// `queueSavedReplies` once the upgrade finished. False when there is no upgrade waiting or it could not be kept.
    private func saveReplyForUpgrade(_ text: String, to destination: NotificationDestination) async -> Bool {
        guard store == nil, let snapshots else { return false }
        switch upgradeState {
        case .deferred, .waitingForLease, .preparing, .snapshotFailed: break
        default: return false
        }
        do { try snapshots.saveReply(.init(destination: destination.payload, text: text, savedAt: Date())) }
        catch { return false }
        await NotificationActionCenter.postSavedReply()
        return true
    }

    /// After the upgrade, with the account loaded: every reply kept by `saveReplyForUpgrade` goes into the outbox as
    /// the notification action would have queued it (and is sent once the session is ready, trust rules unchanged),
    /// under the ID it was saved with, so a launch killed before the file was removed does not queue it twice. One
    /// older than a day is dropped with a notice; one that no longer resolves to this account's message is reported
    /// like a rejected reply.
    private func queueSavedReplies() async {
        guard let snapshots, let store, !snapshots.savedReplies.isEmpty else { return }
        guard let account = authorizedNotificationAccount() else { return }
        let result = await snapshots.queueSavedReplies(account: account, store: store, now: Date()) { try await self.enqueueReply($0) }
        Self.syncLog.notice("replies saved before the upgrade: \(result.queued, privacy: .public) queued, \(result.rejected, privacy: .public) rejected, \(result.expired, privacy: .public) too old")
        if result.expired > 0 { await NotificationActionCenter.postExpiredSavedReply() }
        else if result.rejected > 0 { await NotificationActionCenter.postRejectedReply() }
        startOutbox()
    }

    /// The system is ending the background time. Closes the action's connection; true while the action holds or is
    /// taking the lease, so the center leaves the task to expire (termination frees the lock, suspension would not).
    func abortNotificationAction() -> Bool {
        guard let session = actionSession else { return false }
        session.abort()
        return session.holdsLease || session.acquiringLease
    }

    func authorizedNotificationAccount() -> String? {
        guard testSessionID == nil, !isDemo, !accountID.isEmpty, sessionAccount?.accountID == accountID,
              !ProcessInfo.processInfo.arguments.contains("--inspect-notification"),
              let saved = try? NotificationAccount.load(), saved.accountID == accountID else { return nil }
        return accountID
    }

    func resolveNotificationMessage(_ destination: NotificationDestination, account: String) async -> StoredMessage? {
        guard let store else { return nil }
        return try? await destination.resolve(accountID: account, store: store)
    }

    func beginNotificationAction(account: String, chatID: String, budget: NotificationActionBudget) async -> Bool {
        guard let store, let encryption, let credentials = sessionAccount, credentials.accountID == account else { return false }
        // In front (or still holding the live session while the scene goes): the app's own connection does the work.
        if UIApplication.shared.applicationState != .background || (foreground && !quiescing && hasTransportOwnership) {
            actionSession = NotificationActionSession(account: account, isForeground: true, budget: budget)
            return true
        }
        let session = NotificationActionSession(account: account, isForeground: false, budget: budget)
        actionSession = session
        // Measured from the delegate callback: a slow start or a queued action ahead of this one used part of it.
        session.watchdog = Task { [weak session] in
            try? await Task.sleep(until: budget.deadline, clock: .continuous)
            session?.abort()
        }
        // Take the lifecycle slot: a quiesce in flight finishes first, and a return to the foreground waits for this.
        // The wait for it and for the lease share one bound; past it the action works locally only.
        let waitEnd = budget.leaseDeadline(from: .now)
        let previous = lifecycleTask
        let (gate, release) = AsyncStream<Void>.makeStream()
        session.releaseLifecycle = release
        lifecycleTask = Task { await previous?.value; for await _ in gate {} }
        guard await Self.finishes(previous, by: waitEnd), !session.isOver else { return true }
        // Without the lease (the extension is syncing) the action still reads and queues locally; nothing is sent.
        guard (try? await acquireActionLease(store, session: session, until: waitEnd)) != nil else { return true }
        guard !session.isOver else { return true }
        do {
            try await store.recoverInterruptedSubmissions(accountID: account)
            let client = XMPPClient(labCertificateAuthority: DevelopmentEndpoint.certificateAuthority)
            try await client.configureStreamManagement(persistence: StreamPersistence(store: store, accountID: account, encryption: encryption))
            try await client.configureResource(SharedSession.resource(accountID: account, defaults: sessionDefaults))
            // The user is not in front: the action's session must not make them look online.
            try await client.setAvailability(awayAvailability)
            session.client = client
            // From here an abort closes this client; one that came before it was set is honoured here.
            guard !session.isOver else { throw CancellationError() }
            // Everything that arrives meanwhile is persisted exactly as the extension would, and acknowledged.
            let processor = InboundProcessor(encryption: encryption, client: client, account: account)
            session.consumer = Task {
                for await event in client.events {
                    if case .state(.disconnected) = event { break }
                    _ = try? await processor.process(event)
                }
            }
            try await client.connect(route: credentials.route, domain: credentials.domain, username: credentials.username,
                                     password: credentials.password, requireSCRAM: credentials.requiresSCRAM)
            let resumed = await client.sessionResumed
            Self.syncLog.notice("notification action online resumed=\(resumed, privacy: .public)")
            guard !session.isOver else { throw CancellationError() }
            // As before `.ready`: an identity mismatch fails closed before anything can be sealed.
            try await encryption.initialize(account: account, transport: client)
            if isGroup(chatID) {
                let nickname = preferences.string(forKey: "groupNickname.\(account).\(chatID)") ?? String(account.prefix { $0 != "@" })
                // The reply's room must confirm the join first: the drain sends only to joined rooms.
                if await BackgroundSession.join(chatID, nickname: nickname, client: client,
                                                within: session.budget.remaining(at: .now, atMost: .seconds(3))) {
                    session.joinedRooms.insert(chatID)
                }
            }
            guard !session.isOver else { throw CancellationError() }
            session.ready = true
            // A fresh bind replaced the session the app left hibernating, with its push registration and room
            // occupancy: restore both, as the extension does, or pushes for this account stop. Alongside the reply,
            // which does not wait for them; `endNotificationAction` does, within the budget.
            if !resumed {
                let push = pushWanted ? PushRegistrationState.sessionSubscription(saved: credentials.push,
                                                                                   state: try? PushRegistrationState.load(accountID: account)) : nil
                let limit = session.budget.remaining(at: .now, atMost: .seconds(5))
                session.restoration = Task {
                    async let enabled: Void = BackgroundSession.enablePush(push, client: client)
                    await BackgroundSession.joinRooms(account: account, client: client, encryption: encryption, store: store,
                                                      skipping: [chatID], within: limit)
                    await enabled
                }
            }
        } catch {
            Self.syncLog.notice("notification action offline: \(ConnectionSetup.detail(error), privacy: .public)")
        }
        return true
    }

    /// Polls the lease until `end`. `holdsLease` is set in the same main-actor turn the acquisition returns in, and
    /// `acquiringLease` covers the call in flight, so the expiration handler never ends the task over a held lock.
    private func acquireActionLease(_ store: MessageStore, session: NotificationActionSession, until end: ContinuousClock.Instant) async throws {
        while true {
            guard !session.isOver else { throw CancellationError() }
            session.acquiringLease = true
            do {
                try await store.acquireTransportOwnership()
                session.holdsLease = true
                session.acquiringLease = false
                return
            } catch MessageStoreError.transportOwnedElsewhere {
                session.acquiringLease = false
                guard ContinuousClock.now + .milliseconds(250) <= end else { throw MessageStoreError.transportOwnedElsewhere }
                try await Task.sleep(for: .milliseconds(250))
            } catch {
                session.acquiringLease = false
                throw error
            }
        }
    }

    /// Waits for `task` until `deadline`; false when it had not finished by then (the task itself keeps running).
    private static func finishes(_ task: Task<Void, Never>?, by deadline: ContinuousClock.Instant) async -> Bool {
        guard let task else { return true }
        // Awaiting a task's value ignores cancellation, so the race is polled rather than put in a task group.
        let completion = ActionWaitCompletion()
        Task { @MainActor in await task.value; completion.finished = true }
        while !completion.finished, ContinuousClock.now < deadline { try? await Task.sleep(for: .milliseconds(50)) }
        return completion.finished
    }

    func markNotificationMessageRead(_ message: StoredMessage) async throws {
        guard let store else { throw MessageStoreError.closed }
        let account = message.accountID
        if try await store.markRead(accountID: account, chatID: message.chatID, throughMessageID: message.id) { await refresh(.chats) }
        // The peer's read marker, only when the read-receipts switch allows it (the store checks); it leaves with the
        // outbox's updates. The pointer and XEP-0490 do not depend on the switch.
        _ = try? await encryption?.queueReceipt(account: account, chatID: message.chatID, messageID: message.id, kind: .marker)
        if actionSession?.isForeground == true { publishReadState(); startOutbox() }
    }

    func clearReadNotifications(for message: StoredMessage) async {
        await DeliveredNotificationCleaner.removeMessages(accountID: message.accountID, messageIDs: [message.id])
        if let store { try? await DeliveredNotificationCleaner.removeRead(accountID: message.accountID, store: store) }
    }

    /// The composer's outbox: one queued, still unencrypted row that only the drain seals. A plain answer in the chat,
    /// as in Messages; not an XEP-0461 reply.
    func enqueueNotificationReply(_ text: String, to message: StoredMessage) async throws -> String {
        let reply = NotificationActionHandler.replyMessage(text, id: UUID().uuidString, to: message)
        try await enqueueReply(reply)
        return reply.id
    }

    private func enqueueReply(_ reply: StoredMessage) async throws {
        guard let store else { throw MessageStoreError.closed }
        let chatID = reply.chatID
        guard isGroup(chatID) || !isLabAccount || chatID.hasSuffix("@" + accountDomain) else { throw MessageStoreError.invalidValue }
        try XMPPClient.validateMessage(to: chatID, body: reply.body, id: reply.id, reply: nil)
        try await store.enqueueOutgoing(reply)
        await refresh()
        if actionSession?.isForeground == true { startOutbox() }
    }

    func deliverNotificationReply(_ messageID: String, account: String) async -> ReplyDelivery {
        guard let store, let session = actionSession else { return .held }
        if session.isForeground {
            // The live session's pass: wait until the reply left the queue, or a pass that started after it was queued
            // finished and left it there (held for a decision), or the session never got ready.
            let before = drainPasses
            startOutbox()
            let clock = ContinuousClock(), deadline = clock.now + session.budget.remaining(at: clock.now, atMost: Self.foregroundReplyWait)
            while clock.now < deadline {
                if let state = try? await store.message(accountID: account, messageID: messageID)?.transportState, state != .queued { break }
                if drainPasses > before, drainTask == nil, !outboxRequested { break }
                try? await Task.sleep(for: .milliseconds(200))
            }
        } else {
            await flushBackgroundAction(session)
        }
        return await replyDelivery(messageID, account: account, budget: session.budget)
    }

    /// Server acceptance when it comes in time; a written but unacknowledged reply still counts as sent (the archive
    /// reconciles it). Queued (held) and failed are not sent.
    private func replyDelivery(_ messageID: String, account: String, budget: NotificationActionBudget) async -> ReplyDelivery {
        guard let store else { return .held }
        let clock = ContinuousClock(), deadline = clock.now + budget.remaining(at: clock.now, atMost: Self.acknowledgementWait)
        while true {
            switch try? await store.message(accountID: account, messageID: messageID)?.transportState {
            case .serverAccepted?: return .sent
            case .submitting?, .unconfirmed?: if clock.now >= deadline { return .sent }
            default: return .held
            }
            try? await Task.sleep(for: .milliseconds(200))
        }
    }

    func flushNotificationAction(account: String) async {
        guard let session = actionSession, !session.isForeground else { return }
        await flushBackgroundAction(session)
    }

    /// Read state first, then one outbox pass: the reply, the marker and anything else the user queued earlier.
    private func flushBackgroundAction(_ session: NotificationActionSession) async {
        guard session.ready, !session.isOver, let client = session.client, let store, let encryption, let outboxSender else { return }
        _ = try? await ReadSync(store: store).push(account: session.account, client: client)
        let drain = OutboxDrain(account: session.account, client: client, encryption: encryption, store: store,
                                sender: outboxSender, joinedGroups: session.joinedRooms)
        do { _ = try await drain.run() }
        catch { Self.syncLog.notice("notification action outbox: \(ConnectionSetup.detail(error), privacy: .public)") }
    }

    func reportNotificationReply(failed: Bool, for message: StoredMessage) async {
        let account = message.accountID
        let identifier = NotificationIdentity.replyFailure(accountID: account, chatID: message.chatID)
        let center = UNUserNotificationCenter.current()
        guard failed else { center.removeDeliveredNotifications(withIdentifiers: [identifier]); return }
        guard let destination = NotificationDestination(accountID: account, messageID: message.id) else { return }
        let content = UNMutableNotificationContent()
        // The chat's name only when previews are on, as for the message notification itself.
        content.title = notificationPreviewsEnabled ? chats.first { $0.id == message.chatID }?.displayTitle ?? "" : ""
        content.body = NotificationActionCopy.replyFailed
        content.threadIdentifier = NotificationIdentity.thread(accountID: account, chatID: message.chatID)
        content.categoryIdentifier = NotificationIdentity.noticeCategory
        content.userInfo = [NotificationNavigation.replyFailureKey: destination.payload]
        content.sound = .default
        try? await center.add(UNNotificationRequest(identifier: identifier, content: content, trigger: nil))
    }

    func endNotificationAction() async {
        // `actionSession` stays set until the lease is back, so an expiring background task sees that it is held.
        guard let session = actionSession else { return }
        session.watchdog?.cancel()
        await session.restoration?.value
        if let client = session.client { await client.disconnectAndWait() }
        session.consumer?.cancel()
        await session.consumer?.value
        // Still in the background: the lease goes back, so the extension can run. A foreground session that took it
        // meanwhile keeps it.
        if session.holdsLease, !hasTransportOwnership, let store {
            if session.client != nil { await presentActionArrivals(store: store, session: session) }
            try? await store.releaseTransportOwnership()
        }
        session.holdsLease = false
        actionSession = nil
        session.releaseLifecycle?.finish()
        await refresh()
    }

    /// While the action's connection was online (with initial presence) the server pushed nothing for what it
    /// delivered there, so those messages alert now, under the lease, exactly as the extension would present them:
    /// its planner, identifiers, mute, read state and previews, and the claim that keeps a later run from repeating
    /// them. Bounded; what does not get posted in time stays a candidate for the next run or the foreground claim.
    private func presentActionArrivals(store: MessageStore, session: NotificationActionSession) async {
        guard authorizedNotificationAccount() == session.account else { return }
        let presenter = NotificationPresenter(posting: notificationPoster(account: session.account),
                                              addTimeout: .seconds(2), cleanupTimeout: .seconds(1))
        let account = session.account, progress = NotificationRunProgress()
        let timeout = session.budget.presentationTimeout(at: .now)
        guard timeout > .zero else { return }
        let presentation = Task { try await presenter.present(store: store, accountID: account, progress: progress) }
        let watchdog = Task { try? await Task.sleep(for: timeout); presentation.cancel() }
        _ = await presentation.result
        watchdog.cancel()
        if progress.report.posted > 0 { Self.syncLog.notice("notification action presented=\(progress.report.posted, privacy: .public)") }
    }

    // MARK: Foreground banners

    /// Claims what this connection committed; banners for other chats when permitted and caught up.
    fileprivate func presentForegroundNotifications(store: MessageStore, account: String) async throws {
        let presents = mayPostNotifications && testSessionID == nil && !isDemo && session.isReady && catchUp == nil
            && sessionAccount?.accountID == account
        let posted = try await NotificationPresenter(posting: notificationPoster(account: account))
            .presentForeground(store: store, accountID: account, openChatID: openChatID, presents: presents)
        if posted > 0 { Self.syncLog.notice("foreground notifications posted=\(posted, privacy: .public)") }
    }

    /// The extension's poster, with the app's pre-scaled notification avatars, so banners match the extension's requests.
    private func notificationPoster(account: String) -> UserNotificationPoster {
        let root = storageRoot
        return UserNotificationPoster(avatarData: { hash in
            guard let root else { return nil }
            return AvatarStore.notificationImageData(root: root, account: account, hash: hash)
        })
    }

    fileprivate func refreshNotificationPermission() {
        guard testSessionID == nil else { return }
        Task { [weak self] in
            #if DEBUG
            // Simulator lab runs only: the lab account has no staging push, which is what normally asks.
            if ProcessInfo.processInfo.arguments.contains("-request-notification-permission") {
                _ = try? await UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound, .badge])
            }
            #endif
            let status = await Self.notificationAuthorization()
            guard let self else { return }
            self.mayPostNotifications = [.authorized, .provisional, .ephemeral].contains(status)
            // Turned off in iOS Settings while away; turning it back on is picked up by the next connection.
            if status == .denied, [.on, .settingUp].contains(self.pushStatus) { self.pushStatus = .notAllowed }
        }
    }

    private nonisolated static func notificationAuthorization() async -> UNAuthorizationStatus {
        await UNUserNotificationCenter.current().notificationSettings().authorizationStatus
    }
}

/// Where a launch stands with the previous version's data. Every state but `none` shows a blocking screen.
enum UpgradeState: Equatable {
    case none
    /// Taking the snapshot and migrating (shown only if it takes a moment).
    case preparing
    /// Another process holds the transport lease; retried shortly.
    case waitingForLease
    /// Launched into the background with an upgrade due: left for the foreground.
    case deferred
    /// The snapshot could not be taken, so nothing was migrated.
    case snapshotFailed(String)
    case restoring
    case restored(PreUpgradeSnapshot.RestoredState)
    /// Putting this version's kept data back after a restore.
    case returning
}
