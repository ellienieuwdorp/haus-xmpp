import AppKit
import SwiftUI
import UniformTypeIdentifiers

/// The bubble's items for a photo, video or file that is on this Mac: Copy Image (photos), Save As… and Share…. Used in
/// the bubble's right-click menu and its accessibility actions. Show in Finder is left out: the file lives in the app's
/// container under a name derived from its hash, which says nothing to the user; Save As… puts a copy where they want it.
struct MacAttachmentMenuItems: View {
    let message: TimelineMessage

    var body: some View {
        if let attachment = message.attachment, !message.showsPlaceholder, let url = attachment.localURL {
            let name = MacAttachmentActions.fileName(for: attachment, at: url)
            Section {
                if attachment.isImage {
                    Button("Copy Image", systemImage: "doc.on.doc") { MacAttachmentActions.copyImage(at: url, to: .general) }
                }
                Button("Save As…", systemImage: "square.and.arrow.down") { MacAttachmentActions.saveAs(url, name: name) }
                Button("Share…", systemImage: "square.and.arrow.up") { MacAttachmentActions.share(url, name: name) }
            }
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
                if FileManager.default.fileExists(atPath: destination.path) { try FileManager.default.removeItem(at: destination) }
                try FileManager.default.copyItem(at: url, to: destination)
            } catch {
                let alert = NSAlert(error: error)
                if let window { alert.beginSheetModal(for: window) } else { alert.runModal() }
            }
        }
        if let window { panel.beginSheetModal(for: window, completionHandler: finish) } else { panel.begin(completionHandler: finish) }
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
