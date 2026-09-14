import CryptoKit
import Foundation

/// XEP-0454 file bytes: AES-256-GCM ciphertext followed by its 16-byte tag.
/// Key and IV must travel only inside encrypted message content, never an upload request.
public struct EncryptedAttachment: Equatable, Sendable {
  public let ciphertext: Data
  public let key: Data
  public let iv: Data
  public init(ciphertext: Data, key: Data, iv: Data) {
    self.ciphertext = ciphertext
    self.key = key
    self.iv = iv
  }
}
public enum AttachmentCrypto {
  /// Bounded in-memory foundation. Large-file streaming belongs in the future media pipeline.
  public static func seal(_ plaintext: Data, maximumBytes: Int = 32 * 1024 * 1024) throws
    -> EncryptedAttachment
  {
    guard maximumBytes >= 0, plaintext.count <= maximumBytes else {
      throw OMEMOCryptoError.invalidInput
    }
    let key = SymmetricKey(size: .bits256)
    let nonce = AES.GCM.Nonce()
    let sealed = try AES.GCM.seal(plaintext, using: key, nonce: nonce)
    return EncryptedAttachment(
      ciphertext: Data(sealed.ciphertext) + sealed.tag,
      key: key.withUnsafeBytes { Data($0) }, iv: nonce.withUnsafeBytes { Data($0) })
  }
  /// Returns bytes only after GCM authentication succeeds. No partial plaintext escapes.
  public static func open(_ attachment: EncryptedAttachment, maximumBytes: Int = 32 * 1024 * 1024)
    throws -> Data
  {
    guard maximumBytes >= 0, attachment.key.count == 32, attachment.iv.count == 12,
      attachment.ciphertext.count >= 16, attachment.ciphertext.count - 16 <= maximumBytes
    else { throw OMEMOCryptoError.invalidInput }
    do {
      let box = try AES.GCM.SealedBox(
        nonce: AES.GCM.Nonce(data: attachment.iv),
        ciphertext: attachment.ciphertext.dropLast(16), tag: attachment.ciphertext.suffix(16))
      return try AES.GCM.open(box, using: SymmetricKey(data: attachment.key))
    } catch { throw OMEMOCryptoError.authenticationFailed }
  }
}
