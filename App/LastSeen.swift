import Foundation
import XMPPProtocol

/// What the chat header says about a 1:1 contact's activity. In memory only; nil means unknown and leaves the header
/// showing just the name.
enum LastSeen: Equatable {
    case online
    case lastSeen(Date)

    /// The header subtitle, relative to `now` in `calendar` (its locale and time zone format the time and day).
    static func label(_ state: LastSeen, now: Date, calendar: Calendar) -> String {
        guard case .lastSeen(let date) = state else { return "Online" }
        if now.timeIntervalSince(date) < 60 { return "Last seen just now" }
        let locale = calendar.locale ?? .current
        let style = Date.FormatStyle(locale: locale, calendar: calendar, timeZone: calendar.timeZone)
        let time = date.formatted(style.hour().minute())
        let days = calendar.dateComponents([.day], from: calendar.startOfDay(for: date), to: calendar.startOfDay(for: now)).day ?? .max
        switch days {
        case 0: return "Last seen today at \(time)"
        case 1: return "Last seen yesterday at \(time)"
        case 2...6: return "Last seen \(date.formatted(style.weekday(.wide))) at \(time)"
        default:
            let sameYear = calendar.component(.year, from: date) == calendar.component(.year, from: now)
            let day = style.day().month(.abbreviated)
            return "Last seen \(date.formatted(sameYear ? day : day.year()))"
        }
    }
}

/// One contact's activity as this connection (and earlier ones) saw it. In memory only, never stored.
struct ContactPresenceState: Equatable {
    /// Available resources (the empty string for a bare-address presence) with their XEP-0319 idle start.
    var available: [String: Date?] = [:]
    /// When we saw the contact's last available resource go away.
    var lastUnavailableAt: Date?
    /// now − seconds from a XEP-0012 answer with seconds > 0.
    var lastActivityAt: Date?
    /// When we last sent a XEP-0012 query on this connection.
    var lastQueriedAt: Date?
}

/// Presence, roster and the last-seen policy for 1:1 chats, kept pure so AppModel only does the I/O.
/// The roster and the available sets belong to one connection; what we last saw survives a reconnect.
struct LastSeenTracker {
    /// A XEP-0012 query per contact at most this often on one connection.
    static let queryInterval: TimeInterval = 60

    private(set) var contacts: [String: ContactPresenceState] = [:]
    private(set) var roster: [String: XMPPRosterItem] = [:]
    /// The roster was fetched on this connection, so a missing item really means "not in the roster".
    private(set) var rosterLoaded = false
    /// Contacts we sent `subscribe` to on this connection.
    private var asked: Set<String> = []

    enum AskStep: Equatable { case nothing, subscribe, queryLastActivity }
    enum SubscribeAnswer: Equatable {
        /// Approve; `alsoSubscribe` asks back when we neither hold nor await their presence yet.
        case approve(alsoSubscribe: Bool)
        case deny
        case leavePending
    }

    /// A new connection: the server re-sends presence (probes) and the roster is fetched again.
    mutating func resetConnection() {
        roster = [:]; rosterLoaded = false; asked = []
        for key in contacts.keys { contacts[key]?.available = [:]; contacts[key]?.lastQueriedAt = nil }
    }

    /// Records a presence from a listed 1:1 chat; anything else (our own resources, groups, strangers) is ignored.
    /// Returns whether the presence was recorded.
    @discardableResult
    mutating func apply(_ presence: XMPPContactPresence, account: String, isDirectChat: Bool, now: Date) -> Bool {
        guard isDirectChat, presence.contact != account else { return false }
        var state = contacts[presence.contact] ?? ContactPresenceState()
        let resource = presence.resource ?? ""
        if presence.available {
            state.available[resource] = .some(presence.idleSince)
        } else {
            let wasAvailable = !state.available.isEmpty
            // An unavailable from the bare address (a probe answer for an offline contact) ends every resource.
            if presence.resource == nil { state.available = [:] } else { state.available[resource] = nil }
            // Only a departure we watched dates the contact; a probe answer says "offline", not "offline since now".
            if wasAvailable, state.available.isEmpty { state.lastUnavailableAt = now }
        }
        contacts[presence.contact] = state
        return true
    }

    mutating func applyRoster(_ items: [XMPPRosterItem], replacesAll: Bool) {
        if replacesAll { roster = [:]; rosterLoaded = true }
        for item in items {
            if item.subscription == .remove { roster[item.jid] = nil } else { roster[item.jid] = item }
        }
    }

    func holdsSubscription(to contact: String) -> Bool {
        guard let subscription = roster[contact]?.subscription else { return false }
        return subscription == .to || subscription == .both
    }

    /// Everyone the roster says may currently see our presence.
    var sharingWith: [String] {
        roster.values.filter { $0.subscription == .from || $0.subscription == .both }.map(\.jid).sorted()
    }

    /// What to ask about a 1:1 contact now; records the decision so it is not repeated too soon.
    /// Subscribe once per connection unless the server already keeps our request pending; query XEP-0012
    /// only for a contact we may ask who shows no available resource, at most once a minute.
    mutating func askStep(for contact: String, now: Date) -> AskStep {
        guard rosterLoaded else { return .nothing }
        if !holdsSubscription(to: contact) {
            guard roster[contact]?.askPending != true, !asked.contains(contact) else { return .nothing }
            asked.insert(contact)
            return .subscribe
        }
        var state = contacts[contact] ?? ContactPresenceState()
        guard state.available.isEmpty else { return .nothing }
        if let queried = state.lastQueriedAt, now.timeIntervalSince(queried) < Self.queryInterval { return .nothing }
        state.lastQueriedAt = now
        contacts[contact] = state
        return .queryLastActivity
    }

    /// A XEP-0012 answer. `seconds == 0` means the server has no record (or the contact is online): unknown.
    mutating func recordLastActivity(seconds: Int, of contact: String, now: Date) {
        guard seconds > 0 else { return }
        contacts[contact, default: ContactPresenceState()].lastActivityAt = now.addingTimeInterval(-TimeInterval(seconds))
    }

    /// How to answer a `subscribe` from `contact`: approve contacts we chat with while sharing, deny everyone
    /// while not sharing, and leave strangers pending on the server.
    mutating func answerSubscribe(from contact: String, sharesLastSeen: Bool, isDirectChat: Bool) -> SubscribeAnswer {
        guard sharesLastSeen else { return .deny }
        guard isDirectChat else { return .leavePending }
        let askBack = rosterLoaded && !holdsSubscription(to: contact) && roster[contact]?.askPending != true && !asked.contains(contact)
        if askBack { asked.insert(contact) }
        return .approve(alsoSubscribe: askBack)
    }

    func lastSeen(for contact: String) -> LastSeen? { contacts[contact].flatMap(Self.derive) }

    /// Online when any resource is available and not idle; otherwise the newest idle start when all are idle;
    /// otherwise the newer of the watched departure and the server's last-activity answer; otherwise unknown.
    static func derive(_ state: ContactPresenceState) -> LastSeen? {
        if !state.available.isEmpty {
            let idle = state.available.values.compactMap { $0 }
            if idle.count < state.available.count { return .online }
            return idle.max().map(LastSeen.lastSeen)
        }
        return [state.lastUnavailableAt, state.lastActivityAt].compactMap { $0 }.max().map(LastSeen.lastSeen)
    }
}
