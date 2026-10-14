import Foundation
import XMPPProtocol

/// What the account's server offers for blocking, from its last completed feature discovery
/// (`ServerProfileMemory`). Blocking is XEP-0191; reports ride on a block (XEP-0377) and may quote archived stanza IDs
/// only when the server keeps an archive (XEP-0313).
struct BlockingSupport: Equatable, Sendable {
    static let blockingFeature = "urn:xmpp:blocking"
    static let reportingFeature = "urn:xmpp:reporting:1"

    /// nil while no discovery has completed for the account.
    var blocking: Bool?
    /// The server says it processes reports. Without it a report still blocks, and the report may go unread.
    var reporting = false
    var archive = false

    init(blocking: Bool? = nil, reporting: Bool = false, archive: Bool = false) {
        self.blocking = blocking; self.reporting = reporting; self.archive = archive
    }

    init(features: Set<String>?) {
        guard let features else { self.init(); return }
        self.init(blocking: features.contains(Self.blockingFeature), reporting: features.contains(Self.reportingFeature),
                  archive: features.contains(ConnectionSetup.archiveFeature))
    }
}

/// Whether Block, Unblock and Report can run now, and the short reason shown on a disabled action when not.
enum BlockingAvailability: Equatable {
    case available
    case unavailable(String)

    var isAvailable: Bool { self == .available }
    var reason: String? { if case .unavailable(let reason) = self { reason } else { nil } }

    /// Sample conversations block locally, so the actions can be tried without a server.
    static func evaluate(signedIn: Bool, isDemo: Bool, ready: Bool, support: BlockingSupport, domain: String) -> BlockingAvailability {
        if isDemo { return .available }
        guard signedIn else { return .unavailable("Sign in to block") }
        if support.blocking == false { return .unavailable("\(domain) doesn’t support blocking") }
        guard ready, support.blocking == true else { return .unavailable("Available when connected") }
        return .available
    }
}

/// A block or report waiting for its confirmation dialog. `messageID` names the reported message, when a report came
/// from a message's menu.
struct BlockRequest: Identifiable, Equatable {
    enum Kind: Equatable { case block, report }
    let kind: Kind
    let chatID: String
    let name: String
    var messageID: String? = nil
    var id: String { "\(kind)|\(chatID)|\(messageID ?? "")" }
}

/// The confirmation dialogs' words. Explanatory copy lives here, not in permanent footers.
enum BlockingCopy {
    static func blockTitle(_ name: String) -> String { "Block \(name)?" }

    static func blockMessage(_ name: String, domain: String) -> String {
        "\(name) won’t be able to message you or see when you’re online. Your server, \(domain), enforces this for all your devices. You can unblock them in Settings."
    }

    static func reportTitle(_ name: String, message: Bool) -> String { message ? "Report this message?" : "Report \(name)?" }

    /// Says where the report goes and what it holds: the address, the reason and, for a message, its archive ID. The
    /// server admin cannot read encrypted messages.
    static func reportMessage(_ name: String, domain: String, quotesMessage: Bool, serverHandlesReports: Bool) -> String {
        let contents = quotesMessage
            ? "The report goes to the administrator of your server, \(domain), with \(name)’s address and a reference to this message. They can’t read encrypted messages."
            : "The report goes to the administrator of your server, \(domain), with \(name)’s address and the reason you pick."
        let handling = serverHandlesReports ? "" : " Your server doesn’t say it reviews reports, so it may only block them."
        return contents + handling + " \(name) is also blocked and isn’t told."
    }
}
