import Foundation
import MessageStore
import OMEMO
import XMPPProtocol

/// The database still holds encryption state that the Keychain wrapping key cannot open: the key is gone (a move to
/// another device, a Keychain reset) or is another one. Shown on the recovery screen; nothing changes until the user
/// confirms (docs/development/key-recovery.md).
struct KeyRecoveryPlan: Equatable {
    /// The Keychain item is gone, so starting over creates one. False: a key is there but opens none of `states`.
    let keyMissing: Bool
    /// Every row the key cannot open, at the revision it was read at.
    let states: [UnreadableEncryptionState]
    /// The saved account, which gets its new identity right away; empty when none is signed in.
    let account: String
    /// `-demo-key-recovery`: confirming only dismisses the screen.
    var isSample = false

    /// The saved account's lost state, if it has any.
    var current: UnreadableEncryptionState? {
        states.first { JID.normalizedBare($0.accountID) == JID.normalizedBare(account) }
    }
    /// Other accounts used on this device whose state goes too.
    var otherAccounts: Int { states.count - (current == nil ? 0 : 1) }
    var waitingMessages: Int { states.reduce(0) { $0 + $1.loss.waitingMessages } }
    var unsendableFiles: Int { states.reduce(0) { $0 + $1.loss.unsendableFiles } }
    /// Every lost device's ID was recorded, so each leaves its account's device lists on the next connection.
    var retiresOldDevices: Bool { states.allSatisfy { $0.deviceID != nil } }

    /// The saved account and one other, so the screen and the confirmation show every line that depends on the plan.
    static func sample(account: String) -> KeyRecoveryPlan {
        KeyRecoveryPlan(keyMissing: true, states: [UnreadableEncryptionState(accountID: account, revision: 1, deviceID: 1_234_567,
                                                                               loss: EncryptionLossCounts(waitingMessages: 2, unsendableFiles: 0)),
                                                   UnreadableEncryptionState(accountID: "work@example.org", revision: 1, deviceID: 7_654_321,
                                                                               loss: EncryptionLossCounts(waitingMessages: 0, unsendableFiles: 0))],
                        account: account, isSample: true)
    }
}

enum KeyRecovery {
    enum Access {
        case ready(OMEMOService)
        case needed(KeyRecoveryPlan)
    }

    /// Reads `storageID`'s wrapping key for `store` and checks that it opens every encryption state row. A key is
    /// created only while the database has no state. A missing key, or rows it cannot open, need the recovery screen;
    /// any other Keychain failure (a locked device, an unreadable item) throws, and storage stays closed as before.
    static func open(store: MessageStore, storageID: String, account: String) async throws -> Access {
        let hasState = try await store.hasAnyEncryptionState()
        let key: Data?
        do { key = try EncryptionKeychain.load(storageID: storageID, allowCreation: !hasState) }
        catch EncryptionKeychain.Failure.missing { key = nil }
        let protection = try key.map { try StateProtection(key: $0) }
        let lost = try await OMEMOService.unreadableStates(store: store, protection: protection)
        guard let protection, lost.isEmpty else { return .needed(KeyRecoveryPlan(keyMissing: key == nil, states: lost, account: account)) }
        let service = OMEMOService(store: store, protection: protection)
        // While the key still opens the state: so a later loss knows which device to retire.
        try await service.recordLocalDeviceIDs()
        return .ready(service)
    }

    /// The user confirmed `plan`. Needs the store's lease. Creates the wrapping key if it is missing (the only place
    /// besides an empty database where one is made), then discards exactly the rows the user was shown, each only if
    /// unchanged and still unreadable with that key, and creates the saved account's new identity under a new device ID.
    /// Returns that ID, or nil when the saved account had no state to replace.
    static func startOver(_ plan: KeyRecoveryPlan, store: MessageStore, storageID: String) async throws -> UInt32? {
        guard await store.holdsTransportOwnership else { throw MessageStoreError.transportOwnershipRequired }
        let key = try EncryptionKeychain.load(storageID: storageID, allowCreation: true)
        let service = OMEMOService(store: store, protection: try StateProtection(key: key))
        return try await service.startOver(account: plan.account.isEmpty ? nil : plan.account, discarding: plan.states)
    }
}
