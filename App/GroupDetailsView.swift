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
                    let pill: Color = state.needsReview ? .orange : .green
                    VStack(spacing: 6) {
                        Image(systemName: "person.2.fill")
                            .font(.system(size: 40)).foregroundStyle(.white)
                            .frame(width: 96, height: 96)
                            .background(Color(uiColor: AvatarPalette.color(for: room)), in: Circle())
                        Text(String(room.prefix { $0 != "@" })).font(.title2.bold()).padding(.top, 6)
                        Text(room).font(.footnote).foregroundStyle(.secondary).textSelection(.enabled)
                        Label(state.needsReview ? "Devices need review" : "Encrypted", systemImage: state.needsReview ? "exclamationmark.shield" : "lock.fill")
                            .font(.footnote.weight(.semibold)).foregroundStyle(pill)
                            .padding(.horizontal, 9).padding(.vertical, 3)
                            .background(pill.opacity(0.15), in: Capsule())
                            .padding(.top, 4)
                        if state.issue != nil || !state.joined {
                            Text(state.status).font(.footnote).foregroundStyle(.secondary).multilineTextAlignment(.center)
                        }
                    }
                    .frame(maxWidth: .infinity).padding(.vertical, 8)
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
                ToolbarItem(placement: .confirmationAction) { Button("Done") { dismiss() } }
                ToolbarItem(placement: .topBarLeading) {
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
            } footer: { Text("Other members verify this iPhone by comparing this fingerprint.") }
        }
        .navigationTitle("Your fingerprint").navigationBarTitleDisplayMode(.inline)
    }
}
