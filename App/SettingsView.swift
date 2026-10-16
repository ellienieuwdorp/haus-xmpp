import SwiftUI

struct SettingsView: View {
    @Bindable var model: AppModel
    @Binding var showingConnection: Bool
    @Environment(\.appearance) private var appearance
    @Environment(\.openURL) private var openURL
    @State private var confirmingSignOut = false
    @State private var showingBackup = false
    @State private var confirmingDeleteUnreadable = false
    @State private var confirmingSamples = false
    @State private var noMailApp = false
    @State private var showingTransfer = false
    @State private var showingRestore = false

    private var accent: AccentTheme { appearance.accent }
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

    /// Every signed-in account (the sample conversations have none); in DEBUG, the iPhone's notification harness and the
    /// Mac's `-haus-notification-settings` show it signed out too, for captures.
    private var showsNotificationSettings: Bool {
        #if DEBUG && os(iOS)
        if NotificationHarness.isRequested { return true }
        #elseif DEBUG
        if MacDebugHooks.has("-haus-notification-settings") { return true }
        #endif
        return !model.accountID.isEmpty && !model.isDemo
    }

    var body: some View {
        if model.transferState != .none {
            // The Mac's Settings window, while the main window shows the transfer.
            ContentUnavailableView("Moving to another install", systemImage: "shippingbox",
                                   description: Text("Finish the transfer in the main window."))
        } else {
            settings
        }
    }

    private var settings: some View {
        GroupedList {
            #if os(macOS)
            // A Mac settings pane: who is signed in, with the account's actions as push buttons beside it.
            Section {
                LabeledContent {
                    HStack {
                        if model.session.isConnected {
                            Button("Disconnect") { Task { await model.disconnect() } }
                        }
                        Button(model.accountID.isEmpty || model.isDemo ? "Sign In…" : "Switch Account…") { showingConnection = true }
                            .accessibilityIdentifier("accountSignIn")
                    }
                } label: { profileCard }
            }
            #else
            Section {
                Button { showingConnection = true } label: { profileCard }
                    .buttonStyle(.plain)
                    .accessibilityHint("Opens sign in")
                Button(model.accountID.isEmpty ? "Sign in" : "Switch account") { showingConnection = true }
                    .accessibilityIdentifier("accountSignIn")
                if model.session.isConnected {
                    Button("Disconnect") { Task { await model.disconnect() } }
                }
            }
            #endif
            if showsNotificationSettings {
                Section {
                    // The Mac registers no push yet, so it shows only the preferences that also apply to
                    // the notifications it posts itself.
                    #if os(iOS)
                    // On while push is on or being set up; a status that reads "Off" shows it off.
                    Toggle(isOn: Binding(get: { model.pushWanted && ![.off, .notAllowed].contains(model.pushStatus) },
                        set: { on in Task { if on { await model.enableNotifications() } else { await model.disableNotifications() } } })) {
                        Label {
                            VStack(alignment: .leading, spacing: 2) {
                                Text("Push notifications")
                                Text(model.pushStatus.text).font(.footnote).foregroundStyle(.secondary)
                                    .accessibilityIdentifier("pushStatus")
                            }
                        } icon: { SettingsIconTile(systemName: "bell.fill", color: .red) }
                    }
                    .accessibilityIdentifier("pushNotifications")
                    if model.pushWanted {
                        switch model.pushStatus {
                        case .unreachable, .unsupported:
                            Button("Try Again") { Task { await model.enableNotifications() } }
                                .disabled(!model.session.isReady)
                                .accessibilityIdentifier("retryPushNotifications")
                        case .notAllowed:
                            Button("Open \(ThisDevice.settingsApp)") {
                                if let url = PlatformApplication.notificationSettingsURL { openURL(url) }
                            }
                            .accessibilityIdentifier("openNotificationSettings")
                        default:
                            EmptyView()
                        }
                    }
                    #else
                    MacNotificationPermissionRow(model: model)
                    #endif
                    Toggle("Message previews", isOn: Binding(get: { model.notificationPreviewsEnabled },
                        set: { enabled in Task { await model.setNotificationPreviews(enabled) } }))
                        .accessibilityIdentifier("notificationPreviews")
                    Toggle("Reactions", isOn: Binding(get: { model.accountPreferences.reactionNotifications },
                        set: { on in Task { await model.updatePreferences { $0.reactionNotifications = on } } }))
                        .accessibilityIdentifier("reactionNotifications")
                } header: {
                    Text("Notifications")
                } footer: {
                    Text("Show message text after decryption on this \(ThisDevice.noun). Your \(ThisDevice.systemName) Show Previews setting still controls when it is revealed.")
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
                Toggle(isOn: Binding(get: { model.accountPreferences.lastSeen }, set: { on in Task { await model.updatePreferences { $0.lastSeen = on } } })) {
                    Label { Text("Last seen") } icon: { SettingsIconTile(systemName: "clock.fill", color: .orange) }
                }
                .accessibilityIdentifier("lastSeen")
                if !model.accountID.isEmpty {
                    NavigationLink {
                        BlockedContactsView(model: model)
                    } label: {
                        LabeledContent {
                            Text(model.blocklist.isEmpty ? "None" : "\(model.blocklist.addresses.count)")
                        } label: {
                            Label { Text("Blocked") } icon: { SettingsIconTile(systemName: "hand.raised.fill", color: .red) }
                        }
                    }
                    .accessibilityIdentifier("blockedContacts")
                }
                // Per device (LinkSettings): what this app fetches, not something contacts see.
                Toggle(isOn: Binding(get: { LinkSettings.shared.fetchPreviews }, set: { LinkSettings.shared.fetchPreviews = $0 })) {
                    Label { Text("Link previews") } icon: { SettingsIconTile(systemName: "link", color: .teal) }
                }
                .accessibilityIdentifier("linkPreviews")
            } header: {
                Text("Privacy")
            } footer: {
                Text("Tell contacts when their messages reach this \(ThisDevice.noun) and when you read them. You still see what contacts send you, and their messages are still asked for receipts. Last seen lets contacts you chat with see when you were last online. Turning it off stops sharing your online status with everyone; you still see what contacts share.")
            }
            #if os(macOS)
            MacLoginItemSection()
            #endif
            // The Mac's Settings window has Appearance as a pane of its own.
            #if os(iOS)
            Section {
                NavigationLink {
                    AppearanceView()
                } label: {
                    LabeledContent {
                        Text(accent.title)
                    } label: {
                        Label { Text("Appearance") } icon: { SettingsIconTile(systemName: "paintpalette.fill", color: .indigo) }
                    }
                }
                .accessibilityIdentifier("appearanceRow")
                // Off opens web links in the in-app browser; the Mac always uses the default browser.
                Toggle(isOn: Binding(get: { LinkSettings.shared.openInSafari }, set: { LinkSettings.shared.openInSafari = $0 })) {
                    Label { Text("Open links in Safari") } icon: { SettingsIconTile(systemName: "safari.fill", color: .blue) }
                }
                .accessibilityIdentifier("openLinksInSafari")
            }
            #endif
            Section {
                // Showing the samples signs the account out, so a signed-in account confirms first.
                Button {
                    if model.accountID.isEmpty || model.isDemo { Task { await model.loadDemo() } } else { confirmingSamples = true }
                } label: {
                    Label { Text("Explore sample conversations") } icon: { SettingsIconTile(systemName: "sparkles", color: .blue) }
                }
                .listRowButton()
                .accessibilityIdentifier("exploreSamples")
                .confirmationDialog("Explore sample conversations?", isPresented: $confirmingSamples, titleVisibility: .visible) {
                    Button("Sign Out and Explore") { Task { await model.loadDemo() } }
                } message: {
                    Text("This signs you out of \(model.accountID). You’ll need your password to sign in again. Messages and keys stay on this \(ThisDevice.noun).")
                }
            }
            if model.canTransfer {
                Section {
                    Button { showingTransfer = true } label: {
                        Label { Text("Transfer to another app or device…") } icon: { SettingsIconTile(systemName: "shippingbox.and.arrow.backward.fill", color: .indigo) }
                    }
                    .foregroundStyle(.primary)
                    .listRowButton()
                    .accessibilityIdentifier("transferAccount")
                }
                .sheet(isPresented: $showingTransfer) { TransferIntroView(model: model).macSheetSize(width: 460, height: 480).themedRoot() }
            } else if model.canRestoreTransfer {
                Section {
                    Button { showingRestore = true } label: {
                        Label { Text("Restore from a transfer…") } icon: { SettingsIconTile(systemName: "arrow.down.app.fill", color: .indigo) }
                    }
                    .foregroundStyle(.primary)
                    .listRowButton()
                    .accessibilityIdentifier("restoreTransferRow")
                }
                .sheet(isPresented: $showingRestore) { RestoreTransferView(model: model).themedRoot() }
            }
            #if DEBUG
            Section("Development") {
                HStack(spacing: 12) {
                    SettingsIconTile(systemName: "tray.and.arrow.down.fill", color: .gray)
                    Text("Received lab messages: \(model.receivedCount)")
                        .accessibilityIdentifier("labReceivedCount")
                }
            }
            #endif
            if let backup = model.previousVersionBackup {
                let old = Date() >= backup.suggestDeletionAfter
                Section {
                    Button { showingBackup = true } label: {
                        LabeledContent {
                            Text(old ? "Over 2 weeks old" : backup.takenAt.formatted(.dateTime.day().month())).foregroundStyle(.secondary)
                        } label: {
                            Label { Text("Previous version backup") } icon: { SettingsIconTile(systemName: "clock.arrow.circlepath", color: .gray) }
                        }
                    }
                    .foregroundStyle(.primary)
                    .listRowButton()
                    .accessibilityIdentifier("previousVersionBackupRow")
                } footer: {
                    // Asked, never done on a clock reading: the clock can jump.
                    if old { Text("Delete the backup if you will not go back to the previous version.") }
                }
                .sheet(isPresented: $showingBackup) { PreviousVersionBackupView(model: model, backup: backup).themedRoot() }
            } else if model.previousVersionBackupUnreadable {
                Section {
                    Button { confirmingDeleteUnreadable = true } label: {
                        LabeledContent {
                            Text("Can’t be read").foregroundStyle(.secondary)
                        } label: {
                            Label { Text("Previous version backup") } icon: { SettingsIconTile(systemName: "exclamationmark.triangle.fill", color: .orange) }
                        }
                    }
                    .foregroundStyle(.primary)
                    .listRowButton()
                    .accessibilityIdentifier("previousVersionBackupRow")
                } footer: {
                    Text("A backup is on this \(ThisDevice.noun) but its description could not be read, so it cannot be restored.")
                }
                .confirmationDialog("Delete backup?", isPresented: $confirmingDeleteUnreadable, titleVisibility: .visible) {
                    Button("Delete backup", role: .destructive) { model.deletePreviousVersionBackup() }
                } message: {
                    Text("You will no longer be able to go back to the previous version on this \(ThisDevice.noun).")
                }
            }
            Section {
                // The Mac's Settings window has About as a pane of its own.
                #if os(iOS)
                NavigationLink {
                    AboutView()
                } label: {
                    LabeledContent {
                        Text(AppInfo.version)
                    } label: {
                        Label { Text("About") } icon: { SettingsIconTile(systemName: "info", color: .gray) }
                    }
                }
                .accessibilityIdentifier("aboutRow")
                #endif
                Button {
                    openURL(AppInfo.supportMail) { opened in if !opened { noMailApp = true } }
                } label: {
                    Label { Text("Contact support") } icon: { SettingsIconTile(systemName: "envelope.fill", color: .blue) }
                }
                .foregroundStyle(.primary)
                .listRowButton()
                .accessibilityHint("Writes an email to \(AppInfo.supportAddress)")
                .accessibilityIdentifier("contactSupport")
                ExternalLinkRow(title: "Support website", url: AppInfo.support, systemName: "questionmark", color: .green)
            }
            .alert("No mail app", isPresented: $noMailApp) {
                Button("OK", role: .cancel) {}
            } message: {
                Text("Write to \(AppInfo.supportAddress) from any email app.")
            }
            Section {
                Button("Sign Out", role: .destructive) { confirmingSignOut = true }
                    .disabled(model.accountID.isEmpty)
                    #if os(macOS)
                    // A Mac form's closing action sits at its trailing edge.
                    .frame(maxWidth: .infinity, alignment: .trailing)
                    #endif
            }
        }
        .navigationTitle("Settings")
        .confirmationDialog("Sign out?", isPresented: $confirmingSignOut, titleVisibility: .visible) {
            Button("Sign Out", role: .destructive) { Task { await model.signOut() } }
            if model.previousVersionBackup != nil {
                Button("Sign Out and Delete Backup", role: .destructive) {
                    Task { await model.signOut(); model.deletePreviousVersionBackup() }
                }
            }
        } message: {
            if model.previousVersionBackup != nil {
                Text("You’ll need your password to sign in again. Messages and keys stay on this \(ThisDevice.noun). The backup of the previous version’s data stays too, until you delete it; restoring it would sign you back in as you were then.")
            } else {
                Text("You’ll need your password to sign in again. Messages and keys stay on this \(ThisDevice.noun).")
            }
        }
    }

    private var profileCard: some View {
        HStack(spacing: 14) {
            ChatAvatar(key: model.accountID, name: localPart, image: model.avatars[model.accountID], size: ProfileCardMetrics.avatar)
            #if os(macOS)
            // The sample account's ID is a bare domain, which would read as the name and the address both.
            if model.isDemo {
                VStack(alignment: .leading, spacing: 2) {
                    Text("Sample conversations").font(.title3.weight(.bold))
                    Text("Stored on this \(ThisDevice.noun); nothing is sent").font(.subheadline).foregroundStyle(.secondary)
                }
            } else {
                profileText
            }
            #else
            profileText
            Spacer(minLength: 0)
            Image(systemName: "chevron.right").font(.footnote.weight(.semibold)).foregroundStyle(.tertiary)
            #endif
        }
        .padding(.vertical, 4)
        .contentShape(Rectangle())
    }

    private var profileText: some View {
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
    }
}

/// Rounded colour tile with a white glyph, like the rows of iOS Settings (30 pt) and System Settings on the Mac (22 pt).
struct SettingsIconTile: View {
    let systemName: String
    let color: Color

    var body: some View {
        RoundedRectangle(cornerRadius: IconTileMetrics.radius, style: .continuous)
            .fill(color)
            .frame(width: IconTileMetrics.side, height: IconTileMetrics.side)
            .overlay { Image(systemName: systemName).font(.system(size: IconTileMetrics.glyph, weight: .semibold)).foregroundStyle(.white) }
            .accessibilityHidden(true)
    }
}

/// The profile card's avatar: the iPhone's large card, and a Mac pane's account row.
private enum ProfileCardMetrics {
    #if os(iOS)
    static let avatar: CGFloat = 60
    #else
    static let avatar: CGFloat = 48
    #endif
}

/// The settings and details rows' icon tiles: iOS Settings' size on the iPhone, System Settings' on the Mac.
enum IconTileMetrics {
    #if os(iOS)
    static let side: CGFloat = 30, radius: CGFloat = 8, glyph: CGFloat = 15
    #else
    static let side: CGFloat = 22, radius: CGFloat = 6, glyph: CGFloat = 12
    #endif
}
