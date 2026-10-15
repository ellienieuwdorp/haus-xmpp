import SwiftUI
import UniformTypeIdentifiers
import MessagingCore

/// Settings > Transfer to another app or device: what a transfer does, before anything changes.
struct TransferIntroView: View {
    @Bindable var model: AppModel
    @Environment(\.dismiss) private var dismiss
    @Environment(\.appearance) private var appearance

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(spacing: 20) {
                    Image(systemName: "shippingbox.and.arrow.backward.fill")
                        .font(.system(size: 52)).foregroundStyle(Color(appearance.accent.tint))
                        .accessibilityHidden(true)
                    Text("Move to another app or device").font(.title2.weight(.bold)).multilineTextAlignment(.center)
                        .accessibilityAddTraits(.isHeader)
                    VStack(alignment: .leading, spacing: 14) {
                        point("doc.zipper", "Your chats, files, settings and encryption keys for \(model.accountID) go into one file, locked with a code.")
                        point("arrow.down.app", "Restore it in Haus XMPP on another iPhone, on a Mac, or in another build of the app.")
                        point("lock.shield", "It’s a move, not a copy. Once the file is ready, Haus XMPP stays offline on this \(ThisDevice.noun), so only one install uses your keys. Contacts won’t see a new device.")
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    Button {
                        dismiss()
                        Task { await model.startTransfer() }
                    } label: {
                        Text("Prepare Transfer File").font(.headline).frame(maxWidth: .infinity, minHeight: 44)
                    }
                    .buttonStyle(.borderedProminent)
                    .controlSize(.large)
                    .disabled(!model.canTransfer)
                    .accessibilityIdentifier("prepareTransfer")
                }
                .padding(24)
                .frame(maxWidth: 520)
                .frame(maxWidth: .infinity)
            }
            .background(Color.groupedBackground)
            .inlineNavigationTitle()
            .toolbar { ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } } }
        }
    }

    private func point(_ symbol: String, _ text: String) -> some View {
        Label {
            Text(text).fixedSize(horizontal: false, vertical: true)
        } icon: {
            Image(systemName: symbol).foregroundStyle(Color(appearance.accent.tint)).frame(width: 28)
        }
        .labelStyle(.titleAndIcon)
    }
}

/// Replaces the app while its data is packed for another install and afterwards, until the user deletes this
/// install's copy or takes the data back. Nothing behind it connects or opens storage.
struct TransferBlockingView: View {
    @Bindable var model: AppModel
    @Environment(\.appearance) private var appearance
    @State private var confirmingDelete = false
    @State private var resuming = false
    @State private var working = false
    @State private var saveFailed = false

    var body: some View {
        Group {
            switch model.transferState {
            case .exporting(let progress): exporting(progress)
            case .moved(let moved): movedView(moved)
            case .settling, .none:
                ProgressView().controlSize(.large)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Color.groupedBackground)
    }

    private func exporting(_ progress: AccountTransfer.Progress?) -> some View {
        let step: String
        switch progress?.step {
        case .encrypting?: step = "Encrypting…"
        case .checking?: step = "Checking the file…"
        default: step = "Copying your data…"
        }
        let overall = progress.map { (Double($0.step.rawValue) + $0.fraction) / 3 } ?? 0
        return VStack(spacing: 18) {
            Image(systemName: "shippingbox.fill").font(.system(size: 52)).foregroundStyle(Color(appearance.accent.tint))
                .accessibilityHidden(true)
            Text("Preparing transfer file").font(.title2.weight(.bold)).accessibilityAddTraits(.isHeader)
            ProgressView(value: min(max(overall, 0), 1)) { Text(step).font(.headline) }
                .accessibilityIdentifier("transferProgress")
            Text("Keep Haus XMPP open until this finishes.").font(.subheadline).foregroundStyle(.secondary).multilineTextAlignment(.center)
        }
        .padding(32)
        .frame(maxWidth: 520)
    }

    private func movedView(_ moved: AccountTransfer.Moved) -> some View {
        let file = model.transferFile(moved)
        return ScrollView {
            VStack(spacing: 20) {
                Image(systemName: "checkmark.seal.fill").font(.system(size: 52)).foregroundStyle(.green).accessibilityHidden(true)
                Text("Ready to move").font(.title2.weight(.bold)).multilineTextAlignment(.center).accessibilityAddTraits(.isHeader)
                Text("Save the file or send it with AirDrop. Then, in Haus XMPP where you want your chats, choose **Restore from a transfer** and enter this code.")
                    .foregroundStyle(.secondary).multilineTextAlignment(.center)
                if let code = TransferCode(moved.code) { TransferCodeCard(code: code) }
                VStack(spacing: 12) {
                    if let file {
                        ShareLink(item: file) {
                            Label("Share Transfer File", systemImage: "square.and.arrow.up").font(.headline).frame(maxWidth: .infinity, minHeight: 44)
                        }
                        .buttonStyle(.borderedProminent)
                        .accessibilityIdentifier("shareTransfer")
                        #if os(macOS)
                        Button {
                            do { _ = try PlatformFileSave.save(file) } catch { saveFailed = true }
                        } label: { Text("Save…").frame(maxWidth: .infinity, minHeight: 44) }
                        .buttonStyle(.bordered)
                        #endif
                        Text("\(moved.fileName) · \(ByteCountFormatter.string(fromByteCount: moved.fileSize, countStyle: .file))")
                            .font(.footnote).foregroundStyle(.secondary).multilineTextAlignment(.center)
                    }
                }
                .controlSize(.large)
                Divider().padding(.vertical, 4)
                VStack(spacing: 12) {
                    Text("Haus XMPP stays offline here until you finish.").font(.subheadline).foregroundStyle(.secondary).multilineTextAlignment(.center)
                    Button(role: .destructive) { confirmingDelete = true } label: {
                        Text("Delete Data From This \(ThisDevice.noun)…").frame(maxWidth: .infinity, minHeight: 44)
                    }
                    .buttonStyle(.bordered)
                    .tint(.red)
                    .accessibilityIdentifier("deleteMovedData")
                    Button { resuming = true } label: { Text("Use on This \(ThisDevice.noun) Again…").frame(maxWidth: .infinity, minHeight: 44) }
                        .accessibilityIdentifier("useHereAgain")
                }
                .controlSize(.large)
                .disabled(working)
            }
            .padding(24)
            .frame(maxWidth: 520)
            .frame(maxWidth: .infinity)
        }
        .confirmationDialog("Delete data from this \(ThisDevice.noun)?", isPresented: $confirmingDelete, titleVisibility: .visible) {
            Button("Delete Data", role: .destructive) { run { await model.deleteMovedData() } }
        } message: {
            Text("Do this once Haus XMPP on the other device shows your chats. Your messages, files, keys and settings are removed from this \(ThisDevice.noun). The transfer file you saved elsewhere is not affected.")
        }
        .sheet(isPresented: $resuming) {
            UseHereAgainView { run { await model.useDataHereAgain() } }.themedRoot()
        }
        .alert("The file could not be saved", isPresented: $saveFailed) { Button("OK", role: .cancel) {} }
    }

    private func run(_ action: @escaping () async -> Void) {
        working = true
        Task { await action(); working = false }
    }
}

/// The transfer code, large and monospaced in its six groups, selectable, with a copy button.
struct TransferCodeCard: View {
    let code: TransferCode
    @State private var copied = false

    var body: some View {
        VStack(spacing: 12) {
            Text("Transfer code").font(.subheadline.weight(.semibold)).foregroundStyle(.secondary)
            ViewThatFits(in: .horizontal) {
                rows(of: 3)
                rows(of: 2)
            }
            .textSelection(.enabled)
            .accessibilityElement(children: .ignore)
            .accessibilityLabel(Text("Transfer code \(code.groups.joined(separator: ", "))").speechSpellsOutCharacters())
            Button {
                PlatformPasteboard.copy(code.grouped)
                copied = true
            } label: {
                Label(copied ? "Copied" : "Copy Code", systemImage: copied ? "checkmark" : "doc.on.doc").frame(minHeight: 44)
            }
            .accessibilityIdentifier("copyTransferCode")
            Text("Keep the code apart from the file: together they open your account.")
                .font(.footnote).foregroundStyle(.secondary).multilineTextAlignment(.center)
        }
        .padding(20)
        .frame(maxWidth: .infinity)
        .background(Color.secondaryGroupedBackground, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
    }

    private func rows(of width: Int) -> some View {
        VStack(spacing: 8) {
            ForEach(Array(stride(from: 0, to: code.groups.count, by: width)), id: \.self) { start in
                HStack(spacing: 14) {
                    ForEach(code.groups[start..<min(start + width, code.groups.count)], id: \.self) { group in
                        Text(group).font(.system(.title, design: .monospaced).weight(.semibold)).fixedSize()
                    }
                }
            }
        }
        .accessibilityIdentifier("transferCode")
    }
}

/// "Use on This iPhone Again": allowed only after the user typed the word, because restoring the same file elsewhere
/// too would put one identity on two installs.
private struct UseHereAgainView: View {
    let confirm: () -> Void
    @Environment(\.dismiss) private var dismiss
    @State private var typed = ""
    private var confirmed: Bool { typed.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() == "resume" }

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    Text("Only do this if the transfer file was never restored anywhere.")
                        .font(.headline)
                    Text("If it was, two installs would share your encryption keys: contacts’ messages would stop opening on one of them, and their sessions could break.")
                    Text("The transfer file is deleted from this \(ThisDevice.noun). Delete any copies you saved, too.")
                }
                Section {
                    TextField("Type resume to confirm", text: $typed)
                        .noAutocapitalization().autocorrectionDisabled()
                        .accessibilityIdentifier("resumeConfirmation")
                }
                Section {
                    Button(role: .destructive) {
                        dismiss()
                        confirm()
                    } label: { Text("Use Here Again").frame(maxWidth: .infinity, minHeight: 44) }
                    .disabled(!confirmed)
                    .accessibilityIdentifier("confirmUseHereAgain")
                }
            }
            .groupedFormStyle()
            .navigationTitle("Use on this \(ThisDevice.noun) again?")
            .inlineNavigationTitle()
            .toolbar { ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } } }
        }
        .macSheetSize(width: 420, height: 420)
    }
}

/// Restore from a transfer: pick the file, enter its code, restore. Only for an install with no account of its own.
struct RestoreTransferView: View {
    @Bindable var model: AppModel
    @Environment(\.dismiss) private var dismiss
    @Environment(\.appearance) private var appearance
    @State private var file: URL?
    @State private var fileSize: Int64?
    @State private var choosing = false
    @State private var codeText = ""
    @State private var failure: String?
    @State private var restoring = false

    private var code: TransferCode? { TransferCode(codeText) }

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    VStack(spacing: 10) {
                        Image(systemName: "arrow.down.app.fill").font(.system(size: 46)).foregroundStyle(Color(appearance.accent.tint))
                            .accessibilityHidden(true)
                        Text("Restore from a transfer").font(.title2.weight(.bold)).multilineTextAlignment(.center)
                            .accessibilityAddTraits(.isHeader)
                        Text("Bring your chats, settings and keys from Haus XMPP on another device or build.")
                            .foregroundStyle(.secondary).multilineTextAlignment(.center)
                    }
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 12)
                    .listRowBackground(Color.clear)
                }
                Section("Transfer file") {
                    if let file {
                        HStack(spacing: 12) {
                            Image(systemName: "doc.fill").font(.title2).foregroundStyle(.secondary).accessibilityHidden(true)
                            VStack(alignment: .leading, spacing: 2) {
                                Text(file.lastPathComponent).lineLimit(2).truncationMode(.middle)
                                if let fileSize { Text(ByteCountFormatter.string(fromByteCount: fileSize, countStyle: .file)).font(.footnote).foregroundStyle(.secondary) }
                            }
                            .accessibilityElement(children: .combine)
                            Spacer(minLength: 8)
                            Button("Change") { choosing = true }
                                .disabled(restoring)
                                .accessibilityLabel("Choose another file")
                                .accessibilityIdentifier("chooseTransferFile")
                        }
                    } else {
                        Button("Choose File…") { choosing = true }
                            .disabled(restoring)
                            .accessibilityIdentifier("chooseTransferFile")
                    }
                }
                Section {
                    HStack {
                        TextField("XXXX-XXXX-XXXX-XXXX-XXXX-XXXX", text: $codeText, axis: .vertical)
                            .font(.system(.body, design: .monospaced))
                            .capitalizedCharacters().autocorrectionDisabled()
                            .textContentType(.oneTimeCode)
                            .accessibilityLabel("Transfer code")
                            .accessibilityIdentifier("transferCodeField")
                            // Once it reads as a code, it is shown the way the other device shows it.
                            .onChange(of: codeText) { _, text in
                                if let code = TransferCode(text), text != code.grouped { codeText = code.grouped }
                            }
                        PasteButton(payloadType: String.self) { strings in
                            if let text = strings.first { Task { @MainActor in codeText = text.trimmingCharacters(in: .whitespacesAndNewlines) } }
                        }
                        .labelStyle(.iconOnly)
                        .buttonBorderShape(.circle)
                    }
                    .disabled(restoring)
                } header: {
                    Text("Code")
                } footer: {
                    if !codeText.isEmpty, code == nil {
                        Text("The code is 24 letters and digits, in six groups of four.")
                    } else {
                        Text("Shown on the other device when it prepared the file.")
                    }
                }
                Section {
                    if restoring {
                        ProgressView(value: model.restoreProgress?.fraction ?? 0) { Text("Restoring…") }
                            .accessibilityIdentifier("restoreProgress")
                    } else {
                        Button {
                            guard let file, let code else { return }
                            failure = nil
                            restoring = true
                            Task {
                                let problem = await model.restoreTransfer(from: file, code: code)
                                restoring = false
                                if let problem { failure = problem } else { dismiss() }
                            }
                        } label: {
                            Text("Restore").font(.headline).frame(maxWidth: .infinity, minHeight: 44)
                        }
                        .buttonStyle(.borderedProminent)
                        .disabled(file == nil || code == nil || !model.canRestoreTransfer)
                        .accessibilityIdentifier("restoreTransfer")
                    }
                    if let failure {
                        Label(failure, systemImage: "exclamationmark.triangle.fill").foregroundStyle(.red)
                            .accessibilityIdentifier("restoreFailure")
                    }
                } footer: {
                    if model.isDemo { Text("The sample conversations are replaced.") }
                }
                .listRowBackground(restoring || failure != nil ? nil : Color.clear)
            }
            .groupedFormStyle()
            .inlineNavigationTitle()
            .toolbar { ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() }.disabled(restoring) } }
            .fileImporter(isPresented: $choosing, allowedContentTypes: [.data]) { result in
                guard case let .success(url) = result else { return }
                file = url
                failure = nil
                let scoped = url.startAccessingSecurityScopedResource()
                fileSize = (try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize).map(Int64.init)
                if scoped { url.stopAccessingSecurityScopedResource() }
            }
            .interactiveDismissDisabled(restoring)
        }
        .macSheetSize(width: 440, height: 600)
    }
}

extension AppModel {
    /// The moved state's archive, while it is there.
    func transferFile(_ moved: AccountTransfer.Moved) -> URL? {
        guard let url = transferArchiveURL(moved), FileManager.default.fileExists(atPath: url.path) else { return nil }
        return url
    }
}

extension View {
    /// A sheet's minimum size on the Mac, where it would otherwise shrink to its content; the iPhone's sheets fill the
    /// screen's width.
    func macSheetSize(width: CGFloat, height: CGFloat) -> some View {
        #if os(macOS)
        frame(minWidth: width, minHeight: height)
        #else
        self
        #endif
    }

    /// `.formStyle(.grouped)` on the Mac, the iPhone's default grouped form elsewhere.
    func groupedFormStyle() -> some View {
        #if os(macOS)
        formStyle(.grouped)
        #else
        self
        #endif
    }
}
