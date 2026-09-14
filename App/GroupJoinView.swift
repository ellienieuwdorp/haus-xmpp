import SwiftUI

struct GroupJoinView: View {
    @Bindable var model: AppModel
    var joined: (String) -> Void
    @State private var room = ""
    @State private var nickname = ""
    @State private var joining = false

    var body: some View {
        Form {
            Section {
                TextField("group@rooms.server", text: $room)
                    .textInputAutocapitalization(.never).autocorrectionDisabled().keyboardType(.emailAddress)
                    .accessibilityLabel("Group address").accessibilityIdentifier("groupAddress")
                TextField("Your nickname", text: $nickname)
                    .textInputAutocapitalization(.never).autocorrectionDisabled()
                    .accessibilityIdentifier("groupNickname")
            } header: { Text("Group invitation") }
            footer: { Text("Use the address of a group you already belong to. Your nickname is visible to its members.") }
            Section {
                Label("Private, encrypted groups", systemImage: "lock.shield")
                Text("The group must be members-only and share its members’ addresses. You’ll review everyone’s encryption devices before sending.")
                    .font(.subheadline).foregroundStyle(.secondary)
            }
        }
        .navigationTitle("Join a group").navigationBarTitleDisplayMode(.inline)
        .safeAreaInset(edge: .bottom) {
            Button {
                joining = true
                Task {
                    let address = room.trimmingCharacters(in: .whitespacesAndNewlines)
                    if await model.joinGroup(room: address, nickname: nickname) { joined(address) }
                    joining = false
                }
            } label: {
                HStack(spacing: 10) {
                    if joining { ProgressView().tint(.white) }
                    Text(joining ? "Checking group…" : "Join group").fontWeight(.semibold)
                }.frame(maxWidth: .infinity).frame(minHeight: 44)
            }
            .buttonStyle(.borderedProminent)
            .disabled(joining || !model.isConnected || room.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || nickname.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            .accessibilityIdentifier("joinGroup")
            .padding(.horizontal, 16).padding(.vertical, 8).background(.bar)
        }
        .task { if nickname.isEmpty { nickname = String(model.accountID.prefix { $0 != "@" }) } }
    }
}
