import Foundation
import MessageStore
import MessagingCore
import UserNotifications

/// Opt-in, synthetic inspection of a run on the staging server (`DevelopmentEndpoint.stagingDomain`) through the
/// containing app's regular data container.
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
        // Only the `alice` fixture account on the configured staging domain. Without a staging domain, every request
        // fails here.
        guard let staging = DevelopmentEndpoint.stagingDomain,
              let account = try NotificationAccount.load(),
              account.accountID == "alice@\(staging)", account.username == "alice",
              account.domain == staging,
              let expected = process.environment["XMPP_EXPECTED_MESSAGE"],
              expected.hasPrefix("Synthetic"), expected.utf8.count <= 100,
              !expected.unicodeScalars.contains(where: { CharacterSet.controlCharacters.contains($0) }) else {
            throw Failure.invalidFixture
        }
        let peer = "peer@\(staging)"
        let messages = try await store.messages(accountID: account.accountID, chatID: peer, limit: 1000)
        let matches = messages.filter {
            $0.body == expected && !$0.isOutgoing && $0.senderID == peer
                && ($0.encryptionProfile == "legacy" || $0.encryptionProfile == "modern")
        }
        let state = try await store.encryptionState(accountID: account.accountID)
        // The extension's DEBUG outcome ring: timestamps, phases and counts of recent runs, never content.
        let outcomes: [NotificationOutcomeRecord]
        do { outcomes = try NotificationOutcomeLog.read(directory: directory) } catch { throw Failure.invalidMarker }
        guard outcomes.allSatisfy({ $0.started.isFinite && $0.finished.isFinite && $0.started > 0 && $0.finished >= $0.started }) else {
            throw Failure.invalidMarker
        }
        let marker = outcomes.last
        let previewsBefore = try await store.notificationPreviewsEnabled(accountID: account.accountID)
        if let requested = process.environment["XMPP_NOTIFICATION_PREVIEWS"] {
            guard requested == "0" || requested == "1" else { throw Failure.invalidFixture }
            try await store.acquireTransportOwnership()
            do {
                try await store.setNotificationPreviews(accountID: account.accountID, enabled: requested == "1")
                if requested == "0" { await CommunicationHistory.deleteAll() }
                try await store.releaseTransportOwnership()
            } catch {
                try? await store.releaseTransportOwnership()
                throw error
            }
        }
        let delivered = await UNUserNotificationCenter.current().deliveredNotifications()
        let fresh = delivered.filter { notification in
            guard let started = marker?.started else { return false }
            // UNNotification.date describes the original push arrival, before NSE work starts.
            return notification.date.timeIntervalSince1970 >= started - 5
        }
        let inspection = Inspection(expectedPresent: !matches.isEmpty, expectedCount: matches.count,
            inspectedMessageCount: messages.count, encryptionRevision: state?.revision,
            started: marker?.started, completed: marker?.finished, outcomes: outcomes, sharedDirectory: directory.path,
            previewsBefore: previewsBefore,
            previewsAfter: try await store.notificationPreviewsEnabled(accountID: account.accountID),
            deliveredExpectedCount: delivered.filter { $0.request.content.body == expected }.count,
            deliveredSinceSyncCount: fresh.count,
            deliveredSinceSyncExpectedCount: fresh.filter { $0.request.content.body == expected }.count,
            deliveredSinceSyncGenericCount: fresh.filter { [NotificationPlanner.hiddenBody, NotificationPlanner.fallbackBody].contains($0.request.content.body) }.count,
            deliveredFallbackCount: delivered.filter { $0.request.content.categoryIdentifier == NotificationIdentity.fallbackCategory }.count)
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
    private struct Inspection: Encodable {
        let expectedPresent: Bool
        let expectedCount: Int
        let inspectedMessageCount: Int
        let encryptionRevision: Int?
        let started: Double?
        let completed: Double?
        let outcomes: [NotificationOutcomeRecord]
        let sharedDirectory: String
        let previewsBefore: Bool
        let previewsAfter: Bool
        let deliveredExpectedCount: Int
        let deliveredSinceSyncCount: Int
        let deliveredSinceSyncExpectedCount: Int
        let deliveredSinceSyncGenericCount: Int
        let deliveredFallbackCount: Int
    }
    #endif
}
