#if DEBUG
import AppKit
import CoreGraphics
import ImageIO
import Intents
import MessagingCore
import UniformTypeIdentifiers
import UserNotifications

/// Debug-only launch arguments for checking the Mac notification extension with real remote notifications. Push stays
/// gated off in the app itself (`PushRegistration.request()` throws on the Mac); these hooks register for a token only
/// when asked, and nothing here ships.
///
/// - `-haus-notification-settings`: the app's notification authorization and alert settings.
/// - `-haus-request-provisional`: asks for provisional authorization, which the system grants without a prompt and which
///   delivers quietly to Notification Center.
/// - `-haus-register-push`: registers for remote notifications. The token goes to standard output as the file
///   `push-token.hex` (`HAUS-FILE`, see `MacDebugHooks`); it is never logged.
/// - `-haus-arm-extension-probe suppress|pass`: arms `MacExtensionProbe` for the next remote request.
/// - `-haus-extension-probe-results`: the extension's probe records; `-haus-extension-probe-clear` removes them.
/// - `-haus-delivered-notifications`: what Notification Center holds for the app (category, which fields are set,
///   attachments); `-haus-clear-delivered` removes it all afterwards.
/// - `-haus-group-avatar-probe`: posts a synthetic group communication notification with a room avatar and reports
///   whether the intent, the updated content and the delivered notification carry an image.
@MainActor enum MacPushProbe {
    private static let flags = ["-haus-notification-settings", "-haus-request-provisional", "-haus-register-push", "-haus-arm-extension-probe",
                                "-haus-extension-probe-results", "-haus-extension-probe-clear", "-haus-delivered-notifications",
                                "-haus-clear-delivered", "-haus-group-avatar-probe"]

    static func start() {
        guard flags.contains(where: MacDebugHooks.has) else { return }
        Task {
            let center = UNUserNotificationCenter.current()
            if MacDebugHooks.has("-haus-request-provisional") {
                do {
                    let granted = try await center.requestAuthorization(options: [.provisional, .alert, .sound, .badge])
                    log("provisional authorization: \(granted ? "granted" : "not granted")")
                } catch { log("provisional authorization: FAILED \(error)") }
            }
            if MacDebugHooks.has("-haus-notification-settings") {
                let settings = await center.notificationSettings()
                log("notification settings: authorization \(name(settings.authorizationStatus)), alert \(name(settings.alertSetting)), "
                    + "style \(settings.alertStyle.rawValue), notification center \(name(settings.notificationCenterSetting)), "
                    + "badge \(name(settings.badgeSetting)), sound \(name(settings.soundSetting))")
            }
            if let value = MacDebugHooks.value(after: "-haus-arm-extension-probe") {
                guard let mode = MacExtensionProbe.Mode(rawValue: value) else { log("extension probe: unknown mode \(value)"); return }
                do { log("extension probe armed: \(mode.rawValue), nonce item status \(try MacExtensionProbe.arm(mode))") }
                catch { log("extension probe: FAILED to arm \(error)") }
            }
            if MacDebugHooks.has("-haus-register-push") {
                log("registering for remote notifications")
                NSApp.registerForRemoteNotifications()
            }
            if MacDebugHooks.has("-haus-extension-probe-results") {
                do {
                    let (lines, armed) = try MacExtensionProbe.results()
                    log("extension probe: \(lines.count) record(s), arm file \(armed ? "still waiting" : "taken or absent")")
                    lines.forEach { log("extension probe record \($0)") }
                } catch { log("extension probe: FAILED to read results \(error)") }
            }
            if MacDebugHooks.has("-haus-group-avatar-probe") { await groupAvatarProbe(donates: MacDebugHooks.has("-haus-group-avatar-donate")) }
            if MacDebugHooks.has("-haus-delivered-notifications") { await logDelivered() }
            if MacDebugHooks.has("-haus-clear-delivered") {
                center.removeAllDeliveredNotifications()
                log("delivered notifications removed")
            }
            if MacDebugHooks.has("-haus-extension-probe-clear") {
                do { try MacExtensionProbe.clear(); log("extension probe cleared") } catch { log("extension probe: FAILED to clear \(error)") }
            }
        }
    }

    /// What Notification Center holds for the app, oldest first.
    static func logDelivered() async {
        let delivered = await UNUserNotificationCenter.current().deliveredNotifications().sorted { $0.date < $1.date }
        log("delivered: \(delivered.count)")
        for notification in delivered { log("delivered \(describe(notification))") }
    }

    static func received(token: Data) {
        log("push token received, \(token.count) bytes (written to push-token.hex, not logged)")
        let hex = token.map { String(format: "%02x", $0) }.joined()
        FileHandle.standardOutput.write(Data("HAUS-FILE push-token.hex \(Data(hex.utf8).base64EncodedString())\n".utf8))
    }

    static func failed(_ error: any Error) {
        let error = error as NSError
        log("push registration FAILED \(error.domain) \(error.code) \(error.localizedDescription)")
    }

    // MARK: Group avatar

    /// A synthetic group (no real names, nothing donated) through the same intent and update the poster uses.
    nonisolated private static func groupAvatarProbe(donates: Bool) async {
        let center = UNUserNotificationCenter.current()
        func log(_ text: String) { FileHandle.standardOutput.write(Data("HAUS \(text)\n".utf8)) }
        let room = png(red: 0.2, green: 0.5, blue: 0.9), sender = png(red: 0.9, green: 0.4, blue: 0.2)
        let communication = NotificationCommunication(
            sender: .init(handle: "sender@probe.invalid", displayName: "Probe Sender", avatarHash: "sender"),
            conversationIdentifier: "probe-group", account: .init(handle: "me@probe.invalid", displayName: "Me", avatarHash: nil),
            groupName: "Probe Group", groupAvatarHash: "room",
            otherRecipients: [.init(handle: "other@probe.invalid", displayName: "Other", avatarHash: nil)], body: "Group avatar probe")
        // With the room's avatar, then with only the sender's, to tell which one the system keeps.
        for (label, roomImage, senderImage) in [("with room avatar", room, sender), ("without room avatar", nil, sender),
                                                ("room avatar, no sender avatar", room, nil)] {
            let intent = CommunicationNotification.intent(communication) { $0 == "room" ? roomImage : senderImage }
            log("group avatar \(label): intent group image \(intent.__image(forParameterNamed: "speakableGroupName") == nil ? "none" : "set"), "
                + "sender image \(intent.sender?.image == nil ? "none" : "set")")
            let plain = UNMutableNotificationContent()
            plain.title = "Probe Group"; plain.body = "Group avatar probe"; plain.threadIdentifier = "probe-group"
            // No donation unless asked: the probe must not leave a synthetic contact in the system's suggestions. With
            // `-haus-group-avatar-donate` it donates as the poster does and deletes the app's donations afterwards.
            let donate: CommunicationNotification.Donate? = donates ? CommunicationNotification.systemDonate : nil
            guard let updated = await CommunicationNotification.content(plain, intent: intent, donate: donate) else {
                log("group avatar \(label): the communication update FAILED")
                continue
            }
            log("group avatar \(label): updated content \(describe(updated))")
            let identifier = "probe-group-\(roomImage == nil ? "" : "room")-\(senderImage == nil ? "" : "sender")"
            do {
                try await center.add(UNNotificationRequest(identifier: identifier, content: updated, trigger: nil))
                try? await Task.sleep(for: .seconds(1))
                let delivered = await center.deliveredNotifications().first { $0.request.identifier == identifier }
                log("group avatar \(label): delivered \(delivered.map { describe($0.request.content) } ?? "not in Notification Center")")
            } catch { log("group avatar \(label): add FAILED \(error)") }
        }
        if donates {
            await CommunicationHistory.deleteAll()
            log("group avatar: donations deleted")
        }
    }

    nonisolated private static func png(red: CGFloat, green: CGFloat, blue: CGFloat) -> Data? {
        let size = 128
        guard let context = CGContext(data: nil, width: size, height: size, bitsPerComponent: 8, bytesPerRow: 0,
                                      space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return nil }
        context.setFillColor(red: red, green: green, blue: blue, alpha: 1)
        context.fill(CGRect(x: 0, y: 0, width: size, height: size))
        guard let image = context.makeImage() else { return nil }
        let data = NSMutableData()
        guard let destination = CGImageDestinationCreateWithData(data, UTType.png.identifier as CFString, 1, nil) else { return nil }
        CGImageDestinationAddImage(destination, image, nil)
        return CGImageDestinationFinalize(destination) ? data as Data : nil
    }

    // MARK: Descriptions

    nonisolated private static func describe(_ notification: UNNotification) -> String {
        "\(notification.request.identifier.prefix(12)) at \(notification.date.formatted(date: .omitted, time: .standard)): "
            + describe(notification.request.content)
    }

    /// Which fields are set. Bodies other than the fixed generic texts are given as a length; the communication
    /// context is not public API, so it is read by key only where the object answers to it.
    nonisolated private static func describe(_ content: UNNotificationContent) -> String {
        let fixed = [NotificationPlanner.fallbackBody, "New message", "Group avatar probe"]
        var parts = ["category \(content.categoryIdentifier.isEmpty ? "none" : content.categoryIdentifier)",
                     "title \(content.title.isEmpty ? "empty" : "\(content.title.count) chars")",
                     "body \(content.body.isEmpty ? "empty" : fixed.contains(content.body) ? "\"\(content.body)\"" : "\(content.body.count) chars")",
                     "thread \(content.threadIdentifier.isEmpty ? "none" : "set")", "attachments \(content.attachments.count)",
                     "sound \(content.sound == nil ? "none" : "set")"]
        let object = content as NSObject
        if object.responds(to: NSSelectorFromString("communicationContext")), let context = object.value(forKey: "communicationContext") as? NSObject {
            parts.append("communication context \(type(of: context)) {\(properties(of: context))}")
            if let sender = context.value(forKey: "sender") as? NSObject {
                parts.append("sender \(type(of: sender)) {\(properties(of: sender))}")
            }
        } else {
            parts.append("communication context none")
        }
        return parts.joined(separator: ", ")
    }

    /// A file URL the system keeps for the notification: whether this sandboxed process can read it, and if it is an
    /// image, its size and centre colour (the probe's room avatar is blue, the sender's orange).
    nonisolated private static func imageFile(_ url: URL) -> String {
        // Probe content only (synthetic names and colours), so the URL itself may be shown.
        guard url.isFileURL else { return "URL \(url.absoluteString.prefix(160))" }
        let location = "file …/\(url.deletingLastPathComponent().lastPathComponent)/\(url.lastPathComponent)"
        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil), let image = CGImageSourceCreateImageAtIndex(source, 0, nil) else {
            return "\(location) (\(FileManager.default.fileExists(atPath: url.path) ? "exists, not an image or unreadable" : "not readable here"))"
        }
        var pixel = [UInt8](repeating: 0, count: 4)
        guard let context = CGContext(data: &pixel, width: 1, height: 1, bitsPerComponent: 8, bytesPerRow: 4,
                                      space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else {
            return "\(location) \(image.width)x\(image.height)"
        }
        context.draw(image, in: CGRect(x: -CGFloat(image.width) / 2, y: -CGFloat(image.height) / 2, width: CGFloat(image.width), height: CGFloat(image.height)))
        let colour = pixel[2] > pixel[0] ? "blue (room)" : pixel[0] > pixel[2] ? "orange (sender)" : "other"
        return "\(location) \(image.width)x\(image.height), centre rgb \(pixel[0]),\(pixel[1]),\(pixel[2]) = \(colour)"
    }

    /// The object's declared Objective-C properties with a summary of each value (a type, count or flag, never text).
    nonisolated private static func properties(of object: NSObject) -> String {
        var names: [String] = []
        var cls: AnyClass? = type(of: object)
        while let current = cls, current != NSObject.self {
            var count: UInt32 = 0
            if let list = class_copyPropertyList(current, &count) {
                for index in 0..<Int(count) { names.append(String(cString: property_getName(list[index]))) }
                free(list)
            }
            cls = class_getSuperclass(current)
        }
        let skipped: Set = ["hash", "superclass", "description", "debugDescription"]
        return names.filter { !skipped.contains($0) && object.responds(to: NSSelectorFromString($0)) }
            .map { "\($0) \(summary(object.value(forKey: $0)))" }.joined(separator: "; ")
    }

    nonisolated private static func summary(_ value: Any?) -> String {
        switch value {
        case nil: "nil"
        case let array as [Any]: "\(array.count) item(s)"
        case let number as NSNumber: number.stringValue
        case is String: "set"
        case let url as URL: imageFile(url)
        case let object?: "\(type(of: object))"
        }
    }

    private static func name(_ status: UNAuthorizationStatus) -> String {
        switch status {
        case .notDetermined: "not determined"
        case .denied: "denied"
        case .authorized: "authorized"
        case .provisional: "provisional"
        @unknown default: "unknown \(status.rawValue)"
        }
    }

    private static func name(_ setting: UNNotificationSetting) -> String {
        switch setting {
        case .notSupported: "not supported"
        case .disabled: "disabled"
        case .enabled: "enabled"
        @unknown default: "unknown \(setting.rawValue)"
        }
    }

    private static func log(_ text: String) { MacDebugHooks.log(text) }
}

extension MacAppDelegate {
    func application(_ application: NSApplication, didRegisterForRemoteNotificationsWithDeviceToken deviceToken: Data) {
        MacPushProbe.received(token: deviceToken)
    }

    func application(_ application: NSApplication, didFailToRegisterForRemoteNotificationsWithError error: any Error) {
        MacPushProbe.failed(error)
    }
}
#endif
