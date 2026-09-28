#if DEBUG
import CryptoKit
import UIKit
import UserNotifications
import MessageStore
import MessagingCore

/// DEBUG only, `-notification-harness`: once the app goes to the background, posts synthetic sample notifications
/// through the extension's own path (`NotificationPlanner` → `UserNotificationPoster`, including the communication
/// intent and the pre-scaled App Group avatars), so the simulator shows what a filtered run would post. The samples
/// are invented; nothing is read from, or written to, the message store. `-notification-harness-hidden` posts them
/// with previews off.
@MainActor enum NotificationHarness {
    static var isRequested: Bool { ProcessInfo.processInfo.arguments.contains("-notification-harness") }
    private nonisolated static let account = "me@preview.local"
    private static var observer: NSObjectProtocol?

    static func install() {
        guard isRequested, observer == nil else { return }
        Task { _ = try? await UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound, .badge]) }
        observer = NotificationCenter.default.addObserver(forName: UIApplication.didEnterBackgroundNotification, object: nil, queue: .main) { _ in
            Task { @MainActor in await post() }
        }
    }

    private static func post() async {
        let task = UIApplication.shared.beginBackgroundTask(withName: "notification-harness")
        defer { UIApplication.shared.endBackgroundTask(task) }
        guard let root = try? await SharedStorage.directory(migrate: false) else { return }
        let maya = avatar("M", color: .systemTeal, root: root), alex = avatar("A", color: .systemOrange, root: root)
        let crew = avatar("T", color: .systemIndigo, root: root)
        let previews = !ProcessInfo.processInfo.arguments.contains("-notification-harness-hidden")
        let now = Date()
        func message(_ id: String, chat: String, sender: String, body: String, at offset: TimeInterval) -> StoredMessage {
            StoredMessage(id: id, accountID: account, chatID: chat, senderID: sender, body: body, sentAt: now.addingTimeInterval(offset), encryptionProfile: "modern")
        }
        let direct = message("0B8F5E4C-1D2A-4C7B-9E11-6A1F2B3C4D51", chat: "maya@preview.local", sender: "maya@preview.local",
                             body: "The trail opens at nine. Bring the map?", at: -30)
        let group = message("0B8F5E4C-1D2A-4C7B-9E11-6A1F2B3C4D52", chat: "trail@rooms.preview.local", sender: "alex@preview.local",
                            body: "Carpool leaves from the bakery at 8:15.", at: -20)
        let mine = StoredMessage(id: "0B8F5E4C-1D2A-4C7B-9E11-6A1F2B3C4D53", accountID: account, chatID: "maya@preview.local", senderID: account,
                                 body: "Pastries are on me 🥐", sentAt: now.addingTimeInterval(-60), isOutgoing: true, encryptionProfile: "modern")
        let alexPerson = NotificationParticipant(id: "alex@preview.local", title: "Alex", avatarHash: alex)
        let batch = MessageNotification(
            candidates: [
                NotificationCandidate(key: .message(direct.id), accountID: account, chatID: direct.chatID, chatTitle: "Maya", chatAvatarHash: maya,
                                      senderID: direct.senderID, isGroup: false, sentAt: direct.sentAt, content: .message(direct)),
                NotificationCandidate(key: .message(group.id), accountID: account, chatID: group.chatID, chatTitle: "Trail crew", chatAvatarHash: crew,
                                      senderID: group.senderID, senderTitle: "Alex", senderAvatarHash: alex, isGroup: true, sentAt: group.sentAt,
                                      content: .message(group),
                                      groupMembers: [NotificationParticipant(id: "maya@preview.local", title: "Maya", avatarHash: maya)])
            ],
            claimed: [], previewsEnabled: previews,
            reactions: [
                ReactionNotificationCandidate(key: .reaction(sequence: 1), accountID: account, chatID: "maya@preview.local", chatTitle: "Maya",
                                              chatAvatarHash: maya, actor: NotificationParticipant(id: "maya@preview.local", title: "Maya", avatarHash: maya),
                                              isGroup: false, target: mine, reactions: ["❤️"], reactedAt: now.addingTimeInterval(-10)),
                ReactionNotificationCandidate(key: .reaction(sequence: 2), accountID: account, chatID: "trail@rooms.preview.local", chatTitle: "Trail crew",
                                              chatAvatarHash: crew, actor: alexPerson, isGroup: true,
                                              target: StoredMessage(id: "0B8F5E4C-1D2A-4C7B-9E11-6A1F2B3C4D54", accountID: account,
                                                                    chatID: "trail@rooms.preview.local", senderID: account, body: "I can drive two people.",
                                                                    isOutgoing: true, encryptionProfile: "modern"),
                                              reactions: ["👍"], reactedAt: now.addingTimeInterval(-5),
                                              groupMembers: [NotificationParticipant(id: "maya@preview.local", title: "Maya", avatarHash: maya)])
            ])
        let plan = NotificationPlanner.plan(batch, accountID: account, badge: 3)
        let poster = UserNotificationPoster(avatarData: { hash in AvatarStore.notificationImageData(root: root, account: account, hash: hash) })
        for request in plan.requests {
            do { try await poster.add(request) } catch { print("notification harness: add failed \(error)") }
            try? await Task.sleep(for: .seconds(2))
        }
    }

    /// A drawn sample avatar stored like a verified one, with its pre-scaled notification copy. Returns its hash.
    private static func avatar(_ letter: String, color: UIColor, root: URL) -> String? {
        let size = CGSize(width: 512, height: 512)
        let data = UIGraphicsImageRenderer(size: size).pngData { context in
            color.setFill(); context.fill(CGRect(origin: .zero, size: size))
            let text = NSAttributedString(string: letter, attributes: [.font: UIFont.systemFont(ofSize: 260, weight: .semibold), .foregroundColor: UIColor.white])
            let bounds = text.size()
            text.draw(at: CGPoint(x: (size.width - bounds.width) / 2, y: (size.height - bounds.height) / 2))
        }
        let hash = Insecure.SHA1.hash(data: data).map { String(format: "%02x", $0) }.joined()
        guard (try? AvatarStore.save(data, root: root, account: account, hash: hash)) != nil,
              AvatarStore.saveNotificationImage(root: root, account: account, hash: hash) else { return nil }
        return hash
    }
}
#endif
