import SwiftUI
import OMEMO

struct GroupDetailsView: View {
    @Bindable var model: AppModel
    let room: String
    @State private var selectedDevice: EncryptionDevice?
    private var state: GroupChatState { model.groupChats[room] ?? GroupChatState() }

    var body: some View {
        List {
            Section {
                VStack(spacing: 6) {
                    ChatAvatar(key: room, name: room, isGroup: true, size: 96)
                    Text(String(room.prefix { $0 != "@" })).font(.title2.bold()).padding(.top, 6)
                    Text(room).font(.footnote).foregroundStyle(.secondary).textSelection(.enabled)
                    TrustPill(text: state.needsReview ? "Devices need review" : "Encrypted",
                              systemImage: state.needsReview ? "exclamationmark.shield" : "lock.fill",
                              color: state.needsReview ? .orange : .green)
                        .padding(.top, 4)
                    // Read-only: the join state and the last failed device refresh. Neither changes the pill.
                    let notes = [state.issue != nil || !state.joined ? state.status : nil, model.encryptionAttention.groupProblems[room]].compactMap { $0 }
                    if !notes.isEmpty {
                        Text(notes.joined(separator: "\n")).font(.footnote).foregroundStyle(.secondary).multilineTextAlignment(.center)
                            .accessibilityIdentifier("groupDetails.status")
                    }
                }
                .frame(maxWidth: .infinity).padding(.vertical, 8)
            }
            Section { ChatNotificationRow(model: model, chatID: room) }
            ForEach(state.members, id: \.self) { member in
                Section {
                    let devices = state.devices.filter { $0.jid == member }
                    if member == model.accountID, let deviceID = state.localDeviceID, let fingerprint = state.localFingerprint {
                        NavigationLink("This \(ThisDevice.noun)") { GroupLocalFingerprintView(deviceID: deviceID, fingerprint: fingerprint) }
                    } else if devices.isEmpty {
                        Text(member == model.accountID ? "This \(ThisDevice.noun)" : "No compatible devices found").foregroundStyle(.secondary)
                    }
                    ForEach(devices) { device in
                        Button { selectedDevice = device } label: { DeviceRow(device: device, status: status(device)) }
                            .buttonStyle(.plain).accessibilityIdentifier("groupDevice.\(device.deviceID)")
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
                footer: { Text("Reviewing a previous member does not add them to current recipients.") }
            }
            Section {} footer: { Text("Blocking a device pauses sending to the whole group.") }
        }
        .navigationTitle("Group details").navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Button("Refresh group", systemImage: "arrow.clockwise") { Task { await model.loadGroupDetails(room: room) } }
                    .labelStyle(.iconOnly).disabled(!model.session.isReady)
            }
        }
        .sheet(item: $selectedDevice) { device in
            DeviceFingerprintSheet(model: model, chatID: room, device: device,
                                   name: device.jid == model.accountID ? nil : String(device.jid.prefix { $0 != "@" })) { trust in
                Task { await model.setDeviceTrust(device, trust: trust, chatID: room); selectedDevice = nil }
            }
        }
        .task { await model.loadGroupDetails(room: room) }
    }

    private func status(_ device: EncryptionDevice) -> String {
        device.active && device.trust == .rejected ? "Blocked · group sending paused" : device.reviewStatus
    }
}

private struct GroupLocalFingerprintView: View {
    let deviceID: UInt32
    let fingerprint: String
    var body: some View {
        List {
            Section {
                LabeledContent("Device", value: String(deviceID))
                FingerprintGrid(value: fingerprint).padding(.vertical, 8)
            } footer: { Text("Other members verify this \(ThisDevice.noun) by comparing this fingerprint.") }
        }
        .navigationTitle("Your fingerprint").navigationBarTitleDisplayMode(.inline)
    }
}
