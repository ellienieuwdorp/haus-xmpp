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
        let destination = try groupContainer().appending(path: "Messaging", directoryHint: .isDirectory)
        #if os(macOS)
        // The legacy location only ever held stores from iOS builds before the App Group move. No Mac build kept a store
        // there, so there is nothing to bring across.
        return try await resolve(legacy: nil, destination: destination, migrate: migrate)
        #else
        return try await resolve(legacy: legacy, destination: destination, migrate: migrate)
        #endif
    }

    /// The App Group container, once this process can use it. A missing entitlement makes `containerURL` nil on iOS,
    /// but on macOS it always returns a path, so the directory itself is checked too.
    static func groupContainer() throws -> URL {
        try usableContainer(FileManager.default.containerURL(forSecurityApplicationGroupIdentifier: group))
    }

    /// The container must be a directory that exists or can be created, and that this process may write to. On iOS
    /// that is checked with permissions rather than a probe write, so nothing is written and the answer does not
    /// depend on file protection before first unlock. On macOS a probe file is written and removed (`permitsWriting`).
    static func usableContainer(_ url: URL?) throws -> URL {
        guard let url else { throw Failure.unavailable }
        let manager = FileManager.default
        var isDirectory: ObjCBool = false
        if !manager.fileExists(atPath: url.path, isDirectory: &isDirectory) {
            do { try manager.createDirectory(at: url, withIntermediateDirectories: false) } catch { throw Failure.unavailable }
            isDirectory = true
        }
        guard isDirectory.boolValue, permitsWriting(url) else { throw Failure.unavailable }
        return url
    }

    private static func permitsWriting(_ url: URL) -> Bool {
        #if os(macOS)
        // Inside the Mac sandbox, access(2) calls the App Group container read-only although files can be created in
        // it (measured 2026-10-09 on macOS 27.0.1 with a development-signed build: EPERM from access, success from a
        // write), and permission bits cannot see a sandbox that denies writes (a build without the App Group
        // entitlement, where containerURL still returns a path). Only a real write answers both. A Mac has no data
        // protection classes that could refuse it before first unlock.
        let probe = url.appending(path: ".write-probe-\(UUID().uuidString)")
        guard FileManager.default.createFile(atPath: probe.path, contents: nil) else { return false }
        try? FileManager.default.removeItem(at: probe)
        return true
        #else
        FileManager.default.isWritableFile(atPath: url.path)
        #endif
    }

    /// Explicit roots keep migration tests isolated from both real app containers. Without a legacy directory there
    /// is nothing to move.
    static func resolve(legacy: URL?, destination: URL, migrate: Bool) async throws -> URL {
        let manager = FileManager.default
        let oldDatabase = legacy?.appending(path: "messages.sqlite")
        if migrate, let legacy, let oldDatabase, manager.fileExists(atPath: oldDatabase.path) {
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
