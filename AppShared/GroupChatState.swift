import Foundation
import OMEMO

struct GroupChatState {
    var members: [String] = []
    var devices: [EncryptionDevice] = []
    /// The cached device list has been read from the store; until then the group's trust is pending, not "off".
    var devicesLoaded = false
    var localDeviceID: UInt32?
    var localFingerprint: String?
    /// A transport fact: it gates sending and never the trust pill.
    var joined = false
    /// Why joining failed. Only a failed join (while not joined) makes the pill unavailable.
    var issue: String?

    /// `devices` from a completed store read or refresh marks the list loaded; without them the trust is pending.
    init(members: [String] = [], devices: [EncryptionDevice]? = nil) {
        self.members = members
        self.devices = devices ?? []
        devicesLoaded = devices != nil
    }

    /// An active device holds group sends: an undecided one, or another member's rejected one. A device rejected on the
    /// account itself is left out of group sends instead (`groupRecipients`).
    func needsReview(account: String) -> Bool {
        devices.contains { $0.active && !$0.trust.permitsEncryption && !$0.isLeftOutOfGroups(account: account) }
    }
    func status(account: String) -> String {
        if let issue { return issue }
        if !joined { return "Waiting to join group" }
        if needsReview(account: account) { return "Review group encryption devices" }
        return "Group messages are end-to-end encrypted"
    }
}
