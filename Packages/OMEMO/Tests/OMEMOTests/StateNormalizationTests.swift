import Foundation
import Testing
import SQLite3
import MessageStore
import XMPPProtocol
@testable import OMEMO

/// Encryption state saved before addresses were normalised names owners as they were typed. It must read back in
/// normal form without raising any trust decision, and an entry already in normal form wins a collision.
@Test func savedOwnersAreReadInNormalFormWithoutRaisingTrust() throws {
    let key = Data(repeating: 5, count: 33), otherKey = Data(repeating: 6, count: 33)
    func device(_ jid: String, _ id: UInt32, _ identity: Data, _ trust: DeviceTrust) -> String {
        #"{"jid":"\#(jid)","profile":"legacy","deviceID":\#(id),"identityKey":"\#(identity.base64EncodedString())","trust":"\#(trust.rawValue)","active":true,"identityChanged":false}"#
    }
    let json = #"""
    {"format":1,"engines":{},
     "devices":[\#(device("bob@localhost", 7, key, .undecided)),\#(device("Bob@LocalHost", 7, key, .verified)),\#(device("Carol@LocalHost", 9, otherKey, .accepted))],
     "profiles":{"Carol@LocalHost":"legacy","bob@localhost":"modern","Bob@localhost":"legacy"},
     "incompatiblePeers":{"Carol@LocalHost":true},
     "groupRooms":{"Team@Rooms.LocalHost":["Carol@LocalHost","carol@localhost","bob@localhost"]}}
    """#
    let state = try JSONDecoder().decode(AccountEncryptionState.self, from: Data(json.utf8))
    #expect(state.devices.map(\.jid) == ["bob@localhost", "carol@localhost"])
    // The collision keeps the entry already in normal form: its trust is not raised to the variant's.
    #expect(state.devices.first { $0.jid == "bob@localhost" }?.trust == .undecided)
    #expect(state.devices.first { $0.jid == "carol@localhost" }?.trust == .accepted)
    #expect(state.profiles == ["bob@localhost": .modern, "carol@localhost": .legacy])
    #expect(state.incompatiblePeers == ["carol@localhost": true])
    #expect(state.groupRooms == ["team@rooms.localhost": ["carol@localhost", "bob@localhost"]])
}

/// A base build sealed the identity and a file's key under the typed account (`Ellie@LocalHost`: the account is the
/// sealing's associated data). After the v23 store rewrite renames those rows, both still open for the normal spelling
/// and the identity is the same one: never a new identity, never an unreadable one.
@Test func stateAndFileKeysSealedUnderTheTypedSpellingOpenAfterTheStoreRewrite() async throws {
    let directory = FileManager.default.temporaryDirectory.appending(path: "sealed-\(UUID())")
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: directory) }
    let url = directory.appending(path: "messages.sqlite")
    let typed = "Ellie@LocalHost", account = "ellie@localhost"
    let protection = try StateProtection(key: Data(repeating: 9, count: 32)), server = PublicationServer()
    let key = Data(repeating: 3, count: 32), iv = Data(repeating: 4, count: 12)

    let old = try MessageStore(url: url)
    try await old.acquireTransportOwnership()
    let oldService = OMEMOService(store: old, protection: protection)
    try await oldService.initialize(account: account, transport: TestTransport(account: account, server: server))
    let identity = try await oldService.load(account).1.engines
    // Re-key the saved rows as the base build wrote them.
    let plain = try protection.open(try #require(try await old.encryptionState(accountID: account)).data, account: account)
    try await old.saveEncryptionState(accountID: typed, expectedRevision: nil, data: protection.seal(plain, account: typed))
    try await old.upsertChat(accountID: typed, chatID: "Bob@LocalHost", title: "Bob")
    try await old.insertMessage(StoredMessage(id: "photo", accountID: typed, chatID: "Bob@LocalHost", senderID: "Bob@LocalHost", body: "",
                                              isOutgoing: false,
                                              attachment: StoredAttachment(name: "p.jpg", mediaType: "image/jpeg", size: 1, hash: "",
                                                                           secret: oldService.sealAttachmentSecret(account: typed, key: key, iv: iv),
                                                                           url: "https://uploads.localhost/p.jpg")))
    try await old.close()
    var db: OpaquePointer?
    #expect(sqlite3_open(url.path, &db) == SQLITE_OK)
    #expect(sqlite3_exec(db, "DELETE FROM encryption_state WHERE account_id='\(account)'; PRAGMA user_version=21;", nil, nil, nil) == SQLITE_OK)
    sqlite3_close(db)

    let store = try MessageStore(url: url)
    try await store.acquireTransportOwnership()
    let service = OMEMOService(store: store, protection: protection)
    #expect(try await service.load(account).1.engines == identity)
    try await service.initialize(account: account, transport: TestTransport(account: account, server: server))
    #expect(try await service.load(account).1.engines == identity)
    let attachment = try #require(try await store.messages(accountID: account, chatID: "bob@localhost").first?.attachment)
    let secret = try #require(try service.openAttachmentSecret(account: account, secret: attachment.secret, sealedAs: attachment.sealedAccount))
    #expect(secret.key == key && secret.iv == iv)
    // The spelling only unlocks this account's blobs.
    #expect(throws: OMEMOError.stateUnavailable) { try service.openAttachmentSecret(account: "mallory@localhost", secret: attachment.secret, sealedAs: typed) }
    try await store.close()
}

/// State kept only under another spelling of the account (a store whose rewrite was rolled back) is still this
/// account's identity: setting up encryption refuses rather than creating a second identity beside it.
@Test func setupNeverCreatesAnIdentityBesideOneSavedUnderAnotherSpelling() async throws {
    let url = FileManager.default.temporaryDirectory.appending(path: "spelling-\(UUID()).sqlite")
    defer { try? FileManager.default.removeItem(at: url) }
    let store = try MessageStore(url: url)
    try await store.acquireTransportOwnership()
    try await store.saveEncryptionState(accountID: "Ellie@LocalHost", expectedRevision: nil, data: Data([1]))
    let service = OMEMOService(store: store, protection: try StateProtection(key: Data(repeating: 9, count: 32)))
    await #expect(throws: OMEMOError.stateUnavailable) {
        try await service.initialize(account: "ellie@localhost", transport: TestTransport(account: "ellie@localhost", server: PublicationServer()))
    }
    #expect(try await store.encryptionState(accountID: "ellie@localhost") == nil)
    try await store.close()
}
