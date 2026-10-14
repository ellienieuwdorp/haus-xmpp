import Foundation

/// Device tests may reach the same disposable lab through the Mac's private LAN address.
/// The explicit test CA is scoped to this connection, never installed as system trust.
/// Release builds have none of it: no lab domain, no staging server and no test CA.
enum DevelopmentEndpoint {
    #if DEBUG
    /// The domain of an optional hosted test server, from the `HausStagingDomain` Info.plist key, which the
    /// `HAUS_STAGING_DOMAIN` build setting fills in (set it in Config/Local.xcconfig). Nil when the setting is empty,
    /// and then `-staging` does nothing and the staging notification diagnostics refuse to run.
    static let stagingDomain: String? = {
        guard let value = Bundle.main.object(forInfoDictionaryKey: "HausStagingDomain") as? String else { return nil }
        let domain = value.trimmingCharacters(in: .whitespaces).lowercased()
        return domain.isEmpty || domain.contains("$(") ? nil : domain
    }()

    /// The domain a bare username signs in to: the local lab, or the staging server under `-staging`.
    static var domain: String {
        if ProcessInfo.processInfo.arguments.contains("-staging"), let stagingDomain { return stagingDomain }
        return "localhost"
    }

    static var host: String {
        if domain != "localhost" { return domain }
        if certificateAuthority != nil, let host = ProcessInfo.processInfo.environment["HAUS_LAB_HOST"] {
            let octets = host.split(separator: ".").compactMap { UInt8($0) }
            if octets.count == 4 && (octets[0] == 10 || (octets[0] == 172 && (16...31).contains(octets[1])) || (octets[0] == 192 && octets[1] == 168)) { return host }
        }
        return "localhost"
    }
    #endif

    static var certificateAuthority: Data? {
        #if DEBUG
        if ProcessInfo.processInfo.arguments.contains("-lab-ui-test"),
           let value = ProcessInfo.processInfo.environment["HAUS_LAB_CA_DER"], value.utf8.count < 16_384 {
            return Data(base64Encoded: value)
        }
        #endif
        return nil
    }
}
