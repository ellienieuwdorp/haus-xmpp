import Foundation
import Observation

// Per device, not per account: changing them needs no connection and no extension reads them.
@Observable @MainActor final class LinkSettings {
    static let shared = LinkSettings()

    static let fetchPreviewsKey = "linkPreviewsFetch"
    static let openInSafariKey = "openLinksInSafari"

    var fetchPreviews: Bool { didSet { defaults.set(fetchPreviews, forKey: Self.fetchPreviewsKey) } }
    var openInSafari: Bool { didSet { defaults.set(openInSafari, forKey: Self.openInSafariKey) } }

    @ObservationIgnored private let defaults: UserDefaults

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        fetchPreviews = defaults.object(forKey: Self.fetchPreviewsKey) as? Bool ?? true
        openInSafari = defaults.object(forKey: Self.openInSafariKey) as? Bool ?? false
    }
}
