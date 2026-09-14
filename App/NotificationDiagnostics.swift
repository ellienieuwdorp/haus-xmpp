import Foundation
import MessageStore

/// Opt-in, synthetic staging inspection through the containing app's regular data container.
/// The caller must return from prepare before starting any foreground network synchronization.
enum NotificationDiagnostics {
    enum Failure: Error { case invalidFixture, invalidMarker }

    /// False means no diagnostic request. A requested failure throws; it must never silently
    /// fall through into a foreground connection that could manufacture the expected result.
    static func exportIfRequested(store: MessageStore, directory: URL) async throws -> Bool {
        #if DEBUG
        let process = ProcessInfo.processInfo
        guard process.arguments.contains("--inspect-notification") else { return false }
        let documents = try FileManager.default.url(for: .documentDirectory, in: .userDomainMask,
                                                    appropriateFor: nil, create: true)
        var output = documents.appending(path: "notification-inspection.json")
        // A rejected inspection must not leave an earlier successful result masquerading as
        // this run's evidence. No real conversation or identity data is deleted here.
        if FileManager.default.fileExists(atPath: output.path) { try FileManager.default.removeItem(at: output) }
        guard let account = try NotificationAccount.load(),
              account.accountID == "alice@staging.example.net", account.username == "alice",
              account.domain == "staging.example.net",
              let expected = process.environment["XMPP_EXPECTED_MESSAGE"],
              expected.hasPrefix("Synthetic"), expected.utf8.count <= 100,
              !expected.unicodeScalars.contains(where: { CharacterSet.controlCharacters.contains($0) }) else {
            throw Failure.invalidFixture
        }
        let peer = "peer@staging.example.net"
        let messages = try await store.messages(accountID: account.accountID, chatID: peer, limit: 1000)
        let matches = messages.filter {
            $0.body == expected && !$0.isOutgoing && $0.senderID == peer
                && ($0.encryptionProfile == "legacy" || $0.encryptionProfile == "modern")
        }
        let state = try await store.encryptionState(accountID: account.accountID)
        let markerURL = directory.appending(path: "notification-result.json")
        var marker: CompletionMarker?
        if FileManager.default.fileExists(atPath: markerURL.path) {
            let bytes = try Data(contentsOf: markerURL)
            guard bytes.count <= 1024 else { throw Failure.invalidMarker }
            let decoded = try JSONDecoder().decode(CompletionMarker.self, from: bytes)
            guard decoded.started.isFinite, decoded.completed.isFinite,
                  decoded.started > 0, decoded.completed >= decoded.started else { throw Failure.invalidMarker }
            marker = decoded
        }
        let inspection = Inspection(expectedPresent: !matches.isEmpty, expectedCount: matches.count,
            inspectedMessageCount: messages.count, encryptionRevision: state?.revision,
            started: marker?.started, completed: marker?.completed, sharedDirectory: directory.path)
        try JSONEncoder().encode(inspection).write(to: output,
            options: [.atomic, .completeFileProtectionUntilFirstUserAuthentication])
        var values = URLResourceValues()
        values.isExcludedFromBackup = true
        try output.setResourceValues(values)
        return true
        #else
        return false
        #endif
    }

    #if DEBUG
    private struct CompletionMarker: Decodable {
        let started: Double
        let completed: Double
    }
    private struct Inspection: Encodable {
        let expectedPresent: Bool
        let expectedCount: Int
        let inspectedMessageCount: Int
        let encryptionRevision: Int?
        let started: Double?
        let completed: Double?
        let sharedDirectory: String
    }
    #endif
}
