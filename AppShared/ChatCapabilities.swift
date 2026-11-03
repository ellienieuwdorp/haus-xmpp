import Foundation
import OMEMO
import XMPPProtocol

struct DeviceTrustFacts: Equatable {
    var peerTrust: [DeviceTrust]
    var needsReview: Bool
    // True once a refresh completed, so an empty list is a stored answer rather than "not fetched".
    var peerKnown: Bool
    // A group member without devices keeps the group from reading as verified.
    var everyPeerHasDevice: Bool

    init(peerTrust: [DeviceTrust], needsReview: Bool, peerKnown: Bool, everyPeerHasDevice: Bool = true) {
        self.peerTrust = peerTrust; self.needsReview = needsReview; self.peerKnown = peerKnown
        self.everyPeerHasDevice = everyPeerHasDevice
    }

    init(_ overview: EncryptionOverview, peer: String) {
        // Only the sending profile's devices decide the pill; a device held for reading in the other profile never
        // makes the chat read as encrypted to a peer it cannot send to.
        self.init(peerTrust: overview.devices.filter { $0.jid == peer && $0.active && $0.profile == overview.profile }.map(\.trust), needsReview: overview.needsTrust,
                  peerKnown: overview.isPeerKnown)
    }

    init(_ group: GroupChatState, account: String) {
        let active = group.devices.filter { $0.jid != account && $0.active }
        let owners = Set(active.map(\.jid))
        self.init(peerTrust: active.map(\.trust), needsReview: group.needsReview(account: account), peerKnown: true,
                  everyPeerHasDevice: group.members.allSatisfy { $0 == account || owners.contains($0) })
    }
}

enum EncryptionKnowledge: Equatable {
    case pending
    case stored(DeviceTrustFacts)
    case refreshed(DeviceTrustFacts)

    var facts: DeviceTrustFacts? {
        switch self {
        case .pending: nil
        case .stored(let facts), .refreshed(let facts): facts
        }
    }
}

// Connection state enters only through a group's `canSend`, so reconnecting never changes the pill or attach button.
struct ChatCapabilities: Equatable {
    enum Encryption: Equatable {
        case pending
        case encrypted(verified: Bool)
        case needsReview
        case unavailable(String)
    }

    var encryption: Encryption
    var canAttach: Bool
    var canSend: Bool
    var deviceCount: Int?

    static func derive(isDemo: Bool, isGroup: Bool, knowledge: EncryptionKnowledge, reviewPending: Bool,
                       groupJoined: Bool = false, groupIssue: String? = nil, uploadAvailable: Bool, sessionReady: Bool) -> ChatCapabilities {
        let canAttach = !isGroup && (isDemo || uploadAvailable)
        if isDemo { return ChatCapabilities(encryption: .encrypted(verified: false), canAttach: canAttach, canSend: true, deviceCount: nil) }
        // A 1:1 message is queued and sealed later, so it is always accepted; a group send needs our own room presence.
        let canSend = isGroup ? sessionReady && groupJoined : true
        let facts = knowledge.facts
        let encryption: Encryption
        if reviewPending || facts?.needsReview == true { encryption = .needsReview }
        else if isGroup, let groupIssue, !groupJoined { encryption = .unavailable(groupIssue) }
        else if let facts {
            if facts.peerTrust.contains(where: \.permitsEncryption) {
                encryption = .encrypted(verified: facts.everyPeerHasDevice && facts.peerTrust.allSatisfy { $0 == .verified })
            } else if case .refreshed = knowledge { encryption = .unavailable(Self.noDevices(isGroup)) }
            else if facts.peerKnown { encryption = .unavailable(Self.noDevices(isGroup)) }
            else { encryption = .pending }
        } else { encryption = .pending }
        return ChatCapabilities(encryption: encryption, canAttach: canAttach, canSend: canSend, deviceCount: facts?.peerTrust.count)
    }

    private static func noDevices(_ isGroup: Bool) -> String {
        isGroup ? "No compatible devices in this group" : "No compatible encryption devices"
    }
}

// Nothing here changes stored trust, so a transient problem never moves the pill.
struct EncryptionAttention: Equatable {
    private(set) var diagnostics = ""
    private(set) var heldForTrust: Set<String> = []
    private(set) var groupProblems: [String: String] = [:]

    // The outbox reports holds as user-facing text, so a trust hold is recognised by that text.
    static func needsTrustDecision(issue: String) -> Bool {
        [OMEMOError.trustRequired, .identityChanged].contains { $0.errorDescription == issue }
    }

    mutating func note(_ text: String) { diagnostics = text }

    @discardableResult
    mutating func hold(_ blocked: [String: String], shownChat: String?) -> Set<String> {
        let trust = Set(blocked.filter { Self.needsTrustDecision(issue: $0.value) }.keys)
        heldForTrust.formUnion(trust)
        if let shownChat, let reason = blocked[shownChat] { diagnostics = reason }
        return trust
    }

    mutating func settlePass(heldForTrust held: Set<String>) { heldForTrust = held }

    mutating func trustDecided(in chatID: String) { heldForTrust.remove(chatID) }

    mutating func trustDecidedForAccount() { heldForTrust.removeAll() }

    mutating func groupDevices(_ room: String, problem: String?) {
        groupProblems[room] = problem
        if let problem { diagnostics = problem }
    }
}

// Kept per account so the attach button shows from the first frame after a relaunch. `mirror` is the App Group's
// defaults, which the share extension reads to offer files and enforce the server's size limit.
struct UploadServiceMemory {
    let defaults: UserDefaults
    var mirror: UserDefaults? = nil
    static let lifetime: TimeInterval = 24 * 60 * 60

    private static func key(_ account: String) -> String { "uploadService.\(account)" }
    private static func checkedKey(_ account: String) -> String { "uploadServiceCheckedAt.\(account)" }

    func isFresh(account: String, now: Date = .now) -> Bool {
        guard !account.isEmpty, let at = defaults.object(forKey: Self.checkedKey(account)) as? Date else { return false }
        return at <= now && now.timeIntervalSince(at) < Self.lifetime
    }

    func load(account: String) -> XMPPUploadService? {
        guard !account.isEmpty, let saved = defaults.dictionary(forKey: Self.key(account)),
              let jid = saved["jid"] as? String, !jid.isEmpty else { return nil }
        return XMPPUploadService(jid: jid, maximumFileSize: saved["maximumFileSize"] as? Int)
    }

    // A thrown discovery keeps what was known; a completed one, "none offered" included, replaces it.
    func settle(account: String, previous: XMPPUploadService?, discovery: Result<XMPPUploadService?, any Error>, now: Date = .now) -> XMPPUploadService? {
        guard case .success(let found) = discovery, !account.isEmpty else { return previous }
        defaults.set(now, forKey: Self.checkedKey(account))
        Self.save(found, account: account, in: defaults)
        if let mirror { Self.save(found, account: account, in: mirror, keepingNone: true) }
        return found
    }

    func publish(account: String) {
        guard let mirror, !account.isEmpty else { return }
        guard defaults.object(forKey: Self.checkedKey(account)) != nil else { return }
        Self.save(load(account: account), account: account, in: mirror, keepingNone: true)
    }

    // Without the app's copied answer the extension cannot tell a server without uploads from an app not yet updated.
    func hasAnswer(account: String) -> Bool { !account.isEmpty && defaults.object(forKey: Self.key(account)) != nil }

    func forget(account: String) {
        defaults.removeObject(forKey: Self.key(account))
        defaults.removeObject(forKey: Self.checkedKey(account))
        mirror?.removeObject(forKey: Self.key(account))
    }

    private static func save(_ service: XMPPUploadService?, account: String, in defaults: UserDefaults, keepingNone: Bool = false) {
        if let service {
            var saved: [String: Any] = ["jid": service.jid]
            if let limit = service.maximumFileSize { saved["maximumFileSize"] = limit }
            defaults.set(saved, forKey: key(account))
        } else if keepingNone { defaults.set(["jid": ""], forKey: key(account)) }
        else { defaults.removeObject(forKey: key(account)) }
    }
}

// Failing stranded uploads as "no longer offered" needs a known answer: a stored service or a discovery completed on
// this connection. A thrown discovery knows nothing and leaves them for a later answer.
struct UploadReconciliation {
    private var awaitingAnswer = false

    mutating func setupStarted(discovers: Bool) { awaitingAnswer = discovers }

    func reconcilesAtReady(stored: XMPPUploadService?) -> Bool { stored != nil || !awaitingAnswer }

    mutating func discoverySettled(_ discovery: Result<XMPPUploadService?, any Error>, previous: XMPPUploadService?, ready: Bool) -> Bool {
        guard case .success(let found) = discovery else { return false }
        awaitingAnswer = false
        return ready && (previous == nil || found == nil)
    }
}
