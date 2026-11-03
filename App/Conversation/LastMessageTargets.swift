import Foundation

// Like Messages' "Reply to Last Message": each command takes the newest message whose own menu offers that action.
struct LastMessageTargets: Equatable {
    var reply: TimelineMessage?
    var edit: TimelineMessage?
    var react: TimelineMessage?
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

    // A command never falls through to a message the user did not pick.
    init(focused message: TimelineMessage) {
        let kinds = Set(MessageActionMenu.items(for: message).map(\.kind))
        if kinds.contains(.reply) { reply = message }
        if kinds.contains(.edit) { edit = message }
        if !message.showsPlaceholder, message.canReact { react = message }
        if kinds.contains(.star) { star = message }
    }
}
