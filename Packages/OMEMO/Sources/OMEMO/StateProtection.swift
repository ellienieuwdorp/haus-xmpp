import Foundation
import CryptoKit
import XMPPProtocol

/// AES-GCM with the account as associated data, so a valid state blob cannot move into another account's row.
/// The key is device-local (Keychain in the app).
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
    // `sealedAs` is the unnormalised address spelling an older blob was sealed under; it is honoured only when it
    // names the same account.
    func open(_ data: Data, account: String, sealedAs spelling: String? = nil) throws -> Data {
        let bound = spelling.flatMap { JID.normalizedBare($0) == JID.normalizedBare(account) ? $0 : nil } ?? account
        do { return try AES.GCM.open(AES.GCM.SealedBox(combined: data), using: key, authenticating: Data(bound.utf8)) }
        catch { throw OMEMOError.stateUnavailable }
    }
}
