import Foundation
import notify
import MessagingCore

// The extension saves its request in the App Group and rings with a payload-free Darwin notification. Any process may
// post one, so the ring only makes the app look: the answer goes to a file only this build can write and echoes the
// request's random nonce. The ring's name starts with the App Group, so development and released builds never mix.
enum AppLiveness {
    static var ringName: String { SharedStorage.group + ".liveness.request" }

    // Only the Mac answers, so the iPhone's extension never asks and push stays the iPhone's delivery path.
    static var isOffered: Bool {
        #if os(macOS)
        true
        #else
        false
        #endif
    }

    struct Files: Sendable {
        private let mailbox: GroupMailbox
        var directory: URL { mailbox.directory }
        static let maximumBytes = GroupMailbox.maximumBytes

        init(groupRoot: URL) { mailbox = GroupMailbox(directory: groupRoot.appending(path: "Liveness", directoryHint: .isDirectory)) }

        func saveRequest(_ request: LivenessRequest) throws { try mailbox.save(request, as: "request.json") }
        func request() -> LivenessRequest? { mailbox.read("request.json") }
        func saveAnswer(_ answer: LivenessAnswer) throws { try mailbox.save(answer, as: "answer.json") }
        func answer() -> LivenessAnswer? { mailbox.read("answer.json") }
    }

    struct ExtensionChannel: LivenessChannel {
        let files: Files

        func ask(_ request: LivenessRequest) throws {
            try files.saveRequest(request)
            notify_post(AppLiveness.ringName)
        }

        func latestAnswer() -> LivenessAnswer? { files.answer() }
    }

    // Answers only when the app can keep the promise and then presents: its socket may be stale, as the server pushed.
    @MainActor final class Responder {
        private let files: Files
        private let conditions: @MainActor () -> LivenessConditions
        private let answered: @MainActor () -> Void
        private var token: Int32 = NOTIFY_TOKEN_INVALID
        private var answeredNonce: String?

        init(files: Files, conditions: @escaping @MainActor () -> LivenessConditions, answered: @escaping @MainActor () -> Void) {
            self.files = files; self.conditions = conditions; self.answered = answered
        }

        func start() -> Bool {
            guard token == NOTIFY_TOKEN_INVALID else { return true }
            let status = notify_register_dispatch(AppLiveness.ringName, &token, DispatchQueue.main) { [weak self] _ in
                MainActor.assumeIsolated { _ = self?.ring() }
            }
            guard status == NOTIFY_STATUS_OK else { token = NOTIFY_TOKEN_INVALID; return false }
            return true
        }

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
