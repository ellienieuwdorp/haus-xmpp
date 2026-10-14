import Foundation
import XMPPProtocol

/// Where a link in a message goes when it is opened. The decision is shared; the iPhone timeline and the Mac bubble
/// each perform it.
enum LinkDestination: Equatable, Sendable {
    /// A web page, in the app's browser or the system's default one.
    case web(URL, inApp: Bool)
    /// A phone number: the platform offers Call, Message and Copy.
    case phone(number: String, call: URL, message: URL)
    /// A new mail to `address`; when no mail app takes it, the address is copied instead.
    case mail(URL, address: String)
    /// Open, or start, the direct chat with this bare address.
    case chat(String)
    /// An invitation to the group at this bare address (`?join`): open it when already joined, else the join flow
    /// with the address filled in; copy it where there is no join flow.
    case group(String)
    /// Apple Maps at the place.
    case map(URL)
    /// Nothing the app opens. Copying is all there is.
    case unsupported
}

enum LinkOpening {
    /// `inAppBrowser`: web pages open in the in-app browser (iOS with "Open links in Safari" off). The Mac passes false.
    static func destination(for url: URL, inAppBrowser: Bool) -> LinkDestination {
        switch url.scheme?.lowercased() {
        case "http", "https":
            return url.host()?.isEmpty == false ? .web(url, inApp: inAppBrowser) : .unsupported
        case "tel":
            let number = String(opaque(url).prefix { $0 != ";" })
            guard number.contains(where: \.isNumber), let call = URL(string: "tel:" + number),
                  let message = URL(string: "sms:" + number) else { return .unsupported }
            return .phone(number: number, call: call, message: message)
        case "mailto":
            let address = String(opaque(url).prefix { $0 != "?" })
            return address.isEmpty ? .unsupported : .mail(url, address: address)
        case "xmpp":
            return xmpp(url)
        case "geo":
            return map(url).map(LinkDestination.map) ?? .unsupported
        default:
            return .unsupported
        }
    }

    /// What Copy puts on the pasteboard: the address alone for mail and xmpp links, the number for a phone link, the
    /// link as detected otherwise.
    static func copyText(for url: URL) -> String {
        switch destination(for: url, inAppBrowser: false) {
        case .phone(let number, _, _): number
        case .mail(_, let address): address
        case .chat(let address), .group(let address): address
        default: url.absoluteString
        }
    }

    /// The part after `scheme:`, percent-decoded.
    private static func opaque(_ url: URL) -> String {
        let text = url.absoluteString
        guard let colon = text.firstIndex(of: ":") else { return "" }
        let rest = String(text[text.index(after: colon)...])
        return rest.removingPercentEncoding ?? rest
    }

    /// XEP-0147: `xmpp:romeo@montague.lit?message`, `xmpp:room@conference.example.org?join`, and the rare
    /// `xmpp://authority/address` form. Only an address with a local part is a chat; a bare server is not.
    private static func xmpp(_ url: URL) -> LinkDestination {
        var rest = Substring(url.absoluteString.dropFirst("xmpp:".count))
        if rest.hasPrefix("//") {
            rest = rest.dropFirst(2)
            guard let slash = rest.firstIndex(of: "/") else { return .unsupported }
            rest = rest[rest.index(after: slash)...]
        }
        let parts = rest.split(separator: "?", maxSplits: 1, omittingEmptySubsequences: false)
        let path = parts.first.map(String.init) ?? ""
        let action = parts.count > 1 ? parts[1].prefix { $0 != ";" }.lowercased() : ""
        guard let jid = JID(path.removingPercentEncoding ?? path), jid.localpart != nil else { return .unsupported }
        return action == "join" ? .group(jid.bare) : .chat(jid.bare)
    }

    /// RFC 5870 `geo:lat,lon[,alt][;params]` as an Apple Maps link marking that place.
    private static func map(_ url: URL) -> URL? {
        let coordinates = opaque(url).prefix { $0 != ";" }.split(separator: ",")
        guard coordinates.count >= 2, let latitude = Double(coordinates[0]), let longitude = Double(coordinates[1]),
              abs(latitude) <= 90, abs(longitude) <= 180 else { return nil }
        var parts = URLComponents(string: "https://maps.apple.com/")
        let place = "\(coordinates[0]),\(coordinates[1])"
        parts?.queryItems = [URLQueryItem(name: "ll", value: place), URLQueryItem(name: "q", value: place)]
        return parts?.url
    }
}
