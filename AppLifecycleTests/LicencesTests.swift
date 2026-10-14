import XCTest
@testable import HausXMPP

/// Settings > About > Licences reads the repository's licence files from the app bundle. Every component that
/// THIRD_PARTY_LICENSES.md lists needs a row, and every row's text must be in the built app.
final class LicencesTests: XCTestCase {
    func testEveryRowsTextIsInTheApp() throws {
        for entry in LicenceEntry.all {
            for document in entry.documents() {
                let text = try XCTUnwrap(document.text, "\(entry.name): \(document.title ?? "section") is not in the app bundle")
                XCTAssertFalse(LicenceEntry.paragraphs(text).isEmpty, "\(entry.name) is empty")
            }
        }
    }

    func testEveryListedComponentHasARow() throws {
        let file = try XCTUnwrap(LicenceEntry.read(LicenceEntry.thirdPartyFile, in: .main))
        let shown = Set(LicenceEntry.all.flatMap { entry in
            [entry.name] + entry.sources.compactMap { if case let .thirdPartySection(heading) = $0 { heading } else { nil } }
        })
        let listed = LicenceEntry.headings(of: file)
        XCTAssertFalse(listed.isEmpty)
        for heading in listed { XCTAssertTrue(shown.contains(heading), "\(heading) has no row under Licences") }
    }
}
