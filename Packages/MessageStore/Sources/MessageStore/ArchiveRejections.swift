import Foundation

extension MessageStore {
    // Raw values of every protocol `XMPPArchiveRejection` case; `recordArchiveRejection` stores no other.
    static let archiveRejectionReasons: Set<String> = [
        "unverifiableEncryptedGroup", "foreignSender", "unsupportedDirectContent", "malformedEncryptedContent", "oversizedContent"
    ]
}
