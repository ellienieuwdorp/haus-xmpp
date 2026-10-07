import Foundation
import XCTest

@testable import OMEMOCrypto

/// What `OMEMOService` pays per incoming message before and after the ratchet step: importing the account's engine
/// from its snapshot and exporting it again (docs/development/sync-performance.md). Runs only with HAUS_BENCHMARKS=1:
///   HAUS_BENCHMARKS=1 swift test --package-path Packages/OMEMOCrypto [-c release] --filter SnapshotBenchmarks
/// Each session has done one exchange each way, so it holds a sending and a receiving chain; the local engine keeps
/// its 100 prekeys, as a published device does.
final class SnapshotBenchmarks: XCTestCase {
  override func setUpWithError() throws {
    try XCTSkipUnless(
      ProcessInfo.processInfo.environment["HAUS_BENCHMARKS"] == "1", "set HAUS_BENCHMARKS=1 to run benchmarks")
  }

  private func snapshot(sessions: Int) throws -> (data: Data, peer: DeviceAddress) {
    let local = try OMEMOEngine(profile: .legacy, deviceID: 1)
    let me = DeviceAddress(jid: "app@localhost", deviceID: 1)
    var first: DeviceAddress?
    for index in 0..<sessions {
      let peer = try OMEMOEngine(profile: .legacy, deviceID: UInt32(1000 + index), preKeyCount: 1)
      let address = DeviceAddress(jid: "peer\(index / 5)@localhost", deviceID: peer.deviceID)
      try local.trustIdentity(peer.identityKey, for: address)
      try peer.trustIdentity(local.identityKey, for: me)
      try local.establishSession(with: address, bundle: peer.bundle(), preKeyID: 1)
      _ = try peer.decrypt(local.encrypt(Data("hello".utf8), to: address), from: me)
      _ = try local.decrypt(peer.encrypt(Data("reply".utf8), to: me), from: address)
      first = first ?? address
    }
    return (try local.snapshot(), try XCTUnwrap(first))
  }

  private func measureRoundTrip(sessions: Int) throws {
    let (snapshot, peer) = try snapshot(sessions: sessions)
    print("SnapshotBenchmarks sessions=\(sessions) snapshot_bytes=\(snapshot.count)")
    // One untimed round trip first, so the first test does not carry the one-time setup into its samples.
    _ = try OMEMOEngine(snapshot: snapshot).snapshot()
    var exported = Data()
    var restored = false
    measure {
      guard let engine = try? OMEMOEngine(snapshot: snapshot) else { return }
      restored = engine.hasSession(with: peer)
      exported = (try? engine.snapshot()) ?? Data()
    }
    XCTAssertTrue(restored)
    XCTAssertEqual(exported, snapshot, "an import and export without a ratchet step changes nothing")
  }

  func testSnapshotRoundTripWith1Session() throws { try measureRoundTrip(sessions: 1) }
  func testSnapshotRoundTripWith50Sessions() throws { try measureRoundTrip(sessions: 50) }
  func testSnapshotRoundTripWith200Sessions() throws { try measureRoundTrip(sessions: 200) }
}
