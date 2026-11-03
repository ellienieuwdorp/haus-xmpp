import AppKit
import SwiftUI
import UniformTypeIdentifiers

// No Show in Finder: the cached file's hashed name says nothing to the user; Save As… puts a copy where they want it.
struct MacAttachmentMenu {
    enum Kind { case copyImage, saveAs, share }

    struct Item {
        let kind: Kind
        let title: String
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

// Under the file's own name rather than the cache's.
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
    // Path separators in a sender's name never reach a path.
    static func fileName(for attachment: TimelineAttachment, at url: URL) -> String {
        var name = attachment.name.replacingOccurrences(of: "/", with: "-").replacingOccurrences(of: ":", with: "-")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        if name.isEmpty || name.hasPrefix(".") { name = attachment.kindLabel + name }
        if (name as NSString).pathExtension.isEmpty, !url.pathExtension.isEmpty { name += "." + url.pathExtension }
        return name
    }

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

    // An existing file is replaced only once the whole copy is made, so a failed copy leaves it untouched.
    static func save(_ url: URL, to destination: URL) throws {
        let manager = FileManager.default
        guard manager.fileExists(atPath: destination.path) else { return try manager.copyItem(at: url, to: destination) }
        let staging = try exportFolder()
        defer { try? manager.removeItem(at: staging) }
        let copy = staging.appending(path: destination.lastPathComponent)
        try manager.copyItem(at: url, to: copy)
        _ = try manager.replaceItemAt(destination, withItemAt: copy)
    }

    // At the pointer, which is where the menu item that asked for it was.
    static func share(_ url: URL, name: String) {
        guard let copy = try? namedCopy(of: url, name: name), let window = NSApp.keyWindow ?? NSApp.mainWindow, let view = window.contentView else { return }
        let point = view.convert(window.mouseLocationOutsideOfEventStream, from: nil)
        NSSharingServicePicker(items: [copy]).show(relativeTo: NSRect(origin: point, size: CGSize(width: 1, height: 1)), of: view, preferredEdge: .minY)
    }

    // TIFF too, for apps that only paste that.
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

    private static var exports: URL { FileManager.default.temporaryDirectory.appending(path: "Exports", directoryHint: .isDirectory) }
    // Whoever takes a copy (Finder, Mail, AirDrop) has made its own by then.
    private static let exportLifetime: TimeInterval = 3600

    // A folder per copy, so two files of one name never collide; an APFS clone takes no space until one of them
    // changes.
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

    // Decrypted files must not outlive their use; at launch every copy is an earlier run's.
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
