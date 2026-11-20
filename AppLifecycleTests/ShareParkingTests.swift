import MessageStore
import UniformTypeIdentifiers
import XCTest
@testable import HausXMPP

// The share sheet's process is suspended with its host, or once the sheet is swiped away. Before either it closes
// SQLite, so it holds no lock on the App Group database, and the store opens again once the host is back.
@MainActor final class ShareParkingTests: XCTestCase {
    private let account = NotificationAccount(accountID: "alice@localhost", host: "localhost", port: 5223, domain: "localhost",
                                              username: "alice", password: "synthetic", push: nil)

    func testTheSheetClosesSQLiteWhileAwayAndReopensOnReturn() async throws {
        let group = FileManager.default.temporaryDirectory.appending(path: "share-parking-\(UUID())", directoryHint: .isDirectory)
        let root = group.appending(path: "Messaging", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let database = root.appending(path: "messages.sqlite")
        let seeded = try MessageStore(url: database)
        try await seeded.upsertChat(accountID: account.accountID, chatID: "bob@localhost", title: "Bob")
        try await seeded.close()
        let account = account
        let model = ShareModel(sources: .init(directory: { root }, account: { account }, encryptionKey: { Data(repeating: 7, count: 32) }))
        addTeardownBlock { @MainActor in
            model.resume()
            await model.close()
            try? FileManager.default.removeItem(at: group)
        }
        await model.load(providers: [NSItemProvider(item: "Look at this" as NSString, typeIdentifier: UTType.plainText.identifier)],
                         suggestedConversation: nil)
        XCTAssertEqual(model.phase, .ready, "the authorised account's store opened")
        XCTAssertEqual(model.chats.map(\.id), ["bob@localhost"])
        XCTAssertTrue(StorageLockProbe.sqliteDescriptors(database).contains("messages.sqlite"), "an open store is visible to the probe")

        for moment in ["the host went to the background", "the sheet was swiped away"] {
            await model.suspend()
            XCTAssertEqual(StorageLockProbe.sqliteDescriptors(database), [], "\(moment): descriptors left on the store")
            XCTAssertTrue(StorageLockProbe.transportLockIsFree(database), "\(moment): the transport lock is held")
            XCTAssertFalse(MessageStore.reopeningAllowed, "\(moment): nothing reopens it while away")
            model.resume()
            let chats = try await XCTUnwrap(model.store).chats(accountID: account.accountID)
            XCTAssertEqual(chats.map(\.id), ["bob@localhost"], "\(moment): the store works again once the host is back")
        }
    }
}
