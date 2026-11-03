import Foundation

/// Asked by the notification extension when it finds the transport lease busy. A fresh nonce per lease wait means a
/// stale answer file, or a ring from anyone else, never counts.
public struct LivenessRequest: Codable, Sendable, Equatable {
    public let nonce: String
    public let sentAt: Date

    public init(nonce: String = UUID().uuidString, sentAt: Date = Date()) {
        self.nonce = nonce; self.sentAt = sentAt
    }
}

/// The app owns the lease, is connected or reconnecting, and presents what arrives itself.
public struct LivenessAnswer: Codable, Sendable, Equatable {
    public let nonce: String
    public let answeredAt: Date

    public init(nonce: String, answeredAt: Date = Date()) {
        self.nonce = nonce; self.answeredAt = answeredAt
    }
}

/// All must hold for the app to answer; otherwise it stays silent and the extension falls back.
public struct LivenessConditions: Sendable, Equatable {
    /// Transport wanted, a usable signed-in account, and no upgrade, transfer, offline choice or rejected password.
    public var wantsConnection: Bool
    /// A background transition, sleep or sign-out is under way, so the lease is about to go.
    public var quiescing: Bool
    public var ownsLease: Bool
    public var servesExtensionAccount: Bool
    /// The app may sleep or reconnect after answering, so the message can arrive in its next catch-up; only an app
    /// that posts banners for caught-up messages keeps the promise. The iPhone drops them, so it never answers.
    public var presentsCatchUp: Bool

    public init(wantsConnection: Bool, quiescing: Bool, ownsLease: Bool, servesExtensionAccount: Bool, presentsCatchUp: Bool) {
        self.wantsConnection = wantsConnection; self.quiescing = quiescing
        self.ownsLease = ownsLease; self.servesExtensionAccount = servesExtensionAccount
        self.presentsCatchUp = presentsCatchUp
    }

    var canPromise: Bool { wantsConnection && !quiescing && ownsLease && servesExtensionAccount && presentsCatchUp }
}

/// How the extension rings a running app and reads its answer.
public protocol LivenessChannel: Sendable {
    /// Saves `request` where the app reads it, then rings the app.
    func ask(_ request: LivenessRequest) throws
    /// Whatever request it answered; nil when absent or unreadable.
    func latestAnswer() -> LivenessAnswer?
}

/// A push can wake the extension while a running app holds the lease. A live app that answers in time takes the push
/// over: the extension suppresses the remote alert and leaves the candidates for the app's claim. No answer, a wrong
/// one or a late one is unknown, which is never suppressed: the extension waits for the lease and falls back.
public enum LivenessHandshake {
    /// An app that can keep the promise answers within milliseconds.
    public static let answerWindow: TimeInterval = 1.5
    /// A ring delivered later (an app resumed from suspension, a slow main thread) is for an extension that has
    /// stopped listening, or soon will.
    public static let requestLifetime: TimeInterval = 1.0
    // Both processes read one wall clock; this only absorbs the rounding of the timestamps they write.
    static let clockTolerance: TimeInterval = 0.25

    /// The app's side: nil stays silent.
    public static func answer(to request: LivenessRequest?, conditions: LivenessConditions, now: Date = Date()) -> LivenessAnswer? {
        guard let request, conditions.canPromise, !request.nonce.isEmpty else { return nil }
        let age = now.timeIntervalSince(request.sentAt)
        guard age >= -clockTolerance, age <= requestLifetime else { return nil }
        return LivenessAnswer(nonce: request.nonce, answeredAt: now)
    }

    /// The extension's side: only an answer to this request's nonce, given and read inside the answer window.
    public static func accepts(_ answer: LivenessAnswer?, to request: LivenessRequest, now: Date = Date()) -> Bool {
        guard let answer, !request.nonce.isEmpty, answer.nonce == request.nonce else { return false }
        let deadline = request.sentAt.addingTimeInterval(answerWindow)
        return now <= deadline && answer.answeredAt <= deadline && answer.answeredAt >= request.sentAt.addingTimeInterval(-clockTolerance)
    }

    public static func isListening(to request: LivenessRequest, now: Date = Date()) -> Bool {
        now <= request.sentAt.addingTimeInterval(answerWindow)
    }
}
