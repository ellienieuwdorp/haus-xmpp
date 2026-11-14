import XCTest
import MessagingCore
@testable import HausXMPP

// A temporary directory stands in for the App Group; the ring is counted instead of posted.
final class ExtensionGiveWayTests: XCTestCase {
    private final class Rings: @unchecked Sendable {
        // Guards `count`.
        private let lock = NSLock()
        private var value = 0
        var count: Int { lock.withLock { value } }
        func ring() { lock.withLock { value += 1 } }
    }

    private let start = Date(timeIntervalSince1970: 1_000_000)

    private func files() -> ExtensionGiveWay.Files {
        let url = FileManager.default.temporaryDirectory.appending(path: "give-way-\(UUID())", directoryHint: .isDirectory)
        addTeardownBlock { try? FileManager.default.removeItem(at: url) }
        return ExtensionGiveWay.Files(groupRoot: url)
    }

    // Busy attempts come every 250 ms; the request is rewritten and rung once per interval, under one nonce.
    func testAWaitingAppRefreshesOneRequestOncePerInterval() throws {
        let files = files(), rings = Rings()
        var ask = ExtensionGiveWay.Ask(files: files, ring: rings.ring)
        ask.leaseBusy(now: start)
        let first = try XCTUnwrap(files.request())
        XCTAssertEqual(first, ask.request)
        XCTAssertEqual(rings.count, 1)
        ask.leaseBusy(now: start.addingTimeInterval(0.25))
        ask.leaseBusy(now: start.addingTimeInterval(0.75))
        XCTAssertEqual(rings.count, 1)
        ask.leaseBusy(now: start.addingTimeInterval(GiveWayHandshake.refreshInterval))
        XCTAssertEqual(rings.count, 2)
        XCTAssertEqual(files.request(), GiveWayRequest(nonce: first.nonce, sentAt: start.addingTimeInterval(GiveWayHandshake.refreshInterval)))
        ask.leaseBusy(now: start)
        XCTAssertEqual(files.request()?.sentAt, start)
        XCTAssertEqual(rings.count, 3)
    }

    // The takeover answers the request, so the run after the one that gave way carries on.
    func testTheExtensionReadsTheAppsRequestAndItsTakeover() {
        let files = files()
        var ask = ExtensionGiveWay.Ask(files: files, ring: {})
        ask.leaseBusy(now: start)
        let channel = ExtensionGiveWay.Channel(files: files)
        let running = GiveWaySwitch(channel: channel, now: { [start] in start.addingTimeInterval(0.1) })
        running.check()
        XCTAssertEqual(running.request, ask.request)
        ask.leaseTaken(now: start.addingTimeInterval(0.5))
        XCTAssertEqual(channel.latestTakeover(), GiveWayTakeover(nonce: ask.request?.nonce ?? "", takenAt: start.addingTimeInterval(0.5)))
        let next = GiveWaySwitch(channel: channel, now: { [start] in start.addingTimeInterval(0.6) })
        next.check()
        XCTAssertNil(next.request)
    }

    // An app that never asked confirms nothing, and a withdraw never removes another wait's request.
    func testOnlyAnAskingAppConfirmsOrWithdraws() throws {
        let files = files()
        ExtensionGiveWay.Ask(files: files, ring: {}).leaseTaken(now: start)
        XCTAssertNil(files.takeover())
        var ask = ExtensionGiveWay.Ask(files: files, ring: {})
        ask.leaseBusy(now: start)
        ask.withdraw()
        XCTAssertNil(files.request())
        ask.leaseBusy(now: start.addingTimeInterval(5))
        let other = GiveWayRequest(nonce: "another wait", sentAt: start)
        try files.saveRequest(other)
        ask.withdraw()
        XCTAssertEqual(files.request(), other)
    }

    // Damaged, or too large to be a request.
    func testAnUnreadableRequestIsIgnored() throws {
        let files = files()
        try FileManager.default.createDirectory(at: files.directory, withIntermediateDirectories: true)
        try Data(repeating: 0x7B, count: GroupMailbox.maximumBytes + 1).write(to: files.directory.appending(path: "request.json"))
        XCTAssertNil(files.request())
        try Data("not json".utf8).write(to: files.directory.appending(path: "request.json"))
        XCTAssertNil(files.request())
        let giveWay = GiveWaySwitch(channel: ExtensionGiveWay.Channel(files: files), now: { [start] in start })
        giveWay.check()
        XCTAssertNil(giveWay.request)
    }
}
