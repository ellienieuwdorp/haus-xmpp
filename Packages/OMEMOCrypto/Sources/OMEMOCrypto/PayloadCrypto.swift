import COMEMOBridge
import CryptoKit
import Foundation
import Security

/// The OMEMO payload constructions compose Apple primitives exactly as XEP-0384 specifies.
/// SCE, UTF-8 validation, stanza author checks and durable state are owned by the coordinator.
public enum PayloadCrypto {
  public static func seal(_ plaintext: Data, profile: CryptoProfile) throws -> SealedPayload {
    guard plaintext.count <= 16 * 1024 * 1024 else { throw OMEMOCryptoError.invalidInput }
    switch profile {
    case .legacy:
      let key = SymmetricKey(size: .bits128)
      let nonce = AES.GCM.Nonce()
      let result = try AES.GCM.seal(plaintext, using: key, nonce: nonce)
      let material = key.withUnsafeBytes { Data($0) } + result.tag
      return SealedPayload(
        payload: Data(result.ciphertext), keyMaterial: material,
        iv: nonce.withUnsafeBytes { Data($0) })
    case .modern:
      let key = SymmetricKey(size: .bits256).withUnsafeBytes { Data($0) }
      let derived = derive(key)
      let ciphertext = try cbc(
        plaintext, key: Data(derived.prefix(32)), iv: Data(derived.suffix(16)), encrypt: true)
      let tag = Data(
        HMAC<SHA256>.authenticationCode(
          for: ciphertext, using: SymmetricKey(data: derived[32..<64])
        ).prefix(16))
      return SealedPayload(payload: ciphertext, keyMaterial: key + tag, iv: nil)
    }
  }
  public static func open(_ sealed: SealedPayload, profile: CryptoProfile) throws -> Data {
    guard sealed.payload.count <= 16 * 1024 * 1024 + 16 else { throw OMEMOCryptoError.invalidInput }
    switch profile {
    case .legacy:
      guard [16, 32].contains(sealed.keyMaterial.count), let iv = sealed.iv, iv.count == 12 else {
        throw OMEMOCryptoError.invalidInput
      }
      // Older deployed legacy senders append the GCM tag to payload and transport
      // only the 16-byte key. Never retry an authentication failure in another format.
      let appendedTag = sealed.keyMaterial.count == 16
      guard !appendedTag || sealed.payload.count >= 16 else { throw OMEMOCryptoError.invalidInput }
      let ciphertext = appendedTag ? Data(sealed.payload.dropLast(16)) : sealed.payload
      let tag = appendedTag ? sealed.payload.suffix(16) : sealed.keyMaterial.suffix(16)
      do {
        let box = try AES.GCM.SealedBox(
          nonce: AES.GCM.Nonce(data: iv), ciphertext: ciphertext, tag: tag)
        return try AES.GCM.open(box, using: SymmetricKey(data: sealed.keyMaterial.prefix(16)))
      } catch { throw OMEMOCryptoError.authenticationFailed }
    case .modern:
      guard sealed.keyMaterial.count == 48, sealed.iv == nil, !sealed.payload.isEmpty,
        sealed.payload.count.isMultiple(of: 16)
      else { throw OMEMOCryptoError.invalidInput }
      let derived = derive(Data(sealed.keyMaterial.prefix(32)))
      let expected = Data(
        HMAC<SHA256>.authenticationCode(
          for: sealed.payload, using: SymmetricKey(data: derived[32..<64])
        ).prefix(16))
      let valid = withDataPointers([expected, Data(sealed.keyMaterial.suffix(16))]) {
        om_equal($0[0], $0[1], 16) == 1
      }
      guard valid else { throw OMEMOCryptoError.authenticationFailed }
      do {
        return try cbc(
          sealed.payload, key: Data(derived.prefix(32)), iv: Data(derived.suffix(16)),
          encrypt: false)
      } catch { throw OMEMOCryptoError.authenticationFailed }
    }
  }
  private static func derive(_ key: Data) -> Data {
    HKDF<SHA256>.deriveKey(
      inputKeyMaterial: SymmetricKey(data: key), salt: Data(repeating: 0, count: 32),
      info: Data("OMEMO Payload".utf8), outputByteCount: 80
    ).withUnsafeBytes { Data($0) }
  }
  private static func cbc(_ input: Data, key: Data, iv: Data, encrypt: Bool) throws -> Data {
    try withDataPointers([key, iv, input]) { pointers in
      try output {
        om_aes_cbc(
          encrypt ? 1 : 0, pointers[0], key.count, pointers[1], pointers[2], input.count, $0)
      }
    }
  }
}
