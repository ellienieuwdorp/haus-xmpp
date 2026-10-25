import Foundation

/// Whether a share sheet may write for its account, checked when it opens, again at Send and again before it connects:
/// a sheet left open (the Mac's popover, an iPhone sheet behind an app switch) must not queue or connect for an account
/// that signed out, was replaced by another, moved to another install or is being restored meanwhile. The holds are
/// the ones that keep the notification extension off the store.
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

    /// The signed-in account as saved now. `accountID` is the account the sheet opened for, nil while it opens; another
    /// account, or none, refuses. The fresh record carries the password saved now, for the connection.
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
