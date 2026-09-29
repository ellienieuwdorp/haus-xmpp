import Observation
import SwiftUI
import XCTest
@testable import HausXMPP

@MainActor
final class AppearanceStoreTests: XCTestCase {
    private var suiteName = ""
    private var defaults: UserDefaults!

    override func setUp() {
        super.setUp()
        suiteName = "AppearanceStoreTests.\(UUID().uuidString)"
        defaults = UserDefaults(suiteName: suiteName)
    }

    override func tearDown() {
        defaults.removePersistentDomain(forName: suiteName)
        defaults = nil
        super.tearDown()
    }

    func testReadsAndWritesTheExistingKeys() {
        defaults.set("rose", forKey: "accentTheme")
        defaults.set("dark", forKey: "appearanceMode")
        let store = AppearanceStore(defaults: defaults)
        XCTAssertEqual(store.accent, .rose, "a stored preference survives the move to the store")
        XCTAssertEqual(store.mode, "dark")
        XCTAssertEqual(store.interfaceStyle, .dark)

        store.accent = .crab
        store.mode = "light"
        XCTAssertEqual(defaults.string(forKey: "accentTheme"), "crab")
        XCTAssertEqual(defaults.string(forKey: "appearanceMode"), "light")
        XCTAssertEqual(AppearanceStore(defaults: defaults).accent, .crab, "the next launch reads the new choice")
    }

    func testUnknownStoredValuesFallBack() {
        defaults.set("plaid", forKey: "accentTheme")
        defaults.set("sepia", forKey: "appearanceMode")
        let store = AppearanceStore(defaults: defaults)
        XCTAssertEqual(store.accent, .indigo)
        XCTAssertEqual(store.mode, "automatic")
    }

    func testCurrentResolvesThroughTheSharedStore() {
        let shared = AppearanceStore.shared
        let original = shared.accent
        // The shared store writes to the standard defaults; put the raw key back as it was, absent included.
        let stored = UserDefaults.standard.object(forKey: AccentTheme.storageKey)
        defer {
            shared.accent = original
            if let stored { UserDefaults.standard.set(stored, forKey: AccentTheme.storageKey) }
            else { UserDefaults.standard.removeObject(forKey: AccentTheme.storageKey) }
        }
        shared.accent = .sky
        XCTAssertEqual(AccentTheme.current, .sky)
        let changed = Flag()
        withObservationTracking { _ = AccentTheme.current } onChange: { changed.set() }
        shared.accent = .graphite
        XCTAssertTrue(changed.value, "UIKit and SwiftUI call sites of AccentTheme.current are observed")
    }
}

/// `withObservationTracking` calls back synchronously on the mutating thread (main, here).
private final class Flag: @unchecked Sendable {
    private(set) var value = false
    func set() { value = true }
}
