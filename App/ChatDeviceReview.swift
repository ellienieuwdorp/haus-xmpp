import Foundation
import OMEMO

/// What a chat's review prompt says and lists, derived from its stored devices so tests can state it directly.
enum ChatDeviceReview {
    /// The devices that keep the chat waiting, each with its own fingerprint: in a 1:1 chat the active undecided devices
    /// of the contact and of the account, in the version the chat sends with (sending waits) or the other one (its
    /// messages wait to be read); in a group the active devices that hold its sends (`GroupChatState.needsReview`).
    /// The contact's or members' devices first, then the account's, each in device ID order.
    static func devices(_ devices: [EncryptionDevice], account: String, isGroup: Bool) -> [EncryptionDevice] {
        devices.filter { holds($0, account: account, isGroup: isGroup) }.sorted {
            ($0.jid == account ? 1 : 0, $0.jid, $0.deviceID, $0.profile.rawValue) < ($1.jid == account ? 1 : 0, $1.jid, $1.deviceID, $1.profile.rawValue)
        }
    }

    /// Whether `device` keeps the chat waiting. A group is held by another member's blocked device too; the account's
    /// own blocked devices are left out of group sends instead.
    static func holds(_ device: EncryptionDevice, account: String, isGroup: Bool) -> Bool {
        guard device.active else { return false }
        if isGroup { return !device.trust.permitsEncryption && !device.isLeftOutOfGroups(account: account) }
        return device.trust == .undecided
    }

    /// The decision made on a listed device since the review opened: its stored record's trust once that no longer keeps
    /// the chat waiting, else the decision the review saved (`decided`, by fingerprint-scoped ID) for a device the chat
    /// no longer lists, as the other version's device does once the messages it held are released. Nil while it waits,
    /// and for a record that went inactive undecided (its key was replaced), which the next decision reports as changed.
    static func outcome(of device: EncryptionDevice, in devices: [EncryptionDevice], decided: [String: DeviceTrust] = [:],
                        account: String, isGroup: Bool) -> DeviceTrust? {
        guard let current = devices.first(where: { $0.id == device.id }) else { return decided[device.id] }
        guard !holds(current, account: account, isGroup: isGroup), current.trust != .undecided else { return nil }
        return current.trust
    }

    /// The prompt's title, as the iPhone's review card words it: the contact's new device, the account's own, or a
    /// group's; when only reading waits, the waiting messages.
    static func headline(sendingWaits: Bool, isGroup: Bool, ownDevicesOnly: Bool, title: String) -> String {
        guard sendingWaits else { return "Messages waiting for review" }
        return isGroup ? "Devices need review" : ownDevicesOnly ? "New device on your account" : "\(title) added a new device"
    }

    /// The prompt's explanation under `headline`.
    static func explanation(sendingWaits: Bool) -> String {
        sendingWaits
            ? "Check its fingerprint before sending. Until then, nothing you write here leaves this \(ThisDevice.noun)."
            : "They come from a device you haven’t reviewed yet. Check its fingerprint to read them."
    }

    /// The Don't Trust confirmation for one device: what stops, and for another member's device in a group, that the
    /// whole group's sending pauses.
    static func rejectionMessage(for device: EncryptionDevice, account: String, isGroup: Bool) -> String {
        if device.jid == account { return OwnDeviceReview.rejectionMessage }
        if isGroup { return "Nothing it sends will be opened. Blocking another member’s device pauses sending to the whole group." }
        return "Your messages won’t be encrypted for it, and nothing it sends will be opened."
    }
}
