import Foundation

/// Device tests may reach the same disposable lab through the Mac's private LAN address.
/// The explicit test CA is scoped to this connection, never installed as system trust.
enum DevelopmentEndpoint {
    static var domain: String {
        #if DEBUG
        if ProcessInfo.processInfo.arguments.contains("-staging") { return "staging.example.net" }
        #endif
        return "localhost"
    }

    static var host: String {
        if domain != "localhost" { return domain }
        #if DEBUG
        if certificateAuthority != nil, let host = ProcessInfo.processInfo.environment["XMPP_LAB_HOST"] {
            let octets = host.split(separator: ".").compactMap { UInt8($0) }
            if octets.count == 4 && (octets[0] == 10 || (octets[0] == 172 && (16...31).contains(octets[1])) || (octets[0] == 192 && octets[1] == 168)) { return host }
        }
        #endif
        return "localhost"
    }

    static var certificateAuthority: Data? {
        #if DEBUG
        if ProcessInfo.processInfo.arguments.contains("-lab-ui-test"),
           let value = ProcessInfo.processInfo.environment["XMPP_LAB_CA_DER"], value.utf8.count < 16_384 {
            return Data(base64Encoded: value)
        }
        #endif
        return nil
    }
}
