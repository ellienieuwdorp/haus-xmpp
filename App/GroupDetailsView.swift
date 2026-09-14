import SwiftUI
import OMEMO

struct GroupDetailsView: View {
    @Bindable var model: AppModel
    let room: String
    @Environment(\.dismiss) private var dismiss
    @State private var selectedDevice: EncryptionDevice?
    private var state: GroupChatState { model.groupChats[room] ?? GroupChatState() }

    var body: some View {
        NavigationStack {
            List {
                Section {
                    Text(room).font(.headline).textSelection(.enabled)
                    Label(state.status, systemImage: state.needsReview ? "exclamationmark.shield" : "lock.shield")
                        .font(.subheadline).foregroundStyle(.secondary)
                }
                ForEach(state.members, id: \.self) { member in
                    Section {
                        let devices = state.devices.filter { $0.jid == member }
                        if member == model.accountID, let deviceID = state.localDeviceID, let fingerprint = state.localFingerprint {
                            NavigationLink("This iPhone") { GroupLocalFingerprintView(deviceID: deviceID, fingerprint: fingerprint) }
                        } else if devices.isEmpty {
                            Text(member == model.accountID ? "This iPhone" : "No compatible devices found").foregroundStyle(.secondary)
                        }
                        ForEach(devices) { device in
                            Button { selectedDevice = device } label: {
                                HStack(spacing: 12) {
                                    Image(systemName: device.trust == .verified ? "checkmark.shield" : "iphone")
                                        .frame(width: 24).foregroundStyle(.secondary)
                                    VStack(alignment: .leading, spacing: 4) {
                                        Text("Device \(String(device.deviceID))").foregroundStyle(.primary)
                                        Text(status(device)).font(.caption).foregroundStyle(.secondary)
                                    }
                                }.frame(minHeight: 44, alignment: .leading)
                            }.buttonStyle(.plain).accessibilityIdentifier("groupDevice.\(device.deviceID)")
                        }
                    } header: { Text(member == model.accountID ? "You · \(member)" : member).textCase(nil) }
                }
                let previousDevices = state.devices.filter { !state.members.contains($0.jid) }
                if !previousDevices.isEmpty {
                    Section {
                        ForEach(previousDevices) { device in
                            Button { selectedDevice = device } label: {
                                VStack(alignment: .leading, spacing: 4) {
                                    Text(device.jid).foregroundStyle(.primary)
                                    Text("Device \(device.deviceID) · \(status(device))").font(.caption).foregroundStyle(.secondary)
                                }.frame(minHeight: 44, alignment: .leading)
                            }.buttonStyle(.plain).accessibilityIdentifier("groupDevice.\(device.deviceID)")
                        }
                    } header: { Text("Previous members") }
                    footer: { Text("Currently advertised devices can be reviewed for earlier messages. Retired keys require prior approval. Reviewing a previous member does not add them to current recipients.") }
                }
                Section {
                    Text("Everyone’s active devices must be approved. Blocking a device pauses sending to the whole group so nobody is silently left out.")
                        .font(.footnote).foregroundStyle(.secondary)
                }
            }
            .navigationTitle("Group details").navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done", systemImage: "checkmark") { dismiss() }.labelStyle(.iconOnly)
                }
                ToolbarItem(placement: .topBarLeading) {
                    Button("Refresh group", systemImage: "arrow.clockwise") { Task { await model.loadGroupDetails(room: room) } }
                        .labelStyle(.iconOnly).disabled(!model.isConnected)
                }
            }
            .sheet(item: $selectedDevice) { device in
                GroupFingerprintView(model: model, room: room, device: device)
            }
        }
        .task { await model.loadGroupDetails(room: room) }
    }

    private func status(_ device: EncryptionDevice) -> String {
        if !device.active { return "No longer advertised" }
        if device.identityChanged && device.trust == .undecided { return "Identity changed · review required" }
        switch device.trust {
        case .undecided: return "Review required"
        case .accepted: return "Accepted · not verified"
        case .verified: return "Verified"
        case .rejected: return "Blocked · group sending paused"
        }
    }
}

private struct GroupFingerprintView: View {
    @Bindable var model: AppModel
    let room: String
    let device: EncryptionDevice
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            List {
                Section {
                    Text(device.jid).font(.headline)
                    LabeledContent("Device", value: String(device.deviceID))
                    Text(stride(from: 0, to: device.fingerprint.count, by: 8).map {
                        String(device.fingerprint.dropFirst($0).prefix(8))
                    }.joined(separator: " "))
                    .font(.system(.footnote, design: .monospaced)).textSelection(.enabled)
                    .accessibilityLabel("Fingerprint \(device.fingerprint)")
                } header: { Text("Compare this fingerprint") }
                Section {
                    Button("Fingerprints match · verify", systemImage: "checkmark.shield") { review(.verified) }
                    Button("Accept without verifying", systemImage: "lock") { review(.accepted) }
                    Button("Block this device", systemImage: "hand.raised", role: .destructive) { review(.rejected) }
                } footer: { Text("Compare with this member over a channel you trust. Accepting without comparison does not verify their identity.") }
                .disabled(!device.active)
                if !device.active {
                    Section {
                        Text("This device is no longer advertised. Its fingerprint is read-only; earlier messages require prior approval.")
                            .font(.footnote).foregroundStyle(.secondary)
                    }
                }
            }
            .navigationTitle("Device fingerprint").navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .cancellationAction) { Button("Close", systemImage: "xmark") { dismiss() }.labelStyle(.iconOnly) } }
        }
    }
    private func review(_ trust: DeviceTrust) {
        Task { await model.setDeviceTrust(device, trust: trust, chatID: room); dismiss() }
    }
}

private struct GroupLocalFingerprintView: View {
    let deviceID: UInt32
    let fingerprint: String
    var body: some View {
        List {
            Section {
                LabeledContent("Device", value: String(deviceID))
                Text(stride(from: 0, to: fingerprint.count, by: 8).map { String(fingerprint.dropFirst($0).prefix(8)) }.joined(separator: " "))
                    .font(.system(.footnote, design: .monospaced)).textSelection(.enabled)
                    .accessibilityLabel("Fingerprint \(fingerprint)")
            } footer: { Text("Let other members compare this fingerprint through a channel they trust to verify this iPhone.") }
        }
        .navigationTitle("Your fingerprint").navigationBarTitleDisplayMode(.inline)
    }
}
