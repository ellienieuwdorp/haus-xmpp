import Foundation
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
    private(set) var accountID = ""
    private(set) var connectionStatus = "Offline"
    private(set) var isConnecting = false
    private(set) var isConnected = false
    private(set) var isSending = false
    private(set) var receivedCount = 0
    var error: String?
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
            var directory = try FileManager.default.url(for: .applicationSupportDirectory, in: .userDomainMask, appropriateFor: nil, create: true)
                .appending(path: "Messaging", directoryHint: .isDirectory)
            if let testSessionID { directory.append(path: "UITests/" + testSessionID) }
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true,
                                                   attributes: [.protectionKey: FileProtectionType.completeUntilFirstUserAuthentication])
            var excluded = directory
            var values = URLResourceValues()
            values.isExcludedFromBackup = true
            try excluded.setResourceValues(values)
            store = try MessageStore(url: directory.appending(path: "messages.sqlite"))
            if let store {
                outboxSender = OutboxSender(store: store)
                let allowCreation = try await !store.hasAnyEncryptionState()
                let wrappingKey = try EncryptionKeychain.load(storageID: testSessionID ?? "primary", allowCreation: allowCreation)
                encryption = OMEMOService(store: store, protection: try StateProtection(key: wrappingKey))
            }
            accountID = preferences.string(forKey: "lastAccount") ?? ""
            if ProcessInfo.processInfo.arguments.contains("-demo") { await loadDemo() }
            else { await refresh() }
        } catch { self.error = "Could not open local message storage." }
    }

    func loadDemo() async {
        let previous = resetSession()
        let token = generation
        let account = "preview.local"
        selectAccount(account)
        await previous?.disconnect()
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

    func connect(username: String, password: String) async -> Bool {
        guard !isConnecting, username.range(of: #"^[a-z0-9][a-z0-9._-]{0,63}$"#, options: .regularExpression) != nil else {
            error = "Use a simple local lab username, without @localhost."
            return false
        }
        let previous = resetSession()
        let token = generation
        isConnecting = true
        connectionStatus = "Connecting…"
        let connection = XMPPClient()
        client = connection
        // Assign account before consuming events; scoped refresh rejects stale results.
        selectAccount(username + "@localhost")
        await previous?.disconnect()
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
            try await connection.connect(host: "localhost", port: 5223, domain: "localhost", username: username, password: password)
            guard generation == token else { return false }
            isConnecting = false
            return true
        } catch {
            guard generation == token else { return false }
            isConnecting = false
            isConnected = false
            connectionStatus = "Connection failed"
            self.error = "Could not connect. Check the lab is running, the account password and the simulator's trusted lab certificate."
            return false
        }
    }

    func disconnect() async {
        let previous = resetSession()
        await previous?.disconnect()
    }

    private func selectAccount(_ account: String) {
        accountID = account
        chats = []
        messages = []
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
                        guard generation == token else { return }
                        encryptionReady = true
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
                encryptionNeedsReview = true
                encryptionStatus = (error as? OMEMOError)?.errorDescription ?? "An encrypted message needs attention"
                if let openChatID { await loadEncryptionDetails(for: openChatID, refreshFromServer: false) }
            }
        case .omemoDevices(let owner, _, _):
            if let openChatID, owner == openChatID || owner == accountID {
                await loadEncryptionDetails(for: openChatID)
            }
        case .encryptionFailure:
            encryptionStatus = "An encrypted message could not be opened"
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
        guard isDemo || recipient.hasSuffix("@localhost") else {
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
        guard sample || chatID.hasSuffix("@localhost") else { return false }
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

    private func startOutbox() {
        outboxRequested = true
        guard drainTask == nil, isConnected, encryptionReady, !isDemo,
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
                }, didChange: { [weak self] in
                    await self?.refresh()
                })
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
        openChatID = chatID; messages = []; encryptionOverview = nil
        await refresh()
        if !isDemo { await loadEncryptionDetails(for: chatID) }
    }

    func loadEncryptionDetails(for chatID: String, refreshFromServer: Bool = true, profile: XMPPOMEMOProfile? = nil) async {
        guard let encryption, !isDemo else { return }
        let account = accountID
        let token = generation
        do {
            let overview: EncryptionOverview
            if refreshFromServer, encryptionReady, isConnected, let client {
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
            guard accountID == account, generation == token else { return }
            encryptionStatus = (error as? OMEMOError)?.errorDescription ?? "Could not fetch encryption devices"
        }
    }

    func setDeviceTrust(_ device: EncryptionDevice, trust: DeviceTrust, chatID: String) async {
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
    private func flushEncryptionControls(account: String, client: XMPPClient) async {
        guard accountID == account, self.client === client else { return }
        try? await encryption?.flushKeyTransports(account: account) { to, id, envelope in
            _ = try await client.sendEncryptedMessage(to: to, envelope: envelope, id: id)
        }
    }

    func closeChat(_ chatID: String) { if openChatID == chatID { openChatID = nil; messages = [] } }

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
            let storedMessages: [StoredMessage]
            if let selected {
                storedMessages = try await store.messages(accountID: account, chatID: selected, limit: 1000)
            } else { storedMessages = [] }
            guard accountID == account, openChatID == selected else { return }
            chats = storedChats.map { ChatSummary(id: $0.id, title: $0.title, preview: $0.lastMessage?.body ?? "", isPinned: $0.isPinned) }
            messages = storedMessages
        } catch { self.error = "Could not read local conversations." }
    }
}
