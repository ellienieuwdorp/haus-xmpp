import Foundation
import OMEMO
import XMPPProtocol

/// Initializes an OMEMO account without a server: it remembers only what this account publishes, and no other
/// account has devices. Enough for paths that never need a peer session.
struct NullTransport: OMEMOTransport {
    private actor Published {
        var devices: [XMPPOMEMOProfile: [UInt32]] = [:]
        var bundles: [String: XMPPOMEMOBundle] = [:]
        func setDevices(_ ids: [UInt32], _ profile: XMPPOMEMOProfile) { devices[profile] = ids }
        func setBundle(_ bundle: XMPPOMEMOBundle) { bundles["\(bundle.profile.rawValue)|\(bundle.deviceID)"] = bundle }
        func bundle(_ profile: XMPPOMEMOProfile, _ id: UInt32) -> XMPPOMEMOBundle? { bundles["\(profile.rawValue)|\(id)"] }
    }
    let account: String
    private let published = Published()
    init(account: String) { self.account = account }

    func fetchOMEMODevices(for jid: String, profile: XMPPOMEMOProfile) async throws -> [UInt32] {
        jid == account ? await published.devices[profile] ?? [] : []
    }
    func fetchOMEMOBundle(for jid: String, deviceID: UInt32, profile: XMPPOMEMOProfile) async throws -> XMPPOMEMOBundle {
        guard jid == account, let bundle = await published.bundle(profile, deviceID) else { throw XMPPIQError.stanza(condition: "item-not-found") }
        return bundle
    }
    func publishOMEMODevices(_ devices: [UInt32], profile: XMPPOMEMOProfile) async throws { await published.setDevices(devices, profile) }
    func publishOMEMOBundle(_ bundle: XMPPOMEMOBundle) async throws { await published.setBundle(bundle) }
}
