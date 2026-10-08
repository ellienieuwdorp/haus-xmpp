import Foundation

/// How copy names the device the app runs on ("Messages and keys stay on this iPhone"). On an iPhone, and on anything
/// unrecognised, every word is what the copy hard-coded before.
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

    /// "iPhone", "iPad" or "Mac".
    static var noun: String {
        switch kind { case .iPhone: "iPhone"; case .iPad: "iPad"; case .mac: "Mac" }
    }

    /// The operating system's name, as in "your iOS Show Previews setting".
    static var systemName: String {
        switch kind { case .iPhone: "iOS"; case .iPad: "iPadOS"; case .mac: "macOS" }
    }

    /// The system settings app, as in "Open iOS Settings".
    static var settingsApp: String {
        switch kind { case .iPhone: "iOS Settings"; case .iPad: "iPadOS Settings"; case .mac: "System Settings" }
    }
}
