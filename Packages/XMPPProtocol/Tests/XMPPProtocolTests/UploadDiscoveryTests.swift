import Foundation
import Testing
@testable import XMPPProtocol

/// XEP-0363 service discovery over a real socket, against `LoopbackServer` acting as the server and its components.
@Suite(.serialized)
struct UploadDiscoveryTests {
    private static let bindNamespace = "urn:ietf:params:xml:ns:xmpp-bind"
    private static let items = "http://jabber.org/protocol/disco#items"
    private static let info = "http://jabber.org/protocol/disco#info"

    private static func service(limit: Int?) -> String {
        let form = limit.map { "<x xmlns='jabber:x:data' type='result'><field var='FORM_TYPE' type='hidden'><value>urn:xmpp:http:upload:0</value></field><field var='max-file-size'><value>\($0)</value></field></x>" } ?? ""
        return "<feature var='urn:xmpp:http:upload:0'/>" + form
    }

    private enum Answer { case features(String), silent }

    /// What the server and each component answer to disco#info; an entity missing here refuses. `listed` is the
    /// domain's items.
    private struct Network {
        var listed: [String]
        var info: [String: Answer]
    }

    /// Runs `uploadService` against `network` and returns its outcome and how long it took.
    private func discover(_ network: Network, timeout: Duration) async throws -> (Result<XMPPUploadService?, any Error>, Duration) {
        let server = try await LoopbackServer.start()
        defer { Task { await server.stop() } }
        let client = server.client()
        async let online: Void = server.connect(client)
        try await server.authenticate(features: "")
        let bind = try await server.next()
        try await server.send("<iq type='result' id='\(bind.attributes["id"] ?? "")'><bind xmlns='\(Self.bindNamespace)'><jid>alice@localhost/r</jid></bind></iq>")
        #expect(try await server.next().name == "presence")
        try await online
        let answering = Task {
            while !Task.isCancelled {
                guard let iq = try? await server.next(within: .seconds(30)), iq.name == "iq", let id = iq.attributes["id"] else { continue }
                let to = iq.attributes["to"] ?? ""
                if iq.child("query", namespace: Self.items) != nil {
                    let entries = network.listed.map { "<item jid='\($0)'/>" }.joined()
                    try? await server.send("<iq type='result' id='\(id)' from='\(to)'><query xmlns='\(Self.items)'>\(entries)</query></iq>")
                } else if iq.child("query", namespace: Self.info) != nil {
                    switch network.info[to] {
                    case .features(let features):
                        try? await server.send("<iq type='result' id='\(id)' from='\(to)'><query xmlns='\(Self.info)'>\(features)</query></iq>")
                    case .silent: continue
                    case nil:
                        try? await server.send("<iq type='error' id='\(id)' from='\(to)'><error type='cancel'><service-unavailable xmlns='urn:ietf:params:xml:ns:xmpp-stanzas'/></error></iq>")
                    }
                }
            }
        }
        let started = ContinuousClock.now
        let outcome: Result<XMPPUploadService?, any Error>
        do { outcome = .success(try await client.uploadService(timeout: timeout)) } catch { outcome = .failure(error) }
        let elapsed = ContinuousClock.now - started
        answering.cancel()
        await client.disconnect()
        return (outcome, elapsed)
    }

    /// Before: items were probed one at a time with the 15 s IQ deadline, the first match won, and a MUC service that
    /// also lists uploads could be chosen. A silent component cost 15 s on every connect.
    @Test func probesConcurrentlyWithinTheDeadlineAndPicksTheLargestNonRoomService() async throws {
        let network = Network(listed: ["rooms.localhost", "silent.localhost", "small.localhost", "big.localhost", "pubsub.localhost"],
                              info: ["localhost": .features("<feature var='urn:xmpp:carbons:2'/>"),
                                     "rooms.localhost": .features("<feature var='http://jabber.org/protocol/muc'/>" + Self.service(limit: 1 << 30)),
                                     "silent.localhost": .silent,
                                     "small.localhost": .features(Self.service(limit: 1_000)),
                                     "big.localhost": .features(Self.service(limit: 5_000))])
        let (outcome, elapsed) = try await discover(network, timeout: .milliseconds(500))
        #expect(try outcome.get() == XMPPUploadService(jid: "big.localhost", maximumFileSize: 5_000))
        // One deadline in all, not one per probe.
        #expect(elapsed < .seconds(2))
    }

    @Test func theDomainItselfCanBeTheService() async throws {
        let network = Network(listed: ["silent.localhost"], info: ["localhost": .features(Self.service(limit: nil)), "silent.localhost": .silent])
        let (outcome, _) = try await discover(network, timeout: .milliseconds(300))
        #expect(try outcome.get() == XMPPUploadService(jid: "localhost", maximumFileSize: nil))
    }

    /// Refusals are an answer ("none offered"); a component that never answered is not, so the caller keeps what it
    /// knew instead of removing the attach button.
    @Test func onlyAnsweredProbesCanConcludeThatNoServiceIsOffered() async throws {
        let refused = Network(listed: ["pubsub.localhost"], info: [:])
        let (none, _) = try await discover(refused, timeout: .milliseconds(300))
        #expect(try none.get() == nil)

        let silent = Network(listed: ["uploads.localhost"], info: ["localhost": .features(""), "uploads.localhost": .silent])
        let (open, _) = try await discover(silent, timeout: .milliseconds(300))
        #expect(throws: XMPPClientError.timedOut) { try open.get() }
    }
}
