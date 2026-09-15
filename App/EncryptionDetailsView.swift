import SwiftUI
import OMEMO
import XMPPProtocol

struct EncryptionDetailsView: View {
    @Bindable var model: AppModel
    let chatID: String
    @Environment(\.dismiss) private var dismiss
    @State private var selectedDevice: EncryptionDevice?
    private var name: String { AppModel.displayName(for: chatID, title: model.chats.first { $0.id == chatID }?.title) }

    var body: some View {
        NavigationStack {
            List {
                if let overview = model.encryptionOverview {
                    if overview.hasIncompatibleDevices {
                        Section { Label("Some devices only support the other encryption version. Sending is paused so they are not silently left out.", systemImage: "exclamationmark.shield").font(.subheadline) }
                    }
                    Section {
                        devices(overview.devices.filter { $0.jid == chatID && $0.jid != model.accountID })
                    } header: { Text("\(name)’s devices") } footer: { Text("Approve each device before your messages reach it.") }
                    Section("Your other devices") { devices(overview.devices.filter { $0.jid == model.accountID }) }
                    Section {
                        VStack(alignment: .leading, spacing: 6) {
                            LabeledContent("Device", value: String(overview.localDeviceID))
                            FingerprintGrid(value: overview.localFingerprint, font: .system(.footnote, design: .monospaced))
                        }
                        Picker("Encryption version", selection: Binding(get: { overview.profile }, set: { profile in
                            Task { await model.loadEncryptionDetails(for: chatID, profile: profile) }
                        })) {
                            Text("OMEMO · compatible").tag(XMPPOMEMOProfile.legacy)
                            Text("OMEMO 2").tag(XMPPOMEMOProfile.modern)
                        }
                        .disabled(!model.isConnected)
                    } header: { Text("This iPhone") } footer: { Text("Changing the version means reviewing its devices again.") }
                } else {
                    Section { Text(model.encryptionStatus).foregroundStyle(.secondary) }
                }
            }
            .navigationTitle("Devices & Encryption")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) { Button("Done") { dismiss() } }
                ToolbarItem(placement: .topBarLeading) {
                    Button("Refresh devices", systemImage: "arrow.clockwise") {
                        Task { await model.loadEncryptionDetails(for: chatID) }
                    }.labelStyle(.iconOnly).disabled(!model.isConnected)
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
    }

    @ViewBuilder private func devices(_ devices: [EncryptionDevice]) -> some View {
        if devices.isEmpty { Text("No other devices found").foregroundStyle(.secondary) }
        ForEach(devices) { device in
            Button { selectedDevice = device } label: { DeviceRow(device: device) }
                .buttonStyle(.plain)
                .accessibilityIdentifier("encryptionDevice.\(device.deviceID)")
        }
    }
}

// MARK: - Shared device presentation (also used by GroupDetailsView)

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
    var badge: DeviceBadge {
        switch trust {
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
                .background(Color(.tertiarySystemFill), in: Circle())
            VStack(alignment: .leading, spacing: 2) {
                Text("Device \(String(device.deviceID))").foregroundStyle(.primary)
                Label(status ?? device.reviewStatus, systemImage: device.active ? device.badge.symbol : "iphone.slash")
                    .font(.footnote.weight(.semibold))
                    .foregroundStyle(device.active ? device.badge.color : .secondary)
            }
            Spacer(minLength: 8)
            Image(systemName: "chevron.right").font(.footnote.weight(.semibold)).foregroundStyle(.tertiary)
        }
        .frame(minHeight: 44)
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
                GridRow { ForEach(groups[start..<min(start + 4, groups.count)], id: \.self) { Text($0) } }
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
    let review: (DeviceTrust) -> Void
    @Environment(\.dismiss) private var dismiss
    @State private var confirmingRepair = false
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
                Section {
                    VStack(spacing: 10) {
                        Button { review(.verified) } label: {
                            Label("Fingerprints match · verify", systemImage: "checkmark.shield").frame(maxWidth: .infinity)
                        }
                        .buttonStyle(.glassProminent)
                        Button { review(.accepted) } label: {
                            Text("Accept without verifying").frame(maxWidth: .infinity)
                        }
                        .buttonStyle(.glass)
                    }
                    .fontWeight(.semibold).controlSize(.large)
                }
                .listRowBackground(Color.clear).listRowInsets(EdgeInsets())
                .disabled(!device.active)
                Section {
                    Button("Block this device", systemImage: "hand.raised", role: .destructive) { review(.rejected) }
                } footer: {
                    Text(device.active ? "Blocked devices are left out of new messages." : "No longer advertised. Its fingerprint is read-only.")
                }
                .disabled(!device.active)
                if allowsMaintenance && device.active && device.trust.permitsEncryption {
                    Section {
                        Button("Repair encryption session", systemImage: "arrow.trianglehead.2.clockwise.rotate.90") { confirmingRepair = true }
                            .disabled(!model.isConnected)
                    } footer: { Text("Use this if messages from this device cannot be opened.") }
                }
                if allowsMaintenance && device.active && device.jid == model.accountID {
                    Section {
                        Button("Remove old device", systemImage: "iphone.slash", role: .destructive) { confirmingRetirement = true }
                            .disabled(!model.isConnected)
                    } footer: { Text("Sign out on that device first, or it may advertise itself again.") }
                }
            }
            .navigationTitle("Device \(String(device.deviceID))")
            .navigationSubtitle(device.jid)
            .navigationBarTitleDisplayMode(.inline)
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
