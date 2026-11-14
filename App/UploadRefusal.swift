import Foundation
import XMPPProtocol

// A file too large, or a service that does not let this account upload, never succeeds on a retry, so its message
// fails at once; a requested wait costs none of the file's tries.
enum UploadRefusal: Equatable {
    case tooLarge(maximumFileSize: Int?)
    case notAllowed
    case wait(Duration)
    case failed

    // A stamp already past still waits the back-off, so a repeated one cannot spin the pass.
    static let longestWait: Duration = .seconds(5 * 60)

    init(_ error: any Error, now: Date) {
        switch error as? XMPPUploadError {
        case .fileTooLarge(let maximum)?: self = .tooLarge(maximumFileSize: maximum)
        case .notAllowed?: self = .notAllowed
        case .retry(let stamp)?: self = .wait(Self.wait(until: stamp, now: now))
        case nil: self = .failed
        }
    }

    static func wait(until stamp: Date, now: Date) -> Duration {
        let seconds = min(max(stamp.timeIntervalSince(now), 0), Double(longestWait.components.seconds))
        return max(UploadFailureBudget.backOff, .seconds(seconds))
    }

    var statedLimit: Int? { if case .tooLarge(let maximum) = self { maximum } else { nil } }

    func failure(name: String) -> String? {
        switch self {
        case .tooLarge(let maximum?):
            "\(name) is larger than the \(ByteCountFormatter.string(fromByteCount: Int64(maximum), countStyle: .file)) this server accepts, so it was not sent."
        case .tooLarge(nil): "This server refused \(name) as too large, so it was not sent."
        case .notAllowed: "This server doesn't allow uploading \(name), so it was not sent."
        case .wait, .failed: nil
        }
    }
}

// Files held back by their failure budget or a server's retry stamp, and the connection whose refusal already asked
// for discovery again.
@MainActor final class UploadHolds {
    var failures = UploadFailureBudget()
    private var waits: [String: UUID] = [:]
    private var rediscovered: UUID?
    private let sleep: @Sendable (Duration) async throws -> Void

    init(sleep: @escaping @Sendable (Duration) async throws -> Void = { try await Task.sleep(for: $0) }) { self.sleep = sleep }

    func isWaiting(_ messageID: String) -> Bool { failures.isWaiting(messageID) || waits[messageID] != nil }

    // A later wait for the same file replaces this one.
    func wait(_ messageID: String, for delay: Duration, then resume: @escaping @MainActor () -> Void) {
        let wait = UUID()
        waits[messageID] = wait
        Task { [weak self, sleep] in
            do { try await sleep(delay) } catch { return }
            guard let self, self.waits[messageID] == wait else { return }
            self.waits[messageID] = nil
            resume()
        }
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
