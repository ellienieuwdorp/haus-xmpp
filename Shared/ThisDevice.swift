import Foundation

enum ThisDevice {
    private enum Kind { case iPhone, iPad, mac }

    private static let kind: Kind = {
        #if os(macOS)
        return .mac
        #else
        // The hardware model, not UIDevice: this is read off the main actor too. The simulator reports the model it
        // simulates in its environment and the host's architecture in uname.
        var system = utsname()
        uname(&system)
        let machine = withUnsafeBytes(of: system.machine) { String(decoding: $0.prefix { $0 != 0 }, as: UTF8.self) }
        let model = ProcessInfo.processInfo.environment["SIMULATOR_MODEL_IDENTIFIER"] ?? machine
        return model.hasPrefix("iPad") ? .iPad : .iPhone
        #endif
    }()

    static var noun: String {
        switch kind { case .iPhone: "iPhone"; case .iPad: "iPad"; case .mac: "Mac" }
    }

    static var systemName: String {
        switch kind { case .iPhone: "iOS"; case .iPad: "iPadOS"; case .mac: "macOS" }
    }

    static var settingsApp: String {
        switch kind { case .iPhone: "iOS Settings"; case .iPad: "iPadOS Settings"; case .mac: "System Settings" }
    }
}
