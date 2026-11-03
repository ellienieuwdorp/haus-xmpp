import Foundation

// Once the data is packed up for another install the identity belongs to the copy; the app writes the marker.
enum TransferHold {
    static let directoryName = "Transfer"
    static let markerName = "moved.json"

    static func directory(groupRoot: URL) -> URL { groupRoot.appending(path: directoryName, directoryHint: .isDirectory) }

    static func isMoved(groupRoot: URL) -> Bool {
        FileManager.default.fileExists(atPath: directory(groupRoot: groupRoot).appending(path: markerName).path)
    }
}
