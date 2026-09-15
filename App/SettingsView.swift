import SwiftUI

struct SettingsView: View {
    @Bindable var model: AppModel
    @Binding var showingConnection: Bool

    var body: some View {
                    List {
                        Section("Account") {
                            LabeledContent("Connection", value: model.connectionStatus)
                            Button("Connect to local lab") { showingConnection = true }
                            if model.isConnected {
                                Button("Disconnect") { Task { await model.disconnect() } }
                            }
                        }
                        if model.accountID.hasSuffix("@staging.example.net") {
                            Section("Notifications") {
                                LabeledContent("Status", value: model.notificationStatus)
                                Button("Enable notifications") { Task { await model.enableNotifications() } }
                                    .disabled(!model.isConnected || !model.encryptionReady)
                                    .accessibilityIdentifier("enableNotifications")
                                Toggle("Message previews", isOn: Binding(get: { model.notificationPreviewsEnabled },
                                    set: { enabled in Task { await model.setNotificationPreviews(enabled) } }))
                                    .accessibilityIdentifier("notificationPreviews")
                                Text("Show message text after decryption on this iPhone. Your iOS Show Previews setting still controls when it is revealed.")
                                    .font(.footnote).foregroundStyle(.secondary)
                            }
                        }
                        Section("Development preview") {
                            Text("Received lab messages: \(model.receivedCount)")
                                .accessibilityIdentifier("labReceivedCount")
                            Text("This development build supports encrypted direct messages between local test accounts. Archive recovery is enabled. Push delivery is being validated on the staging server.")
                                .foregroundStyle(.secondary)
                            Button("Explore sample conversations") { Task { await model.loadDemo() } }
                        }
                    }
                    .navigationTitle("Settings")
    }
}
