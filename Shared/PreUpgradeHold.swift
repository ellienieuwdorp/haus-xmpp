import Foundation

/// Files in the App Group container that hold every background process off the store: a restore of the previous
/// version's data under way (its journal) or finished (the data is back in the previous version's format and waits
/// for that build). The app writes them (`PreUpgradeSnapshot`); the notification extension only checks for them.
enum PreUpgradeHold {
    static let directoryName = "PreUpgrade"
    static let journalName = "restore-journal.json"
    static let restoredName = "restored.json"

    static func directory(groupRoot: URL) -> URL { groupRoot.appending(path: directoryName, directoryHint: .isDirectory) }

    static func isHeld(groupRoot: URL) -> Bool {
        let directory = directory(groupRoot: groupRoot)
        return [journalName, restoredName].contains { FileManager.default.fileExists(atPath: directory.appending(path: $0).path) }
    }
}
