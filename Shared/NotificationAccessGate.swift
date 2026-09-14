import Foundation

/// A non-secret logout tombstone, independent of Keychain deletion. It prevents the extension
/// from reusing saved credentials when deletion fails; an explicit successful sign-in clears it.
enum NotificationAccessGate {
    static func location() throws -> URL {
        guard let root = FileManager.default.containerURL(forSecurityApplicationGroupIdentifier: SharedStorage.group) else {
            throw NotificationAccount.Failure.unavailable
        }
        return root.appending(path: "notification-access-disabled")
    }

    static func isDisabled(at url: URL) throws -> Bool {
        do { _ = try Data(contentsOf: url); return true }
        catch CocoaError.fileReadNoSuchFile { return false }
        // Unreadable or malformed state never authorizes background access.
    }

    static func disable(at url: URL) throws {
        try Data("disabled\n".utf8).write(to: url,
            options: [.atomic, .completeFileProtectionUntilFirstUserAuthentication])
    }

    static func enable(at url: URL) throws {
        do { try FileManager.default.removeItem(at: url) }
        catch CocoaError.fileNoSuchFile { return }
    }
}
