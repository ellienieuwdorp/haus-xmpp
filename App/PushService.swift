import Foundation
import UserNotifications
import XMPPProtocol

// Reached over federation: any account server with XEP-0357, s2s, MAM, carbons and stream management works.
enum PushService {
    static let defaultServiceJID = "push.xmpp.haus"

    static var serviceJID: String {
        #if DEBUG
        if let override = ProcessInfo.processInfo.environment["XMPP_PUSH_SERVICE"],
           (try? XMPPPushConfiguration(serviceJID: override, node: "probe")) != nil, !override.contains("@") {
            return override.lowercased()
        }
        #endif
        return defaultServiceJID
    }

    // Debug gets sandbox tokens, Release production ones; a missing value is a build error.
    static var environment: XMPPPushEnvironment? {
        (Bundle.main.object(forInfoDictionaryKey: "HausPushEnvironment") as? String).flatMap(XMPPPushEnvironment.init(rawValue:))
    }

    static let gatewayDefaultTopic = "haus.xmpp.ios"

    // Nil for the gateway default, so the released app's registrations stay as older gateways expect.
    static var topic: String? { topic(bundleIdentifier: Bundle.main.bundleIdentifier) }

    static func topic(bundleIdentifier: String?) -> String? {
        bundleIdentifier == gatewayDefaultTopic ? nil : bundleIdentifier
    }

    // On the Mac push is safe only once the extension decrypts under the transport lease and the liveness handshake
    // keeps a live app's alert to itself; only a Debug run with `-haus-mac-push` registers.
    static var isOffered: Bool {
        #if os(iOS)
        true
        #elseif DEBUG
        ProcessInfo.processInfo.arguments.contains("-haus-mac-push")
        #else
        false
        #endif
    }
}

enum PushStatus: Equatable {
    case off
    case settingUp
    case on
    case notAllowed
    case unsupported
    case unreachable
    case inspected

    var text: String {
        switch self {
        case .off: "Off"
        case .settingUp: "Setting up…"
        case .on: "On"
        case .notAllowed: "Off (not allowed in \(ThisDevice.settingsApp))"
        case .unsupported: "Your server doesn't support push notifications"
        case .unreachable: "Couldn't reach the push service"
        case .inspected: "Inspection complete"
        }
    }

    // Only a sign-in or a tap in Settings may ask; a reconnect at launch never shows the system prompt.
    static func gate(for authorization: UNAuthorizationStatus, interactive: Bool) -> PushStatus? {
        switch authorization {
        case .authorized, .provisional: nil
        #if os(iOS)
        case .ephemeral: nil
        #endif
        case .denied: .notAllowed
        case .notDetermined: interactive ? nil : .off
        @unknown default: .notAllowed
        }
    }

    // macOS starts the notification extension only for apps that may show alerts; under quiet delivery a push would
    // leave the gateway's generic text beside the app's own notification.
    static func gate(for authorization: UNAuthorizationStatus, alertStyle: UNAlertStyle, interactive: Bool) -> PushStatus? {
        if let stop = gate(for: authorization, interactive: interactive) { return stop }
        return authorization == .notDetermined || authorization == .authorized && alertStyle != .none ? nil : .notAllowed
    }

    static func resumesSetup(after authorization: UNAuthorizationStatus, status: PushStatus, wanted: Bool, offered: Bool) -> Bool {
        offered && wanted && status == .off && authorization != .notDetermined
    }

    static func settled(after error: any Error, wanted: Bool) -> PushStatus {
        wanted ? after(error) : .off
    }

    static func after(_ error: any Error) -> PushStatus {
        switch error {
        case XMPPNotificationError.pushUnavailable: .unsupported
        case PushRegistration.Failure.denied: .notAllowed
        default: .unreachable
        }
    }
}

enum PushCleanup {
    // The gateway answers an unknown node like bad credentials, so a retry can never succeed. A retired gateway is only
    // asked as a courtesy.
    static func revocationSettles(_ error: any Error, retired: Bool) -> Bool {
        if let stanza = error as? XMPPIQError, case .stanza(let condition) = stanza {
            return retired || condition == "item-not-found" || condition == "forbidden"
        }
        return retired && (error as? XMPPClientError) == .timedOut
    }

    static func disableSettles(_ error: any Error) -> Bool {
        switch error {
        case XMPPIQError.stanza: true
        case XMPPNotificationError.pushUnavailable: true
        default: false
        }
    }
}
