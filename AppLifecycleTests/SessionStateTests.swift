import XCTest
import XMPPProtocol
import MessageStore
@testable import HausXMPP

final class SessionStateTests: XCTestCase {
    func testReconnectDelayIsImmediateThenDoublesAndCapsAtAMinute() {
        XCTAssertEqual(AppModel.reconnectDelay(attempt: 0), .zero)
        for attempt in 1...12 {
            let expected = min(60.0, pow(2.0, Double(attempt - 1)))
            let seconds = Double(AppModel.reconnectDelay(attempt: attempt).components.seconds)
                + Double(AppModel.reconnectDelay(attempt: attempt).components.attoseconds) / 1e18
            XCTAssertGreaterThanOrEqual(seconds, expected, "attempt \(attempt)")
            XCTAssertLessThanOrEqual(seconds, expected * 1.25 + 0.001, "attempt \(attempt)")
        }
    }

    func testOnlyRejectedCredentialsStopAutomaticReconnection() {
        XCTAssertTrue(AppModel.isAuthenticationFailure(XMPPClientError.authenticationFailed))
        XCTAssertTrue(AppModel.isAuthenticationFailure(XMPPClientError.authenticationUnavailable))
        XCTAssertFalse(AppModel.isAuthenticationFailure(XMPPClientError.timedOut))
        XCTAssertFalse(AppModel.isAuthenticationFailure(XMPPClientError.connectionClosed))
        XCTAssertFalse(AppModel.isAuthenticationFailure(MessageStoreError.transportOwnedElsewhere))
        XCTAssertFalse(AppModel.isAuthenticationFailure(CancellationError()))
    }

    func testFailureMessagesNameTheRealCause() {
        XCTAssertEqual(AppModel.failureMessage(for: XMPPClientError.authenticationFailed), "The password was not accepted.")
        XCTAssertEqual(AppModel.failureMessage(for: MessageStoreError.transportOwnedElsewhere),
                       "Another process is still using this account’s storage. Try again in a moment.")
        XCTAssertEqual(AppModel.failureMessage(for: XMPPClientError.timedOut), "The server did not respond.")
        XCTAssertEqual(AppModel.failureMessage(for: URLError(.cannotConnectToHost)), "Could not reach the server.")
    }

    func testOnlyOfflineAndNeedsAttentionAreConnectable() {
        XCTAssertTrue(SessionState.offline(reason: nil).isConnectable)
        XCTAssertTrue(SessionState.needsAttention(step: "carbons", detail: "x").isConnectable)
        XCTAssertFalse(SessionState.connecting(step: "Connecting…").isConnectable)
        XCTAssertFalse(SessionState.connected(settingUp: "server features").isConnectable)
        XCTAssertFalse(SessionState.ready.isConnectable)
        XCTAssertTrue(SessionState.connected(settingUp: "x").isConnected)
        XCTAssertFalse(SessionState.connected(settingUp: "x").isReady)
    }
}
