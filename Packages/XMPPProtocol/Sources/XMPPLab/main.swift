import Foundation
import XMPPProtocol

@main struct Lab {
    static func main() async {
        do { try await run() } catch { print("FAILED: TLS or XMPP session could not be established (\(error))"); exit(1) }
    }
    static func run() async throws {
        let env = ProcessInfo.processInfo.environment
        guard let domain = env["XMPP_LAB_DOMAIN"], let user = env["XMPP_LAB_USERNAME"], let password = env["XMPP_LAB_PASSWORD"] else {
            print("Required environment: XMPP_LAB_DOMAIN, XMPP_LAB_USERNAME, XMPP_LAB_PASSWORD; optional XMPP_LAB_HOST, XMPP_LAB_PORT, XMPP_LAB_CA_DER, XMPP_LAB_TO, XMPP_LAB_BODY. Lab plaintext only.")
            return
        }
        let ca = try env["XMPP_LAB_CA_DER"].map { try Data(contentsOf: URL(fileURLWithPath: $0)) }
        let client = XMPPClient(labCertificateAuthority: ca)
        let timeout = Task { try await Task.sleep(for: .seconds(30)); await client.disconnect() }
        try await client.connect(host: env["XMPP_LAB_HOST"] ?? domain, port: UInt16(env["XMPP_LAB_PORT"] ?? "5223") ?? 5223, domain: domain, username: user, password: password)
        var receivedCount = 0
        let cycles = max(1, Int(env["XMPP_LAB_CYCLES"] ?? "1") ?? 1)
        for await event in client.events {
            switch event {
            case .state(.online):
                print("ONLINE")
                if let to = env["XMPP_LAB_TO"] {
                    let id = try await client.sendMessage(to: to, body: env["XMPP_LAB_BODY"] ?? "Local protocol smoke test", id: env["XMPP_LAB_ID"] ?? UUID().uuidString)
                    print("SENT \(id)")
                }
            case .state(.disconnected(let reason)):
                print("DISCONNECTED \(reason ?? "requested")")
                if receivedCount > 0 && receivedCount < cycles {
                    try await client.connect(host: env["XMPP_LAB_HOST"] ?? domain, port: UInt16(env["XMPP_LAB_PORT"] ?? "5223") ?? 5223, domain: domain, username: user, password: password)
                } else {
                    timeout.cancel()
                    return
                }
            case .state: break
            case .message(let message):
                if let expected = env["XMPP_LAB_EXPECT_BODY"], message.body != expected { throw XMPPClientError.unexpectedProtocol }
                if let expectedID = env["XMPP_LAB_ID"], message.id != expectedID || message.originID != expectedID { throw XMPPClientError.unexpectedProtocol }
                receivedCount += 1
                print("RECEIVED \(message.id) bytes=\(message.body.utf8.count)")
                await client.disconnect()
            }
        }
    }
}
