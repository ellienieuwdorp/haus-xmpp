import OMEMO
import SwiftUI

// Later hides it until what waits changes.
struct MacDeviceReviewBanner: View {
    @Bindable var model: AppModel
    let chatID: String
    let title: String
    @State private var dismissed = false
    @State private var reviewing = false

    private var isGroup: Bool { model.isGroup(chatID) }
    // An undecided device in the version this chat sends with, or a send held for a decision.
    private var sendingWaits: Bool { model.chatCapabilities(chatID).encryption == .needsReview }
    // Messages from a device in the other version are held until it is decided.
    private var readingWaits: Bool { !isGroup && model.encryptionOverview(for: chatID)?.needsIncomingReview == true }
    private var waiting: [EncryptionDevice] { MacDeviceReviewSheet.waiting(model: model, chatID: chatID) }
    private var shows: Bool { !model.isDemo && (sendingWaits || readingWaits) && !dismissed }

    // Every device sending waits for is the account's.
    private var ownDevicesOnly: Bool {
        guard let profile = model.encryptionOverview(for: chatID)?.profile else { return false }
        let sending = waiting.filter { $0.profile == profile }
        return !sending.isEmpty && sending.allSatisfy { $0.jid == model.accountID }
    }

    var body: some View {
        // Always in the hierarchy, so the sheet stays open when the last decision takes the banner away.
        VStack(spacing: 0) {
            if shows { card }
        }
        .onChange(of: [sendingWaits, readingWaits]) { dismissed = false }
        .onChange(of: waiting.map(\.id)) { dismissed = false }
        .sheet(isPresented: $reviewing) {
            MacDeviceReviewSheet(model: model, chatID: chatID, title: title)
                .frame(minWidth: 480, idealWidth: 520, minHeight: 520, idealHeight: 640)
                .themedRoot()
        }
    }

    private var card: some View {
        // Beside the text while it keeps a readable column, under it in a narrow conversation.
        ViewThatFits(in: .horizontal) {
            HStack(alignment: .center, spacing: 12) {
                icon
                message.frame(minWidth: 0, idealWidth: 280, maxWidth: .infinity, alignment: .leading)
                buttons
            }
            VStack(alignment: .leading, spacing: 10) {
                HStack(alignment: .top, spacing: 12) {
                    icon
                    message.frame(maxWidth: .infinity, alignment: .leading)
                }
                HStack {
                    Spacer(minLength: 0)
                    buttons
                }
            }
        }
        .padding(.horizontal, 14).padding(.vertical, 10)
        // On the timeline's own background, so no message scrolling under the banner shows through the tint.
        .background(.orange.opacity(0.12), in: RoundedRectangle(cornerRadius: 10, style: .continuous))
        .background(Color(nsColor: .textBackgroundColor), in: RoundedRectangle(cornerRadius: 10, style: .continuous))
        .padding(.horizontal, 16).padding(.top, 8)
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("deviceReview.card")
    }

    private var icon: some View {
        Image(systemName: "exclamationmark.shield")
            .font(.system(size: 15, weight: .semibold)).foregroundStyle(.orange)
            .frame(width: 30, height: 30).background(.orange.opacity(0.15), in: Circle())
            .accessibilityHidden(true)
    }

    private var message: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(ChatDeviceReview.headline(sendingWaits: sendingWaits, isGroup: isGroup, ownDevicesOnly: ownDevicesOnly, title: title))
                .font(.callout.weight(.semibold))
            Text(ChatDeviceReview.explanation(sendingWaits: sendingWaits))
                .font(.callout).foregroundStyle(.secondary)
        }
    }

    private var buttons: some View {
        HStack(spacing: 8) {
            Button("Later") { withAnimation { dismissed = true } }
                .accessibilityIdentifier("deviceReview.later")
            Button("Review…") { reviewing = true }
                .buttonStyle(.borderedProminent)
                .accessibilityIdentifier("deviceReview.open")
        }
        .fixedSize()
    }
}

// A decision covers one device's key in one version and applies to every chat it is in; nothing is decided for
// several devices at once.
struct MacDeviceReviewSheet: View {
    @Bindable var model: AppModel
    let chatID: String
    let title: String
    @Environment(\.dismiss) private var dismiss
    // So a decided device stays with its outcome until the sheet closes.
    @State private var shown: [EncryptionDevice] = []
    // By fingerprint-scoped ID, for devices the chat stops listing once decided.
    @State private var decided: [String: DeviceTrust] = [:]
    @State private var rejecting: EncryptionDevice?
    @State private var comparing: EncryptionDevice?

    private var isGroup: Bool { model.isGroup(chatID) }
    private var stored: [EncryptionDevice] { Self.stored(model: model, chatID: chatID) }

    static func stored(model: AppModel, chatID: String) -> [EncryptionDevice] {
        model.groupChats[chatID]?.devices ?? model.encryptionOverview(for: chatID)?.devices ?? []
    }

    static func waiting(model: AppModel, chatID: String) -> [EncryptionDevice] {
        ChatDeviceReview.devices(stored(model: model, chatID: chatID), account: model.accountID, isGroup: model.isGroup(chatID))
    }

    var body: some View {
        NavigationStack {
            GroupedList {
                Section { hero }
                if shown.isEmpty {
                    Section {
                        Text("No device of this chat waits for a decision now. Devices & Encryption lists all of them.")
                            .foregroundStyle(.secondary)
                    }
                }
                ForEach(shown) { device in section(for: device) }
                Section {
                    Button("Show All Devices…", systemImage: "lock.shield") {
                        dismiss()
                        model.requestRoute(isGroup ? .groupDetails(chatID) : .encryption(chatID))
                    }
                    .listRowButton()
                    .accessibilityIdentifier("deviceReview.allDevices")
                }
            }
            .navigationTitle("Review Devices")
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Done") { dismiss() } }
            }
            .sheet(item: $comparing) { device in
                DeviceFingerprintSheet(model: model, chatID: chatID, device: current(device), name: name(of: device),
                                       rejectionMessage: ChatDeviceReview.rejectionMessage(for: device, account: model.accountID, isGroup: isGroup)) { trust in
                    comparing = nil
                    decide(device, trust)
                }
                .themedRoot()
            }
        }
        .onAppear { shown = Self.waiting(model: model, chatID: chatID) }
        .onChange(of: Self.waiting(model: model, chatID: chatID).map(\.id)) { _, _ in
            // A device that starts waiting while the sheet is open joins the list; decided ones stay.
            shown += Self.waiting(model: model, chatID: chatID).filter { device in !shown.contains { $0.id == device.id } }
        }
        // The root's alert cannot show over this sheet; a failed decision is reported here.
        .alert("Something needs attention", isPresented: Binding(
            get: { model.error != nil }, set: { if !$0 { model.error = nil } }
        )) {
            Button("OK") { model.error = nil }
        } message: { Text(model.error ?? "") }
        .allowsQuitWhileOpen()
    }

    private var hero: some View {
        VStack(spacing: 6) {
            Image(systemName: "exclamationmark.shield")
                .font(.system(size: 24, weight: .medium)).foregroundStyle(.orange)
                .frame(width: 52, height: 52)
                .background(.orange.opacity(0.15), in: Circle())
                .accessibilityHidden(true)
            Text("Do you recognize \(shown.count == 1 ? "this device" : "these devices")?")
                .font(.title3.bold()).multilineTextAlignment(.center).padding(.top, 4)
            Text(guidance)
                .font(.callout).foregroundStyle(.secondary).multilineTextAlignment(.center)
        }
        .frame(maxWidth: .infinity).padding(.vertical, 4)
    }

    private var guidance: String {
        let own = shown.contains { $0.jid == model.accountID }, others = shown.contains { $0.jid != model.accountID }
        let subject = shown.count == 1 ? "the fingerprint" : "each fingerprint"
        if isGroup { return "Compare \(subject) with the one shown on that member’s device. Trust only devices you recognize." }
        if own && !others { return "Compare \(subject) with the one shown on your other device. Trust only devices you know are yours." }
        if own { return "Compare each fingerprint with the one \(title) reads out from their device, or the one shown on your other device. Trust only devices you recognize." }
        return "Compare \(subject) with the one \(title) reads out from their device. Trust only devices you recognize."
    }

    // Trust may have changed since the list was made; a device no longer listed gets the decision saved here.
    private func current(_ device: EncryptionDevice) -> EncryptionDevice {
        if let record = stored.first(where: { $0.id == device.id }) { return record }
        var listed = device
        if let trust = decided[device.id] { listed.trust = trust }
        return listed
    }

    private func name(of device: EncryptionDevice) -> String? {
        device.jid == model.accountID ? nil : isGroup ? String(device.jid.prefix { $0 != "@" }) : title
    }

    private func owner(of device: EncryptionDevice) -> String {
        device.jid == model.accountID ? "Your account" : isGroup ? device.jid : "\(title)’s device"
    }

    // A device ID can be listed once per version (its OMEMO 2 record holding messages while the chat sends legacy), so
    // the spoken label and the key name the version too.
    private func spoken(_ device: EncryptionDevice) -> String { "\(String(device.deviceID)), \(device.profile.label)" }
    private func key(_ device: EncryptionDevice) -> String { "\(device.deviceID).\(device.profile.rawValue)" }

    private func decide(_ device: EncryptionDevice, _ trust: DeviceTrust) {
        let record = current(device)
        Task { if await model.setDeviceTrust(record, trust: trust, chatID: chatID) { decided[record.id] = trust } }
    }

    @ViewBuilder private func section(for listed: EncryptionDevice) -> some View {
        let device = current(listed)
        let outcome = ChatDeviceReview.outcome(of: listed, in: stored, decided: decided, account: model.accountID, isGroup: isGroup)
        // A group waits on another member's blocked device too; it can only be trusted from here.
        let blocked = outcome == nil && device.trust == .rejected
        let readingOnly = !isGroup && model.encryptionOverview(for: chatID).map { device.profile != $0.profile } == true
        Section {
            VStack(alignment: .leading, spacing: 10) {
                HStack(alignment: .firstTextBaseline) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Device \(String(device.deviceID))").font(.headline)
                        Text("\(owner(of: device)) · \(device.profile.label)").font(.footnote).foregroundStyle(.secondary)
                    }
                    Spacer(minLength: 8)
                    if let outcome { OutcomeLabel(outcome: .decided(outcome)) }
                }
                if outcome == nil {
                    // Plain HStacks, not Labels: in a form row a Label pads its icon column to body metrics.
                    if device.identityChanged {
                        note("exclamationmark.shield", "Its identity changed since you last reviewed it", color: .orange)
                    } else if blocked {
                        note("hand.raised", "Blocked · sending to this group is paused", color: .red)
                    } else if readingOnly {
                        note("envelope.badge", "Holds messages sent to you with \(device.profile.label)", color: .secondary)
                    }
                }
                FingerprintGrid(value: device.fingerprint, font: .system(.footnote, design: .monospaced))
                    .padding(.vertical, 4)
                if outcome == nil {
                    HStack(spacing: 10) {
                        if !blocked {
                            Button(role: .destructive) { rejecting = listed } label: { Text("Don’t Trust").frame(maxWidth: .infinity) }
                                .secondaryActionStyle().foregroundStyle(.red)
                                .accessibilityLabel("Don’t trust device \(spoken(device))")
                                .accessibilityIdentifier("deviceReview.reject.\(key(device))")
                                // Anchored to its button, so the dialog points at the device it decides.
                                .confirmationDialog("Don’t trust device \(String(device.deviceID))?",
                                                    isPresented: Binding(get: { rejecting?.id == listed.id }, set: { if !$0 { rejecting = nil } }),
                                                    titleVisibility: .visible) {
                                    Button("Don’t Trust", role: .destructive) { decide(listed, .rejected) }
                                } message: { Text(ChatDeviceReview.rejectionMessage(for: device, account: model.accountID, isGroup: isGroup)) }
                        }
                        Button { decide(listed, .accepted) } label: { Text("Trust").frame(maxWidth: .infinity) }
                            .prominentActionStyle()
                            .accessibilityLabel("Trust device \(spoken(device))")
                            .accessibilityIdentifier("deviceReview.trust.\(key(device))")
                    }
                    .controlSize(.large)
                }
            }
            .padding(.vertical, 4)
            if outcome == nil || outcome == .accepted {
                Button { comparing = listed } label: {
                    HStack {
                        Label("Compare Fingerprints…", systemImage: "checkmark.shield")
                        Spacer()
                        Image(systemName: "chevron.right").font(.footnote.weight(.semibold)).foregroundStyle(.tertiary)
                    }
                    .contentShape(Rectangle())
                }
                .listRowButton()
                .accessibilityLabel("Compare fingerprints of device \(spoken(device))")
                .accessibilityIdentifier("deviceReview.compare.\(key(device))")
            }
        }
    }

    private func note(_ symbol: String, _ text: String, color: Color) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 6) {
            Image(systemName: symbol)
            Text(text)
        }
        .font(.footnote.weight(.semibold)).foregroundStyle(color)
    }
}
