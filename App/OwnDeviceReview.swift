import SwiftUI
import OMEMO
import XMPPProtocol

/// One of the account's other devices as the account-level review shows it: its undecided records with one identity,
/// at most one per OMEMO version, decided together. Each record is fingerprint-scoped, so a stale review can never
/// decide a key that replaced this one.
struct OwnDeviceCandidate: Identifiable, Equatable {
    let deviceID: UInt32
    let fingerprint: String
    /// Legacy first, then OMEMO 2.
    let records: [EncryptionDevice]

    var id: String { "\(deviceID)|\(fingerprint)" }
    /// The device had another key before: the review must say so, never present it as merely new.
    var identityChanged: Bool { records.contains(where: \.identityChanged) }
    var versions: String { records.count > 1 ? "Both encryption versions" : records.first?.profile.label ?? "" }
}

/// What became of a device the review asked about.
enum OwnDeviceOutcome: Equatable {
    case decided(DeviceTrust)
    /// No longer advertised by the account: Remove from Account took it off the device lists.
    case removed
}

/// What the account-level review shows, derived from the stored own devices so tests can state it directly.
enum OwnDeviceReview {
    /// Active, undecided own devices grouped by device ID and fingerprint, in device ID order. A device ID that publishes
    /// different identities in the two versions stays two entries: only the same fingerprint is decided together.
    static func candidates(_ devices: [EncryptionDevice]) -> [OwnDeviceCandidate] {
        var groups: [String: [EncryptionDevice]] = [:]
        for device in devices where device.active && device.trust == .undecided {
            groups["\(device.deviceID)|\(device.fingerprint)", default: []].append(device)
        }
        return groups.values.map { records in
            OwnDeviceCandidate(deviceID: records[0].deviceID, fingerprint: records[0].fingerprint,
                               records: records.sorted { $0.profile == .legacy && $1.profile == .modern })
        }.sorted { ($0.deviceID, $0.fingerprint) < ($1.deviceID, $1.fingerprint) }
    }

    /// What the stored records of `candidate` say: removed once none of them is advertised, otherwise their decision once
    /// they agree and are no longer undecided; nil while the review still has to ask (or a record is gone, which the
    /// next decision reports as a changed device).
    static func outcome(of candidate: OwnDeviceCandidate, in devices: [EncryptionDevice]) -> OwnDeviceOutcome? {
        let current = candidate.records.map { record in devices.first { $0.id == record.id } }
        guard !current.isEmpty, current.allSatisfy({ $0 != nil }) else { return nil }
        if current.allSatisfy({ $0?.active == false }) { return .removed }
        guard let trust = current[0]?.trust, trust != .undecided, current.allSatisfy({ $0?.trust == trust }) else { return nil }
        return .decided(trust)
    }

    /// Remove from Account is for a device the user does not recognise: offered while it is undecided or not trusted,
    /// never once it is trusted or removed.
    static func offersRemoval(after outcome: OwnDeviceOutcome?) -> Bool { outcome == nil || outcome == .decided(.rejected) }

    /// A changed identity is named even when several devices wait, so it never reads as just another new device.
    static func headline(_ candidates: [OwnDeviceCandidate]) -> String {
        guard candidates.count == 1 else {
            let several = "\(candidates.count) devices on your account need review"
            switch candidates.filter(\.identityChanged).count {
            case 0: return several
            case 1: return several + ", one changed its identity"
            case let changed: return several + ", \(changed) changed their identity"
            }
        }
        return candidates[0].identityChanged ? "A device on your account changed its identity" : "New device on your account"
    }

    /// The Don't trust confirmation: what stops and what keeps working. Chats and groups both leave the device out.
    static let rejectionMessage = "New messages in your chats and groups won’t be encrypted for it, and nothing it sends will be opened. Your trusted devices are unaffected."

    /// The Remove from Account confirmation: what removal does, and that it is not a remote sign-out.
    static let removalMessage = "It stops receiving your encrypted messages, and nothing it sends will be opened. If it’s still signed in, it may add itself back; it stays untrusted unless you trust it."
}

extension OwnDeviceReview {
    /// Two identities in both encodings (legacy and OMEMO 2), public keys only, generated once for sample data and
    /// tests. Each pair has one fingerprint.
    static let sampleIdentities: [(legacy: Data, modern: Data)] = [
        (Data(hex: "05c508ef09624c2963740a4968ae0e9049aeb36e44d66c119d6897e0cac655e757")!,
         Data(hex: "3c039deaaf7f4c8ab11a133ee9f4917133a8b8e609823cdfd4192a30ee8bdb40")!),
        (Data(hex: "05533def5f7fecd4ba5cb52010938322ee1f4232c6bd99626d014e53b53e68a14a")!,
         Data(hex: "95e3685f6102f7b06536192b6f877c174291d8dc474028ab6a3713dd37a39b09")!)
    ]

    /// `-demo-own-device`: a newly signed-in device in both versions, and a known one whose OMEMO 2 identity changed.
    static func sampleDevices(account: String) -> [EncryptionDevice] {
        let new = sampleIdentities[0], changed = sampleIdentities[1]
        return [
            EncryptionDevice(jid: account, profile: .legacy, deviceID: 48213, identityKey: new.legacy, trust: .undecided, active: true, identityChanged: false),
            EncryptionDevice(jid: account, profile: .modern, deviceID: 48213, identityKey: new.modern, trust: .undecided, active: true, identityChanged: false),
            EncryptionDevice(jid: account, profile: .modern, deviceID: 1907, identityKey: changed.modern, trust: .undecided, active: true, identityChanged: true)
        ]
    }
}

/// The chat list's account-level prompt, shaped like a chat's trust review card.
struct OwnDeviceReviewCard: View {
    let candidates: [OwnDeviceCandidate]
    let review: () -> Void
    let later: () -> Void

    // The iPhone's thumb-sized card; regular Mac push buttons in a card that fits a sidebar row.
    #if os(iOS)
    private static let buttonPadding: CGFloat = 4, padding: CGFloat = 14, cornerRadius: CGFloat = 26
    #else
    private static let buttonPadding: CGFloat = 0, padding: CGFloat = 12, cornerRadius: CGFloat = 16
    #endif

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .top, spacing: 10) {
                Image(systemName: "exclamationmark.shield")
                    .font(.system(size: 18, weight: .semibold)).foregroundStyle(.orange)
                    .frame(width: 36, height: 36).background(.orange.opacity(0.15), in: Circle())
                    .accessibilityHidden(true)
                VStack(alignment: .leading, spacing: 1) {
                    Text(OwnDeviceReview.headline(candidates)).font(.subheadline.weight(.semibold))
                    Text("Encrypted messages wait until you decide. Nothing is trusted automatically.")
                        .font(.footnote).foregroundStyle(.secondary)
                }
                #if os(macOS)
                // A sidebar row's text is one line unless it asks for more; the card's text wraps in full.
                .lineLimit(nil)
                .fixedSize(horizontal: false, vertical: true)
                #endif
            }
            HStack(spacing: 8) {
                Button(action: review) { Text("Review").frame(maxWidth: .infinity).padding(.vertical, Self.buttonPadding) }
                    .buttonStyle(.borderedProminent)
                    .accessibilityIdentifier("ownDeviceReview.open")
                Button(action: later) { Text("Later").frame(maxWidth: .infinity).padding(.vertical, Self.buttonPadding) }
                    .buttonStyle(.bordered)
            }
            .buttonBorderShape(.capsule)
        }
        .padding(Self.padding)
        .glassEffect(.regular, in: RoundedRectangle(cornerRadius: Self.cornerRadius, style: .continuous))
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("ownDeviceReview.card")
    }
}

/// Every undecided device of the account at once, each with its fingerprint, Trust and Don't trust, the fingerprint
/// comparison that can verify it, and Remove from Account for one the user does not recognise. A decision applies to
/// every chat.
struct OwnDeviceReviewSheet: View {
    @Bindable var model: AppModel
    @Environment(\.dismiss) private var dismiss
    /// Every device shown since the sheet opened, so a decided one stays with its outcome until the sheet closes.
    @State private var shown: [OwnDeviceCandidate] = []
    @State private var rejecting: OwnDeviceCandidate?
    @State private var comparing: OwnDeviceCandidate?
    @State private var removing: OwnDeviceCandidate?

    var body: some View {
        NavigationStack {
            List {
                Section {
                    VStack(spacing: 6) {
                        Image(systemName: "person.badge.shield.checkmark")
                            .font(.system(size: 28, weight: .medium)).foregroundStyle(.orange)
                            .frame(width: 64, height: 64)
                            .background(.orange.opacity(0.15), in: Circle())
                            .accessibilityHidden(true)
                        Text("Do you recognize these devices?").font(.title2.bold()).multilineTextAlignment(.center).padding(.top, 6)
                        Text("They use your account, \(model.accountID). Trust only devices you know are yours, and remove any you don’t recognize. To be sure, compare each fingerprint with the one shown on that device.")
                            .font(.subheadline).foregroundStyle(.secondary).multilineTextAlignment(.center)
                    }
                    .frame(maxWidth: .infinity).padding(.vertical, 4)
                }
                .listRowBackground(Color.clear)
                ForEach(shown) { candidate in device(candidate) }
            }
            .navigationTitle("Your Devices")
            .inlineNavigationTitle()
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Close", systemImage: "xmark") { dismiss() }.closeButtonLabel() }
            }
            .sheet(item: $comparing) { candidate in
                // The comparison sheet names one record; a decision there applies to all of this device's records.
                DeviceFingerprintSheet(model: model, chatID: model.accountID, device: candidate.records[0], name: nil,
                                       versions: candidate.versions,
                                       rejectionMessage: OwnDeviceReview.rejectionMessage) { trust in
                    comparing = nil
                    Task { await model.decideOwnDevice(candidate, trust: trust) }
                }
            }
        }
        .onAppear { shown = model.ownDeviceReview }
        .onChange(of: model.ownDeviceReview) { _, current in
            // A shown device whose other version arrived meanwhile takes the fuller entry, so one decision covers both.
            shown = shown.map { old in current.first { $0.id == old.id } ?? old }
                + current.filter { candidate in !shown.contains { $0.id == candidate.id } }
        }
        // The root's alert cannot show over this sheet; a failed decision is reported here.
        .alert("Something needs attention", isPresented: Binding(
            get: { model.error != nil }, set: { if !$0 { model.error = nil } }
        )) {
            Button("OK") { model.error = nil }
        } message: { Text(model.error ?? "") }
    }

    @ViewBuilder private func device(_ candidate: OwnDeviceCandidate) -> some View {
        let outcome = OwnDeviceReview.outcome(of: candidate, in: model.ownDevices)
        Section {
            VStack(alignment: .leading, spacing: 10) {
                HStack(alignment: .firstTextBaseline) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Device \(String(candidate.deviceID))").font(.headline)
                        Text(candidate.versions).font(.footnote).foregroundStyle(.secondary)
                    }
                    Spacer(minLength: 8)
                    if let outcome { OutcomeLabel(outcome: outcome) }
                }
                if candidate.identityChanged && outcome == nil {
                    // A plain HStack, not a Label: in a List row a Label pads its icon column to body metrics.
                    HStack(alignment: .firstTextBaseline, spacing: 6) {
                        Image(systemName: "exclamationmark.shield")
                        Text("Its identity changed since you last reviewed it")
                    }
                    .font(.footnote.weight(.semibold)).foregroundStyle(.orange)
                }
                FingerprintGrid(value: candidate.fingerprint, font: .system(.footnote, design: .monospaced))
                    .padding(.vertical, 4)
                if outcome == nil {
                    // Styled buttons take their own taps, so both can share the device's row.
                    HStack(spacing: 10) {
                        Button(role: .destructive) { rejecting = candidate } label: { Text("Don’t Trust").frame(maxWidth: .infinity) }
                            .secondaryActionStyle().foregroundStyle(.red)
                            .accessibilityIdentifier("ownDevice.reject.\(candidate.deviceID)")
                            // Anchored to its button, so the dialog's popover points at the device it decides.
                            .confirmationDialog("Don’t trust device \(String(candidate.deviceID))?",
                                                isPresented: Binding(get: { rejecting?.id == candidate.id }, set: { if !$0 { rejecting = nil } }),
                                                titleVisibility: .visible) {
                                Button("Don’t Trust", role: .destructive) { Task { await model.decideOwnDevice(candidate, trust: .rejected) } }
                            } message: { Text(OwnDeviceReview.rejectionMessage) }
                        Button { Task { await model.decideOwnDevice(candidate, trust: .accepted) } } label: { Text("Trust").frame(maxWidth: .infinity) }
                            .prominentActionStyle()
                            .accessibilityIdentifier("ownDevice.trust.\(candidate.deviceID)")
                    }
                    .fontWeight(.semibold).controlSize(.large)
                }
            }
            .padding(.vertical, 4)
            if outcome == nil || outcome == .decided(.accepted) {
                Button { comparing = candidate } label: {
                    HStack {
                        Label("Compare fingerprints", systemImage: "checkmark.shield")
                        Spacer()
                        Image(systemName: "chevron.right").font(.footnote.weight(.semibold)).foregroundStyle(.tertiary)
                    }
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .frame(minHeight: 44)
                .accessibilityIdentifier("ownDevice.compare.\(candidate.deviceID)")
            }
            if OwnDeviceReview.offersRemoval(after: outcome) {
                Button(role: .destructive) { removing = candidate } label: {
                    Label("Remove from Account", systemImage: EncryptionDevice.removedSymbol).foregroundStyle(.red)
                        .frame(maxWidth: .infinity, minHeight: 44, alignment: .leading)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                // The removal rewrites the account's device lists on the server.
                .disabled(!(model.isDemo || model.session.isReady))
                .accessibilityIdentifier("ownDevice.remove.\(candidate.deviceID)")
                .confirmationDialog("Remove device \(String(candidate.deviceID)) from your account?",
                                    isPresented: Binding(get: { removing?.id == candidate.id }, set: { if !$0 { removing = nil } }),
                                    titleVisibility: .visible) {
                    Button("Remove from Account", role: .destructive) { Task { await model.removeOwnDevice(candidate) } }
                } message: { Text(OwnDeviceReview.removalMessage) }
            }
        }
    }
}

/// What became of a device, in the words the Devices page uses.
private struct OutcomeLabel: View {
    let outcome: OwnDeviceOutcome

    var body: some View {
        let (symbol, text, color): (String, String, Color) = switch outcome {
        case .removed: (EncryptionDevice.removedSymbol, "Removed", .secondary)
        case .decided(let trust):
            (trust.badge.symbol, trust == .accepted ? "Trusted · not verified" : trust == .rejected ? "Not trusted" : trust.badge.text, trust.badge.color)
        }
        HStack(spacing: 4) {
            Image(systemName: symbol)
            Text(text)
        }
        .font(.footnote.weight(.semibold)).foregroundStyle(color)
    }
}
