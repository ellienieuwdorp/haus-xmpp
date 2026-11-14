import Foundation
import Testing

@testable import OMEMOCrypto

private struct Pair {
  let alice: OMEMOEngine, bob: OMEMOEngine
  let a = DeviceAddress(jid: "alice@example.org", deviceID: 111)
  let b = DeviceAddress(jid: "bob@example.org", deviceID: 222)
  init(_ profile: CryptoProfile) throws {
    alice = try OMEMOEngine(profile: profile, deviceID: 111, preKeyCount: 10)
    bob = try OMEMOEngine(profile: profile, deviceID: 222, preKeyCount: 10)
    try alice.trustIdentity(bob.identityKey, for: b)
    try bob.trustIdentity(alice.identityKey, for: a)
    try alice.establishSession(with: b, bundle: bob.bundle(), preKeyID: 1)
  }
}

// Reverting a prekey message restores the prekey, the absent session and every snapshot byte, so the same ciphertext
// decrypts again.
@Test(arguments: CryptoProfile.allCases)
func revertedPreKeyMessageRestoresTheEngine(profile: CryptoProfile) throws {
  let pair = try Pair(profile)
  let first = try pair.alice.encrypt(Data("first".utf8), to: pair.b)
  let before = try pair.bob.snapshot()
  try pair.bob.beginChange()
  #expect(try pair.bob.decrypt(first, from: pair.a) == Data("first".utf8))
  try pair.bob.replenishPreKeys(targetCount: 10)
  #expect(try pair.bob.snapshot() != before)
  try pair.bob.revertChange()
  #expect(try pair.bob.snapshot() == before)
  #expect(!pair.bob.hasSession(with: pair.a))
  #expect(try pair.bob.decrypt(first, from: pair.a) == Data("first".utf8))
}

// A kept change is the new state; a later revert only undoes what came after it.
@Test(arguments: CryptoProfile.allCases)
func keptChangeSurvivesALaterRevert(profile: CryptoProfile) throws {
  let pair = try Pair(profile)
  let first = try pair.alice.encrypt(Data("first".utf8), to: pair.b)
  let second = try pair.alice.encrypt(Data("second".utf8), to: pair.b)
  try pair.bob.beginChange()
  _ = try pair.bob.decrypt(first, from: pair.a)
  pair.bob.keepChange()
  let kept = try pair.bob.snapshot()
  try pair.bob.beginChange()
  _ = try pair.bob.decrypt(second, from: pair.a)
  _ = try pair.bob.encrypt(Data("reply".utf8), to: pair.a)
  try pair.bob.revertChange()
  #expect(try pair.bob.snapshot() == kept)
  #expect(try pair.bob.decrypt(second, from: pair.a) == Data("second".utf8))
  #expect(throws: (any Error).self) { try pair.bob.decrypt(first, from: pair.a) }
}

// A changed identity accepted with a session reset deletes the session; reverting brings both back.
@Test(arguments: CryptoProfile.allCases)
func revertRestoresARemovedSessionAndIdentity(profile: CryptoProfile) throws {
  let pair = try Pair(profile)
  _ = try pair.bob.decrypt(pair.alice.encrypt(Data("first".utf8), to: pair.b), from: pair.a)
  let before = try pair.bob.snapshot()
  let replacement = try OMEMOEngine(profile: profile, deviceID: 111, preKeyCount: 1)
  try pair.bob.beginChange()
  try pair.bob.trustIdentity(replacement.identityKey, for: pair.a, resetSession: true)
  #expect(!pair.bob.hasSession(with: pair.a))
  try pair.bob.revertChange()
  #expect(pair.bob.hasSession(with: pair.a))
  #expect(try pair.bob.snapshot() == before)
}

@Test func oneChangeAtATime() throws {
  let engine = try OMEMOEngine(profile: .legacy, deviceID: 1, preKeyCount: 2)
  try engine.beginChange()
  #expect(throws: (any Error).self) { try engine.beginChange() }
  engine.keepChange()
  try engine.beginChange()
  try engine.revertChange()
  try engine.revertChange()
}

// Counting prekeys does not depend on how many other records the engine holds.
@Test func replenishTopsUpOnlyConsumedPreKeys() throws {
  let pair = try Pair(.legacy)
  let before = try pair.bob.bundle().preKeys
  _ = try pair.bob.decrypt(pair.alice.encrypt(Data("first".utf8), to: pair.b), from: pair.a)
  #expect(try pair.bob.bundle().preKeys.count == 9)
  try pair.bob.replenishPreKeys(targetCount: 10)
  let after = try pair.bob.bundle().preKeys
  #expect(after.count == 10)
  #expect(Set(after.keys).subtracting(before.keys) == [11])
  let snapshot = try pair.bob.snapshot()
  try pair.bob.replenishPreKeys(targetCount: 10)
  #expect(try pair.bob.snapshot() == snapshot)
}
