import SwiftUI

/// Everything pushed onto the Chats stack. Details and encryption are pages to the right of a chat;
/// only the single-device fingerprint review stays modal.
enum ChatRoute: Hashable {
    case chat(String), details(String), encryption(String), groupDetails(String)
}

struct RootView: View {
    @Bindable var model: AppModel
    @State private var chatPath: [ChatRoute] = []
    @State private var showingConnection = false
    @State private var showingSettings = false

    var body: some View {
        NavigationStack(path: $chatPath) {
            ChatListView(model: model, path: $chatPath, showingConnection: $showingConnection, showingSettings: $showingSettings)
        }
        .id(model.accountID)
        .onChange(of: model.accountID) { _, _ in chatPath.removeAll() }
        .onChange(of: model.notificationRoute, initial: true) { _, route in
            guard let route else { return }
            model.consumeNotificationRoute(route.id)
            guard route.accountID == model.accountID else { return }
            showingConnection = false
            showingSettings = false
            chatPath = [.chat(route.chatID)]
        }
        .onChange(of: model.signInRequested) { _, requested in
            guard requested else { return }
            model.signInRequested = false
            showingConnection = true
        }
        .sheet(isPresented: $showingConnection) { SignInView(model: model) }
        .sheet(isPresented: $showingSettings) {
            NavigationStack {
                SettingsView(model: model, showingConnection: $showingConnection)
                    .toolbar {
                        ToolbarItem(placement: .confirmationAction) { Button("Done") { showingSettings = false } }
                    }
            }
        }
        .alert("Something needs attention", isPresented: Binding(
            get: { model.error != nil }, set: { if !$0 { model.error = nil } }
        )) {
            Button("OK") { model.error = nil }
        } message: { Text(model.error ?? "") }
    }
}
