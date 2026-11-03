import Foundation

// The test CA is scoped to this connection, never installed as system trust. Release builds have no lab domain, staging
// server or test CA.
enum DevelopmentEndpoint {
    #if DEBUG
    static let stagingDomain: String? = {
        guard let value = Bundle.main.object(forInfoDictionaryKey: "HausStagingDomain") as? String else { return nil }
        let domain = value.trimmingCharacters(in: .whitespaces).lowercased()
        return domain.isEmpty || domain.contains("$(") ? nil : domain
    }()

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
