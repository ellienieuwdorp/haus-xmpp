import Foundation
import Testing
@testable import XMPPProtocol

// XEP-0363 service discovery over a real socket, against `LoopbackServer` acting as the server and its components.
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

    // What the server and each component answer to disco#info; an entity missing here refuses. `listed` is the
    // domain's items.
    private struct Network {
        var listed: [String]
        var info: [String: Answer]
    }

    private static func connected(to server: LoopbackServer) async throws -> XMPPClient {
        let client = server.client()
        async let online: Void = server.connect(client)
        try await server.authenticate(features: "")
        let bind = try await server.next()
        let jid = "<jid>alice@localhost/r</jid>"
        try await server.send("<iq type='result' id='\(bind.attributes["id"] ?? "")'><bind xmlns='\(bindNamespace)'>\(jid)</bind></iq>")
        #expect(try await server.next().name == "presence")
        try await online
        return client
    }

    // Runs `uploadService` against `network` and returns its outcome and how long it took.
    private func discover(_ network: Network, timeout: Duration) async throws -> (Result<XMPPUploadService?, any Error>, Duration) {
        let server = try await LoopbackServer.start()
        defer { Task { await server.stop() } }
        let client = try await Self.connected(to: server)
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

    // A silent component must not cost a deadline per probe, and a MUC service that also lists uploads is never chosen.
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

    // Refusals are an answer ("none offered"); a component that never answered is not, so the caller keeps what it
    // knew instead of removing the attach button.
    @Test func onlyAnsweredProbesCanConcludeThatNoServiceIsOffered() async throws {
        let refused = Network(listed: ["pubsub.localhost"], info: [:])
        let (none, _) = try await discover(refused, timeout: .milliseconds(300))
        #expect(try none.get() == nil)

        let silent = Network(listed: ["uploads.localhost"], info: ["localhost": .features(""), "uploads.localhost": .silent])
        let (open, _) = try await discover(silent, timeout: .milliseconds(300))
        #expect(throws: XMPPClientError.timedOut) { try open.get() }
    }
    // The client hands the slot request's error reply to the decoder instead of reducing it to its condition.
    @Test func aSlotRefusalArrivesWithItsReason() async throws {
        let server = try await LoopbackServer.start()
        defer { Task { await server.stop() } }
        let client = try await Self.connected(to: server)
        let service = XMPPUploadService(jid: "uploads.localhost", maximumFileSize: 1_000)
        let stanzas = "xmlns='urn:ietf:params:xml:ns:xmpp-stanzas'"
        let tooLarge = "<file-too-large xmlns='urn:xmpp:http:upload:0'><max-file-size>1000</max-file-size></file-too-large>"
        let answers = ["<error type='modify'><not-acceptable \(stanzas)/>\(tooLarge)</error>",
                       "<error type='cancel'><internal-server-error \(stanzas)/></error>"]
        var outcomes: [any Error] = []
        for answer in answers {
            async let slot = client.requestUploadSlot(service: service, filename: "a.jpg", size: 1_016, contentType: "application/octet-stream")
            let request = try await server.next()
            #expect(request.child("request", namespace: XMPPUploadService.namespace)?.attributes["size"] == "1016")
            try await server.send("<iq type='error' id='\(request.attributes["id"] ?? "")' from='uploads.localhost'>\(answer)</iq>")
            do { _ = try await slot; Issue.record("a refusal returned a slot") } catch { outcomes.append(error) }
        }
        #expect(outcomes.first as? XMPPUploadError == .fileTooLarge(maximumFileSize: 1_000))
        #expect(outcomes.last as? XMPPIQError == .stanza(condition: "internal-server-error"))
        await client.disconnect()
    }
}
