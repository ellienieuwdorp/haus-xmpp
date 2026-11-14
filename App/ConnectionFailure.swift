import Foundation
import MessageStore
import XMPPProtocol

extension AppModel {
    // UI test sessions never touch the Keychain, so they sign in without FAST.
    func signInConfiguration(_ account: String, carbons: Bool) -> XMPPSASL2Configuration {
        SharedSession.sasl2(accountID: account, carbons: carbons, tokens: testSessionID == nil ? FastTokenKeychain() : nil, defaults: sessionDefaults)
    }

    // After the sign-out's quiesce: a sign-in that was in flight saved nothing once the tombstone stood; this covers one
    // that saved just before it.
    func forgetFastToken(of account: String) -> String? {
        guard testSessionID == nil, (try? FastTokenKeychain.remove(account: account)) == nil else { return nil }
        return "Background credentials could not be safely removed. Please retry signing out."
    }

    nonisolated static func isAuthenticationFailure(_ error: any Error) -> Bool {
        switch error as? XMPPClientError {
        case .authenticationFailed, .authenticationUnavailable, .authenticationDowngrade: true
        default: false
        }
    }

    nonisolated static func failureMessage(for error: any Error) -> String {
        switch error {
        case XMPPClientError.authenticationFailed: "The password was not accepted."
        case XMPPClientError.authenticationUnavailable: "The server does not offer a sign-in method this app supports."
        case XMPPClientError.authenticationDowngrade:
            "The server no longer offers the secure sign-in this account used before, so the password was not sent. "
                + "Sign out and in again only if the server’s operator made this change."
        case XMPPClientError.authenticationRetryable: "The server could not check the password right now."
        case XMPPClientError.encryptionUnavailable: "The server did not offer an encrypted connection."
        case XMPPClientError.serviceNotOffered: "This domain does not offer XMPP service."
        case XMPPClientError.unexpectedProtocol: "The server sent a reply this app cannot accept."
        case XMPPClientError.timedOut: "The server did not respond."
        case MessageStoreError.transportOwnedElsewhere:
            "Another process is still using this account’s storage. Try again in a moment."
        case is SignOutCleanup.Owed: "Couldn’t finish signing out this account. Try again."
        case is CancellationError: "Connection cancelled."
        case XMPPIdentityError.boundAccountMismatch: "The server signed in a different account than the one entered."
        default: "Could not reach the server."
        }
    }
}
