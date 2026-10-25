import SwiftUI

/// One-line trust state for the details pill, presented from `ChatCapabilities.encryption`.
struct ConversationTrust {
    /// `pending`: nothing stored yet. No pill is drawn (its height is kept), so "not known yet" never reads as "off".
    enum Level { case verified, encrypted, review, pending, other }
    let level: Level
    let subtitle: String

    var needsReview: Bool { level == .review }
    var icon: String {
        switch level {
        case .verified, .encrypted, .pending: "lock"
        case .review: "exclamationmark.shield"
        case .other: "lock.open"
        }
    }
    var color: Color {
        switch level {
        case .verified: .green
        case .encrypted: .secondary
        case .review: .orange
        case .pending, .other: .secondary
        }
    }
    var pill: String {
        switch level {
        case .verified: "Encrypted · Verified"
        case .encrypted: "Encrypted"
        case .review: "Needs review"
        case .pending, .other: subtitle
        }
    }
}

extension ConversationTrust {
    /// The pill for a chat's stored encryption state, as the details screens and the share sheet show it. `members`
    /// counts a group's members for its subtitle.
    init(_ encryption: ChatCapabilities.Encryption, isGroup: Bool, members: Int) {
        switch encryption {
        case .pending:
            self.init(level: .pending, subtitle: "")
        case .needsReview:
            self.init(level: .review, subtitle: isGroup ? "Devices need review" : "New device needs review")
        case .unavailable(let reason):
            self.init(level: .other, subtitle: reason)
        case .encrypted(let verified):
            if isGroup { self.init(level: verified ? .verified : .encrypted, subtitle: "\(members) members · Encrypted") }
            else { self.init(level: verified ? .verified : .encrypted, subtitle: verified ? "Encrypted · Verified" : "Encrypted") }
        }
    }
}

/// The trust capsule under a details hero; the small symbol keeps it a balanced pill.
struct TrustPill: View {
    let text: String
    let systemImage: String
    let color: Color

    var body: some View {
        // Label's default icon gap reads as two separate things at footnote size.
        HStack(spacing: 3) { Image(systemName: systemImage); Text(text) }
            .accessibilityElement(children: .combine)
            .imageScale(.small)
            .font(.footnote.weight(.semibold))
            .padding(.horizontal, 10).padding(.vertical, 5)
            .frame(minHeight: 26)
            .foregroundStyle(color)
            .background(color.opacity(0.14), in: Capsule())
    }
}
