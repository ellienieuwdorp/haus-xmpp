import Foundation
import MessageStore
import OMEMO
import XMPPProtocol

// Starting over keeps messages, gives a new identity under a new device ID and retires the old IDs. Nothing changes
// until the user confirms.
struct KeyRecoveryPlan: Equatable {
    let keyMissing: Bool
    let states: [UnreadableEncryptionState]
    let account: String
    var isSample = false

    var current: UnreadableEncryptionState? {
        states.first { JID.normalizedBare($0.accountID) == JID.normalizedBare(account) }
    }
    var otherAccounts: Int { states.count - (current == nil ? 0 : 1) }
    var waitingMessages: Int { states.reduce(0) { $0 + $1.loss.waitingMessages } }
    var unsendableFiles: Int { states.reduce(0) { $0 + $1.loss.unsendableFiles } }
    var retiresOldDevices: Bool { states.allSatisfy { $0.deviceID != nil } }

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

    // A key is created only while the database has no state; other Keychain failures throw and keep storage closed.
    static func open(store: MessageStore, storageID: String, account: String) async throws -> Access {
        let hasState = try await store.hasAnyEncryptionState()
        let key: Data?
        do { key = try EncryptionKeychain.load(storageID: storageID, allowCreation: !hasState) }
        catch EncryptionKeychain.Failure.missing { key = nil }
        let protection = try key.map { try StateProtection(key: $0) }
        let lost = try await OMEMOService.unreadableStates(store: store, protection: protection)
        guard let protection, lost.isEmpty else { return .needed(KeyRecoveryPlan(keyMissing: key == nil, states: lost, account: account)) }
        let service = OMEMOService(store: store, protection: protection)
        // Recorded while the key still opens the state, so a later loss knows which device to retire.
        try await service.recordLocalDeviceIDs()
        return .ready(service)
    }

    // Needs the store's lease. Discards only rows the user was shown that are unchanged and still unreadable.
    static func startOver(_ plan: KeyRecoveryPlan, store: MessageStore, storageID: String) async throws -> UInt32? {
        guard await store.holdsTransportOwnership else { throw MessageStoreError.transportOwnershipRequired }
        let key = try EncryptionKeychain.load(storageID: storageID, allowCreation: true)
        let service = OMEMOService(store: store, protection: try StateProtection(key: key))
        return try await service.startOver(account: plan.account.isEmpty ? nil : plan.account, discarding: plan.states)
    }
}
