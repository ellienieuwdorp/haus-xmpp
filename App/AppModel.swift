import Foundation
import UIKit
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
}

typealias ChatMessage = StoredMessage

@MainActor @Observable
final class AppModel {
    private(set) var chats: [ChatSummary] = []
    private(set) var messages: [ChatMessage] = []
    private(set) var messageReactions: [String: [AuthenticatedReaction]] = [:]
    private(set) var accountID = ""
    private(set) var connectionStatus = "Offline"
    private(set) var isConnecting = false
    private(set) var isConnected = false
    private(set) var isSending = false
    private(set) var receivedCount = 0
    var error: String?
    private(set) var notificationStatus = "Not enabled"
    @ObservationIgnored private var sessionAccount: NotificationAccount?
    @ObservationIgnored private var lifecycleTask: Task<Void, Never>?
    @ObservationIgnored private var foreground = true
    @ObservationIgnored private var quiescing = false
    @ObservationIgnored private var activeEncryptionOperations = 0
    @ObservationIgnored private var acquiringOwnership = false
    @ObservationIgnored private var hasTransportOwnership = false
    private(set) var encryptionReady = false
    private(set) var encryptionStatus = "Preparing encryption…"
    private(set) var encryptionOverview: EncryptionOverview?
    private(set) var encryptionNeedsReview = false
    @ObservationIgnored private var encryption: OMEMOService?
    var isDemo: Bool { accountID == "preview.local" }

    @ObservationIgnored private var store: MessageStore?
    @ObservationIgnored private var outboxSender: OutboxSender?
    @ObservationIgnored private var outboxRequested = false
    @ObservationIgnored private var drainTask: Task<Void, Never>?
    @ObservationIgnored private var client: XMPPClient?
    @ObservationIgnored private var eventTask: Task<Void, Never>?
    @ObservationIgnored private var openChatID: String?
    @ObservationIgnored private var generation = UUID()
    @ObservationIgnored private var prepared = false
    @ObservationIgnored private var inboundMayAcknowledge = true
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
        do {
            let directory = try await SharedStorage.directory(testSessionID: testSessionID, migrate: true)
            store = try MessageStore(url: directory.appending(path: "messages.sqlite"))
            if let store {
                outboxSender = OutboxSender(store: store)
                let allowCreation = try await !store.hasAnyEncryptionState()
                let wrappingKey = try EncryptionKeychain.load(storageID: testSessionID ?? "primary", allowCreation: allowCreation)
                encryption = OMEMOService(store: store, protection: try StateProtection(key: wrappingKey))
            }
            accountID = preferences.string(forKey: "lastAccount") ?? ""
            if ProcessInfo.processInfo.arguments.contains("-demo") { await loadDemo() }
            else {
                if let store, try await NotificationDiagnostics.exportIfRequested(store: store, directory: directory) { return }
                await refresh()
                if testSessionID == nil, let saved = try NotificationAccount.load() {
                    sessionAccount = saved
                    notificationStatus = "Configured for staging"
                    _ = await connect(username: saved.username, password: saved.password, savedEndpoint: saved)
                }
            }
        } catch { self.error = "Could not open local message storage." }
    }

    func loadDemo() async {
        await disconnect()
        let token = generation
        let account = "preview.local"
        selectAccount(account)
        guard generation == token, let store else { return }
        do {
            let samples: [(String, String, [String])] = [
                ("alex@preview.local", "Alex", ["Found a quiet spot by the water. Coffee tomorrow?", "That sounds perfect. Around ten?", "Ten it is ☕️"]),
                ("maya@preview.local", "Maya", ["A little reminder to take the scenic route.", "Always. See you this weekend!"]),
                ("notes@preview.local", "Notes to self", ["A place for the things worth keeping. Try starring this message."])
            ]
            for (chatID, title, bodies) in samples {
                try await store.upsertChat(accountID: account, chatID: chatID, title: title)
                for (index, body) in bodies.enumerated() {
                    let outgoing = index == 1
                    try await store.insertMessage(StoredMessage(
                        id: "sample-\(chatID)-\(index)", accountID: account, chatID: chatID,
                        senderID: outgoing ? account : chatID, body: body,
                        sentAt: Date(timeIntervalSince1970: 1_789_380_000 + Double(index)), isOutgoing: outgoing
                    ))
                }
            }
            guard generation == token else { return }
            await refresh()
        } catch { if generation == token { self.error = "Could not load sample conversations." } }
    }

    func connect(username: String, password: String, savedEndpoint: NotificationAccount? = nil) async -> Bool {
        guard foreground, !quiescing, !isConnecting, username.range(of: #"^[a-z0-9][a-z0-9._-]{0,63}$"#, options: .regularExpression) != nil else {
            error = "Use a simple local lab username, without @localhost."
            return false
        }
        let requestedDomain = savedEndpoint?.domain ?? DevelopmentEndpoint.domain
        if let sessionAccount, sessionAccount.accountID != username + "@" + requestedDomain {
            await disconnect()
            guard foreground, !quiescing else { return false }
        }
        let priorEvents = eventTask
        let previous = resetSession()
        let token = generation
        isConnecting = true
        connectionStatus = "Connecting…"
        let connection = XMPPClient(labCertificateAuthority: DevelopmentEndpoint.certificateAuthority)
        client = connection
        // Assign account before consuming events; scoped refresh rejects stale results.
        let endpoint = savedEndpoint ?? Self.retainingPushSubscription(previous: sessionAccount, replacement: NotificationAccount(accountID: username + "@" + DevelopmentEndpoint.domain,
            host: DevelopmentEndpoint.host, port: 5223, domain: DevelopmentEndpoint.domain,
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
            if endpoint.push != nil {
                // Authentication has succeeded. Only now may a manually entered password
                // replace the extension's previously working protected credentials.
                do { try endpoint.save() }
                catch {
                    notificationStatus = "Needs attention"
                    self.error = "Connected, but background credentials could not be saved. Enable notifications again before leaving the app."
                }
            }
            isConnecting = false
            return true
        } catch {
            guard generation == token else { await connection.disconnect(); return false }
            isConnecting = false
            isConnected = false
            connectionStatus = "Connection failed"
            self.error = "Could not connect. Check the server and account password."
            return false
        }
    }

    func disconnect() async {
        quiescing = true
        generation = UUID() // Invalidate pending permission/registration before removing credentials.
        let token = generation
        let push = sessionAccount?.push
        let connection = client
        try? NotificationAccount.remove()
        sessionAccount = nil
        notificationStatus = "Not enabled"
        if let push, let connection, isConnected {
            activeEncryptionOperations += 1
            defer { activeEncryptionOperations -= 1 }
            do { try await connection.disablePush(serviceJID: push.serviceJID, node: push.node) }
            catch {
                if generation == token { self.error = "Could not disable the server push subscription. Background access has been removed from this phone." }
            }
        }
        guard generation == token else { return }
        await quiesceTransport()
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
                if let saved = self.sessionAccount, !self.isConnected, !self.isConnecting {
                    _ = await self.connect(username: saved.username, password: saved.password, savedEndpoint: saved)
                }
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
            #if DEBUG
            let environment = ProcessInfo.processInfo.environment
            guard let node = environment["XMPP_PUSH_NODE"], let secret = environment["XMPP_PUSH_SECRET"] else {
                throw XMPPNotificationError.invalidConfiguration
            }
            let push = try XMPPPushConfiguration(serviceJID: "push.staging.example.net", node: node, publishOptions: ["secret": secret])
            let saved = NotificationAccount(accountID: session.accountID, host: session.host, port: session.port,
                domain: session.domain, username: session.username, password: session.password, push: push)
            // Save before enabling: an immediately arriving push can safely find its account.
            try saved.save()
            try await client.enablePush(push)
            guard generation == token else { return }
            sessionAccount = saved
            notificationStatus = "Enabled for staging"
            if ProcessInfo.processInfo.arguments.contains("-push-diagnostics") {
                let directory = try FileManager.default.url(for: .documentDirectory, in: .userDomainMask, appropriateFor: nil, create: true)
                let data = try JSONEncoder().encode(["node": node, "device_token": deviceToken.map { String(format: "%02x", $0) }.joined()])
                try data.write(to: directory.appending(path: "push-registration.json"), options: [.atomic, .completeFileProtectionUntilFirstUserAuthentication])
                var privateFile = directory.appending(path: "push-registration.json")
                var values = URLResourceValues(); values.isExcludedFromBackup = true
                try privateFile.setResourceValues(values)
            }
            #else
            _ = deviceToken
            throw XMPPNotificationError.invalidConfiguration
            #endif
        } catch {
            guard generation == token else { return }
            notificationStatus = "Needs attention"
            self.error = "Notifications could not be enabled. Check notification permission and staging gateway configuration."
        }
    }

    private func selectAccount(_ account: String) {
        accountID = account
        chats = []
        messages = []
        messageReactions = [:]
        openChatID = nil
        preferences.set(account, forKey: "lastAccount")
    }

    private func resetSession() -> XMPPClient? {
        generation = UUID()
        drainTask?.cancel()
        eventTask?.cancel()
        eventTask = nil
        let previous = client
        client = nil
        isConnected = false
        isConnecting = false
        connectionStatus = "Offline"
        encryptionReady = false
        encryptionOverview = nil
        encryptionNeedsReview = false
        encryptionStatus = "Connect to prepare encryption"
        inboundMayAcknowledge = true
        return previous
    }

    private func handle(_ event: XMPPEvent, token: UUID) async {
        let account = accountID
        switch event {
        case .state(let state):
            switch state {
            case .connecting: connectionStatus = "Connecting…"
            case .authenticating: connectionStatus = "Signing in…"
            case .binding: connectionStatus = "Opening session…"
            case .online:
                connectionStatus = "Connected to lab"; isConnected = true; isConnecting = false
                if let encryption, let client {
                    do {
                        let features = try await client.discoveryFeatures()
                        if features.contains("urn:xmpp:carbons:2") { try await client.setCarbonsEnabled() }
                        try await encryption.initialize(account: account, transport: client)
                        if features.contains("urn:xmpp:mam:2"), let store {
                            connectionStatus = "Catching up…"
                            try await ArchiveSynchronizer(store: store).synchronize(account: account, client: client, encryption: encryption)
                        }
                        guard generation == token else { return }
                        encryptionReady = true
                        connectionStatus = "Connected to lab"
                        encryptionStatus = "End-to-end encryption"
                        try? await encryption.retryPendingIncoming(account: account, transport: client)
                        guard generation == token else { return }
                        await flushEncryptionControls(account: account, client: client)
                        await refresh()
                        guard generation == token else { return }
                        startOutbox()
                        if let openChatID { await loadEncryptionDetails(for: openChatID) }
                    } catch {
                        guard generation == token else { return }
                        encryptionStatus = "Encryption setup needs attention"
                        self.error = "Could not prepare encryption. Your queued messages have not been sent."
                    }
                }
            case .disconnected(let reason):
                drainTask?.cancel()
                connectionStatus = "Offline"; isConnected = false; isConnecting = false
                if reason != nil { error = "The lab connection ended. Delivery of any in-flight message is unconfirmed." }
            }
        case .encryptedMessage(let incoming):
            receivedCount += 1
            guard let encryption, let client else { return }
            do {
                _ = try await encryption.receive(account: account, message: incoming, transport: client)
                guard generation == token else { return }
                await flushEncryptionControls(account: account, client: client)
                guard generation == token else { return }
                await refresh()
            } catch {
                guard generation == token else { return }
                let mayAcknowledge = (try? await encryption.hasDurableIncomingDisposition(account: account, message: incoming)) ?? false
                guard generation == token else { return }
                inboundMayAcknowledge = mayAcknowledge
                encryptionNeedsReview = true
                encryptionStatus = (error as? OMEMOError)?.errorDescription ?? "An encrypted message needs attention"
                await refresh()
                guard generation == token else { return }
                if let openChatID { await loadEncryptionDetails(for: openChatID, refreshFromServer: false) }
            }
        case .omemoDevices(let owner, let profile, _):
            if owner == account, let encryption, let client {
                try? await encryption.maintainLocalAdvertisement(account: account, profile: profile, transport: client)
            }
            if let openChatID, owner == openChatID || owner == accountID {
                await loadEncryptionDetails(for: openChatID)
            }
        case .encryptionFailure:
            encryptionStatus = "An encrypted message could not be opened"
        case .streamAcknowledged:
            await refresh()
        case .streamManagementBarrier(let barrier):
            guard let client else { return }
            if inboundMayAcknowledge {
                do { try await client.acknowledgeInbound(barrier) }
                catch {
                    await client.disconnect()
                    guard generation == token else { return }
                    self.error = "Could not save synchronization progress. Reconnect to recover safely."
                }
            } else {
                await client.disconnect()
                guard generation == token else { return }
                self.error = "An incoming message could not be saved. Reconnect after checking local storage."
            }
            guard generation == token else { return }
            inboundMayAcknowledge = true
        case .message:
            // Encrypted conversations do not render unauthenticated plaintext injected by a peer
            // or server as though it had passed OMEMO authentication.
            encryptionStatus = "An unencrypted message was blocked"

        }
    }

    func createChat(_ recipient: String) async -> Bool {
        let recipient = recipient.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !accountID.isEmpty, recipient.contains("@"), !recipient.contains("/"),
              !recipient.contains(where: { $0.isWhitespace }), let store else {
            error = "Enter a contact address such as bob@localhost."
            return false
        }
        guard isDemo || recipient.hasSuffix("@" + (sessionAccount?.domain ?? DevelopmentEndpoint.domain)) else {
            error = "This development build only sends to local lab accounts."
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
        guard sample || chatID.hasSuffix("@" + (sessionAccount?.domain ?? DevelopmentEndpoint.domain)) else { return false }
        if let source, source.accountID != account || source.chatID != chatID { return false }
        let reply = source.map { MessageReply(messageID: $0.id, senderID: $0.senderID, body: $0.body, wireID: $0.isOutgoing && $0.transportState != nil ? $0.id : nil) }
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
            await refresh()
            startOutbox()
        } catch { self.error = "This message could not be queued again." }
    }

    private nonisolated static func wireReply(_ reply: MessageReply?) -> XMPPReply? {
        reply.map { XMPPReply(id: $0.wireID, to: $0.senderID, body: $0.body) }
    }

    func canReact(to message: StoredMessage) -> Bool {
        message.accountID == accountID && message.chatID == openChatID && message.encryptionProfile == "modern"
            && message.wireIDAuthenticated && message.wireID != nil && encryptionOverview?.profile == .modern
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
            await refresh()
            startOutbox()
        } catch {
            if generation == token { self.error = (error as? OMEMOError)?.errorDescription ?? "Could not save your reaction." }
        }
    }

    private func startOutbox() {
        outboxRequested = true
        guard hasTransportOwnership, foreground, !quiescing, drainTask == nil, isConnected, encryptionReady, !isDemo,
              let client, let outboxSender, let encryption else { return }
        outboxRequested = false
        let account = accountID
        let token = generation
        drainTask = Task { [weak self] in
            do {
                let preparation = try await encryption.prepareAvailableMessages(account: account, transport: client)
                if let self, self.generation == token, let issue = preparation.blockedChats[self.openChatID ?? ""] {
                    self.encryptionStatus = issue
                    self.encryptionNeedsReview = true
                }
                try await outboxSender.drain(accountID: account, messageIDs: preparation.messageIDs, send: { message in
                    let envelope: XMPPOMEMOEnvelope
                    do { envelope = try await encryption.outgoingEnvelope(account: account, messageID: message.id) }
                    catch { throw OutboxSendFailure.notAttempted }
                    _ = try await client.sendEncryptedMessage(to: message.chatID, envelope: envelope, id: message.id)
                    try? await client.requestAcknowledgement()
                }, didChange: { [weak self] in
                    await self?.refresh()
                })
                let reactions = try await encryption.prepareAvailableReactions(account: account, transport: client)
                if let self, self.generation == token, let issue = reactions.blockedChats[self.openChatID ?? ""] {
                    self.encryptionStatus = issue
                    self.encryptionNeedsReview = true
                }
                try await encryption.flushPreparedReactions(account: account, preparedIDs: reactions.messageIDs) { to, id, envelope in
                    _ = try await client.sendEncryptedMessage(to: to, envelope: envelope, id: id)
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

    func openChat(_ chatID: String) async {
        openChatID = chatID; messages = []; messageReactions = [:]; encryptionOverview = nil
        await refresh()
        if !isDemo { await loadEncryptionDetails(for: chatID) }
    }

    func loadEncryptionDetails(for chatID: String, refreshFromServer: Bool = true, profile: XMPPOMEMOProfile? = nil) async {
        guard foreground, !quiescing else { return }
        activeEncryptionOperations += 1
        defer { activeEncryptionOperations -= 1 }
        guard let encryption, !isDemo else { return }
        let account = accountID
        let token = generation
        do {
            let overview: EncryptionOverview
            if refreshFromServer, hasTransportOwnership, encryptionReady, isConnected, let client {
                overview = try await encryption.refreshDevices(account: account, peer: chatID, profile: profile, transport: client)
            } else { overview = try await encryption.overview(account: account, peer: chatID) }
            guard accountID == account, generation == token, openChatID == chatID else { return }
            encryptionOverview = overview
            encryptionNeedsReview = overview.needsTrust
            if overview.hasIncompatibleDevices { encryptionStatus = "Devices use incompatible encryption versions" }
            else if overview.needsTrust { encryptionStatus = "Review encryption devices" }
            else if !overview.devices.contains(where: { $0.jid == chatID && $0.active && $0.trust.permitsEncryption }) {
                encryptionStatus = "No compatible encryption devices"
            } else { encryptionStatus = "New messages are end-to-end encrypted" }
        } catch {
            guard accountID == account, generation == token, openChatID == chatID else { return }
            encryptionStatus = (error as? OMEMOError)?.errorDescription ?? "Could not fetch encryption devices"
        }
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
            await loadEncryptionDetails(for: chatID, refreshFromServer: false)
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
        try? await encryption?.flushKeyTransports(account: account) { to, id, envelope in
            _ = try await client.sendEncryptedMessage(to: to, envelope: envelope, id: id)
            try? await client.requestAcknowledgement()
        }
    }

    func closeChat(_ chatID: String) { if openChatID == chatID { openChatID = nil; messages = []; messageReactions = [:] } }

    func toggleStar(_ id: String) async {
        guard let message = messages.first(where: { $0.id == id }), let store else { return }
        do {
            try await store.setStarred(accountID: accountID, messageID: id, starred: !message.isStarred)
            await refresh()
        } catch { self.error = "Could not update starred message." }
    }

    func togglePin(_ chat: ChatSummary) async {
        guard let store else { return }
        do {
            try await store.setPinned(accountID: accountID, chatID: chat.id, pinned: !chat.isPinned)
            await refresh()
        } catch { self.error = "Could not update pinned conversation." }
    }

    private func refresh() async {
        guard let store else { return }
        let account = accountID
        let selected = openChatID
        do {
            let storedChats = try await store.chats(accountID: account)
            let pending = try await encryption?.pendingConversations(account: account) ?? [:]
            let existingChatIDs = Set(storedChats.map(\.id))
            for peer in pending.keys where !existingChatIDs.contains(peer) {
                // A retained first-contact message needs a discoverable review entry and
                // a durable conversation for pinning or queuing a reply before approval.
                try await store.upsertChat(accountID: account, chatID: peer, title: peer)
            }
            let storedMessages: [StoredMessage]
            if let selected {
                storedMessages = try await store.messages(accountID: account, chatID: selected, limit: 1000)
            } else { storedMessages = [] }
            let reactions: [String: [AuthenticatedReaction]]
            if let selected {
                reactions = try await store.reactionsForChat(accountID: account, chatID: selected, messageIDs: Set(storedMessages.map(\.id)))
            } else { reactions = [:] }
            guard accountID == account, openChatID == selected else { return }
            let known = Set(storedChats.map(\.id))
            let reviewPreview = "Encrypted message needs attention"
            chats = storedChats.map { ChatSummary(id: $0.id, title: $0.title,
                preview: pending[$0.id] != nil ? reviewPreview : ($0.lastMessage?.body ?? ""), isPinned: $0.isPinned) }
            chats += pending.keys.filter { !known.contains($0) }.sorted().map {
                ChatSummary(id: $0, title: $0, preview: reviewPreview, isPinned: false)
            }
            messages = storedMessages
            messageReactions = reactions
        } catch { self.error = "Could not read local conversations." }
    }
}
