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
    /// Title for display: the stored title, or the address local part when the title is just the address.
    var displayTitle: String { AppModel.displayName(for: id, title: title) }
}

typealias ChatMessage = StoredMessage

@MainActor @Observable
final class AppModel {
    private(set) var chats: [ChatSummary] = []
    private(set) var messages: [ChatMessage] = []
    /// The chat whose messages `messages` currently holds; nil while a load is pending.
    private(set) var messagesLoadedFor: String?
    /// How many of the open chat's newest messages are loaded; scrolling to the top and searching raise it.
    // ponytail: each page re-reads the whole window and search stops at the ceiling; page by cursor and search in the store when chats outgrow it.
    @ObservationIgnored private var timelineWindow = AppModel.timelinePage
    @ObservationIgnored private var loadingOlder = false
    private static let timelinePage = 100, timelineCeiling = 1000
    private(set) var messageReactions: [String: [AuthenticatedReaction]] = [:]
    /// The peer's strongest receipt per own message in the open chat: delivered or displayed.
    private(set) var messageReceipts: [String: MessageEventKind] = [:]
    private(set) var accountPreferences = AccountPreferences()
    private(set) var groupChats: [String: GroupChatState] = [:]
    /// Chat → who is typing there (XEP-0085). In memory only; it expires on its own.
    private(set) var typing: [String: [String]] = [:] { didSet { syncOpenChatTyping() } }
    /// The open chat's entry in `typing`, observed on its own so typing in another chat never re-renders the conversation.
    private(set) var openChatTyping: [String]?
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
    private(set) var accountID = ""
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
    private(set) var notificationStatus = "Not enabled"
    private(set) var notificationRoute: NotificationChatRoute?
    @ObservationIgnored private var sessionAccount: NotificationAccount?
    @ObservationIgnored private var lifecycleTask: Task<Void, Never>?
    @ObservationIgnored private var foreground = true
    @ObservationIgnored private var quiescing = false
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
    /// Chats with retained incoming ciphertext awaiting review, from the chat-list load.
    private(set) var pendingReviewChats: Set<String> = []
    /// What the last device refresh saw on the server, and any refresh or decryption problem, for the Devices screen footer.
    private(set) var encryptionDiagnostics = ""
    /// The chat whose devices were re-fetched on which connection generation, with that refresh's footer line.
    /// Opening a chat or popping back reuses it; a reconnect (new generation) fetches once more.
    @ObservationIgnored private var refreshFence: [String: (generation: UUID, note: String)] = [:]
    /// The open chat's encryption in words, derived from stored devices. Inbound, outbox and decryption paths still
    /// assign it to report a problem; the text lands in the diagnostics footer only, so a transient problem never
    /// rewrites the pill or re-shows a dismissed review card.
    var encryptionStatus: String {
        get { encryptionOverviewChatID.map { trustSummary(for: $0).subtitle } ?? "" }
        set { encryptionDiagnostics = newValue }
    }
    /// Stored undecided devices or retained ciphertext for the open chat. The outbox still assigns it when a send is
    /// blocked; the assignment is ignored because the store already holds whatever blocked the send.
    var encryptionNeedsReview: Bool {
        get { encryptionOverviewChatID.map { chatCapabilities($0).encryption == .needsReview } ?? false }
        set { _ = newValue }
    }
    @ObservationIgnored private var encryption: OMEMOService?
    var isDemo: Bool { accountID == "preview.local" }

    @ObservationIgnored private var store: MessageStore?
    @ObservationIgnored private var outboxSender: OutboxSender?
    @ObservationIgnored private var outboxRequested = false
    @ObservationIgnored private var drainTask: Task<Void, Never>?
    @ObservationIgnored private var client: XMPPClient?
    @ObservationIgnored private var eventTask: Task<Void, Never>?
    @ObservationIgnored private var openChatID: String? { didSet { syncOpenChatTyping() } }
    @ObservationIgnored private var encryptionDetailsChatID: String?
    @ObservationIgnored private var generation = UUID()
    @ObservationIgnored private var prepared = false
    @ObservationIgnored private var pushTokenTask: Task<Void, Never>?
    @ObservationIgnored private var notificationTapTask: Task<Void, Never>?
    /// Owns the durable-disposition rule for the current stream; replaced with the client.
    @ObservationIgnored private var inbound: InboundProcessor?
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
        return UserDefaults(suiteName: "dev.xmpplab.uitest." + testSessionID) ?? .standard
    }()

    func prepare() async {
        guard !prepared else { return }
        prepared = true
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
        do {
            let directory = try await SharedStorage.directory(testSessionID: testSessionID, migrate: true)
            storageRoot = directory
            store = try MessageStore(url: directory.appending(path: "messages.sqlite"))
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
                    notificationStatus = "Inspection complete"
                    return
                }
                await refresh()
                if let openChatID { await loadEncryptionDetails(for: openChatID, refreshFromServer: false) }
                if testSessionID == nil, let saved = try NotificationAccount.load() {
                    sessionAccount = saved
                    if saved.push != nil { notificationStatus = "Configured for staging" }
                    reconcile()
                }
            }
        } catch { self.error = "Could not open local message storage." }
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
            guard generation == token else { return }
            await refresh()
        } catch { if generation == token { self.error = "Could not load sample conversations." } }
    }

    /// Domains served by the development lab; they keep the disposable-account safeguards.
    static let labDomains: Set<String> = ["localhost", "staging.example.net"]
    var accountDomain: String { accountID.split(separator: "@", maxSplits: 1).last.map(String.init) ?? DevelopmentEndpoint.domain }
    var isLabAccount: Bool { Self.labDomains.contains(accountDomain) }

    /// `address` is a lab username or a full `name@domain`; `host` optionally overrides the server (direct TLS on 5223).
    func connect(username address: String, password: String, host serverHost: String? = nil, savedEndpoint: NotificationAccount? = nil) async -> Bool {
        let parts = address.trimmingCharacters(in: .whitespacesAndNewlines).split(separator: "@", maxSplits: 1).map(String.init)
        let username = parts.first ?? ""
        let requestedDomain = savedEndpoint?.domain ?? (parts.count == 2 ? parts[1].lowercased() : DevelopmentEndpoint.domain)
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
        let host: String
        if let savedEndpoint { host = savedEndpoint.host }
        else if Self.labDomains.contains(requestedDomain) { host = requestedDomain == "localhost" ? DevelopmentEndpoint.host : requestedDomain }
        else { host = (serverHost ?? "").trimmingCharacters(in: .whitespacesAndNewlines).lowercased().isEmpty ? requestedDomain : serverHost!.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() }
        if let sessionAccount, sessionAccount.accountID != username + "@" + requestedDomain {
            await forgetAccount()
            guard foreground, !quiescing else { return false }
        }
        let priorEvents = eventTask
        let previous = resetSession()
        let token = generation
        session = .connecting(step: "Connecting…")
        let connection = XMPPClient(labCertificateAuthority: DevelopmentEndpoint.certificateAuthority)
        client = connection
        // Assign account before consuming events; scoped refresh rejects stale results.
        let endpoint = savedEndpoint ?? Self.retainingPushSubscription(previous: sessionAccount, replacement: NotificationAccount(accountID: username + "@" + requestedDomain,
            host: host, port: 5223, domain: requestedDomain,
            username: username, password: password, push: nil))
        let account = endpoint.accountID
        sessionAccount = endpoint
        selectAccount(account)
        await previous?.disconnectAndWait()
        await priorEvents?.value
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
        }
        do {
            guard let store, let encryption else { throw MessageStoreError.invalidValue }
            try await acquireForegroundOwnership(store, token: token)
            try await store.recoverInterruptedSubmissions(accountID: account)
            guard generation == token else { return false }
            try await connection.configureStreamManagement(persistence: StreamPersistence(store: store, accountID: account, encryption: encryption))
            guard generation == token else { return false }
            try await connection.connect(host: endpoint.host, port: endpoint.port, domain: endpoint.domain, username: username, password: password)
            guard generation == token, accountID == endpoint.accountID,
                  sessionAccount?.accountID == endpoint.accountID else { await connection.disconnect(); return false }
            // Authentication has succeeded. Only now may a manually entered password replace
            // saved credentials, so the next launch and every reconnect can sign in unattended.
            do { try endpoint.save() }
            catch {
                notificationStatus = "Needs attention"
                self.error = "Connected, but the password could not be saved. You will be asked for it on the next launch."
            }
            await refreshPushRegistration(client: connection, session: endpoint, token: token)
            return true
        } catch {
            guard generation == token else { await connection.disconnect(); return false }
            let message = Self.failureMessage(for: error)
            session = .offline(reason: message)
            if Self.isAuthenticationFailure(error) {
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
        case .authenticationFailed, .authenticationUnavailable: true
        default: false
        }
    }

    nonisolated static func failureMessage(for error: any Error) -> String {
        switch error {
        case XMPPClientError.authenticationFailed: "The password was not accepted."
        case XMPPClientError.authenticationUnavailable: "The server does not offer password sign-in over TLS."
        case XMPPClientError.timedOut: "The server did not respond."
        case MessageStoreError.transportOwnedElsewhere: "Another process is still using this account’s storage. Try again in a moment."
        case is CancellationError: "Connection cancelled."
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
        foreground && !quiescing && !userWantsOffline && !authenticationRejected && sessionAccount != nil && !isDemo
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
        let push = testSessionID == nil ? sessionAccount?.push ?? (try? PushRegistrationState.load(accountID: account))?.configuration : nil
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
        }
        sessionAccount = nil
        notificationStatus = "Not enabled"
        do {
            if testSessionID == nil, var state = try PushRegistrationState.load(accountID: account) {
                try state.journal.stageRevocation()
                try state.save()
            } else if let push {
                var state = PushRegistrationState(accountID: account, configuration: push, journal: PushRegistrationJournal())
                try state.journal.stageRevocation()
                try state.save()
            }
        } catch { self.error = "Signed out locally, but remote notification cleanup still needs attention." }
        if let push, let connection, isConnected {
            activeEncryptionOperations += 1
            defer { activeEncryptionOperations -= 1 }
            do {
                try await sendPendingPushRegistration(client: connection, account: account, token: token)
            }
            catch {
                if generation == token { self.error = "Could not disable the server push subscription. Background access has been removed from this phone." }
            }
            if generation == token {
                do { try await connection.disablePush(serviceJID: push.serviceJID, node: push.node) }
                catch { self.error = "Signed out locally. Remote notification cleanup could not be confirmed." }
            }
        }
        guard generation == token else { return }
        await quiesceTransport()
        if let localFailure { notificationStatus = "Needs attention"; self.error = localFailure }
    }

    /// Re-entering credentials does not revoke an existing server subscription. Keep its
    /// identity available for background handoff and explicit logout, but never cross accounts.
    static func retainingPushSubscription(previous: NotificationAccount?, replacement: NotificationAccount) -> NotificationAccount {
        guard replacement.push == nil, let previous, let push = previous.push,
              previous.accountID == replacement.accountID, previous.domain == replacement.domain,
              previous.username == replacement.username else { return replacement }
        return NotificationAccount(accountID: replacement.accountID, host: replacement.host, port: replacement.port,
            domain: replacement.domain, username: replacement.username, password: replacement.password, push: push)
    }

    /// Serialize scene transitions; never release the lease with a suspended writer alive.
    func setForeground(_ active: Bool) {
        foreground = active
        if !active { quiescing = true }
        let previous = lifecycleTask
        lifecycleTask = Task { [weak self] in
            await previous?.value
            guard let self else { return }
            if active {
                guard self.foreground else { return }
                self.reconnectAttempt = 0
                self.reconcile()
                if let client = self.client { try? await client.setClientActive(true) }
                await self.refresh()
            } else {
                let task = UIApplication.shared.beginBackgroundTask(withName: "Finish encrypted synchronization")
                await self.quiesceTransport()
                if task != .invalid { UIApplication.shared.endBackgroundTask(task) }
            }
        }
    }

    private func quiesceTransport() async {
        quiescing = true
        defer { quiescing = false }
        let events = eventTask
        let drain = drainTask
        let previous = resetSession()
        await previous?.disconnectAndWait()
        await events?.value
        await drain?.value
        // Includes already-started UI trust/repair/discovery work and an acquisition that
        // was suspended in the store actor when the scene changed.
        while activeEncryptionOperations > 0 || acquiringOwnership {
            try? await Task.sleep(for: .milliseconds(10))
        }
        hasTransportOwnership = false
        try? await store?.releaseTransportOwnership()
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

    func enableNotifications() async {
        guard hasTransportOwnership, foreground, !quiescing else { return }
        activeEncryptionOperations += 1
        defer { activeEncryptionOperations -= 1 }
        guard let client, isConnected, encryptionReady, let session = sessionAccount,
              testSessionID == nil, session.domain == "staging.example.net" else {
            error = "Notification testing requires a connected staging account."
            return
        }
        let token = generation
        do {
            let deviceToken = try await PushRegistration.request()
            guard generation == token else { return }
            let push: XMPPPushConfiguration
            if let configured = session.push { push = configured }
            else if let saved = try PushRegistrationState.load(accountID: session.accountID) { push = saved.configuration }
            else {
                #if DEBUG
                let environment = ProcessInfo.processInfo.environment
                guard let node = environment["XMPP_PUSH_NODE"], let secret = environment["XMPP_PUSH_SECRET"] else {
                    throw XMPPNotificationError.invalidConfiguration
                }
                push = try XMPPPushConfiguration(serviceJID: "push.staging.example.net", node: node, publishOptions: ["secret": secret])
                #else
                throw XMPPNotificationError.invalidConfiguration
                #endif
            }
            let saved = NotificationAccount(accountID: session.accountID, host: session.host, port: session.port,
                domain: session.domain, username: session.username, password: session.password, push: push)
            // Save before enabling: an immediately arriving push can safely find its account.
            try saved.save()
            sessionAccount = saved
            try stagePushToken(deviceToken, account: session.accountID, configuration: push)
            try await sendPendingPushRegistration(client: client, account: session.accountID, token: token)
            guard generation == token else { return }
            try await client.enablePush(push)
            guard generation == token else { return }
            notificationStatus = "Enabled for staging"
            #if DEBUG
            if ProcessInfo.processInfo.arguments.contains("-push-diagnostics") {
                let directory = try FileManager.default.url(for: .documentDirectory, in: .userDomainMask, appropriateFor: nil, create: true)
                let data = try JSONEncoder().encode(["node": push.node, "device_token": deviceToken.map { String(format: "%02x", $0) }.joined()])
                try data.write(to: directory.appending(path: "push-registration.json"), options: [.atomic, .completeFileProtectionUntilFirstUserAuthentication])
                var privateFile = directory.appending(path: "push-registration.json")
                var values = URLResourceValues(); values.isExcludedFromBackup = true
                try privateFile.setResourceValues(values)
            }
            #endif
        } catch {
            guard generation == token else { return }
            notificationStatus = "Needs attention"
            self.error = "Notifications could not be enabled. Check notification permission and staging gateway configuration."
        }
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
        guard testSessionID == nil, let session = sessionAccount, let push = session.push else { return }
        let token = generation
        do {
            // A callback while offline still becomes durable work for this account's next
            // authenticated connection. Logout clears sessionAccount before any suspension.
            try stagePushToken(deviceToken, account: session.accountID, configuration: push)
            guard foreground, !quiescing, hasTransportOwnership, isConnected, let client else { return }
            activeEncryptionOperations += 1
            defer { activeEncryptionOperations -= 1 }
            try await sendPendingPushRegistration(client: client, account: session.accountID, token: token)
            guard generation == token else { return }
            try await client.enablePush(push)
            if generation == token { notificationStatus = "Enabled for staging" }
        } catch {
            if generation == token { notificationStatus = "Will retry on reconnect" }
        }
    }

    private func sendPendingPushRegistration(client: XMPPClient, account: String, token: UUID) async throws {
        for attempt in 0..<2 {
            guard generation == token, accountID == account else { throw CancellationError() }
            guard let state = try PushRegistrationState.load(accountID: account), let operation = state.journal.pending else { return }
            do {
                let result = try await client.updatePushRegistration(operation, configuration: state.configuration)
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

    private func refreshPushRegistration(client: XMPPClient, session: NotificationAccount, token: UUID) async {
        guard testSessionID == nil, hasTransportOwnership, foreground, !quiescing, generation == token else { return }
        activeEncryptionOperations += 1
        defer { activeEncryptionOperations -= 1 }
        do {
            if let state = try PushRegistrationState.load(accountID: session.accountID), state.journal.pending?.action == .revoke {
                try await sendPendingPushRegistration(client: client, account: session.accountID, token: token)
                guard generation == token else { return }
                try await client.disablePush(serviceJID: state.configuration.serviceJID, node: state.configuration.node)
                return
            }
            guard let push = session.push else { return }
            guard let deviceToken = try await PushRegistration.refreshIfAuthorized() else {
                notificationStatus = "Permission needed"
                return
            }
            guard generation == token, foreground, !quiescing else { return }
            try stagePushToken(deviceToken, account: session.accountID, configuration: push)
            try await sendPendingPushRegistration(client: client, account: session.accountID, token: token)
            guard generation == token else { return }
            try await client.enablePush(push)
            guard generation == token else { return }
            notificationStatus = "Enabled for staging"
        } catch {
            if generation == token { notificationStatus = "Will retry on reconnect" }
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
        messages = []
        messageReactions = [:]; messageReceipts = [:]
        attachmentFiles = [:]
        openChatID = nil
        encryptionOverviewChatID = nil; encryptionOverview = nil; encryptionDetailsChatID = nil
        pendingReviewChats = []; refreshFence = [:]
        uploadService = uploads.load(account: account)
        resetTyping()
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
                    let secret = try encryption.openAttachmentSecret(account: account, secret: attachment.secret)
                    let bytes = try await AttachmentDownloader.fetch(attachment, secret: secret)
                    let destination = files.cacheURL(attachment, messageID: message.id)
                    try files.write(bytes, to: destination)
                    guard let self, self.accountID == account, self.openChatID == chat else { return }
                    attachmentFiles[message.id] = destination
                } catch {
                    Logger(subsystem: "dev.xmpplab.ios", category: "attachments").error("Download of \(attachment.name, privacy: .public) failed: \(String(describing: error), privacy: .public)")
                }
            }
        }
    }

    private func resetSession() -> XMPPClient? {
        generation = UUID()
        drainTask?.cancel()
        eventTask?.cancel()
        eventTask = nil
        let previous = client
        client = nil
        reconnectTask?.cancel(); reconnectTask = nil
        session = .offline(reason: nil)
        inbound = nil
        for room in groupChats.keys { groupChats[room]?.joined = false }
        resetTyping()
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
                var step = "server features" { didSet { session = .connected(settingUp: step) } }
                session = .connected(settingUp: step)
                if let encryption, let client {
                    do {
                        let features = try await client.discoveryFeatures()
                        if features.contains("urn:xmpp:carbons:2") { step = "carbons"; try await client.setCarbonsEnabled() }
                        step = "file upload"
                        // Optional: a server without XEP-0363 just has no attach button. Only a completed answer changes
                        // what the button remembers; a discovery that throws keeps the last one.
                        let discovery: Result<XMPPUploadService?, any Error>
                        do { discovery = .success(try await client.uploadService()) } catch { discovery = .failure(error) }
                        guard generation == token else { return }
                        uploadService = uploads.settle(account: account, previous: uploadService, discovery: discovery)
                        step = "publishing this phone’s keys"
                        try await encryption.initialize(account: account, transport: client)
                        step = "rejoining groups"
                        try await rejoinKnownGroups(account: account, client: client, encryption: encryption, token: token)
                        if features.contains("urn:xmpp:mam:2"), let store {
                            step = "archive catch-up"
                            try await ArchiveSynchronizer(store: store).synchronize(account: account, client: client, encryption: encryption)
                        }
                        guard generation == token else { return }
                        session = .ready
                        reconnectAttempt = 0
                        reportedSetupFailure = nil
                        try? await encryption.retryPendingIncoming(account: account, transport: client)
                        guard generation == token else { return }
                        await flushEncryptionControls(account: account, client: client)
                        await refresh()
                        guard generation == token else { return }
                        startOutbox()
                        await reconcileUploads()
                        if let openChatID { await loadEncryptionDetails(for: openChatID) }
                        avatarChecked = []
                        await loadAvatar(for: account)
                    } catch {
                        guard generation == token else { return }
                        let detail: String
                        if case .stanza(let condition)? = error as? XMPPIQError { detail = condition }
                        else { detail = (error as? OMEMOError)?.errorDescription ?? String(describing: error).prefix(120).description }
                        Logger(subsystem: "dev.xmpplab.ios", category: "encryption").error("Encryption setup failed at \(step, privacy: .public): \(detail, privacy: .public)")
                        session = .needsAttention(step: step, detail: detail)
                        encryptionDiagnostics = "Setup failed at \(step): \(detail)"
                        if reportedSetupFailure != detail {
                            reportedSetupFailure = detail
                            self.error = "Could not prepare encryption (\(step): \(detail)). Your queued messages have not been sent."
                        }
                        await refresh()
                        guard generation == token else { return }
                        // A half-alive session is a connection failure: end it and let the reconciler retry.
                        await client.disconnect()
                    }
                }
            case .disconnected(let reason):
                for room in groupChats.keys { groupChats[room]?.joined = false }
                // Chat states belong to the stream that carried them.
                resetTyping()
                drainTask?.cancel()
                if case .needsAttention = session {} else { session = .offline(reason: reason) }
                reconcile()
            }
        case .chatState(let update):
            // A state never creates a chat: only listed chats (joined groups among them) show one.
            guard chats.contains(where: { $0.id == update.chat }) else { return }
            typingTracker.apply(update.state, chat: update.chat, participant: update.participant ?? update.chat, settles: update.ridesOnMessage, now: .now)
            publishTyping()
        case .reaction, .retraction, .receipt, .encryptedMessage, .encryptedGroupMessage, .streamManagementBarrier:
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
                switch outcome {
                case .stored:
                    await flushEncryptionControls(account: account, client: client)
                    guard generation == token else { return }
                    refreshSoon()
                case .retained(let problem):
                    encryptionNeedsReview = true
                    encryptionStatus = problem
                    await refresh()
                    guard generation == token else { return }
                    if let openChatID { await loadEncryptionDetails(for: openChatID, refreshFromServer: false) }
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
            if let openChatID, owner == openChatID || owner == accountID || groupChats[openChatID]?.members.contains(owner) == true {
                await loadEncryptionDetails(for: openChatID, force: true)
            }
        case .avatarMetadata(let owner, _):
            // The server pushed a change; re-fetch through the one lazy path so the hash check applies.
            avatarChecked.remove(owner)
            if owner == account || chats.contains(where: { $0.id == owner }) { await loadAvatar(for: owner) }
        case .encryptionFailure:
            encryptionStatus = "An encrypted message could not be opened"
        case .streamAcknowledged:
            refreshSoon()
        case .message:
            // Encrypted conversations do not render unauthenticated plaintext injected by a peer
            // or server as though it had passed OMEMO authentication.
            encryptionStatus = "An unencrypted message was blocked"

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
        }
    }
    func canSend(to chatID: String) -> Bool {
        guard isGroup(chatID) else { return true }
        return isConnected && encryptionReady && groupChats[chatID]?.joined == true
    }

    func joinGroup(room: String, nickname: String) async -> Bool {
        guard hasTransportOwnership, foreground, !quiescing, isConnected, encryptionReady,
              let client, let encryption, let store else { error = "Connect before joining a group."; return false }
        let room = room.trimmingCharacters(in: .whitespacesAndNewlines)
        let nickname = nickname.trimmingCharacters(in: .whitespacesAndNewlines)
        let domain = accountDomain
        let roomAllowed = isLabAccount ? room.hasSuffix("@rooms." + domain) : (room.contains("@") && !room.hasPrefix("@") && !room.hasSuffix("@"))
        guard roomAllowed, !room.contains("/"), !room.contains(where: { $0.isWhitespace }),
              !nickname.isEmpty else { error = isLabAccount ? "Enter a group address at rooms.\(domain) and a nickname." : "Enter a group address such as room@conference.example.org and a nickname."; return false }
        activeEncryptionOperations += 1
        defer { activeEncryptionOperations -= 1 }
        let account = accountID, token = generation
        do {
            let overview = try await encryption.refreshGroupDevices(account: account, room: room, transport: client)
            guard generation == token, foreground, !quiescing else { return false }
            groupChats[room] = GroupChatState(members: overview.room.members, devices: overview.devices)
            _ = try await client.joinGroupRoom(room, nickname: nickname)
            let confirmed = try await client.groupRoomSnapshot(room)
            guard generation == token, foreground, !quiescing else { return false }
            preferences.set(nickname, forKey: "groupNickname.\(account).\(room)")
            groupChats[room]?.joined = confirmed?.joined == true
            try await store.upsertChat(accountID: account, chatID: room, title: String(room.prefix { $0 != "@" }))
            guard generation == token else { return false }
            await refresh()
            return true
        } catch {
            if generation == token { self.error = groupFailure(error) }
            return false
        }
    }

    private func rejoinKnownGroups(account: String, client: XMPPClient, encryption: OMEMOService, token: UUID) async throws {
        let rooms = try await encryption.knownGroupRooms(account: account)
        for (room, members) in rooms.sorted(by: { $0.key < $1.key }) {
            guard generation == token, foreground, !quiescing else { throw CancellationError() }
            groupChats[room] = GroupChatState(members: members)
            let nickname = preferences.string(forKey: "groupNickname.\(account).\(room)") ?? String(account.prefix { $0 != "@" })
            do {
                let snapshot = try await client.joinGroupRoom(room, nickname: nickname)
                guard generation == token else { throw CancellationError() }
                groupChats[room]?.joined = snapshot.joined
            } catch {
                guard generation == token else { throw CancellationError() }
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
            encryptionDiagnostics = "Stored group devices could not be read: \(groupFailure(error))"
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
            encryptionDiagnostics = note
        } catch {
            guard generation == token, accountID == account, !(error is CancellationError) else { return }
            encryptionDiagnostics = "Last group refresh failed: \(groupFailure(error))"
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

    func createChat(_ recipient: String) async -> Bool {
        let recipient = recipient.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !accountID.isEmpty, recipient.contains("@"), !recipient.contains("/"),
              !recipient.contains(where: { $0.isWhitespace }), let store else {
            error = "Enter a contact address such as bob@localhost."
            return false
        }
        guard isDemo || !isLabAccount || recipient.hasSuffix("@" + accountDomain) else {
            error = "Lab accounts only message other accounts on the same lab server."
            return false
        }
        do {
            try await store.upsertChat(accountID: accountID, chatID: recipient, title: recipient)
            await refresh()
            return true
        } catch { self.error = "Could not create conversation."; return false }
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
        guard message.accountID == accountID, message.chatID == openChatID, message.isOutgoing, !message.isRetracted, !isGroup(message.chatID) else { return false }
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
                // Whether we ask for receipts and read markers is decided per send from the stored switches.
                let switches = try await store.accountPreferences(accountID: account)
                let preparation = try await encryption.prepareAvailableMessages(account: account, transport: client)
                if let self, self.generation == token, let issue = preparation.blockedChats[self.openChatID ?? ""] {
                    self.encryptionStatus = issue
                    self.encryptionNeedsReview = true
                }
                var preparedIDs = preparation.messageIDs
                for message in try await store.queuedOutgoing(accountID: account) where joinedGroups.contains(message.chatID) {
                    do {
                        try await encryption.prepareGroupMessage(account: account, messageID: message.id, room: message.chatID, transport: client)
                        preparedIDs.insert(message.id)
                        if let self, self.generation == token { self.groupChats[message.chatID]?.issue = nil }
                    } catch {
                        if error is CancellationError { throw error }
                        if let self, self.generation == token {
                            self.groupChats[message.chatID]?.issue = self.groupFailure(error)
                            if self.openChatID == message.chatID { self.encryptionStatus = self.groupFailure(error); self.encryptionNeedsReview = true }
                        }
                    }
                }
                try await outboxSender.drain(accountID: account, messageIDs: preparedIDs, send: { message in
                    if joinedGroups.contains(message.chatID) {
                        let prepared: PreparedGroupMessage
                        do { prepared = try await encryption.outgoingGroupEnvelope(account: account, messageID: message.id, room: message.chatID, transport: client) }
                        catch { throw OutboxSendFailure.notAttempted }
                        _ = try await client.sendEncryptedGroupMessage(room: message.chatID, envelope: prepared.envelope, id: message.id, expectedMembers: prepared.members)
                    } else {
                        let envelope: XMPPOMEMOEnvelope
                        do { envelope = try await encryption.outgoingEnvelope(account: account, messageID: message.id) }
                        catch { throw OutboxSendFailure.notAttempted }
                        _ = try await client.sendEncryptedMessage(to: message.chatID, envelope: envelope, id: message.id,
                                                                  requestReceipt: switches.deliveryReceipts, markable: switches.readReceipts)
                    }
                    try? await client.requestAcknowledgement()
                }, didChange: { [weak self] in
                    await self?.refresh()
                })
                // Everything that is not a chat message rides one queue: reactions (plain, encrypted,
                // group) and key transports. Preparation seals; the flush re-validates and sends.
                let updates = try await encryption.prepareAvailableUpdates(account: account, transport: client)
                if let self, self.generation == token, let issue = updates.blockedChats[self.openChatID ?? ""] {
                    self.encryptionStatus = issue
                    self.encryptionNeedsReview = true
                }
                var updateIDs = updates.messageIDs
                for update in try await store.queuedReactions(accountID: account) where joinedGroups.contains(update.chatID) {
                    do {
                        try await encryption.prepareGroupReaction(account: account, updateID: update.id, room: update.chatID, transport: client)
                        updateIDs.insert(update.id)
                    } catch {
                        if error is CancellationError { throw error }
                        if let self, self.generation == token {
                            self.groupChats[update.chatID]?.issue = self.groupFailure(error)
                            if self.openChatID == update.chatID { self.encryptionStatus = self.groupFailure(error); self.encryptionNeedsReview = true }
                        }
                    }
                }
                try await encryption.flushUpdates(account: account, updateIDs: updateIDs, groupTransport: client) { update, prepared in
                    switch prepared {
                    case .encrypted(let to, let envelope):
                        // A legacy correction carries its reference outside the ciphertext; the sealed target is the reference.
                        let replaces = update.kind == .correction && envelope.profile == .legacy ? update.targetWireID : nil
                        _ = try await client.sendEncryptedMessage(to: to, envelope: envelope, id: update.id, replaces: replaces)
                    case .group(let room, let envelope, let members):
                        _ = try await client.sendEncryptedGroupMessage(room: room, envelope: envelope, id: update.id, expectedMembers: members)
                    case .plainReaction(let to, let targetID, let reactions):
                        _ = try await client.sendReaction(to: to, targetID: targetID, reactions: reactions, id: update.id)
                    case .plainRetraction(let to, let targetID):
                        _ = try await client.sendRetraction(to: to, targetID: targetID, id: update.id)
                    case .plainReceipt(let to, let targetID, let kind):
                        _ = try await client.sendReceipt(to: to, targetID: targetID, kind: kind, id: update.id)
                    }
                    try? await client.requestAcknowledgement()
                }
                await self?.refresh()
            } catch {
                if let self, self.generation == token {
                    self.encryptionNeedsReview = true
                    self.encryptionStatus = (error as? OMEMOError)?.errorDescription ?? "Encryption could not be prepared. Messages remain saved."
                    if let chat = self.openChatID { await self.loadEncryptionDetails(for: chat, refreshFromServer: false) }
                }
            }
            guard let self else { return }
            self.drainTask = nil
            // A different account/session may have become ready while this attempt settled.
            if self.outboxRequested || self.generation != token { self.startOutbox() }
        }
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

    private func routeNotification(_ destination: NotificationDestination) async {
        guard testSessionID == nil, !isDemo,
              !ProcessInfo.processInfo.arguments.contains("--inspect-notification"), let store else { return }
        let account = accountID
        do {
            guard let authorization = try NotificationAccount.load(), authorization.push != nil,
                  authorization.accountID == account, sessionAccount?.accountID == account,
                  let message = try await destination.resolve(accountID: account, active: true, store: store),
                  accountID == account, sessionAccount?.accountID == account,
                  try NotificationAccount.load() == authorization else { return }
            notificationRoute = NotificationChatRoute(accountID: account, chatID: message.chatID)
        } catch {
            // A tap never prompts for another account, creates a chat or changes endpoints.
        }
    }

    func openChat(_ chatID: String) async {
        openChatID = chatID; timelineWindow = AppModel.timelinePage; messages = []; messagesLoadedFor = nil; messageReactions = [:]; messageReceipts = [:]; attachmentFiles = [:]
        // Keep the same chat's devices across pop-back and reconnect; another chat starts pending until its store read.
        if encryptionOverviewChatID != chatID { encryptionOverviewChatID = chatID; encryptionOverview = nil }
        encryptionDetailsChatID = chatID
        // First paint: the newest screenful now, before the chat list and the rest of the history.
        let account = accountID
        if let store, let publish = try? await loadTimeline(store: store, account: account, chat: chatID, isGroup: isGroup(chatID), limit: 50),
           accountID == account, openChatID == chatID, messagesLoadedFor != chatID { publish() }
        await refresh()
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
                encryptionDiagnostics = Self.storedDevicesUnreadable
            }
        }
        guard refreshFromServer else { return }
        if !force, profile == nil, let fence = refreshFence[chatID], fence.generation == token {
            encryptionDiagnostics = fence.note
            return
        }
        guard hasTransportOwnership, encryptionReady, isConnected, let client else {
            if !encryptionDiagnostics.hasPrefix("Setup failed") {
                encryptionDiagnostics = isConnected ? "Not refreshed: encryption setup has not completed on this connection." : "Not refreshed: offline."
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
                let active = overview.devices.filter { $0.jid == owner && $0.active && !(owner == account && $0.deviceID == overview.localDeviceID) }.count
                return "\(name): \(advertised) advertised, \(active) usable" + (missing > 0 ? ", \(missing) without keys" : "")
            }.joined(separator: " · ")
            let note = "Last refresh (\(overview.profile == .legacy ? "OMEMO · compatible" : "OMEMO 2")): \(summary)"
            refreshFence[chatID] = (token, note)
            encryptionDiagnostics = note
            Logger(subsystem: "dev.xmpplab.ios", category: "encryption").info("Device refresh: \(summary, privacy: .public)")
        } catch {
            guard isCurrent else { return }
            let detail: String
            if case .stanza(let condition)? = error as? XMPPIQError { detail = condition } else { detail = String(describing: error).prefix(80).description }
            Logger(subsystem: "dev.xmpplab.ios", category: "encryption").error("Device refresh for \(chatID, privacy: .private) failed: \(detail, privacy: .public)")
            let friendly: String
            switch detail {
            case "remote-server-not-found", "remote-server-timeout": friendly = "Their server could not be reached. Try again in a moment."
            case "forbidden", "not-authorized", "not-allowed": friendly = "Their server refused to share their devices."
            default: friendly = "Could not fetch encryption devices."
            }
            encryptionDiagnostics = "Last refresh failed (\(detail)). \((error as? OMEMOError)?.errorDescription ?? friendly)"
        }
    }

    static let storedDevicesUnreadable = "Stored devices could not be read. Nothing was changed."

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
            await loadEncryptionDetails(for: chatID, refreshFromServer: isGroup(chatID))
            guard generation == token else { return }
            if let client, isConnected {
                try? await encryption.retryPendingIncoming(account: account, transport: client)
                guard generation == token else { return }
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
            await loadEncryptionDetails(for: chatID)
        } catch {
            if generation == token { self.error = (error as? OMEMOError)?.errorDescription ?? "Could not remove this device. Refresh its fingerprint and try again." }
        }
    }
    private func flushEncryptionControls(account: String, client: XMPPClient) async {
        guard accountID == account, self.client === client else { return }
        try? await encryption?.flushBundlePublications(account: account, transport: client)
        // Key transports are ordinary durable updates; the outbox drain sends them.
        startOutbox()
    }

    /// The reader reached the oldest loaded message. A full window means the store may hold more.
    func loadOlderMessages(all: Bool = false) async {
        guard !loadingOlder, openChatID != nil, timelineWindow < AppModel.timelineCeiling, all || messages.count >= timelineWindow else { return }
        loadingOlder = true
        defer { loadingOlder = false }
        timelineWindow = all ? AppModel.timelineCeiling : min(AppModel.timelineCeiling, timelineWindow + AppModel.timelinePage)
        await refresh(.openChat)
    }

    func closeChat(_ chatID: String) {
        if ownTyping?.chat == chatID { sendOwnTyping(ownTyping?.sender.left(), to: chatID); ownTyping = nil; ownTypingPause?.cancel() }
        if openChatID == chatID { openChatID = nil; messages = []; messagesLoadedFor = nil; messageReactions = [:]; messageReceipts = [:]; attachmentFiles = [:] }
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
        !isDemo && session.isReady && hasTransportOwnership && foreground && !quiescing && !encryptionNeedsReview
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
            if accountID == account { accountPreferences = updated; notificationPreviewsEnabled = updated.notificationPreviews }
        } catch { self.error = "Could not save preferences." }
    }

    /// The timeline showed the newest received message while the app is in front: queue the read marker.
    func markDisplayed(_ messageID: String) async {
        guard foreground, !quiescing, hasTransportOwnership, !isDemo, let encryption,
              let message = messages.first(where: { $0.id == messageID }), !message.isOutgoing, message.chatID == openChatID,
              message.encryptionProfile == "modern" || message.encryptionProfile == "legacy" else { return }
        activeEncryptionOperations += 1
        defer { activeEncryptionOperations -= 1 }
        let account = accountID, token = generation
        let queued = (try? await encryption.queueReceipt(account: account, chatID: message.chatID, messageID: messageID, kind: .marker)) ?? nil
        guard queued != nil, generation == token else { return }
        startOutbox()
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

    @ObservationIgnored private lazy var reload = CoalescedReload { [weak self] scope in await self?.load(scope) }

    /// Returns after a load that started after this call; concurrent calls share one follow-up load.
    private func refresh(_ scope: CoalescedReload.Scope = .all) async { await reload.request(scope) }

    /// The event loop handles one event at a time, so awaiting there would serialise a burst into one load each.
    /// Counted as an operation so a background transition still joins it before releasing the lease.
    private func refreshSoon(_ scope: CoalescedReload.Scope = .all) {
        activeEncryptionOperations += 1
        Task { await refresh(scope); activeEncryptionOperations -= 1 }
    }

    /// Reads one chat's newest messages with their projected events; the caller checks its fences, then publishes.
    private func loadTimeline(store: MessageStore, account: String, chat: String, isGroup: Bool, limit: Int) async throws -> @MainActor () -> Void {
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
        return { [self] in
            messages = storedMessages.map { $0.applying(events[$0.id] ?? []) }
            messagesLoadedFor = chat
            messageReactions = reactions
            messageReceipts = receipts
            reactableGroupMessages = groupReactionTargets
            loadAttachments(storedMessages, chat: chat)
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
            if scope.contains(.chats) { try await loadChats(store: store, account: account) }
            guard scope.contains(.openChat), accountID == account, let selected = openChatID else { return }
            // Every chat-list load, join and rejoin mirrors the known rooms into groupChats.
            let publish = try await loadTimeline(store: store, account: account, chat: selected, isGroup: isGroup(selected), limit: timelineWindow)
            // A chat opened meanwhile requests its own load.
            guard accountID == account, openChatID == selected else { return }
            publish()
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
        pendingReviewChats = Set(pending.keys)
        accountPreferences = try await store.accountPreferences(accountID: account)
        notificationPreviewsEnabled = accountPreferences.notificationPreviews
        if foreground, hasTransportOwnership, !quiescing {
            try await store.dismissPendingMessageNotifications(accountID: account)
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
            preview: pending[$0.id] != nil ? reviewPreview : ($0.lastMessage.map { $0.isRetracted ? "Message unsent" : ($0.body.isEmpty ? ($0.attachment?.kindLabel ?? "") : $0.body) } ?? ""), isPinned: $0.isPinned, avatarHash: $0.avatarHash,
            lastMessageAt: $0.lastMessage?.sentAt, lastMessageIsOutgoing: $0.lastMessage?.isOutgoing ?? false,
            lastMessageState: $0.lastMessage?.transportState, lastMessageReceipt: $0.lastMessageReceipt) }
        summaries += pending.keys.filter { !known.contains($0) }.sorted().map {
            ChatSummary(id: $0, title: $0, preview: reviewPreview, isPinned: false)
        }
        // A reorder (pin, new activity) animates; List only does so inside an explicit transaction.
        withAnimation(summaries.map(\.id) == chats.map(\.id) ? nil : .default) { chats = summaries }
    }
}
