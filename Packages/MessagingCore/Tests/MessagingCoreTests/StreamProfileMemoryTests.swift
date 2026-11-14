import Foundation
import Testing
import XMPPProtocol
@testable import MessagingCore

// The app's `ServerProfileMemory` and an extension's `StreamProfileMemory` on separate instances of one App Group suite,
// as two processes hold it.
struct StreamProfileMemoryTests {
    private let account = "alice@example.org", other = "bob@example.org"
    private let endpoint = XMPPEndpoint(host: "xmpp.example.org", port: 5223, security: .directTLS)

    private let appSuite = "haus.xmpp.tests.streams.app.\(UUID().uuidString)", group = "haus.xmpp.tests.streams.group.\(UUID().uuidString)"

    private func clean() {
        for suite in [appSuite, group] { UserDefaults(suiteName: suite)?.removePersistentDomain(forName: suite) }
    }

    @Test func whatTheAppLearnedIsWhatAnExtensionConnectsWithAndARefusalHoldsForBoth() throws {
        let app = try #require(UserDefaults(suiteName: appSuite))
        defer { clean() }
        let appMemory = ServerProfileMemory(defaults: app, streamProfiles: UserDefaults(suiteName: group))
        let extensionMemory = StreamProfileMemory(defaults: try #require(UserDefaults(suiteName: group)))
        let learned = XMPPStreamProfile(endpoint: endpoint, mechanisms: ["SCRAM-SHA-256"], streamManagement: true)
        appMemory.saveStreamProfile(learned, account: account)
        #expect(extensionMemory.streamProfile(account: account) == learned)
        #expect(extensionMemory.streamProfile(account: other) == nil)
        #expect(app.object(forKey: "streamProfile." + account) == nil, "the profile lives only in the App Group")

        let refused = XMPPStreamProfile(endpoint: endpoint, mechanisms: [], streamManagement: false, refusedEarlyData: Date(timeIntervalSince1970: 1_000))
        extensionMemory.saveStreamProfile(refused, account: account)
        #expect(appMemory.streamProfile(account: account) == refused)
    }

    @Test func signOutForgetsOnlyThatAccountsProfileInEveryProcess() throws {
        let app = try #require(UserDefaults(suiteName: appSuite))
        defer { clean() }
        let appMemory = ServerProfileMemory(defaults: app, streamProfiles: UserDefaults(suiteName: group))
        let extensionMemory = StreamProfileMemory(defaults: try #require(UserDefaults(suiteName: group)))
        let profile = XMPPStreamProfile(endpoint: endpoint, mechanisms: ["SCRAM-SHA-1"], streamManagement: true)
        extensionMemory.saveStreamProfile(profile, account: account)
        extensionMemory.saveStreamProfile(profile, account: other)
        appMemory.forget(account: account)
        #expect(extensionMemory.streamProfile(account: account) == nil)
        #expect(extensionMemory.streamProfile(account: other) == profile)
    }
}
