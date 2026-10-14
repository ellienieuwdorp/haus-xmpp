import Foundation

/// A link found in message text.
public struct DetectedLink: Sendable, Equatable {
    public enum Kind: String, Sendable, Equatable {
        /// http or https. A bare domain (`example.org`) is a web link opened as https.
        case web
        /// `xmpp:` (XEP-0147): a chat or a group to open in the app.
        case xmpp
        /// `mailto:`, also for a bare email address.
        case mail
        /// `tel:`, also for a phone number written in the text.
        case phone
        /// `geo:` (RFC 5870), which the system detector does not find.
        case geo
    }

    public let kind: Kind
    /// UTF-16 range of `text` in the scanned string, as `NSAttributedString` and `UITextView` count.
    public let range: NSRange
    /// What the link opens. A bare domain is already `https://…`, a phone number `tel:+…`.
    public let url: URL
    /// The characters as written.
    public let text: String

    public init(kind: Kind, range: NSRange, url: URL, text: String) {
        self.kind = kind; self.range = range; self.url = url; self.text = text
    }
}

/// Link detection and the preview exclusions, shared by the bubble (CX-8), the composer, the XEP-0511 encoder and the
/// receive validator, so all of them agree on which characters are a link and which links may carry a preview.
public enum LinkDetection {
    /// Every link in `text`, in order: web links, `xmpp:`, `mailto:` and bare email addresses, `tel:` and phone numbers,
    /// and `geo:`. Never returned: other schemes (`aesgcm:` among them, which only the attachment decoder reads),
    /// key-bearing attachment URLs (an https URL whose fragment is 88 or 96 hex digits), and web URLs with a user name
    /// or password or without a host.
    public static func links(in text: String) -> [DetectedLink] {
        let whole = NSRange(location: 0, length: (text as NSString).length)
        let places = geoLinks(in: text, range: whole)
        var found = places
        for match in detector.matches(in: text, range: whole) {
            guard !places.contains(where: { NSIntersectionRange($0.range, match.range).length > 0 }),
                  let written = Range(match.range, in: text).map({ String(text[$0]) }) else { continue }
            if match.resultType == .phoneNumber {
                if let number = match.phoneNumber, let url = telephoneURL(number) {
                    found.append(DetectedLink(kind: .phone, range: match.range, url: url, text: written))
                }
            } else if let url = match.url, let link = classify(url, written: written, range: match.range) {
                found.append(link)
            }
        }
        return found.sorted { $0.range.location < $1.range.location }
    }

    /// The links of `text` that may carry a preview, in order and without repeats: web links only, never one that is
    /// only on a quoted line (starting with `>`), longer than 2,048 UTF-8 bytes, equal to one of `fileURLs` (the
    /// message's own file link, its legacy `aesgcm://` form or a stored attachment URL; compared without fragment), or
    /// on one of `uploadHosts` (the GET hosts of our upload slots). `text` is the body after the reply quote.
    /// http links are listed (a sender may describe one) but never fetched: see `isFetchable`.
    public static func previewableURLs(in text: String, fileURLs: [String] = [], uploadHosts: Set<String> = []) -> [URL] {
        let files = Set(fileURLs.compactMap { URL(string: $0).flatMap(withoutFragment) })
        let hosts = Set(uploadHosts.map { $0.lowercased() })
        let quoted = quotedLineRanges(in: text)
        var seen = Set<String>()
        return links(in: text).compactMap { link in
            guard link.kind == .web, link.url.absoluteString.utf8.count <= 2_048,
                  !quoted.contains(where: { NSLocationInRange(link.range.location, $0) }),
                  let host = link.url.host()?.lowercased(), !hosts.contains(host),
                  let comparable = withoutFragment(link.url), !files.contains(comparable),
                  seen.insert(link.url.absoluteString).inserted else { return nil }
            return link.url
        }
    }

    /// Whether our own fetcher may request `url`: https on the default port. Every other check (resolved addresses,
    /// redirects, sizes) belongs to the fetcher.
    public static func isFetchable(_ url: URL) -> Bool {
        url.scheme?.lowercased() == "https" && (url.port == nil || url.port == 443) && url.host()?.isEmpty == false && url.user() == nil
    }

    /// The key for the fetch cache and for coalescing fetches: scheme and host lowercased, the default port and the
    /// fragment dropped, path and query as written.
    public static func cacheKey(for url: URL) -> String {
        guard var parts = URLComponents(url: url, resolvingAgainstBaseURL: false) else { return url.absoluteString }
        parts.scheme = parts.scheme?.lowercased()
        parts.percentEncodedHost = parts.percentEncodedHost?.lowercased()
        if (parts.scheme == "https" && parts.port == 443) || (parts.scheme == "http" && parts.port == 80) { parts.port = nil }
        parts.fragment = nil
        return parts.string ?? url.absoluteString
    }

    /// The host a card shows for `url`: lowercased, a leading `www.` dropped, international names in their ASCII
    /// (punycode) form as the detector produces them. Never taken from page metadata.
    public static func displayHost(for url: URL) -> String? {
        guard let host = url.host()?.lowercased(), !host.isEmpty else { return nil }
        return host.hasPrefix("www.") && host.count > 4 ? String(host.dropFirst(4)) : host
    }

    // MARK: Detection

    // NSDataDetector, like NSRegularExpression, is immutable once made and Sendable.
    private static let detector = try! NSDataDetector(
        types: NSTextCheckingResult.CheckingType.link.rawValue | NSTextCheckingResult.CheckingType.phoneNumber.rawValue)

    /// RFC 5870 `geo:` with latitude, longitude, an optional altitude and `;name=value` parameters (`crs`, `u`).
    private static let geoPattern = try! NSRegularExpression(
        pattern: #"(?<![\p{L}\p{N}])geo:(-?\d{1,2}(?:\.\d+)?),(-?\d{1,3}(?:\.\d+)?)(?:,-?\d+(?:\.\d+)?)?(?:;[A-Za-z0-9-]+=[A-Za-z0-9-]+(?:\.[A-Za-z0-9-]+)*)*"#,
        options: [.caseInsensitive])

    private static func geoLinks(in text: String, range: NSRange) -> [DetectedLink] {
        let string = text as NSString
        return geoPattern.matches(in: text, range: range).compactMap { match in
            guard let latitude = Double(string.substring(with: match.range(at: 1))), abs(latitude) <= 90,
                  let longitude = Double(string.substring(with: match.range(at: 2))), abs(longitude) <= 180 else { return nil }
            let written = string.substring(with: match.range)
            guard let url = URL(string: "geo:" + written.dropFirst(4)) else { return nil }
            return DetectedLink(kind: .geo, range: match.range, url: url, text: written)
        }
    }

    private static func classify(_ url: URL, written: String, range: NSRange) -> DetectedLink? {
        switch url.scheme?.lowercased() {
        case "http", "https":
            guard url.host()?.isEmpty == false, url.user() == nil, url.password() == nil, !isKeyBearing(url) else { return nil }
            // The detector turns a bare domain into http://; with no scheme written, open it as https.
            let hasScheme = written.range(of: "^https?://", options: [.regularExpression, .caseInsensitive]) != nil
            guard !hasScheme, var parts = URLComponents(url: url, resolvingAgainstBaseURL: false) else {
                return DetectedLink(kind: .web, range: range, url: url, text: written)
            }
            parts.scheme = "https"
            return parts.url.map { DetectedLink(kind: .web, range: range, url: $0, text: written) }
        case "xmpp": return DetectedLink(kind: .xmpp, range: range, url: url, text: written)
        case "mailto": return DetectedLink(kind: .mail, range: range, url: url, text: written)
        case "tel": return DetectedLink(kind: .phone, range: range, url: url, text: written)
        default: return nil
        }
    }

    /// `tel:` with the digits of a written number, keeping a leading `+`.
    private static func telephoneURL(_ number: String) -> URL? {
        let digits = number.filter(\.isASCII).filter(\.isNumber)
        guard digits.count >= 3 else { return nil }
        let plus = number.trimmingCharacters(in: .whitespaces).hasPrefix("+") ? "+" : ""
        return URL(string: "tel:" + plus + digits)
    }

    /// An attachment link with its IV and key in the fragment (XEP-0454 form over https, as Conversations sends it).
    private static func isKeyBearing(_ url: URL) -> Bool {
        guard let fragment = url.fragment(percentEncoded: false), fragment.count == 88 || fragment.count == 96 else { return false }
        return fragment.allSatisfy(\.isHexDigit)
    }

    /// `url` as https without its fragment, so an `aesgcm://` file link and its https form compare equal.
    private static func withoutFragment(_ url: URL) -> String? {
        guard var parts = URLComponents(url: url, resolvingAgainstBaseURL: false) else { return nil }
        if parts.scheme?.lowercased() == "aesgcm" || parts.scheme?.lowercased() == "http" { parts.scheme = "https" }
        parts.scheme = parts.scheme?.lowercased()
        parts.percentEncodedHost = parts.percentEncodedHost?.lowercased()
        parts.fragment = nil
        return parts.string
    }

    /// UTF-16 ranges of lines that start with `>`, the quote form legacy bodies carry.
    private static func quotedLineRanges(in text: String) -> [NSRange] {
        let string = text as NSString
        var ranges: [NSRange] = []
        string.enumerateSubstrings(in: NSRange(location: 0, length: string.length), options: [.byLines, .substringNotRequired]) { _, line, _, _ in
            if string.substring(with: line).hasPrefix(">") { ranges.append(line) }
        }
        return ranges
    }
}
