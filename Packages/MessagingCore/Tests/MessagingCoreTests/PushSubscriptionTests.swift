import Foundation
import Testing
import XMPPProtocol
@testable import MessagingCore

struct PushSubscriptionTests {
    private let contract = #/^[A-Za-z0-9_-]{43}$/#

    @Test func freshInstallGeneratesContractShapedDistinctCredentials() throws {
        let first = try PushSubscription.generate(serviceJID: "push.xmpp.haus")
        let second = try PushSubscription.generate(serviceJID: "push.xmpp.haus")
        #expect(first.serviceJID == "push.xmpp.haus")
        #expect(Set(first.publishOptions.keys) == ["secret"])
        let secret = try #require(first.publishOptions["secret"])
        #expect(first.node.wholeMatch(of: contract) != nil && secret.wholeMatch(of: contract) != nil)
        #expect(first.node != secret && first.node != second.node && secret != second.publishOptions["secret"])
    }

    @Test func generationEncodesThirtyTwoRandomBytesAsUnpaddedBase64URL() throws {
        var calls = 0
        let config = try PushSubscription.generate(serviceJID: "push.xmpp.haus") { count in
            calls += 1
            #expect(count == 32)
            return calls == 1 ? Array(224...255) : [UInt8](repeating: 0xFF, count: count)
        }
        // Standard base64 would contain '+', '/' and '=' here; base64url uses '-' and '_' and drops the padding.
        #expect(config.node == "4OHi4-Tl5ufo6err7O3u7_Dx8vP09fb3-Pn6-_z9_v8")
        #expect(config.publishOptions["secret"] == String(repeating: "_", count: 42) + "8")
    }

    @Test func generationFailsInsteadOfUsingWeakRandomness() {
        #expect(throws: PushSubscription.Failure.self) {
            try PushSubscription.generate(serviceJID: "push.xmpp.haus") { _ in throw PushSubscription.Failure.randomUnavailable }
        }
    }

    @Test func planKeepsCreatesOrReplacesByServiceOnly() throws {
        let current = try PushSubscription.generate(serviceJID: "push.xmpp.haus")
        let staging = try XMPPPushConfiguration(serviceJID: "push.staging.example.net", node: String(repeating: "n", count: 43),
                                                publishOptions: ["secret": String(repeating: "s", count: 43)])
        #expect(PushSubscription.plan(saved: nil, serviceJID: "push.xmpp.haus") == .create)
        #expect(PushSubscription.plan(saved: current, serviceJID: "push.xmpp.haus") == .keep(current))
        #expect(PushSubscription.plan(saved: staging, serviceJID: "push.xmpp.haus") == .replace(staging))
        // A DEBUG override to another service replaces the production subscription the same way.
        #expect(PushSubscription.plan(saved: current, serviceJID: "push.localhost") == .replace(current))
        // Service JIDs compare as DNS names.
        #expect(PushSubscription.plan(saved: current, serviceJID: "PUSH.xmpp.haus") == .keep(current))
    }
}
