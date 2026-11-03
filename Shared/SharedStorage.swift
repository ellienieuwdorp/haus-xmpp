import Foundation
import MessageStore

enum SharedStorage {
    // A bundle without the `HausAppGroup` key is a broken build: any default could be another app's data.
    static let group: String = {
        guard let group = Bundle.main.object(forInfoDictionaryKey: "HausAppGroup") as? String, !group.isEmpty else {
            preconditionFailure("HausAppGroup is missing from the Info.plist")
        }
        return group
    }()
    enum Failure: Error, Equatable { case unavailable, conflictingStores }

    // Only the app migrates: it moves the whole directory under its OS lease, SQLite sidecars and identity included.
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
        return try await resolve(legacy: nil, destination: destination, migrate: migrate)
        #else
        return try await resolve(legacy: legacy, destination: destination, migrate: migrate)
        #endif
    }

    // On macOS `containerURL` returns a path even without the entitlement, so the directory itself is checked too.
    static func groupContainer() throws -> URL {
        try usableContainer(FileManager.default.containerURL(forSecurityApplicationGroupIdentifier: group))
    }

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
        // In the Mac sandbox access(2) reports the container read-only although writes succeed, and permission bits
        // cannot see a sandbox that denies writes; only a real write answers both.
        let probe = url.appending(path: ".write-probe-\(UUID().uuidString)")
        guard FileManager.default.createFile(atPath: probe.path, contents: nil) else { return false }
        try? FileManager.default.removeItem(at: probe)
        return true
        #else
        // On iOS a URL means the process has the App Group; access(2) wrongly reports it read-only on devices, and a
        // probe write could fail before first unlock.
        true
        #endif
    }

    static func resolve(legacy: URL?, destination: URL, migrate: Bool) async throws -> URL {
        let manager = FileManager.default
        let oldDatabase = legacy?.appending(path: "messages.sqlite")
        if migrate, let legacy, let oldDatabase, manager.fileExists(atPath: oldDatabase.path) {
            guard !manager.fileExists(atPath: destination.path) else { throw Failure.conflictingStores }
            // A store an older build left there is moved unchanged; the app snapshots it before migrating.
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
