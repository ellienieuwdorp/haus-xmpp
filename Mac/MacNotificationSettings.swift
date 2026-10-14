import ServiceManagement
import SwiftUI
import UserNotifications

/// The Mac's notification permission, which iOS folds into its push switch (the Mac registers no push yet): what
/// macOS allows now, a button to ask while it was never asked, and System Settings for everything else, including
/// turning quiet delivery into banners.
struct MacNotificationPermissionRow: View {
    @Bindable var model: AppModel
    @Environment(\.openURL) private var openURL

    var body: some View {
        LabeledContent {
            if model.notificationAuthorization == .notDetermined {
                Button("Allow…") { Task { await model.requestNotificationPermission() } }
                    .accessibilityIdentifier("allowNotifications")
            } else {
                Button("Open \(ThisDevice.settingsApp)") {
                    if let url = PlatformApplication.notificationSettingsURL { openURL(url) }
                }
                .accessibilityIdentifier("openNotificationSettings")
            }
        } label: {
            Label {
                VStack(alignment: .leading, spacing: 2) {
                    Text("Notifications")
                    Text(status).font(.footnote).foregroundStyle(.secondary)
                        .accessibilityIdentifier("notificationPermission")
                }
            } icon: { SettingsIconTile(systemName: "bell.fill", color: .red) }
        }
    }

    private var status: String {
        switch model.notificationAuthorization {
        case .authorized: "Allowed"
        case .provisional: "Delivered quietly, without banners"
        case .denied: "Off in \(ThisDevice.settingsApp)"
        default: "Not allowed yet"
        }
    }
}

/// "Open at login": the app as its own login item (`SMAppService.mainApp`). Off until the user turns it on here;
/// the app never registers itself.
struct MacLoginItemSection: View {
    @State private var status = SMAppService.mainApp.status
    @State private var failed = false

    var body: some View {
        Section {
            Toggle(isOn: Binding(get: { [.enabled, .requiresApproval].contains(status) }, set: change)) {
                Label { Text("Open at login") } icon: { SettingsIconTile(systemName: "power", color: .gray) }
            }
            .accessibilityIdentifier("openAtLogin")
            if status == .requiresApproval {
                Button("Allow in Login Items…") { SMAppService.openSystemSettingsLoginItems() }
            }
        } footer: {
            if failed { Text("The login item could not be changed. Try again, or change it in Login Items.") }
        }
        // Login Items in System Settings can change it while the window is closed.
        .onAppear { status = SMAppService.mainApp.status }
    }

    private func change(_ on: Bool) {
        do {
            if on { try SMAppService.mainApp.register() } else { try SMAppService.mainApp.unregister() }
            failed = false
        } catch { failed = true }
        status = SMAppService.mainApp.status
    }
}
