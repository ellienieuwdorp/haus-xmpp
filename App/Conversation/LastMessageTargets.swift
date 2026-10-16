import Foundation

/// The messages the menu bar's message commands act on, as Messages' "Reply to Last Message" does: each command takes
/// the newest loaded message whose own menu offers that action, so it never does what the bubble's menu would refuse.
struct LastMessageTargets: Equatable {
    /// The newest received message offering Reply: what an answer is to.
    var reply: TimelineMessage?
    /// The newest own message offering Edit: what Up-arrow in an empty composer edits.
    var edit: TimelineMessage?
    /// The newest received message taking reactions.
    var react: TimelineMessage?
    /// The newest message offering Star or Unstar.
    var star: TimelineMessage?

    init(messages: [TimelineMessage]) {
        for message in messages.reversed() {
            let kinds = Set(MessageActionMenu.items(for: message).map(\.kind))
            if reply == nil, !message.isOutgoing, kinds.contains(.reply) { reply = message }
            if edit == nil, message.isOutgoing, kinds.contains(.edit) { edit = message }
            if react == nil, !message.isOutgoing, !message.showsPlaceholder, message.canReact { react = message }
            if star == nil, kinds.contains(.star) { star = message }
            if reply != nil, edit != nil, react != nil, star != nil { break }
        }
    }
}
