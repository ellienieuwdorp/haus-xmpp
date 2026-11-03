import Foundation

// Once the data is packed up for another install the identity belongs to the copy: nothing here may connect, decrypt
// or send. The app writes the marker; the notification extension only checks for it.
enum TransferHold {
    static let directoryName = "Transfer"
    static let markerName = "moved.json"

    static func directory(groupRoot: URL) -> URL { groupRoot.appending(path: directoryName, directoryHint: .isDirectory) }

    // Any marker counts, an unfinished export too: the data is not this install's until the app settles it.
    static func isMoved(groupRoot: URL) -> Bool {
        FileManager.default.fileExists(atPath: directory(groupRoot: groupRoot).appending(path: markerName).path)
    }
}
