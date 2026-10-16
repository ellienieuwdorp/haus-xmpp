import AppKit
import PhotosUI
import SwiftUI
import UniformTypeIdentifiers

/// A file in the composer's tray: being reduced to what will be uploaded, then ready to send.
struct MacTrayItem: Identifiable {
    let id = UUID()
    /// The file's name, or the kind of a picture with no file behind it; shown while it is prepared.
    let label: String
    /// Nil while it is being prepared.
    var prepared: PreparedAttachment?
    var preview: NSImage?
}

/// How picked, pasted and dropped files reach the tray, as the iPhone's `addToTray` does it: picking never sends,
/// each file is reduced (`AttachmentPreparer`) in the order it came, and one that is too large or unreadable shows why
/// and is left out while the rest still land. Each file holds its place in the tray from the start, so a slow video
/// cannot let a later photo jump ahead of it.
@MainActor enum MacAttachmentIntake {
    struct Job {
        let label: String
        let prepare: () async throws -> PreparedAttachment
    }

    static func jobs(for attachments: MacComposerAttachments, limit: Int) -> [Job] {
        switch attachments {
        case .files(let urls):
            urls.map { url in
                Job(label: url.lastPathComponent) {
                    try await AttachmentPreparer.prepare(fileURL: url, name: url.lastPathComponent, type: UTType(filenameExtension: url.pathExtension), limit: limit)
                }
            }
        case .image(let data, _):
            [Job(label: "Photo") { try AttachmentPreparer.prepareImage(data, name: "photo", limit: limit) }]
        case .pdf(let data):
            [Job(label: "Document") {
                guard data.count <= limit else { throw AttachmentPreparer.Failure.tooLarge(limit: limit) }
                return PreparedAttachment(data: data, name: "Scan.pdf", mediaType: "application/pdf", width: nil, height: nil)
            }]
        }
    }

    static func jobs(forPhotos items: [PhotosPickerItem], limit: Int) -> [Job] {
        items.map { item in
            Job(label: item.supportedContentTypes.contains { $0.conforms(to: .movie) } ? "Video" : "Photo") {
                try await AttachmentPreparer.prepare(photo: item, limit: limit)
            }
        }
    }

    /// Up to `ComposerPlan.trayLimit` files in the tray; beyond that the user is told and the rest are left out.
    static func add(_ jobs: [Job], to state: MacComposerState, model: AppModel) {
        guard !jobs.isEmpty else { return }
        let room = ComposerPlan.trayLimit - state.tray.count
        if jobs.count > room { model.error = "You can attach up to \(ComposerPlan.trayLimit) files at a time." }
        let accepted = Array(jobs.prefix(max(0, room)))
        guard !accepted.isEmpty else { return }
        let items = accepted.map { MacTrayItem(label: $0.label) }
        state.tray.append(contentsOf: items)
        let previous = state.preparation
        let account = model.accountID
        state.preparation = Task {
            await previous?.value
            for (item, job) in zip(items, accepted) {
                // Removed from the tray while it waited its turn.
                guard state.tray.contains(where: { $0.id == item.id }) else { continue }
                do {
                    let prepared = try await job.prepare()
                    let preview = await AttachmentThumbnails.preview(of: prepared)
                    guard let index = state.tray.firstIndex(where: { $0.id == item.id }) else { continue }
                    state.tray[index].prepared = prepared
                    state.tray[index].preview = preview
                } catch {
                    state.tray.removeAll { $0.id == item.id }
                    guard model.accountID == account else { continue }
                    model.error = (error as? LocalizedError)?.errorDescription ?? "\(item.label) could not be attached."
                }
            }
        }
    }

    /// A drop onto the conversation, one job per dragged item: a file, else an image or PDF with no file behind it (a
    /// photo dragged from a web page or from Photos). Each holds its place in the tray as soon as it is dropped, so Send
    /// waits for it, and its bytes are read only in its turn, so a large drop beyond the tray's room is never loaded.
    static func jobs(for providers: [NSItemProvider], limit: Int) -> [Job] {
        providers.compactMap { provider in
            if provider.hasItemConformingToTypeIdentifier(UTType.fileURL.identifier) {
                return Job(label: provider.suggestedName ?? "File") {
                    guard let url = await fileURL(from: provider) else { throw AttachmentPreparer.Failure.unreadable }
                    return try await AttachmentPreparer.prepare(fileURL: url, name: url.lastPathComponent, type: UTType(filenameExtension: url.pathExtension), limit: limit)
                }
            }
            guard let type = [UTType.image, .pdf].first(where: { provider.hasItemConformingToTypeIdentifier($0.identifier) }) else { return nil }
            let name = provider.suggestedName ?? (type == .pdf ? "Document" : "photo")
            return Job(label: provider.suggestedName ?? (type == .pdf ? "Document" : "Photo")) {
                let copy = try await fileCopy(from: provider, type: type)
                defer { try? FileManager.default.removeItem(at: copy.deletingLastPathComponent()) }
                let named = (name as NSString).pathExtension.isEmpty && type == .pdf ? name + ".pdf" : name
                return try await AttachmentPreparer.prepare(fileURL: copy, name: named, type: type, limit: limit)
            }
        }
    }

    private static func fileURL(from provider: NSItemProvider) async -> URL? {
        await withCheckedContinuation { continuation in
            _ = provider.loadObject(ofClass: URL.self) { url, _ in continuation.resume(returning: url?.isFileURL == true ? url : nil) }
        }
    }

    /// The item as a file of our own: the provider's file is gone once its handler returns. A file rather than data,
    /// so the provider never has to hold the whole item in memory to hand it over.
    private static func fileCopy(from provider: NSItemProvider, type: UTType) async throws -> URL {
        try await withCheckedThrowingContinuation { continuation in
            _ = provider.loadFileRepresentation(for: type) { url, _, error in
                guard let url else { return continuation.resume(throwing: error ?? AttachmentPreparer.Failure.unreadable) }
                do {
                    let folder = FileManager.default.temporaryDirectory.appending(path: "Drops/\(UUID().uuidString)", directoryHint: .isDirectory)
                    try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
                    let copy = folder.appending(path: url.lastPathComponent)
                    try FileManager.default.copyItem(at: url, to: copy)
                    continuation.resume(returning: copy)
                } catch {
                    continuation.resume(throwing: error)
                }
            }
        }
    }
}

/// Files and images dropped anywhere on the open chat join its composer's tray, as a drop on the field does. Refused
/// where the composer would refuse them: a group, a server without uploads, an edit in progress.
struct MacAttachmentDrop: DropDelegate {
    static let types: [UTType] = [.fileURL, .image, .pdf]
    let model: AppModel
    let chatID: String
    let intent: MacComposerIntent
    @Binding var targeted: Bool

    private var canAttach: Bool {
        !model.isGroup(chatID) && model.canSendAttachments && !model.isBlocked(chatID) && intent.editing == nil
    }

    func validateDrop(info: DropInfo) -> Bool { canAttach && info.hasItemsConforming(to: Self.types) }
    func dropEntered(info: DropInfo) { targeted = validateDrop(info: info) }
    func dropExited(info: DropInfo) { targeted = false }
    func dropUpdated(info: DropInfo) -> DropProposal? { DropProposal(operation: validateDrop(info: info) ? .copy : .forbidden) }

    func performDrop(info: DropInfo) -> Bool {
        targeted = false
        guard validateDrop(info: info) else { return false }
        let state = MacComposerDrafts.state(account: model.accountID, chat: chatID)
        let jobs = MacAttachmentIntake.jobs(for: info.itemProviders(for: Self.types), limit: model.attachmentLimit)
        MacAttachmentIntake.add(jobs, to: state, model: model)
        intent.focusComposer()
        return true
    }
}

/// The files waiting for Send, above the field inside the composer's glass: a sideways strip of 64 pt tiles, photos
/// and videos as stills, other files as a card with their name and size, each with its own remove button. A file
/// still being prepared shows a spinner in its place.
struct MacAttachmentTray: View {
    let items: [MacTrayItem]
    /// While Send works through the tray, removing an item could no longer stop it going out.
    let frozen: Bool
    let onRemove: (UUID) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            if items.count > 1 {
                Text("\(items.count) attachments").font(.caption).foregroundStyle(.secondary).padding(.leading, 14)
            }
            ScrollView(.horizontal) {
                HStack(spacing: 8) {
                    ForEach(Array(items.enumerated()), id: \.element.id) { index, item in tile(item, index: index) }
                }
                .padding(.horizontal, 10)
            }
            .scrollIndicators(.never)
        }
        .padding(.top, 10)
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Attachments")
        .accessibilityIdentifier("attachmentTray")
    }

    private func tile(_ item: MacTrayItem, index: Int) -> some View {
        let kind = item.prepared.map { $0.mediaType.hasPrefix("image/") ? "Photo" : $0.mediaType.hasPrefix("video/") ? "Video" : $0.name } ?? item.label
        // Photos all share one name, so the position tells VoiceOver users which one a control means.
        let label = items.count > 1 ? "\(kind), \(index + 1) of \(items.count)" : kind
        return Group {
            if let prepared = item.prepared {
                if let preview = item.preview {
                    // Fill a fixed square rather than framing the image, so its accessibility frame is the tile's.
                    Color.clear.frame(width: 64, height: 64)
                        .overlay { Image(nsImage: preview).resizable().scaledToFill() }
                        .clipped()
                        .overlay(alignment: .bottomLeading) {
                            if prepared.mediaType.hasPrefix("video/") {
                                Image(systemName: "video.fill").font(.caption2).foregroundStyle(.white).shadow(radius: 2).padding(6)
                            }
                        }
                } else {
                    card(name: prepared.name, detail: ByteCountFormatter.string(fromByteCount: Int64(prepared.data.count), countStyle: .file)) {
                        Image(systemName: "doc.fill").font(.title3).foregroundStyle(.tint)
                    }
                }
            } else {
                card(name: item.label, detail: "Preparing…") { ProgressView().controlSize(.small) }
            }
        }
        .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(item.prepared == nil ? "\(label), preparing" : label)
        .overlay(alignment: .topTrailing) {
            Button { onRemove(item.id) } label: {
                Image(systemName: "xmark.circle.fill").font(.system(size: 16))
                    .symbolRenderingMode(.palette).foregroundStyle(.white, .black.opacity(0.55))
                    .padding(3)
                    .frame(width: 28, height: 28, alignment: .topTrailing).contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .disabled(frozen)
            .help("Remove")
            .accessibilityLabel("Remove \(label)")
            .accessibilityIdentifier("removeAttachment")
        }
    }

    private func card(name: String, detail: String, @ViewBuilder icon: () -> some View) -> some View {
        HStack(spacing: 8) {
            icon().frame(width: 22)
            VStack(alignment: .leading, spacing: 1) {
                Text(name).font(.callout.weight(.semibold)).lineLimit(1).truncationMode(.middle)
                Text(detail).font(.caption).foregroundStyle(.secondary)
            }
        }
        .padding(.leading, 10).padding(.trailing, 26)
        .frame(width: 168, height: 64, alignment: .leading)
        .background(Color.tertiaryFill)
    }
}

/// Over the chat while files dragged over it would join the tray.
struct MacAttachmentDropHighlight: View {
    @Environment(\.appearance) private var appearance

    var body: some View {
        let tint = Color(platform: appearance.accent.tint)
        RoundedRectangle(cornerRadius: 14, style: .continuous)
            .strokeBorder(tint, style: StrokeStyle(lineWidth: 2, dash: [8, 6]))
            .background(tint.opacity(0.06), in: RoundedRectangle(cornerRadius: 14, style: .continuous))
            .overlay {
                Label("Drop to Attach", systemImage: "paperclip")
                    .font(.headline).foregroundStyle(tint)
                    .padding(.horizontal, 14).padding(.vertical, 8)
                    .background(.regularMaterial, in: Capsule())
            }
            .padding(8)
            .allowsHitTesting(false)
            .accessibilityHidden(true)
    }
}

#if DEBUG
/// `-haus-tour`'s attachment steps (`MacDebugHooks`), through the composer's own paths: `attach` hands files to its
/// seam as a drop on the field would, `drop` hands item providers to the tray as a drop on the chat would, `paste` and
/// `import` go through the text view's pasteboard reading (from a private pasteboard, never the user's),
/// `remove-attachment` uses the tray's remove, `copy-image` copies a bubble's photo to a private pasteboard and logs what
/// landed there, and `save-over` runs Save As…'s copy over an existing file and logs what is left of it.
@MainActor enum MacAttachmentTour {
    private static let pasteboard = NSPasteboard(name: NSPasteboard.Name("haus.tour.attachments"))

    static func step(_ step: String, _ argument: String, model: AppModel) {
        guard let textView = MacComposerTour.textView, let actions = textView.actions else { MacDebugHooks.log("tour \(step): no composer"); return }
        let state = MacComposerDrafts.state(account: model.accountID, chat: model.messagesLoadedFor ?? "")
        switch step {
        case "attach":
            // `photo`, `file`, `scan`, or a path the sandbox can read (inside the app's container).
            let attachments: MacComposerAttachments? = switch argument {
            case "photo": DemoArt.lakePhotoJPEG().map { .image($0, .jpeg) }
            case "file": sampleFile().map { .files([$0]) }
            case "scan": samplePDF().map { .pdf($0) }
            default: .files([URL(fileURLWithPath: argument)])
            }
            MacDebugHooks.log("tour attach \(argument): \(attachments.map { actions.attach($0) ? "taken" : "refused" } ?? "no sample")")
        case "paste", "import":
            pasteboard.clearContents()
            switch argument {
            case "photo": pasteboard.setData(DemoArt.lakePhotoJPEG(), forType: NSPasteboard.PasteboardType(UTType.jpeg.identifier))
            case "file": if let url = sampleFile() { pasteboard.writeObjects([url as NSURL]) }
            case "scan": pasteboard.setData(samplePDF(), forType: .pdf)
            default: pasteboard.setString(argument, forType: .string)
            }
            if step == "import" {
                // What Continuity Camera asks before it offers its items, then how it hands over what it took.
                let returnType = pasteboard.types?.first ?? .string
                let requestor = textView.validRequestor(forSendType: nil, returnType: returnType)
                MacDebugHooks.log("tour import \(argument): requestor \(requestor.map { "\(type(of: $0))" } ?? "none") for \(returnType.rawValue)")
                guard requestor != nil else { return }
            }
            MacDebugHooks.log("tour \(step) \(argument): read \(textView.readSelection(from: pasteboard)), draft \(textView.string.count) characters")
        case "drop":
            // `photo`, `slow-photo` (whose source takes two seconds to hand it over), `file` or `scan`, as item providers
            // dropped on the chat.
            let provider: NSItemProvider? = switch argument {
            case "photo", "slow-photo": DemoArt.lakePhotoJPEG().map { data in
                let provider = NSItemProvider()
                let delay: TimeInterval = argument == "slow-photo" ? 2 : 0
                provider.registerDataRepresentation(for: .jpeg) { load in
                    DispatchQueue.global().asyncAfter(deadline: .now() + delay) { load(data, nil) }
                    return nil
                }
                return provider
            }
            case "file": sampleFile().map { NSItemProvider(object: $0 as NSURL) }
            case "scan": samplePDF().map { NSItemProvider(item: $0 as NSData, typeIdentifier: UTType.pdf.identifier) }
            default: nil
            }
            guard let provider else { MacDebugHooks.log("tour drop \(argument): no sample"); return }
            MacAttachmentIntake.add(MacAttachmentIntake.jobs(for: [provider], limit: model.attachmentLimit), to: state, model: model)
        case "save-over":
            // Save As… over an existing file, first from a source that cannot be read, then from the newest photo.
            let folder = FileManager.default.temporaryDirectory.appending(path: "SaveOver", directoryHint: .isDirectory)
            let destination = folder.appending(path: "Existing.jpg")
            try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            try? Data("existing".utf8).write(to: destination)
            let missing = Result { try MacAttachmentActions.save(folder.appending(path: "missing.jpg"), to: destination) }
            let kept = (try? Data(contentsOf: destination)) == Data("existing".utf8)
            let photo = model.messages.last { $0.attachment?.mediaType.hasPrefix("image/") == true }.flatMap { model.attachmentFiles[$0.id] }
            let replaced = photo.map { photo in Result { try MacAttachmentActions.save(photo, to: destination) } }
            let matches = photo.flatMap { try? Data(contentsOf: $0) } == (try? Data(contentsOf: destination))
            MacDebugHooks.log("tour save-over: unreadable source \((try? missing.get()) == nil ? "failed" : "saved"), existing kept \(kept); photo \(replaced.map { (try? $0.get()) == nil ? "failed" : "saved" } ?? "none"), replaced \(matches)")
            try? FileManager.default.removeItem(at: folder)
        case "remove-attachment":
            if let index = Int(argument), state.tray.indices.contains(index) { state.tray.remove(at: index) }
        case "copy-image":
            let message = argument == "newest" ? model.messages.last { $0.attachment?.mediaType.hasPrefix("image/") == true } : model.messages.first { $0.id == argument }
            guard let message, let url = model.attachmentFiles[message.id] else { MacDebugHooks.log("tour copy-image \(argument): no photo on disk"); return }
            let copied = MacAttachmentActions.copyImage(at: url, to: pasteboard)
            let name = message.attachment.map { MacAttachmentActions.fileName(for: TimelineAttachment(name: $0.name, mediaType: $0.mediaType, size: $0.size, width: $0.width, height: $0.height), at: url) } ?? "-"
            MacDebugHooks.log("tour copy-image \(message.id): \(copied), types \(pasteboard.types?.map(\.rawValue) ?? []), file name \(name)")
        default: break
        }
        MacDebugHooks.log("tray: \(state.tray.count) items, \(state.tray.filter { $0.prepared != nil }.count) ready, sending \(state.sending)")
    }

    /// A one-page PDF itinerary in the app's temporary directory, standing in for a file picked in Finder.
    private static func sampleFile() -> URL? {
        guard let data = samplePDF() else { return nil }
        let url = FileManager.default.temporaryDirectory.appending(path: "Itinerary.pdf")
        return (try? data.write(to: url)) == nil ? nil : url
    }

    private static func samplePDF() -> Data? {
        let data = NSMutableData()
        var box = CGRect(x: 0, y: 0, width: 595, height: 842)
        guard let consumer = CGDataConsumer(data: data), let context = CGContext(consumer: consumer, mediaBox: &box, nil) else { return nil }
        context.beginPDFPage(nil)
        context.setFillColor(CGColor(red: 0.2, green: 0.45, blue: 0.8, alpha: 1))
        context.fill(CGRect(x: 60, y: 700, width: 475, height: 60))
        context.endPDFPage()
        context.closePDF()
        return data as Data
    }
}
#endif
