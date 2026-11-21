import Foundation
import MessageStore
import OMEMOCrypto
import XMPPProtocol

extension OMEMOService {
    typealias Retain = (PendingEncryptedReason, PendingNotificationContext?, Bool) async throws -> Bool

    // `retain` is set when nothing was kept before the decrypt; `alert` only on the ciphertext's first observation.
    struct FailedDecrypt {
        let account: String, digest: String
        let alert: PendingNotificationContext?
        let retain: Retain?
        let transport: any OMEMOTransport
    }

    // A trusted device's ciphertext that failed to decrypt. Throws its outcome, or returns false when a limit gave it
    // its final outcome.
    func settleDecryptFailure(_ error: OMEMOCryptoError, message: XMPPEncryptedMessage, sentAt: Date?, in failed: FailedDecrypt) async throws -> Bool {
        let sender = bare(message.from)
        func unreadable() async throws -> Bool {
            try await recordDecryptFailure(account: failed.account, message: message, sender: sender, digest: failed.digest, sentAt: sentAt)
        }
        guard error == .untrustedIdentity else { return try await undecryptable(unreadable) }
        return try await settleRefusedIdentity(owner: sender, deviceID: message.envelope.senderDeviceID, profile: message.envelope.profile,
                                               in: failed, unreadable: unreadable)
    }

    func settleGroupDecryptFailure(_ error: OMEMOCryptoError, message: XMPPEncryptedGroupMessage, sentAt: Date,
                                   in failed: FailedDecrypt) async throws -> Bool {
        func unreadable() async throws -> Bool {
            try await recordGroupDecryptFailure(account: failed.account, message: message, digest: failed.digest, sentAt: sentAt)
            return true
        }
        guard error == .untrustedIdentity else { return try await undecryptable(unreadable) }
        return try await settleRefusedIdentity(owner: message.sender, deviceID: message.envelope.senderDeviceID, profile: .modern,
                                               in: failed, unreadable: unreadable)
    }

    // A prekey message under an approved device ID carried another identity. Nothing is committed and nothing answers it;
    // the ciphertext is kept before the sender lookup, then waits for review when that device ID now publishes another
    // key, or becomes a placeholder while the approved key is still the published one.
    private func settleRefusedIdentity(owner: String, deviceID: UInt32, profile: XMPPOMEMOProfile, in failed: FailedDecrypt,
                                       unreadable: () async throws -> Bool) async throws -> Bool {
        if let retain = failed.retain { guard try await retain(.trustPending, nil, false) else { return false } }
        func awaitReview() async throws {
            try await store.classifyPendingEncryptedIncoming(accountID: failed.account, sender: owner, digest: failed.digest, reason: .trustPending,
                                                             notification: failed.alert)
        }
        do {
            try await refreshSenderDeviceLocked(account: failed.account, owner: owner, deviceID: deviceID, profile: profile, transport: failed.transport)
        } catch {
            try await awaitReview()
            throw error
        }
        let (_, state) = try await load(failed.account)
        guard state.devices.last(where: { $0.jid == owner && $0.profile == profile && $0.deviceID == deviceID })?.trust == .undecided else {
            return try await undecryptable(unreadable)
        }
        try await awaitReview()
        throw OMEMOError.trustRequired
    }

    private func undecryptable(_ record: () async throws -> Bool) async throws -> Bool {
        guard try await record() else { return false }
        throw OMEMOError.undecryptable
    }
}
