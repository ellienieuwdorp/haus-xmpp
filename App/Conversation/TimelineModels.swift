import Foundation
import MessageStore
import XMPPProtocol

// The values one timeline row shows. The iPhone's collection view and a Mac timeline draw the same ones, so nothing
// here may import UIKit or AppKit.

/// The app's name for a message as the store keeps it.
typealias ChatMessage = StoredMessage

struct TimelineReply: Sendable, Equatable {
    let author: String
    let body: String
    /// The quoted photo or video on disk, shown as a small still at the quote's trailing edge; nil shows the text alone.
    var thumbnail: TimelineAttachment? = nil
    /// The quoted message as the reply names it, for jumping to it from the quote: its local ID for a reply sent from
    /// here, the ID its sender saw for a received one. The store resolves either (`AppModel.quotedMessageID`).
    var messageID: String? = nil
    /// Side of that still, in the bubble and in the composer's reply strip.
    static let thumbnailSide: CGFloat = 36
}

struct TimelineReaction: Sendable, Equatable {
    let emoji: String
    let count: Int
    let isSelected: Bool

    static let choices = ["❤️", "👍", "😂", "😮", "😢", "🙏"]
    static func name(for emoji: String) -> String {
        switch emoji {
        case "❤️": "heart"
        case "👍": "thumbs up"
        case "😂": "tears of joy"
        case "😮": "surprised"
        case "😢": "sad"
        case "🙏": "folded hands"
        default: emoji
        }
    }
    var accessibilityDescription: String {
        "\(count) \(Self.name(for: emoji)) \(count == 1 ? "reaction" : "reactions")" + (isSelected ? ", including you" : "")
    }
}

struct TimelineAttachment: Sendable, Equatable {
    let name: String
    let mediaType: String
    let size: Int
    let width: Int?
    let height: Int?
    /// Plaintext on disk once sent or downloaded and verified; nil until then.
    var localURL: URL? = nil
    /// Where a file that is not on disk stands; ignored once `localURL` is set.
    var download: AttachmentDownloadState = .loading
    var isImage: Bool { mediaType.hasPrefix("image/") }
    var isVideo: Bool { mediaType.hasPrefix("video/") }
    var showsPreview: Bool { isImage || isVideo }
    var aspectRatio: CGFloat {
        guard let width, let height, width > 0, height > 0 else { return 4 / 3 }
        return CGFloat(width) / CGFloat(height)
    }
    var kindLabel: String { isImage ? "Photo" : isVideo ? "Video" : "File" }
    /// What a file that is not on disk shows under its name, or under its symbol in a preview.
    var downloadDetail: String {
        let size = self.size > 0 ? ByteCountFormatter.string(fromByteCount: Int64(self.size), countStyle: .file) : nil
        let parts: [String?] = switch download {
        case .loading: [size, "Downloading…"]
        case .tapToDownload: [size, "Tap to download"]
        // Short enough for the file card's one detail line.
        case .failed: ["Failed", "Tap to retry"]
        case .mismatch: ["Doesn’t match its message"]
        case .tooLarge: [size, "Too large to download"]
        }
        return parts.compactMap { $0 }.joined(separator: " · ")
    }
    var downloadAccessibility: String {
        switch download {
        case .loading: "downloading"
        case .tapToDownload: "not downloaded"
        case .failed: "could not be downloaded"
        case .mismatch: "does not match its message, not downloaded"
        case .tooLarge: "too large to download"
        }
    }
}

struct TimelineMessage: Identifiable, Sendable, Equatable {
    let id: String
    let body: String
    let isOutgoing: Bool
    let isStarred: Bool
    var attachment: TimelineAttachment? = nil
    /// The card above the text: the sender's or our own sent preview, else our fetch for the first previewable link.
    var linkPreview: TimelineLinkPreview? = nil
    /// The first previewable link has no card yet: the bubble asks the model for one when it comes on screen.
    var wantsLinkPreview = false
    var sentAt: Date? = nil
    var status: Status? = nil
    /// Why a server returned this message (`RejectionCopy`); set only while it shows as failed.
    var failure: String? = nil
    var reply: TimelineReply? = nil
    var securityNotice: String? = nil
    var reactions: [TimelineReaction] = []
    var canReact: Bool = false
    /// Shown under a disabled reaction row; nil when `canReact`.
    var reactionUnavailableReason: String? = nil
    var author: String? = nil
    /// The sender unsent it: `body` is empty and the bubble shows a quiet placeholder.
    var isRetracted = false
    /// `body` is the sender's latest correction.
    var isEdited = false
    var canEdit = false
    var canUnsend = false
    /// A received message in a direct chat: its menu offers Report, which reports and blocks the sender.
    var canReport = false
    /// This device could not show the message; `body` is empty and the bubble shows the reason as a quiet placeholder.
    var unreadable: UnreadableReason? = nil

    /// Unsent or unreadable: the bubble keeps its shape and time, and its text is a quiet italic notice.
    var showsPlaceholder: Bool { isRetracted || unreadable != nil }
    var placeholder: String {
        if let unreadable { return UnreadableCopy.bubble(unreadable, isOutgoing: isOutgoing) }
        return isOutgoing ? "You unsent a message" : "Message unsent"
    }

    /// The bubble's text: the placeholder for an unsent or unreadable message, the body otherwise.
    var displayedText: String { showsPlaceholder ? placeholder : body }

    /// The links drawn in the text and opened on a tap; a placeholder has none.
    var links: [DetectedLink] { showsPlaceholder ? [] : LinkScan.links(in: body) }

    /// The quiet line beside the status mark: edited, the security notice and the time, in that order.
    var footerText: String {
        [isEdited ? "Edited" : nil, securityNotice, sentAt?.formatted(date: .omitted, time: .shortened)].compactMap { $0 }.joined(separator: " · ")
    }
    var showsFooterText: Bool { sentAt != nil || securityNotice != nil || isEdited }
    /// Only a sent message shows a mark, and only once it has a status.
    var statusGlyph: MessageStatusGlyph? { isOutgoing ? status.map(MessageStatusGlyph.glyph(for:)) : nil }

    /// What VoiceOver reads for the bubble: who, what, then everything the bubble shows around the text.
    var accessibilityDescription: String { accessibilityDescription(sender: nil) }

    /// As `accessibilityDescription`, with `sender` naming who sent a received message, where the caller knows a name
    /// for them; without it, the author or "Contact".
    func accessibilityDescription(sender: String?) -> String {
        let shown = displayedText
        let speaker = isOutgoing ? "You" : (sender ?? author ?? "Contact")
        var descriptions = [shown.isEmpty ? speaker : "\(speaker): \(shown)"]
        if unreadable != nil { descriptions.append("not readable on this device") }
        if isEdited { descriptions.append("edited") }
        if !showsPlaceholder, let attachment { descriptions.append("\(attachment.kindLabel) \(attachment.name)" + (attachment.localURL == nil ? ", " + attachment.downloadAccessibility : "")) }
        if !showsPlaceholder, let linkPreview { descriptions.append(linkPreview.accessibilityDescription) }
        if let quote = reply { descriptions.append("Replying to \(quote.author): \(quote.body)") }
        if isStarred { descriptions.append("starred") }
        if let date = sentAt { descriptions.append(date.formatted(date: .abbreviated, time: .shortened)) }
        if isOutgoing, let state = status {
            descriptions.append(failure.flatMap { state == .failed ? "Not delivered: \($0)" : nil } ?? state.accessibilityDescription)
        }
        if let notice = securityNotice { descriptions.append(notice) }
        if !reactions.isEmpty { descriptions.append(reactions.map(\.accessibilityDescription).joined(separator: ", ")) }
        return descriptions.joined(separator: ", ")
    }

    enum Status: String, Sendable, Equatable {
        case queued, submitting, unconfirmed, failed, serverAccepted, delivered, displayed

        var accessibilityDescription: String {
            switch self {
            case .queued: "Waiting to send"
            case .submitting: "Sending"
            case .unconfirmed: "Sending, not yet confirmed"
            case .failed: "Not sent"
            case .serverAccepted: "Sent"
            case .delivered: "Delivered"
            case .displayed: "Read"
            }
        }

        var canRetry: Bool { self == .unconfirmed || self == .failed }
    }
}

/// Which status mark a sent message shows. A socket write is not delivery: until the server accepts the
/// message it keeps the dashed sending ring, spinning only while the outbox is actively working on it.
enum MessageStatusGlyph: Equatable, Sendable {
    case sending(spinning: Bool), sent, delivered, read, failed

    static func glyph(for status: TimelineMessage.Status) -> MessageStatusGlyph {
        switch status {
        case .queued, .submitting: .sending(spinning: true)
        case .unconfirmed: .sending(spinning: false)
        case .failed: .failed
        case .serverAccepted: .sent
        case .delivered: .delivered
        case .displayed: .read
        }
    }
}

/// Someone is typing: a received-style bubble of dots after the newest message.
struct TimelineTyping: Sendable, Equatable {
    /// Group only: who, above the bubble like a message author.
    let author: String?
    /// The author colour's key, so the line matches that sender's messages.
    let colorKey: String
    let accessibilityLabel: String
}

/// A message plus what its neighbours decide: day header, run start (spacing, sender name) and run end (tail corner).
struct TimelineRow: Equatable {
    let message: TimelineMessage
    let dateHeader: String?
    let startsRun: Bool
    let endsRun: Bool

    static func rows(for messages: [TimelineMessage]) -> [TimelineRow] {
        let calendar = Calendar.current
        var headers: [String?] = []
        var starts: [Bool] = []
        var lastDay: Date?
        for (index, message) in messages.enumerated() {
            var header: String?
            if let date = message.sentAt {
                if lastDay.map({ !calendar.isDate($0, inSameDayAs: date) }) ?? true {
                    header = calendar.isDateInToday(date) ? "Today" : calendar.isDateInYesterday(date) ? "Yesterday" : date.formatted(date: .abbreviated, time: .omitted)
                }
                lastDay = date
            }
            let previous = index > 0 ? messages[index - 1] : nil
            let continues = previous.map { $0.isOutgoing == message.isOutgoing && $0.author == message.author } ?? false
            headers.append(header)
            starts.append(header != nil || !continues)
        }
        return messages.indices.map { index in
            TimelineRow(message: messages[index], dateHeader: headers[index], startsRun: starts[index],
                        endsRun: index == messages.count - 1 || starts[index + 1])
        }
    }
}
