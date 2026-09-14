import Foundation
import OMEMO

struct GroupChatState {
    var members: [String] = []
    var devices: [EncryptionDevice] = []
    var localDeviceID: UInt32?
    var localFingerprint: String?
    var joined = false
    var issue: String?

    var needsReview: Bool { devices.contains { $0.active && !$0.trust.permitsEncryption } }
    var status: String {
        if let issue { return issue }
        if !joined { return "Waiting to join group" }
        if needsReview { return "Review group encryption devices" }
        return "Group messages are end-to-end encrypted"
    }
}
