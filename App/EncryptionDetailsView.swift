import SwiftUI
import OMEMO
import XMPPProtocol

struct EncryptionDetailsView: View {
    @Bindable var model: AppModel
    let chatID: String
    @State private var selectedDevice: EncryptionDevice?
    private var name: String { AppModel.displayName(for: chatID, title: model.chats.first { $0.id == chatID }?.title) }

    var body: some View {
        List {
            if let overview = model.encryptionOverview(for: chatID) {
                if overview.hasIncompatibleDevices {
                    Section { Label(otherVersionNotice(overview), systemImage: "info.circle").font(.subheadline) }
                }
                let waiting = overview.devices.filter { $0.profile != overview.profile }
                if !waiting.isEmpty {
                    // Incoming messages decrypt in the version they were sent in; this device's are held until it is reviewed.
                    Section {
                        devices(waiting, owner: chatID, identifier: "waitingDevice")
                    } header: { Text("Messages waiting · \(waiting[0].profile.label)") } footer: {
                        Text("Approve to read what \(waiting.contains { $0.jid != model.accountID } ? name : "your other device") sent with \(waiting[0].profile.label). You keep sending with \(overview.profile.label).")
                    }
                }
                Section {
                    devices(overview.devices.filter { $0.jid == chatID && $0.jid != model.accountID && $0.profile == overview.profile }, owner: chatID)
                } header: { Text("\(name)’s devices") } footer: { Text("Approve each device before your messages reach it.") }
                Section("Your other devices") { devices(overview.devices.filter { $0.jid == model.accountID && $0.profile == overview.profile }, owner: model.accountID) }
                Section {
                    VStack(alignment: .leading, spacing: 6) {
                        LabeledContent("Device", value: String(overview.localDeviceID))
                        FingerprintGrid(value: overview.localFingerprint, font: .system(.footnote, design: .monospaced))
                    }
                    Picker("Encryption version", selection: Binding(get: { overview.profile }, set: { profile in
                        Task { await model.loadEncryptionDetails(for: chatID, profile: profile) }
                    })) {
                        Text(XMPPOMEMOProfile.legacy.label).tag(XMPPOMEMOProfile.legacy)
                        Text(XMPPOMEMOProfile.modern.label).tag(XMPPOMEMOProfile.modern)
                    }
                    .disabled(!model.session.isReady)
                } header: { Text("This \(ThisDevice.noun)") } footer: {
                    Text(model.encryptionDiagnostics.isEmpty ? "Changing the version means reviewing its devices again." : "Changing the version means reviewing its devices again.\n\n\(model.encryptionDiagnostics)")
                        .textSelection(.enabled)
                }
            } else {
                // The store read takes milliseconds; a refresh problem shows in the footer once the list is there.
                // Sample data has no store to read, so it would otherwise say "Loading" forever.
                let unreadable = model.encryptionDiagnostics == AppModel.storedDevicesUnreadable
                let text = model.isDemo ? "Sample conversations have no encryption devices." : unreadable ? AppModel.storedDevicesUnreadable : "Loading stored devices…"
                Section { Text(text).foregroundStyle(.secondary) }
            }
        }
        // Stored devices at once; the server is asked at most once per connection unless Refresh is tapped.
        .task { await model.loadEncryptionDetails(for: chatID) }
        .navigationTitle("Devices & Encryption")
        .inlineNavigationTitle()
        .toolbar {
            ToolbarItem(placement: .barTrailing) {
                Button("Refresh devices", systemImage: "arrow.clockwise") {
                    Task { await model.loadEncryptionDetails(for: chatID, force: true) }
                }.labelStyle(.iconOnly).disabled(!model.session.isReady)
            }
        }
        .sheet(item: $selectedDevice) { device in
            DeviceFingerprintSheet(model: model, chatID: chatID, device: device,
                                   name: device.jid == model.accountID ? nil : name, allowsMaintenance: true) { trust in
                selectedDevice = nil
                Task { await model.setDeviceTrust(device, trust: trust, chatID: chatID) }
            }
        }
    }

    /// Which devices will not receive messages in the selected version because they publish keys only in the other one.
    private func otherVersionNotice(_ overview: EncryptionOverview) -> String {
        func count(_ owner: String, _ label: String) -> String? {
            let value = overview.otherVersionOnlyDevices[owner] ?? 0
            return value > 0 ? "\(value) of \(label) devices" : nil
        }
        let parts = [count(model.accountID, "your"), count(chatID, "\(name)’s")].compactMap { $0 }
        let subject = parts.isEmpty ? "Some devices" : parts.joined(separator: " and ")
        return "\(subject) only support the other encryption version and won’t receive these messages. Messages still go to the devices listed here; switch the version below to reach the others instead."
    }

    /// Why a contact has nothing to review: keys missing on the server, or a list their server does not show us.
    private func emptyExplanation(for owner: String) -> String {
        let missing = model.encryptionOverview(for: chatID)?.unavailableDevices[owner] ?? 0
        if missing > 0 {
            return "\(missing) advertised \(missing == 1 ? "device has" : "devices have") no published keys. Ask them to open their chat app so it republishes them."
        }
        if owner == model.accountID { return "No other devices found" }
        return "No encryption devices are published for this address in this version. Try the other encryption version below, or ask them to open their app so it publishes keys. Nothing is ever sent unencrypted."
    }

    /// `identifier` prefixes each row's accessibility identifier; a device ID can appear once per version.
    @ViewBuilder private func devices(_ devices: [EncryptionDevice], owner: String, identifier: String = "encryptionDevice") -> some View {
        if devices.isEmpty { Text(emptyExplanation(for: owner)).foregroundStyle(.secondary) }
        ForEach(devices) { device in
            Button { selectedDevice = device } label: { DeviceRow(device: device) }
                .buttonStyle(.plain)
                .accessibilityIdentifier("\(identifier).\(device.deviceID)")
        }
    }
}

// MARK: - Shared device presentation (also used by GroupDetailsView)

extension XMPPOMEMOProfile {
    /// The version's name wherever a person chooses or reads it.
    var label: String { self == .legacy ? "OMEMO · compatible" : "OMEMO 2" }
}

struct DeviceBadge {
    let text: String
    let symbol: String
    let color: Color
}

extension EncryptionDevice {
    /// Secondary row text. Tests read "Review required" and "Accepted · not verified" verbatim.
    var reviewStatus: String {
        if !active { return "No longer advertised" }
        if identityChanged && trust == .undecided { return "Identity changed · review required" }
        switch trust {
        case .undecided: return "Review required"
        case .accepted: return "Accepted · not verified"
        case .verified: return "Verified"
        case .rejected: return "Blocked"
        }
    }
    /// Trailing coloured status label; doubles as the fingerprint sheet's hero glyph.
    var badge: DeviceBadge { trust.badge }
}

extension DeviceTrust {
    var badge: DeviceBadge {
        switch self {
        case .verified: DeviceBadge(text: "Verified", symbol: "checkmark.shield", color: .green)
        case .accepted: DeviceBadge(text: "Accepted", symbol: "lock", color: .secondary)
        case .rejected: DeviceBadge(text: "Blocked", symbol: "hand.raised", color: .red)
        case .undecided: DeviceBadge(text: "Needs review", symbol: "exclamationmark.shield", color: .orange)
        }
    }
}

struct DeviceRow: View {
    let device: EncryptionDevice
    var status: String? = nil

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: "iphone")
                .font(.system(size: 18)).foregroundStyle(.secondary)
                .frame(width: 36, height: 36)
                .background(Color.tertiaryFill, in: Circle())
            Text("Device \(String(device.deviceID))").foregroundStyle(.primary)
            Spacer(minLength: 8)
            // A plain HStack, not a Label: List pads a Label's icon column to body metrics and leaves a gap.
            HStack(spacing: 4) {
                Image(systemName: device.active ? device.badge.symbol : "iphone.slash")
                Text(status ?? device.reviewStatus).multilineTextAlignment(.trailing)
            }
            .font(.footnote.weight(.semibold))
            .foregroundStyle(device.active ? device.badge.color : .secondary)
            .layoutPriority(1)
            Image(systemName: "chevron.right").font(.footnote.weight(.semibold)).foregroundStyle(.tertiary)
        }
        .frame(minHeight: 44)
        // The Spacer is not hittable on its own under a plain button style: the whole row is the target.
        .contentShape(Rectangle())
    }
}

/// Fingerprint as 8-character monospace groups in four columns.
struct FingerprintGrid: View {
    let value: String
    var font: Font = .system(size: 15, design: .monospaced)

    var body: some View {
        let groups = stride(from: 0, to: value.count, by: 8).map { String(value.dropFirst($0).prefix(8)) }
        Grid(horizontalSpacing: 8, verticalSpacing: 12) {
            ForEach(Array(stride(from: 0, to: groups.count, by: 4)), id: \.self) { start in
                GridRow { ForEach(groups[start..<min(start + 4, groups.count)], id: \.self) { Text($0).lineLimit(1).minimumScaleFactor(0.7) } }
            }
        }
        .font(font).frame(maxWidth: .infinity).textSelection(.enabled)
        .accessibilityElement(children: .ignore).accessibilityLabel("Fingerprint \(value)")
    }
}

struct DeviceFingerprintSheet: View {
    @Bindable var model: AppModel
    let chatID: String
    let device: EncryptionDevice
    /// Who to compare with; nil for one of your own devices.
    let name: String?
    /// Repair / remove rows, offered on 1:1 chats only.
    var allowsMaintenance = false
    /// The versions the decision applies to, when it covers more than `device` (the account-level review).
    var versions: String? = nil
    /// When set, Block asks first with this explanation, as the account-level review's Don't Trust does.
    var rejectionMessage: String? = nil
    let review: (DeviceTrust) -> Void
    @Environment(\.dismiss) private var dismiss
    @State private var confirmingRepair = false
    @State private var confirmingRejection = false
    @State private var confirmingRetirement = false

    var body: some View {
        NavigationStack {
            List {
                Section {
                    VStack(spacing: 6) {
                        Image(systemName: device.badge.symbol)
                            .font(.system(size: 30, weight: .medium)).foregroundStyle(device.badge.color)
                            .frame(width: 64, height: 64)
                            .background(device.badge.color.opacity(0.15), in: Circle())
                        Text("Compare fingerprints").font(.title2.bold()).padding(.top, 6)
                        Text(name.map { "Ask \($0) to read theirs out loud." } ?? "Compare with the fingerprint shown on that device.")
                            .font(.subheadline).foregroundStyle(.secondary).multilineTextAlignment(.center)
                        if device.identityChanged {
                            Label("This device’s identity changed", systemImage: "exclamationmark.shield")
                                .font(.subheadline).foregroundStyle(.orange)
                        }
                    }
                    .frame(maxWidth: .infinity).padding(.vertical, 8)
                }
                .listRowBackground(Color.clear)
                Section { FingerprintGrid(value: device.fingerprint).padding(.vertical, 8) }
                // One button per row: a List row forwards taps to a single control.
                Section {
                    Button { review(.verified) } label: {
                        HStack(spacing: 8) {
                            Image(systemName: "checkmark.shield")
                            Text("Fingerprints match · verify")
                        }
                        .frame(maxWidth: .infinity)
                    }
                    .buttonStyle(.glassProminent)
                    .frame(maxWidth: .infinity)
                    .listRowBackground(Color.clear).listRowInsets(EdgeInsets(top: 0, leading: 0, bottom: 10, trailing: 0)).listRowSeparator(.hidden)
                    Button { review(.accepted) } label: {
                        Text("Accept without verifying").frame(maxWidth: .infinity)
                    }
                    .buttonStyle(.glass)
                    .frame(maxWidth: .infinity)
                    .listRowBackground(Color.clear).listRowInsets(EdgeInsets()).listRowSeparator(.hidden)
                }
                .fontWeight(.semibold).controlSize(.large)
                .disabled(!device.active)
                if allowsMaintenance && device.active && device.trust.permitsEncryption {
                    Section {
                        Button("Repair encryption session", systemImage: "arrow.trianglehead.2.clockwise.rotate.90") { confirmingRepair = true }
                            .disabled(!model.session.isReady)
                    } footer: { Text("Use this if messages from this device cannot be opened.") }
                }
                Section {
                    Button(role: .destructive) { if rejectionMessage == nil { review(.rejected) } else { confirmingRejection = true } } label: {
                        Label("Block this device", systemImage: "hand.raised").foregroundStyle(.red)
                    }
                    .disabled(!device.active)
                    // Anchored to its button, so the dialog's popover points at what it confirms.
                    .confirmationDialog("Don’t trust device \(String(device.deviceID))?", isPresented: $confirmingRejection, titleVisibility: .visible) {
                        Button("Don’t Trust", role: .destructive) { review(.rejected) }
                    } message: { Text(rejectionMessage ?? "") }
                    if allowsMaintenance && device.active && device.jid == model.accountID {
                        Button(role: .destructive) { confirmingRetirement = true } label: {
                            Label("Remove old device", systemImage: "iphone.slash").foregroundStyle(.red)
                        }
                        .disabled(!model.session.isReady)
                    }
                } footer: {
                    Text(device.active
                         ? (allowsMaintenance && device.jid == model.accountID
                            ? "Blocked devices are left out of new messages, and what they send is never opened. Removing an old device takes it off your account’s advertised devices; sign out on it first, or it may advertise itself again."
                            : "Blocked devices are left out of new messages, and what they send is never opened.")
                         : "No longer advertised. Its fingerprint is read-only.")
                }
            }
            .navigationTitle("Device \(String(device.deviceID))")
            // A device ID can publish in both versions, each with its own fingerprint encoding: name the one being compared.
            .navigationSubtitle("\(device.jid) · \(versions ?? device.profile.label)")
            .inlineNavigationTitle()
            .toolbar { ToolbarItem(placement: .cancellationAction) { Button("Close", systemImage: "xmark") { dismiss() }.labelStyle(.iconOnly) } }
            .confirmationDialog("Repair this encryption session?", isPresented: $confirmingRepair, titleVisibility: .visible) {
                Button("Repair session") {
                    dismiss()
                    Task { await model.repairDeviceSession(device, chatID: chatID) }
                }
            } message: { Text("This starts a fresh session with the approved fingerprint. It cannot recover messages whose original keys are no longer available.") }
            .confirmationDialog("Remove this old device?", isPresented: $confirmingRetirement, titleVisibility: .visible) {
                Button("Remove device", role: .destructive) {
                    dismiss()
                    Task { await model.retireDevice(device, chatID: chatID) }
                }
            } message: { Text("It will be removed from your account’s advertised encryption devices. Previous messages cannot be recalled.") }
        }
    }
}
