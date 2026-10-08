import MessageStore

/// One place for the words; the bubble, the chat list and VoiceOver read the same ones.
enum UnreadableCopy {
    static func bubble(_ reason: UnreadableReason, isOutgoing: Bool) -> String {
        switch reason {
        case .notForThisDevice: isOutgoing ? "Sent from another device and not encrypted for this iPhone" : "Not encrypted for this iPhone"
        case .unsupportedEncryption, .malformedContent, .decryptFailed: "Couldn't read this message"
        case .rejectedDevice: isOutgoing ? "Sent from a device you blocked" : "From a device you blocked"
        case .retentionLimit: "Not kept: too many messages waiting for review"
        }
    }
    static func preview(_ reason: UnreadableReason) -> String {
        switch reason {
        case .notForThisDevice: "Not encrypted for this iPhone"
        case .unsupportedEncryption, .malformedContent, .decryptFailed: "Couldn't read this message"
        case .rejectedDevice: "From a device you blocked"
        case .retentionLimit: "Not kept: too many messages waiting"
        }
    }
}

/// Why a server returned a message (`StoredMessage.rejection`), in our words: the error's own text is written by
/// whoever bounced it and is never shown. The alert, the retry dialog and VoiceOver read the same sentence.
enum RejectionCopy {
    static func reason(_ rejection: String, isGroup: Bool) -> String {
        switch rejection {
        case "blocked": "You blocked this contact."
        case "item-not-found", "service-unavailable", "gone", "jid-malformed", "registration-required", "subscription-required":
            isGroup ? "The group isn't available." : "This address doesn't exist or isn't accepting messages."
        case "remote-server-not-found": "Their server couldn't be found."
        case "remote-server-timeout": "Their server didn't answer."
        case "not-acceptable", "not-allowed": isGroup ? "You weren't in the group when it was sent." : "Their server refused it."
        case "forbidden", "not-authorized": isGroup ? "You aren't allowed to send to this group." : "Their server refused it."
        case "policy-violation": "A server refused it under its rules."
        case "resource-constraint", "internal-server-error": "A server couldn't handle it right now."
        default: "A server returned it."
        }
    }
}
