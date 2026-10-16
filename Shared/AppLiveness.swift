import Foundation
import notify
import MessagingCore

/// The liveness handshake's I/O (`LivenessHandshake` in MessagingCore). The notification extension saves its request in
/// the App Group and rings the app with a payload-free Darwin notification; the app reads the request and writes its
/// answer next to it, which the extension's lease wait reads. A Darwin notification carries no data and any process may
/// post one, so the ring only makes the app look: the request and the answer are in files only this build's app and
/// extensions can write, and the answer echoes the request's random nonce.
///
/// Everything is scoped by this build's App Group: the development and the released app each have their own container,
/// and the ring's name starts with the group, so neither ever rings or answers the other.
enum AppLiveness {
    static var ringName: String { SharedStorage.group + ".liveness.request" }

    /// The request and answer files in `directory` (`Liveness/` in the App Group container).
    struct Files: Sendable {
        let directory: URL
        /// Larger than this is not ours to parse.
        static let maximumBytes = 4 * 1024

        /// `Liveness/` in the App Group container `groupRoot`.
        init(groupRoot: URL) { directory = groupRoot.appending(path: "Liveness", directoryHint: .isDirectory) }

        func saveRequest(_ request: LivenessRequest) throws { try save(request, as: "request.json") }
        func request() -> LivenessRequest? { read("request.json") }
        func saveAnswer(_ answer: LivenessAnswer) throws { try save(answer, as: "answer.json") }
        func answer() -> LivenessAnswer? { read("answer.json") }

        private func save(_ value: some Encodable, as name: String) throws {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            let data = try JSONEncoder().encode(value)
            #if os(iOS)
            // The extension runs while the iPhone is locked; it never runs before the first unlock anyway.
            try data.write(to: directory.appending(path: name), options: [.atomic, .completeFileProtectionUntilFirstUserAuthentication])
            #else
            try data.write(to: directory.appending(path: name), options: [.atomic])
            #endif
        }

        private func read<Value: Decodable>(_ name: String) -> Value? {
            let url = directory.appending(path: name)
            guard let size = (try? FileManager.default.attributesOfItem(atPath: url.path))?[.size] as? Int,
                  size <= Self.maximumBytes, let data = try? Data(contentsOf: url) else { return nil }
            return try? JSONDecoder().decode(Value.self, from: data)
        }
    }

    /// The extension's side: saves the request, then rings.
    struct ExtensionChannel: LivenessChannel {
        let files: Files

        func ask(_ request: LivenessRequest) throws {
            try files.saveRequest(request)
            notify_post(AppLiveness.ringName)
        }

        func latestAnswer() -> LivenessAnswer? { files.answer() }
    }

    /// The app's side, on the main queue for the life of the process. Each ring reads the request and answers it only
    /// when `conditions` say the app can keep the promise (`LivenessHandshake.answer`); `answered` then runs, and the
    /// app makes sure it presents (its socket may be stale: the server pushed because an acknowledgement was overdue).
    @MainActor final class Responder {
        private let files: Files
        private let conditions: @MainActor () -> LivenessConditions
        private let answered: @MainActor () -> Void
        private var token: Int32 = NOTIFY_TOKEN_INVALID
        /// The last request answered: another ring for it (anyone may ring) changes nothing.
        private var answeredNonce: String?

        init(files: Files, conditions: @escaping @MainActor () -> LivenessConditions, answered: @escaping @MainActor () -> Void) {
            self.files = files; self.conditions = conditions; self.answered = answered
        }

        /// Starts listening. False when the ring cannot be observed; the extension then falls back, as without it.
        func start() -> Bool {
            guard token == NOTIFY_TOKEN_INVALID else { return true }
            let status = notify_register_dispatch(AppLiveness.ringName, &token, DispatchQueue.main) { [weak self] _ in
                MainActor.assumeIsolated { _ = self?.ring() }
            }
            guard status == NOTIFY_STATUS_OK else { token = NOTIFY_TOKEN_INVALID; return false }
            return true
        }

        /// One ring: the answer written, or nil when the app stays silent.
        @discardableResult
        func ring(now: Date = Date()) -> LivenessAnswer? {
            guard let request = files.request(), request.nonce != answeredNonce,
                  let answer = LivenessHandshake.answer(to: request, conditions: conditions(), now: now) else { return nil }
            // An answer that could not be saved never reaches the extension, which falls back: nothing was promised.
            guard (try? files.saveAnswer(answer)) != nil else { return nil }
            answeredNonce = request.nonce
            answered()
            return answer
        }
    }
}
