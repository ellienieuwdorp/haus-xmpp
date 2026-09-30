import SwiftUI

/// Replaces the app while the previous version's data is being backed up, could not be backed up, is being restored,
/// or has been restored. Nothing behind it connects or changes storage.
struct UpgradeBlockingView: View {
    @Bindable var model: AppModel
    @State private var confirmingWithoutBackup = false
    @State private var confirmingUpgradeAgain = false
    @State private var working = false
    /// A quick upgrade finishes before this shows, so launches do not flash a progress screen.
    @State private var showsProgress = false

    var body: some View {
        Group {
            switch model.upgradeState {
            case .snapshotFailed(let reason): failed(reason)
            case .restored(let restored): restoredView(restored)
            case .restoring: progress("Restoring the previous version’s data…")
            case .waitingForLease: progress("Waiting for a notification to finish…")
            default: progress("Backing up before updating…")
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Color(.systemGroupedBackground))
    }

    private func progress(_ text: String) -> some View {
        VStack(spacing: 16) {
            ProgressView().controlSize(.large)
            Text(text).font(.headline).multilineTextAlignment(.center)
        }
        .padding(32)
        .opacity(showsProgress ? 1 : 0)
        .task {
            try? await Task.sleep(for: .milliseconds(400))
            withAnimation { showsProgress = true }
        }
        .accessibilityElement(children: .combine)
    }

    private func failed(_ reason: String) -> some View {
        blocking(symbol: "exclamationmark.triangle.fill", tint: .orange, title: "Backup before update failed",
                 body: reason + "\n\nNothing has been changed yet: your data is still in the previous version’s format.") {
            Button { run { await model.retryUpgrade() } } label: { Text("Try again").frame(maxWidth: .infinity) }
                .buttonStyle(.borderedProminent)
                .accessibilityIdentifier("upgradeTryAgain")
            Button("Continue without a backup") { confirmingWithoutBackup = true }
                .accessibilityIdentifier("upgradeWithoutBackup")
        }
        .confirmationDialog("Continue without a backup?", isPresented: $confirmingWithoutBackup, titleVisibility: .visible) {
            Button("Continue without a backup", role: .destructive) { run { await model.upgradeWithoutBackup() } }
        } message: {
            Text("Your data will be upgraded for this version. Without a backup you cannot go back to the previous version on this iPhone.")
        }
    }

    private func restoredView(_ restored: PreUpgradeSnapshot.Restored) -> some View {
        blocking(symbol: "arrow.uturn.backward.circle.fill", tint: .accentColor, title: "Previous version’s data restored",
                 body: "Your messages, keys and settings are back as they were on \(restored.takenAt.formatted(date: .abbreviated, time: .shortened)), in the previous version’s format.\n\nInstall the previous version of Haus XMPP now. Until then this version stays offline and leaves the data alone.") {
            Button("Upgrade again") { confirmingUpgradeAgain = true }
                .accessibilityIdentifier("upgradeAgain")
        }
        .confirmationDialog("Upgrade again?", isPresented: $confirmingUpgradeAgain, titleVisibility: .visible) {
            Button("Upgrade again") { run { await model.upgradeAgain() } }
        } message: {
            Text("This version takes a fresh backup of the restored data, replacing the old one, and upgrades it again. Messages that arrived since are fetched from the server.")
        }
    }

    private func blocking(symbol: String, tint: Color, title: String, body: String, @ViewBuilder actions: () -> some View) -> some View {
        VStack(spacing: 20) {
            Spacer()
            Image(systemName: symbol).font(.system(size: 56)).foregroundStyle(tint).accessibilityHidden(true)
            Text(title).font(.title2.weight(.bold)).multilineTextAlignment(.center)
                .accessibilityAddTraits(.isHeader)
            Text(body).font(.body).foregroundStyle(.secondary).multilineTextAlignment(.center)
            Spacer()
            VStack(spacing: 12) { actions() }
                .controlSize(.large)
                .disabled(working)
        }
        .padding(.horizontal, 24)
        .padding(.vertical, 32)
        .frame(maxWidth: 520)
    }

    private func run(_ action: @escaping () async -> Void) {
        working = true
        Task { await action(); working = false }
    }
}

/// Settings: the snapshot of the previous version's data, what restoring it does, and the two actions.
struct PreviousVersionBackupView: View {
    @Bindable var model: AppModel
    let backup: PreUpgradeSnapshot.Manifest
    @Environment(\.dismiss) private var dismiss
    @State private var confirmingRestore = false
    @State private var confirmingDelete = false

    private var taken: String { backup.takenAt.formatted(date: .abbreviated, time: .shortened) }

    var body: some View {
        NavigationStack {
            List {
                Section {
                    LabeledContent("Taken", value: taken)
                    LabeledContent("Deleted automatically", value: backup.expiresAt.formatted(date: .abbreviated, time: .omitted))
                } footer: {
                    Text("Haus XMPP copied your data before this version upgraded it, so you can go back to the previous version.")
                }
                Section("Restoring brings back") {
                    Label("Messages, chats and read state as of \(taken)", systemImage: "bubble.left.and.bubble.right")
                    Label("Encryption keys, sessions and trust decisions", systemImage: "key")
                    Label("Your account, notification and app settings", systemImage: "gearshape")
                }
                Section("It does not bring back") {
                    Label("Messages sent or received since. The previous version fetches them from the server again; some encrypted ones may be unreadable.", systemImage: "clock.arrow.circlepath")
                    Label("Changes made in this version since, such as settings or trust decisions", systemImage: "slider.horizontal.3")
                }
                Section {
                    Button("Restore previous version's data") { confirmingRestore = true }
                        .accessibilityIdentifier("restorePreviousVersion")
                    Button("Delete backup", role: .destructive) { confirmingDelete = true }
                        .accessibilityIdentifier("deletePreviousVersionBackup")
                }
            }
            .navigationTitle("Previous Version Backup")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .confirmationAction) { Button("Done") { dismiss() } } }
        }
        .confirmationDialog("Restore previous version’s data?", isPresented: $confirmingRestore, titleVisibility: .visible) {
            Button("Restore previous version's data", role: .destructive) {
                dismiss()
                Task { await model.restorePreviousVersion() }
            }
        } message: {
            Text("This version goes offline and your data returns to how it was on \(taken). Anything since is removed from this iPhone. Then install the previous version.")
        }
        .confirmationDialog("Delete backup?", isPresented: $confirmingDelete, titleVisibility: .visible) {
            Button("Delete backup", role: .destructive) {
                model.deletePreviousVersionBackup()
                dismiss()
            }
        } message: {
            Text("You will no longer be able to go back to the previous version on this iPhone.")
        }
    }
}
