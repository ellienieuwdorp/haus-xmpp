import Foundation
import os
import MessageStore
import OMEMO
import XMPPProtocol

/// How one shared message stands, read from the store. Only the server's stream-management acknowledgement counts as
/// sent; a written stanza or a finished PUT does not.
public enum ShareItemState: Sendable, Equatable {
    /// Durably queued; the app sends it on its next connection unless this session gets there first.
    case queued
    /// Written to the stream, waiting for the server's acknowledgement.
    case sending
    /// The server acknowledged it.
    case sent
    /// The server refused it, or its file could not be uploaded: the chat shows it as not sent, with Retry.
    case failed

    public init(_ message: StoredMessage?) {
        switch message?.transportState {
        case .serverAccepted?: self = .sent
        case .failed?: self = .failed
        case .submitting?, .unconfirmed?: self = .sending
        case .queued?, nil: self = .queued
        }
    }
}

/// A short connection a share extension opens to send what it just queued, while its sheet is on screen. It works
/// only under the store's transport lease, taken without ever stealing it: a lease held elsewhere (the app, a
/// notification run) means the share stays queued for whoever holds it. Under the lease it does what a notification
/// Reply in the background does: recover interrupted submissions, connect with the installation's resource and the
/// saved stream state, persist everything that arrives before acknowledging it, upload the shared files, run one
/// outbox pass and wait for the server's acknowledgement. `end()` always follows: it closes the stream, joins every
/// task and gives the lease back, which marks a stanza still in flight as unconfirmed for the archive to reconcile.
///
/// The PUTs run in this process, so ending the session cancels them; the rows stay pending and the app requests new
/// slots for them on its next connection. Nothing here changes trust or sends plaintext.
public actor ShareSession {
    /// Puts the staged ciphertext at the slot; true for a 2xx answer. Injectable for tests.
    public typealias Upload = @Sendable (_ file: URL, _ slot: XMPPUploadSlot, _ size: Int) async throws -> Bool

    private let store: MessageStore
    private let encryption: OMEMOService
    private let files: AttachmentFiles
    private let account: BackgroundAccount
    private let uploadService: XMPPUploadService?
    private let upload: Upload
    private var client: XMPPClient?
    private var consumer: Task<Void, Never>?
    private var restoration: Task<Void, Never>?
    private var holdsLease = false
    private var ended = false
    private static let log = Logger(subsystem: "haus.xmpp.ios", category: "share")

    public init(store: MessageStore, encryption: OMEMOService, files: AttachmentFiles, account: BackgroundAccount,
                uploadService: XMPPUploadService?, upload: @escaping Upload = ShareSession.urlSessionUpload) {
        self.store = store; self.encryption = encryption; self.files = files; self.account = account
        self.uploadService = uploadService; self.upload = upload
    }

    /// Polls the non-blocking lease for at most `wait`. False when another process kept it (or the session ended).
    public func acquireLease(waitingUpTo wait: Duration = .seconds(3)) async -> Bool {
        guard !ended, !holdsLease else { return holdsLease }
        do { _ = try await acquireTransportOwnership(store, waitingUpTo: wait) }
        catch { return false }
        // `end()` may have run while the wait slept; the lease it could not release goes back now.
        if ended { try? await store.releaseTransportOwnership(); return false }
        holdsLease = true
        return true
    }

    /// Connects, uploads `messageIDs`' files, joins `rooms` and runs one outbox pass, then waits until `deadline` for the
    /// server to acknowledge every one of them. `progress` hears each message's state as it changes. Cancelling the
    /// calling task closes the stream, so every step returns promptly. Returns the last states read.
    public func send(messageIDs: [String], rooms: Set<String>, until deadline: ContinuousClock.Instant,
                     progress: @escaping @Sendable ([String: ShareItemState]) async -> Void = { _ in }) async -> [String: ShareItemState] {
        guard holdsLease, !ended else { return await states(messageIDs) }
        let watchdog = Task { [weak self] in
            try? await Task.sleep(until: deadline, clock: .continuous)
            await self?.disconnect()
        }
        defer { watchdog.cancel() }
        do {
            try await withTaskCancellationHandler {
                try await connect(rooms: rooms, deadline: deadline)
                await progress(await states(messageIDs))
                try await uploadFiles(inChatsOf: Set(messageIDs))
                guard let client else { throw CancellationError() }
                let joined = await joinedRooms(rooms, client: client)
                _ = try await OutboxDrain(account: account.accountID, client: client, encryption: encryption, store: store,
                                          sender: OutboxSender(store: store), joinedGroups: joined)
                    .run(OutboxDrain.Hooks(didChange: { [weak self] in
                        guard let self else { return }
                        await progress(await self.states(messageIDs))
                    }))
                try? await client.requestAcknowledgement()
            } onCancel: {
                Task { await self.disconnect() }
            }
        } catch {
            Self.log.notice("share send ended: \(String(describing: type(of: error)), privacy: .public)")
        }
        // The acknowledgement arrives on the stream after the write; the consumer persists it.
        var current = await states(messageIDs)
        while current.values.contains(.sending), ContinuousClock.now < deadline, !Task.isCancelled, client != nil {
            await progress(current)
            try? await Task.sleep(for: .milliseconds(200))
            current = await states(messageIDs)
        }
        await progress(current)
        return current
    }

    /// Ends the session: closes the stream, joins the consumer and the post-bind duties, runs `presentation` while the
    /// lease is still held (what arrived on this connection alerts as the notification extension would show it), then
    /// releases the lease. Safe to call more than once and without a lease.
    public func end(presentation: (@Sendable (MessageStore) async -> Void)? = nil) async {
        guard !ended else { return }
        ended = true
        restoration?.cancel()
        await restoration?.value
        let connected = client != nil
        if let client { await client.disconnectAndWait() }
        consumer?.cancel()
        await consumer?.value
        client = nil
        guard holdsLease else { return }
        if connected, let presentation { await presentation(store) }
        do { try await store.releaseTransportOwnership() }
        catch { Self.log.error("share lease release failed: \(String(describing: type(of: error)), privacy: .public)") }
        holdsLease = false
    }

    /// The states of `messageIDs` as stored.
    public func states(_ messageIDs: [String]) async -> [String: ShareItemState] {
        var result: [String: ShareItemState] = [:]
        for id in messageIDs { result[id] = ShareItemState(try? await store.message(accountID: account.accountID, messageID: id)) }
        return result
    }

    private func disconnect() async { await client?.disconnect() }

    private func connect(rooms: Set<String>, deadline: ContinuousClock.Instant) async throws {
        let accountID = account.accountID
        try await store.recoverInterruptedSubmissions(accountID: accountID)
        let client = XMPPClient(labCertificateAuthority: account.labCertificateAuthority)
        try await client.configureStreamManagement(persistence: StreamPersistence(store: store, accountID: accountID, encryption: encryption))
        if let resource = account.resource { try await client.configureResource(resource) }
        let preferences = try await store.accountPreferences(accountID: accountID)
        // The user is in another app: this session must not make them look online.
        try await client.setAvailability(BackgroundSession.availability(sharesLastSeen: preferences.lastSeen, leftForeground: account.leftForeground),
                                         clientActive: false)
        self.client = client
        // Everything that arrives is persisted before it is acknowledged, exactly as the notification extension does. The
        // processor refuses the next acknowledgement after a stanza it could not store and closes the stream itself, so
        // no unhandled gap is ever acknowledged.
        let processor = InboundProcessor(encryption: encryption, client: client, account: accountID)
        consumer = Task {
            for await event in client.events {
                if case .state(.disconnected) = event { break }
                _ = try? await processor.process(event)
            }
        }
        try Task.checkCancellation()
        try await client.connect(route: account.route, domain: account.domain, username: account.username,
                                 password: account.password, requireSCRAM: account.requiresSCRAM)
        let resumed = await client.sessionResumed
        Self.log.notice("share session online resumed=\(resumed, privacy: .public)")
        // As before the app's `.ready`: an identity mismatch fails closed before anything can be sealed.
        try await encryption.initialize(account: accountID, transport: client)
        guard !resumed else { return }
        // A fresh bind replaced the session the app left hibernating, with its push registration and room occupancy:
        // restore both alongside the send, as a notification Reply does. `end()` waits for it.
        let push = account.push, encryption = encryption, store = store
        let limit = max(.zero, min(.seconds(5), deadline - .now))
        restoration = Task {
            async let enabled: Void = BackgroundSession.enablePush(push, client: client)
            await BackgroundSession.joinRooms(account: accountID, client: client, encryption: encryption, store: store,
                                              skipping: rooms, within: limit)
            await enabled
        }
    }

    /// The rooms a shared text goes to must confirm the join first: the drain sends only to joined rooms.
    private func joinedRooms(_ rooms: Set<String>, client: XMPPClient) async -> Set<String> {
        guard !rooms.isEmpty else { return [] }
        let fallback = String(account.accountID.prefix { $0 != "@" })
        var joined: Set<String> = []
        for room in rooms.sorted() {
            let nickname = (try? await store.groupNickname(accountID: account.accountID, room: room)) ?? fallback
            if await BackgroundSession.join(room, nickname: nickname, client: client, within: .seconds(3)) { joined.insert(room) }
        }
        return joined
    }

    /// One slot and one PUT per file waiting in the shared chats, in queue order: a chat's messages are claimable only
    /// once every earlier file in it is uploaded, so a file queued before (by an earlier share, or the app while
    /// offline) would otherwise hold this share back. A file the app's background session carries (it has a task) is
    /// left to the app. A refusal leaves the file pending for the app, which retries it within its own budget; nothing
    /// here fails a message.
    private func uploadFiles(inChatsOf messageIDs: Set<String>) async throws {
        let accountID = account.accountID
        let waiting = try await store.attachmentsAwaitingUpload(accountID: accountID)
        var chats: Set<String> = []
        for id in messageIDs { if let chat = try await store.message(accountID: accountID, messageID: id)?.chatID { chats.insert(chat) } }
        let pending = waiting.filter { chats.contains($0.chatID) }
        Self.log.notice("share uploads: \(pending.count, privacy: .public) waiting in \(chats.count, privacy: .public) chats, service \(self.uploadService != nil, privacy: .public)")
        guard !pending.isEmpty, let service = uploadService, let client else { return }
        for message in pending where message.attachment?.uploadTaskID == nil {
            try Task.checkCancellation()
            guard let attachment = message.attachment else { continue }
            let staged = files.stagingURL(messageID: message.id)
            guard let size = try? FileManager.default.attributesOfItem(atPath: staged.path)[.size] as? Int else { continue }
            do {
                let slot = try await client.requestUploadSlot(service: service, filename: attachment.name, size: size,
                                                              contentType: "application/octet-stream")
                guard try await upload(staged, slot, size) else { continue }
                try await store.recordAttachmentUploaded(accountID: accountID, messageID: message.id, url: slot.get.absoluteString)
                try? FileManager.default.removeItem(at: staged)
            } catch {
                if error is CancellationError || error is MessageStoreError { throw error }
                Self.log.notice("share upload left for the app: \(String(describing: type(of: error)), privacy: .public)")
            }
        }
    }

    /// The PUT on an ephemeral session of this process, with the slot's permitted headers.
    public static let urlSessionUpload: Upload = { file, slot, size in
        var request = URLRequest(url: slot.put)
        request.httpMethod = "PUT"
        request.setValue("application/octet-stream", forHTTPHeaderField: "Content-Type")
        request.setValue(String(size), forHTTPHeaderField: "Content-Length")
        for (name, value) in slot.headers { request.setValue(value, forHTTPHeaderField: name) }
        let session = URLSession(configuration: .ephemeral)
        defer { session.finishTasksAndInvalidate() }
        let (_, response) = try await session.upload(for: request, fromFile: file)
        return (response as? HTTPURLResponse).map { (200...299).contains($0.statusCode) } ?? false
    }
}
