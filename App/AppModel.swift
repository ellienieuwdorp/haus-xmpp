import Foundation
import Network
import os
import SwiftUI
#if os(iOS)
import UIKit
#endif
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
    var notification = ChatNotificationSetting()
    var unreadCount = 0
    var contactName: String? = nil
    var displayTitle: String { AppModel.displayName(for: id, title: contactName ?? title) }
}

@MainActor @Observable
final class AppModel {
    private(set) var chats: [ChatSummary] = []
    // A cold start must not flash the empty state before the stored rows arrive.
    private(set) var hasLoadedChats = false
    // Retained ciphertext per chat at the last load, so a resolved review can clear its notification.
    @ObservationIgnored private var reviewCounts: [String: Int] = [:]
    private(set) var messages: [ChatMessage] = []
    private(set) var messagesLoadedFor: String?
    @ObservationIgnored private var timelineWindow = AppModel.timelinePage
    @ObservationIgnored private var loadingOlder = false
    private static let timelinePage = 100, timelineCeiling = 1000
    private static let backfillPagesPerScroll = 5, opportunisticBackfillPages = 3
    // Newest pages of recently seen chats, so pushing one shows its tail in the first frame.
    @ObservationIgnored private var timelinePages = TimelinePageCache()
    @ObservationIgnored private var prefetchingPages = false
    private(set) var messageReactions: [String: [AuthenticatedReaction]] = [:]
    private(set) var messageReceipts: [String: MessageEventKind] = [:]
    private(set) var accountPreferences = AccountPreferences()
    private(set) var groupChats: [String: GroupChatState] = [:]
    // XEP-0085; in memory only, entries expire on their own.
    private(set) var typing: [String: [String]] = [:] { didSet { syncOpenChatTyping() } }
    // Observed separately so typing in another chat never re-renders the conversation.
    private(set) var openChatTyping: [String]?
    private(set) var openChatLastSeen: LastSeen?
    // Presence and the roster stay in memory; never stored.
    @ObservationIgnored private var lastSeenTracker = LastSeenTracker()
    @ObservationIgnored private var typingTracker = TypingTracker()
    @ObservationIgnored private var typingExpiry: Task<Void, Never>?
    @ObservationIgnored private var ownTyping: (chat: String, sender: TypingSender)?
    @ObservationIgnored private var ownTypingPause: Task<Void, Never>?
    @ObservationIgnored private var ownTypingSend: Task<Void, Never>?
    private(set) var reactableGroupMessages: Set<String> = []
    private(set) var avatars: [String: PlatformImage] = [:]
    @ObservationIgnored private var avatarChecked: Set<String> = []
    @ObservationIgnored private var storageRoot: URL?
    // Anything but `.none` replaces the app with a blocking screen and keeps storage closed.
    private(set) var upgradeState: UpgradeState = .none
    private(set) var previousVersionBackup: PreUpgradeSnapshot.Manifest?
    private(set) var previousVersionBackupUnreadable = false
    private(set) var keptCopyUnreadable = false
    // A restore owns the store's lease until it closes the store; a background transition must not release it.
    @ObservationIgnored private var restoringData = false
    @ObservationIgnored private var snapshots: PreUpgradeSnapshot?
    // Its snapshot or migration can hold the lease before `store` is set, so a background transition joins it.
    @ObservationIgnored private var storageOpening: Task<Void, Never>?
    // Anything but `.none` replaces the app with the transfer screen and keeps storage closed.
    private(set) var transferState: TransferState = .none
    @ObservationIgnored private var transfers: AccountTransfer?
    private(set) var restoreProgress: AccountTransfer.Progress?
    var transferRestored = false
    // The Keychain wrapping key cannot open the stored encryption state: storage stays closed for everything else until
    // the user sets encryption up again.
    private(set) var keyRecovery: KeyRecoveryPlan?
    // Opened for the recovery screen alone; nothing else reads or writes it.
    @ObservationIgnored private var recoveryStore: MessageStore?
    @ObservationIgnored private var startingEncryptionOver = false
    private(set) var accountID = "" {
        didSet {
            if accountID != oldValue {
                timelinePages.removeAll()
                pushWanted = accountID.isEmpty || !preferences.bool(forKey: "pushOff." + accountID)
                pushStatus = .off
                loadBlocklist()
                // At once: the previous account's fetches stop and record nothing.
                useLinkPreviewAccount()
            }
            ForegroundNotificationState.shared.accountID = isDemo ? "" : accountID
        }
    }
    // Chat trust derives from stored devices, never from this.
    private(set) var session: SessionState = .offline(reason: nil)
    var isConnected: Bool { session.isConnected }
    var encryptionReady: Bool { session.isReady }
    var isSettlingConnection: Bool { wantsConnection && !session.isReady && !connectionNeedsAttention }
    var connectionNeedsAttention: Bool { if case .needsAttention = session { true } else { false } }
    var signInRequested = false
    var conversationIntent: ConversationIntent?
    private(set) var isSending = false
    private(set) var receivedCount = 0
    var error: String?
    private(set) var pushStatus = PushStatus.off
    private(set) var pushWanted = true
    // Bumped by every Settings toggle, so a setup still in flight cannot enable what was just turned off.
    @ObservationIgnored private var pushIntent = 0
    // Each setup waits for the previous, so two never generate or register at once; resetSession cancels it and
    // forgetAccount joins it.
    @ObservationIgnored private var pushTask: Task<Void, Never>?
    private(set) var notificationRoute: NotificationChatRoute?
    @ObservationIgnored var onNotificationRoute: (@MainActor () -> Void)?
    var requestedRoute: ChatRoute?
    @ObservationIgnored private var sessionAccount: NotificationAccount?
    @ObservationIgnored private var lifecycleTask: Task<Void, Never>?
    // Only `applyLifecycle` changes these, from the updates of the process-owned platform lifecycle driver.
    @ObservationIgnored private(set) var lifecycle = LifecycleSignals.inFront
    // Set by the lifecycle owner before `prepare()`; on iOS a launch into the background starts with `.start(.away)`.
    @ObservationIgnored var lifecycleAtLaunch: @MainActor () -> [LifecycleUpdate] = { [] }
    private static let attention: AttentionRules = {
        #if os(macOS)
        .desktop
        #else
        .phone
        #endif
    }()
    // Mac only: the conversation then marks its newest visible message; on iOS cells do that as they appear.
    private(set) var readingStarts = 0
    // With `quiescing`, this guards all transport, crypto and setup work, so a background transition blocks new work at
    // once.
    private var transportWanted: Bool { lifecycle.transportWanted }
    @ObservationIgnored private var quiescing = false
    @ObservationIgnored private var appBadge: Int?
    @ObservationIgnored private var activeEncryptionOperations = 0
    @ObservationIgnored private var acquiringOwnership = false
    @ObservationIgnored private var hasTransportOwnership = false
    @ObservationIgnored private var livenessResponder: AppLiveness.Responder?
    @ObservationIgnored private var outboxRingListener: OutboxRing.Listener?
    // Begun when a background release left the kernel lock held, so the app is not suspended holding it; the next
    // release that frees the lock ends it.
    @ObservationIgnored private var unreleasedLease: BackgroundActivity?
    @ObservationIgnored private var reconnectTask: Task<Void, Never>?
    @ObservationIgnored private var reconnection = ReconnectPolicy()
    @ObservationIgnored private var userWantsOffline = false
    @ObservationIgnored private var authenticationRejected = false
    @ObservationIgnored private let pathMonitor = NWPathMonitor()
    // Set as a chat opens, before its store read returns, and kept across pop-back and reconnect; only another chat or
    // account replaces it.
    private(set) var encryptionOverviewChatID: String?
    private(set) var encryptionOverview: EncryptionOverview?
    private(set) var encryptionAttention = EncryptionAttention()
    var encryptionDiagnostics: String { encryptionAttention.diagnostics }
    // Opening a chat or popping back reuses the refresh; a reconnect (new generation) fetches again.
    @ObservationIgnored private var refreshFence: [String: (generation: UUID, note: String)] = [:]
    // Read-only: problems go to `encryptionAttention`, so a transient problem never rewrites the pill or re-shows a
    // dismissed review card.
    var encryptionStatus: String { encryptionOverviewChatID.map { trustSummary(for: $0).subtitle } ?? "" }
    var encryptionNeedsReview: Bool { encryptionOverviewChatID.map { chatCapabilities($0).encryption == .needsReview } ?? false }
    // A 1:1 chat's sending then waits only on the account's own devices, so the card must not name the contact.
    var encryptionReviewIsOwnDevice: Bool {
        guard let chat = encryptionOverviewChatID, !isGroup(chat), let overview = encryptionOverview(for: chat) else { return false }
        let undecided = overview.devices.filter { $0.profile == overview.profile && $0.active && $0.trust == .undecided }
        return !undecided.isEmpty && undecided.allSatisfy { $0.jid == accountID }
    }
    // Sending is unaffected, so this asks for a review but never pauses the composer.
    var encryptionIncomingReview: Bool {
        guard let chat = encryptionOverviewChatID, !isGroup(chat) else { return false }
        return encryptionOverview(for: chat)?.needsIncomingReview ?? false
    }
    private(set) var ownDevices: [EncryptionDevice] = []
    var ownDeviceReview: [OwnDeviceCandidate] { OwnDeviceReview.candidates(ownDevices) }
    @ObservationIgnored private lazy var ownDevicePasses = RerunningPass { [weak self] in self?.ownDevicePass() }
    @ObservationIgnored private var encryption: OMEMOService?
    var isDemo: Bool { accountID == "preview.local" }

    @ObservationIgnored private var store: MessageStore?
    @ObservationIgnored private var outboxSender: OutboxSender?
    @ObservationIgnored private var outboxRequested = false
    @ObservationIgnored private var drainTask: Task<Void, Never>?
    // Off the event loop; joined like `drainTask`.
    @ObservationIgnored private var setupTask: Task<Void, Never>?
    private(set) var catchUp: CatchUpProgress? {
        didSet {
            if catchUp == nil { catchUpActivity?.end(); catchUpActivity = nil }
            else if catchUpActivity == nil { catchUpActivity = BackgroundActivity.burst("Catch up with the archive") }
        }
    }
    @ObservationIgnored private var catchUpActivity: BackgroundActivity?
    var isCatchingUp: Bool { catchUp != nil }
    // Numbers only, never message contents.
    private static let syncLog = Logger(subsystem: "haus.xmpp.ios", category: "sync")
    private static let lifecycleLog = Logger(subsystem: "haus.xmpp.ios", category: "lifecycle")
    @ObservationIgnored private var onlineAt: ContinuousClock.Instant?
    @ObservationIgnored private var firstMessageLogged = false
    @ObservationIgnored private var liveStoredLogged = false
    @ObservationIgnored private var catchUpByArchive: [String: CatchUpProgress] = [:]
    @ObservationIgnored private var connectPhases = SyncPhaseTimings.ConnectPhases()
    @ObservationIgnored private var syncTimings = SyncPhaseTimings()
    @ObservationIgnored private var backfillTask: Task<Void, Never>?
    private(set) var backfillingArchive: String?
    @ObservationIgnored private var opportunisticBackfillDone = false
    // The forward walk finished, so the single archive query is free.
    @ObservationIgnored private var archiveWalkFinished = false
    // A join boundary query holds the archive query: no backfill starts meanwhile.
    @ObservationIgnored private var joinBoundaryQueries = 0
    // Recorded as the room's read baseline once its presence admits us on that connection; a refusal drops it and
    // another connection ignores it.
    @ObservationIgnored private var joinBoundaries: [String: (token: UUID, historyThrough: Date)] = [:]
    // Reach-top fires every scroll frame near the top; settled archives (exhausted or refused) are not asked again.
    @ObservationIgnored private var backfillSettled: Set<String> = []
    @ObservationIgnored private var backfillResumesAt: ContinuousClock.Instant?
    @ObservationIgnored private var client: XMPPClient?
    @ObservationIgnored private var eventTask: Task<Void, Never>?
    @ObservationIgnored private var openChatID: String? {
        didSet { syncOpenChatTyping(); syncOpenChatLastSeen(); syncForegroundNotificationChat() }
    }
    @ObservationIgnored private var encryptionDetailsChatID: String?
    private var encryptionShownChatID: String? { openChatID ?? encryptionOverviewChatID }
    @ObservationIgnored private var generation = UUID()
    @ObservationIgnored private var bounceRejoins: [String: UUID] = [:]
    @ObservationIgnored private var deferredBounceRejoins: [String: UUID] = [:]
    @ObservationIgnored private var groupRejoinsFinished: UUID?
    // Runs once; a notification action on a background launch joins it.
    @ObservationIgnored private var preparation: Task<Void, Never>?
    @ObservationIgnored private var mayPostNotifications = false
    #if os(macOS)
    private(set) var notificationAuthorization = UNAuthorizationStatus.notDetermined
    private(set) var notificationAlertStyle = UNAlertStyle.none
    // Every caller that comes while the prompt is on screen waits for it.
    @ObservationIgnored private var permissionRequest: Task<Void, Never>?
    #endif
    @ObservationIgnored private var catchUpBanners = CatchUpBanners.holding
    @ObservationIgnored private var actionSession: NotificationActionSession?
    // Lets an action tell that a pass ran after its reply was queued.
    @ObservationIgnored private var drainPasses = 0
    @ObservationIgnored private var pushTokenTask: Task<Void, Never>?
    @ObservationIgnored private var notificationTapTask: Task<Void, Never>?
    // Owns the durable-disposition rule for the current stream; replaced with the client.
    @ObservationIgnored private var inbound: InboundProcessor?
    // One XEP-0490 publication at a time; a read made meanwhile asks for one more.
    @ObservationIgnored private var publishingReadState = false
    @ObservationIgnored private var readStateChangedWhilePublishing = false
    private(set) var attachmentFiles: [String: URL] = [:]
    var attachmentDownloads: [String: AttachmentDownloadState] { downloads.states }
    // Persisted per account so the attach button survives launch and reconnect.
    private var uploadService: XMPPUploadService?
    private var uploads: UploadServiceMemory {
        UploadServiceMemory(defaults: preferences, mirror: testSessionID == nil ? SharedSession.groupDefaults : nil)
    }
    @ObservationIgnored private var uploadReconciliation = UploadReconciliation()
    private var serverProfiles: ServerProfileMemory { ServerProfileMemory(defaults: preferences) }
    private var files: AttachmentFiles? { storageDirectory.map { AttachmentFiles(directory: $0, account: accountID) } }
    let linkPreviewCenter = LinkPreviewCenter()
    let contactLinks = ContactLinkCenter()
    // Hosts serving the account's own files never get a preview: our upload slots' GET hosts and received-file hosts.
    var linkPreviewUploadHosts: Set<String> = []
    @ObservationIgnored var linkPreviewHostsAccount: String?
    var linkPreviewFolder: URL? { storageDirectory.map { AttachmentFiles.root(directory: $0, account: accountID) } }
    var linkPreviewCache: (any LinkPreviewCaching)? { store }
    func linkPreviewRosterEntry(_ contact: String) -> LinkPreviewPolicy.RosterEntry {
        guard lastSeenTracker.rosterLoaded else { return .notLoaded }
        return lastSeenTracker.roster[contact].map { .item($0.subscription) } ?? .absent
    }
    @ObservationIgnored private var uploader: AttachmentUploader?
    @ObservationIgnored private var storageDirectory: URL?
    @ObservationIgnored private lazy var uploadPasses = RerunningPass { [weak self] in self?.uploadPass() }
    @ObservationIgnored private var uploadFailures = UploadFailureBudget()
    @ObservationIgnored private let downloads = AttachmentDownloadCenter(configuration: .ephemeral)
    var attachmentLimit: Int { min(AttachmentTransfer.maximumBytes, uploadService?.maximumFileSize ?? AttachmentTransfer.maximumBytes) }
    // Never gated on the socket: a file is sealed and queued offline and uploads once the session is ready.
    var canSendAttachments: Bool { isDemo || uploadService != nil }
    @ObservationIgnored let testSessionID: String? = {
        #if DEBUG
        guard let value = ProcessInfo.processInfo.environment["XMPP_UI_TEST_STORE"],
              let id = UUID(uuidString: value) else { return nil }
        return id.uuidString
        #else
        return nil
        #endif
    }()
    @ObservationIgnored private(set) lazy var preferences: UserDefaults = {
        guard let testSessionID else { return .standard }
        return UserDefaults(suiteName: "haus.xmpp.uitest." + testSessionID) ?? .standard
    }()
    @ObservationIgnored private lazy var sessionDefaults: UserDefaults? = testSessionID == nil ? SharedSession.groupDefaults : preferences

    init() {
        // Known before storage opens, so the first frame has the account avatar and the Chats stack keeps its identity.
        // Not rewritten here: preferences change only after the pre-upgrade snapshot (`openStorage`).
        accountID = preferences.string(forKey: "lastAccount").map { JID.normalizedBare($0) ?? $0 } ?? ""
        loadBlocklist()
        NotificationActionCenter.shared.handler = { [weak self] request, budget in
            await self?.performNotificationAction(request, budget: budget) ?? .rejected
        }
        NotificationActionCenter.shared.abort = { [weak self] in self?.abortNotificationAction() ?? false }
        downloads.onFile = { [weak self] account, messageIDs, file in
            guard let self, self.accountID == account else { return }
            for id in messageIDs { self.attachmentFiles[id] = file }
        }
        contactLinks.onChange = { [weak self] in self?.applyContactNames() }
        downloads.openSecret = { [weak self] job in
            guard let encryption = self?.encryption else { throw OMEMOError.unavailable }
            return try encryption.openAttachmentSecret(account: job.account, secret: job.attachment.secret, sealedAs: job.attachment.sealedAccount)
        }
    }

    // Runs once; every caller returns only after it finished.
    func prepare() async {
        if let preparation { await preparation.value; return }
        let task = Task { await prepareOnce() }
        preparation = task
        await task.value
    }

    private func prepareOnce() async {
        // A launch into the background (a notification action) must not connect: the scene is not in front.
        applyLifecycle(lifecycleAtLaunch())
        refreshNotificationPermission()
        if testSessionID == nil {
            let tokens = PushRegistration.unsolicitedTokens()
            pushTokenTask = Task { [weak self] in
                for await token in tokens {
                    guard !Task.isCancelled else { return }
                    await self?.receivePushToken(token)
                }
            }
            startLivenessResponder()
            startOutboxRingListener()
        }
        pathMonitor.pathUpdateHandler = { [weak self] path in
            let usable = path.status == .satisfied
            Task { @MainActor in
                self?.linkPreviewCenter.hasNetwork = usable
                if usable { self?.networkBecameReachable() }
            }
        }
        pathMonitor.start(queue: .global(qos: .utility))
        await openStorage()
    }

    // The pre-upgrade snapshot precedes any migration; while it cannot be taken (background launch, lease held
    // elsewhere, failed snapshot, restored data awaiting the previous build) storage stays closed and nothing connects.
    private func openStorage(withoutSnapshot: Bool = false) async {
        guard store == nil, storageOpening == nil else { return }
        let opening = Task { await openStorageOnce(withoutSnapshot: withoutSnapshot) }
        storageOpening = opening
        await opening.value
        storageOpening = nil
    }

    private func openStorageOnce(withoutSnapshot: Bool) async {
        // A snapshot or migration holds the lease across awaits: the app must not be suspended with it.
        let activity = BackgroundActivity("Open message storage")
        defer { activity.end() }
        do {
            // Before any store opens: transferred data stays out of reach, and a crash-interrupted transfer is undone
            // first.
            let transferLocations = if let testSessionID {
                AccountTransfer.Locations.testSession(testSessionID, preferences: preferences)
            } else {
                AccountTransfer.Locations.production(messaging: try SharedStorage.groupContainer().appending(path: "Messaging", directoryHint: .isDirectory))
            }
            let transfers = transferLocations.map { AccountTransfer(locations: $0) }
            self.transfers = transfers
            if let moved = try transfers?.recover() {
                transferState = .moved(moved)
                hasLoadedChats = true
                return
            }
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
                let opening = try await snapshots.open(upgradeAllowed: !PlatformApplication.isInBackground,
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
                opened = try MessageStore(url: directory.appending(path: "messages.sqlite"))
                AccountIdentityMigration.migratePreferences(preferences)
                AccountIdentityMigration.moveFiles(directory: directory, defaults: preferences)
            }
            let savedAccount = preferences.string(forKey: "lastAccount") ?? ""
            switch try await KeyRecovery.open(store: opened, storageID: testSessionID ?? "primary", account: savedAccount) {
            case .ready(let service): encryption = service
            case .needed(let plan):
                // Nothing else may use the store until the user chooses: no sender, no connection, no notification work.
                Self.syncLog.error("encryption state unreadable: key missing \(plan.keyMissing, privacy: .public), rows \(plan.states.count, privacy: .public)")
                recoveryStore = opened
                keyRecovery = plan
                hasLoadedChats = true
                return
            }
            store = opened
            storageDirectory = directory
            let uploader = AttachmentUploader(scope: testSessionID ?? "primary")
            uploader.onFinish = { [weak self] taskID, succeeded in Task { @MainActor in await self?.uploadFinished(taskID: taskID, succeeded: succeeded) } }
            self.uploader = uploader
            outboxSender = OutboxSender(store: opened)
            accountID = savedAccount
            uploadService = uploads.load(account: accountID)
            if Self.launchesWithSamples {
                await loadDemo()
                #if DEBUG
                if ProcessInfo.processInfo.arguments.contains("-demo-key-recovery") { keyRecovery = .sample(account: accountID) }
                #endif
            } else {
                if let store, try await NotificationDiagnostics.exportIfRequested(store: store, directory: directory) {
                    pushStatus = .inspected
                    return
                }
                await refresh()
                if let openChatID { await loadEncryptionDetails(for: openChatID, refreshFromServer: false) }
                if testSessionID == nil, let saved = try NotificationAccount.load() {
                    if try await Self.ownsSavedAccount(saved, lastAccount: savedAccount, store: opened) {
                        sessionAccount = saved
                        if saved.push != nil { pushStatus = .on }
                        reconcile()
                        await queueSavedReplies()
                    } else {
                        // Left by a deleted install (the Keychain outlives it): signing in would add a new OMEMO device
                        // and rule out a transfer restore. The extension ignores it too.
                        Self.syncLog.notice("ignoring an account record this install did not save")
                        try? NotificationAccessGate.disable(at: NotificationAccessGate.location())
                    }
                }
            }
        } catch MessageStoreError.unsupportedSchema(let version) {
            // A newer build wrote this store (TestFlight allows installing an older build): open nothing for writing
            // and stay offline.
            Self.syncLog.error("store schema \(version, privacy: .public) is newer than this build's \(MessageStore.currentSchemaVersion, privacy: .public)")
            upgradeState = .newerData
        } catch {
            if upgradeState != .none { upgradeState = .none }
            // The error names a step and a file at most, never message contents.
            Self.syncLog.error("could not open storage: \(String(reflecting: error), privacy: .public)")
            self.error = "Could not open local message storage."
            hasLoadedChats = true // show the empty state behind the alert, not a blank screen
        }
    }

    // Ours if it is the account last selected here, or the store holds its encryption state (older installs did not
    // remember the selection).
    static func ownsSavedAccount(_ saved: NotificationAccount, lastAccount: String, store: MessageStore) async throws -> Bool {
        if JID.normalizedBare(lastAccount) == saved.accountID { return true }
        return try await store.encryptionStateRevision(accountID: saved.accountID) != nil
    }

    private static var launchesWithSamples: Bool {
        #if DEBUG
        ProcessInfo.processInfo.arguments.contains("-demo")
        #else
        false
        #endif
    }

    // Messages and keys stay; the samples start afresh each time and nothing is sent.
    func loadDemo() async {
        await forgetAccount()
        let token = generation
        let account = DemoSamples.account
        selectAccount(account)
        guard generation == token, let store else { return }
        do {
            try await store.eraseLocalAccount(accountID: account)
            if let storageRoot {
                try? FileManager.default.removeItem(at: AttachmentFiles.root(directory: storageRoot, account: account))
                try? FileManager.default.removeItem(at: AvatarStore.directory(root: storageRoot, account: account))
            }
            let morning = DemoSamples.morning()
            let ownAvatar = try await DemoSamples.write(to: store, files: files, avatarRoot: storageRoot, morning: morning)
            preferences.set(ownAvatar, forKey: "avatar.\(account)")
            #if DEBUG
            if ProcessInfo.processInfo.arguments.contains("-demo-long") {
                let chatID = "history@preview.local"
                // With -demo-tall, message 200 runs to 80 lines, taller than a window, for scroll checks inside it.
                let tall = ProcessInfo.processInfo.arguments.contains("-demo-tall")
                try await store.upsertChat(accountID: account, chatID: chatID, title: "History")
                for index in 1...250 {
                    let lines = tall && index == 200 ? (1...80).map { "\nLine \($0) of a message taller than the window." }.joined() : ""
                    try await store.insertMessage(StoredMessage(id: "sample-history-\(index)", accountID: account, chatID: chatID, senderID: index.isMultiple(of: 3) ? account : chatID,
                                                                body: "History message \(index)" + (index.isMultiple(of: 7) ? ", with a second sentence so some bubbles wrap onto another line." : "") + lines,
                                                                sentAt: Date(timeIntervalSince1970: 1_789_300_000 + Double(index) * 60), isOutgoing: index.isMultiple(of: 3),
                                                                wireID: index.isMultiple(of: 3) ? nil : "history-wire-\(index)"))
                }
            }
            #endif
            #if DEBUG
            // Recorded exactly as the receive path records undecryptable messages, so they are never content, never
            // reactable and never counted.
            if ProcessInfo.processInfo.arguments.contains("-demo-unreadable") {
                try await store.recordUnreadableMessage(UnreadableMessage(accountID: account, chatID: DemoSamples.alex, senderID: account, isOutgoing: true,
                    sentAt: morning.addingTimeInterval(4), reason: .notForThisDevice, key: .archive(archive: account, id: "sample-unreadable-1")))
                try await store.recordUnreadableMessage(UnreadableMessage(accountID: account, chatID: DemoSamples.alex, senderID: DemoSamples.alex, isOutgoing: false,
                    sentAt: morning.addingTimeInterval(5), reason: .decryptFailed, key: .archive(archive: account, id: "sample-unreadable-2")))
            }
            #endif
            try await store.setChatNotificationSetting(accountID: account, chatID: DemoSamples.maya, ChatNotificationSetting(mutedUntil: ChatNotificationSetting.always))
            #if DEBUG
            if ProcessInfo.processInfo.arguments.contains("-demo-typing") { typing = [DemoSamples.alex: [DemoSamples.alex]] }
            #endif
            // Sample history is read; only `-demo-unread` leaves something new.
            for chat in try await store.chats(accountID: account) { try await store.markChatRead(accountID: account, chatID: chat.id) }
            #if DEBUG
            if ProcessInfo.processInfo.arguments.contains("-demo-unread") {
                let unread = [(DemoSamples.maya, "Also, bring the map 🗺️"), (DemoSamples.maya, "The trail opens at nine."), (DemoSamples.alex, "Bringing pastries 🥐")]
                for (index, (chatID, body)) in unread.enumerated() {
                    try await store.insertMessage(StoredMessage(id: "sample-unread-\(index)", accountID: account, chatID: chatID, senderID: chatID, body: body,
                                                                sentAt: morning.addingTimeInterval(60 + Double(index)), isOutgoing: false))
                }
            }
            #endif
            #if DEBUG
            // Failing them takes the store's lease as the foreground does; nothing is sent, since the outbox never runs
            // for the samples.
            if ProcessInfo.processInfo.arguments.contains("-demo-failed") {
                do {
                    try await acquireForegroundOwnership(store, token: token)
                    let file = StoredAttachment(name: "boathouse-plan.pdf", mediaType: "application/pdf", size: 48_213, hash: String(repeating: "0", count: 64),
                                                secret: Data([0]), url: "https://example.org/upload/boathouse-plan.pdf", uploadState: .uploaded)
                    let failed = [(StoredMessage(id: "sample-failed-0", accountID: account, chatID: DemoSamples.alex, senderID: account, body: "Did the photo come through?",
                                                 sentAt: morning.addingTimeInterval(10), isOutgoing: true, wireID: "sample-failed-0"), "service-unavailable"),
                                  (StoredMessage(id: "sample-failed-1", accountID: account, chatID: DemoSamples.alex, senderID: account, body: "",
                                                 sentAt: morning.addingTimeInterval(11), isOutgoing: true, wireID: "sample-failed-1", attachment: file),
                                   MessageStore.encryptionResetRejection)]
                    for (message, rejection) in failed {
                        try await store.enqueueOutgoing(message)
                        guard let submission = try await store.claimNextOutgoing(accountID: account, messageIDs: [message.id]) else { continue }
                        try await store.finishOutgoingSubmission(submission)
                        try await store.rejectOutgoing(accountID: account, chatID: message.chatID, wireID: message.id, rejection: rejection)
                    }
                } catch { Self.syncLog.error("demo failed sends not added: \(String(describing: error), privacy: .public)") }
            }
            #endif
            guard generation == token else { return }
            #if DEBUG
            if ProcessInfo.processInfo.arguments.contains("-demo-own-device") { ownDevices = OwnDeviceReview.sampleDevices(account: account) }
            if ProcessInfo.processInfo.arguments.contains("-demo-group") {
                let room = OwnDeviceReview.sampleRoom
                try await store.upsertChat(accountID: account, chatID: room, title: "Trail crew")
                try await store.insertMessage(StoredMessage(id: "sample-group-1", accountID: account, chatID: room, senderID: room + "/Alex",
                                                            body: "Who’s bringing the map?", sentAt: morning.addingTimeInterval(-600), isOutgoing: false))
                try await store.markChatRead(accountID: account, chatID: room)
                guard generation == token else { return }
                var group = GroupChatState(members: [account, DemoSamples.alex, DemoSamples.maya], devices: OwnDeviceReview.sampleGroupDevices(account: account))
                group.joined = true
                group.localDeviceID = 31337
                group.localFingerprint = OwnDeviceReview.sampleIdentities[0].modern.map { String(format: "%02x", $0) }.joined()
                groupChats[room] = group
            }
            #endif
            await refresh()
        } catch { if generation == token { self.error = "Could not load sample conversations." } }
    }

    #if DEBUG
    // Lab domains keep the disposable-account safeguards.
    static let labDomains: Set<String> = Set(["localhost"] + [DevelopmentEndpoint.stagingDomain].compactMap { $0 })
    static var bareUsernameDomain: String? { DevelopmentEndpoint.domain }
    var isLabAccount: Bool { Self.labDomains.contains(accountDomain) }
    #else
    static var bareUsernameDomain: String? { nil }
    var isLabAccount: Bool { false }
    #endif
    var accountDomain: String { accountID.split(separator: "@", maxSplits: 1).last.map(String.init) ?? Self.bareUsernameDomain ?? "" }

    // Without `server` the domain's SRV records choose the endpoint (lab domains keep direct TLS on 5223); with one,
    // only that endpoint is used.
    func connect(username address: String, password: String, server: XMPPEndpoint? = nil, savedEndpoint: NotificationAccount? = nil) async -> Bool {
        let parts = address.trimmingCharacters(in: .whitespacesAndNewlines).split(separator: "@", maxSplits: 1).map(String.init)
        // RFC 7622 normal form from here on: the bound JID, every key and every comparison.
        let username = parts.first.flatMap(JID.normalizedLocalpart) ?? ""
        let requestedDomain = savedEndpoint?.domain ?? (parts.count == 2 ? JID.normalizedDomainpart(parts[1]) ?? "" : Self.bareUsernameDomain ?? "")
        let localPattern = parts.count == 2 ? #"^[^@/\s]{1,64}$"# : #"^[a-z0-9][a-z0-9._-]{0,63}$"#
        let domainPattern = #"^(localhost|[a-z0-9]([a-z0-9-]{0,61}[a-z0-9])?(\.[a-z0-9]([a-z0-9-]{0,61}[a-z0-9])?)+)$"#
        guard transportWanted, !quiescing, !session.isConnecting else { return false }
        guard savedEndpoint != nil || parts.count == 2 || Self.bareUsernameDomain != nil else {
            error = "Enter your full address, including the server, such as name@example.org."
            return false
        }
        guard username.range(of: localPattern, options: .regularExpression) != nil,
              requestedDomain.range(of: domainPattern, options: .regularExpression) != nil else {
            error = "Enter an address such as name@example.org."
            return false
        }
        let manual = savedEndpoint == nil
        if manual { userWantsOffline = false; authenticationRejected = false; reconnection = ReconnectPolicy() }
        #if DEBUG
        let fixedEndpoint = server ?? (Self.labDomains.contains(requestedDomain)
            ? XMPPEndpoint(host: requestedDomain == "localhost" ? DevelopmentEndpoint.host : requestedDomain, port: 5223, security: .directTLS) : nil)
        #else
        let fixedEndpoint = server
        #endif
        if let sessionAccount, sessionAccount.accountID != username + "@" + requestedDomain {
            await forgetAccount()
            guard transportWanted, !quiescing else { return false }
        }
        let priorEvents = eventTask
        let priorSetup = setupTask
        let priorBackfill = backfillTask
        let previous = resetSession()
        let token = generation
        session = .connecting(step: "Connecting…")
        let connection = XMPPClient(labCertificateAuthority: DevelopmentEndpoint.certificateAuthority)
        client = connection
        // Assign account before consuming events; scoped refresh rejects stale results. A discovered endpoint is saved
        // only after the first connection through it succeeds.
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
            // A full buffer drops the client's disconnect event and finishes the stream instead; without this the
            // session would stay "connected" with nothing left to reconnect it.
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
            // On iOS the stream always binds available and active; a Mac with no window or nobody at it binds inactive
            // or away.
            let binding = lifecycle.streamBinding
            try await connection.setAvailability(binding.presence == .available ? .active : awayAvailability, clientActive: binding.clientActive)
            guard generation == token else { return false }
            let connectedSession = try await connection.connect(route: endpoint.route, domain: endpoint.domain, username: username,
                                                                password: password, requireSCRAM: endpoint.requiresSCRAM)
            guard generation == token, accountID == endpoint.accountID, let current = sessionAccount,
                  current.accountID == endpoint.accountID else { await connection.disconnect(); return false }
            // Only after authentication succeeds may a manually entered password replace saved credentials.
            let connected = current.connected(connectedSession)
            sessionAccount = connected
            do { try connected.save() }
            catch {
                self.error = "Connected, but the password could not be saved. You will be asked for it on the next launch."
            }
            // `.online` was emitted before `connect` returned, so this runs alongside the setup task; not awaited, so
            // the sign-in sheet closes at once.
            startPushSetup(client: connection, session: connected, token: token, interactive: manual)
            #if os(macOS)
            // The Mac's own banners need permission whether or not it registers for push; a push setup that asks too
            // waits for this prompt.
            if manual { Task { await requestNotificationPermission() } }
            #endif
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

    private var wantsConnection: Bool {
        transportWanted && !quiescing && !userWantsOffline && !authenticationRejected && sessionAccount != nil && !isDemo && upgradeState == .none
            && transferState == .none
    }

    // The single place that turns "should be connected" into `connect()`; every input change only updates state and
    // calls this.
    private func reconcile() {
        guard wantsConnection, session.isConnectable, reconnectTask == nil, let saved = sessionAccount else { return }
        let delay = reconnection.nextDelay
        Self.syncLog.notice("reconnect in \(Int(delay / .milliseconds(1)), privacy: .public) ms attempt=\(self.reconnection.attempt, privacy: .public)")
        reconnectTask = Task { [weak self] in
            try? await Task.sleep(for: delay)
            guard let self, !Task.isCancelled else { return }
            await self.lifecycleTask?.value
            self.reconnectTask = nil
            guard self.wantsConnection, self.session.isConnectable, self.sessionAccount == saved else { return }
            self.reconnection.attemptStarted()
            _ = await self.connect(username: saved.username, password: saved.password, savedEndpoint: saved)
        }
    }

    private func networkBecameReachable() {
        guard wantsConnection, session.isConnectable else { return }
        reconnection.retryNow()
        reconnectTask?.cancel(); reconnectTask = nil
        reconcile()
    }

    func signOut() async {
        let account = accountID
        await forgetAccount()
        // Replies saved before the upgrade for this account are not sent after it signed out.
        if !account.isEmpty { try? snapshots?.removeSavedReplies(of: account) }
        reconnection = ReconnectPolicy()
        selectAccount("")
        AccountResource.forgetPreferencesAtSignOut(of: account, app: preferences, group: sessionDefaults)
    }

    func disconnect() async {
        userWantsOffline = true
        reconnectTask?.cancel(); reconnectTask = nil
        await quiesceTransport()
    }

    private func forgetAccount() async {
        quiescing = true
        // No preview fetch of this account runs on, or lands in its cache, while its data is being removed.
        linkPreviewCenter.use(account: "", folder: nil, cache: nil)
        generation = UUID() // Invalidate pending permission/registration before removing credentials.
        let token = generation
        let account = accountID
        SignOutCleanup(defaults: preferences).owe(account)
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
            donationEpoch += 1
            await CommunicationHistory.deleteAll()
        } else if badgeUsesDockTile {
            appBadge = nil
            setAppBadge(0)
        }
        sessionAccount = nil
        pushStatus = .off
        // Wait for a setup in flight so its register or enable cannot land after this revocation and disable. Sign-out
        // cannot happen while the permission prompt is on screen.
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
        await quiesceTransport(signingOut: true)
        if let localFailure { self.error = localFailure }
    }

    // Nothing else changes the lifecycle signals.
    func applyLifecycle(_ updates: [LifecycleUpdate]) {
        for update in updates {
            switch update {
            case .start(let signals):
                lifecycle = signals
                syncForegroundNotificationChat()
            case .interactionEnded(let at): recordLastInteraction(at: at ?? Date())
            case .change(let signals, let activated): changeLifecycle(to: signals, activated: activated)
            }
        }
        linkPreviewCenter.setForeground(lifecycle.windowVisible)
    }

    // The Mac waits for this before acknowledging sleep or replying to a quit.
    func lifecycleSettled() async {
        while let task = lifecycleTask {
            await task.value
            if lifecycleTask == task { return }
        }
    }

    // Serialize lifecycle transitions; never release the lease with a suspended writer alive.
    private func changeLifecycle(to signals: LifecycleSignals, activated: Bool) {
        let old = lifecycle
        let transition = LifecycleTransition.between(old, signals, activated: activated)
        // Checked under the old signals and sent before a quiesce's away presence and disconnect.
        var typingEnd: Task<Void, Never>?
        if Self.attention.endsChatState(from: old, to: signals), let typing = ownTyping {
            sendOwnTyping(ownTyping?.sender.left(), to: typing.chat)
            ownTyping = nil
            ownTypingPause?.cancel()
            typingEnd = ownTypingSend
        }
        lifecycle = signals
        syncForegroundNotificationChat()
        if Self.attention.startsReading(from: old, to: signals), let chatID = openChatID { startedReading(chatID) }
        appBadge = nil
        if transition.quiescesTransport { quiescing = true }
        // Begun before anything is awaited: iOS grants background time asynchronously, and an app it suspends while
        // holding the lease's file lock is killed.
        let protection = transition.quiescesTransport ? BackgroundActivity("Finish encrypted synchronization") : nil
        let previous = lifecycleTask
        let requested = ContinuousClock.now
        if transition.quiescesTransport {
            Self.lifecycleLog.notice("background transition requested, behind another: \(previous != nil, privacy: .public)")
        }
        lifecycleTask = Task { [weak self] in
            defer { protection?.end() }
            await previous?.value
            guard let self else { return }
            if transition.quiescesTransport {
                // Storage still opening may hold the lease before `store` is set; it is joined, never cut short.
                await self.storageOpening?.value
                let waited = Int((ContinuousClock.now - requested) / .milliseconds(1))
                Self.lifecycleLog.notice("background transition started after \(waited, privacy: .public) ms")
                // The session hibernates (up to days with push): it must read as away until it resumes.
                if transition.presence == .away, let client = self.client, self.isConnected {
                    await typingEnd?.value
                    try? await client.setAvailability(self.awayAvailability, clientActive: transition.clientActive ?? false)
                }
                await self.quiesceTransport()
            } else {
                guard self.transportWanted else { return }
                // Never on iOS, where presence follows the transport. A stream still binding records the change and
                // announces it once online, so a change made mid-connect is not lost.
                if let presence = transition.presence, let client = self.client {
                    try? await client.setAvailability(presence == .available ? .active : self.awayAvailability,
                                                      clientActive: transition.clientActive ?? signals.windowVisible)
                }
                if transition.resumesTransport {
                    self.returnedToForegroundForUpgrade()
                    // A suspended app does not get the contacts change notification.
                    self.contactLinks.refreshSoon()
                    self.refreshNotificationPermission()
                    self.reconnection.retryNow()
                    self.reconcile()
                }
                if transition.presence == nil, let active = transition.clientActive, let client = self.client {
                    try? await client.setClientActive(active)
                }
                // Not awaited: a background transition queued behind this one disconnects first, then joins the load.
                if transition.resumesTransport, self.transportWanted { self.refreshSoon() }
            }
        }
    }

    private func syncForegroundNotificationChat() {
        ForegroundNotificationState.shared.openChatID = Self.attention.bannerHiddenChat(lifecycle, openChatID: openChatID)
    }

    private func startedReading(_ chatID: String) {
        readingStarts += 1
        guard !isDemo else { return }
        let account = accountID
        Task { await DeliveredNotificationCleaner.removeThread(accountID: account, chatID: chatID) }
        if transportWanted, hasTransportOwnership, !quiescing, let store {
            Task { try? await store.dismissReactionNotifications(accountID: account, chatID: chatID) }
        }
    }

    private func returnedToForegroundForUpgrade() {
        if store == nil, upgradeState == .deferred || upgradeState == .waitingForLease {
            Task { await openStorage() }
        }
    }

    private func readBackupStatus() {
        guard let snapshots else { return }
        previousVersionBackup = snapshots.manifest
        keptCopyUnreadable = snapshots.status(.thisVersion) == .unreadable
        previousVersionBackupUnreadable = snapshots.status(.previousVersion) == .unreadable || (previousVersionBackup == nil && keptCopyUnreadable)
    }

    // Another process holds the lease: retry shortly, never take it by force.
    private func retryOpeningStorage() {
        Task { [weak self] in
            try? await Task.sleep(for: .seconds(2))
            guard let self, self.upgradeState == .waitingForLease, self.transportWanted else { return }
            await self.openStorage()
        }
    }

    func retryUpgrade() async {
        guard store == nil, case .snapshotFailed = upgradeState else { return }
        upgradeState = .preparing
        await openStorage()
    }

    func upgradeWithoutBackup() async {
        guard store == nil, case .snapshotFailed = upgradeState else { return }
        upgradeState = .preparing
        await openStorage(withoutSnapshot: true)
    }

    // This version's kept data goes back with its messages and encryption sessions; the previous build's data, if it
    // ran, becomes the backup.
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

    // Takes a fresh snapshot of the restored data first when the previous version ran on it.
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

    // Their sessions moved on, and a restore puts back older session state the peers no longer match.
    func chatsWithEncryptedSendsSinceBackup() async -> [String] {
        guard let store, let backup = previousVersionBackup, !accountID.isEmpty else { return [] }
        return (try? await store.chatsWithEncryptedSends(accountID: accountID, since: backup.takenAt)) ?? []
    }

    func deletePreviousVersionBackup() {
        guard let snapshots else { return }
        do { try snapshots.delete() }
        catch { self.error = "The backup could not be deleted. Try again." }
        readBackupStatus()
    }

    // Quiesces the transport like a background transition but keeps (or takes, never by force) the lease so the store
    // is closed and swapped under it. Afterwards nothing reconnects or migrates until the user chooses.
    func restorePreviousVersion() async {
        guard let snapshots, let store, upgradeState == .none, previousVersionBackup != nil else { return }
        upgradeState = .restoring
        restoringData = true
        defer { restoringData = false }
        let background = BackgroundActivity("Restore previous version's data")
        defer { background.end() }
        reconnectTask?.cancel(); reconnectTask = nil
        await stopTransportWork()
        quiescing = true
        var leased = await store.holdsTransportOwnership
        for _ in 0..<40 where !leased {
            do { try await store.acquireTransportOwnership(); leased = true }
            catch MessageStoreError.transportOwnedElsewhere { guard (try? await Task.sleep(for: .milliseconds(250))) != nil else { break } }
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
            // Whatever the lease is at this point: a background transition during the restore left it alone, and the restore
            // gives it up here if the app is no longer in front.
            hasTransportOwnership = await store.holdsTransportOwnership
            if hasTransportOwnership, !transportWanted { await releaseLeaseInBackground(store) }
            quiescing = false
            upgradeState = .none
            self.error = "The backup could not be restored: " + PreUpgradeSnapshot.describe(error)
            reconcile()
        } catch {
            // Part way: the journal finishes it, here or on the next launch.
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
        // Fetches still writing to the closed store stop and record nothing.
        useLinkPreviewAccount()
        chats = []
        messages = []
    }

    // Under the lease (taken, never by force; nothing else runs on this store, so no sender to join): discards exactly
    // the state the screen described and creates a new identity. The next connection publishes the new device and
    // removes the old one.
    func startEncryptionOver() async {
        guard let plan = keyRecovery, !startingEncryptionOver else { return }
        guard !plan.isSample else { keyRecovery = nil; return }
        guard let store = recoveryStore else { return }
        startingEncryptionOver = true
        defer { startingEncryptionOver = false }
        let background = BackgroundActivity("Set up encryption again")
        defer { background.end() }
        var leased = await store.holdsTransportOwnership
        var busy = false
        for _ in 0..<40 where !leased {
            do { try await store.acquireTransportOwnership(); leased = true }
            catch MessageStoreError.transportOwnedElsewhere { busy = true; guard (try? await Task.sleep(for: .milliseconds(250))) != nil else { break } }
            catch {
                Self.syncLog.error("setting up encryption again could not take the lease: \(String(describing: error), privacy: .public)")
                busy = false
                break
            }
        }
        guard leased else {
            self.error = busy ? "A notification is being processed. Try again in a moment."
                : "Encryption could not be set up again, and nothing was discarded. Try again."
            return
        }
        do {
            let deviceID = try await KeyRecovery.startOver(plan, store: store, storageID: testSessionID ?? "primary")
            Self.syncLog.notice("encryption set up again: new device \(deviceID.map(String.init) ?? "none", privacy: .public), discarded \(plan.states.count, privacy: .public) rows")
        } catch {
            Self.syncLog.error("setting up encryption again failed: \(String(describing: error), privacy: .public)")
            try? await store.releaseTransportOwnership()
            // Rows written since the screen was read are shown before anything is discarded.
            switch try? await KeyRecovery.open(store: store, storageID: testSessionID ?? "primary", account: plan.account) {
            case .needed(let current)?:
                keyRecovery = current
                self.error = "Encryption could not be set up again, and nothing was discarded. Try again."
                return
            case .ready?: break // nothing is unreadable any more: open normally
            case nil:
                self.error = "Encryption could not be set up again, and nothing was discarded. Try again."
                return
            }
        }
        try? await store.releaseTransportOwnership()
        try? await store.close()
        recoveryStore = nil
        keyRecovery = nil
        hasLoadedChats = false
        await openStorage()
    }

    func transferArchiveURL(_ moved: AccountTransfer.Moved) -> URL? { transfers?.archive(of: moved) }

    func transferCode(_ moved: AccountTransfer.Moved) -> TransferCode? { transfers?.code(of: moved) }

    var canTransfer: Bool {
        transfers != nil && store != nil && transferState == .none && upgradeState == .none && keyRecovery == nil
            && !accountID.isEmpty && !isDemo
    }

    // A restore replaces the sample conversations; whether the store holds an identity is checked when it runs.
    var canRestoreTransfer: Bool {
        transfers != nil && store != nil && transferState == .none && upgradeState == .none && keyRecovery == nil
            && (accountID.isEmpty || isDemo)
    }

    // Keeps (or takes, never by force) the lease and quiesces like a background transition. On success storage stays
    // closed and nothing connects until the user settles it; on failure everything is put back.
    func startTransfer() async {
        guard canTransfer, let transfers, let store else { return }
        let account = accountID, code = TransferCode.generate()
        transferState = .exporting(nil)
        restoringData = true
        defer { restoringData = false }
        let background = BackgroundActivity("Prepare transfer")
        defer { background.end() }
        reconnectTask?.cancel(); reconnectTask = nil
        downloads.reset()
        // No preview fetch writes into the folders while they are packed.
        linkPreviewCenter.use(account: "", folder: nil, cache: nil)
        await stopTransportWork()
        quiescing = true
        guard await takeLease(store) else {
            hasTransportOwnership = false
            quiescing = false
            transferState = .none
            useLinkPreviewAccount()
            self.error = "A notification is being processed. Try the transfer again in a moment."
            reconcile()
            return
        }
        do {
            let moved = try await transfers.export(store: store, accountID: account, code: code, now: Date()) { progress in
                Task { @MainActor [weak self] in self?.showTransferProgress(progress) }
            }
            Self.syncLog.notice("transfer packed; this install is moved")
            try? await store.close()
            closeStorageAfterRestore()
            quiescing = false
            transferState = .moved(moved)
        } catch {
            Self.syncLog.error("transfer failed: \(String(describing: error), privacy: .public)")
            // Before the store moved it is still open under the lease; after, it was closed and put back.
            try? await store.close()
            closeStorageAfterRestore()
            quiescing = false
            transferState = .none
            hasLoadedChats = false
            self.error = "The transfer file could not be made, and nothing was changed. " + AccountTransfer.describe(error)
            await openStorage()
        }
    }

    private func showTransferProgress(_ progress: AccountTransfer.Progress) {
        if case let .exporting(current) = transferState {
            // Reports hop here one by one and may arrive out of order; a bar never goes back.
            if let current, (current.step.rawValue, current.fraction) > (progress.step.rawValue, progress.fraction) { return }
            transferState = .exporting(progress)
        } else if let current = restoreProgress, progress.fraction >= current.fraction {
            restoreProgress = progress
        }
    }

    func useDataHereAgain() async {
        guard case let .moved(moved) = transferState, let transfers else { return }
        transferState = .settling
        do { try transfers.rollBackExport() }
        catch {
            Self.syncLog.error("could not take the moved data back: \(String(describing: error), privacy: .public)")
            transferState = .moved(moved)
            self.error = "The data could not be put back on this \(ThisDevice.noun)."
            return
        }
        Self.syncLog.notice("transfer cancelled; using the data here again")
        transferState = .none
        hasLoadedChats = false
        await openStorage()
    }

    func deleteMovedData() async {
        guard case let .moved(moved) = transferState, let transfers else { return }
        transferState = .settling
        do { try transfers.deleteMovedData() }
        catch {
            Self.syncLog.error("could not delete the moved data: \(String(describing: error), privacy: .public)")
            transferState = .moved(moved)
            self.error = "The data could not be deleted from this \(ThisDevice.noun). Try again."
            return
        }
        // Delivered notifications and donated interactions name the account's contacts.
        UNUserNotificationCenter.current().removeAllDeliveredNotifications()
        UNUserNotificationCenter.current().removeAllPendingNotificationRequests()
        appBadge = nil
        setAppBadge(0)
        donationEpoch += 1
        await CommunicationHistory.deleteAll()
        selectAccount("")
        preferences.removeObject(forKey: "lastAccount")
        transferState = .none
        hasLoadedChats = false
        await openStorage()
    }

    // Reads and checks the file before anything changes, then puts it in place under the lease. Returns why it did not,
    // or nil once restored.
    func restoreTransfer(from file: URL, code: TransferCode) async -> String? {
        guard canRestoreTransfer, let transfers, let store, restoreProgress == nil else { return "A restore can’t start right now." }
        restoreProgress = AccountTransfer.Progress(step: .restoring, fraction: 0)
        defer { restoreProgress = nil }
        let background = BackgroundActivity("Restore transfer")
        defer { background.end() }
        do { if let blocker = try await transfers.importBlocker(store: store) { return AccountTransfer.describe(blocker) } }
        catch { return AccountTransfer.describe(error) }
        let staged: AccountTransfer.Staged
        do {
            staged = try await Task.detached {
                try Self.readPicked(file) { url in
                    try transfers.stage(archive: url, code: code) { progress in
                        Task { @MainActor [weak self] in self?.showTransferProgress(progress) }
                    }
                }
            }.value
        } catch {
            Self.syncLog.error("restore refused: \(String(describing: error), privacy: .public)")
            return AccountTransfer.describe(error)
        }
        guard canRestoreTransfer, self.store === store else { return "A restore can’t start right now." }
        restoringData = true
        defer { restoringData = false }
        reconnectTask?.cancel(); reconnectTask = nil
        downloads.reset()
        await stopTransportWork()
        quiescing = true
        guard await takeLease(store) else {
            hasTransportOwnership = false
            quiescing = false
            return "A notification is being processed. Try again in a moment."
        }
        do {
            try await transfers.commit(staged, store: store, now: Date())
        } catch {
            Self.syncLog.error("restore failed: \(String(describing: error), privacy: .public)")
            if await store.holdsTransportOwnership {
                // Refused before the store closed: it is as it was.
                try? await store.releaseTransportOwnership()
                hasTransportOwnership = false
                quiescing = false
                reconcile()
            } else {
                closeStorageAfterRestore()
                quiescing = false
                hasLoadedChats = false
                await openStorage()
            }
            return AccountTransfer.describe(error)
        }
        Self.syncLog.notice("restored a transfer for \(staged.manifest.accountID.isEmpty ? "no account" : "an account", privacy: .public)")
        closeStorageAfterRestore()
        quiescing = false
        hasLoadedChats = false
        transferRestored = true
        await openStorage()
        return nil
    }

    // A coordinated read inside the security scope, so a file in iCloud Drive is downloaded first.
    nonisolated private static func readPicked<T>(_ url: URL, _ read: (URL) throws -> T) throws -> T {
        let scoped = url.startAccessingSecurityScopedResource()
        defer { if scoped { url.stopAccessingSecurityScopedResource() } }
        var coordination: NSError?, result: Result<T, any Error>?
        NSFileCoordinator().coordinate(readingItemAt: url, options: [], error: &coordination) { readable in
            result = Result { try read(readable) }
        }
        if let coordination { throw coordination }
        guard let result else { throw CocoaError(.fileReadUnknown) }
        return try result.get()
    }

    // Kept or taken, never by force: false when another process holds it for ten seconds, or once transport is unwanted.
    private func takeLease(_ store: MessageStore, whileWanted: Bool = false) async -> Bool {
        var leased = await store.holdsTransportOwnership
        for _ in 0..<40 where !leased && (!whileWanted || transportWanted) {
            do { try await store.acquireTransportOwnership(); leased = true }
            catch MessageStoreError.transportOwnedElsewhere { guard (try? await Task.sleep(for: .milliseconds(250))) != nil else { break } }
            catch { Self.lifecycleLog.error("lease not taken: \(String(describing: error), privacy: .public)"); break }
        }
        return leased
    }

    // From here on away presence reports this as the last time the user was here.
    private func recordLastInteraction(at moment: Date) {
        // Nothing the previous build left is rewritten or added to before its snapshot exists.
        guard store != nil else { return }
        SharedSession.recordLeftForeground(moment, defaults: sessionDefaults)
    }

    private var awayAvailability: XMPPAvailability {
        BackgroundSession.availability(sharesLastSeen: accountPreferences.lastSeen, leftForeground: SharedSession.leftForeground(defaults: sessionDefaults))
    }

    private func quiesceTransport(signingOut: Bool = false) async {
        await stopTransportWork()
        // A restore holds the lease until it closes the store, and releases it itself if it is refused.
        guard !restoringData else { return }
        hasTransportOwnership = false
        guard let store else { return }
        guard signingOut else { return await releaseLeaseInBackground(store) }
        // The rows go under the lease, so no extension run writes them meanwhile. Until the lease is released again a
        // background transition joins this and connect waits; in the background the rows stay owed.
        let background = BackgroundActivity("Sign out"); quiescing = true; acquiringOwnership = true
        defer { quiescing = false; acquiringOwnership = false; background.end() }
        if transportWanted, await takeLease(store, whileWanted: true) { await settleSignOut(store) } else { SignOutCleanup.log.error("sign-out rows stay owed: no lease") }
        await releaseLeaseInBackground(store)
    }

    // The store frees the kernel lock even when marking interrupted sends fails, so only a failed unlock keeps it; that
    // is retried. While the lock holds, background time is kept that only a later release ends; when it runs out iOS
    // ends the process.
    private func releaseLeaseInBackground(_ store: MessageStore) async {
        hasTransportOwnership = false
        for attempt in 1...3 {
            do {
                try await store.releaseTransportOwnership()
                Self.lifecycleLog.notice("lease released")
            } catch MessageStoreError.transportOwnershipRequired {
            } catch {
                // Sends the release could not mark stay as they are; every owner recovers them after acquiring.
                Self.lifecycleLog.error("lease release failed, attempt \(attempt, privacy: .public): \(String(reflecting: error), privacy: .public)")
            }
            guard await store.holdsTransportOwnership else {
                unreleasedLease?.end()
                unreleasedLease = nil
                return
            }
            if attempt < 3 { try? await Task.sleep(for: .milliseconds(100)) }
        }
        Self.lifecycleLog.fault("lease still held: the transport lock did not unlock")
        hasTransportOwnership = true
        if unreleasedLease == nil { unreleasedLease = BackgroundActivity("Hold the unreleased lease") }
    }

    // Without giving up the lease: blocks new transport, crypto and setup work, disconnects, and joins every reader,
    // consumer, sender and UI crypto mutation.
    private func stopTransportWork() async {
        quiescing = true
        defer { quiescing = false }
        let clock = ContinuousClock(), start = clock.now
        let events = eventTask
        let setup = setupTask
        let backfill = backfillTask
        let drain = drainTask
        let previous = resetSession()
        await previous?.disconnectAndWait()
        let disconnected = clock.now
        defer {
            let disconnect = Int((disconnected - start) / .milliseconds(1)), joins = Int((clock.now - disconnected) / .milliseconds(1))
            Self.lifecycleLog.notice("transport stopped: disconnect \(disconnect, privacy: .public) ms, joins \(joins, privacy: .public) ms")
        }
        await events?.value
        // Setup's archive walk, initialize, rejoin and pending retry are all structured children of it.
        await setup?.value
        await backfill?.value
        if backfillTask == backfill { backfillTask = nil }
        await drain?.value
        // Includes already-started UI trust/repair/discovery work and an acquisition that was suspended in the store
        // actor when the scene changed.
        while activeEncryptionOperations > 0 || acquiringOwnership {
            try? await Task.sleep(for: .milliseconds(10))
        }
    }

    // An extension run that held the lease may have posted for the chat already on screen; every such run is over.
    private func dismissOpenChatNotifications(store: MessageStore, account: String) async {
        guard let chatID = openChatID, Self.attention.clearsNotifications(of: chatID, lifecycle, openChatID: openChatID),
              !isDemo, accountID == account, hasTransportOwnership else { return }
        try? await store.dismissReactionNotifications(accountID: account, chatID: chatID)
        await DeliveredNotificationCleaner.removeThread(accountID: account, chatID: chatID)
    }

    private func acquireForegroundOwnership(_ store: MessageStore, token: UUID) async throws {
        acquiringOwnership = true
        defer { acquiringOwnership = false }
        for attempt in 0..<120 {
            guard transportWanted, !quiescing, generation == token else { throw CancellationError() }
            do {
                try await store.acquireTransportOwnership()
                // An account whose sign-out rows are still owed never gets a session.
                guard await SignOutCleanup(defaults: preferences).settle(store: store) else { await releaseLeaseInBackground(store); throw SignOutCleanup.Owed() }
                guard transportWanted, !quiescing, generation == token else { throw CancellationError() }
                hasTransportOwnership = true
                return
            }
            catch MessageStoreError.transportOwnedElsewhere {
                guard attempt < 119 else { throw MessageStoreError.transportOwnedElsewhere }
                try await Task.sleep(for: .milliseconds(250))
            }
        }
    }

    func enableNotifications() async {
        guard !accountID.isEmpty, testSessionID == nil, !isDemo else { return }
        setPushWanted(true, account: accountID)
        pushIntent += 1
        if pushStatus != .on { pushStatus = .settingUp }
        let token = generation
        guard let client, let session = sessionAccount, isConnected else {
            // The next connection finishes the setup; asked here, permission needs no prompt then.
            #if os(macOS)
            await requestNotificationPermission()
            #else
            if await Self.notificationAuthorization() == .notDetermined {
                _ = try? await UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound, .badge])
                refreshNotificationPermission()
            }
            #endif
            if generation == token, pushWanted { pushStatus = .settingUp }
            return
        }
        startPushSetup(client: client, session: session, token: token, interactive: true)
        await pushTask?.value
    }

    #if os(macOS)
    // Callers that come while the prompt is up wait for its answer, so one sign-in shows one prompt.
    func requestNotificationPermission() async {
        guard testSessionID == nil, !isDemo, !accountID.isEmpty else { return }
        #if DEBUG
        if MacUnobtrusive.isOn || MacDebugNotificationLog.mode != nil { return }
        #endif
        if let permissionRequest { await permissionRequest.value; return }
        let request = Task { @MainActor in
            guard await Self.notificationAuthorization() == .notDetermined else { return }
            _ = try? await UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound, .badge])
        }
        permissionRequest = request
        await request.value
        if permissionRequest == request { permissionRequest = nil }
        refreshNotificationPermission()
    }

    func allowNotifications() async {
        await requestNotificationPermission()
        await pushTask?.value
        let authorization = await Self.notificationAuthorization()
        guard PushStatus.resumesSetup(after: authorization, status: pushStatus, wanted: pushWanted, offered: PushService.isOffered),
              let client, let session = sessionAccount, isConnected else { return }
        startPushSetup(client: client, session: session, token: generation, interactive: false)
        await pushTask?.value
    }
    #endif

    // Offline or on a failure, the revocation and disable wait in the saved registration state for the next connection.
    func disableNotifications() async {
        guard !accountID.isEmpty, testSessionID == nil, !isDemo else { return }
        let account = accountID
        setPushWanted(false, account: account)
        pushIntent += 1
        pushStatus = .off
        let token = generation
        do {
            guard try stagePushTurnOff(account: account) else { return }
            guard let client, isConnected, hasTransportOwnership, transportWanted, !quiescing, generation == token else { return }
            activeEncryptionOperations += 1
            defer { activeEncryptionOperations -= 1 }
            try await settlePushCleanup(client: client, account: account, token: token)
        } catch {
            if generation == token, accountID == account { Self.syncLog.error("push revocation will retry on reconnect") }
        }
    }

    // Taking the subscription out of the saved account makes the extension's guard decline from then on.
    @discardableResult private func stagePushTurnOff(account: String) throws -> Bool {
        let enabled = sessionAccount?.accountID == account ? sessionAccount?.push : nil
        guard let state = try PushRegistrationState.turningOff(accountID: account, saved: try PushRegistrationState.load(accountID: account),
                                                               enabled: enabled) else { return false }
        try state.save()
        if let session = sessionAccount, session.accountID == account, session.push != nil {
            let saved = session.replacingPush(nil)
            try saved.save()
            sessionAccount = saved
        }
        return true
    }

    // A reconnect during the permission prompt waits for the answer, then sets up without asking again.
    private func startPushSetup(client: XMPPClient, session: NotificationAccount, token: UUID, interactive: Bool) {
        let previous = pushTask
        pushTask = Task { [weak self] in
            await previous?.value
            guard let self, self.generation == token, !Task.isCancelled else { return }
            await self.reconcilePush(client: client, session: session, token: token, interactive: interactive)
        }
    }

    // Only a manual sign-in or a Settings tap (`interactive`) may show the permission prompt. Only the transport work
    // counts as an encryption operation, so a background transition never waits for an unanswered prompt or APNs.
    private func reconcilePush(client: XMPPClient, session: NotificationAccount, token: UUID, interactive: Bool) async {
        guard testSessionID == nil, !isDemo, hasTransportOwnership, transportWanted, !quiescing, generation == token else { return }
        let account = session.accountID, intent = pushIntent
        do {
            let supported: Bool
            do {
                activeEncryptionOperations += 1
                defer { activeEncryptionOperations -= 1 }
                // A build that offers no push keeps no subscription: one a run that offered it left behind is turned
                // off.
                if !PushService.isOffered, sessionAccount?.accountID == account, sessionAccount?.push != nil {
                    try stagePushTurnOff(account: account)
                }
                try await settlePushCleanup(client: client, account: account, token: token)
                guard generation == token, pushIntent == intent else { return }
                guard pushWanted, PushService.isOffered else { pushStatus = .off; return }
                supported = try await client.supportsPushNotifications()
            }
            guard generation == token, pushIntent == intent else { return }
            guard supported else { pushStatus = .unsupported; return }
            var authorization = await Self.notificationAuthorization()
            if authorization == .notDetermined, interactive {
                if pushStatus != .on { pushStatus = .settingUp }
                #if os(macOS)
                await requestNotificationPermission()
                #else
                _ = try? await UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound, .badge])
                refreshNotificationPermission()
                #endif
                authorization = await Self.notificationAuthorization()
            }
            guard generation == token, pushIntent == intent else { return }
            #if os(macOS)
            let (_, alertStyle) = await Self.notificationPermission()
            guard generation == token, pushIntent == intent else { return }
            if let stop = PushStatus.gate(for: authorization, alertStyle: alertStyle, interactive: false) {
                if sessionAccount?.accountID == account, sessionAccount?.push != nil {
                    activeEncryptionOperations += 1
                    defer { activeEncryptionOperations -= 1 }
                    try stagePushTurnOff(account: account)
                    try await settlePushCleanup(client: client, account: account, token: token)
                    guard generation == token, pushIntent == intent else { return }
                }
                pushStatus = stop
                return
            }
            #else
            if let stop = PushStatus.gate(for: authorization, interactive: false) { pushStatus = stop; return }
            #endif
            if pushStatus != .on { pushStatus = .settingUp }
            let deviceToken = try await PushRegistration.request()
            refreshNotificationPermission()
            guard generation == token, pushIntent == intent, pushWanted, transportWanted, !quiescing, hasTransportOwnership,
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

    // A subscription saved at another push service is disabled at the account server before a new one replaces it, so
    // the two are never enabled together.
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

    // Best effort at the old gateway; at the account server only a transport failure stops the migration (the old
    // subscription stays saved, so the next connection repeats it).
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

    // Each step is stored separately and cleared only when confirmed or when `PushCleanup` says nothing is left, so a
    // failure of either leaves it for the next connection, whether or not push is wanted.
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
        // The disable goes ahead even when the revocation must be retried: it is what stops the account server
        // publishing.
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
            // A callback while offline still becomes durable work for this account's next authenticated connection.
            // Logout clears sessionAccount before any suspension.
            try stagePushToken(deviceToken, account: session.accountID, configuration: push)
            guard transportWanted, !quiescing, hasTransportOwnership, isConnected, let client else { return }
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
                let result = try await client.updatePushRegistration(operation, configuration: state.configuration, environment: environment,
                                                                     topic: PushService.topic)
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
        contactLinks.reset()
        chats = []
        hasLoadedChats = account.isEmpty // sign-out shows its empty state at once
        messages = []
        messageReactions = [:]; messageReceipts = [:]
        attachmentFiles = [:]
        downloads.reset()
        openChatID = nil
        requestedRoute = nil
        encryptionOverviewChatID = nil; encryptionOverview = nil; encryptionDetailsChatID = nil
        refreshFence = [:]; encryptionAttention = EncryptionAttention(); ownDevices = []
        uploadService = uploads.load(account: account)
        uploads.publish(account: account)
        shareSuggestionsEnabled = ShareSuggestionSetting.isEnabled(accountID: account, defaults: sessionDefaults)
        resetTyping()
        lastSeenTracker = LastSeenTracker()
        // The previous account's preview fetches stop at once, not at the next display.
        linkPreviewUploadHosts = []; linkPreviewHostsAccount = nil
        useLinkPreviewAccount()
        preferences.set(account, forKey: "lastAccount")
    }

    // Seals once and stores everything the send will need; unsendable until the background PUT succeeds, and nothing is
    // regenerated. Never with a caption: Conversations shows a file only when the body is exactly its link.
    func sendAttachment(_ prepared: PreparedAttachment, to chatID: String, replyingTo source: ChatMessage? = nil) async -> Bool {
        guard !isSending, let store, let files, !accountID.isEmpty else { return false }
        guard !isGroup(chatID) else { error = "Files can't be sent to groups yet."; return false }
        if let source, !canReplyWithFilesAlone(to: source, in: chatID) {
            // The chat's encryption changed after Send was pressed; nothing was queued.
            error = "This reply can't be sent with files alone in this chat. Add a caption to send it."; return false
        }
        let reply = source.map { replySnapshot(of: $0, in: chatID) }
        guard prepared.data.count <= attachmentLimit else {
            error = AttachmentPreparer.Failure.tooLarge(limit: attachmentLimit).localizedDescription; return false
        }
        isSending = true
        defer { isSending = false }
        let account = accountID
        let id = UUID().uuidString
        if isDemo {
            let attachment = StoredAttachment(name: prepared.name, mediaType: prepared.mediaType, size: prepared.data.count, width: prepared.width,
                                              height: prepared.height, hash: Data.sha256(prepared.data).hexString, secret: Data([0]))
            do {
                try files.write(prepared.data, to: files.cacheURL(attachment, messageID: id))
                try await store.insertMessage(StoredMessage(id: id, accountID: account, chatID: chatID, senderID: account, body: "", isOutgoing: true, reply: reply, attachment: attachment))
                await refresh()
                return true
            } catch { self.error = "Could not save the file."; return false }
        }
        guard let encryption else { return false }
        do {
            try await OutgoingEnqueue.file(prepared, id: id, account: account, chatID: chatID, reply: reply, limit: attachmentLimit,
                                           store: store, files: files, encryption: encryption)
            await refresh()
            startUploads()
            donateSend(to: chatID)
            return true
        } catch {
            if accountID == account { self.error = (error as? LocalizedError)?.errorDescription ?? "Could not save the file." }
            return false
        }
    }

    // A pass reads the pending files once, so a call while one runs asks for another pass when it ends.
    private func startUploads() { uploadPasses.request() }

    private func uploadPass() -> (@MainActor () async -> Void)? {
        guard session.isReady, hasTransportOwnership, transportWanted, !quiescing,
              let client, let store, let uploader, let service = uploadService, let files else { return nil }
        let account = accountID, token = generation
        return { [weak self] in
            guard let pending = try? await store.attachmentsAwaitingUpload(accountID: account) else { return }
            for message in pending where message.attachment?.uploadTaskID == nil {
                guard let attachment = message.attachment, self?.generation == token else { return }
                if self?.uploadFailures.isWaiting(message.id) == true { continue }
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
                    if self?.accountID == account, let host = slot.get.host()?.lowercased() { self?.noteLinkPreviewHosts([host]) }
                } catch {
                    // A dropped connection is not the server refusing; the reconnect starts uploads again.
                    let dropped = error is CancellationError || [XMPPClientError.notConnected, .connectionClosed].contains { $0 == error as? XMPPClientError }
                    guard let self, self.generation == token, !dropped else { continue }
                    await self.uploadFailed(message, account: account)
                }
            }
        }
    }

    // At the failure budget the file is failed, so it shows Not sent with Retry and stops holding back what was queued
    // after it.
    private func uploadFailed(_ message: StoredMessage, account: String) async {
        guard let store, accountID == account, let name = message.attachment?.name else { return }
        guard uploadFailures.recordFailure(message.id) else {
            error = "Could not upload \(name). It will be retried."
            Task { [weak self] in
                try? await Task.sleep(for: UploadFailureBudget.backOff)
                self?.startUploads()
            }
            return
        }
        guard (try? await store.failQueuedOutgoing(accountID: account, messageID: message.id)) != nil else { return }
        error = "Could not upload \(name), so it was not sent. Retry it from the message."
        await refresh()
        startOutbox()
    }

    // Tasks the system dropped while we were gone get a fresh slot; running ones are left alone.
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
            await uploadFailed(message, account: accountID)
        }
    }

    // Verified before they exist locally; `downloads` decides which wait for a tap.
    private func loadAttachments(_ storedMessages: [StoredMessage], chat: String) {
        guard let files else { return }
        downloads.load(storedMessages, known: isGroup(chat) || chats.first { $0.id == chat }?.isPinned == true, files: files, account: accountID,
                       onDisk: { attachmentFiles[$0] != nil })
    }

    func attachmentDisplayed(_ messageID: String) {
        guard let files else { return }
        downloads.displayed(messageID, attachment: messages.first { $0.id == messageID }?.attachment, files: files)
    }

    func downloadAttachment(_ messageID: String) {
        guard let files, let message = messages.first(where: { $0.id == messageID }) else { return }
        downloads.request(message, files: files, account: accountID)
    }

    private func resetSession() -> XMPPClient? {
        generation = UUID()
        drainTask?.cancel()
        // Cancelled, not cleared: connect() and quiesceTransport() join the handle.
        setupTask?.cancel()
        // Its transport work counts as an encryption operation, which quiesceTransport waits for; a permission prompt
        // still on screen does not.
        pushTask?.cancel()
        catchUp = nil
        // Cancelled, not cleared: a new connection's walk must never meet an old backfill.
        backfillTask?.cancel()
        backfillingArchive = nil
        opportunisticBackfillDone = false
        archiveWalkFinished = false
        catchUpBanners = .holding
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
            connectPhases.mark(state)
            switch state {
            case .connecting: session = .connecting(step: "Connecting…")
            case .authenticating: session = .connecting(step: "Signing in…")
            case .binding: session = .connecting(step: "Opening session…")
            case .online:
                session = .connected(settingUp: ConnectionSetup.featuresStep)
                let online = ContinuousClock.now
                onlineAt = online
                reconnection.online()
                syncTimings = SyncPhaseTimings()
                firstMessageLogged = false
                liveStoredLogged = false
                catchUpByArchive = [:]
                let resumed = await client?.sessionResumed ?? false
                Self.syncLog.notice("online resumed=\(resumed, privacy: .public)\(self.connectPhases.summary(online: online), privacy: .public)")
                // XEP-0012: the client answers queries to our full address only while the account shares last seen.
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
                    // The live consumer cannot persist anything without encryption state: publish a new account's
                    // identity before setup runs concurrently.
                    session = .connected(settingUp: ConnectionSetup.keysStep)
                    do { try await encryption.initialize(account: account, transport: client) }
                    catch {
                        guard generation == token else { return }
                        await reportSetupFailure(step: ConnectionSetup.keysStep, detail: ConnectionSetup.detail(error), client: client, token: token)
                        return
                    }
                    guard generation == token else { return }
                }
                // The event loop keeps persisting and acknowledging live stanzas while setup runs; OMEMO's operation
                // gate serialises the two per crypto operation.
                setupTask = Task { [weak self] in
                    guard let self else { return }
                    await self.runConnectionSetup(account: account, client: client, encryption: encryption, store: store,
                                                  identityExists: identityExists, resumed: resumed, token: token)
                    if self.generation == token { self.setupTask = nil }
                }
            case .disconnected(let reason):
                Self.syncLog.notice("disconnected: \(reason ?? "closed", privacy: .public)")
                // Its client calls fail with the connection anyway; cancelling makes the exit prompt.
                setupTask?.cancel()
                catchUp = nil
                backfillTask?.cancel()
                archiveWalkFinished = false
                catchUpBanners = .holding
                for room in groupChats.keys { groupChats[room]?.joined = false }
                resetTyping()
                resetPresence()
                drainTask?.cancel()
                if case .needsAttention = session {} else { session = .offline(reason: reason) }
                reconnection.ended()
                reconcile()
            }
        case .chatState(let update):
            // A chat state never creates a chat, and never shows for a blocked one.
            guard chats.contains(where: { $0.id == update.chat }), !isBlocked(update.chat) else { return }
            typingTracker.apply(update.state, chat: update.chat, participant: update.participant ?? update.chat, settles: update.ridesOnMessage, now: .now)
            publishTyping()
        case .reaction, .retraction, .receipt, .encryptedMessage, .encryptedGroupMessage, .streamManagementBarrier, .displayedSync, .messageError:
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
            if case .messageError(let bounce) = event { rejoinAfterBounce(bounce, token: token) }
            do {
                let outcome = try await inbound.process(event)
                guard generation == token else { return }
                // An XEP-0490 item older than our pointer leaves our newer state pending: answer it.
                if case .displayedSync = event { publishReadState() }
                switch outcome {
                case .stored:
                    await flushEncryptionControls(account: account, client: client)
                    guard generation == token else { return }
                    refreshSoon()
                case .retained(let problem):
                    // The ciphertext is kept; the chat-list load marks its chat for review.
                    encryptionAttention.note(problem)
                    await refresh()
                    guard generation == token else { return }
                    if let openChatID { await loadEncryptionDetails(for: openChatID, refreshFromServer: false) }
                case .excluded(let reason):
                    // Not content, not review: the placeholder row is the record.
                    encryptionAttention.note(reason == .notForThisDevice
                        ? "A message from another device was not encrypted for this \(ThisDevice.noun); it is shown as a placeholder."
                        : "An encrypted message could not be read; it is shown as a placeholder.")
                    refreshSoon()
                case .rejected(let rejected):
                    guard rejected.messageID != nil else { refreshSoon(); break }
                    await refresh()
                    // Only where it can be seen: iOS in front; a Mac with a window on screen.
                    guard generation == token, Self.attention.showsDeliveryAlert(lifecycle) else { return }
                    let name = chats.first { $0.id == rejected.chatID }?.displayTitle ?? AppModel.displayName(for: rejected.chatID, title: nil)
                    self.error = "A message to \(name) wasn't delivered. \(RejectionCopy.reason(rejected.rejection, isGroup: isGroup(rejected.chatID))) You can retry it from the message."
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
                ownDevicePasses.request()
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
            // Re-fetch through the one lazy path so the hash check applies.
            avatarChecked.remove(owner)
            if owner == account || chats.contains(where: { $0.id == owner }) { await loadAvatar(for: owner) }
        case .encryptionFailure:
            encryptionAttention.note("An encrypted message could not be opened")
        case .contactPresence(let presence):
            guard !isDemo, lastSeenTracker.apply(presence, account: account, isContact: !isGroup(presence.contact), now: .now),
                  presence.contact == openChatID else { return }
            syncOpenChatLastSeen()
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
            // While the account does not share last seen, every presence subscription in the roster is revoked on each
            // connection, so a switch turned off offline or elsewhere takes effect.
            if !accountPreferences.lastSeen { await revokePresenceSharing(items.filter { $0.subscription == .from || $0.subscription == .both }.map(\.jid), token: token) }
            guard generation == token, let openChatID, replacesAll || items.contains(where: { $0.jid == openChatID }) else { return }
            requestLastSeen(for: openChatID)
        case .blocklist(let change):
            guard !isDemo else { return }
            applyBlocklist(change, account: account)
        case .streamAcknowledged:
            refreshSoon()
        case .message:
            // Encrypted conversations do not render unauthenticated plaintext injected by a peer or server as though it
            // had passed OMEMO authentication.
            encryptionAttention.note("An unencrypted message was blocked")

        }
    }

    func isGroup(_ chatID: String) -> Bool { groupChats[chatID] != nil }

    // Once per session: XEP-0084 metadata, bytes only when the hash changed, vCard when PEP has nothing. Bytes are
    // hash-verified and decoded within a pixel budget before anything shows.
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
                // No PEP node, no PEP, or a presence-gated node: the XEP-0153 vCard (servers mirror PEP avatars,
                // XEP-0398) is the one place left.
                if let photo = try await client.fetchVCardPhoto(for: chatID) {
                    hash = photo.id
                    if photo.id != stored { fetched = (photo.id, photo.data) }
                }
            }
            guard generation == token, accountID == account else { return }
            if let fetched {
                try AvatarStore.save(fetched.data, root: storageRoot, account: account, hash: fetched.hash)
                if let image = AvatarStore.image(root: storageRoot, account: account, hash: fetched.hash) {
                    avatars[chatID] = PlatformImage(cgImage: image)
                    // Pre-scaled here, so the notification extension never decodes an image.
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

    // A user-chosen link photo (`ContactLink.avatarHash`) comes first, the extension's rule too.
    func avatar(for chatID: String) -> PlatformImage? {
        guard let photo = contactLinks.photos[chatID] else { return avatars[chatID] }
        return contactLinks.links[chatID]?.usesContactPhoto == true ? photo : avatars[chatID] ?? photo
    }

    func verifiedAvatarData(for chatID: String) -> Data? {
        guard let storageRoot, let hash = chats.first(where: { $0.id == chatID })?.avatarHash else { return nil }
        return AvatarStore.notificationImageData(root: storageRoot, account: accountID, hash: hash)
    }

    func chatName(for chatID: String) -> String {
        chats.first { $0.id == chatID }?.displayTitle ?? AppModel.displayName(for: chatID, title: contactLinks.links[chatID]?.name)
    }

    private func applyContactNames() {
        let renamed = chats.map { chat in
            var chat = chat
            chat.contactName = contactLinks.links[chat.id]?.name
            return chat
        }
        if renamed.map(\.contactName) != chats.map(\.contactName) { chats = renamed }
    }

    private func loadStoredAvatars(_ stored: [StoredChat]) {
        guard let storageRoot else { return }
        let account = accountID
        var wanted = stored.compactMap { chat in chat.avatarHash.map { (chat.id, $0) } }
        if let own = preferences.string(forKey: "avatar.\(account)") { wanted.append((account, own)) }
        for (id, hash) in wanted where avatars[id] == nil {
            avatars[id] = AvatarStore.image(root: storageRoot, account: account, hash: hash).map { PlatformImage(cgImage: $0) }
            if avatars[id] != nil { AvatarStore.saveNotificationImage(root: storageRoot, account: account, hash: hash) }
        }
    }
    func canSend(to chatID: String) -> Bool {
        guard isGroup(chatID) else { return true }
        return isConnected && encryptionReady && groupChats[chatID]?.joined == true
    }

    func joinGroup(room: String, nickname: String) async -> String? {
        guard hasTransportOwnership, transportWanted, !quiescing, isConnected, encryptionReady,
              let client, let encryption, let store else { error = "Connect before joining a group."; return nil }
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
            guard generation == token, transportWanted, !quiescing else { return nil }
            groupChats[room] = GroupChatState(members: overview.room.members, devices: overview.devices)
            // Before the join, so the self-presence that admits us finds it.
            if let boundary = await roomJoinBoundary(room, client: client, store: store, token: token) {
                joinBoundaries[room] = (token, boundary)
            }
            guard generation == token, transportWanted, !quiescing else { return nil }
            _ = try await client.joinGroupRoom(room, nickname: nickname)
            let confirmed = try await client.groupRoomSnapshot(room)
            guard generation == token, transportWanted, !quiescing else { return nil }
            preferences.set(nickname, forKey: "groupNickname.\(account).\(room)")
            groupChats[room]?.joined = confirmed?.joined == true
            try await store.upsertChat(accountID: account, chatID: room, title: String(room.prefix { $0 != "@" }))
            try await store.setGroupNickname(accountID: account, room: room, nickname: nickname)
            guard generation == token else { return nil }
            await refresh()
            return room
        } catch {
            if generation == token { self.error = groupFailure(error) }
            return nil
        }
    }

    // Every operation runs inside the setup task under the generation fence; none spawns an unstructured task.
    private func runConnectionSetup(account: String, client: XMPPClient, encryption: OMEMOService, store: MessageStore,
                                    identityExists: Bool, resumed: Bool, token: UUID) async {
        let profiles = serverProfiles
        let streamID: @Sendable () async -> String? = {
            try? await StreamPersistence(store: store, accountID: account, encryption: encryption).load()?.streamID
        }
        let memory = profiles.memory(account: account, stream: resumed ? await streamID() : nil,
                                     uploadsFresh: uploads.isFresh(account: account))
        let setup = ConnectionSetup(identityExists: identityExists, resumed: resumed, memory: memory)
        // The stream ID is a store read; a newer connection may have started meanwhile.
        guard setupIsCurrent(token) else { return }
        if resumed {
            Self.syncLog.notice("resume reuses features=\(setup.skipsFeatures, privacy: .public) carbons=\(setup.skipsCarbons, privacy: .public) uploads=\(setup.skipsUploads, privacy: .public)")
        }
        uploadReconciliation.setupStarted(discovers: !setup.skipsUploads)
        let operations = ConnectionSetup.Operations(
            features: { [domain = accountDomain] in
                let found = try await ConnectionSetup.discoverFeatures(server: { try await client.discoveryFeatures(for: domain) },
                                                                       account: { try await client.discoveryFeatures() })
                if found.complete { profiles.discovered(found.features, account: account) }
                return found.features
            },
            enableCarbons: {
                try await client.setCarbonsEnabled()
                profiles.carbonsEnabled(account: account, stream: await streamID())
            },
            discoverUploads: { [weak self] in
                // Optional XEP-0363. Only a completed answer changes what the attach button remembers; a discovery that
                // throws keeps the last one.
                let discovery: Result<XMPPUploadService?, any Error>
                do { discovery = .success(try await client.uploadService()) } catch { discovery = .failure(error) }
                await self?.settleUploadDiscovery(discovery, account: account, token: token)
            },
            initializeEncryption: { try await encryption.initialize(account: account, transport: client) },
            rejoinGroups: { [weak self] in
                guard let self else { throw CancellationError() }
                try await self.rejoinKnownGroups(account: account, client: client, encryption: encryption, token: token)
                // `.ready` started the outbox before the rooms were joined; group messages queued offline need a joined
                // room.
                await self.startOutbox()
            },
            catchUp: { progress in
                let outcome = try await ArchiveSynchronizer(store: store).synchronize(account: account, client: client, encryption: encryption) {
                    await progress(CatchUpProgress(archive: $0.archive, pages: $0.pages, messages: $0.messages))
                }
                // A refused or unanswered archive query keeps the connection; that archive's checkpoint stands and the
                // next connection walks it again.
                if !outcome.isComplete {
                    Logger(subsystem: "haus.xmpp.ios", category: "sync").notice("catch-up incomplete: own=\(outcome.ownArchiveComplete, privacy: .public) rooms=\(outcome.unfinishedRooms.count, privacy: .public)")
                }
            },
            retryPending: { try? await encryption.retryPendingIncoming(account: account, transport: client) })
        let timings = syncTimings
        await setup.run(operations: operations.timed(by: timings)) { [weak self] event in
            await self?.applySetupEvent(event, account: account, client: client, token: token)
        }
        if setupIsCurrent(token) {
            Self.syncLog.notice("setup finished +\(self.syncElapsed(), privacy: .public) ms \(timings.summary([.features, .carbons, .uploads, .keys, .rejoin, .walk, .retry]), privacy: .public)")
        }
    }

    // `.ready` reconciles stranded uploads only against a known answer; a later completed discovery reconciles them
    // when nothing was stored or when it withdraws the stored service.
    private func settleUploadDiscovery(_ discovery: Result<XMPPUploadService?, any Error>, account: String, token: UUID) async {
        guard generation == token else { return }
        let previous = uploadService
        uploadService = uploads.settle(account: account, previous: previous, discovery: discovery)
        if case .failure(let error) = discovery { Self.syncLog.notice("upload discovery kept the stored service: \(ConnectionSetup.detail(error), privacy: .public)") }
        guard uploadReconciliation.discoverySettled(discovery, previous: previous, ready: session.isReady) else { return }
        await reconcileUploads()
    }

    // `.disconnected` cancels the setup task without changing the generation, so the generation alone would let a late
    // `.step` or `.ready` overwrite the offline state and stop the reconciler.
    private func setupIsCurrent(_ token: UUID) -> Bool { generation == token && !Task.isCancelled }

    private func applySetupEvent(_ event: ConnectionSetup.Event, account: String, client: XMPPClient, token: UUID) async {
        // Runs in the setup child's task on the main actor, so a `.disconnected` handled before this job already
        // cancelled it.
        guard setupIsCurrent(token) else { return }
        reconnection.observe(event)
        switch event {
        case .step(let step):
            if !session.isReady { session = .connected(settingUp: step) }
        case .ready:
            session = .ready
            Self.syncLog.notice("ready +\(self.syncElapsed(), privacy: .public) ms")
            // Roster pushes are answered only after a fetch on this stream; the `.rosterItems` event revokes and asks.
            try? await client.fetchRoster()
            guard setupIsCurrent(token) else { return }
            await flushEncryptionControls(account: account, client: client, logsLiveStore: false)
            await refresh()
            guard setupIsCurrent(token) else { return }
            startOutbox()
            // After the outbox started, so a server slow to answer cannot hold back sending.
            await refreshBlocklist(account: account, client: client)
            guard setupIsCurrent(token) else { return }
            if uploadReconciliation.reconcilesAtReady(stored: uploadService) { await reconcileUploads() }
            if let openChatID { await loadEncryptionDetails(for: openChatID) }
            // Another client may have signed in while this one was away.
            ownDevicePasses.request()
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
                let elapsed = syncElapsed(), rate = elapsed > 0 ? messages * 1000 / elapsed : 0
                Self.syncLog.notice("catch-up finished +\(elapsed, privacy: .public) ms pages=\(pages, privacy: .public) messages=\(messages, privacy: .public) entries_per_s=\(rate, privacy: .public) \(self.syncTimings.summary([.reload, .notify]), privacy: .public)")
                archiveWalkFinished = true
                requestOpportunisticBackfill()
                // XEP-0490 after the walk, so the ids other devices published name messages we hold.
                syncReadState(account: account, client: client, token: token)
            }
        case .degraded(let step, let detail):
            Self.syncLog.notice("setup went on without \(step, privacy: .public): \(detail, privacy: .public)")
        case .settled:
            Self.syncLog.notice("settled +\(self.syncElapsed(), privacy: .public) ms")
            // A server without an archive: nothing more to catch up on. After a walk the read-state sync releases them.
            if !archiveWalkFinished { releaseCatchUpBanners() }
        case .failed(let step, let detail):
            catchUp = nil
            if step == ConnectionSetup.archiveStep { Self.syncLog.notice("catch-up failed +\(self.syncElapsed(), privacy: .public) ms") }
            await reportSetupFailure(step: step, detail: detail, client: client, token: token)
        }
    }

    // A half-alive session is a connection failure: end it and let the reconciler retry.
    private func reportSetupFailure(step: String, detail: String, client: XMPPClient, token: UUID) async {
        let wasReady = session.isReady
        Logger(subsystem: "haus.xmpp.ios", category: "encryption").error("Encryption setup failed at \(step, privacy: .public): \(detail, privacy: .public)")
        session = .needsAttention(step: step, detail: detail)
        encryptionAttention.note("Setup failed at \(step): \(detail)")
        if reconnection.shouldAlert(detail) {
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
        // However the pass ends, a room that bounced meanwhile is rejoined here unless the pass just sent it a join.
        var joined = Set<String>()
        defer { if setupIsCurrent(token) { groupRejoinsFinished = token; rejoinRoomsThatBouncedDuringSetup(token: token, joinedByPass: joined) } }
        let rooms = try await encryption.knownGroupRooms(account: account)
        for (room, members) in rooms.sorted(by: { $0.key < $1.key }) {
            guard setupIsCurrent(token), transportWanted, !quiescing else { throw CancellationError() }
            // Keep the cached devices (and a past join failure) across the rejoin; only the transport state restarts.
            groupChats[room, default: GroupChatState()].members = members
            let nickname = preferences.string(forKey: "groupNickname.\(account).\(room)") ?? String(account.prefix { $0 != "@" })
            // Mention detection is best effort.
            try? await store?.setGroupNickname(accountID: account, room: room, nickname: nickname)
            do {
                let snapshot = try await client.joinGroupRoom(room, nickname: nickname)
                guard setupIsCurrent(token) else { throw CancellationError() }
                joined.insert(room)
                groupChats[room]?.joined = snapshot.joined
            } catch {
                guard setupIsCurrent(token) else { throw CancellationError() }
                groupChats[room]?.issue = groupFailure(error)
                // No send is allowed until this room's own authenticated presence is received. Archive synchronization
                // separately fails closed if room provenance is unavailable.
            }
        }
    }

    // One rejoin per room and connection for a non-occupant bounce. Before setup's own rejoin pass ends, a second join
    // would race it (a resumed stream delivers queued bounces right after `.online`), so the bounce is only noted.
    private func rejoinAfterBounce(_ bounce: XMPPMessageError, token: UUID) {
        let room = bounce.from
        guard bounce.meansNotInRoom, groupChats[room] != nil, bounceRejoins[room] != token else { return }
        guard groupRejoinsFinished == token else {
            Self.syncLog.notice("room bounce during setup: rejoin after its pass if still needed")
            deferredBounceRejoins[room] = token; return
        }
        rejoinBouncedRoom(room, token: token)
    }

    private func rejoinRoomsThatBouncedDuringSetup(token: UUID, joinedByPass: Set<String>) {
        let rooms = deferredBounceRejoins.filter { $0.value == token }.keys.sorted()
        deferredBounceRejoins = [:]
        // The pass's join answers the bounce; its self-presence may still be on its way, so `joined` cannot tell.
        let needed = rooms.filter { !joinedByPass.contains($0) && groupChats[$0]?.joined != true && bounceRejoins[$0] != token }
        if !rooms.isEmpty { Self.syncLog.notice("rooms that bounced during setup: \(rooms.count, privacy: .public), left to rejoin: \(needed.count, privacy: .public)") }
        for room in needed { rejoinBouncedRoom(room, token: token) }
    }

    private func rejoinBouncedRoom(_ room: String, token: UUID) {
        let account = accountID
        guard generation == token, groupChats[room] != nil, let client, transportWanted, !quiescing else { return }
        Self.syncLog.notice("rejoining a room that bounced a stanza")
        bounceRejoins[room] = token
        let nickname = preferences.string(forKey: "groupNickname.\(account).\(room)") ?? String(account.prefix { $0 != "@" })
        Task { [weak self] in
            // A disconnect, sign-out or background transition since the bounce: that connection is done with.
            guard let self, self.generation == token, self.transportWanted, !self.quiescing else { return }
            do { _ = try await client.joinGroupRoom(room, nickname: nickname) }
            catch {
                guard self.generation == token else { return }
                self.groupChats[room]?.issue = self.groupFailure(error)
            }
        }
    }

    private func updateGroupPresence(_ room: String, token: UUID) async {
        guard groupChats[room] != nil, let client else { return }
        do {
            let value = try await client.groupRoomSnapshot(room)
            guard generation == token else { return }
            if value?.joined == true { await recordJoinBoundary(room, token: token) }
            else if await client.groupRoomRefusedJoin(room) { joinBoundaries[room] = nil }
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

    // nil when the room was walked already or there is no boundary: its first walk then takes everything as history.
    // The connection's walk holds the single archive query, so a room joined during catch-up gets no boundary.
    private func roomJoinBoundary(_ room: String, client: XMPPClient, store: MessageStore, token: UUID) async -> Date? {
        guard (try? await store.archiveCheckpoint(accountID: accountID, archiveID: room)) == nil else { return nil }
        while let backfill = backfillTask {
            await backfill.value
            guard generation == token else { return nil }
        }
        guard archiveWalkFinished, catchUp == nil else {
            Self.syncLog.notice("room join boundary skipped: this connection's archive walk has not finished")
            return nil
        }
        joinBoundaryQueries += 1
        defer { joinBoundaryQueries -= 1 }
        do { return try await ArchiveSynchronizer(store: store).roomJoinBoundary(room: room, client: client) }
        catch {
            Self.syncLog.notice("room join boundary unavailable: \(ConnectionSetup.detail(error), privacy: .public)")
            return nil
        }
    }

    private func recordJoinBoundary(_ room: String, token: UUID) async {
        guard let boundary = joinBoundaries[room], boundary.token == token, let store else { return }
        joinBoundaries[room] = nil
        do {
            try await store.recordJoinedRoom(accountID: accountID, room: room, historyThrough: boundary.historyThrough)
            Self.syncLog.notice("room join boundary recorded\(boundary.historyThrough == .distantPast ? " (empty archive)" : "", privacy: .public)")
        } catch { Self.syncLog.error("room join boundary not saved: \(ConnectionSetup.detail(error), privacy: .public)") }
    }

    // The pill follows the cached devices; joining only gates sending. `force: false` reuses this connection's refresh.
    // A failed refresh writes the diagnostics footer only.
    func loadGroupDetails(room: String, refreshFromServer: Bool = true, force: Bool = true) async {
        guard transportWanted, !quiescing, let encryption, isGroup(room), !isDemo else { return }
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
        if let identity = try? await encryption.localIdentity(account: account, profile: .modern), generation == token, accountID == account {
            groupChats[room]?.localDeviceID = identity.deviceID
            groupChats[room]?.localFingerprint = identity.fingerprint
        }
        guard refreshFromServer, force || refreshFence[room]?.generation != token,
              hasTransportOwnership, isConnected, encryptionReady, let client else { return }
        do {
            let overview = try await encryption.refreshGroupDevices(account: account, room: room, transport: client)
            // Device refresh persists policy after its room snapshot. Own presence may change during those awaits;
            // display the transport's current join state.
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

    func createChat(_ recipient: String) async -> String? {
        // `Bob@Example.org` is the chat the server's `bob@example.org` replies land in.
        let address = JID(recipient.trimmingCharacters(in: .whitespacesAndNewlines))
        guard !accountID.isEmpty, let address, address.localpart != nil, address.resourcepart == nil, let store else {
            error = "Enter a contact address such as name@example.org."
            return nil
        }
        let recipient = address.bare
        guard isDemo || !isLabAccount || recipient.hasSuffix("@" + accountDomain) else {
            error = "Lab accounts only message other accounts on the same lab server."
            return nil
        }
        do {
            try await store.createChatIfMissing(accountID: accountID, chatID: recipient, title: recipient)
            await refresh()
            return recipient
        } catch { self.error = "Could not create conversation."; return nil }
    }

    // Stored with the message so every retry seals the same bytes. Only modern OMEMO carries it, inside the SCE
    // content; a legacy seal clears it.
    func send(_ body: String, to chatID: String, replyingTo source: ChatMessage? = nil, linkPreview: StoredLinkPreview? = nil) async -> Bool {
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
        let id = UUID().uuidString, reply = source.map { replySnapshot(of: $0, in: chatID) }
        if let problem = XMPPClient.messageProblem(to: chatID, body: body, id: id, reply: Self.wireReply(reply)) {
            self.error = Self.sendFailure(problem)
            return false
        }
        guard var message = try? OutgoingEnqueue.textMessage(body, id: id, account: account, chatID: chatID, reply: reply,
                                                             linkPreview: Self.acceptedOwnLinkPreview(linkPreview, body: body, uploadHosts: linkPreviewUploadHosts))
        else { return false }
        do {
            if sample {
                message.encryptionProfile = nil
                try await store.insertMessage(message)
            } else { try await store.enqueueOutgoing(message) }
            await refresh()
            startOutbox()
            if !sample { donateSend(to: chatID) }
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

    // Stored so a restart or a queued retry sends the same words.
    private func replySnapshot(of source: ChatMessage, in chatID: String) -> MessageReply {
        MessageReply(messageID: source.id, senderID: source.senderID, body: source.quoteText,
                     wireID: Self.replyWireID(of: source, isGroup: isGroup(chatID)), mediaType: source.attachment?.mediaType)
    }

    // Only our own sent direct message has an ID we know the peer holds.
    nonisolated static func replyWireID(of source: ChatMessage, isGroup: Bool) -> String? {
        !isGroup && source.isOutgoing && source.transportState != nil ? source.id : nil
    }

    // A file's body must stay exactly its link, so the reply can only be the XEP-0461 reference without a quote: that
    // needs an own sent direct message to name and a modern OMEMO envelope (legacy would put it in clear).
    func canReplyWithFilesAlone(to source: ChatMessage, in chatID: String) -> Bool {
        Self.filesAloneCanReply(to: source, accountID: accountID, chatID: chatID, isGroup: isGroup(chatID), isDemo: isDemo,
                                chatProfile: encryptionOverviewChatID == chatID ? encryptionOverview?.profile : nil)
    }

    nonisolated static func filesAloneCanReply(to source: ChatMessage, accountID: String, chatID: String, isGroup: Bool,
                                               isDemo: Bool, chatProfile: XMPPOMEMOProfile?) -> Bool {
        guard source.accountID == accountID, source.chatID == chatID, !isGroup, source.isOutgoing else { return false }
        if isDemo { return true }
        return replyWireID(of: source, isGroup: isGroup) != nil && chatProfile == .modern
    }

    nonisolated static func sendFailure(_ problem: XMPPClient.MessageProblem) -> String {
        switch problem {
        case .emptyQuote: "The message you're replying to has nothing to quote. Remove the reply to send your text, which is still in the composer."
        case .quoteTooLong: "The message you're replying to is too long to quote. Remove the reply to send your text, which is still in the composer."
        case .quoteUnsupportedCharacters: "The message you're replying to contains characters that can't be quoted. Remove the reply to send your text, which is still in the composer."
        case .combinedTooLong: "Your text and the quoted message are too long together. Shorten your text or remove the reply; your text is still in the composer."
        case .bodyTooLong: "This message is too long. Your text is still in the composer."
        case .bodyUnsupportedCharacters: "This message contains characters that can't be sent. Your text is still in the composer."
        case .emptyBody, .invalidAddressing: "This message can't be sent to this chat. Your text is still in the composer."
        }
    }

    func canReact(to message: StoredMessage) -> Bool {
        #if DEBUG
        if isDemo, Self.demoReactions {
            return message.accountID == accountID && message.chatID == openChatID && message.wireID != nil && message.unreadableReason == nil
        }
        #endif
        guard message.accountID == accountID, message.chatID == openChatID,
              message.encryptionProfile == "modern" || message.encryptionProfile == "legacy" else { return false }
        if isGroup(message.chatID) { return message.encryptionProfile == "modern" && canSend(to: message.chatID) && reactableGroupMessages.contains(message.id) }
        if encryptionOverview?.profile == .modern { return message.wireIDAuthenticated && message.wireID != nil }
        // Legacy peers (Conversations) only speak unencrypted XEP-0444.
        return encryptionOverview?.profile == .legacy && message.wireID != nil
    }

    #if DEBUG
    func recordSampleReceipt(read: Bool, messageID: String) async {
        guard isDemo, let store,
              let message = messages.first(where: { $0.id == messageID }), message.isOutgoing, let wireID = message.wireID else { return }
        try? await store.recordReceipt(accountID: accountID, event: MessageEvent(id: UUID().uuidString, chatID: message.chatID, actorID: message.chatID,
                                                                                targetWireID: wireID, kind: read ? .displayed : .delivered, payload: "{}", updatedAt: Date()))
        await refresh(.openChat)
    }

    // Recorded on this device as a peer's would be and never sent.
    private static let demoReactions = ProcessInfo.processInfo.arguments.contains("-demo-reactions")
    #endif

    func toggleReaction(_ emoji: String, messageID: String) async {
        #if DEBUG
        if isDemo, Self.demoReactions {
            guard let store, let message = messages.first(where: { $0.id == messageID }), canReact(to: message), let wireID = message.wireID else { return }
            let account = accountID
            let mine = messageReactions[messageID]?.first(where: { $0.actorID == account })?.reactions ?? []
            try? await store.recordReaction(accountID: account, reaction: AuthenticatedReaction(id: UUID().uuidString, chatID: message.chatID, actorID: account,
                                                                                                targetWireID: wireID, reactions: mine.contains(emoji) ? [] : [emoji],
                                                                                                updatedAt: Date()))
            await refresh(.openChat)
            return
        }
        #endif
        guard hasTransportOwnership, transportWanted, !quiescing else { return }
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

    func canRevise(_ message: StoredMessage) -> Bool {
        guard message.accountID == accountID, message.chatID == openChatID, message.isOutgoing, !message.isRetracted, message.unreadableReason == nil,
              !isGroup(message.chatID) else { return false }
        if isDemo { return true }
        // Mirrors the direct-chat half of canReact.
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
                guard hasTransportOwnership, transportWanted, !quiescing, let encryption else { return false }
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
        guard hasTransportOwnership, transportWanted, !quiescing, drainTask == nil, session.isReady, !isDemo,
              let client, let outboxSender, let encryption, let store else { return }
        outboxRequested = false
        let joinedGroups = Set(groupChats.filter { $0.value.joined }.map(\.key))
        let account = accountID
        let token = generation
        let activity = BackgroundActivity.burst("Send the outbox")
        drainTask = Task { [weak self] in
            defer { activity?.end() }
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
                    repliesDropped: { [weak self] _ in
                        // The composer let these replies go at Send, and the seal has cleared their quotes.
                        guard let self, self.generation == token else { return }
                        self.error = "This chat switched to an older encryption version, so a file you sent as a reply goes without it. Reply again with a caption to quote the message."
                    },
                    didChange: { [weak self] in await self?.refresh() }))
                if let self, self.generation == token { self.encryptionAttention.settlePass(heldForTrust: heldForTrust) }
                await self?.refresh()
            } catch {
                if let self, self.generation == token {
                    // Not tied to one chat, so it cannot mark one for review; a trust problem shows through the stored
                    // devices re-read below.
                    self.encryptionAttention.note((error as? OMEMOError)?.errorDescription ?? "Encryption could not be prepared. Messages remain saved.")
                    if let chat = self.openChatID { await self.loadEncryptionDetails(for: chat, refreshFromServer: false) }
                }
            }
            guard let self else { return }
            self.drainTask = nil
            self.drainPasses += 1
            // A different account/session may have become ready while this attempt settled.
            if self.outboxRequested || self.generation != token { self.startOutbox() }
            // Catch-up often finishes while the first drain is still running; the deferred history fetch runs here.
            if self.generation == token { self.requestOpportunisticBackfill() }
        }
    }

    // After the archive walk and while no drain runs, so a new install shows more than the newest page without a
    // scroll.
    private func requestOpportunisticBackfill() {
        guard archiveWalkFinished, !opportunisticBackfillDone, transportWanted, !quiescing, drainTask == nil else { return }
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

    func requestRoute(_ route: ChatRoute) { requestedRoute = route }

    private func routeNotification(_ destination: NotificationDestination) async {
        guard testSessionID == nil, !isDemo,
              !ProcessInfo.processInfo.arguments.contains("--inspect-notification"), let store else { return }
        // A tap never prompts for another account, creates a chat or changes endpoints.
        guard let account = authorizedNotificationAccount(),
              let message = try? await destination.resolve(accountID: account, store: store),
              authorizedNotificationAccount() == account else { return }
        notificationRoute = NotificationChatRoute(accountID: account, chatID: message.chatID)
        onNotificationRoute?()
    }

    // Runs before the pushed screen's first frame, while the chat list still shows the same newest message.
    func prepareChat(_ chatID: String) {
        guard openChatID != chatID || messagesLoadedFor != chatID else { return }
        openChatID = chatID; timelineWindow = AppModel.timelinePage; messages = []; messagesLoadedFor = nil; messageReactions = [:]; messageReceipts = [:]; attachmentFiles = [:]
        downloads.reset()
        if let page = timelinePages.page(for: chats.first { $0.id == chatID }, account: accountID) { publishTimeline(page, chat: chatID) }
    }

    func openChat(_ chatID: String) async {
        prepareChat(chatID)
        // A Mac clears them only once the chat is read (`startedReading`).
        let onScreen = Self.attention.clearsNotifications(of: chatID, lifecycle, openChatID: openChatID)
        if !isDemo, onScreen { let account = accountID; Task { await DeliveredNotificationCleaner.removeThread(accountID: account, chatID: chatID) } }
        // Reactions have no read state, so an opened chat clears their alerts. Only under the transport lease: without
        // it an extension run may be posting them, and lease acquisition repeats this
        // (`dismissOpenChatNotifications`).
        if onScreen, transportWanted, hasTransportOwnership, !quiescing, let store {
            let account = accountID
            Task { try? await store.dismissReactionNotifications(accountID: account, chatID: chatID) }
        }
        // Keep the same chat's devices across pop-back and reconnect; another chat starts pending until its store read.
        if encryptionOverviewChatID != chatID { encryptionOverviewChatID = chatID; encryptionOverview = nil }
        encryptionDetailsChatID = chatID
        // First paint without a cached page loads the whole window at once, so the refresh below publishes the same rows.
        let account = accountID
        if messagesLoadedFor != chatID, let store, let page = try? await loadTimeline(store: store, account: account, chat: chatID, isGroup: isGroup(chatID), limit: timelineWindow),
           accountID == account, openChatID == chatID, messagesLoadedFor != chatID { publishTimeline(page, chat: chatID) }
        await refresh()
        syncOpenChatLastSeen()
        if openChatID == chatID { requestLastSeen(for: chatID) }
        if !isDemo { await loadEncryptionDetails(for: chatID) }
    }

    // Stored devices publish at once, offline too; the server fetch runs at most once per connection unless forced or
    // switching versions. A failed fetch writes the diagnostics footer only; stored trust keeps deciding the pill.
    func loadEncryptionDetails(for chatID: String, refreshFromServer: Bool = true, profile: XMPPOMEMOProfile? = nil, force: Bool = false) async {
        guard transportWanted, !quiescing else { return }
        activeEncryptionOperations += 1
        defer { activeEncryptionOperations -= 1 }
        guard let encryption, !isDemo else { return }
        if isGroup(chatID) { await loadGroupDetails(room: chatID, refreshFromServer: refreshFromServer, force: force); return }
        let account = accountID
        let token = generation
        // The pushed details pages cover the conversation, which clears openChatID; the latest request is the fence.
        encryptionDetailsChatID = chatID
        var isCurrent: Bool { accountID == account && generation == token && encryptionDetailsChatID == chatID }
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

    static let storedDevicesUnreadable = "No stored devices yet. They appear after this account connects."

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

    func encryptionOverview(for chatID: String) -> EncryptionOverview? {
        encryptionOverviewChatID == chatID ? encryptionOverview : nil
    }

    // A device of the other version that only held incoming messages leaves the overview once decided, so a review
    // listing it keeps the returned outcome itself.
    @discardableResult
    func setDeviceTrust(_ device: EncryptionDevice, trust: DeviceTrust, chatID: String) async -> Bool {
        guard hasTransportOwnership, transportWanted, !quiescing else { return false }
        activeEncryptionOperations += 1
        defer { activeEncryptionOperations -= 1 }
        guard let encryption else { return false }
        let account = accountID
        let token = generation
        do {
            try await encryption.setTrust(account: account, deviceID: device.id, trust: trust)
        } catch {
            if generation == token { self.error = "This device changed. Refresh its fingerprint before reviewing it again." }
            return false
        }
        guard generation == token else { return true }
        encryptionAttention.trustDecided(in: chatID)
        // A group re-fetches too: its recipients are re-validated against the room.
        await loadEncryptionDetails(for: chatID, refreshFromServer: isGroup(chatID), force: isGroup(chatID))
        guard generation == token else { return true }
        if let client, isConnected {
            // A trust decision can only unblock rows that waited for trust; keys-pending rows wait for device lists.
            try? await encryption.retryPendingIncoming(account: account, transport: client, reasons: [.trustPending])
            guard generation == token else { return true }
            // Released messages leave the retained rows: the other version's waiting devices go with them.
            if !isGroup(chatID) { await loadEncryptionDetails(for: chatID, refreshFromServer: false) }
            await flushEncryptionControls(account: account, client: client)
            await refresh()
            startOutbox()
        }
        return true
    }

    func repairDeviceSession(_ device: EncryptionDevice, chatID: String) async {
        guard hasTransportOwnership, transportWanted, !quiescing else { return }
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
        guard hasTransportOwnership, transportWanted, !quiescing else { return }
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

    private func ownDevicePass() -> (@MainActor () async -> Void)? {
        guard transportWanted, !quiescing, hasTransportOwnership, session.isReady, !isDemo, let client, let encryption else { return nil }
        let account = accountID, token = generation
        return { [weak self] in
            guard let self, self.transportWanted, !self.quiescing, self.generation == token else { return }
            self.activeEncryptionOperations += 1
            defer { self.activeEncryptionOperations -= 1 }
            do {
                let devices = try await encryption.refreshOwnDevices(account: account, transport: client)
                guard self.generation == token, self.accountID == account else { return }
                self.ownDevices = devices
            } catch {
                // The stored devices keep deciding the review; the next connection or device-list change asks again.
                Logger(subsystem: "haus.xmpp.ios", category: "encryption").error("Own device refresh failed: \(String(describing: error).prefix(80), privacy: .public)")
            }
        }
    }

    // Every OMEMO version's record carrying the reviewed fingerprint gets `trust`, which every chat reads.
    func decideOwnDevice(_ candidate: OwnDeviceCandidate, trust: DeviceTrust) async {
        if isDemo {
            changeSampleOwnDevices(candidate) { $0.trust = trust }
            return
        }
        guard hasTransportOwnership, transportWanted, !quiescing else { return }
        activeEncryptionOperations += 1
        defer { activeEncryptionOperations -= 1 }
        guard let encryption else { return }
        let account = accountID, token = generation
        do {
            try await encryption.setTrust(account: account, deviceIDs: candidate.records.map(\.id), trust: trust)
            guard generation == token else { return }
            await ownDeviceChanged(encryption, account: account, token: token)
        } catch {
            guard generation == token else { return }
            let failure = error as? OMEMOError
            // setTrust saves all of the device's records or none of them.
            self.error = failure == .identityChanged ? "This device changed. Review its new fingerprint."
                : failure?.errorDescription ?? "Could not save this decision. Nothing was changed."
            await refresh()
        }
    }

    // `retireOwnDevice` checks the fingerprint, removes the device from both versions' advertised lists and stores it
    // rejected and inactive. The service refuses this installation's own device.
    func removeOwnDevice(_ candidate: OwnDeviceCandidate) async {
        if isDemo {
            changeSampleOwnDevices(candidate) { $0.trust = .rejected; $0.active = false }
            return
        }
        guard hasTransportOwnership, transportWanted, !quiescing, let record = candidate.records.first else { return }
        activeEncryptionOperations += 1
        defer { activeEncryptionOperations -= 1 }
        guard let encryption, let client, isConnected else {
            error = "Connect to your server to remove this device."
            return
        }
        let account = accountID, token = generation
        do {
            try await encryption.retireOwnDevice(account: account, deviceID: record.id, transport: client)
            guard generation == token else { return }
            await ownDeviceChanged(encryption, account: account, token: token)
        } catch {
            guard generation == token else { return }
            let failure = error as? OMEMOError
            self.error = failure == .identityChanged ? "This device changed. Review its new fingerprint."
                : failure?.errorDescription ?? "Could not remove this device. Try again."
            await refresh()
        }
    }

    private func ownDeviceChanged(_ encryption: OMEMOService, account: String, token: UUID) async {
        // Any chat may have been held for this device: clear every mark; the next outbox pass re-marks those still held.
        encryptionAttention.trustDecidedForAccount()
        if let chat = encryptionOverviewChatID { await loadEncryptionDetails(for: chat, refreshFromServer: false) }
        for room in groupChats.keys where room != encryptionOverviewChatID {
            await loadGroupDetails(room: room, refreshFromServer: false)
        }
        guard generation == token else { return }
        if let client, isConnected {
            try? await encryption.retryPendingIncoming(account: account, transport: client, reasons: [.trustPending])
            guard generation == token else { return }
            await flushEncryptionControls(account: account, client: client)
        }
        await refresh()
    }

    private func changeSampleOwnDevices(_ candidate: OwnDeviceCandidate, _ change: (inout EncryptionDevice) -> Void) {
        let ids = Set(candidate.records.map(\.id))
        ownDevices = ownDevices.map { device in
            guard ids.contains(device.id) else { return device }
            var changed = device
            change(&changed)
            return changed
        }
    }
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

    // A full window means the store may hold more; otherwise the server's older archive pages are next. Returns false
    // at the window ceiling or when the archive has no more (or cannot be read from here).
    @discardableResult
    func loadOlderMessages(all: Bool = false) async -> Bool {
        guard let chat = openChatID else { return false }
        guard !loadingOlder else { return true }
        if all || messages.count >= timelineWindow {
            guard timelineWindow < AppModel.timelineCeiling else { return false }
            loadingOlder = true
            defer { loadingOlder = false }
            timelineWindow = all ? AppModel.timelineCeiling : min(AppModel.timelineCeiling, timelineWindow + AppModel.timelinePage)
            await refresh(.openChat)
            return true
        }
        // The window is not raised here: each committed page reloads the same window, which fills further.
        let archive = isGroup(chat) ? chat : nil
        requestBackfill(archive: archive, pages: AppModel.backfillPagesPerScroll)
        return !isDemo && session.isReady && !backfillSettled.contains(archive ?? accountID)
    }

    // A reply sent from here names its original by local ID, a received one by the ID its sender saw, resolved as a
    // reaction's target is.
    func quotedMessageID(_ reference: String, in chatID: String) async -> String? {
        guard let store else { return nil }
        let account = accountID
        if let local = try? await store.message(accountID: account, messageID: reference), local.chatID == chatID { return local.id }
        return try? await store.reactionTarget(accountID: account, chatID: chatID, wireID: reference)?.id
    }

    func isBackfilling(chat: String) -> Bool { backfillingArchive != nil && backfillingArchive == (isGroup(chat) ? chat : accountID) }

    // `XMPPClient` allows one archive query at a time, so the forward walk must have finished. `resetSession` cancels
    // this; `connect` and `quiesceTransport` join it. The loading cell shows only when the store has something to
    // fetch.
    private func requestBackfill(archive: String?, pages: Int) {
        let archiveID = archive ?? accountID
        guard transportWanted, !quiescing, hasTransportOwnership, session.isReady, archiveWalkFinished, catchUp == nil, backfillTask == nil,
              joinBoundaryQueries == 0, !isDemo,
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
                    // Only a spent budget leaves more to ask for on this connection; a refusal is retried on the next
                    // one.
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
            if showed { self.refreshSoon() }
        }
    }

    private func backfillPageCommitted(_ progress: ArchiveSyncProgress, token: UUID) {
        guard generation == token else { return }
        Self.syncLog.notice("backfill page pages=\(progress.pages, privacy: .public) messages=\(progress.messages, privacy: .public)")
        refreshSoon(.openChat)
    }

    func closeChat(_ chatID: String) {
        if ownTyping?.chat == chatID { sendOwnTyping(ownTyping?.sender.left(), to: chatID); ownTyping = nil; ownTypingPause?.cancel() }
        guard openChatID == chatID else { return }
        if messagesLoadedFor == chatID {
            timelinePages.store(TimelinePage(messages: Array(messages.suffix(AppModel.timelinePage)), reactions: messageReactions, receipts: messageReceipts,
                                             reactableGroupMessages: reactableGroupMessages), for: chats.first { $0.id == chatID }, account: accountID)
        }
        openChatID = nil; messages = []; messagesLoadedFor = nil; messageReactions = [:]; messageReceipts = [:]; attachmentFiles = [:]
        downloads.reset()
    }

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

    // Never the sample data, and not while sending is paused for review.
    private func canSendChatState(to chatID: String) -> Bool {
        !isDemo && session.isReady && hasTransportOwnership && Self.attention.sendsChatStates(lifecycle) && !quiescing
            && chatCapabilities(chatID).encryption != .needsReview
            && chatID != accountID && chats.contains(where: { $0.id == chatID }) && canSend(to: chatID)
            && (isGroup(chatID) || !isLabAccount || chatID.hasSuffix("@" + accountDomain))
    }

    // Chained, so states reach the wire in the order they were decided.
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

    private func dropTyping(in chatIDs: [String]) {
        guard !chatIDs.isEmpty else { return }
        for chatID in chatIDs { typingTracker.clear(chat: chatID) }
        let current = typing.filter { !chatIDs.contains($0.key) }
        if current != typing { typing = current }
    }

    private func syncOpenChatTyping() {
        let open = openChatID.flatMap { typing[$0] }
        if open != openChatTyping { openChatTyping = open }
    }

    private func syncOpenChatLastSeen() {
        let open = openChatID.flatMap { chat in
            isDemo ? DemoSamples.lastSeen(chat) : isDirectChat(chat) ? lastSeenTracker.lastSeen(for: chat) : nil
        }
        if open != openChatLastSeen { openChatLastSeen = open }
    }

    private func isDirectChat(_ chatID: String) -> Bool {
        chatID != accountID && !isGroup(chatID) && chats.contains(where: { $0.id == chatID })
    }

    // The last departure and last-activity answer stay so the header does not blank across a reconnect.
    private func resetPresence() {
        lastSeenTracker.resetConnection()
        syncOpenChatLastSeen()
    }

    // A presence subscription once per connection, or an XEP-0012 query at most once a minute while the contact shows
    // no available resource. A refused or failed query leaves the header unknown.
    private func requestLastSeen(for chatID: String) {
        guard !isDemo, session.isReady, transportWanted, !quiescing, let client, isDirectChat(chatID) else { return }
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

    // RFC 6121 §3.2. Stops at the first failure; the next connection's roster load retries while the switch stays off.
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
    private(set) var shareSuggestionsEnabled = true
    // Moves on before every deletion of all donations; a donation in flight then deletes its conversation again, so it
    // cannot outlive the deletion.
    @ObservationIgnored private var donationEpoch = 0

    func setNotificationPreviews(_ enabled: Bool) async { await updatePreferences { $0.notificationPreviews = enabled } }

    // Off deletes every donation under the lease, so no notification run donates meanwhile; when the system cannot
    // delete them the switch stays on.
    func setShareSuggestions(_ enabled: Bool) async {
        guard !accountID.isEmpty, enabled != shareSuggestionsEnabled else { return }
        let account = accountID
        guard !enabled else {
            ShareSuggestionSetting.set(true, accountID: account, defaults: sessionDefaults)
            shareSuggestionsEnabled = true
            return
        }
        guard transportWanted, !quiescing, let store else { return }
        let token = generation
        activeEncryptionOperations += 1
        defer { activeEncryptionOperations -= 1 }
        do { if !hasTransportOwnership { try await acquireForegroundOwnership(store, token: token) } }
        catch { self.error = "Could not save preferences."; return }
        guard generation == token, accountID == account else { return }
        // Off first, so an extension that reads it from here on donates nothing that the deletion would miss.
        ShareSuggestionSetting.set(false, accountID: account, defaults: sessionDefaults)
        donationEpoch += 1
        if !isDemo, testSessionID == nil, !(await CommunicationHistory.deleteAll()) {
            ShareSuggestionSetting.set(true, accountID: account, defaults: sessionDefaults)
            self.error = "Suggestions could not be removed from the share sheet. Try again."
            return
        }
        guard accountID == account else { return }
        shareSuggestionsEnabled = false
    }

    // Only after the send is durably queued; nothing with previews or suggestions off, for samples, in a test session,
    // or when a deletion since has revoked it (`mayDonate`).
    private func donateSend(to chatID: String) {
        let account = accountID, epoch = donationEpoch
        guard !isDemo, testSessionID == nil, let storageRoot, let store, mayDonate(to: chatID, account: account, epoch: epoch) else { return }
        let chat = chats.first { $0.id == chatID }
        let titles = Dictionary(chats.map { ($0.id, $0.title) }, uniquingKeysWith: { first, _ in first })
        let conversation = SuggestedConversation.outgoing(accountID: account, chatID: chatID, title: chat?.title, avatarHash: chat?.avatarHash,
                                                          roomMembers: groupChats[chatID]?.members, titles: titles, links: contactLinks.links)
        Task.detached {
            await OutgoingDonation.donate([conversation], store: store,
                                          avatar: { AvatarStore.suggestionImageData(root: storageRoot, account: account, hash: $0) },
                                          allowed: { _ in await self.mayDonate(to: chatID, account: account, epoch: epoch) })
        }
    }

    private func mayDonate(to chatID: String, account: String, epoch: Int) -> Bool {
        donationEpoch == epoch && accountID == account && notificationPreviewsEnabled
            && ShareSuggestionSetting.isEnabled(accountID: account, defaults: sessionDefaults) && !blocklist.blocks(chatID)
    }

    private func forgetSuggestions(for chatIDs: [String], account: String) {
        guard !chatIDs.isEmpty, !isDemo, testSessionID == nil else { return }
        let identifiers = chatIDs.map { NotificationIdentity.thread(accountID: account, chatID: $0) }
        Task.detached { await CommunicationHistory.deleteConversations(identifiers) }
    }

    // Sends them only if this process owns the transport; without the lease the next connection sends them.
    private func startOutboxRingListener() {
        guard outboxRingListener == nil else { return }
        let listener = OutboxRing.Listener { [weak self] in
            guard let self, self.store != nil, !self.isDemo else { return }
            Task {
                await self.refresh()
                self.startUploads()
                self.startOutbox()
            }
        }
        if listener.start() { outboxRingListener = listener }
        else { Self.syncLog.error("outbox ring could not be observed") }
    }

    // Every per-account switch is one row written under the transport lease; the store enforces the receipt switches.
    func updatePreferences(_ change: (inout AccountPreferences) -> Void) async {
        guard transportWanted, !quiescing, let store, !accountID.isEmpty else { return }
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
            // The lease is held, so no extension run is donating meanwhile, and later runs read the new setting.
            if CommunicationHistory.purgesDonations(from: accountPreferences, to: updated) {
                donationEpoch += 1
                await CommunicationHistory.deleteAll()
            }
            guard accountID == account else { return }
            let sharedLastSeen = accountPreferences.lastSeen
            accountPreferences = updated; notificationPreviewsEnabled = updated.notificationPreviews
            guard updated.lastSeen != sharedLastSeen, generation == token, let client else { return }
            // Off revokes every subscription to our presence at once, or on the next connection's roster load when offline.
            await client.setSharesLastActivity(updated.lastSeen)
            if !updated.lastSeen, session.isReady, lastSeenTracker.rosterLoaded {
                await revokePresenceSharing(lastSeenTracker.sharingWith, token: token)
            }
        } catch { self.error = "Could not save preferences." }
    }

    // Read on this device (published with XEP-0490); the peer gets a read marker only when the read-receipts switch
    // allows.
    func markDisplayed(_ messageID: String) async {
        guard !quiescing, let store, let message = messages.first(where: { $0.id == messageID }), !message.isOutgoing,
              lifecycle.reading(message.chatID, openChatID: openChatID) else { return }
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

    // The peer gets no read marker: nothing was shown.
    func markChatRead(_ chatID: String) async {
        guard let store else { return }
        let account = accountID
        guard (try? await store.markChatRead(accountID: account, chatID: chatID)) == true, accountID == account else { return }
        await refresh(.chats)
        publishReadState()
    }

    // Counted as an operation so a background transition joins it; what fails stays pending for the next connection.
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

    // After catch-up, so other devices' XEP-0490 items name messages we hold.
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
            guard generation == token else { return }
            releaseCatchUpBanners()
        }
    }

    // Mac only: catch-up and the other devices' read state are in, so held banners can go, one per chat.
    private func releaseCatchUpBanners() {
        guard Self.attention.holdsCatchUpBanners, catchUpBanners == .holding else { return }
        catchUpBanners = .due
        refreshSoon(.chats)
    }

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

    // Local only: nothing reaches the server.
    private func setChatNotifications(_ chatID: String, _ setting: ChatNotificationSetting) async {
        guard let store else { return }
        do {
            try await store.setChatNotificationSetting(accountID: accountID, chatID: chatID, setting)
            await refresh(.chats)
        } catch { self.error = "Could not update notifications for this chat." }
    }

    // Keeps the level, so unmuting a mentions-only group returns to mentions only.
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

    func setNotificationLevel(_ chatID: String, _ level: ChatNotificationLevel) async {
        await setChatNotifications(chatID, ChatNotificationSetting(level: isGroup(chatID) ? level : .all))
    }

    private(set) var blocklist = XMPPBlocklist()
    private(set) var blockingSupport = BlockingSupport()

    func isBlocked(_ chatID: String) -> Bool { !isGroup(chatID) && blocklist.blocks(chatID) }

    var blockingAvailability: BlockingAvailability {
        .evaluate(signedIn: !accountID.isEmpty, isDemo: isDemo, ready: session.isReady, support: blockingSupport, domain: accountDomain)
    }

    private func loadBlocklist() {
        blocklist = isDemo ? XMPPBlocklist() : BlockedAddresses.load(accountID: accountID, defaults: sessionDefaults)
        blockingSupport = BlockingSupport(features: isDemo ? nil : serverProfiles.memory(account: accountID, stream: nil, uploadsFresh: false).features)
    }

    // A server with XEP-0191 sends its list and pushes later changes; one without it blocks nothing, so the kept copy
    // is dropped.
    private func refreshBlocklist(account: String, client: XMPPClient) async {
        guard !isDemo else { return }
        blockingSupport = BlockingSupport(features: serverProfiles.memory(account: account, stream: nil, uploadsFresh: false).features)
        switch blockingSupport.blocking {
        case true?:
            do { try await client.fetchBlocklist() } catch {
                Self.syncLog.notice("block list fetch failed: \(ConnectionSetup.detail(error), privacy: .public)")
            }
        case false?: applyBlocklist(.replaceAll([]), account: account)
        case nil: break
        }
    }

    private func applyBlocklist(_ change: XMPPBlocklistChange, account: String) {
        guard account == accountID else { return }
        let updated = blocklist.applying(change)
        guard updated != blocklist else { return }
        let newlyBlocked = chats.map(\.id).filter { !isGroup($0) && updated.blocks($0) && !blocklist.blocks($0) }
        blocklist = updated
        BlockedAddresses.save(updated, accountID: account, defaults: sessionDefaults)
        updateAppBadge(chats)
        dropTyping(in: newlyBlocked)
        // What a newly blocked chat already had on screen goes too, and so do its share-sheet suggestions.
        for chatID in newlyBlocked {
            Task { await DeliveredNotificationCleaner.removeThread(accountID: account, chatID: chatID) }
        }
        forgetSuggestions(for: newlyBlocked, account: account)
    }

    // The server confirms before the chat shows as blocked (XEP-0191, XEP-0377 report).
    @discardableResult
    func block(_ chatID: String, report reason: XMPPReportReason? = nil, messageID: String? = nil) async -> Bool {
        guard !isGroup(chatID), blockingAvailability.isAvailable else { return false }
        let account = accountID
        if isDemo {
            blocklist.apply(.blocked([chatID]))
            updateAppBadge(chats)
            dropTyping(in: [chatID])
            return true
        }
        guard let client else { return false }
        var report: XMPPBlockReport?
        if let reason {
            var references: [XMPPStanzaReference] = []
            // XEP-0377 §6: stanza IDs point into the server's archive. Only an incoming message of this very chat
            // counts.
            if blockingSupport.archive, let messageID, let store,
               messages.contains(where: { $0.id == messageID && $0.chatID == chatID && !$0.isOutgoing }),
               let stanzaID = try? await store.archiveStanzaID(accountID: account, messageID: messageID) {
                references.append(XMPPStanzaReference(id: stanzaID, by: account))
            }
            report = XMPPBlockReport(reason: reason, messages: references)
        }
        do {
            try await client.block(chatID, report: report)
        } catch {
            guard account == accountID else { return false }
            self.error = "Couldn’t block \(chatName(for: chatID)). Try again."
            return false
        }
        applyBlocklist(.blocked([chatID]), account: account)
        return true
    }

    // The entry as the server holds it: a bare address, or a domain or full address set elsewhere.
    func unblock(_ address: String) async {
        guard blockingAvailability.isAvailable else { return }
        let account = accountID
        if isDemo {
            blocklist.apply(.unblocked([address]))
            updateAppBadge(chats)
            return
        }
        guard let client else { return }
        do {
            try await client.unblock([address])
        } catch {
            guard account == accountID else { return }
            self.error = "Couldn’t unblock \(address). Try again."
            return
        }
        applyBlocklist(.unblocked([address]), account: account)
    }

    func blockEntries(for chatID: String) -> [String] {
        guard let jid = JID(chatID) else { return [] }
        return [jid.bare, jid.domainpart].filter { blocklist.addresses.contains($0) }
    }

    @ObservationIgnored private lazy var reload = CoalescedReload { [weak self] scope in await self?.load(scope) }

    // Returns after a load that started after this call; concurrent calls share one follow-up load.
    private func refresh(_ scope: CoalescedReload.Scope = .all) async { await reload.request(scope) }

    // Not awaited: the event loop handles one event at a time, so awaiting would serialise a burst into one load each.
    // Counted as an operation so a background transition still joins it before releasing the lease.
    private func refreshSoon(_ scope: CoalescedReload.Scope = .all) {
        activeEncryptionOperations += 1
        Task { await refresh(scope); activeEncryptionOperations -= 1 }
    }

    struct TimelinePage {
        var messages: [ChatMessage]
        var reactions: [String: [AuthenticatedReaction]] = [:]
        var receipts: [String: MessageEventKind] = [:]
        var reactableGroupMessages: Set<String> = []
    }

    // A page is shown only while the chat list still describes the same newest message; the real load then replaces it.
    struct TimelinePageCache {
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
        private var order: [String] = []

        mutating func page(for chat: ChatSummary?, account: String) -> TimelinePage? {
            guard let chat, account == self.account, let entry = entries[chat.id] else { return nil }
            guard entry.tail == Tail(chat) else { remove(chat.id); return nil }
            touch(chat.id)
            return entry.page
        }

        mutating func store(_ page: TimelinePage, for chat: ChatSummary?, account: String) {
            switchAccount(account)
            guard let chat else { return }
            guard page.messages.last?.sentAt == chat.lastMessageAt, (page.messages.last?.isOutgoing ?? false) == chat.lastMessageIsOutgoing else { remove(chat.id); return }
            entries[chat.id] = (Tail(chat), page)
            touch(chat.id)
            while order.count > Self.capacity { entries[order.removeFirst()] = nil }
        }

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

    private func loadTimeline(store: MessageStore, account: String, chat: String, isGroup: Bool, limit: Int) async throws -> TimelinePage {
        let storedMessages = try await store.messages(accountID: account, chatID: chat, limit: limit)
        var reactions: [String: [AuthenticatedReaction]] = [:], receipts: [String: MessageEventKind] = [:]
        // One bounded query: reactions, receipts, retractions and corrections together.
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
        noteLinkPreviewHosts(of: page.messages)
        messages = page.messages
        messagesLoadedFor = chat
        messageReactions = page.reactions
        messageReceipts = page.receipts
        reactableGroupMessages = page.reactableGroupMessages
        loadAttachments(page.messages, chat: chat)
    }

    // One chat at a time so an open waits on at most one read. Counted as an operation so a background transition joins
    // it; it stops at the next chat once quiescing.
    private func prefetchTimelinePages(store: MessageStore, account: String) {
        guard !prefetchingPages, transportWanted, !quiescing, accountID == account else { return }
        let wanted = timelinePages.missing(from: chats, account: account, excluding: openChatID)
        guard !wanted.isEmpty else { return }
        prefetchingPages = true
        activeEncryptionOperations += 1
        Task {
            defer { prefetchingPages = false; activeEncryptionOperations -= 1 }
            for chat in wanted {
                guard transportWanted, !quiescing, accountID == account, openChatID != chat.id else { continue }
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
        let started = ContinuousClock.now
        defer { syncTimings.add(.reload, since: started) }
        let account = accountID
        // Typing that a message ended goes in the same update that shows the message, so the bubble takes its place.
        defer { typingTracker.flushSettled(); publishTyping() }
        do {
            await loadLinkPreviewHosts(store: store, account: account)
            if scope.contains(.chats) {
                try await loadChats(store: store, account: account)
                prefetchTimelinePages(store: store, account: account)
            }
            guard scope.contains(.openChat), accountID == account, let selected = openChatID else { return }
            // Every chat-list load, join and rejoin mirrors the known rooms into groupChats.
            let page = try await loadTimeline(store: store, account: account, chat: selected, isGroup: isGroup(selected), limit: timelineWindow)
            guard accountID == account, openChatID == selected else { return }
            publishTimeline(page, chat: selected)
        } catch { self.error = "Could not read local conversations." }
    }

    // The chat list does not depend on which chat is open, so only the account fences it.
    private func loadChats(store: MessageStore, account: String) async throws {
        let storedChats = try await store.chats(accountID: account)
        let pending = try await encryption?.pendingConversations(account: account) ?? [:]
        let rooms: [String: [String]]
        var own: [EncryptionDevice] = []
        if let encryption, !isDemo, !account.isEmpty, try await store.encryptionState(accountID: account) != nil {
            rooms = try await encryption.knownGroupRooms(account: account)
            // Unreadable own devices only hide the account-level review; sealing still refuses undecided devices.
            own = (try? await encryption.ownDevices(account: account)) ?? []
        } else { rooms = [:] }
        let existingChatIDs = Set(storedChats.map(\.id))
        for peer in pending.keys where !existingChatIDs.contains(peer) {
            // A retained first-contact message needs a discoverable review entry and a durable conversation for pinning
            // or queuing a reply before approval.
            try await store.upsertChat(accountID: account, chatID: peer, title: peer)
        }
        guard accountID == account else { return }
        accountPreferences = try await store.accountPreferences(accountID: account)
        notificationPreviewsEnabled = accountPreferences.notificationPreviews
        if transportWanted, hasTransportOwnership, !quiescing {
            try await presentForegroundNotifications(store: store, account: account)
        }
        guard accountID == account else { return }
        if !isDemo, own != ownDevices { ownDevices = own }
        for (room, members) in rooms {
            var value = groupChats[room] ?? GroupChatState()
            value.members = members
            groupChats[room] = value
        }
        let known = Set(storedChats.map(\.id))
        loadStoredAvatars(storedChats)
        await contactLinks.load(store: store, account: account, root: storageRoot)
        guard accountID == account else { return }
        let reviewPreview = "Encrypted message needs attention"
        var summaries = storedChats.map { ChatSummary(id: $0.id, title: $0.title,
            preview: pending[$0.id] != nil ? reviewPreview : ($0.lastMessage.map { last in
                last.isRetracted ? "Message unsent"
                    : last.unreadableReason.map(UnreadableCopy.preview) ?? (last.body.isEmpty ? (last.attachment?.kindLabel ?? "") : last.body) } ?? ""),
            isPinned: $0.isPinned, avatarHash: $0.avatarHash,
            lastMessageAt: $0.lastMessage?.sentAt, lastMessageIsOutgoing: $0.lastMessage?.isOutgoing ?? false,
            lastMessageState: $0.lastMessage?.transportState, lastMessageReceipt: $0.lastMessageReceipt, notification: $0.notification, unreadCount: $0.unreadCount,
            contactName: contactLinks.links[$0.id]?.name) }
        summaries += pending.keys.filter { !known.contains($0) }.sorted().map {
            ChatSummary(id: $0, title: $0, preview: reviewPreview, isPinned: false)
        }
        // A pointer moved (here, elsewhere, or before this launch) or retained ciphertext was resolved: its chat's
        // notifications, or its review notification, may go.
        let previousUnread = Dictionary(chats.map { ($0.id, $0.unreadCount) }, uniquingKeysWith: max)
        if !hasLoadedChats || summaries.contains(where: { $0.unreadCount < (previousUnread[$0.id] ?? 0) })
            || reviewCounts.contains(where: { pending[$0.key, default: 0] < $0.value }) {
            removeReadNotifications(account: account, store: store)
        }
        reviewCounts = pending
        // List animates a reorder only inside an explicit transaction.
        withAnimation(summaries.map(\.id) == chats.map(\.id) ? nil : .default) { chats = summaries }
        hasLoadedChats = true
        updateAppBadge(summaries)
    }

    // Unread outside muted chats (`NotificationBadge`, the extension's rule too); every change of unread totals or mute
    // reloads the chat list.
    private func updateAppBadge(_ summaries: [ChatSummary]) {
        guard !accountID.isEmpty else { return }
        setAppBadge(NotificationBadge.count(unread: Dictionary(summaries.map { ($0.id, $0.unreadCount) }, uniquingKeysWith: max),
                                            settings: Dictionary(summaries.map { ($0.id, $0.notification) }, uniquingKeysWith: { first, _ in first }),
                                            blocklist: blocklist))
    }

    private func setAppBadge(_ count: Int) {
        guard appBadge != count else { return }
        appBadge = count
        let dockTileOnly = badgeUsesDockTile
        Task { await PlatformApplication.setBadgeCount(count, dockTileOnly: dockTileOnly) }
    }

    // The Mac labels its Dock tile until notifications are asked, and in a test session, whose counts must not reach the
    // app's real badge; otherwise the extension sets the same badge too.
    private var badgeUsesDockTile: Bool {
        #if os(macOS)
        testSessionID != nil || notificationAuthorization == .notDetermined
        #else
        false
        #endif
    }
}

// In front it is the app's live session; in the background the store's lease plus a short-lived connection, which the
// watchdog ends at the budget's deadline.
@MainActor private final class NotificationActionSession {
    let account: String
    let isForeground: Bool
    let budget: NotificationActionBudget
    var client: XMPPClient?
    var consumer: Task<Void, Never>?
    var watchdog: Task<Void, any Error>?
    var releaseLifecycle: AsyncStream<Void>.Continuation?
    // `acquiringLease` covers the call in flight, whose lock may already be held before the main actor hears of it.
    var holdsLease = false
    var acquiringLease = false
    private(set) var aborted = false
    // Only after `initialize`, as the app's `.ready`, is anything sealed or sent.
    var ready = false
    var joinedRooms: Set<String> = []
    var restoration: Task<Void, Never>?

    init(account: String, isForeground: Bool, budget: NotificationActionBudget) {
        self.account = account; self.isForeground = isForeground; self.budget = budget
    }

    var isOver: Bool { aborted || ContinuousClock.now >= budget.deadline }

    func abort() {
        aborted = true
        guard let client else { return }
        Task { await client.disconnect() }
    }
}

@MainActor private final class ActionWaitCompletion { var finished = false }

extension AppModel: NotificationActionEnvironment {
    private static let acknowledgementWait: Duration = .seconds(3)
    private static let foregroundReplyWait: Duration = .seconds(10)

    // `NotificationActionCenter` measured `budget` from the delegate callback, so `prepare()` counts against it.
    func performNotificationAction(_ request: NotificationActionRequest, budget: NotificationActionBudget) async -> NotificationActionOutcome {
        await prepare()
        let outcome: NotificationActionOutcome
        if case let .reply(text) = request.kind, await saveReplyForUpgrade(text, to: request.destination) { outcome = .replySavedForUpgrade }
        else { outcome = await NotificationActionHandler.perform(request, budget: budget, in: self) }
        Self.syncLog.notice("notification action: \(outcome.rawValue, privacy: .public)")
        return outcome
    }

    // The previous version's data still waits for its snapshot and upgrade, which only run in front: nothing may touch
    // it, so the text is kept for `queueSavedReplies`.
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

    // Queued under the ID it was saved with, so a launch killed before the file was removed does not queue it twice.
    // Sending still follows the trust rules once the session is ready.
    private func queueSavedReplies() async {
        guard let snapshots, let store, !snapshots.savedReplies.isEmpty else { return }
        guard let account = authorizedNotificationAccount() else { return }
        let result = await snapshots.queueSavedReplies(account: account, store: store, now: Date()) { try await self.enqueueReply($0) }
        Self.syncLog.notice("replies saved before the upgrade: \(result.queued, privacy: .public) queued, \(result.rejected, privacy: .public) rejected, \(result.expired, privacy: .public) too old")
        if result.expired > 0 { await NotificationActionCenter.postExpiredSavedReply() }
        else if result.rejected > 0 { await NotificationActionCenter.postRejectedReply() }
        startOutbox()
    }

    // True while the action holds or is taking the lease, so the center leaves the task to expire: termination frees
    // the lock, suspension would not.
    func abortNotificationAction() -> Bool {
        guard let session = actionSession else { return false }
        session.abort()
        return session.holdsLease || session.acquiringLease
    }

    func authorizedNotificationAccount() -> String? {
        guard postsNotificationsInThisSession, !isDemo, !accountID.isEmpty, sessionAccount?.accountID == accountID,
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
        if !PlatformApplication.isInBackground || (transportWanted && !quiescing && hasTransportOwnership) {
            actionSession = NotificationActionSession(account: account, isForeground: true, budget: budget)
            return true
        }
        let session = NotificationActionSession(account: account, isForeground: false, budget: budget)
        actionSession = session
        // Measured from the delegate callback: a slow start or a queued action ahead of this one used part of it.
        session.watchdog = Task { [weak session] in
            try await Task.sleep(until: budget.deadline, clock: .continuous)
            session?.abort()
        }
        // A quiesce in flight finishes first, and a return to the foreground waits for this. The wait for it and for
        // the lease share one bound; past it the action works locally only.
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
            try await client.setAvailability(awayAvailability, clientActive: false)
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
            // An identity mismatch fails closed before anything can be sealed.
            try await encryption.initialize(account: account, transport: client)
            if isGroup(chatID) {
                let nickname = preferences.string(forKey: "groupNickname.\(account).\(chatID)") ?? String(account.prefix { $0 != "@" })
                // The drain sends only to joined rooms.
                if await BackgroundSession.join(chatID, nickname: nickname, client: client,
                                                within: session.budget.remaining(at: .now, atMost: .seconds(3))) {
                    session.joinedRooms.insert(chatID)
                }
            }
            guard !session.isOver else { throw CancellationError() }
            session.ready = true
            // A fresh bind lost the hibernated session's push registration and room occupancy: restore both, or pushes
            // for this account stop. `endNotificationAction` waits for them within the budget.
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

    // `holdsLease` is set in the same main-actor turn the acquisition returns in, and `acquiringLease` covers the call
    // in flight, so the expiration handler never ends the task over a held lock.
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

    private static func finishes(_ task: Task<Void, Never>?, by deadline: ContinuousClock.Instant) async -> Bool {
        guard let task else { return true }
        // Awaiting a task's value ignores cancellation, so the race is polled rather than put in a task group.
        let completion = ActionWaitCompletion()
        Task { @MainActor in await task.value; completion.finished = true }
        while !completion.finished, ContinuousClock.now < deadline { guard (try? await Task.sleep(for: .milliseconds(50))) != nil else { break } }
        return completion.finished
    }

    func markNotificationMessageRead(_ message: StoredMessage) async throws {
        guard let store else { throw MessageStoreError.closed }
        let account = message.accountID
        if try await store.markRead(accountID: account, chatID: message.chatID, throughMessageID: message.id) { await refresh(.chats) }
        // The store checks the read-receipts switch for the marker; the pointer and XEP-0490 do not depend on it.
        _ = try? await encryption?.queueReceipt(account: account, chatID: message.chatID, messageID: message.id, kind: .marker)
        if actionSession?.isForeground == true { publishReadState(); startOutbox() }
    }

    func clearReadNotifications(for message: StoredMessage) async {
        await DeliveredNotificationCleaner.removeMessages(accountID: message.accountID, messageIDs: [message.id])
        if let store { try? await DeliveredNotificationCleaner.removeRead(accountID: message.accountID, store: store) }
    }

    // Only the drain seals the queued row. A plain answer in the chat, not an XEP-0461 reply.
    func enqueueNotificationReply(_ text: String, to message: StoredMessage) async throws -> String {
        let reply = NotificationActionHandler.replyMessage(text, id: UUID().uuidString, to: message)
        try await enqueueReply(reply)
        donateSend(to: reply.chatID)
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
            // Wait until the reply left the queue, a pass that started after it finished and left it there (held for a
            // decision), or the session never got ready.
            let before = drainPasses
            startOutbox()
            let clock = ContinuousClock(), deadline = clock.now + session.budget.remaining(at: clock.now, atMost: Self.foregroundReplyWait)
            while clock.now < deadline {
                if let state = try? await store.message(accountID: account, messageID: messageID)?.transportState, state != .queued { break }
                if drainPasses > before, drainTask == nil, !outboxRequested { break }
                guard (try? await Task.sleep(for: .milliseconds(200))) != nil else { break }
            }
        } else {
            await flushBackgroundAction(session)
        }
        return await replyDelivery(messageID, account: account, budget: session.budget)
    }

    // A written but unacknowledged reply still counts as sent (the archive reconciles it); queued (held) and failed are
    // not sent.
    private func replyDelivery(_ messageID: String, account: String, budget: NotificationActionBudget) async -> ReplyDelivery {
        guard let store else { return .held }
        let clock = ContinuousClock(), deadline = clock.now + budget.remaining(at: clock.now, atMost: Self.acknowledgementWait)
        while true {
            switch try? await store.message(accountID: account, messageID: messageID)?.transportState {
            case .serverAccepted?: return .sent
            case .submitting?, .unconfirmed?: if clock.now >= deadline { return .sent }
            default: return .held
            }
            // Cancelled while written but unacknowledged, which counts as sent.
            guard (try? await Task.sleep(for: .milliseconds(200))) != nil else { return .sent }
        }
    }

    func flushNotificationAction(account: String) async {
        guard let session = actionSession, !session.isForeground else { return }
        await flushBackgroundAction(session)
    }

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
        content.title = notificationPreviewsEnabled ? chats.first { $0.id == message.chatID }?.displayTitle ?? "" : ""
        content.body = NotificationActionCopy.replyFailed
        content.threadIdentifier = NotificationIdentity.thread(accountID: account, chatID: message.chatID)
        content.categoryIdentifier = NotificationIdentity.noticeCategory
        content.userInfo = [NotificationNavigation.replyFailureKey: destination.payload]
        content.sound = .default
        let request = UNNotificationRequest(identifier: identifier, content: content, trigger: nil)
        #if DEBUG && os(macOS)
        guard MacDebugNotificationLog.shouldPost(notice: request) else { return }
        #endif
        try? await center.add(request)
    }

    func endNotificationAction() async {
        // `actionSession` stays set until the lease is back, so an expiring background task sees that it is held.
        guard let session = actionSession else { return }
        session.watchdog?.cancel()
        await session.restoration?.value
        if let client = session.client { await client.disconnectAndWait() }
        session.consumer?.cancel()
        await session.consumer?.value
        // Still in the background: the lease goes back so the extension can run. A foreground session that took it
        // meanwhile keeps it.
        if session.holdsLease, !hasTransportOwnership, let store {
            if session.client != nil { await presentActionArrivals(store: store, session: session) }
            await releaseLeaseInBackground(store)
        }
        session.holdsLease = false
        actionSession = nil
        session.releaseLifecycle?.finish()
        await refresh()
    }

    // The server pushed nothing for what the action's online connection received, so those alert here under the lease,
    // exactly as the extension would (including the claim that stops a later run repeating them).
    private func presentActionArrivals(store: MessageStore, session: NotificationActionSession) async {
        guard authorizedNotificationAccount() == session.account else { return }
        let presenter = NotificationPresenter(posting: notificationPoster(account: session.account),
                                              addTimeout: .seconds(2), cleanupTimeout: .seconds(1))
        let account = session.account, progress = NotificationRunProgress()
        let timeout = session.budget.presentationTimeout(at: .now)
        guard timeout > .zero else { return }
        let blocked = BlockedAddresses.load(accountID: account, defaults: sessionDefaults)
        let presentation = Task { try await presenter.present(store: store, accountID: account, progress: progress, blocklist: blocked) }
        let watchdog = Task { try? await Task.sleep(for: timeout); presentation.cancel() }
        _ = await presentation.result
        watchdog.cancel()
        if progress.report.posted > 0 { Self.syncLog.notice("notification action presented=\(progress.report.posted, privacy: .public)") }
    }

    // Lets a push for this live session be presented once, by the app, not beside the extension's fallback. Mac only,
    // and only for the real store: a UI test session's store is not the one the extension opens.
    private func startLivenessResponder() {
        guard AppLiveness.isOffered, livenessResponder == nil, let container = try? SharedStorage.groupContainer() else { return }
        let responder = AppLiveness.Responder(files: AppLiveness.Files(groupRoot: container),
                                              conditions: { [weak self] in self?.livenessConditions ?? Self.silent },
                                              answered: { [weak self] in self?.keepLivenessPromise() })
        if responder.start() { livenessResponder = responder }
        else { Self.syncLog.error("liveness responder could not observe its ring") }
    }

    private static let silent = LivenessConditions(wantsConnection: false, quiescing: true, ownsLease: false, servesExtensionAccount: false,
                                                   presentsCatchUp: false)

    // The answer promises this process keeps the lease and presents: never while a sleep or sign-out quiesces, only for
    // the account the extension serves, and only where a later catch-up still gets its banner.
    private var livenessConditions: LivenessConditions {
        LivenessConditions(wantsConnection: wantsConnection && testSessionID == nil, quiescing: quiescing,
                           ownsLease: hasTransportOwnership,
                           servesExtensionAccount: sessionAccount.map { saved in
                               (try? NotificationAccount.load())?.accountID == saved.accountID
                           } ?? false,
                           presentsCatchUp: Self.attention.holdsCatchUpBanners)
    }

    // The server pushed because an acknowledgement was overdue, so the socket may be dead without an error: probe it (a
    // dead stream ends and the reconciler resumes it, replaying what the server queued), or connect at once.
    private func keepLivenessPromise() {
        Self.syncLog.notice("liveness answered, connected=\(self.isConnected, privacy: .public)")
        guard isConnected, let client else {
            networkBecameReachable()
            return
        }
        Task { [weak self] in
            let alive = await client.probeLiveness(within: .seconds(5))
            Self.syncLog.notice("liveness probe answered=\(alive, privacy: .public)")
            if !alive { self?.networkBecameReachable() }
        }
    }

    fileprivate func presentForegroundNotifications(store: MessageStore, account: String) async throws {
        let started = ContinuousClock.now
        defer { syncTimings.add(.notify, since: started) }
        if Self.attention.holdsCatchUpBanners, catchUpBanners != .live {
            try await presentCaughtUpNotifications(store: store, account: account)
            return
        }
        let presents = mayPostNotifications && postsNotificationsInThisSession && !isDemo && session.isReady && catchUp == nil
            && sessionAccount?.accountID == account
        let posted = try await NotificationPresenter(posting: notificationPoster(account: account))
            .presentForeground(store: store, accountID: account, readingChatID: lifecycle.readingChat(openChatID: openChatID), presents: presents,
                               blocklist: blocklist)
        if posted > 0 { Self.syncLog.notice("foreground notifications posted=\(posted, privacy: .public)") }
    }

    // Mac only: until this connection has caught up, candidates are neither posted nor dismissed; then each chat's held
    // candidates post once.
    private func presentCaughtUpNotifications(store: MessageStore, account: String) async throws {
        guard catchUpBanners == .due else { return }
        let token = generation
        let presents = mayPostNotifications && postsNotificationsInThisSession && !isDemo && session.isReady && sessionAccount?.accountID == account
        let posted = try await NotificationPresenter(posting: notificationPoster(account: account))
            .presentCaughtUp(store: store, accountID: account, readingChatID: lifecycle.readingChat(openChatID: openChatID), presents: presents)
        if generation == token, catchUpBanners == .due { catchUpBanners = .live }
        Self.syncLog.notice("caught-up notifications posted=\(posted, privacy: .public)")
    }

    private func notificationPoster(account: String) -> any NotificationPosting {
        let root = storageRoot
        let avatarData: @Sendable (String) -> Data? = { hash in
            guard let root else { return nil }
            return AvatarStore.notificationImageData(root: root, account: account, hash: hash)
        }
        // Read as each request posts, so a presentation under way stops donating once the switch is off. UserDefaults
        // is thread-safe.
        nonisolated(unsafe) let defaults = sessionDefaults
        let poster = UserNotificationPoster(donates: { ShareSuggestionSetting.isEnabled(accountID: account, defaults: defaults) },
                                            avatarData: avatarData)
        #if DEBUG && os(macOS)
        if let logged = MacDebugNotificationLog.poster(posting: poster, avatarData: avatarData) { return logged }
        #endif
        return poster
    }

    // Except in a DEBUG Mac run that logs its notifications, so banner checks can use a private test store and leave
    // the shared App Group store alone.
    private var postsNotificationsInThisSession: Bool {
        #if DEBUG && os(macOS)
        if MacDebugNotificationLog.mode != nil { return true }
        #endif
        return testSessionID == nil
    }

    fileprivate func refreshNotificationPermission() {
        guard postsNotificationsInThisSession else { return }
        Task { [weak self] in
            #if DEBUG
            // Simulator lab runs only: the lab account has no staging push, which is what normally asks.
            if ProcessInfo.processInfo.arguments.contains("-request-notification-permission") {
                _ = try? await UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound, .badge])
            }
            #endif
            #if os(iOS)
            let status = await Self.notificationAuthorization()
            guard let self else { return }
            self.mayPostNotifications = [.authorized, .provisional, .ephemeral].contains(status)
            #else
            let (status, alertStyle) = await Self.notificationPermission()
            guard let self else { return }
            self.mayPostNotifications = [.authorized, .provisional].contains(status)
            let asked = self.notificationAuthorization != .notDetermined
            let changed = (self.notificationAuthorization, self.notificationAlertStyle) != (status, alertStyle)
            self.notificationAuthorization = status
            self.notificationAlertStyle = alertStyle
            if asked != (status != .notDetermined), let badge = self.appBadge {
                self.appBadge = nil
                self.setAppBadge(badge)
            }
            // Banners allowed or taken away in System Settings while connected: push follows at once.
            let alertsAllowed = PushStatus.gate(for: status, alertStyle: alertStyle, interactive: false) == nil
            if changed, status != .notDetermined, self.pushWanted, PushService.isOffered,
               alertsAllowed ? self.pushStatus == .notAllowed : [.on, .settingUp].contains(self.pushStatus),
               let client = self.client, let session = self.sessionAccount, self.isConnected {
                self.startPushSetup(client: client, session: session, token: self.generation, interactive: false)
            }
            #if DEBUG
            if MacDebugNotificationLog.mode == .log { self.mayPostNotifications = true }
            #endif
            #endif
            // Turning it back on is picked up by the next connection.
            if status == .denied, [.on, .settingUp].contains(self.pushStatus) { self.pushStatus = .notAllowed }
        }
    }

    private nonisolated static func notificationAuthorization() async -> UNAuthorizationStatus {
        await UNUserNotificationCenter.current().notificationSettings().authorizationStatus
    }

    #if os(macOS)
    private nonisolated static func notificationPermission() async -> (UNAuthorizationStatus, UNAlertStyle) {
        let settings = await UNUserNotificationCenter.current().notificationSettings()
        return (settings.authorizationStatus, settings.alertStyle)
    }
    #endif

    #if DEBUG
    #if os(macOS)
    func debugShowNotificationPermission(_ status: UNAuthorizationStatus, alertStyle: UNAlertStyle) {
        notificationAuthorization = status
        notificationAlertStyle = alertStyle
    }
    #endif

    func debugLeaseReport() async -> String {
        let held = await store?.holdsTransportOwnership
        let stored = held.map { $0 ? "held" : "free" } ?? "closed"
        return "lease store \(stored) model \(hasTransportOwnership ? "held" : "free"), session \(session.label), quiescing \(quiescing ? 1 : 0)"
    }

    func debugMessageReport(_ chatID: String) async -> String {
        guard let store else { return "closed" }
        let pointer = try? await store.readPointer(accountID: accountID, chatID: chatID)
        let rows = ((try? await store.messages(accountID: accountID, chatID: chatID)) ?? []).map { message in
            "\(message.id.prefix(8)) \(message.isOutgoing ? "out \(message.transportState.map { "\($0)" } ?? "")" : "in") at \(message.sentAt.timeIntervalSince1970) body \(message.body.count)"
                + (message.unreadableReason.map { " unreadable \($0)" } ?? "")
        }
        return "pointer \(pointer.map { "\($0.messageID.prefix(8)) at \($0.sentAt.timeIntervalSince1970)" } ?? "none"); \(rows.joined(separator: " | "))"
    }

    func debugRetentionReport(_ chatID: String) async -> String {
        guard let store, let encryption else { return "closed" }
        let pending = ((try? await store.pendingEncryptedIncomingSummaries(accountID: accountID)) ?? []).map {
            "\($0.sender) \($0.reason)\($0.room.map { " in \($0)" } ?? "")"
        }
        let devices = ((try? await encryption.cachedGroupDevices(account: accountID, room: chatID)) ?? []).map {
            "\($0.jid) \($0.deviceID) \($0.trust)\($0.active ? "" : " inactive")"
        }
        return "retained [\(pending.joined(separator: ", "))], room devices [\(devices.joined(separator: ", "))]"
    }

    var debugBadgeReport: String {
        "icon badge \(appBadge.map(String.init) ?? "unset") through \(badgeUsesDockTile ? "the Dock tile" : "the notification centre")"
    }

    func debugSilenceTransport() async -> Bool {
        await client?.silenceTransport() ?? false
    }

    func debugHoldAcknowledgements(for duration: Duration) async -> Bool {
        await client?.holdAcknowledgements(for: duration) ?? false
    }

    // Simulates a missed sleep deadline: a quiesce that starts meanwhile cannot finish before it.
    func debugHoldEncryptionOperation(for duration: Duration) {
        activeEncryptionOperations += 1
        Task { [weak self] in
            try? await Task.sleep(for: duration)
            self?.activeEncryptionOperations -= 1
        }
    }
    #endif
}

// Mac only: catch-up banners wait until the walk and the read-state sync are in, then go once per chat; after that each
// candidate banners as it arrives.
private enum CatchUpBanners { case holding, due, live }

enum TransferState: Equatable {
    case none
    case exporting(AccountTransfer.Progress?)
    case moved(AccountTransfer.Moved)
    case settling
}

enum UpgradeState: Equatable {
    case none
    case preparing
    case waitingForLease
    case deferred
    case snapshotFailed(String)
    case restoring
    case restored(PreUpgradeSnapshot.RestoredState)
    case returning
    // Nothing opens the store until a newer build is installed; no way out from here may change or delete it.
    case newerData
}
