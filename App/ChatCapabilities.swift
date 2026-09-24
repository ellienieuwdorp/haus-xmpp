import Foundation
import OMEMO
import XMPPProtocol

/// The stored facts about one chat's devices that decide its trust, reduced so tests can state them directly.
struct DeviceTrustFacts: Equatable {
    /// Trust of each active device on the other side: the peer's in a 1:1 chat, the other members' in a group.
    var peerTrust: [DeviceTrust]
    /// An active device (own devices included) waits for a fingerprint decision.
    var needsReview: Bool
    var incompatible: Bool
    /// A refresh for this peer completed at some point, so an empty list is a stored answer, not "not fetched".
    var peerKnown: Bool

    init(peerTrust: [DeviceTrust], needsReview: Bool, incompatible: Bool = false, peerKnown: Bool) {
        self.peerTrust = peerTrust; self.needsReview = needsReview; self.incompatible = incompatible; self.peerKnown = peerKnown
    }

    init(_ overview: EncryptionOverview, peer: String) {
        self.init(peerTrust: overview.devices.filter { $0.jid == peer && $0.active }.map(\.trust), needsReview: overview.needsTrust,
                  incompatible: overview.hasIncompatibleDevices, peerKnown: overview.isPeerKnown)
    }

    /// A known room was refreshed when it was joined, so its cached device list is always a stored answer.
    init(_ group: GroupChatState, account: String) {
        self.init(peerTrust: group.devices.filter { $0.jid != account && $0.active }.map(\.trust), needsReview: group.needsReview, peerKnown: true)
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
        /// At least one usable device on the other side; verified only when every active one is `.verified`.
        case encrypted(verified: Bool)
        /// An undecided device, a changed identity, or retained ciphertext for this chat.
        case needsReview
        /// A definitive answer: no usable device after a completed refresh, incompatible versions, or a failed join.
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
            if facts.incompatible { encryption = .unavailable("Devices use incompatible encryption versions") }
            else if facts.peerTrust.contains(where: \.permitsEncryption) {
                encryption = .encrypted(verified: facts.peerTrust.allSatisfy { $0 == .verified })
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
        return ChatCapabilities.derive(isDemo: isDemo, isGroup: group != nil, knowledge: encryptionKnowledge(for: chatID),
                                       reviewPending: pendingReviewChats.contains(chatID), groupJoined: group?.joined == true,
                                       groupIssue: group?.issue, uploadAvailable: canSendAttachments, sessionReady: session.isReady)
    }
}
