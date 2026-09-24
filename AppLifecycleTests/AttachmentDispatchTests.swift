import XCTest
@testable import XMPPiOS

@MainActor final class AttachmentDispatchTests: XCTestCase {
    func testFilesGoOneByOneThenTheCaptionLast() async {
        var sent: [String] = []
        let result = await ComposerState.dispatch(["a.jpg", "b.jpg"], caption: "Look",
                                                  sendFile: { sent.append($0); return true },
                                                  sendCaption: { sent.append("caption: " + $0); return true })
        XCTAssertEqual(sent, ["a.jpg", "b.jpg", "caption: Look"])
        XCTAssertEqual(result.files, 2)
        XCTAssertTrue(result.caption)
    }

    func testTheFirstRefusalStopsEverythingAfterIt() async {
        var sent: [String] = []
        let result = await ComposerState.dispatch(["a.jpg", "b.jpg", "c.jpg"], caption: "Look",
                                                  sendFile: { file in guard file != "b.jpg" else { return false }; sent.append(file); return true },
                                                  sendCaption: { sent.append($0); return true })
        XCTAssertEqual(sent, ["a.jpg"])
        XCTAssertEqual(result.files, 1)
        XCTAssertFalse(result.caption)
    }

    func testABlankCaptionIsNotSent() async {
        var captions = 0
        let result = await ComposerState.dispatch(["a.jpg"], caption: " \n", sendFile: { _ in true }, sendCaption: { _ in captions += 1; return true })
        XCTAssertEqual(captions, 0)
        XCTAssertEqual(result.files, 1)
        XCTAssertFalse(result.caption)
    }

    func testAnUploadGivesUpAfterItsBudgetAndARetryStartsOver() {
        var budget = UploadFailureBudget()
        for _ in 1..<UploadFailureBudget.limit { XCTAssertFalse(budget.recordFailure("photo")) }
        XCTAssertFalse(budget.recordFailure("other"), "Each file has its own budget")
        XCTAssertTrue(budget.recordFailure("photo"))
        XCTAssertFalse(budget.recordFailure("photo"), "A retried file gets fresh tries")
        budget.reset("other")
        for _ in 1..<UploadFailureBudget.limit { XCTAssertFalse(budget.recordFailure("other")) }
    }
}
