import Foundation
import MessageStore
import XMPPProtocol

typealias ChatMessage = StoredMessage

struct TimelineReply: Sendable, Equatable {
    let author: String
    let body: String
    var thumbnail: TimelineAttachment? = nil
    // Local ID for a reply sent from here, the ID its sender saw for a received one; the store resolves either.
    var messageID: String? = nil
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
    // Plaintext on disk once sent, or downloaded and verified.
    var localURL: URL? = nil
    var download: AttachmentDownloadState = .loading
    var isImage: Bool { mediaType.hasPrefix("image/") }
    var isVideo: Bool { mediaType.hasPrefix("video/") }
    var showsPreview: Bool { isImage || isVideo }
    var aspectRatio: CGFloat {
        guard let width, let height, width > 0, height > 0 else { return 4 / 3 }
        return CGFloat(width) / CGFloat(height)
    }
    var kindLabel: String { isImage ? "Photo" : isVideo ? "Video" : "File" }
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
    var linkPreview: TimelineLinkPreview? = nil
    var wantsLinkPreview = false
    var sentAt: Date? = nil
    var status: Status? = nil
    var failure: String? = nil
    var reply: TimelineReply? = nil
    var securityNotice: String? = nil
    var reactions: [TimelineReaction] = []
    var canReact: Bool = false
    var reactionUnavailableReason: String? = nil
    var author: String? = nil
    var isRetracted = false
    var isEdited = false
    var canEdit = false
    var canUnsend = false
    var canReport = false
    var unreadable: UnreadableReason? = nil

    var showsPlaceholder: Bool { isRetracted || unreadable != nil }
    var placeholder: String {
        if let unreadable { return UnreadableCopy.bubble(unreadable, isOutgoing: isOutgoing) }
        return isOutgoing ? "You unsent a message" : "Message unsent"
    }

    var displayedText: String { showsPlaceholder ? placeholder : body }

    var links: [DetectedLink] { showsPlaceholder ? [] : LinkScan.links(in: body) }

    var footerText: String {
        [isEdited ? "Edited" : nil, securityNotice, sentAt?.formatted(date: .omitted, time: .shortened)].compactMap { $0 }.joined(separator: " · ")
    }
    var showsFooterText: Bool { sentAt != nil || securityNotice != nil || isEdited }
    var statusGlyph: MessageStatusGlyph? { isOutgoing ? status.map(MessageStatusGlyph.glyph(for:)) : nil }

    var accessibilityDescription: String { accessibilityDescription(sender: nil) }

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

// A socket write is not delivery: until the server accepts the message it keeps the dashed ring, spinning only while
// the outbox works on it.
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

struct TimelineTyping: Sendable, Equatable {
    let author: String?
    let colorKey: String
    let accessibilityLabel: String
}

// Neighbours decide the day header, run start (spacing, sender name) and run end (tail corner).
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
