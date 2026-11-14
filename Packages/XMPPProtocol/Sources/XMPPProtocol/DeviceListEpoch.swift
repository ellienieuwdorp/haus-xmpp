import Foundation

/// What a stream has heard that could make OMEMO device lists read on it out of date. `changes` moves with every
/// device-list event (parsed or not), every bounce, every roster or subscription change and every switch to CSI
/// inactive, so lists read under one epoch were not contradicted by anything that arrived since. `notified` names
/// the owners whose list this stream received as a PEP notification, so later changes to it are notified too.
public struct XMPPDeviceEpoch: Sendable, Equatable {
    public let session: UUID
    public let changes: UInt64
    let notified: Set<String>

    public func notifies(_ owner: String, profile: XMPPOMEMOProfile) -> Bool {
        notified.contains(DeviceListObservation.key(owner, profile))
    }

    /// Nothing that could change a device list arrived between the two readings.
    public func isUnchanged(since earlier: XMPPDeviceEpoch) -> Bool { session == earlier.session && changes == earlier.changes }
}

struct DeviceListObservation {
    private(set) var changes: UInt64 = 0
    private var session = UUID()
    private var notified: Set<String> = []

    static func key(_ owner: String, _ profile: XMPPOMEMOProfile) -> String { profile.rawValue + " " + owner }

    func epoch(session current: UUID) -> XMPPDeviceEpoch {
        XMPPDeviceEpoch(session: current, changes: changes, notified: session == current ? notified : [])
    }

    mutating func changed() { changes &+= 1 }

    // Only messages our server routes to us directly count; carbons and archives are other clients' or past traffic.
    mutating func see(_ message: XMLNode, provenance: XMPPMessageProvenance = .direct, session current: UUID) {
        guard provenance == .direct else { return }
        if session != current { session = current; notified = [] }
        if message.attributes["type"] == "error" { changed(); return }
        guard let event = try? OMEMOWire.singleton(message, "event", OMEMOWire.eventNamespace),
              event.children.contains(where: { child in XMPPOMEMOProfile.allCases.contains { $0.devicesNode == child.attributes["node"] } })
        else { return }
        changed()
        if let update = Self.deviceUpdate(message) { notified.insert(Self.key(update.owner, update.profile)) }
    }

    mutating func see(_ event: XMPPEvent) {
        switch event {
        case .rosterItems, .subscription:
            changed()
            notified = []
        default:
            break
        }
    }

    static func deviceUpdate(_ message: XMLNode) -> (owner: String, profile: XMPPOMEMOProfile, devices: [UInt32])? {
        guard message.name == "message", message.namespace == "jabber:client", let owner = message.attributes["from"],
              OMEMOWire.bareJID(owner) == owner,
              let event = try? OMEMOWire.singleton(message, "event", OMEMOWire.eventNamespace),
              let items = try? OMEMOWire.singleton(event, "items", OMEMOWire.eventNamespace),
              let profile = XMPPOMEMOProfile.allCases.first(where: { $0.devicesNode == items.attributes["node"] }),
              items.children.count == 1, let item = try? OMEMOWire.singleton(items, "item", OMEMOWire.eventNamespace),
              item.attributes["id"] == "current", item.children.count == 1,
              let devices = try? OMEMOWire.parseDevices(item.children[0], profile: profile) else { return nil }
        return (owner, profile, devices)
    }
}

extension XMPPClient {
    /// Nil unless the stream is online and CSI active: an inactive stream's server may hold notifications back.
    public func omemoDeviceEpoch() -> XMPPDeviceEpoch? {
        guard phase == .online, clientActive else { return nil }
        return deviceLists.epoch(session: generation)
    }
}
