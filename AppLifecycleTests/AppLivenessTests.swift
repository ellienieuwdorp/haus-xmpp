import XCTest
import MessagingCore
@testable import HausXMPP

/// The liveness handshake's files and the app's responder, in a temporary directory instead of the App Group.
@MainActor final class AppLivenessTests: XCTestCase {
    private static let live = LivenessConditions(wantsConnection: true, quiescing: false, ownsLease: true, servesExtensionAccount: true)

    private func files() -> AppLiveness.Files {
        let url = FileManager.default.temporaryDirectory.appending(path: "liveness-\(UUID())", directoryHint: .isDirectory)
        addTeardownBlock { try? FileManager.default.removeItem(at: url) }
        return AppLiveness.Files(groupRoot: url)
    }

    /// The extension asks, a live app answers with the request's nonce, and the extension's channel reads it back.
    func testALiveAppAnswersWhatTheExtensionAsked() throws {
        let files = files()
        var promises = 0
        let responder = AppLiveness.Responder(files: files, conditions: { Self.live }, answered: { promises += 1 })
        let channel = AppLiveness.ExtensionChannel(files: files)
        let request = LivenessRequest()
        try channel.ask(request)
        let answer = try XCTUnwrap(responder.ring())
        XCTAssertEqual(answer.nonce, request.nonce)
        XCTAssertEqual(channel.latestAnswer(), answer)
        XCTAssertTrue(LivenessHandshake.accepts(channel.latestAnswer(), to: request))
        XCTAssertEqual(promises, 1)
        // Anyone may ring again: the same request is not answered twice, and the app does not start over.
        XCTAssertNil(responder.ring())
        XCTAssertEqual(promises, 1)
    }

    /// A quiescing app (going to the background or to sleep) writes nothing and promises nothing.
    func testAQuiescingAppStaysSilent() throws {
        let files = files()
        var promises = 0
        var conditions = Self.live
        conditions.quiescing = true
        let responder = AppLiveness.Responder(files: files, conditions: { conditions }, answered: { promises += 1 })
        try files.saveRequest(LivenessRequest())
        XCTAssertNil(responder.ring())
        XCTAssertNil(files.answer())
        XCTAssertEqual(promises, 0)
    }

    /// A ring with no request, or with one older than the extension still listens for, is not answered.
    func testOnlyAFreshRequestIsAnswered() throws {
        let files = files()
        let responder = AppLiveness.Responder(files: files, conditions: { Self.live }, answered: {})
        XCTAssertNil(responder.ring())
        try files.saveRequest(LivenessRequest(sentAt: Date().addingTimeInterval(-5)))
        XCTAssertNil(responder.ring())
        XCTAssertNil(files.answer())
    }

    /// A file that is not a request (damaged, or too large to be one) is ignored.
    func testAnUnreadableRequestIsIgnored() throws {
        let files = files()
        try FileManager.default.createDirectory(at: files.directory, withIntermediateDirectories: true)
        try Data(repeating: 0x7B, count: AppLiveness.Files.maximumBytes + 1).write(to: files.directory.appending(path: "request.json"))
        XCTAssertNil(files.request())
        try Data("not json".utf8).write(to: files.directory.appending(path: "request.json"))
        XCTAssertNil(files.request())
    }
}
