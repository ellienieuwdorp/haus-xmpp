import Foundation
import MessageStore

enum SharedStorage {
    static let group = "group.haus.xmpp.ios"
    enum Failure: Error, Equatable { case unavailable, conflictingStores }

    /// Only the containing app migrates its original store. Move the whole directory while
    /// holding its OS lease, preserving SQLite sidecars and the identity instead of copying it.
    static func directory(testSessionID: String? = nil, migrate: Bool) async throws -> URL {
        let manager = FileManager.default
        let support = try manager.url(for: .applicationSupportDirectory, in: .userDomainMask, appropriateFor: nil, create: true)
        let legacy = support.appending(path: "Messaging", directoryHint: .isDirectory)
        if let testSessionID {
            let testDirectory = legacy.appending(path: "UITests/" + testSessionID, directoryHint: .isDirectory)
            try prepare(testDirectory)
            return testDirectory
        }
        guard let container = manager.containerURL(forSecurityApplicationGroupIdentifier: group) else { throw Failure.unavailable }
        let destination = container.appending(path: "Messaging", directoryHint: .isDirectory)
        return try await resolve(legacy: legacy, destination: destination, migrate: migrate)
    }

    /// Explicit roots keep migration tests isolated from both real app containers.
    static func resolve(legacy: URL, destination: URL, migrate: Bool) async throws -> URL {
        let manager = FileManager.default
        let oldDatabase = legacy.appending(path: "messages.sqlite")
        if migrate, manager.fileExists(atPath: oldDatabase.path) {
            guard !manager.fileExists(atPath: destination.path) else { throw Failure.conflictingStores }
            // As is: a store an older build left there is moved unchanged; the app snapshots it before migrating.
            let old = try MessageStore(url: oldDatabase, schema: .asIs)
            do {
                try await old.acquireTransportOwnership()
                try await old.closeForMigration {
                    try FileManager.default.moveItem(at: legacy, to: destination)
                }
            } catch { try? await old.close(); throw error }
        }
        if !migrate, !manager.fileExists(atPath: destination.appending(path: "messages.sqlite").path) { throw Failure.unavailable }
        try prepare(destination)
        return destination
    }

    private static func prepare(_ directory: URL) throws {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true,
            attributes: [.protectionKey: FileProtectionType.completeUntilFirstUserAuthentication])
        var location = directory
        var values = URLResourceValues()
        values.isExcludedFromBackup = true
        try location.setResourceValues(values)
    }
}
