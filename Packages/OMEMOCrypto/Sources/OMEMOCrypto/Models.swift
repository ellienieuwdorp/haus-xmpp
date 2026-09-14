import Foundation

public enum CryptoProfile: String, Codable, CaseIterable, Sendable {
  case legacy, modern
  var version: Int32 { self == .legacy ? 3 : 4 }
}
public struct DeviceAddress: Hashable, Codable, Sendable {
  public let jid: String
  public let deviceID: UInt32
  public init(jid: String, deviceID: UInt32) {
    self.jid = jid
    self.deviceID = deviceID
  }
}
public struct DeviceBundle: Codable, Equatable, Sendable {
  public let deviceID: UInt32
  public let identityKey: Data
  public let signedPreKeyID: UInt32
  public let signedPreKey: Data
  public let signedPreKeySignature: Data
  public let preKeys: [UInt32: Data]
  public init(
    deviceID: UInt32, identityKey: Data, signedPreKeyID: UInt32, signedPreKey: Data,
    signedPreKeySignature: Data, preKeys: [UInt32: Data]
  ) {
    self.deviceID = deviceID
    self.identityKey = identityKey
    self.signedPreKeyID = signedPreKeyID
    self.signedPreKey = signedPreKey
    self.signedPreKeySignature = signedPreKeySignature
    self.preKeys = preKeys
  }
}
public struct RatchetCiphertext: Codable, Equatable, Sendable {
  public let data: Data
  public let isPreKey: Bool
  public init(data: Data, isPreKey: Bool) {
    self.data = data
    self.isPreKey = isPreKey
  }
}
public struct SealedPayload: Equatable, Sendable {
  public let payload: Data
  public let keyMaterial: Data
  public let iv: Data?
  public init(payload: Data, keyMaterial: Data, iv: Data?) {
    self.payload = payload
    self.keyMaterial = keyMaterial
    self.iv = iv
  }
}
public enum OMEMOCryptoError: Error, Equatable {
  case invalidInput, invalidSnapshot, missingPreKey, authenticationFailed
  case upstream(Int32)
}
