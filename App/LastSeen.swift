import Foundation
import XMPPProtocol

enum LastSeen: Equatable {
    case online
    case lastSeen(Date)

    // A blocked contact's presence no longer reaches us, so an old answer would go stale.
    static func headerLabel(_ state: LastSeen?, isGroup: Bool, isBlocked: Bool, now: Date, calendar: Calendar) -> String? {
        guard !isGroup, !isBlocked, let state else { return nil }
        return label(state, now: now, calendar: calendar)
    }

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

struct ContactPresenceState: Equatable {
    // Resource (empty for a bare-address presence) to its XEP-0319 idle start.
    var available: [String: Date?] = [:]
    var lastUnavailableAt: Date?
    // From a XEP-0012 answer with seconds > 0.
    var lastActivityAt: Date?
    var lastQueriedAt: Date?
    // Restored when the next stream resumes this session (no probe answers then), dropped when a new session starts.
    var heldAvailable: [String: Date?] = [:]
}

struct LastSeenTracker {
    static let queryInterval: TimeInterval = 60

    private(set) var contacts: [String: ContactPresenceState] = [:]
    private(set) var roster: [String: XMPPRosterItem] = [:]
    // A missing roster item means "not in the roster" only once the roster was fetched on this connection.
    private(set) var rosterLoaded = false
    private var asked: Set<String> = []

    enum AskStep: Equatable { case nothing, subscribe, queryLastActivity }
    enum SubscribeAnswer: Equatable {
        case approve(alsoSubscribe: Bool)
        case deny
        case leavePending
    }

    mutating func resetConnection() {
        roster = [:]; rosterLoaded = false; asked = []
        for key in contacts.keys {
            guard var state = contacts[key] else { continue }
            if !state.available.isEmpty { state.heldAvailable = state.available }
            state.available = [:]; state.lastQueriedAt = nil
            contacts[key] = state
        }
    }

    // A resumed session gets no probe answers, so held availability is still true; a new session drops it.
    mutating func beginConnection(resumed: Bool) {
        for key in contacts.keys {
            guard var state = contacts[key] else { continue }
            if resumed, state.available.isEmpty { state.available = state.heldAvailable }
            state.heldAvailable = [:]
            contacts[key] = state
        }
    }

    // Contacts without a listed chat are kept: probe answers arrive once at login, and a chat started later would
    // otherwise stay unknown until the contact's presence changes.
    @discardableResult
    mutating func apply(_ presence: XMPPContactPresence, account: String, isContact: Bool, now: Date) -> Bool {
        guard isContact, presence.contact != account else { return false }
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

    var sharingWith: [String] {
        roster.values.filter { $0.subscription == .from || $0.subscription == .both }.map(\.jid).sorted()
    }

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

    // `seconds == 0` means the server has no record (or the contact is online): unknown.
    mutating func recordLastActivity(seconds: Int, of contact: String, now: Date) {
        guard seconds > 0 else { return }
        contacts[contact, default: ContactPresenceState()].lastActivityAt = now.addingTimeInterval(-TimeInterval(seconds))
    }

    // Strangers stay pending on the server.
    mutating func answerSubscribe(from contact: String, sharesLastSeen: Bool, isDirectChat: Bool) -> SubscribeAnswer {
        guard sharesLastSeen else { return .deny }
        guard isDirectChat else { return .leavePending }
        let askBack = rosterLoaded && !holdsSubscription(to: contact) && roster[contact]?.askPending != true && !asked.contains(contact)
        if askBack { asked.insert(contact) }
        return .approve(alsoSubscribe: askBack)
    }

    func lastSeen(for contact: String) -> LastSeen? { contacts[contact].flatMap(Self.derive) }

    static func derive(_ state: ContactPresenceState) -> LastSeen? {
        if !state.available.isEmpty {
            let idle = state.available.values.compactMap { $0 }
            if idle.count < state.available.count { return .online }
            return idle.max().map(LastSeen.lastSeen)
        }
        return [state.lastUnavailableAt, state.lastActivityAt].compactMap { $0 }.max().map(LastSeen.lastSeen)
    }
}
