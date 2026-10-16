import SwiftUI

struct GroupJoinView: View {
    @Bindable var model: AppModel
    var joined: (String) -> Void
    @State private var room = ""
    @State private var nickname = ""
    @State private var joining = false

    /// `room` prefills the address, as when an `xmpp:…?join` link in a message opens this.
    init(model: AppModel, room: String = "", joined: @escaping (String) -> Void) {
        self.model = model
        self.joined = joined
        _room = State(initialValue: room)
    }

    var body: some View {
        Form {
            Section {
                #if os(macOS)
                // A Mac form row is the field's own label and the field; LabeledContent around a field shows its
                // title as a second label.
                TextField("Address", text: $room, prompt: Text("group@rooms.server"))
                    .autocorrectionDisabled()
                    .accessibilityLabel("Group address").accessibilityIdentifier("groupAddress")
                TextField("Nickname", text: $nickname, prompt: Text("Your nickname"))
                    .autocorrectionDisabled()
                    .accessibilityIdentifier("groupNickname")
                #else
                LabeledContent("Address") {
                    TextField("group@rooms.server", text: $room)
                        .multilineTextAlignment(.trailing)
                        .noAutocapitalization().autocorrectionDisabled().keyboard(.emailAddress)
                        .accessibilityLabel("Group address").accessibilityIdentifier("groupAddress")
                }
                LabeledContent("Nickname") {
                    TextField("Your nickname", text: $nickname)
                        .multilineTextAlignment(.trailing)
                        .noAutocapitalization().autocorrectionDisabled()
                        .accessibilityIdentifier("groupNickname")
                }
                #endif
            } footer: { Text("Members-only, encrypted groups you already belong to.") }
        }
        .groupedFormStyle()
        .navigationTitle("Join a group").inlineNavigationTitle()
        .safeAreaInset(edge: .bottom) {
            Button {
                joining = true
                Task {
                    let address = room.trimmingCharacters(in: .whitespacesAndNewlines)
                    if let chat = await model.joinGroup(room: address, nickname: nickname) { joined(chat) }
                    joining = false
                }
            } label: {
                HStack(spacing: 10) {
                    if joining { ProgressView().tint(.white) }
                    Text(joining ? "Checking group…" : "Join group").fontWeight(.semibold)
                }.frame(maxWidth: .infinity)
            }
            .prominentActionStyle().controlSize(.large)
            #if os(macOS)
            .keyboardShortcut(.defaultAction)
            #endif
            .disabled(joining || !model.session.isReady || room.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || nickname.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            .accessibilityIdentifier("joinGroup")
            .padding(.horizontal, 16).padding(.vertical, 8)
        }
        .task { if nickname.isEmpty { nickname = String(model.accountID.prefix { $0 != "@" }) } }
    }
}
