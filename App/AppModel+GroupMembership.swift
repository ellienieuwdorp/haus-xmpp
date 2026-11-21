import Foundation
import MessagingCore
import XMPPProtocol

extension AppModel {
    func isRemovedFromGroup(_ chatID: String) -> Bool { groupChats[chatID]?.removal != nil }

    // A blocked chat, or a group that no longer counts us, shows a bar in the composer's place and sends nothing.
    func composerless(_ chatID: String) -> Bool { isBlocked(chatID) || isRemovedFromGroup(chatID) }

    // The join a reconnect sends; the room's presence then admits us or names the refusal.
    func rejoinGroup(_ room: String) async {
        guard groupChats[room]?.mayRejoin == true else { return }
        if isDemo { roomRejoined(room, joined: true); return }
        guard hasTransportOwnership, transportWanted, !quiescing, isConnected, encryptionReady, let client else {
            error = "Connect before joining a group."
            return
        }
        let account = accountID, token = engine.generation
        do {
            _ = try await client.joinGroupRoom(room, nickname: nickname(in: room, account: account))
        } catch {
            guard engine.generation == token, accountID == account else { return }
            roomRejoinFailed(room, error: error)
            self.error = GroupChatState.failure(error)
        }
    }
}
