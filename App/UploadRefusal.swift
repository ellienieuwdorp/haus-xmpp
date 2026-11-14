import Foundation
import XMPPProtocol

// A file too large, or a service that does not let this account upload, never succeeds on a retry, so its message
// fails at once; a requested wait costs none of the file's tries. A held file holds back its chat's later messages, so
// a stamp beyond the longest wait, or past `mostWaits` in a row, fails it.
enum UploadRefusal: Equatable {
    case tooLarge(maximumFileSize: Int?)
    case notAllowed
    case wait(Duration)
    case unavailable
    case failed

    // A stamp already past still waits the back-off, so a repeated one cannot spin the pass.
    static let longestWait: Duration = .seconds(5 * 60)
    static let mostWaits = 3

    init(_ error: any Error, now: Date) {
        switch error as? XMPPUploadError {
        case .fileTooLarge(let maximum)?: self = .tooLarge(maximumFileSize: maximum)
        case .notAllowed?: self = .notAllowed
        case .retry(let stamp)?: self = Self.wait(until: stamp, now: now).map { .wait($0) } ?? .unavailable
        case nil: self = .failed
        }
    }

    static func wait(until stamp: Date, now: Date) -> Duration? {
        let seconds = stamp.timeIntervalSince(now)
        guard seconds <= Double(longestWait.components.seconds) else { return nil }
        return max(UploadFailureBudget.backOff, .seconds(max(seconds, 0)))
    }

    var statedLimit: Int? { if case .tooLarge(let maximum) = self { maximum } else { nil } }

    func failure(name: String) -> String? {
        switch self {
        case .tooLarge(let maximum?):
            "\(name) is larger than the \(ByteCountFormatter.string(fromByteCount: Int64(maximum), countStyle: .file)) this server accepts, so it was not sent."
        case .tooLarge(nil): "This server refused \(name) as too large, so it was not sent."
        case .notAllowed: "This server doesn't allow uploading \(name), so it was not sent."
        case .unavailable: "The server can't take \(name) right now, so it was not sent. Retry it from the message."
        case .wait, .failed: nil
        }
    }
}

// Files held back by their failure budget or a server's retry stamp, and the connection whose refusal already asked
// for discovery again.
@MainActor final class UploadHolds {
    private var failures = UploadFailureBudget()
    private var waits: [String: UUID] = [:]
    private var serverWaits: [String: Int] = [:]
    private var noticed: Set<String> = []
    private var rediscovered: UUID?
    private let sleep: @Sendable (Duration) async throws -> Void
    private let resume: @MainActor () -> Void
    private let notify: @MainActor (String) -> Void

    init(sleep: @escaping @Sendable (Duration) async throws -> Void = { try await Task.sleep(for: $0) },
         resume: @escaping @MainActor () -> Void, notify: @escaping @MainActor (String) -> Void) {
        self.sleep = sleep; self.resume = resume; self.notify = notify
    }

    func isWaiting(_ messageID: String) -> Bool { failures.isWaiting(messageID) || waits[messageID] != nil }

    // True once the file's tries are used up. Any answer but a stamp ends its run of waits.
    func recordFailure(_ messageID: String) -> Bool {
        serverWaits[messageID] = nil
        return failures.recordFailure(messageID)
    }

    // A later wait for the same file replaces this one.
    func wait(_ messageID: String, for delay: Duration) {
        let wait = UUID()
        waits[messageID] = wait
        Task { [weak self, sleep] in
            do { try await sleep(delay) } catch { return }
            guard let self, self.waits[messageID] == wait else { return }
            self.waits[messageID] = nil
            self.resume()
        }
    }

    // Nil while the file waits out a stamp, noticed on its first wait; otherwise the refusal to act on.
    func unlessHeld(_ refusal: UploadRefusal, of messageID: String, named name: String) -> UploadRefusal? {
        guard case .wait(let delay) = refusal else {
            serverWaits[messageID] = nil
            return refusal
        }
        let count = serverWaits[messageID, default: 0]
        serverWaits[messageID] = count < UploadRefusal.mostWaits ? count + 1 : nil
        guard count < UploadRefusal.mostWaits else { return .unavailable }
        wait(messageID, for: delay)
        if noticed.insert(messageID).inserted { notify("The server asked to wait before uploading \(name).") }
        return nil
    }

    func reset(_ messageID: String) {
        failures.reset(messageID)
        serverWaits[messageID] = nil
        noticed.remove(messageID)
    }

    func rediscovers(on connection: UUID) -> Bool {
        defer { rediscovered = connection }
        return rediscovered != connection
    }
}

extension XMPPClient {
    // Only a completed answer changes what the attach button remembers; one that throws keeps the last.
    func uploadDiscovery() async -> Result<XMPPUploadService?, any Error> {
        do { return .success(try await uploadService()) } catch { return .failure(error) }
    }
}
