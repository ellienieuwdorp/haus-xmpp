import Foundation
import Observation
import MessageStore
import XMPPProtocol

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
    var isDemo: Bool { accountID == "preview.local" }

    @ObservationIgnored private var store: MessageStore?
    @ObservationIgnored private var client: XMPPClient?
    @ObservationIgnored private var eventTask: Task<Void, Never>?
    @ObservationIgnored private var openChatID: String?
    @ObservationIgnored private var generation = UUID()
    @ObservationIgnored private var prepared = false

    func prepare() async {
        guard !prepared else { return }
        prepared = true
        do {
            let directory = try FileManager.default.url(for: .applicationSupportDirectory, in: .userDomainMask, appropriateFor: nil, create: true)
                .appending(path: "Messaging", directoryHint: .isDirectory)
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true,
                                                   attributes: [.protectionKey: FileProtectionType.completeUntilFirstUserAuthentication])
            var excluded = directory
            var values = URLResourceValues()
            values.isExcludedFromBackup = true
            try excluded.setResourceValues(values)
            store = try MessageStore(url: directory.appending(path: "messages.sqlite"))
            accountID = UserDefaults.standard.string(forKey: "lastAccount") ?? ""
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
        UserDefaults.standard.set(account, forKey: "lastAccount")
    }

    private func resetSession() -> XMPPClient? {
        generation = UUID()
        eventTask?.cancel()
        eventTask = nil
        let previous = client
        client = nil
        isConnected = false
        isConnecting = false
        connectionStatus = "Offline"
        return previous
    }

    private func handle(_ event: XMPPEvent, token: UUID) async {
        switch event {
        case .state(let state):
            switch state {
            case .connecting: connectionStatus = "Connecting…"
            case .authenticating: connectionStatus = "Signing in…"
            case .binding: connectionStatus = "Opening session…"
            case .online: connectionStatus = "Connected to lab"; isConnected = true; isConnecting = false
            case .disconnected(let reason):
                connectionStatus = "Offline"; isConnected = false; isConnecting = false
                if reason != nil { error = "The lab connection ended. Delivery of any in-flight message is unconfirmed." }
            }
        case .message(let incoming):
            receivedCount += 1
            let sender = String(incoming.from.split(separator: "/", maxSplits: 1).first ?? "")
            // Self echoes are useful to the transport smoke but aren't a second conversation entry.
            guard sender != accountID, !sender.isEmpty, let store else { return }
            let account = accountID
            do {
                try await store.upsertChat(accountID: account, chatID: sender, title: sender)
                try await store.insertMessage(StoredMessage(id: UUID().uuidString, accountID: account, chatID: sender,
                                                           senderID: sender, body: incoming.body))
                guard generation == token else { return }
                await refresh()
            } catch { self.error = "An incoming lab message could not be saved." }
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

    func send(_ body: String, to chatID: String) async -> Bool {
        guard !isSending, let store, !body.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              body.utf8.count <= 16_384 else { return false }
        isSending = true
        defer { isSending = false }
        let account = accountID
        do {
            if !isDemo {
                guard isConnected, let client, chatID.hasSuffix("@localhost") else { return false }
                _ = try await client.sendMessage(to: chatID, body: body)
            }
            try await store.insertMessage(StoredMessage(id: UUID().uuidString, accountID: account, chatID: chatID,
                                                       senderID: account, body: body, isOutgoing: true))
            await refresh()
            return true
        } catch {
            self.error = "The lab send did not complete. Delivery is unconfirmed; check the recipient before retrying."
            return false
        }
    }

    func openChat(_ chatID: String) async { openChatID = chatID; messages = []; await refresh() }
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
