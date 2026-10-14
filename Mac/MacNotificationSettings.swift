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
