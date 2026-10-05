import Foundation
import MessageStore
import OMEMO
import XMPPProtocol

/// Every inbound stanza that changes durable state goes through here, in the app and in the
/// notification extension alike: decrypt, persist, project, and honour the stream-management
/// barrier only when everything before it is durably disposed. Callers layer UI on the outcome.
public actor InboundProcessor {
    public enum Outcome: Sendable, Equatable {
        /// Not a persistence event (connection state, presence, device lists); the caller decides.
        case ignored
        /// Content persisted and projected.
        case stored
        /// Decryption failed but the ciphertext is retained for later trust or keys; nothing is lost.
        case retained(problem: String)
        /// Deliberately not shown as content. When the envelope would have been a bubble, a durable placeholder row now
        /// marks it; otherwise (an update from a device that excluded this one) nothing is stored. Nothing to review.
        /// The reason is the error class; the row carries the exact reason.
        case excluded(reason: UnreadableReason)
        /// The barrier was acknowledged to the server.
        case acknowledged
    }
    public enum Failure: Error, Sendable, Equatable {
        /// An earlier inbound stanza has no durable disposition, so the barrier was refused and
        /// the transport ended: the server will redeliver from its last acknowledged count.
        case unsavedInbound
    }

    public nonisolated let client: XMPPClient
    private let encryption: OMEMOService
    private let account: String
    /// False from a storage failure until the next barrier ends the stream.
    private var mayAcknowledge = true

    public init(encryption: OMEMOService, client: XMPPClient, account: String) {
        self.encryption = encryption; self.client = client; self.account = account
    }

    /// Throws only when the stanza could not be durably disposed (storage failure) or the
    /// barrier could not be honoured; both end the stream so nothing is skipped.
    public func process(_ event: XMPPEvent) async throws -> Outcome {
        switch event {
        case .encryptedMessage(let message):
            // Our own server's delay (offline storage, a hibernated stream's queue) is when it was sent, not now.
            do { _ = try await encryption.receive(account: account, message: message, transport: client, sentAt: message.serverStamp); return .stored }
            catch OMEMOError.notForThisDevice { return .excluded(reason: .notForThisDevice) }
            catch OMEMOError.undecryptable { return .excluded(reason: .decryptFailed) }
            catch {
                // A failed decrypt can still be safely retained for later explicit trust.
                // Storage failures and unretained content must stop before the next barrier.
                guard (try? await encryption.hasDurableIncomingDisposition(account: account, message: message)) ?? false else {
                    mayAcknowledge = false; throw error
                }
                return .retained(problem: (error as? OMEMOError)?.errorDescription ?? "An encrypted message needs attention")
            }
        case .encryptedGroupMessage(let message):
            do { _ = try await encryption.receiveGroup(account: account, message: message, transport: client, sentAt: message.serverStamp); return .stored }
            catch OMEMOError.notForThisDevice { return .excluded(reason: .notForThisDevice) }
            catch OMEMOError.undecryptable { return .excluded(reason: .decryptFailed) }
            catch {
                guard (try? await encryption.hasDurableGroupDisposition(account: account, message: message)) ?? false else {
                    mayAcknowledge = false; throw error
                }
                return .retained(problem: (error as? OMEMOError)?.errorDescription ?? "A group message needs attention")
            }
        case .reaction(let reaction):
            do { _ = try await encryption.receivePlaintextReaction(account: account, reaction: reaction); return .stored }
            catch { mayAcknowledge = false; throw error }
        case .retraction(let retraction):
            do { _ = try await encryption.receivePlaintextRetraction(account: account, retraction: retraction); return .stored }
            catch { mayAcknowledge = false; throw error }
        case .receipt(let receipt):
            do { _ = try await encryption.receivePlaintextReceipt(account: account, receipt: receipt); return .stored }
            catch { mayAcknowledge = false; throw error }
        case .displayedSync(let items):
            // XEP-0490 state another device of ours published; the client verified it came from our bare JID.
            do { _ = try await encryption.receiveDisplayedSync(account: account, items: items); return .stored }
            catch { mayAcknowledge = false; throw error }
        case .streamManagementBarrier(let token):
            defer { mayAcknowledge = true }
            guard mayAcknowledge else { await client.disconnect(); throw Failure.unsavedInbound }
            do { try await client.acknowledgeInbound(token) }
            catch { await client.disconnect(); throw error }
            return .acknowledged
        case .state, .message, .chatState, .groupPresence, .omemoDevices, .avatarMetadata, .encryptionFailure, .streamAcknowledged,
             .contactPresence, .subscription, .rosterItems:
            return .ignored
        }
    }
}
