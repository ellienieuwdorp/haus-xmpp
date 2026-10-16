import AppKit
import SwiftUI
import UniformTypeIdentifiers

/// The bubble's items for a photo, video or file that is on this Mac: Copy Image (photos), Save As… and Share…. They
/// follow the message's own items in `MacMessageMenu`, so the right-click menus, the hover toolbar's More menu and the
/// row's VoiceOver actions all list them. Show in Finder is left out: the file lives in the app's container under a name
/// derived from its hash, which says nothing to the user; Save As… puts a copy where they want it.
struct MacAttachmentMenu {
    enum Kind { case copyImage, saveAs, share }

    struct Item {
        let kind: Kind
        let title: String
        /// An SF Symbol name.
        let symbol: String
    }

    let attachment: TimelineAttachment
    let url: URL

    init?(message: TimelineMessage) {
        guard let attachment = message.attachment, !message.showsPlaceholder, let url = attachment.localURL else { return nil }
        self.attachment = attachment
        self.url = url
    }

    var items: [Item] {
        (attachment.isImage ? [Item(kind: .copyImage, title: "Copy Image", symbol: "doc.on.doc")] : [])
            + [Item(kind: .saveAs, title: "Save As…", symbol: "square.and.arrow.down"),
               Item(kind: .share, title: "Share…", symbol: "square.and.arrow.up")]
    }

    @MainActor func perform(_ kind: Kind) {
        let name = MacAttachmentActions.fileName(for: attachment, at: url)
        switch kind {
        case .copyImage: MacAttachmentActions.copyImage(at: url, to: .general)
        case .saveAs: MacAttachmentActions.saveAs(url, name: name)
        case .share: MacAttachmentActions.share(url, name: name)
        }
    }
}

/// Lets a photo, video or file that is on this Mac be dragged out of its bubble (to Finder, Mail, another chat app),
/// under its own name rather than the cache's.
struct MacAttachmentDragSource: ViewModifier {
    let attachment: TimelineAttachment?

    func body(content: Content) -> some View {
        if let attachment, let url = attachment.localURL {
            content.onDrag { MacAttachmentActions.dragItem(url, name: MacAttachmentActions.fileName(for: attachment, at: url)) }
        } else {
            content
        }
    }
}

@MainActor enum MacAttachmentActions {
    /// The name the sender gave the file, or its kind, with the cached file's extension when it has none. Path
    /// separators in a sender's name never reach a path.
    static func fileName(for attachment: TimelineAttachment, at url: URL) -> String {
        var name = attachment.name.replacingOccurrences(of: "/", with: "-").replacingOccurrences(of: ":", with: "-")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        if name.isEmpty || name.hasPrefix(".") { name = attachment.kindLabel + name }
        if (name as NSString).pathExtension.isEmpty, !url.pathExtension.isEmpty { name += "." + url.pathExtension }
        return name
    }

    /// A save panel named after the file; the copy goes where the user chooses, replacing what they agreed to replace.
    static func saveAs(_ url: URL, name: String) {
        let panel = NSSavePanel()
        panel.nameFieldStringValue = name
        panel.canCreateDirectories = true
        let window = NSApp.keyWindow ?? NSApp.mainWindow
        let finish = { (response: NSApplication.ModalResponse) in
            guard response == .OK, let destination = panel.url else { return }
            do {
                try save(url, to: destination)
            } catch {
                let alert = NSAlert(error: error)
                if let window { alert.beginSheetModal(for: window) } else { alert.runModal() }
            }
        }
        if let window { panel.beginSheetModal(for: window, completionHandler: finish) } else { panel.begin(completionHandler: finish) }
    }

    /// Copies the file to a destination that may already hold one. An existing file is replaced only once the whole
    /// copy is made: a copy that fails (a full disk, an unreadable cache) leaves what was there untouched.
    static func save(_ url: URL, to destination: URL) throws {
        let manager = FileManager.default
        guard manager.fileExists(atPath: destination.path) else { return try manager.copyItem(at: url, to: destination) }
        let staging = try exportFolder()
        defer { try? manager.removeItem(at: staging) }
        let copy = staging.appending(path: destination.lastPathComponent)
        try manager.copyItem(at: url, to: copy)
        _ = try manager.replaceItemAt(destination, withItemAt: copy)
    }

    /// The system's share popover, at the pointer, which is where the menu item that asked for it was.
    static func share(_ url: URL, name: String) {
        guard let copy = try? namedCopy(of: url, name: name), let window = NSApp.keyWindow ?? NSApp.mainWindow, let view = window.contentView else { return }
        let point = view.convert(window.mouseLocationOutsideOfEventStream, from: nil)
        NSSharingServicePicker(items: [copy]).show(relativeTo: NSRect(origin: point, size: CGSize(width: 1, height: 1)), of: view, preferredEdge: .minY)
    }

    /// The photo's own bytes under its type, and TIFF for apps that only paste that.
    @discardableResult
    static func copyImage(at url: URL, to pasteboard: NSPasteboard) -> Bool {
        guard let image = NSImage(contentsOf: url) else { return false }
        let item = NSPasteboardItem()
        if let type = UTType(filenameExtension: url.pathExtension), type.conforms(to: .image), type != .tiff, let data = try? Data(contentsOf: url) {
            item.setData(data, forType: NSPasteboard.PasteboardType(type.identifier))
        }
        if let tiff = image.tiffRepresentation { item.setData(tiff, forType: .tiff) }
        pasteboard.clearContents()
        return pasteboard.writeObjects([item])
    }

    static func dragItem(_ url: URL, name: String) -> NSItemProvider {
        guard let copy = try? namedCopy(of: url, name: name), let provider = NSItemProvider(contentsOf: copy) else { return NSItemProvider() }
        provider.suggestedName = name
        return provider
    }

    /// Where shared and dragged copies wait for the app that takes them.
    private static var exports: URL { FileManager.default.temporaryDirectory.appending(path: "Exports", directoryHint: .isDirectory) }
    /// Whoever takes a shared or dragged copy (Finder, Mail, AirDrop) has made its own by then.
    private static let exportLifetime: TimeInterval = 3600

    /// A copy of the cached file under its own name, in a folder of its own so two files of one name never collide.
    /// A clone on APFS, so it takes no space until one of them changes. It goes an hour later, or at the next launch.
    static func namedCopy(of url: URL, name: String) throws -> URL {
        removeExports(olderThan: .now - exportLifetime)
        let copy = try exportFolder().appending(path: name)
        try FileManager.default.copyItem(at: url, to: copy)
        Task {
            try? await Task.sleep(for: .seconds(exportLifetime + 1))
            removeExports(olderThan: .now - exportLifetime)
        }
        return copy
    }

    /// Every copy made before `cutoff`; by default all of them, which at launch are an earlier run's. Decrypted files
    /// must not outlive their use.
    static func removeExports(olderThan cutoff: Date = .distantFuture) {
        let manager = FileManager.default
        for folder in (try? manager.contentsOfDirectory(at: exports, includingPropertiesForKeys: [.creationDateKey])) ?? [] {
            if let created = try? folder.resourceValues(forKeys: [.creationDateKey]).creationDate, created < cutoff { try? manager.removeItem(at: folder) }
        }
    }

    private static func exportFolder() throws -> URL {
        let folder = exports.appending(path: UUID().uuidString, directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        return folder
    }
}
