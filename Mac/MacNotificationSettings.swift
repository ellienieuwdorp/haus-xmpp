import ServiceManagement
import SwiftUI
import UserNotifications

/// The Mac's notification permission, in a build that registers no push (`PushService.isOffered`): what macOS allows
/// now, a button to ask while it was never asked, and System Settings for everything else, including turning quiet
/// delivery into banners.
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

/// The iPhone's push switch and its statuses, with the permission row folded in. On the Mac the permission matters
/// apart from push: the banners the app posts itself while it runs need it too, so it is shown and asked for whatever
/// the switch says. Quiet delivery, which macOS grants without asking, shows no banners, so the row says so and points
/// to System Settings.
struct MacPushNotificationRows: View {
    @Bindable var model: AppModel
    @Environment(\.openURL) private var openURL

    var body: some View {
        // On while push is on or being set up; a status that reads "Off" shows it off, as on the iPhone.
        Toggle(isOn: Binding(get: { model.pushWanted && ![.off, .notAllowed].contains(model.pushStatus) },
            set: { on in Task { if on { await model.enableNotifications() } else { await model.disableNotifications() } } })) {
            Label {
                VStack(alignment: .leading, spacing: 2) {
                    Text("Push notifications")
                    Text(model.pushStatus.text).font(.footnote).foregroundStyle(.secondary)
                        .accessibilityIdentifier("pushStatus")
                    if let permission {
                        Text(permission).font(.footnote).foregroundStyle(.secondary)
                            .accessibilityIdentifier("notificationPermission")
                    }
                }
            } icon: { SettingsIconTile(systemName: "bell.fill", color: .red) }
        }
        .accessibilityIdentifier("pushNotifications")
        if model.pushWanted, [.unreachable, .unsupported].contains(model.pushStatus) {
            Button("Try Again") { Task { await model.enableNotifications() } }
                .disabled(!model.session.isReady)
                .accessibilityIdentifier("retryPushNotifications")
        }
        switch model.notificationAuthorization {
        case .notDetermined:
            Button("Allow Notifications…") { Task { await model.requestNotificationPermission() } }
                .accessibilityIdentifier("allowNotifications")
        case .provisional, .denied:
            Button("Open \(ThisDevice.settingsApp)") {
                if let url = PlatformApplication.notificationSettingsURL { openURL(url) }
            }
            .accessibilityIdentifier("openNotificationSettings")
        default:
            EmptyView()
        }
    }

    /// What the permission adds to the push status; nothing once banners are allowed, or where the status already
    /// names it.
    private var permission: String? {
        switch model.notificationAuthorization {
        case .provisional: "Delivered quietly, without banners"
        case .denied: model.pushStatus == .notAllowed ? nil : "Notifications off in \(ThisDevice.settingsApp)"
        case .notDetermined: "Notifications not allowed yet"
        default: nil
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
