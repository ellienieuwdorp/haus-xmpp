import Foundation
import OMEMO
import XMPPProtocol

/// The stored facts about one chat's devices that decide its trust, reduced so tests can state them directly.
struct DeviceTrustFacts: Equatable {
    /// Trust of each active device on the other side: the peer's in a 1:1 chat, the other members' in a group.
    var peerTrust: [DeviceTrust]
    /// An active device (own devices included) waits for a fingerprint decision.
    var needsReview: Bool
    /// A refresh for this peer completed at some point, so an empty list is a stored answer, not "not fetched".
    var peerKnown: Bool
    /// Every other participant has at least one active device. Always true for a 1:1 chat, whose one peer is
    /// covered by `peerTrust`; a group member without devices keeps the group from reading as verified.
    var everyPeerHasDevice: Bool

    init(peerTrust: [DeviceTrust], needsReview: Bool, peerKnown: Bool, everyPeerHasDevice: Bool = true) {
        self.peerTrust = peerTrust; self.needsReview = needsReview; self.peerKnown = peerKnown
        self.everyPeerHasDevice = everyPeerHasDevice
    }

    init(_ overview: EncryptionOverview, peer: String) {
        self.init(peerTrust: overview.devices.filter { $0.jid == peer && $0.active }.map(\.trust), needsReview: overview.needsTrust,
                  peerKnown: overview.isPeerKnown)
    }

    /// A known room was refreshed when it was joined, so its cached device list is always a stored answer.
    init(_ group: GroupChatState, account: String) {
        let active = group.devices.filter { $0.jid != account && $0.active }
        let owners = Set(active.map(\.jid))
        self.init(peerTrust: active.map(\.trust), needsReview: group.needsReview, peerKnown: true,
                  everyPeerHasDevice: group.members.allSatisfy { $0 == account || owners.contains($0) })
    }
}

/// How much the app knows about a chat's devices. "Not yet known" is its own case, so it never renders as "off".
enum EncryptionKnowledge: Equatable {
    /// The store has not answered for this chat yet.
    case pending
    /// Read from the store; not yet re-fetched on this connection.
    case stored(DeviceTrustFacts)
    /// Re-fetched from the server on the current connection.
    case refreshed(DeviceTrustFacts)

    var facts: DeviceTrustFacts? {
        switch self {
        case .pending: nil
        case .stored(let facts), .refreshed(let facts): facts
        }
    }
}

/// What a chat can do and show, derived from persisted facts. Connection state enters only through a group's
/// `canSend`, so connecting, disconnecting and reconnecting never change the pill or the attach button.
struct ChatCapabilities: Equatable {
    enum Encryption: Equatable {
        /// Nothing stored for this chat yet: neutral, never drawn as "not encrypted".
        case pending
        /// At least one usable device on the other side; verified only when every active one is `.verified` and, in a
        /// group, every other member has one.
        case encrypted(verified: Bool)
        /// An undecided device, a changed identity, or retained ciphertext for this chat.
        case needsReview
        /// A definitive answer: no usable device after a completed refresh, or a failed join. A device published only
        /// in the other OMEMO version is a Devices-screen notice, never a reason to hold the chat.
        case unavailable(String)
    }

    var encryption: Encryption
    /// The composer's attach button reads this and nothing else.
    var canAttach: Bool
    var canSend: Bool
    /// Active devices on the other side; nil while nothing is stored.
    var deviceCount: Int?

    /// Pure, so tests drive launch and reconnect sequences without an AppModel.
    /// - Parameters:
    ///   - uploadAvailable: the account's server offered XEP-0363 on its last completed discovery.
    ///   - groupJoined, groupIssue: transport facts of a group; ignored for a 1:1 chat.
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

/// Where encryption problems are written. Decryption, blocked plaintext, storage and refresh problems are words for
/// the Devices footer (and, for a group, under its Group Details pill); only a queued send that waits for a fingerprint
/// decision marks its chat for review. Nothing here changes stored trust, so a transient problem never moves the pill.
struct EncryptionAttention: Equatable {
    /// The Devices screen footer: the last refresh summary or the last problem.
    private(set) var diagnostics = ""
    /// Chats whose queued sends the outbox holds for a fingerprint decision (an undecided or changed device).
    private(set) var heldForTrust: Set<String> = []
    /// The last failed device read or refresh per group, until a refresh succeeds.
    private(set) var groupProblems: [String: String] = [:]

    /// The two OMEMO answers that ask the user to decide on a fingerprint. Everything else is a diagnostic.
    static func needsTrustDecision(_ error: any Error) -> Bool {
        guard let error = error as? OMEMOError else { return false }
        return error == .trustRequired || error == .identityChanged
    }

    /// The outbox reports held chats as their user-facing reason, so a trust hold is recognised by that text.
    static func needsTrustDecision(issue: String) -> Bool {
        [OMEMOError.trustRequired, .identityChanged].contains { $0.errorDescription == issue }
    }

    mutating func note(_ text: String) { diagnostics = text }

    /// One outbox preparation step's held chats (chat ID to reason). Trust holds mark their chat for review at once;
    /// the reason for `shownChat` (the chat on screen) goes to the footer. Returns the chats held for trust.
    @discardableResult
    mutating func hold(_ blocked: [String: String], shownChat: String?) -> Set<String> {
        let trust = Set(blocked.filter { Self.needsTrustDecision(issue: $0.value) }.keys)
        heldForTrust.formUnion(trust)
        if let shownChat, let reason = blocked[shownChat] { diagnostics = reason }
        return trust
    }

    /// A completed outbox pass: only the chats it held for trust stay marked.
    mutating func settlePass(heldForTrust held: Set<String>) { heldForTrust = held }

    /// The user decided on a device in this chat; the next pass marks it again if a send is still held.
    mutating func trustDecided(in chatID: String) { heldForTrust.remove(chatID) }

    /// A group's device read or refresh failed (`problem`) or succeeded (nil).
    mutating func groupDevices(_ room: String, problem: String?) {
        groupProblems[room] = problem
        if let problem { diagnostics = problem }
    }
}

/// The account's XEP-0363 service as last discovered, kept in the account-keyed preferences so the attach button
/// is there from the first frame after a relaunch or reconnect. Only a completed discovery changes it.
struct UploadServiceMemory {
    let defaults: UserDefaults

    private static func key(_ account: String) -> String { "uploadService.\(account)" }

    func load(account: String) -> XMPPUploadService? {
        guard !account.isEmpty, let saved = defaults.dictionary(forKey: Self.key(account)),
              let jid = saved["jid"] as? String, !jid.isEmpty else { return nil }
        return XMPPUploadService(jid: jid, maximumFileSize: saved["maximumFileSize"] as? Int)
    }

    /// A thrown discovery (a dropped stream, a timeout) keeps what was known. A completed one replaces it,
    /// including a completed "none offered", which stands until the next completed answer.
    func settle(account: String, previous: XMPPUploadService?, discovery: Result<XMPPUploadService?, any Error>) -> XMPPUploadService? {
        guard case .success(let found) = discovery, !account.isEmpty else { return previous }
        if let found {
            var saved: [String: Any] = ["jid": found.jid]
            if let limit = found.maximumFileSize { saved["maximumFileSize"] = limit }
            defaults.set(saved, forKey: Self.key(account))
        } else { defaults.removeObject(forKey: Self.key(account)) }
        return found
    }

    func forget(account: String) { defaults.removeObject(forKey: Self.key(account)) }
}

extension AppModel {
    /// The one derived value per chat that views read for trust, sending and attaching.
    func chatCapabilities(_ chatID: String) -> ChatCapabilities {
        let group = groupChats[chatID]
        // Review means a stored device is undecided or a send is held for a fingerprint decision. Retained ciphertext
        // is not a review by itself: a carbon from another own client or a message from a removed device stays
        // retained with nothing to approve, and blaming a new device for it was wrong (2026-09-25).
        return ChatCapabilities.derive(isDemo: isDemo, isGroup: group != nil, knowledge: encryptionKnowledge(for: chatID),
                                       reviewPending: encryptionAttention.heldForTrust.contains(chatID),
                                       groupJoined: group?.joined == true,
                                       groupIssue: group?.issue, uploadAvailable: canSendAttachments, sessionReady: session.isReady)
    }
}
