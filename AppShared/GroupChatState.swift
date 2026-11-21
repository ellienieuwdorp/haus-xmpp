import Foundation
import OMEMO
import XMPPProtocol

struct GroupChatState {
    var members: [String] = []
    var devices: [EncryptionDevice] = []
    var devicesLoaded = false
    var localDeviceID: UInt32?
    var localFingerprint: String?
    // A transport fact: it gates sending and never the trust pill. Being admitted ends a removal.
    var joined = false {
        didSet { if joined { removal = nil; mayRejoin = false } }
    }
    var issue: String?
    // The room's own word that it no longer counts us, held across disconnects until a join succeeds.
    private(set) var removal: XMPPGroupRemoval?
    // A kick keeps the affiliation; otherwise only a membership read that lists us again makes a join worth trying.
    private(set) var mayRejoin = false

    init(members: [String] = [], devices: [EncryptionDevice]? = nil) {
        self.members = members
        self.devices = devices ?? []
        devicesLoaded = devices != nil
    }

    mutating func noteRemoval(_ removal: XMPPGroupRemoval) {
        joined = false
        guard self.removal != removal else { return }
        self.removal = removal
        mayRejoin = removal == .kicked
    }

    // A membership read that leaves us out is the room's answer, as a removal presence is.
    mutating func noteFailure(_ error: any Error, issue: String? = nil) {
        if let issue { self.issue = issue }
        if case .notMember? = error as? XMPPGroupError { noteRemoval(.notMember) }
    }

    mutating func noteMembershipConfirmed() {
        issue = nil
        if removal != nil { mayRejoin = true }
    }

    static func failure(_ error: any Error) -> String {
        switch error as? XMPPGroupError {
        case .unsupportedRoom: "This group must be members-only and share its members’ addresses."
        case .incompleteMembership: "The group could not confirm its complete member list or your membership."
        case .membershipChanged: "Group membership changed. Refresh the group and try again."
        case .notJoined: "This account has not joined the group yet."
        case .notMember: "You’re not a member of this group."
        default: (error as? OMEMOError)?.errorDescription ?? "Could not open this group. Check its address and your membership."
        }
    }

    // A device rejected on the account itself is left out of group sends (`groupRecipients`) instead of holding them.
    func needsReview(account: String) -> Bool {
        devices.contains { $0.active && !$0.trust.permitsEncryption && !$0.isLeftOutOfGroups(account: account) }
    }
    func status(account: String) -> String {
        if removal != nil { return "You’re not a member of this group" }
        if let issue { return issue }
        if !joined { return "Waiting to join group" }
        if needsReview(account: account) { return "Review group encryption devices" }
        return "Group messages are end-to-end encrypted"
    }
}
