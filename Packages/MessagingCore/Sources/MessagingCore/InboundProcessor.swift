import Foundation
import MessageStore
import OMEMO
import XMPPProtocol

/// Every inbound stanza that changes durable state, in the app and the notification extension: decrypt, persist,
/// project, and acknowledge a stream-management barrier only when everything before it is durably disposed.
public actor InboundProcessor {
    public enum Outcome: Sendable, Equatable {
        /// Not a persistence event (connection state, presence, device lists); the caller decides.
        case ignored
        case stored
        /// Decryption failed but the ciphertext is retained for later trust or keys.
        case retained(problem: String)
        /// Never shown as content. A would-be bubble gets a durable placeholder row carrying the exact reason; an
        /// update from a device that excluded this one stores nothing.
        case excluded(reason: UnreadableReason)
        /// A server returned one of our stanzas; the message or update it named is failed.
        case rejected(RejectedOutgoing)
        case acknowledged
    }
    public enum Failure: Error, Sendable, Equatable {
        /// An earlier inbound stanza has no durable disposition, so the barrier was refused and the transport ended;
        /// the server redelivers from its last acknowledged count.
        case unsavedInbound
    }

    public nonisolated let client: XMPPClient
    private let encryption: OMEMOService
    private let account: String
    // False from a storage failure until the next barrier ends the stream.
    private var mayAcknowledge = true

    public init(encryption: OMEMOService, client: XMPPClient, account: String) {
        self.encryption = encryption; self.client = client; self.account = account
    }

    /// Throws only when the stanza could not be durably disposed or the barrier could not be honoured; both end the
    /// stream so nothing is skipped.
    public func process(_ event: XMPPEvent) async throws -> Outcome {
        switch event {
        case .encryptedMessage(let message):
            // Our own server's delay (offline storage, a hibernated stream's queue) is when it was sent, not now.
            do { _ = try await encryption.receive(account: account, message: message, transport: client, sentAt: message.serverStamp); return .stored }
            catch OMEMOError.notForThisDevice { return .excluded(reason: .notForThisDevice) }
            catch OMEMOError.undecryptable { return .excluded(reason: .decryptFailed) }
            catch {
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
        case .messageError(let error):
            // Only a bounce from the address we sent to counts: its server (or the room) returning the stanza. An error
            // one of a peer's resources wrote names a full JID; the message may still have reached the others.
            guard let chat = error.bouncedAddress else { return .ignored }
            do {
                let rejected = try await encryption.rejectOutgoing(account: account, chatID: chat, wireID: error.id, rejection: error.rejection)
                return rejected.map(Outcome.rejected) ?? .ignored
            } catch { mayAcknowledge = false; throw error }
        case .displayedSync(let items):
            // The client verified it came from our bare JID.
            do { _ = try await encryption.receiveDisplayedSync(account: account, items: items); return .stored }
            catch { mayAcknowledge = false; throw error }
        case .streamManagementBarrier(let token):
            defer { mayAcknowledge = true }
            guard mayAcknowledge else { await client.disconnect(); throw Failure.unsavedInbound }
            do { try await client.acknowledgeInbound(token) }
            catch { await client.disconnect(); throw error }
            return .acknowledged
        case .state, .message, .chatState, .groupPresence, .omemoDevices, .avatarMetadata, .encryptionFailure, .streamAcknowledged,
             .contactPresence, .subscription, .rosterItems, .blocklist:
            return .ignored
        }
    }
}
