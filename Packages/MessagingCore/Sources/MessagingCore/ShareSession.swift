import Foundation
import os
import MessageStore
import OMEMO
import XMPPProtocol

/// Only the server's stream-management acknowledgement counts as sent; a written stanza or a finished PUT does not.
public enum ShareItemState: Sendable, Equatable {
    case queued
    /// Written to the stream, waiting for the server's acknowledgement.
    case sending
    case sent
    /// Refused by the server, or its file could not be uploaded.
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

/// The share extension's short connection. Works only under the transport lease, never stolen: a lease held
/// elsewhere leaves the share queued for its holder. Persists everything that arrives before acknowledging it. Always
/// follow with `end()`, which closes the stream, joins every task and releases the lease; a stanza still in flight
/// stays unconfirmed for the archive to reconcile. Cancelled PUTs leave their rows pending for the app to request
/// new slots. Never changes trust or sends plaintext.
public actor ShareSession {
    /// True for a 2xx answer.
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

    /// False when another process kept the lease or the session ended.
    public func acquireLease(waitingUpTo wait: Duration = .seconds(3)) async -> Bool {
        guard !ended, !holdsLease else { return holdsLease }
        do { _ = try await acquireTransportOwnership(store, waitingUpTo: wait) }
        catch { return false }
        // `end()` may have run during the wait and could not release this lease.
        if ended { try? await store.releaseTransportOwnership(); return false }
        holdsLease = true
        return true
    }

    /// Waits until `deadline` for the server to acknowledge every message. The deadline or cancelling the caller closes
    /// the stream and cancels any slot request or PUT in flight, so this returns promptly and `end()` can release the
    /// lease.
    public func send(messageIDs: [String], rooms: Set<String>, until deadline: ContinuousClock.Instant,
                     progress: @escaping @Sendable ([String: ShareItemState]) async -> Void = { _ in }) async -> [String: ShareItemState] {
        guard holdsLease, !ended else { return await states(messageIDs) }
        let work = Task { await transmit(messageIDs: messageIDs, rooms: rooms, deadline: deadline, progress: progress) }
        let watchdog = Task {
            try? await Task.sleep(until: deadline, clock: .continuous)
            work.cancel()
        }
        defer { watchdog.cancel() }
        await withTaskCancellationHandler { await work.value } onCancel: { work.cancel() }
        let current = await states(messageIDs)
        await progress(current)
        return current
    }

    private func transmit(messageIDs: [String], rooms: Set<String>, deadline: ContinuousClock.Instant,
                          progress: @escaping @Sendable ([String: ShareItemState]) async -> Void) async {
        do {
            try await withTaskCancellationHandler {
                try await connect(rooms: rooms, deadline: deadline)
                await progress(await states(messageIDs))
                try await uploadFiles(inChatsOf: Set(messageIDs))
                guard let client else { throw CancellationError() }
                let joined = await joinedRooms(rooms, client: client)
                // Past the deadline nothing more is sealed.
                try Task.checkCancellation()
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
    }

    /// Runs `presentation` while the lease is still held, then releases it. Safe to call more than once and without
    /// a lease.
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
        // The user is in another app, so this session must not make them look online.
        try await client.setAvailability(BackgroundSession.availability(sharesLastSeen: preferences.lastSeen, leftForeground: account.leftForeground),
                                         clientActive: false)
        self.client = client
        // The processor refuses the next acknowledgement after a stanza it could not store and closes the stream, so no
        // unhandled gap is ever acknowledged.
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
        // An identity mismatch fails closed before anything can be sealed.
        try await encryption.initialize(account: accountID, transport: client)
        guard !resumed else { return }
        // A fresh bind replaced the hibernated session with its push registration and room occupancy; restore both.
        let push = account.push, encryption = encryption, store = store
        let limit = max(.zero, min(.seconds(5), deadline - .now))
        restoration = Task {
            async let enabled: Void = BackgroundSession.enablePush(push, client: client)
            await BackgroundSession.joinRooms(account: accountID, client: client, encryption: encryption, store: store,
                                              skipping: rooms, within: limit)
            await enabled
        }
    }

    // The drain sends only to joined rooms.
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

    // Uploads every waiting file in the shared chats: a chat's messages are claimable only once every earlier file in
    // it is uploaded. Files with an app upload task, and refusals, are left to the app; nothing here fails a message.
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
