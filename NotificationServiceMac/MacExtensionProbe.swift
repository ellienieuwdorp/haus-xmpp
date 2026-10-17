#if DEBUG && os(macOS)
import Foundation
import os
import Security
import UserNotifications
import MessagingCore

/// Debug-only check that the signed Mac app and its signed notification extension share their storage, run inside the
/// extension process for a real remote notification. Compiled into the Mac app and the
/// Mac extension only; nothing here ships.
///
/// The app arms it (`-haus-arm-extension-probe suppress|pass|liveness`): it saves a random nonce as a data-protection Keychain
/// item and writes the same nonce, with the mode, to `Debug/extension-probe.json` in the App Group container. The
/// extension takes the arm file on the next remote request (it is used once) and records what it can reach (the App
/// Group container, the store, the access gate, the wrapping key, the notification account and the app's nonce item) as
/// one line in `Debug/extension-probe-results.jsonl`. An armed `suppress` request is then delivered with empty content
/// and nothing else runs, so the filtering entitlement can be seen to hide it; in `pass` mode the request continues to
/// the normal extension run. `liveness` also rings the app as the lease wait does (`AppLiveness`) and records whether
/// an answer to its nonce came back within the handshake's window, then continues like `pass`: the round trip between
/// the two sandboxed processes, which the app answers when started with `-haus-liveness-answer`. Without an arm file
/// nothing is recorded. Records hold paths, statuses and counts, never an
/// address, password, key or token.
enum MacExtensionProbe {
    enum Mode: String, Codable { case suppress, pass, liveness }

    struct Arm: Codable { let mode: Mode; let nonce: String; let armedAt: Date }

    static let keychainService = "haus.xmpp.extension-probe"
    private static let log = Logger(subsystem: "haus.xmpp.ios", category: "extension-probe")

    static func directory() throws -> URL {
        let directory = try SharedStorage.groupContainer().appending(path: "Debug", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        return directory
    }

    static var armFile: URL { get throws { try directory().appending(path: "extension-probe.json") } }
    static var resultsFile: URL { get throws { try directory().appending(path: "extension-probe-results.jsonl") } }

    private static var nonceQuery: [String: Any] { KeychainQuery.genericPassword(service: keychainService, account: "nonce") }

    // MARK: App side

    /// Saves a new nonce item and the arm file. Returns the Keychain status of the add.
    static func arm(_ mode: Mode) throws -> OSStatus {
        let nonce = UUID().uuidString
        SecItemDelete(nonceQuery as CFDictionary)
        var item = nonceQuery
        item[kSecValueData as String] = Data(nonce.utf8)
        item[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
        let status = SecItemAdd(item as CFDictionary, nil)
        let encoder = JSONEncoder(); encoder.dateEncodingStrategy = .iso8601
        try encoder.encode(Arm(mode: mode, nonce: nonce, armedAt: Date())).write(to: armFile, options: .atomic)
        return status
    }

    /// The recorded lines, oldest first, and whether the arm file is still waiting for a request.
    static func results() throws -> (lines: [String], stillArmed: Bool) {
        let text = (try? String(contentsOf: resultsFile, encoding: .utf8)) ?? ""
        return (text.split(separator: "\n").map(String.init), FileManager.default.fileExists(atPath: try armFile.path))
    }

    /// Removes the results, the arm file and the nonce item.
    static func clear() throws {
        for file in [try resultsFile, try armFile] { try? FileManager.default.removeItem(at: file) }
        SecItemDelete(nonceQuery as CFDictionary)
    }

    // MARK: Extension side

    /// Takes the arm file, if the app left one: nil means this request is not probed.
    static func takeArm() -> Arm? {
        guard let file = try? armFile, let data = try? Data(contentsOf: file) else { return nil }
        try? FileManager.default.removeItem(at: file)
        let decoder = JSONDecoder(); decoder.dateDecodingStrategy = .iso8601
        return try? decoder.decode(Arm.self, from: data)
    }

    /// Records what this process can reach for an armed request and returns the armed mode.
    static func record(_ request: UNNotificationRequest, arm: Arm) async -> Mode {
        var fields: [String: String] = [
            "at": ISO8601DateFormatter().string(from: Date()),
            "process": Bundle.main.bundleIdentifier ?? "?",
            "pid": String(ProcessInfo.processInfo.processIdentifier),
            "sandbox": ProcessInfo.processInfo.environment["APP_SANDBOX_CONTAINER_ID"] ?? "none",
            "request.category": request.content.categoryIdentifier,
            "request.body": request.content.body == "New message" ? "gateway generic" : "\(request.content.body.count) characters",
            "request.thread": request.content.threadIdentifier.isEmpty ? "none" : "set"
        ]
        do {
            let container = try SharedStorage.groupContainer()
            fields["group container"] = "ok \(container.path)"
        } catch { fields["group container"] = "FAILED \(error)" }
        fields["armed"] = "\(arm.mode.rawValue), \(Int(Date().timeIntervalSince(arm.armedAt))) s ago"

        do {
            let root = try await SharedStorage.directory(migrate: false)
            let database = root.appending(path: "messages.sqlite")
            let handle = try FileHandle(forReadingFrom: database)
            let header = try handle.read(upToCount: 16) ?? Data()
            try handle.close()
            fields["store"] = "\(header.starts(with: Data("SQLite format 3".utf8)) ? "readable SQLite" : "unexpected header") \(database.path)"
        } catch { fields["store"] = "FAILED \(error)" }

        do {
            let gate = try NotificationAccessGate.location()
            fields["access gate"] = try NotificationAccessGate.isDisabled(at: gate) ? "disabled (logout tombstone)" : "passes"
        } catch { fields["access gate"] = "FAILED \(error)" }
        if let root = try? SharedStorage.groupContainer() {
            fields["pre-upgrade hold"] = PreUpgradeHold.isHeld(groupRoot: root) ? "held" : "none"
        }

        do {
            let key = try EncryptionKeychain.load(storageID: "primary", allowCreation: false)
            fields["wrapping key"] = "present, \(key.count) bytes, access group \(accessGroup(service: "haus.xmpp.encryption-state", account: "primary"))"
        } catch EncryptionKeychain.Failure.missing { fields["wrapping key"] = "none" }
        catch { fields["wrapping key"] = "FAILED \(error)" }

        do {
            if let account = try NotificationAccount.load() {
                fields["notification account"] = "present, push subscription \(account.push == nil ? "none" : "saved"), access group "
                    + accessGroup(service: "haus.xmpp.notification-account", account: "primary")
            } else { fields["notification account"] = "none" }
        } catch { fields["notification account"] = "FAILED \(error)" }

        var lookup = nonceQuery
        lookup[kSecReturnData as String] = true
        lookup[kSecMatchLimit as String] = kSecMatchLimitOne
        var result: CFTypeRef?
        let status = SecItemCopyMatching(lookup as CFDictionary, &result)
        if status == errSecSuccess, let data = result as? Data {
            let nonce = String(decoding: data, as: UTF8.self)
            fields["app nonce item"] = arm.nonce == nonce ? "read, matches the arm file" : "read, does NOT match the arm file"
        } else { fields["app nonce item"] = status == errSecItemNotFound ? "none" : "FAILED \(status)" }

        if arm.mode == .liveness { fields["liveness"] = await livenessRoundTrip() }
        fields["delivers"] = arm.mode == .suppress ? "empty content (suppress)" : "normal run"
        if let line = try? JSONSerialization.data(withJSONObject: fields, options: [.sortedKeys]),
           let file = try? resultsFile {
            if let handle = try? FileHandle(forWritingTo: file) {
                _ = try? handle.seekToEnd(); try? handle.write(contentsOf: line + Data("\n".utf8)); try? handle.close()
            } else {
                try? (line + Data("\n".utf8)).write(to: file)
            }
            log.notice("probe \(String(decoding: line, as: UTF8.self), privacy: .public)")
        }
        return arm.mode
    }

    /// Rings the app and waits for an answer to this nonce, as `acquireTransportOwnership` does while the lease is busy.
    private static func livenessRoundTrip() async -> String {
        guard let container = try? SharedStorage.groupContainer() else { return "FAILED no group container" }
        let channel = AppLiveness.ExtensionChannel(files: AppLiveness.Files(groupRoot: container))
        let request = LivenessRequest()
        do { try channel.ask(request) } catch { return "FAILED to ask \(error)" }
        let clock = ContinuousClock(), start = clock.now
        while LivenessHandshake.isListening(to: request) {
            if LivenessHandshake.accepts(channel.latestAnswer(), to: request) {
                return "answered in \(Int((clock.now - start) / .milliseconds(1))) ms, nonce matches"
            }
            try? await Task.sleep(for: .milliseconds(50))
        }
        return channel.latestAnswer() == nil ? "no answer" : "no answer to this nonce in time"
    }

    private static func accessGroup(service: String, account: String) -> String {
        var lookup = KeychainQuery.genericPassword(service: service, account: account)
        lookup[kSecReturnAttributes as String] = true
        var result: CFTypeRef?
        let status = SecItemCopyMatching(lookup as CFDictionary, &result)
        guard status == errSecSuccess, let attributes = result as? [String: Any] else { return "? (\(status))" }
        return attributes[kSecAttrAccessGroup as String] as? String ?? "?"
    }
}
#endif
