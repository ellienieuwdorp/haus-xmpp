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

    var needsReview: Bool { devices.contains { $0.active && !$0.trust.permitsEncryption } }
    var status: String {
        if let issue { return issue }
        if !joined { return "Waiting to join group" }
        if needsReview { return "Review group encryption devices" }
        return "Group messages are end-to-end encrypted"
    }
}
