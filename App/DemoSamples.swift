import CryptoKit
import Foundation
import MessageStore

/// The sample conversations ("Explore sample conversations"): who they are with, what was said and when. They are
/// stored as received and sent messages would be, with receipts, reactions, a reply, a star, a photo and a carried
/// link preview, so every part of a bubble shows; nothing is sent or fetched. `AppModel.loadDemo` writes them on a
/// fresh sample account each time. Avatars and pictures are drawn by `DemoArt`.
enum DemoSamples {
    static let account = "preview.local"
    static let alex = "alex@preview.local"
    static let maya = "maya@preview.local"
    static let notes = "notes@preview.local"

    /// The end of Alex's chat: 09:38 on the latest day that has passed it, so the sample reads as this morning's (or,
    /// before then, yesterday's) and the list shows a time, "Yesterday" and weekdays. Every other sample is dated from it.
    static func morning(now: Date = .now, calendar: Calendar = .current) -> Date {
        let today = calendar.date(bySettingHour: 9, minute: 38, second: 0, of: now) ?? now
        return today.addingTimeInterval(120) <= now ? today : calendar.date(byAdding: .day, value: -1, to: today) ?? today
    }

    /// `days` before `morning`, at `hour`:`minute`.
    static func day(_ days: Int, _ hour: Int, _ minute: Int, from morning: Date, calendar: Calendar = .current) -> Date {
        let day = calendar.date(byAdding: .day, value: days, to: morning) ?? morning
        return calendar.date(bySettingHour: hour, minute: minute, second: 0, of: day) ?? day
    }

    /// The sample chats' header lines; a real chat starts unknown until presence says otherwise.
    static func lastSeen(_ chat: String) -> LastSeen? {
        switch chat {
        case alex: .online
        case maya: .lastSeen(day(-1, 21, 5, from: morning()))
        default: nil
        }
    }

    /// Writes the chats, their messages, receipts and reactions, the photo into the file cache and the avatars into the
    /// avatar store. Returns the hash of the account's own avatar, which the model keeps with its preferences.
    static func write(to store: MessageStore, files: AttachmentFiles?, avatarRoot: URL?, morning: Date) async throws -> String? {
        func minutes(_ value: Double) -> Date { morning.addingTimeInterval(value * 60) }
        func message(_ id: String, in chat: String, outgoing: Bool, _ body: String, at date: Date, starred: Bool = false, reply: MessageReply? = nil,
                     attachment: StoredAttachment? = nil, preview: StoredLinkPreview? = nil) -> StoredMessage {
            // A wire ID lets sample messages carry receipts and reactions, and own ones be unsent or edited (projection
            // only, nothing is sent).
            StoredMessage(id: id, accountID: account, chatID: chat, senderID: outgoing ? account : chat, body: body, sentAt: date, isOutgoing: outgoing,
                          isStarred: starred, reply: reply, wireID: id, attachment: attachment, linkPreview: preview)
        }

        // Alex: a photo, a reply quoting it, a café link with its preview, reactions both ways and a star.
        let photo = DemoArt.lakePhotoJPEG() ?? Data()
        let attachment = StoredAttachment(name: "boathouse.jpg", mediaType: "image/jpeg", size: photo.count, width: 1200, height: 600,
                                          hash: Data.sha256(photo).hexString,
                                          secret: Data([0])) // never opened: the file is already in the cache
        if let files, !photo.isEmpty { try files.write(photo, to: files.cacheURL(attachment, messageID: "sample-alex-photo")) }
        let cafe = "https://example.org/cafe"
        let thumbnail = DemoArt.cafeThumbnailJPEG()
        let alexMessages = [
            message("sample-alex-0", in: alex, outgoing: false, "Found a quiet spot by the water 🌅", at: minutes(-57)),
            message("sample-alex-photo", in: alex, outgoing: false, "", at: minutes(-56.8), attachment: photo.isEmpty ? nil : attachment),
            message("sample-alex-1", in: alex, outgoing: true, "Is that the old boathouse? It looks so calm.", at: minutes(-51),
                    reply: MessageReply(messageID: "sample-alex-photo", senderID: alex, body: attachment.quoteLabel, wireID: "sample-alex-photo",
                                        mediaType: attachment.mediaType)),
            message("sample-alex-2", in: alex, outgoing: false, "It’s a café now. Coffee tomorrow? \(cafe)", at: minutes(-49), starred: true,
                    preview: StoredLinkPreview(url: cafe, title: "The Boathouse Café", summary: "Coffee and cardamom buns.",
                                               imageData: thumbnail, imageType: thumbnail.map { _ in "image/jpeg" }, imageAlt: "A cup of coffee",
                                               source: .sender)),
            message("sample-alex-3", in: alex, outgoing: true, "That sounds perfect. Around ten?", at: minutes(-6)),
            message("sample-alex-5", in: alex, outgoing: true, "See you there!", at: minutes(0)),
        ]
        // Maya (muted by the caller) and the notes chat, on earlier days.
        let mayaMessages = [
            message("sample-maya-0", in: maya, outgoing: false, "A little reminder to take the scenic route.", at: day(-1, 19, 12, from: morning)),
            message("sample-maya-1", in: maya, outgoing: true, "Always. See you this weekend!", at: day(-1, 19, 20, from: morning)),
        ]
        let notesMessages = [
            message("sample-notes-0", in: notes, outgoing: false, "A place for the things worth keeping. Try starring this message.",
                    at: day(-2, 18, 30, from: morning)),
            message("sample-notes-1", in: notes, outgoing: true, "Starred things stay at the top of the list.", at: day(-2, 18, 31, from: morning)),
        ]
        // Each chat's sent messages show one receipt state: read (Alex), delivered (Maya), held by the server (notes).
        let chats: [(String, String, [StoredMessage], MessageEventKind?)] = [
            (alex, "Alex", alexMessages, .displayed), (maya, "Maya", mayaMessages, .delivered), (notes, "Notes to self", notesMessages, nil),
            (DemoLinkSamples.chatID, DemoLinkSamples.title, DemoLinkSamples.messages(account: account, start: day(-3, 17, 40, from: morning)), .displayed),
        ]
        for (chat, title, messages, receipt) in chats {
            try await store.upsertChat(accountID: account, chatID: chat, title: title)
            for message in messages {
                try await store.insertMessage(message)
                guard message.isOutgoing, let receipt, let wireID = message.wireID else { continue }
                try await store.recordReceipt(accountID: account, event: MessageEvent(id: message.id + "-receipt", chatID: chat, actorID: chat, targetWireID: wireID,
                                                                                    kind: receipt, payload: "{}", updatedAt: message.sentAt.addingTimeInterval(30)))
            }
        }
        // Our heart on the photo, ringed in the accent, and Alex's thumbs up as the answer to the plan.
        try await store.recordReaction(accountID: account, reaction: AuthenticatedReaction(id: "sample-reaction-own", chatID: alex, actorID: account,
                                                                                           targetWireID: "sample-alex-photo", reactions: ["❤️"], updatedAt: minutes(-51)))
        try await store.recordReaction(accountID: account, reaction: AuthenticatedReaction(id: "sample-reaction-alex", chatID: alex, actorID: alex,
                                                                                           targetWireID: "sample-alex-3", reactions: ["👍"], updatedAt: minutes(-5)))

        guard let avatarRoot else { return nil }
        func avatar(_ art: DemoArt.Avatar) throws -> String? {
            guard let data = DemoArt.avatarPNG(art) else { return nil }
            let hash = Insecure.SHA1.hash(data: data).map { String(format: "%02x", $0) }.joined()
            try AvatarStore.save(data, root: avatarRoot, account: account, hash: hash)
            return hash
        }
        for (chat, art) in [(alex, DemoArt.Avatar.alex), (maya, .maya), (notes, .notes), (DemoLinkSamples.chatID, .sam)] {
            try await store.setAvatarHash(accountID: account, chatID: chat, hash: try avatar(art))
        }
        return try avatar(.own)
    }
}
