import Foundation

/// The notification extension's question to a running app, once it found the transport lease busy: "do you own the
/// lease, and will you present what this push is about?" A fresh random nonce per lease wait, so an answer can only be
/// to this question: a stale answer file, or a ring from anyone else, never counts.
public struct LivenessRequest: Codable, Sendable, Equatable {
    public let nonce: String
    public let sentAt: Date

    public init(nonce: String = UUID().uuidString, sentAt: Date = Date()) {
        self.nonce = nonce; self.sentAt = sentAt
    }
}

/// The app's answer: it owns the lease, is connected or reconnecting now, and presents what arrives itself. It echoes
/// the request's nonce.
public struct LivenessAnswer: Codable, Sendable, Equatable {
    public let nonce: String
    public let answeredAt: Date

    public init(nonce: String, answeredAt: Date = Date()) {
        self.nonce = nonce; self.answeredAt = answeredAt
    }
}

/// What the app must be able to promise before it answers. Any one missing keeps it silent, and the extension falls
/// back as it would without the handshake.
public struct LivenessConditions: Sendable, Equatable {
    /// The app wants its connection: the transport is wanted (on the iPhone, the app is in front), an account is signed
    /// in and usable, and no upgrade, transfer, offline choice or rejected password stops it.
    public var wantsConnection: Bool
    /// A background transition, sleep or sign-out is under way: the lease is about to go, and the connection with it.
    public var quiescing: Bool
    /// The app holds the transport lease the extension is waiting for.
    public var ownsLease: Bool
    /// The app's account is the one the extension serves (the saved notification account).
    public var servesExtensionAccount: Bool

    public init(wantsConnection: Bool, quiescing: Bool, ownsLease: Bool, servesExtensionAccount: Bool) {
        self.wantsConnection = wantsConnection; self.quiescing = quiescing
        self.ownsLease = ownsLease; self.servesExtensionAccount = servesExtensionAccount
    }

    var canPromise: Bool { wantsConnection && !quiescing && ownsLease && servesExtensionAccount }
}

/// How the extension rings a running app and reads its answer. The apps use the App Group and a Darwin notification
/// (`AppLiveness`); tests use a fake.
public protocol LivenessChannel: Sendable {
    /// Saves `request` where the app reads it, then rings the app.
    func ask(_ request: LivenessRequest) throws
    /// The app's latest answer, whatever request it was for; nil when there is none or it cannot be read.
    func latestAnswer() -> LivenessAnswer?
}

/// The extension-to-app liveness handshake. While the app runs it holds the transport lease, so an extension woken by a
/// push (an acknowledgement the server found overdue: sleep, a network change, a frozen app) would wait out its lease
/// wait and post the generic fallback next to the app's own banner. With the handshake it asks first, and a live app
/// that answers in time takes the push over: the extension ends handed off (the remote alert suppressed) and leaves the
/// candidates for the app's own claim. No answer, a wrong one or a late one keeps the old rule: unknown is never
/// suppressed, so the extension waits and falls back.
public enum LivenessHandshake {
    /// How long after its request the extension takes an answer. An app that can keep the promise answers within
    /// milliseconds; after this the extension waits for the lease as before.
    public static let answerWindow: TimeInterval = 1.5
    /// How old a request the app still answers. A ring delivered late (an app resumed from suspension, a slow main
    /// thread) is for an extension that has stopped listening, or soon will.
    public static let requestLifetime: TimeInterval = 1.0
    /// Two processes read one wall clock; this only absorbs the rounding of the timestamps they write.
    static let clockTolerance: TimeInterval = 0.25

    /// The app's side: the answer to send, or nil to stay silent (the extension then falls back).
    public static func answer(to request: LivenessRequest?, conditions: LivenessConditions, now: Date = Date()) -> LivenessAnswer? {
        guard let request, conditions.canPromise, !request.nonce.isEmpty else { return nil }
        let age = now.timeIntervalSince(request.sentAt)
        guard age >= -clockTolerance, age <= requestLifetime else { return nil }
        return LivenessAnswer(nonce: request.nonce, answeredAt: now)
    }

    /// The extension's side: whether `answer` hands this push to the app. Only an answer to this request's nonce,
    /// given and read inside the answer window.
    public static func accepts(_ answer: LivenessAnswer?, to request: LivenessRequest, now: Date = Date()) -> Bool {
        guard let answer, !request.nonce.isEmpty, answer.nonce == request.nonce else { return false }
        let deadline = request.sentAt.addingTimeInterval(answerWindow)
        return now <= deadline && answer.answeredAt <= deadline && answer.answeredAt >= request.sentAt.addingTimeInterval(-clockTolerance)
    }

    /// Whether the extension still listens for an answer to `request`.
    public static func isListening(to request: LivenessRequest, now: Date = Date()) -> Bool {
        now <= request.sentAt.addingTimeInterval(answerWindow)
    }
}
