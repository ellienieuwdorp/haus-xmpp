import COMEMOBridge
import Foundation
import Security

/// Synchronous, deliberately non-Sendable, single-owner ratchet. Persist `snapshot()` with its
/// resulting ciphertext/plaintext in one transaction. If any operation or transaction fails,
/// discard this instance, or revert the change that wrapped it; never persist partial state.
public final class OMEMOEngine {
  public let profile: CryptoProfile
  public let deviceID: UInt32
  private let engine: OpaquePointer
  private var nextPreKeyID: UInt32
  private var signedPreKeyID: UInt32
  private var signedPreKeyCreatedAt: Date
  private var retiredSignedPreKeys: [UInt32: Date]
  private struct Snapshot: Codable {
    let schema: Int
    let profile: CryptoProfile
    let deviceID: UInt32
    let nextPreKeyID: UInt32
    let records: [String: Data]
    let signedPreKeyID: UInt32?
    let signedPreKeyCreatedAt: Date?
    let retiredSignedPreKeys: [UInt32: Date]?
  }
  /// XEP-0384 recommends the raw 32-byte Curve25519 identity for fingerprints,
  /// including modern profiles whose bundle publishes the Ed25519 representation.
  public static func fingerprintBytes(for identityKey: Data, profile: CryptoProfile) throws -> Data
  {
    guard identityKey.count == (profile == .legacy ? 33 : 32) else {
      throw OMEMOCryptoError.invalidInput
    }
    return try withDataPointers([identityKey]) { p in
      try output { om_fingerprint(profile.version, p[0], identityKey.count, $0) }
    }
  }
  /// Verifies a signed public bundle (or a modern signed device label) without advancing
  /// a ratchet or granting trust. The profile determines the upstream identity encoding.
  public static func verifySignature(_ signature: Data, for data: Data,
                                    identityKey: Data, profile: CryptoProfile) throws -> Bool {
    guard signature.count == 64, data.count <= 1_048_576,
          identityKey.count == (profile == .legacy ? 33 : 32) else {
      throw OMEMOCryptoError.invalidInput
    }
    return try withDataPointers([identityKey, data, signature]) { p in
      let result = om_verify(profile.version, p[0], identityKey.count,
                             p[1], data.count, p[2], signature.count)
      try checked(result)
      return result == 1
    }
  }
  public static func randomDeviceID() throws -> UInt32 {
    var value: UInt32 = 0
    repeat {
      guard
        SecRandomCopyBytes(kSecRandomDefault, MemoryLayout<UInt32>.size, &value) == errSecSuccess
      else { throw OMEMOCryptoError.authenticationFailed }
      value &= 0x7fff_ffff
    } while value == 0
    return value
  }
  public init(
    profile: CryptoProfile, deviceID: UInt32, preKeyCount: UInt32 = 100, now: Date = Date()
  ) throws {
    guard (1...1000).contains(preKeyCount), deviceID > 0, deviceID <= Int32.max,
      now.timeIntervalSince1970.isFinite, now.timeIntervalSince1970 >= 0
    else { throw OMEMOCryptoError.invalidInput }
    self.profile = profile
    self.deviceID = deviceID
    self.nextPreKeyID = preKeyCount + 1
    self.signedPreKeyID = 1
    self.signedPreKeyCreatedAt = now
    self.retiredSignedPreKeys = [:]
    var handle: OpaquePointer?
    try checked(om_engine_create(&handle, profile.version, deviceID))
    guard let handle else { throw OMEMOCryptoError.invalidInput }
    engine = handle
    try checked(om_generate(engine, preKeyCount))
  }
  /// New profile for the same physical device: share only its identity keypair. Signed
  /// prekeys, one-time prekeys and sessions are generated independently. Never use this
  /// initializer to replace an existing published profile identity or durable ratchet.
  public init(
    profile: CryptoProfile, sharingIdentityWith source: OMEMOEngine,
    preKeyCount: UInt32 = 100, now: Date = Date()
  ) throws {
    guard (1...1000).contains(preKeyCount), now.timeIntervalSince1970.isFinite,
      now.timeIntervalSince1970 >= 0
    else { throw OMEMOCryptoError.invalidInput }
    self.profile = profile
    self.deviceID = source.deviceID
    self.nextPreKeyID = preKeyCount + 1
    self.signedPreKeyID = 1
    self.signedPreKeyCreatedAt = now
    self.retiredSignedPreKeys = [:]
    var handle: OpaquePointer?
    try checked(om_engine_create(&handle, profile.version, deviceID))
    guard let handle else { throw OMEMOCryptoError.invalidInput }
    engine = handle
    try checked(om_generate_shared_identity(engine, source.engine, preKeyCount))
  }
  public init(snapshot: Data) throws {
    guard snapshot.count <= 64 * 1024 * 1024 else { throw OMEMOCryptoError.invalidSnapshot }
    let value = try JSONDecoder().decode(Snapshot.self, from: snapshot)
    guard (1...2).contains(value.schema), value.deviceID > 0, value.deviceID <= Int32.max,
      value.nextPreKeyID > 0, value.nextPreKeyID <= 0xFFFFFF,
      value.records.count <= 100_000,
      value.records["identity.public"]?.count == 33,
      value.records["identity.private"]?.count == 32,
      value.records["k:\(value.signedPreKeyID ?? 1)"] != nil,
      (value.signedPreKeyID ?? 1) > 0, (value.signedPreKeyID ?? 1) <= Int32.max,
      value.records.allSatisfy({
        !$0.key.contains("\0") && $0.key.utf8.count <= 3200 && $0.value.count <= 1_048_576
      })
    else { throw OMEMOCryptoError.invalidSnapshot }
    profile = value.profile
    deviceID = value.deviceID
    nextPreKeyID = value.nextPreKeyID
    signedPreKeyID = value.signedPreKeyID ?? 1
    signedPreKeyCreatedAt = value.signedPreKeyCreatedAt ?? Date()
    retiredSignedPreKeys = value.retiredSignedPreKeys ?? [:]
    var handle: OpaquePointer?
    try checked(om_engine_create(&handle, profile.version, deviceID))
    guard let handle else { throw OMEMOCryptoError.invalidSnapshot }
    engine = handle
    for (name, data) in value.records {
      try withDataPointers([data]) { p in
        try checked(om_record_write(engine, name, p[0], data.count))
      }
    }
    _ = try identityKey
  }
  deinit { om_engine_free(engine) }
  public var identityKey: Data { get throws { try publicKey(kind: 0, id: 0) } }
  public func snapshot() throws -> Data {
    var records: [String: Data] = [:]
    try forEachRecord { name, value in records[name] = value }
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.sortedKeys]
    return try encoder.encode(
      Snapshot(
        schema: 2, profile: profile, deviceID: deviceID, nextPreKeyID: nextPreKeyID,
        records: records, signedPreKeyID: signedPreKeyID,
        signedPreKeyCreatedAt: signedPreKeyCreatedAt, retiredSignedPreKeys: retiredSignedPreKeys))
  }
  public func bundle() throws -> DeviceBundle {
    var prekeys: [UInt32: Data] = [:]
    for id in try preKeyIDs() { prekeys[id] = try publicKey(kind: 3, id: id) }
    return try DeviceBundle(
      deviceID: deviceID, identityKey: identityKey, signedPreKeyID: signedPreKeyID,
      signedPreKey: publicKey(kind: 1, id: signedPreKeyID),
      signedPreKeySignature: publicKey(kind: 2, id: signedPreKeyID), preKeys: prekeys)
  }
  /// Rotate weekly; retain previous private signed prekeys for 30 days after retirement
  /// so sessions initiated from recently cached bundles remain decryptable. Returns true
  /// whenever the snapshot changed, including expired-key deletion without a new rotation.
  @discardableResult
  public func rotateSignedPreKeyIfNeeded(now: Date = Date()) throws -> Bool {
    guard now.timeIntervalSince1970.isFinite, now.timeIntervalSince1970 >= 0,
      now.timeIntervalSince1970 < Double(UInt64.max / 1000)
    else { throw OMEMOCryptoError.invalidInput }
    let due = now.timeIntervalSince(signedPreKeyCreatedAt) >= 7 * 24 * 60 * 60
    if due {
      guard signedPreKeyID < Int32.max else { throw OMEMOCryptoError.invalidInput }
      let next = signedPreKeyID + 1
      try checked(om_rotate_signed_key(engine, next, UInt64(now.timeIntervalSince1970 * 1000)))
      retiredSignedPreKeys[signedPreKeyID] = now
      signedPreKeyID = next
      signedPreKeyCreatedAt = now
    }
    var changed = due
    for (id, retiredAt) in retiredSignedPreKeys
    where now.timeIntervalSince(retiredAt) >= 30 * 24 * 60 * 60 {
      om_delete_signed_key(engine, id)
      retiredSignedPreKeys.removeValue(forKey: id)
      changed = true
    }
    return changed
  }
  public func replenishPreKeys(targetCount: UInt32 = 100) throws {
    guard targetCount > 0, targetCount <= 1000 else { throw OMEMOCryptoError.invalidInput }
    let current = UInt32(clamping: om_prekey_count(engine))
    guard current < targetCount else { return }
    let count = targetCount - current
    guard nextPreKeyID < 0xFFFFFF - count else { throw OMEMOCryptoError.invalidInput }
    try checked(om_replenish(engine, nextPreKeyID, count))
    nextPreKeyID += count
  }
  private var pendingChange:
    (nextPreKeyID: UInt32, signedPreKeyID: UInt32, signedPreKeyCreatedAt: Date, retired: [UInt32: Date])?
  /// Starts one change: `revertChange()` restores the engine exactly as it is now, `keepChange()` accepts every
  /// write since. A kept-alive engine wraps each message in a change, so a failure never leaves partial state.
  public func beginChange() throws {
    guard pendingChange == nil else { throw OMEMOCryptoError.invalidInput }
    try checked(om_change_begin(engine))
    pendingChange = (nextPreKeyID, signedPreKeyID, signedPreKeyCreatedAt, retiredSignedPreKeys)
  }
  public func keepChange() {
    om_change_keep(engine)
    pendingChange = nil
  }
  /// Throws when the engine could not be restored; it must then be discarded.
  public func revertChange() throws {
    guard let saved = pendingChange else { return }
    pendingChange = nil
    nextPreKeyID = saved.nextPreKeyID
    signedPreKeyID = saved.signedPreKeyID
    signedPreKeyCreatedAt = saved.signedPreKeyCreatedAt
    retiredSignedPreKeys = saved.retired
    try checked(om_change_revert(engine))
  }
  public func hasSession(with address: DeviceAddress) -> Bool {
    guard valid(address) else { return false }
    return om_has_session(engine, address.jid, address.deviceID) == 1
  }
  public func establishSession(
    with address: DeviceAddress, bundle: DeviceBundle, preKeyID: UInt32? = nil
  ) throws {
    guard valid(address), address.deviceID == bundle.deviceID,
      bundle.signedPreKeyID > 0, bundle.signedPreKeyID <= Int32.max,
      bundle.signedPreKeySignature.count == 64,
      bundle.identityKey.count == (profile == .legacy ? 33 : 32),
      bundle.signedPreKey.count == (profile == .legacy ? 33 : 32),
      let id = preKeyID ?? bundle.preKeys.keys.randomElement(), let prekey = bundle.preKeys[id],
      id > 0, id <= Int32.max, prekey.count == (profile == .legacy ? 33 : 32)
    else { throw OMEMOCryptoError.invalidInput }
    try withDataPointers([
      bundle.identityKey, bundle.signedPreKey, bundle.signedPreKeySignature, prekey,
    ]) { p in
      try checked(
        om_establish(
          engine, address.jid, address.deviceID, p[0], bundle.identityKey.count,
          p[1], bundle.signedPreKey.count, bundle.signedPreKeyID, p[2],
          bundle.signedPreKeySignature.count, p[3], prekey.count, id))
    }
  }
  public func encrypt(_ data: Data, to address: DeviceAddress) throws -> RatchetCiphertext {
    guard valid(address), !data.isEmpty, data.count <= 1_048_576 else {
      throw OMEMOCryptoError.invalidInput
    }
    var prekey: Int32 = 0
    let bytes = try withDataPointers([data]) { p in
      try output {
        om_encrypt(engine, address.jid, address.deviceID, p[0], data.count, $0, &prekey)
      }
    }
    return RatchetCiphertext(data: bytes, isPreKey: prekey != 0)
  }
  public func decrypt(_ ciphertext: RatchetCiphertext, from address: DeviceAddress) throws -> Data {
    guard valid(address), !ciphertext.data.isEmpty, ciphertext.data.count <= 1_048_576 else {
      throw OMEMOCryptoError.invalidInput
    }
    return try withDataPointers([ciphertext.data]) { p in
      try output {
        om_decrypt(
          engine, address.jid, address.deviceID, p[0], ciphertext.data.count,
          ciphertext.isPreKey ? 1 : 0, $0)
      }
    }
  }
  /// Explicit application trust decision. A changed fingerprint requires resetSession true.
  public func trustIdentity(
    _ identityKey: Data, for address: DeviceAddress, resetSession: Bool = false
  ) throws {
    guard valid(address), identityKey.count == (profile == .legacy ? 33 : 32) else {
      throw OMEMOCryptoError.invalidInput
    }
    try withDataPointers([identityKey]) { p in
      try checked(
        om_trust(
          engine, address.jid, address.deviceID, p[0], identityKey.count, resetSession ? 1 : 0))
    }
  }
  public func sign(_ data: Data) throws -> Data {
    guard data.count <= 1_048_576 else { throw OMEMOCryptoError.invalidInput }
    return try withDataPointers([data]) { p in try output { om_sign(engine, p[0], data.count, $0) }
    }
  }
  private func publicKey(kind: Int32, id: UInt32) throws -> Data {
    try output { om_public(engine, kind, id, $0) }
  }
  private func preKeyIDs() throws -> [UInt32] {
    var ids: [UInt32] = []
    try forEachRecord { name, _ in
      if name.hasPrefix("p:"), let id = UInt32(name.dropFirst(2)) { ids.append(id) }
    }
    return ids.sorted()
  }
  private func forEachRecord(_ body: (String, Data) throws -> Void) throws {
    let count = om_record_count(engine)
    var names = [UnsafePointer<CChar>?](repeating: nil, count: count)
    var values = [UnsafePointer<UInt8>?](repeating: nil, count: count)
    var lengths = [Int](repeating: 0, count: count)
    guard om_record_list(engine, &names, &values, &lengths, count) == count else {
      throw OMEMOCryptoError.invalidSnapshot
    }
    for index in 0..<count {
      guard let name = names[index], let value = values[index] else {
        throw OMEMOCryptoError.invalidSnapshot
      }
      try body(String(cString: name), Data(bytes: value, count: lengths[index]))
    }
  }
  private func valid(_ address: DeviceAddress) -> Bool {
    !address.jid.isEmpty && !address.jid.contains("\0") && address.jid.utf8.count <= 3071
      && address.deviceID > 0 && address.deviceID <= Int32.max
  }
}
func checked(_ code: Int32) throws { if code < 0 { throw OMEMOCryptoError.upstream(code) } }
func output(_ body: (UnsafeMutablePointer<om_bytes>) -> Int32) throws -> Data {
  var buffer = om_bytes(data: nil, length: 0)
  defer { om_bytes_free(&buffer) }
  try checked(body(&buffer))
  guard let pointer = buffer.data else { throw OMEMOCryptoError.invalidInput }
  return Data(bytes: pointer, count: buffer.length)
}
func withDataPointers<T>(_ data: [Data], body: ([UnsafePointer<UInt8>]) throws -> T) rethrows -> T {
  let retained = data.map { $0 as NSData }
  return try withExtendedLifetime(retained) {
    try body(retained.map { $0.bytes.assumingMemoryBound(to: UInt8.self) })
  }
}
