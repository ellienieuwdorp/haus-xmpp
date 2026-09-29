import Foundation
import Testing

@testable import OMEMOCrypto

@Test(arguments: CryptoProfile.allCases)
func ratchetSurvivesRelaunchAndOutOfOrderDelivery(profile: CryptoProfile) throws {
  var alice = try OMEMOEngine(profile: profile, deviceID: 111, preKeyCount: 10)
  var bob = try OMEMOEngine(profile: profile, deviceID: 222, preKeyCount: 10)
  let a = DeviceAddress(jid: "alice@example.org", deviceID: 111)
  let b = DeviceAddress(jid: "bob@example.org", deviceID: 222)
  try alice.trustIdentity(bob.identityKey, for: b)
  try bob.trustIdentity(alice.identityKey, for: a)
  try alice.establishSession(with: b, bundle: bob.bundle(), preKeyID: 1)
  let first = try alice.encrypt(Data("first".utf8), to: b)
  #expect(first.isPreKey)
  #expect(try bob.decrypt(first, from: a) == Data("first".utf8))
  #expect(throws: (any Error).self) { try bob.decrypt(first, from: a) }
  #expect(try bob.bundle().preKeys.count == 9)
  try bob.replenishPreKeys(targetCount: 10)
  #expect(try bob.bundle().preKeys.count == 10)
  #expect(try bob.bundle().preKeys[1] == nil)
  let reply = try bob.encrypt(Data("reply".utf8), to: a)
  #expect(try alice.decrypt(reply, from: b) == Data("reply".utf8))
  alice = try OMEMOEngine(snapshot: alice.snapshot())
  bob = try OMEMOEngine(snapshot: bob.snapshot())
  let second = try alice.encrypt(Data("second".utf8), to: b)
  let third = try alice.encrypt(Data("third".utf8), to: b)
  #expect(!second.isPreKey)
  #expect(try bob.decrypt(third, from: a) == Data("third".utf8))
  #expect(try bob.decrypt(second, from: a) == Data("second".utf8))
}
@Test(arguments: CryptoProfile.allCases)
func unknownAndChangedIdentityAreRejected(profile: CryptoProfile) throws {
  let alice = try OMEMOEngine(profile: profile, deviceID: 111, preKeyCount: 2)
  let bob = try OMEMOEngine(profile: profile, deviceID: 222, preKeyCount: 2)
  let impostor = try OMEMOEngine(profile: profile, deviceID: 222, preKeyCount: 2)
  let address = DeviceAddress(jid: "bob@example.org", deviceID: 222)
  #expect(throws: (any Error).self) {
    try alice.establishSession(with: address, bundle: bob.bundle())
  }
  try alice.trustIdentity(bob.identityKey, for: address)
  try alice.establishSession(with: address, bundle: bob.bundle())
  #expect(throws: (any Error).self) {
    try alice.establishSession(with: address, bundle: impostor.bundle())
  }
  #expect(throws: (any Error).self) { try alice.trustIdentity(impostor.identityKey, for: address) }
  try alice.trustIdentity(impostor.identityKey, for: address, resetSession: true)
  #expect(!alice.hasSession(with: address))
}
@Test(arguments: CryptoProfile.allCases)
func payloadAuthenticationBeforePlaintext(profile: CryptoProfile) throws {
  let body = Data("hello 🔐".utf8)
  let sealed = try PayloadCrypto.seal(body, profile: profile)
  #expect(try PayloadCrypto.open(sealed, profile: profile) == body)
  var corrupted = sealed.payload
  corrupted[corrupted.startIndex] ^= 1
  #expect(throws: OMEMOCryptoError.authenticationFailed) {
    try PayloadCrypto.open(
      SealedPayload(payload: corrupted, keyMaterial: sealed.keyMaterial, iv: sealed.iv),
      profile: profile)
  }
  var key = sealed.keyMaterial
  key[key.index(before: key.endIndex)] ^= 1
  #expect(throws: OMEMOCryptoError.authenticationFailed) {
    try PayloadCrypto.open(
      SealedPayload(payload: sealed.payload, keyMaterial: key, iv: sealed.iv), profile: profile)
  }
}

@Test(arguments: CryptoProfile.allCases)
func invalidBundleSignatureAndUntrustedInboundDoNotDecrypt(profile: CryptoProfile) throws {
  let alice = try OMEMOEngine(profile: profile, deviceID: 111, preKeyCount: 2)
  let bob = try OMEMOEngine(profile: profile, deviceID: 222, preKeyCount: 2)
  let a = DeviceAddress(jid: "alice@example.org", deviceID: 111)
  let b = DeviceAddress(jid: "bob@example.org", deviceID: 222)
  let bundle = try bob.bundle()
  try alice.trustIdentity(bundle.identityKey, for: b)
  var signature = bundle.signedPreKeySignature
  signature[signature.startIndex] ^= 1
  let invalid = DeviceBundle(
    deviceID: bundle.deviceID, identityKey: bundle.identityKey,
    signedPreKeyID: bundle.signedPreKeyID, signedPreKey: bundle.signedPreKey,
    signedPreKeySignature: signature, preKeys: bundle.preKeys)
  #expect(throws: (any Error).self) { try alice.establishSession(with: b, bundle: invalid) }
  #expect(!alice.hasSession(with: b))
  try alice.establishSession(with: b, bundle: bundle)
  let cipher = try alice.encrypt(Data("secret".utf8), to: b)
  let before = try bob.snapshot()
  #expect(throws: (any Error).self) { try bob.decrypt(cipher, from: a) }
  #expect(try bob.snapshot() == before)
  try bob.trustIdentity(alice.identityKey, for: a)
  #expect(throws: (any Error).self) {
    try bob.decrypt(cipher, from: DeviceAddress(jid: "mallory@example.org", deviceID: 111))
  }
  var damaged = cipher.data
  damaged[damaged.index(before: damaged.endIndex)] ^= 1
  #expect(throws: (any Error).self) {
    try bob.decrypt(RatchetCiphertext(data: damaged, isPreKey: cipher.isPreKey), from: a)
  }
  // Roll back after authentication failure, as a durable caller must.
  let restored = try OMEMOEngine(snapshot: before)
  try restored.trustIdentity(alice.identityKey, for: a)
  #expect(try restored.decrypt(cipher, from: a) == Data("secret".utf8))
}

@Test func profileAndDeviceValidation() throws {
  #expect(throws: (any Error).self) { try OMEMOEngine(profile: .modern, deviceID: 0) }
  #expect(throws: (any Error).self) { try OMEMOEngine(profile: .legacy, deviceID: UInt32.max) }
  #expect(throws: (any Error).self) { try OMEMOEngine(snapshot: Data("{}".utf8)) }
  let legacy = try OMEMOEngine(profile: .legacy, deviceID: 111, preKeyCount: 1)
  let modern = try OMEMOEngine(profile: .modern, deviceID: 222, preKeyCount: 1)
  #expect(throws: (any Error).self) {
    try modern.trustIdentity(
      legacy.identityKey, for: DeviceAddress(jid: "alice@example.org", deviceID: 111))
  }
  #expect(throws: (any Error).self) {
    try legacy.trustIdentity(
      modern.identityKey, for: DeviceAddress(jid: "bob@example.org", deviceID: 222))
  }
  #expect(try OMEMOEngine.randomDeviceID() > 0)
}

@Test(arguments: CryptoProfile.allCases)
func rotationPreservesDelayedPreKeyMessagesButExpiresOldSecrets(profile: CryptoProfile) throws {
  let start = Date(timeIntervalSince1970: 1_800_000_000)
  let week: TimeInterval = 7 * 24 * 60 * 60
  let a = DeviceAddress(jid: "alice@example.org", deviceID: 111)
  let b = DeviceAddress(jid: "bob@example.org", deviceID: 222)
  let alice = try OMEMOEngine(profile: profile, deviceID: 111, preKeyCount: 3, now: start)
  var bob = try OMEMOEngine(profile: profile, deviceID: 222, preKeyCount: 3, now: start)
  let oldBundle = try bob.bundle()
  try alice.trustIdentity(oldBundle.identityKey, for: b)
  try alice.establishSession(with: b, bundle: oldBundle, preKeyID: 1)
  let delayed = try alice.encrypt(Data("arrives after rotation".utf8), to: b)
  #expect(try !bob.rotateSignedPreKeyIfNeeded(now: start.addingTimeInterval(week - 1)))
  #expect(try bob.rotateSignedPreKeyIfNeeded(now: start.addingTimeInterval(week)))
  let rotated = try bob.bundle()
  #expect(rotated.signedPreKeyID == 2)
  #expect(rotated.signedPreKey != oldBundle.signedPreKey)
  #expect(rotated.identityKey == oldBundle.identityKey)
  bob = try OMEMOEngine(snapshot: bob.snapshot())
  try bob.trustIdentity(alice.identityKey, for: a)
  #expect(try bob.decrypt(delayed, from: a) == Data("arrives after rotation".utf8))
  // A different device starts from another still-unconsumed key in the original cached bundle.
  let another = try OMEMOEngine(profile: profile, deviceID: 333, preKeyCount: 2, now: start)
  let c = DeviceAddress(jid: "carol@example.org", deviceID: 333)
  try another.trustIdentity(oldBundle.identityKey, for: b)
  try another.establishSession(with: b, bundle: oldBundle, preKeyID: 2)
  let expired = try another.encrypt(Data("too late".utf8), to: b)
  try bob.rotateSignedPreKeyIfNeeded(now: start.addingTimeInterval(week + 30 * 24 * 60 * 60))
  bob = try OMEMOEngine(snapshot: bob.snapshot())
  try bob.trustIdentity(another.identityKey, for: c)
  #expect(throws: (any Error).self) { try bob.decrypt(expired, from: c) }
}

@Test func legacyAppendedTagCompatibilityStillAuthenticates() throws {
  let body = Data("older sender".utf8)
  let generated = try PayloadCrypto.seal(body, profile: .legacy)
  let historical = SealedPayload(
    payload: generated.payload + generated.keyMaterial.suffix(16),
    keyMaterial: Data(generated.keyMaterial.prefix(16)), iv: generated.iv)
  #expect(try PayloadCrypto.open(historical, profile: .legacy) == body)
  var corrupted = historical.payload
  corrupted[corrupted.index(before: corrupted.endIndex)] ^= 1
  #expect(throws: OMEMOCryptoError.authenticationFailed) {
    try PayloadCrypto.open(
      SealedPayload(payload: corrupted, keyMaterial: historical.keyMaterial, iv: historical.iv),
      profile: .legacy)
  }
}
@Test func attachmentKeysAndAuthentication() throws {
  let plaintext = Data((0..<256).map(UInt8.init))
  let sealed = try AttachmentCrypto.seal(plaintext)
  #expect(sealed.key.count == 32)
  #expect(sealed.iv.count == 12)
  #expect(sealed.ciphertext.count == plaintext.count + 16)
  #expect(try AttachmentCrypto.open(sealed) == plaintext)
  let again = try AttachmentCrypto.seal(plaintext)
  #expect(again.key != sealed.key)
  #expect(again.iv != sealed.iv)
  var ciphertext = sealed.ciphertext
  ciphertext[ciphertext.startIndex] ^= 1
  #expect(throws: OMEMOCryptoError.authenticationFailed) {
    try AttachmentCrypto.open(
      EncryptedAttachment(ciphertext: ciphertext, key: sealed.key, iv: sealed.iv))
  }
  #expect(throws: (any Error).self) {
    try AttachmentCrypto.open(sealed, maximumBytes: plaintext.count - 1)
  }
  #expect(throws: (any Error).self) { try AttachmentCrypto.seal(plaintext, maximumBytes: 0) }
  #expect(try AttachmentCrypto.open(AttachmentCrypto.seal(Data())).isEmpty)
}

@Test func sharedPhysicalIdentityKeepsProfileSessionsAndPrekeysSeparate() throws {
  let legacy = try OMEMOEngine(profile: .legacy, deviceID: 555, preKeyCount: 3)
  let modern = try OMEMOEngine(profile: .modern, sharingIdentityWith: legacy, preKeyCount: 3)
  #expect(modern.deviceID == legacy.deviceID)
  // Both publish the same physical identity in different encodings (33-byte Curve25519, 32-byte Ed25519);
  // either fingerprint is the raw 32-byte Curve25519 key, so one device reads the same in both versions.
  let curve = Data(try legacy.identityKey.dropFirst())
  #expect(try modern.identityKey != curve)
  #expect(try OMEMOEngine.fingerprintBytes(for: legacy.identityKey, profile: .legacy) == curve)
  #expect(try OMEMOEngine.fingerprintBytes(for: modern.identityKey, profile: .modern) == curve)
  #expect(try Data(legacy.bundle().signedPreKey.dropFirst()) != modern.bundle().signedPreKey)
  #expect(try Data(legacy.bundle().preKeys[1]!.dropFirst()) != modern.bundle().preKeys[1]!)
  let reopened = try OMEMOEngine(snapshot: modern.snapshot())
  #expect(try reopened.identityKey == modern.identityKey)
  #expect(try reopened.bundle() == modern.bundle())
}

@Test(arguments: CryptoProfile.allCases)
func publicSignatureValidationDoesNotRequireASession(profile: CryptoProfile) throws {
  let engine = try OMEMOEngine(profile: profile, deviceID: 17, preKeyCount: 2)
  let bundle = try engine.bundle()
  #expect(try OMEMOEngine.verifySignature(bundle.signedPreKeySignature, for: bundle.signedPreKey,
                                         identityKey: bundle.identityKey, profile: profile))
  var invalid = bundle.signedPreKeySignature
  invalid[0] ^= 1
  #expect(try !OMEMOEngine.verifySignature(invalid, for: bundle.signedPreKey,
                                          identityKey: bundle.identityKey, profile: profile))
  let label = Data("iPhone 🗝️".utf8)
  let signed = try engine.sign(label)
  #expect(try OMEMOEngine.verifySignature(signed, for: label, identityKey: engine.identityKey, profile: profile))
  #expect(try !OMEMOEngine.verifySignature(signed, for: Data("Changed label".utf8), identityKey: engine.identityKey, profile: profile))
}

@Test(arguments: CryptoProfile.allCases)
func expiredSignedKeyDeletionSignalsADurableChangeWithoutRotating(profile: CryptoProfile) throws {
  let day: TimeInterval = 24 * 60 * 60
  let start = Date(timeIntervalSince1970: 1_700_000_000)
  let bob = try OMEMOEngine(profile: profile, deviceID: 222, preKeyCount: 2, now: start)
  let alice = try OMEMOEngine(profile: profile, deviceID: 111, preKeyCount: 2, now: start)
  let a = DeviceAddress(jid: "alice@example.org", deviceID: 111)
  let b = DeviceAddress(jid: "bob@example.org", deviceID: 222)
  try bob.trustIdentity(alice.identityKey, for: a)
  try alice.trustIdentity(bob.identityKey, for: b)
  try alice.establishSession(with: b, bundle: bob.bundle(), preKeyID: 1)
  let delayed = try alice.encrypt(Data("old signed prekey".utf8), to: b)
  for week in 1...5 {
    #expect(try bob.rotateSignedPreKeyIfNeeded(now: start.addingTimeInterval(Double(week) * 7 * day)))
  }
  let keyID = try bob.bundle().signedPreKeyID
  // The first key expires 30 days after its retirement at day 7; no rotation is due at day 37.
  #expect(try bob.rotateSignedPreKeyIfNeeded(now: start.addingTimeInterval(37 * day)))
  #expect(try bob.bundle().signedPreKeyID == keyID)
  let reopened = try OMEMOEngine(snapshot: bob.snapshot())
  #expect(throws: (any Error).self) { try reopened.decrypt(delayed, from: a) }
}
