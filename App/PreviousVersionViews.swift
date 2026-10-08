import SwiftUI

/// Replaces the app while the previous version's data is being backed up, could not be backed up, is being restored,
/// has been restored, or while this version's kept data goes back. Nothing behind it connects or changes storage.
struct UpgradeBlockingView: View {
    @Bindable var model: AppModel
    @Environment(\.appearance) private var appearance
    @State private var confirmingWithoutBackup = false
    @State private var choosing = false
    @State private var working = false
    /// A quick upgrade finishes before this shows, so launches do not flash a progress screen.
    @State private var showsProgress = false

    var body: some View {
        Group {
            switch model.upgradeState {
            case .snapshotFailed(let reason): failed(reason)
            case .restored(let state) where state.previousVersionRan:
                UpgradeChoiceView(model: model, state: state)
            case .restored(let state): restoredView(state)
            case .restoring: progress("Restoring the previous version’s data…")
            case .returning: progress("Putting this version’s data back…")
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
            Button { confirmingWithoutBackup = true } label: { Text("Continue without a backup").frame(maxWidth: .infinity, minHeight: 44) }
                .accessibilityIdentifier("upgradeWithoutBackup")
        }
        .confirmationDialog("Continue without a backup?", isPresented: $confirmingWithoutBackup, titleVisibility: .visible) {
            Button("Continue without a backup", role: .destructive) { run { await model.upgradeWithoutBackup() } }
        } message: {
            Text("Your data will be upgraded for this version. Without a backup you cannot go back to the previous version on this \(ThisDevice.noun).")
        }
    }

    /// The previous version has not opened the restored data yet.
    private func restoredView(_ state: PreUpgradeSnapshot.RestoredState) -> some View {
        let taken = state.restored.takenAt.formatted(date: .abbreviated, time: .shortened)
        let kept = state.thisVersion != nil ? " This version kept its own data, so you can still return to it."
            : state.thisVersionUnreadable ? " This version kept a copy of its own data, but that copy can’t be read, so you cannot return to it." : ""
        return blocking(symbol: "arrow.uturn.backward.circle.fill", tint: Color(appearance.accent.tint), title: "Previous version’s data restored",
                        body: "Your messages, keys and settings are back as they were on \(taken), in the previous version’s format.\(kept)\n\nInstall the previous version of Haus XMPP now. Until then this version stays offline and leaves the data alone.") {
            Button { choosing = true } label: { Text("Continue With This Version").frame(maxWidth: .infinity, minHeight: 44) }
                .accessibilityIdentifier("upgradeAgain")
        }
        .sheet(isPresented: $choosing) {
            NavigationStack {
                UpgradeChoiceView(model: model, state: state)
                    .background(Color(.systemGroupedBackground))
                    .toolbar { ToolbarItem(placement: .cancellationAction) { Button("Cancel") { choosing = false } } }
            }
            .themedRoot()
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

/// Which data to continue with after a restore: this version's kept copy (the default: its messages stay readable
/// and nothing on the iPhone is dropped) or the restored data, upgraded afresh. Shown in a sheet from the restored
/// screen, and as the screen itself on the first launch after the previous version used the data.
struct UpgradeChoiceView: View {
    @Bindable var model: AppModel
    let state: PreUpgradeSnapshot.RestoredState
    @State private var confirmingReturn = false
    @State private var confirmingUpgrade = false
    @State private var working = false

    private var ran: Bool { state.previousVersionRan }
    private var restoredAt: String { state.restored.restoredAt.formatted(date: .abbreviated, time: .shortened) }
    private var rolledBack: String? { state.rolledBack.isEmpty ? nil : state.rolledBack.formatted(.list(type: .and)) }
    private var sentThere: String? { state.sentOnPreviousVersion.isEmpty ? nil : state.sentOnPreviousVersion.formatted(.list(type: .and)) }
    private var upgradeTitle: String { ran ? "Upgrade the Previous Version’s Data" : "Upgrade the Restored Data" }

    private var intro: String {
        let start = ran ? "The previous version of Haus XMPP used your data after the restore on \(restoredAt)."
                        : "You restored the previous version’s data on \(restoredAt)."
        if state.thisVersionUnreadable {
            return start + " This version kept a copy of its own data from then, but it can’t be read, so it cannot be put back. It stays on this \(ThisDevice.noun) until you delete the backup in Settings."
        }
        guard state.thisVersion != nil else { return start + " This version’s own data from then is no longer on this \(ThisDevice.noun)." }
        return start + " This version kept its own data from that moment. Choose which to continue with."
    }

    private var returnCaption: String {
        ran ? "Your messages from this version are readable again; messages received on the previous version are fetched from the server again, some may be unreadable, and what you sent there is not shown."
            : "Everything is back as it was in this version before the restore, and messages that arrived since are fetched from the server."
    }

    private var upgradeCaption: String {
        let start = ran ? "Continues from what the previous version left" : "Continues from the restored data"
        let deleted = state.thisVersion == nil ? "" : ", and this version’s own data is deleted"
        guard let rolledBack else { return start + deleted + "." }
        return start + "; messages received in \(rolledBack) after your first reply on this version stay unreadable" + deleted + "."
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 24) {
                VStack(spacing: 12) {
                    Image(systemName: "arrow.triangle.branch").font(.system(size: 48)).foregroundStyle(.secondary).accessibilityHidden(true)
                    Text("Continue With Which Data?").font(.title2.weight(.bold)).accessibilityAddTraits(.isHeader)
                    Text(intro).foregroundStyle(.secondary)
                }
                .multilineTextAlignment(.center)
                .frame(maxWidth: .infinity)
                if state.thisVersion != nil {
                    option(caption: returnCaption) {
                        Button { confirmingReturn = true } label: { Text("Return to This Version’s Data").frame(maxWidth: .infinity) }
                            .buttonStyle(.borderedProminent)
                            .accessibilityIdentifier("returnToThisVersion")
                    }
                }
                option(caption: upgradeCaption) {
                    Button { confirmingUpgrade = true } label: { Text(upgradeTitle).frame(maxWidth: .infinity) }
                        .buttonStyle(.bordered)
                        .accessibilityIdentifier("upgradeRestoredData")
                }
            }
            .controlSize(.large)
            .disabled(working)
            .padding(.horizontal, 24)
            .padding(.vertical, 32)
            .frame(maxWidth: 520)
            .frame(maxWidth: .infinity)
        }
        .confirmationDialog("Return to this version’s data?", isPresented: $confirmingReturn, titleVisibility: .visible) {
            Button("Return to This Version’s Data") { run { await model.returnToThisVersion() } }
        } message: {
            Text(returnConfirmation)
        }
        .confirmationDialog(ran ? "Upgrade the previous version’s data?" : "Upgrade the restored data?", isPresented: $confirmingUpgrade, titleVisibility: .visible) {
            Button(state.thisVersion == nil ? "Upgrade" : "Delete This Version’s Data and Upgrade", role: .destructive) { run { await model.upgradeRestoredData() } }
        } message: {
            Text(upgradeConfirmation)
        }
    }

    private var returnConfirmation: String {
        guard ran else { return "Your data returns to how it was in this version on \(restoredAt). The backup of the previous version’s data stays." }
        var text = "The previous version’s data becomes the backup, so you can still go back to it. Messages received there are fetched from the server again; some may be unreadable, and what you sent there is not shown here."
        if let sentThere {
            text += " You sent encrypted messages in \(sentThere) on the previous version: if messages there fail to decrypt, repair the encryption session (chat details, Encryption, the device)."
        }
        return text
    }

    private var upgradeConfirmation: String {
        var text = state.thisVersion != nil ? "This version’s own data from \(restoredAt) is deleted. "
            : state.thisVersionUnreadable ? "This version’s unreadable copy of its data stays until you delete the backup in Settings. " : ""
        if let rolledBack {
            text += "In \(rolledBack), messages received after your first reply on this version stay unreadable, and group sessions stay broken. "
        }
        return text + "This cannot be undone."
    }

    private func option(caption: String, @ViewBuilder button: () -> some View) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            button()
            Text(caption).font(.footnote).foregroundStyle(.secondary)
        }
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
    /// Chats where this version sent encrypted messages since the backup; a restore rolls their sessions back.
    @State private var rolledBack: [String] = []

    private var taken: String { backup.takenAt.formatted(date: .abbreviated, time: .shortened) }
    private var rolledBackList: String { rolledBack.formatted(.list(type: .and)) }

    var body: some View {
        NavigationStack {
            List {
                Section {
                    LabeledContent("Taken", value: taken)
                } footer: {
                    Text(Date() >= backup.suggestDeletionAfter
                         ? "This backup is more than two weeks old. Delete it if you will not go back to the previous version."
                         : "Haus XMPP copied your data before this version upgraded it, so you can go back to the previous version. It stays until you delete it.")
                }
                Section("Restoring brings back") {
                    Label("Messages, chats and read state as of \(taken)", systemImage: "bubble.left.and.bubble.right")
                    Label("Encryption keys, sessions and trust decisions", systemImage: "key")
                    Label("Your account, notification and app settings", systemImage: "gearshape")
                }
                Section("It does not bring back") {
                    Label("Messages sent or received since. The previous version fetches received ones from the server again.", systemImage: "clock.arrow.circlepath")
                    Label("Changes made in this version since, such as settings or trust decisions", systemImage: "slider.horizontal.3")
                }
                if !rolledBack.isEmpty {
                    Section {
                        ForEach(rolledBack, id: \.self) { Text($0) }
                    } header: {
                        Text("Unreadable on the previous version")
                    } footer: {
                        Text("You replied in these chats on this version. The previous version cannot decrypt messages received in them after your first reply here, and messages fail in both directions until you repair the session there (chat details, Encryption, the device). Group chats cannot be repaired in the previous version.")
                    }
                }
                Section {
                    Label("This version’s data, with its messages readable, so you can return to it", systemImage: "externaldrive")
                } header: {
                    Text("Restoring keeps a copy of")
                } footer: {
                    Text(model.keptCopyUnreadable
                         ? "A copy of this version’s data kept at an earlier restore can’t be read; restoring replaces it. Both copies, including your saved password, stay on this \(ThisDevice.noun) until you open this version again and delete them. The previous version cannot delete them."
                         : "Both copies, including your saved password, stay on this \(ThisDevice.noun) until you open this version again and delete them. The previous version cannot delete them.")
                }
                Section {
                    Button("Restore previous version’s data") { confirmingRestore = true }
                        .accessibilityIdentifier("restorePreviousVersion")
                    Button("Delete backup", role: .destructive) { confirmingDelete = true }
                        .accessibilityIdentifier("deletePreviousVersionBackup")
                }
            }
            .task { rolledBack = await model.chatsWithEncryptedSendsSinceBackup() }
            .navigationTitle("Previous Version Backup")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .confirmationAction) { Button("Done") { dismiss() } } }
        }
        .confirmationDialog("Restore previous version’s data?", isPresented: $confirmingRestore, titleVisibility: .visible) {
            Button("Restore previous version’s data", role: .destructive) {
                dismiss()
                Task { await model.restorePreviousVersion() }
            }
        } message: {
            Text(restoreConfirmation)
        }
        .confirmationDialog("Delete backup?", isPresented: $confirmingDelete, titleVisibility: .visible) {
            Button("Delete backup", role: .destructive) {
                model.deletePreviousVersionBackup()
                dismiss()
            }
        } message: {
            Text("You will no longer be able to go back to the previous version on this \(ThisDevice.noun).")
        }
    }

    private var restoreConfirmation: String {
        var text = "This version goes offline and your data returns to how it was on \(taken). "
        if !rolledBack.isEmpty {
            text += "In \(rolledBackList), messages received after your first reply here will be unreadable on the previous version, and group chats cannot be repaired there. "
        }
        if model.keptCopyUnreadable { text += "The unreadable copy of this version’s data from an earlier restore is replaced. " }
        return text + "This version keeps a copy of its own data. The backups stay on this \(ThisDevice.noun) until you open this version again and delete them. Then install the previous version."
    }
}
