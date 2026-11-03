import Foundation
import MessageStore

// Markers for a restore under way or finished, or a return to kept data: every background process stays off the store.
// Each build names its folder after its schema (`PreUpgrade-24/`), so an older build never takes a newer one's markers.
// The app writes them; the notification extension only checks for them.
enum PreUpgradeHold {
    static let generation = MessageStore.currentSchemaVersion
    static let firstNumberedGeneration = 24
    static let journalName = "restore-journal.json"
    static let returnJournalName = "return-journal.json"
    static let restoredName = "restored.json"

    static var olderGenerations: [Int?] { (firstNumberedGeneration..<generation).reversed().map(Optional.some) + [nil] }

    static func directoryName(generation: Int?) -> String { generation.map { "PreUpgrade-\($0)" } ?? "PreUpgrade" }

    static func directory(groupRoot: URL, generation: Int? = PreUpgradeHold.generation) -> URL {
        groupRoot.appending(path: directoryName(generation: generation), directoryHint: .isDirectory)
    }

    static func activeDirectory(groupRoot: URL) -> URL {
        let own = directory(groupRoot: groupRoot), files = FileManager.default
        guard !files.fileExists(atPath: own.path) else { return own }
        return olderGenerations.lazy.map { directory(groupRoot: groupRoot, generation: $0) }.first { files.fileExists(atPath: $0.path) } ?? own
    }

    static func isHeld(groupRoot: URL) -> Bool {
        let directory = activeDirectory(groupRoot: groupRoot)
        return [journalName, returnJournalName, restoredName].contains { FileManager.default.fileExists(atPath: directory.appending(path: $0).path) }
    }
}
