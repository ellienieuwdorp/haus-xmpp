import XCTest
import XMPPProtocol
import MessageStore
@testable import HausXMPP

final class SessionStateTests: XCTestCase {
    func testReconnectDelayIsImmediateThenDoublesAndCapsAtAMinute() {
        XCTAssertEqual(ReconnectPolicy.delay(attempt: 0), .zero)
        for attempt in 1...12 {
            let expected = min(60.0, pow(2.0, Double(attempt - 1)))
            let delay = ReconnectPolicy.delay(attempt: attempt)
            let seconds = Double(delay.components.seconds) + Double(delay.components.attoseconds) / 1e18
            XCTAssertGreaterThanOrEqual(seconds, expected, "attempt \(attempt)")
            XCTAssertLessThanOrEqual(seconds, expected * 1.25 + 0.001, "attempt \(attempt)")
        }
    }

    /// A server that drops every stream right after login (a kick, a walk that fails the same way each time) used to be
    /// retried with no delay and alerted on every cycle, because `.ready` reset both. A quiet account settles its setup
    /// within a second, so a settled setup alone is not enough either.
    func testOnlyASettledSetupThatStayedUpForgivesEarlierFailures() {
        var policy = ReconnectPolicy()
        let start = ContinuousClock.now
        var delays: [Duration] = []
        for cycle in 0..<4 {
            delays.append(policy.nextDelay)
            policy.attemptStarted()
            let online = start + .seconds(cycle * 10)
            policy.online(at: online)
            for event in [ConnectionSetup.Event.step("carbons"), .ready, .catchingUp(nil), .settled] { policy.observe(event) }
            policy.ended(at: online + .seconds(1))
        }
        XCTAssertEqual(delays.first, .zero)
        XCTAssertGreaterThanOrEqual(delays[1], .seconds(1))
        XCTAssertGreaterThanOrEqual(delays[3], .seconds(4))
        XCTAssertTrue(policy.shouldAlert("malformedResponse"))
        XCTAssertFalse(policy.shouldAlert("malformedResponse"), "the same failure alerts once")
        XCTAssertTrue(policy.shouldAlert("timedOut"), "a different one is news")

        // Returning to the app retries at once, but the repeated failure stays quiet.
        policy.retryNow()
        XCTAssertEqual(policy.nextDelay, .zero)
        XCTAssertFalse(policy.shouldAlert("timedOut"))

        // A connection that stays up but never settles (a walk still running) forgives nothing.
        policy.attemptStarted()
        policy.online(at: start + .seconds(100))
        policy.ended(at: start + .seconds(300))
        XCTAssertGreaterThanOrEqual(policy.nextDelay, .seconds(1))

        // Settled and up for a minute: healthy, even while still connected when the next failure comes.
        policy.online(at: start + .seconds(400))
        policy.observe(.settled)
        XCTAssertTrue(policy.shouldAlert("timedOut", at: start + .seconds(400) + ReconnectPolicy.stableUptime), "the failure is new again")
        policy.ended(at: start + .seconds(500))
        XCTAssertEqual(policy.nextDelay, .zero)
    }

    func testOnlyRejectedCredentialsStopAutomaticReconnection() {
        XCTAssertTrue(AppModel.isAuthenticationFailure(XMPPClientError.authenticationFailed))
        XCTAssertTrue(AppModel.isAuthenticationFailure(XMPPClientError.authenticationUnavailable))
        XCTAssertTrue(AppModel.isAuthenticationFailure(XMPPClientError.authenticationDowngrade))
        // A server that cannot check the password right now is retried with backoff, not a password prompt.
        XCTAssertFalse(AppModel.isAuthenticationFailure(XMPPClientError.authenticationRetryable))
        XCTAssertFalse(AppModel.isAuthenticationFailure(XMPPClientError.encryptionUnavailable))
        XCTAssertFalse(AppModel.isAuthenticationFailure(XMPPClientError.timedOut))
        XCTAssertFalse(AppModel.isAuthenticationFailure(XMPPClientError.connectionClosed))
        XCTAssertFalse(AppModel.isAuthenticationFailure(MessageStoreError.transportOwnedElsewhere))
        XCTAssertFalse(AppModel.isAuthenticationFailure(CancellationError()))
    }
}
