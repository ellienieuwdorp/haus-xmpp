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
                LabeledContent("Address") {
                    TextField("group@rooms.server", text: $room)
                        .multilineTextAlignment(.trailing)
                        .textInputAutocapitalization(.never).autocorrectionDisabled().keyboardType(.emailAddress)
                        .accessibilityLabel("Group address").accessibilityIdentifier("groupAddress")
                }
                LabeledContent("Nickname") {
                    TextField("Your nickname", text: $nickname)
                        .multilineTextAlignment(.trailing)
                        .textInputAutocapitalization(.never).autocorrectionDisabled()
                        .accessibilityIdentifier("groupNickname")
                }
            } footer: { Text("Members-only, encrypted groups you already belong to.") }
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
                }.frame(maxWidth: .infinity)
            }
            .buttonStyle(.glassProminent).controlSize(.large)
            .disabled(joining || !model.session.isReady || room.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || nickname.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            .accessibilityIdentifier("joinGroup")
            .padding(.horizontal, 16).padding(.vertical, 8)
        }
        .task { if nickname.isEmpty { nickname = String(model.accountID.prefix { $0 != "@" }) } }
    }
}
