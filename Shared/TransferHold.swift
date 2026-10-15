import Foundation

/// The App Group folder a transfer to another install works in, and the marker that holds every process off this
/// install's data once it has been packed up for the other one: from then on the encryption identity belongs to the
/// copy, and nothing here may connect, decrypt or send with it. The app writes the marker (`AccountTransfer`); the
/// notification extension only checks for it.
enum TransferHold {
    static let directoryName = "Transfer"
    static let markerName = "moved.json"

    static func directory(groupRoot: URL) -> URL { groupRoot.appending(path: directoryName, directoryHint: .isDirectory) }

    /// Any marker counts, also one whose export has not finished: the data is not this install's to use until the
    /// app has settled it.
    static func isMoved(groupRoot: URL) -> Bool {
        FileManager.default.fileExists(atPath: directory(groupRoot: groupRoot).appending(path: markerName).path)
    }
}
