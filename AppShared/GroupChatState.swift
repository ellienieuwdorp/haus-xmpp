import Foundation
import OMEMO

struct GroupChatState {
    var members: [String] = []
    var devices: [EncryptionDevice] = []
    var devicesLoaded = false
    var localDeviceID: UInt32?
    var localFingerprint: String?
    // A transport fact: it gates sending and never the trust pill.
    var joined = false
    var issue: String?

    init(members: [String] = [], devices: [EncryptionDevice]? = nil) {
        self.members = members
        self.devices = devices ?? []
        devicesLoaded = devices != nil
    }

    // A device rejected on the account itself is left out of group sends (`groupRecipients`) instead of holding them.
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
