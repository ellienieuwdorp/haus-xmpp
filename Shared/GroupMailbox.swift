import Foundation

// Small JSON files the app and its extensions leave each other in the App Group, which only this build can write. A
// file that is missing, larger than `maximumBytes` or not the expected JSON reads as nil.
struct GroupMailbox: Sendable {
    let directory: URL
    static let maximumBytes = 4 * 1024

    func save(_ value: some Encodable, as name: String) throws {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let data = try JSONEncoder().encode(value)
        #if os(iOS)
        // The extensions run while the iPhone is locked; they never run before the first unlock anyway.
        try data.write(to: directory.appending(path: name), options: [.atomic, .completeFileProtectionUntilFirstUserAuthentication])
        #else
        try data.write(to: directory.appending(path: name), options: [.atomic])
        #endif
    }

    func read<Value: Decodable>(_ name: String) -> Value? {
        let url = directory.appending(path: name)
        guard let size = (try? FileManager.default.attributesOfItem(atPath: url.path))?[.size] as? Int,
              size <= Self.maximumBytes, let data = try? Data(contentsOf: url) else { return nil }
        return try? JSONDecoder().decode(Value.self, from: data)
    }

    func remove(_ name: String) {
        // A file left behind reads as stale or answered.
        try? FileManager.default.removeItem(at: directory.appending(path: name))
    }
}
