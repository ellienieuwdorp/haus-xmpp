import Foundation

// Per-account state outside the store (whose tables are `AccountTable`), and what sign-out and a transfer do to it. A
// pre-upgrade copy takes both preference domains whole, `PreUpgradeSnapshot.folders`, the account record and the push
// registrations. AccountResourceTests checks the preferences and folders against the code that handles them.
enum AccountResource: CaseIterable {
    case lastAccount, signOutRowsOwed, pushOff, ownAvatar, groupNickname, serverFeatures, carbonsStream, uploadService, uploadServiceCheckedAt
    case blocklist, shareSuggestions, xmppResource
    case accountRecord, pushRegistration, wrappingKey
    case attachmentFolder, avatarFolder
    case deliveredNotifications, appBadge, donations

    enum Domain { case app, group }

    enum Location {
        // `key` spells the preference for an account; a per-room key is spelled for one example room.
        case preference([Domain], key: @Sendable (String) -> String)
        case keychain(service: String)
        case folder(String)
        case system
    }

    enum SignOut: Equatable {
        case delete
        case keep(reason: String)
    }

    enum Transfer: Equatable {
        case copy
        case omit(reason: String)
    }

    struct Policy {
        let location: Location
        let signOut: SignOut
        let transfer: Transfer
    }

    var policy: Policy {
        switch self {
        case .lastAccount: Policy(location: .preference([.app], key: { _ in "lastAccount" }), signOut: .delete, transfer: .copy)
        case .signOutRowsOwed:
            Policy(location: .preference([.app], key: { _ in SignOutCleanup.key }),
                   signOut: .keep(reason: "names the accounts whose rows sign-out still owes the store"), transfer: .copy)
        case .pushOff:
            Policy(location: .preference([.app], key: { "pushOff." + $0 }), signOut: .keep(reason: "the user's choice for the account"), transfer: .copy)
        case .ownAvatar:
            Policy(location: .preference([.app], key: { "avatar." + $0 }), signOut: .keep(reason: "names the own avatar file, which stays"), transfer: .copy)
        case .groupNickname:
            Policy(location: .preference([.app], key: { "groupNickname.\($0).room@conference.example.org" }),
                   signOut: .keep(reason: "the nickname each of the account's rooms knows it by"), transfer: .copy)
        case .serverFeatures: Policy(location: .preference([.app], key: { "serverFeatures." + $0 }), signOut: .delete, transfer: .copy)
        case .carbonsStream:
            Policy(location: .preference([.app], key: { "carbonsStream." + $0 }), signOut: .delete, transfer: .omit(reason: "names a stream of this install"))
        case .uploadService: Policy(location: .preference([.app, .group], key: { "uploadService." + $0 }), signOut: .delete, transfer: .copy)
        case .uploadServiceCheckedAt: Policy(location: .preference([.app], key: { "uploadServiceCheckedAt." + $0 }), signOut: .delete, transfer: .copy)
        case .blocklist: Policy(location: .preference([.group], key: { "blocklist." + $0 }), signOut: .delete, transfer: .copy)
        case .shareSuggestions: Policy(location: .preference([.group], key: { "shareSuggestions." + $0 }), signOut: .delete, transfer: .copy)
        case .xmppResource:
            Policy(location: .preference([.group], key: { "xmppResource." + $0 }),
                   signOut: .keep(reason: "a bind under it replaces the session the app or an extension left"), transfer: .omit(reason: "each install binds its own"))
        case .accountRecord: Policy(location: .keychain(service: NotificationAccount.service), signOut: .delete, transfer: .copy)
        case .pushRegistration:
            Policy(location: .keychain(service: PushRegistrationState.service),
                   signOut: .keep(reason: "saved turned off, so the gateway revokes it and the server disables it"), transfer: .copy)
        case .wrappingKey:
            Policy(location: .keychain(service: EncryptionKeychain.service), signOut: .keep(reason: "seals every account's encryption state"), transfer: .copy)
        case .attachmentFolder: Policy(location: .folder("attachments"), signOut: .keep(reason: "the kept history's files"), transfer: .copy)
        case .avatarFolder: Policy(location: .folder("avatars"), signOut: .keep(reason: "the kept chats' avatars"), transfer: .copy)
        case .deliveredNotifications, .appBadge, .donations:
            Policy(location: .system, signOut: .delete, transfer: .omit(reason: "the system's, on this device"))
        }
    }

    // Sign-out's share of the preferences, after the account was deselected.
    static func forgetPreferencesAtSignOut(of account: String, app: UserDefaults, group: UserDefaults?) {
        UploadServiceMemory(defaults: app, mirror: group).forget(account: account)
        ServerProfileMemory(defaults: app).forget(account: account)
        BlockedAddresses.forget(accountID: account, defaults: group)
        ShareSuggestionSetting.forget(accountID: account, defaults: group)
        app.removeObject(forKey: "lastAccount")
    }
}
