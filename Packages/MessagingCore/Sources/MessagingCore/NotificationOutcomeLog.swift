import Foundation

/// One extension run as the physical checks need to see it: timestamps, phase and counts. No account, address,
/// identifier, token or content. The extension writes it in DEBUG builds only; the app's diagnostics read it.
public struct NotificationOutcomeRecord: Codable, Sendable, Equatable {
    public let started: Double
    public let finished: Double
    /// "suppressed" or "fallback".
    public let outcome: String
    public let reason: NotificationFallbackReason?
    /// The furthest phase the run reached.
    public let phase: NotificationRunPhase
    /// Remote requests that shared this run, and how many of them expired before it ended.
    public let requests: Int
    public let expired: Int
    public let report: NotificationRunReport

    public init(progress: NotificationRunProgress, outcome: NotificationRunOutcome, finished: Date = Date()) {
        started = progress.started.timeIntervalSince1970
        self.finished = finished.timeIntervalSince1970
        switch outcome {
        case .settled: self.outcome = "suppressed"; reason = nil
        case let .fallback(value): self.outcome = "fallback"; reason = value
        }
        phase = progress.phase
        requests = progress.joined
        expired = progress.expired
        report = progress.report
    }
}

/// A bounded ring in the shared container, newest last.
public enum NotificationOutcomeLog {
    public static let fileName = "notification-outcomes.json"
    public static let capacity = 32
    /// A file larger than this is not ours to parse.
    static let maximumBytes = 64 * 1024

    public static func read(directory: URL) throws -> [NotificationOutcomeRecord] {
        let url = directory.appending(path: fileName)
        guard FileManager.default.fileExists(atPath: url.path) else { return [] }
        let data = try Data(contentsOf: url)
        guard data.count <= maximumBytes else { throw CocoaError(.fileReadTooLarge) }
        return try JSONDecoder().decode([NotificationOutcomeRecord].self, from: data)
    }

    /// Appends and trims. An unreadable ring is replaced rather than blocking diagnostics forever.
    public static func append(_ record: NotificationOutcomeRecord, directory: URL) throws {
        var records = (try? read(directory: directory)) ?? []
        records.append(record)
        let data = try JSONEncoder().encode(Array(records.suffix(capacity)))
        var url = directory.appending(path: fileName)
        #if os(iOS)
        try data.write(to: url, options: [.atomic, .completeFileProtectionUntilFirstUserAuthentication])
        #else
        try data.write(to: url, options: [.atomic])
        #endif
        var values = URLResourceValues()
        values.isExcludedFromBackup = true
        try? url.setResourceValues(values)
    }
}
