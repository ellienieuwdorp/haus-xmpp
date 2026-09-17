import SwiftUI

struct SettingsView: View {
    @Bindable var model: AppModel
    @Binding var showingConnection: Bool
    @AppStorage(AccentTheme.storageKey) private var accentRaw = AccentTheme.indigo.rawValue
    @State private var confirmingSignOut = false

    private var accent: AccentTheme { AccentTheme(rawValue: accentRaw) ?? .indigo }
    private var localPart: String { model.accountID.split(separator: "@").first.map(String.init) ?? "" }
    private var domain: String { model.accountID.split(separator: "@").dropFirst().first.map(String.init) ?? "" }

    private var status: (color: Color, text: String) {
        switch model.session {
        case .ready: (.green, "Connected · \(domain)")
        case .connecting, .connected: (.orange, model.session.label)
        case .needsAttention: (.red, model.session.label)
        case .offline: (.gray, model.session.label)
        }
    }

    var body: some View {
        List {
            Section {
                Button { showingConnection = true } label: { profileCard }
                    .buttonStyle(.plain)
                    .accessibilityHint("Opens sign in")
                Button(model.accountID.isEmpty ? "Sign in" : "Switch account") { showingConnection = true }
                    .accessibilityIdentifier("Connect to local lab")
                if model.session.isConnected {
                    Button("Disconnect") { Task { await model.disconnect() } }
                }
            }
            if model.accountID.hasSuffix("@staging.example.net") {
                Section {
                    LabeledContent("Status", value: model.notificationStatus)
                    Button { Task { await model.enableNotifications() } } label: {
                        Label { Text("Enable notifications") } icon: { SettingsIconTile(systemName: "bell.fill", color: .red) }
                    }
                    .disabled(!model.session.isReady)
                    .accessibilityIdentifier("enableNotifications")
                    Toggle("Message previews", isOn: Binding(get: { model.notificationPreviewsEnabled },
                        set: { enabled in Task { await model.setNotificationPreviews(enabled) } }))
                        .accessibilityIdentifier("notificationPreviews")
                } header: {
                    Text("Notifications")
                } footer: {
                    Text("Show message text after decryption on this iPhone. Your iOS Show Previews setting still controls when it is revealed.")
                }
            }
            Section {
                Toggle(isOn: Binding(get: { model.accountPreferences.deliveryReceipts }, set: { on in Task { await model.updatePreferences { $0.deliveryReceipts = on } } })) {
                    Label { Text("Delivery receipts") } icon: { SettingsIconTile(systemName: "checkmark.message.fill", color: .green) }
                }
                .accessibilityIdentifier("deliveryReceipts")
                Toggle(isOn: Binding(get: { model.accountPreferences.readReceipts }, set: { on in Task { await model.updatePreferences { $0.readReceipts = on } } })) {
                    Label { Text("Read receipts") } icon: { SettingsIconTile(systemName: "eye.fill", color: .blue) }
                }
                .accessibilityIdentifier("readReceipts")
            } header: {
                Text("Privacy")
            } footer: {
                Text("Tell contacts when their messages reach this iPhone and when you read them. Turning one off also stops asking contacts for it. You still see what contacts send you.")
            }
            Section {
                NavigationLink {
                    AppearanceView()
                } label: {
                    LabeledContent {
                        Text(accent.title)
                    } label: {
                        Label { Text("Appearance") } icon: { SettingsIconTile(systemName: "paintpalette.fill", color: Color(uiColor: .label)) }
                    }
                }
            }
            Section("Development") {
                HStack(spacing: 12) {
                    SettingsIconTile(systemName: "tray.and.arrow.down.fill", color: .gray)
                    Text("Received lab messages: \(model.receivedCount)")
                        .accessibilityIdentifier("labReceivedCount")
                }
                Button { Task { await model.loadDemo() } } label: {
                    Label { Text("Explore sample conversations") } icon: { SettingsIconTile(systemName: "sparkles", color: .blue) }
                }
            }
            Section {
                Button("Sign Out", role: .destructive) { confirmingSignOut = true }
                    .disabled(model.accountID.isEmpty)
            }
        }
        .navigationTitle("Settings")
        .confirmationDialog("Sign out?", isPresented: $confirmingSignOut, titleVisibility: .visible) {
            Button("Sign Out", role: .destructive) { Task { await model.signOut() } }
        } message: {
            Text("You’ll need your password to sign in again. Messages and keys stay on this iPhone.")
        }
    }

    private var profileCard: some View {
        HStack(spacing: 14) {
            Circle()
                .fill(Color(uiColor: model.accountID.isEmpty ? .systemGray3 : AvatarPalette.color(for: model.accountID)))
                .frame(width: 60, height: 60)
                .overlay {
                    if let initial = localPart.first {
                        Text(String(initial).uppercased()).font(.system(size: 26, weight: .semibold)).foregroundStyle(.white)
                    } else {
                        Image(systemName: "person.fill").font(.system(size: 26)).foregroundStyle(.white)
                    }
                }
            VStack(alignment: .leading, spacing: 2) {
                Text(localPart.isEmpty ? "Not signed in" : localPart).font(.title3.weight(.bold))
                if !model.accountID.isEmpty {
                    Text(model.accountID).font(.subheadline).foregroundStyle(.secondary).lineLimit(1).truncationMode(.middle)
                }
                HStack(spacing: 6) {
                    Circle().fill(status.color).frame(width: 8, height: 8)
                    Text(status.text)
                }
                .font(.footnote).foregroundStyle(.secondary)
            }
            Spacer(minLength: 0)
            Image(systemName: "chevron.right").font(.footnote.weight(.semibold)).foregroundStyle(.tertiary)
        }
        .padding(.vertical, 4)
        .contentShape(Rectangle())
    }
}

/// 30pt rounded colour tile with a white glyph, like iOS Settings rows.
struct SettingsIconTile: View {
    let systemName: String
    let color: Color

    var body: some View {
        RoundedRectangle(cornerRadius: 8, style: .continuous)
            .fill(color)
            .frame(width: 30, height: 30)
            .overlay { Image(systemName: systemName).font(.system(size: 15, weight: .semibold)).foregroundStyle(.white) }
            .accessibilityHidden(true)
    }
}
