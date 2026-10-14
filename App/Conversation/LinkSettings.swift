import Foundation
import Observation

/// The two link settings, kept per device rather than per account: they decide what this app does with links, need
/// no connection to change, and no extension reads them. The shared Settings screen is also the Mac's General pane.
@Observable @MainActor final class LinkSettings {
    static let shared = LinkSettings()

    static let fetchPreviewsKey = "linkPreviewsFetch"
    static let openInSafariKey = "openLinksInSafari"

    /// Privacy > Link previews: our own fetching, for links we type and links contacts send. Previews that arrive with
    /// a message show either way. On by default.
    var fetchPreviews: Bool { didSet { defaults.set(fetchPreviews, forKey: Self.fetchPreviewsKey) } }
    /// Open links in Safari: off opens web links in the in-app browser. iOS only; the Mac always uses the default browser.
    var openInSafari: Bool { didSet { defaults.set(openInSafari, forKey: Self.openInSafariKey) } }

    @ObservationIgnored private let defaults: UserDefaults

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        fetchPreviews = defaults.object(forKey: Self.fetchPreviewsKey) as? Bool ?? true
        openInSafari = defaults.object(forKey: Self.openInSafariKey) as? Bool ?? false
    }
}
