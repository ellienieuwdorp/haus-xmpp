import Foundation
import CryptoKit
import XMPPProtocol

/// The app supplies a device-local Keychain key. Tests may supply an ephemeral key.
/// Account binding prevents moving a valid encrypted state blob into another account's row.
public struct StateProtection: Sendable {
    private let key: SymmetricKey
    public init(key: Data) throws {
        guard key.count == 32 else { throw OMEMOError.stateUnavailable }
        self.key = SymmetricKey(data: key)
    }
    func seal(_ data: Data, account: String) throws -> Data {
        guard let combined = try AES.GCM.seal(data, using: key, authenticating: Data(account.utf8)).combined else {
            throw OMEMOError.stateUnavailable
        }
        return combined
    }
    /// `sealedAs` is the spelling a blob saved before addresses were normalised was sealed under (the store keeps it).
    /// It is used only when it names the same account, so a blob still cannot move to another account's row.
    func open(_ data: Data, account: String, sealedAs spelling: String? = nil) throws -> Data {
        let bound = spelling.flatMap { JID.normalizedBare($0) == JID.normalizedBare(account) ? $0 : nil } ?? account
        do { return try AES.GCM.open(AES.GCM.SealedBox(combined: data), using: key, authenticating: Data(bound.utf8)) }
        catch { throw OMEMOError.stateUnavailable }
    }
}
