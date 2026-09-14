import Foundation
import CryptoKit

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
    func open(_ data: Data, account: String) throws -> Data {
        do { return try AES.GCM.open(AES.GCM.SealedBox(combined: data), using: key, authenticating: Data(account.utf8)) }
        catch { throw OMEMOError.stateUnavailable }
    }
}
