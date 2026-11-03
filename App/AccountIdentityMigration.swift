import Foundation
import XMPPProtocol
import MessagingCore

// Moves an account's preference keys and folders from its as-typed spelling (`Ellie@Example.org`) to normal form
// once. Moves never overwrite: what the normal spelling already has wins, the rest is carried over.
enum AccountIdentityMigration {
    static let accountKeyPrefixes = ["pushOff.", "avatar.", "uploadService."]

    private static func normal(_ address: String) -> String { JID.normalizedBare(address) ?? address }

    // Saved before the preferences that name them are rewritten, so a launch that ends before storage opens still
    // moves them on the next one.
    static let pendingFolderMovesKey = "identityFolderMoves"

    @discardableResult
    static func migratePreferences(_ defaults: UserDefaults) -> Set<String> {
        var spellings = Set<String>()
        let keys = defaults.dictionaryRepresentation().keys
        if let last = defaults.string(forKey: "lastAccount"), normal(last) != last { spellings.insert(last) }
        for key in keys {
            for prefix in accountKeyPrefixes where key.hasPrefix(prefix) {
                let account = String(key.dropFirst(prefix.count))
                if normal(account) != account { spellings.insert(account) }
            }
        }
        if !spellings.isEmpty {
            let queued = Set(defaults.stringArray(forKey: pendingFolderMovesKey) ?? [])
            defaults.set(Array(queued.union(spellings)).sorted(), forKey: pendingFolderMovesKey)
        }
        if let last = defaults.string(forKey: "lastAccount"), normal(last) != last { defaults.set(normal(last), forKey: "lastAccount") }
        func move(_ key: String, to target: String) {
            guard key != target else { return }
            if defaults.object(forKey: target) == nil { defaults.set(defaults.object(forKey: key), forKey: target) }
            defaults.removeObject(forKey: key)
        }
        for key in keys {
            for prefix in accountKeyPrefixes where key.hasPrefix(prefix) {
                let account = String(key.dropFirst(prefix.count))
                guard normal(account) != account else { continue }
                move(key, to: prefix + normal(account))
            }
        }
        // Both addresses contain dots, so only a known account spelling splits `groupNickname.<account>.<room>`.
        let accounts = spellings.union(spellings.map(normal)).union(defaults.string(forKey: "lastAccount").map { [$0] } ?? [])
        for key in keys where key.hasPrefix("groupNickname.") {
            for account in accounts where key.hasPrefix("groupNickname.\(account).") {
                let room = String(key.dropFirst("groupNickname.\(account).".count))
                move(key, to: "groupNickname.\(normal(account)).\(normal(room))")
            }
        }
        return spellings
    }

    static func moveFiles(directory: URL, defaults: UserDefaults) {
        for account in defaults.stringArray(forKey: pendingFolderMovesKey) ?? [] where normal(account) != account {
            merge(AttachmentFiles.root(directory: directory, account: account), into: AttachmentFiles.root(directory: directory, account: normal(account)))
            merge(AvatarStore.directory(root: directory, account: account), into: AvatarStore.directory(root: directory, account: normal(account)))
        }
        defaults.removeObject(forKey: pendingFolderMovesKey)
    }

    private static func merge(_ source: URL, into target: URL) {
        let files = FileManager.default
        guard files.fileExists(atPath: source.path) else { return }
        if !files.fileExists(atPath: target.path) {
            try? files.createDirectory(at: target.deletingLastPathComponent(), withIntermediateDirectories: true)
            try? files.moveItem(at: source, to: target)
            return
        }
        var isDirectory: ObjCBool = false
        for name in (try? files.contentsOfDirectory(atPath: source.path)) ?? [] {
            let item = source.appending(path: name), destination = target.appending(path: name)
            if files.fileExists(atPath: destination.path, isDirectory: &isDirectory) {
                if isDirectory.boolValue { merge(item, into: destination) }
            } else { try? files.moveItem(at: item, to: destination) }
        }
        if ((try? files.contentsOfDirectory(atPath: source.path)) ?? ["?"]).isEmpty { try? files.removeItem(at: source) }
    }
}
