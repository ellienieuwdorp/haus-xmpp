import Foundation
import MessageStore

/// Files in the App Group container that hold every background process off the store: a restore of the previous
/// version's data under way (its journal), finished (the data is back in the previous version's format and waits for
/// that build or for the user's choice), or a return to this version's kept data under way. The app writes them
/// (`PreUpgradeSnapshot`); the notification extension only checks for them.
///
/// Each build keeps its backups in a folder named after the schema it writes (`PreUpgrade-24/`). Builds up to 6664869
/// used `PreUpgrade/` and carry the same backup code: with one shared folder, the previous build installed after a
/// restore would take this build's restored marker and kept copy for its own, and offer to put back data it cannot
/// open or to delete it. An older build never looks at a newer generation's folder; the app moves an older
/// generation's folder to its own name when it finds one (`PreUpgradeSnapshot.open`).
enum PreUpgradeHold {
    /// This build's generation: the schema it writes.
    static let generation = MessageStore.currentSchemaVersion
    /// The first generation with a numbered folder; older builds used the unnumbered name.
    static let firstNumberedGeneration = 24
    static let journalName = "restore-journal.json"
    static let returnJournalName = "return-journal.json"
    static let restoredName = "restored.json"

    /// Older generations, newest first; nil is the unnumbered folder of builds up to 6664869.
    static var olderGenerations: [Int?] { (firstNumberedGeneration..<generation).reversed().map(Optional.some) + [nil] }

    static func directoryName(generation: Int?) -> String { generation.map { "PreUpgrade-\($0)" } ?? "PreUpgrade" }

    static func directory(groupRoot: URL, generation: Int? = PreUpgradeHold.generation) -> URL {
        groupRoot.appending(path: directoryName(generation: generation), directoryHint: .isDirectory)
    }

    /// The folder the app reads its backups from: its own generation's, or, until the app has moved it there, the
    /// newest older generation's.
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
