import SwiftUI
import OMEMO
import XMPPProtocol

struct GroupDetailsView: View {
    @Bindable var model: AppModel
    let room: String
    @State private var selectedDevice: EncryptionDevice?
    private var state: GroupChatState { model.groupChats[room] ?? GroupChatState() }

    var body: some View {
        GroupedList {
            Section {
                VStack(spacing: 6) {
                    ChatAvatar(key: room, name: room, isGroup: true, size: DetailsHeroMetrics.avatar)
                    Text(String(room.prefix { $0 != "@" })).font(.title2.bold()).padding(.top, 6).accessibilityAddTraits(.isHeader)
                    Text(room).font(.footnote).foregroundStyle(.secondary).textSelection(.enabled)
                    let needsReview = state.needsReview(account: model.accountID)
                    TrustPill(text: needsReview ? "Devices need review" : "Encrypted",
                              systemImage: needsReview ? "exclamationmark.shield" : "lock.fill",
                              color: needsReview ? .orange : .green)
                        .padding(.top, 4)
                    // Read-only: the join state and the last failed device refresh. Neither changes the pill.
                    if !notes.isEmpty {
                        Text(notes.joined(separator: "\n")).font(.footnote).foregroundStyle(.secondary).multilineTextAlignment(.center)
                            .accessibilityIdentifier(state.removal == nil ? "groupDetails.status" : "groupDetails.notMember")
                    }
                }
                .frame(maxWidth: .infinity).padding(.vertical, 8)
                #if os(macOS)
                // A long room address wraps in the narrow inspector; its lines stay centred under the avatar.
                .multilineTextAlignment(.center)
                #endif
            }
            Section { ChatNotificationRow(model: model, chatID: room) }
            ForEach(state.members, id: \.self) { member in
                Section {
                    let devices = state.devices.filter { $0.jid == member }
                    if member == model.accountID, let deviceID = state.localDeviceID, let fingerprint = state.localFingerprint {
                        NavigationLink("This \(ThisDevice.noun)") {
                            GroupLocalFingerprintView(deviceID: deviceID, fingerprint: fingerprint)
                                #if os(macOS)
                                .macInspectorPage("Your fingerprint")
                                #endif
                        }
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
            Section {} footer: { Text("Blocking another member’s device pauses sending to the whole group. Your own blocked devices are left out instead.") }
        }
        // On iOS 27 the automatic edge has its own look instead of resolving to soft.
        .scrollEdgeEffectStyle(.soft, for: .top)
        .navigationTitle("Group details").inlineNavigationTitle()
        .toolbar {
            ToolbarItem(placement: .barTrailing) {
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

    // A removal stands alone: the refresh failure it caused would only repeat it.
    private var notes: [String] {
        let status = state.status(account: model.accountID)
        if state.removal != nil { return [status] }
        return [state.issue != nil || !state.joined ? status : nil, model.encryptionAttention.groupProblems[room]].compactMap { $0 }
    }

    private func status(_ device: EncryptionDevice) -> String {
        guard device.active && device.trust == .rejected else { return device.reviewStatus }
        return device.isLeftOutOfGroups(account: model.accountID) ? "Blocked · left out" : "Blocked · group sending paused"
    }
}

private struct GroupLocalFingerprintView: View {
    let deviceID: UInt32
    let fingerprint: String
    var body: some View {
        GroupedList {
            Section {
                LabeledContent("Device", value: String(deviceID))
                FingerprintGrid(value: fingerprint).padding(.vertical, 8)
            } footer: { Text("Other members verify this \(ThisDevice.noun) by comparing this fingerprint.") }
        }
        .navigationTitle("Your fingerprint").inlineNavigationTitle()
    }
}

// In the composer's place: unblocking, or rejoining a group, brings the composer back.
struct ComposerStandIn: View {
    @Bindable var model: AppModel
    let chatID: String
    let name: String

    var body: some View {
        if model.isBlocked(chatID) {
            BlockedChatBar(model: model, chatID: chatID, name: name)
        } else {
            GroupRemovedBar(model: model, room: chatID)
        }
    }
}

// Takes the composer's place while the room no longer counts us, shaped like `BlockedChatBar`.
struct GroupRemovedBar: View {
    @Bindable var model: AppModel
    let room: String
    @State private var rejoining = false

    var body: some View {
        let state = model.groupChats[room]
        HStack(spacing: 12) {
            Text(state?.removal == .kicked ? "You were removed from this group." : "You’re not a member of this group.")
                .font(.subheadline).foregroundStyle(.secondary)
                .frame(maxWidth: .infinity, alignment: .leading)
            if state?.mayRejoin == true {
                Button {
                    rejoining = true
                    Task { await model.rejoinGroup(room); rejoining = false }
                } label: {
                    Text("Rejoin").frame(minHeight: 44).contentShape(Rectangle())
                }
                .font(.subheadline.weight(.semibold))
                .disabled(rejoining || !(model.isDemo || model.session.isReady))
                .accessibilityIdentifier("rejoinGroup")
            }
        }
        .padding(.leading, 16).padding(.trailing, 12)
        .frame(minHeight: 48)
        .glassEffect(.regular, in: Capsule())
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("groupRemovedBar")
    }
}
