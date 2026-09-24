import Observation
import SwiftUI
import XCTest
@testable import XMPPiOS

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

    func testDefaultsToIndigoAndAutomatic() {
        let store = AppearanceStore(defaults: defaults)
        XCTAssertEqual(store.accent, .indigo)
        XCTAssertEqual(store.mode, "automatic")
        XCTAssertNil(store.colorScheme)
        XCTAssertEqual(store.interfaceStyle, .unspecified)
    }

    func testReadsAndWritesTheExistingKeys() {
        defaults.set("rose", forKey: "accentTheme")
        defaults.set("dark", forKey: "appearanceMode")
        let store = AppearanceStore(defaults: defaults)
        XCTAssertEqual(store.accent, .rose, "a stored preference survives the move to the store")
        XCTAssertEqual(store.mode, "dark")

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

    func testModeMapsToSchemeAndWindowStyle() {
        let store = AppearanceStore(defaults: defaults)
        store.mode = "light"
        XCTAssertEqual(store.colorScheme, .light)
        XCTAssertEqual(store.interfaceStyle, .light)
        store.mode = "dark"
        XCTAssertEqual(store.colorScheme, .dark)
        XCTAssertEqual(store.interfaceStyle, .dark)
        store.mode = "automatic"
        XCTAssertNil(store.colorScheme)
        XCTAssertEqual(store.interfaceStyle, .unspecified)
    }

    func testChangesAreObservable() {
        let store = AppearanceStore(defaults: defaults)
        let accentChanged = Flag()
        withObservationTracking { _ = store.accent } onChange: { accentChanged.set() }
        store.accent = .lime
        XCTAssertTrue(accentChanged.value, "a view that read the accent is invalidated")

        let modeChanged = Flag()
        withObservationTracking { _ = store.interfaceStyle } onChange: { modeChanged.set() }
        store.mode = "dark"
        XCTAssertTrue(modeChanged.value, "a view that read the derived style is invalidated")
    }

    func testCurrentResolvesThroughTheSharedStore() {
        let shared = AppearanceStore.shared
        let original = shared.accent
        defer { shared.accent = original }
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
