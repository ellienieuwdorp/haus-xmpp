import SwiftUI

/// Replaces the app while the database holds encryption state this iPhone can no longer open (`AppModel.keyRecovery`).
/// Nothing behind it connects or changes storage; only the confirmed button starts encryption over.
struct KeyRecoveryView: View {
    @Bindable var model: AppModel
    @Environment(\.appearance) private var appearance
    @State private var confirming = false
    @State private var working = false

    var body: some View {
        if let plan = model.keyRecovery {
            content(plan)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .background(Color(.systemGroupedBackground))
        }
    }

    private func content(_ plan: KeyRecoveryPlan) -> some View {
        VStack(spacing: 0) {
            ScrollView {
                VStack(spacing: 24) {
                    VStack(spacing: 12) {
                        Image(systemName: "key.slash").font(.system(size: 52)).foregroundStyle(.orange).accessibilityHidden(true)
                        Text("Set up encryption again").font(.title2.weight(.bold)).accessibilityAddTraits(.isHeader)
                        Text("This \(ThisDevice.noun) can no longer read its saved encryption keys, so it can’t send or read encrypted messages. This can happen after moving to a new device or resetting the Keychain. The messages already on this \(ThisDevice.noun) stay readable, and nothing changes until you choose.")
                            .foregroundStyle(.secondary)
                    }
                    .multilineTextAlignment(.center)
                    VStack(alignment: .leading, spacing: 16) {
                        Text("Setting up again").font(.headline).accessibilityAddTraits(.isHeader)
                        ForEach(Self.consequences(plan), id: \.text) { item in
                            HStack(alignment: .firstTextBaseline, spacing: 12) {
                                Image(systemName: item.symbol).foregroundStyle(Color(appearance.accent.tint))
                                    .frame(width: 28).accessibilityHidden(true)
                                Text(item.text).frame(maxWidth: .infinity, alignment: .leading)
                            }
                        }
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(20)
                    .background(Color(.secondarySystemGroupedBackground), in: RoundedRectangle(cornerRadius: 16, style: .continuous))
                }
                .padding(.horizontal, 24)
                .padding(.vertical, 32)
                .frame(maxWidth: 520)
                .frame(maxWidth: .infinity)
            }
            Button { confirming = true } label: {
                Group {
                    if working { ProgressView() } else { Text("Set Up Encryption Again") }
                }
                .frame(maxWidth: .infinity, minHeight: 22)
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.large)
            .disabled(working)
            .padding(.horizontal, 24)
            .padding(.bottom, 16)
            .frame(maxWidth: 520)
            .accessibilityIdentifier("setUpEncryptionAgain")
        }
        .confirmationDialog("Set up encryption again?", isPresented: $confirming, titleVisibility: .visible) {
            Button("Set Up Encryption Again", role: .destructive) {
                working = true
                Task { await model.startEncryptionOver(); working = false }
            }
        } message: {
            Text(Self.confirmation(plan))
        }
    }

    struct Consequence { let symbol: String; let text: String }

    /// What starting over does, in the order it matters to the user; only lines that apply.
    static func consequences(_ plan: KeyRecoveryPlan) -> [Consequence] {
        var items: [Consequence] = []
        items.append(Consequence(symbol: "plus.circle", text: plan.account.isEmpty
            ? "A new encryption device is created the next time you sign in."
            : "A new encryption device is created for \(plan.account)."))
        items.append(Consequence(symbol: "person.2", text: "Your contacts and your other devices will see a new device to review before they can send to it."))
        items.append(Consequence(symbol: "checkmark.shield", text: "The devices you reviewed or verified are forgotten here. You’ll review your contacts’ devices again before you send."))
        if plan.waitingMessages > 0 {
            items.append(Consequence(symbol: "envelope.badge", text: plan.waitingMessages == 1
                ? "1 message waiting to be decrypted can’t be read any more and is shown as unreadable."
                : "\(plan.waitingMessages) messages waiting to be decrypted can’t be read any more and are shown as unreadable."))
        }
        items.append(Consequence(symbol: "doc", text: "Files you haven’t downloaded yet can’t be opened."))
        if plan.unsendableFiles > 0 {
            items.append(Consequence(symbol: "exclamationmark.circle", text: plan.unsendableFiles == 1
                ? "1 file waiting to be sent can’t be sent any more. Attach it again to send it."
                : "\(plan.unsendableFiles) files waiting to be sent can’t be sent any more. Attach them again to send them."))
        }
        if plan.otherAccounts > 0 {
            items.append(Consequence(symbol: "person.crop.circle", text: plan.otherAccounts == 1
                ? "Encryption is also reset for 1 other account used on this \(ThisDevice.noun)."
                : "Encryption is also reset for \(plan.otherAccounts) other accounts used on this \(ThisDevice.noun)."))
        }
        items.append(Consequence(symbol: "iphone.slash", text: plan.retiresOldDevices
            ? "The old device is removed from your account’s device list when you’re next online. If another iPhone or Mac still uses it, it comes back as a device to review."
            : "The old device stays in your account’s device list until you remove it from a chat’s Devices & Encryption."))
        return items
    }

    static func confirmation(_ plan: KeyRecoveryPlan) -> String {
        let others = switch plan.otherAccounts {
        case 0: ""
        case 1: " This also applies to 1 other account."
        default: " This also applies to \(plan.otherAccounts) other accounts."
        }
        return "This \(ThisDevice.noun)’s old encryption keys are discarded and a new encryption device is created.\(others) Messages encrypted for the old keys can never be read here. This cannot be undone."
    }
}
