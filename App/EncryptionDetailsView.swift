import SwiftUI
import OMEMO
import XMPPProtocol

struct EncryptionDetailsView: View {
    @Bindable var model: AppModel
    let chatID: String
    @Environment(\.dismiss) private var dismiss
    @State private var selectedDevice: EncryptionDevice?
    @State private var confirmingRetirement = false
    @State private var confirmingRepair = false

    var body: some View {
        NavigationStack {
            List {
                Section {
                    Label("Only approved devices can receive your new messages.", systemImage: "lock.shield")
                        .font(.subheadline)
                    Text("Compare fingerprints through another trusted channel to verify a device. Accepting without comparison enables encryption, but does not verify who owns the key.")
                        .font(.footnote).foregroundStyle(.secondary)
                }
                if let overview = model.encryptionOverview {
                    if overview.hasIncompatibleDevices {
                        Section { Label("Some devices only support the other encryption version. Sending is paused so they are not silently left out.", systemImage: "exclamationmark.shield").font(.subheadline) }
                    }
                    Section("Their devices") { devices(overview.devices.filter { $0.jid == chatID && $0.jid != model.accountID }) }
                    Section("Your other devices") { devices(overview.devices.filter { $0.jid == model.accountID }) }
                    Section("This device") {
                        LabeledContent("Device", value: String(overview.localDeviceID))
                        fingerprint(overview.localFingerprint)
                    }
                    Section {
                        Picker("Encryption version", selection: Binding(get: { overview.profile }, set: { profile in
                            Task { await model.loadEncryptionDetails(for: chatID, profile: profile) }
                        })) {
                            Text("OMEMO · compatible").tag(XMPPOMEMOProfile.legacy)
                            Text("OMEMO 2").tag(XMPPOMEMOProfile.modern)
                        }
                        .disabled(!model.isConnected)
                    } footer: {
                        Text("Devices using different versions may not receive the same message. Changing the version requires reviewing its devices again. Messages already encrypted keep their original version.")
                    }
                } else {
                    Section { Text(model.encryptionStatus).foregroundStyle(.secondary) }
                }
            }
            .navigationTitle("Encryption")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done", systemImage: "checkmark") { dismiss() }.labelStyle(.iconOnly)
                }
                ToolbarItem(placement: .topBarLeading) {
                    Button("Refresh devices", systemImage: "arrow.clockwise") {
                        Task { await model.loadEncryptionDetails(for: chatID) }
                    }.labelStyle(.iconOnly).disabled(!model.isConnected)
                }
            }
            .sheet(item: $selectedDevice) { device in
                NavigationStack {
                    List {
                        Section {
                            Text(device.jid).font(.headline)
                            LabeledContent("Device", value: String(device.deviceID))
                            if device.identityChanged {
                                Label("This device’s identity changed", systemImage: "exclamationmark.shield")
                                    .foregroundStyle(.orange)
                            }
                            fingerprint(device.fingerprint)
                        } header: { Text("Compare this fingerprint") }
                        Section {
                            Button("Fingerprints match · verify", systemImage: "checkmark.shield") { setTrust(.verified, device: device) }
                            Button("Accept without verifying", systemImage: "lock") { setTrust(.accepted, device: device) }
                            Button("Block this device", systemImage: "hand.raised", role: .destructive) { setTrust(.rejected, device: device) }
                        } footer: { Text("A blocked device will be excluded from new encrypted messages. Previous messages cannot be recalled.") }
                        .disabled(!device.active)
                        if device.active && device.trust.permitsEncryption {
                            Section {
                                Button("Repair encryption session", systemImage: "arrow.trianglehead.2.clockwise.rotate.90") { confirmingRepair = true }
                                    .disabled(!model.isConnected)
                            } footer: {
                                Text("Use this if messages from this device cannot be opened. Your fingerprint and saved messages stay the same.")
                            }
                        }
                        if device.active && device.jid == model.accountID {
                            Section {
                                Button("Remove old device", systemImage: "iphone.slash", role: .destructive) { confirmingRetirement = true }
                                    .disabled(!model.isConnected)
                            } footer: {
                                Text("Remove a device you no longer use. Sign out on that device first, or it may advertise itself again.")
                            }
                        }
                    }
                    .navigationTitle("Device fingerprint").navigationBarTitleDisplayMode(.inline)
                    .toolbar { ToolbarItem(placement: .cancellationAction) { Button("Close", systemImage: "xmark") { selectedDevice = nil }.labelStyle(.iconOnly) } }
                    .confirmationDialog("Repair this encryption session?", isPresented: $confirmingRepair, titleVisibility: .visible) {
                        Button("Repair session") {
                            selectedDevice = nil
                            Task { await model.repairDeviceSession(device, chatID: chatID) }
                        }
                    } message: { Text("This starts a fresh session with the approved fingerprint. It cannot recover messages whose original keys are no longer available.") }
                    .confirmationDialog("Remove this old device?", isPresented: $confirmingRetirement, titleVisibility: .visible) {
                        Button("Remove device", role: .destructive) {
                            selectedDevice = nil
                            Task { await model.retireDevice(device, chatID: chatID) }
                        }
                    } message: { Text("It will be removed from your account’s advertised encryption devices. Previous messages cannot be recalled.") }
                }
            }
        }
    }

    @ViewBuilder private func devices(_ devices: [EncryptionDevice]) -> some View {
        if devices.isEmpty { Text("No other devices found").foregroundStyle(.secondary) }
        ForEach(devices) { device in
            Button { selectedDevice = device } label: {
                HStack(spacing: 12) {
                    Image(systemName: device.trust == .verified ? "checkmark.shield" : "iphone")
                        .frame(width: 24).foregroundStyle(.secondary)
                    VStack(alignment: .leading, spacing: 4) {
                        Text("Device \(String(device.deviceID))").foregroundStyle(.primary)
                        Text(status(device)).font(.caption).foregroundStyle(.secondary)
                    }
                    Spacer()
                    if device.trust == .undecided && device.active { Image(systemName: "circle.fill").font(.system(size: 7)).foregroundStyle(.orange) }
                }.padding(.vertical, 3)
            }
            .buttonStyle(.plain)
            .accessibilityIdentifier("encryptionDevice.\(device.deviceID)")
        }
    }
    private func status(_ device: EncryptionDevice) -> String {
        if !device.active { return "No longer advertised" }
        if device.identityChanged && device.trust == .undecided { return "Identity changed · review required" }
        switch device.trust {
        case .undecided: return "Review required"
        case .accepted: return "Accepted · not verified"
        case .verified: return "Verified"
        case .rejected: return "Blocked"
        }
    }
    private func fingerprint(_ value: String) -> some View {
        Text(stride(from: 0, to: value.count, by: 8).map { offset in
            String(value.dropFirst(offset).prefix(8))
        }.joined(separator: " "))
        .font(.system(.footnote, design: .monospaced)).textSelection(.enabled)
        .accessibilityLabel("Fingerprint \(value)")
    }
    private func setTrust(_ trust: DeviceTrust, device: EncryptionDevice) {
        selectedDevice = nil
        Task { await model.setDeviceTrust(device, trust: trust, chatID: chatID) }
    }
}
