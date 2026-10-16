import Foundation
import UserNotifications
import XMPPProtocol

/// The Haus push gateway every account registers with. Account servers reach it over federation, so any server with
/// XEP-0357 push, s2s, MAM, carbons and stream management works.
enum PushService {
    static let defaultServiceJID = "push.xmpp.haus"

    /// DEBUG builds may point at a lab component with `XMPP_PUSH_SERVICE`; release builds always use the gateway.
    static var serviceJID: String {
        #if DEBUG
        if let override = ProcessInfo.processInfo.environment["XMPP_PUSH_SERVICE"],
           (try? XMPPPushConfiguration(serviceJID: override, node: "probe")) != nil, !override.contains("@") {
            return override.lowercased()
        }
        #endif
        return defaultServiceJID
    }

    /// Set per build configuration in project.yml (`HAUS_PUSH_ENVIRONMENT`): Debug is development-signed and gets
    /// sandbox tokens, Release is distribution-signed and gets production ones. A missing value is a build error, not
    /// something to guess at run time.
    static var environment: XMPPPushEnvironment? {
        (Bundle.main.object(forInfoDictionaryKey: "HausPushEnvironment") as? String).flatMap(XMPPPushEnvironment.init(rawValue:))
    }

    /// The topic the gateway assumes when a registration names none: the released app's, which registered before
    /// topics existed.
    static let gatewayDefaultTopic = "haus.xmpp.ios"

    /// The APNs topic this build's tokens belong to, which is its bundle identifier: the development app's differs from
    /// the released app's. Named in a registration only when it is not the gateway's default, so the released app's
    /// registrations stay exactly as gateways without topics expect them.
    static var topic: String? { topic(bundleIdentifier: Bundle.main.bundleIdentifier) }

    static func topic(bundleIdentifier: String?) -> String? {
        bundleIdentifier == gatewayDefaultTopic ? nil : bundleIdentifier
    }

    /// Whether this build registers for push. The iPhone always does. On the Mac a push is only safe once the
    /// notification extension has been seen decrypting under the transport lease there, and a live app has been seen
    /// keeping its alert to itself through the liveness handshake; until those runs pass, only a Debug run started
    /// with `-haus-mac-push` registers, and a Release build never does. Where it is false, Settings shows no push
    /// switch and a subscription left by such a run is turned off on the next connection.
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

/// What Settings says about push for the signed-in account.
enum PushStatus: Equatable {
    /// Turned off in Settings, or never asked for notification permission.
    case off
    case settingUp
    case on
    /// Notifications are not allowed for the app in the system's settings.
    case notAllowed
    /// The account's server does not advertise urn:xmpp:push:0.
    case unsupported
    /// The gateway or the account server did not accept the registration.
    case unreachable
    /// DEBUG notification inspection finished (`--inspect-notification`).
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

    /// Where a push setup stops because of the notification permission, or nil to go on (asking if `interactive`).
    /// Only a sign-in or a tap in Settings may ask; a reconnect at launch never shows the system prompt.
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

    /// What Settings shows after a push setup or cleanup failed. Turned off, it stays "Off": a stored revocation or
    /// disable retries silently on the next connection, and an error under an Off switch would contradict it.
    static func settled(after error: any Error, wanted: Bool) -> PushStatus {
        wanted ? after(error) : .off
    }

    /// A failed setup, in the words Settings uses.
    static func after(_ error: any Error) -> PushStatus {
        switch error {
        case XMPPNotificationError.pushUnavailable: .unsupported
        case PushRegistration.Failure.denied: .notAllowed
        default: .unreachable
        }
    }
}

/// When a turned-off subscription counts as gone. Anything else keeps the work stored for the next connection.
enum PushCleanup {
    /// The gateway answers a node it does not hold (or not for this account) like bad credentials: a retry can never
    /// succeed and nothing of ours is left there. A retired service (the staging gateway) is only asked as a courtesy:
    /// any error answer or silence settles it, because the account server's disable, kept separately, is what stops
    /// publishes. A lost connection or a cancelled request never settles a revocation.
    static func revocationSettles(_ error: any Error, retired: Bool) -> Bool {
        if let stanza = error as? XMPPIQError, case .stanza(let condition) = stanza {
            return retired || condition == "item-not-found" || condition == "forbidden"
        }
        return retired && (error as? XMPPClientError) == .timedOut
    }

    /// The account server answered, or no longer offers push at all: it holds no registration to disable. Transport
    /// failures keep the disable pending.
    static func disableSettles(_ error: any Error) -> Bool {
        switch error {
        case XMPPIQError.stanza: true
        case XMPPNotificationError.pushUnavailable: true
        default: false
        }
    }
}
