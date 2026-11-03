import Foundation

// Checked at open, at Send and before connecting: a sheet left open must not queue or connect for an account that
// signed out, was replaced, moved to another install or is being restored.
enum ShareAuthorization {
    enum Refusal: Error, Equatable {
        case restoring, moved, signedOut, signedOutSinceOpening, unreadable

        var message: String {
            switch self {
            case .restoring: "Open Haus XMPP to finish restoring your data, then share again."
            case .moved: "This account moved to another \(ThisDevice.noun). Share from there."
            case .signedOut: "Sign in to Haus XMPP to share."
            case .signedOutSinceOpening: "This account was signed out of Haus XMPP, so nothing was shared."
            case .unreadable: "Haus XMPP's messages can't be opened right now. Unlock your \(ThisDevice.noun) or open the app, then try again."
            }
        }
    }

    static func check(groupRoot: URL, accountID: String? = nil,
                      load: () throws -> NotificationAccount? = NotificationAccount.load) -> Result<NotificationAccount, Refusal> {
        if PreUpgradeHold.isHeld(groupRoot: groupRoot) { return .failure(.restoring) }
        if TransferHold.isMoved(groupRoot: groupRoot) { return .failure(.moved) }
        let account: NotificationAccount?
        do { account = try load() } catch { return .failure(.unreadable) }
        guard let account else { return .failure(accountID == nil ? .signedOut : .signedOutSinceOpening) }
        if let accountID, account.accountID != accountID { return .failure(.signedOutSinceOpening) }
        return .success(account)
    }
}
