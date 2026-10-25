import Foundation
import ImageIO
import UniformTypeIdentifiers
#if os(iOS)
import UIKit
#else
import AppKit
#endif

/// One thing a share sheet handed over, reduced to what the share screen sends: a file of our own (a photo, a video,
/// any other file), or text (a link, a note), which goes into the message text.
struct SharedItem: Identifiable, Sendable, Equatable {
    enum Kind: Sendable, Equatable { case image, video, file, link, text }

    let id: UUID
    let kind: Kind
    /// For files: a copy in this process's temporary directory, which the intake owns and `SharedItemIntake.discard`
    /// removes. Nil for links and text.
    let file: URL?
    let name: String
    let type: UTType?
    /// For links and text.
    let text: String?
    /// Bytes on disk before preparation; images and videos shrink when they are prepared.
    let size: Int?

    var isFile: Bool { file != nil }
}

/// Turns the share sheet's item providers into `SharedItem`s, one at a time, each file copied once to our own temporary
/// directory (never held in memory): the extension's memory budget is far below an app's.
enum SharedItemIntake {
    /// Files one share may carry, as the composer's tray.
    static let maximumFiles = 10

    /// What a provider is taken as, from the types it registered. The first match in this order wins: a movie, an image
    /// (a Live Photo is sent as its still), a PDF, a file shared by reference, a web link, a file of any other type, text.
    /// A web page's archive or property list beside its link is not a file anyone meant to send.
    static func kind(of registeredTypes: [String]) -> SharedItem.Kind? {
        let types = registeredTypes.compactMap(UTType.init)
        if types.contains(where: { $0.conforms(to: .movie) }) { return .video }
        if types.contains(where: { $0.conforms(to: .image) }) { return .image }
        if types.contains(where: { $0.conforms(to: .pdf) }) { return .file }
        if types.contains(where: { $0.conforms(to: .fileURL) }) { return .file }
        if types.contains(where: { $0.conforms(to: .url) }) { return .link }
        if types.contains(where: isFileType) { return .file }
        if types.contains(where: { $0.conforms(to: .plainText) || $0.conforms(to: .text) }) { return .text }
        return nil
    }

    /// A concrete file type: data that is neither a link nor text (a PDF, an archive, a document).
    private static func isFileType(_ type: UTType) -> Bool {
        type.conforms(to: .data) && !type.conforms(to: .url) && !type.conforms(to: .text) && type != .data
            && !type.conforms(to: .propertyList) && !type.conforms(to: .webArchive)
    }

    /// The type to ask for: the provider's own most specific registration of `kind`. A Live Photo's bundle is skipped for
    /// the plain image registered beside it.
    static func preferredType(for kind: SharedItem.Kind, registeredTypes: [String]) -> UTType? {
        let types = registeredTypes.compactMap(UTType.init)
        switch kind {
        case .video: return types.first { $0.conforms(to: .movie) }
        case .image: return types.first { $0.conforms(to: .image) && !$0.conforms(to: .livePhoto) } ?? types.first { $0.conforms(to: .image) }
        case .file: return types.first(where: isFileType) ?? types.first { $0.conforms(to: .fileURL) }
        case .link: return .url
        case .text: return .plainText
        }
    }

    /// Several extension items with a web link among them (Safari: the page plus its preview) share only the link.
    static func providers(of items: [NSExtensionItem]) -> [NSItemProvider] {
        let providers = items.flatMap { $0.attachments ?? [] }
        if items.count > 1, let link = providers.first(where: { kind(of: $0.registeredTypeIdentifiers) == .link }) { return [link] }
        return providers
    }

    struct Result: Sendable {
        var items: [SharedItem] = []
        /// Files beyond `maximumFiles`, and providers whose content could not be read.
        var skipped = 0
        var unreadable = 0
    }

    /// Loads every provider in order, one at a time. Files past `maximumFiles` are not loaded at all.
    static func load(_ providers: [NSItemProvider]) async -> Result {
        var result = Result()
        for provider in providers {
            guard let kind = kind(of: provider.registeredTypeIdentifiers) else { result.unreadable += 1; continue }
            let isFile = kind == .image || kind == .video || kind == .file
            if isFile, result.items.filter(\.isFile).count >= maximumFiles { result.skipped += 1; continue }
            if let item = await load(provider, as: kind) { result.items.append(item) } else { result.unreadable += 1 }
        }
        return result
    }

    private static func load(_ provider: NSItemProvider, as kind: SharedItem.Kind) async -> SharedItem? {
        let registered = provider.registeredTypeIdentifiers
        switch kind {
        case .link:
            guard let url = await object(URL.self, from: provider) else { return nil }
            // A file URL offered as a link is a file.
            if url.isFileURL { return await copiedFile(at: url, suggestedName: provider.suggestedName) }
            return SharedItem(id: UUID(), kind: .link, file: nil, name: url.host() ?? "Link", type: .url, text: url.absoluteString, size: nil)
        case .text:
            guard let text = await text(from: provider), !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return nil }
            return SharedItem(id: UUID(), kind: .text, file: nil, name: "Text", type: .plainText, text: text, size: nil)
        case .image, .video, .file:
            guard let type = preferredType(for: kind, registeredTypes: registered) else { return nil }
            if type.conforms(to: .fileURL) {
                guard let url = await object(URL.self, from: provider), url.isFileURL else { return nil }
                return await copiedFile(at: url, suggestedName: provider.suggestedName)
            }
            if let copy = await fileCopy(from: provider, type: type) {
                return item(kind: kind, file: copy, type: type, suggestedName: provider.suggestedName)
            }
            // A screenshot from the markup editor and some apps' images come only as an image object.
            if kind == .image, let copy = await imageObjectCopy(from: provider) {
                return item(kind: .image, file: copy, type: .jpeg, suggestedName: provider.suggestedName)
            }
            return nil
        }
    }

    private static func item(kind: SharedItem.Kind, file: URL, type: UTType, suggestedName: String?) -> SharedItem {
        let size = (try? file.resourceValues(forKeys: [.fileSizeKey]))?.fileSize
        let fallback = switch kind { case .image: "photo"; case .video: "video"; default: "file" }
        var name = suggestedName.flatMap { $0.isEmpty ? nil : $0 } ?? file.lastPathComponent
        if name.isEmpty { name = fallback }
        if (name as NSString).pathExtension.isEmpty, let ext = type.preferredFilenameExtension { name += "." + ext }
        return SharedItem(id: UUID(), kind: kind, file: file, name: Self.safeName(name), type: type, text: nil, size: size)
    }

    /// A file name the upload slot accepts: no path separators, at most 255 bytes.
    static func safeName(_ name: String) -> String {
        var cleaned = name.replacingOccurrences(of: "/", with: "-").replacingOccurrences(of: ":", with: "-")
        while cleaned.utf8.count > 255 { cleaned.removeFirst() }
        return cleaned.isEmpty ? "file" : cleaned
    }

    /// Text as a string object, or as whatever item the provider registered under its text type (a string, an attributed
    /// string or UTF-8 bytes): apps that share text differ.
    private static func text(from provider: NSItemProvider) async -> String? {
        if let text = await object(String.self, from: provider) { return text }
        guard let type = preferredType(for: .text, registeredTypes: provider.registeredTypeIdentifiers),
              let identifier = provider.registeredTypeIdentifiers.first(where: { UTType($0)?.conforms(to: type) == true }) else { return nil }
        return await withCheckedContinuation { continuation in
            provider.loadItem(forTypeIdentifier: identifier, options: nil) { item, _ in
                let text: String? = switch item {
                case let string as String: string
                case let attributed as NSAttributedString: attributed.string
                case let data as Data where data.count <= 1 << 20: String(data: data, encoding: .utf8)
                default: nil
                }
                continuation.resume(returning: text)
            }
        }
    }

    /// A provider's file, copied before its handler returns (the system deletes its own copy then).
    private static func fileCopy(from provider: NSItemProvider, type: UTType) async -> URL? {
        await withCheckedContinuation { continuation in
            _ = provider.loadFileRepresentation(for: type, openInPlace: false) { url, _, _ in
                continuation.resume(returning: url.flatMap { try? copyToOwnFolder($0) })
            }
        }
    }

    /// A file shared by reference (the Files app): read through a file coordinator, inside its security scope.
    private static func copiedFile(at url: URL, suggestedName: String?) async -> SharedItem? {
        let scoped = url.startAccessingSecurityScopedResource()
        defer { if scoped { url.stopAccessingSecurityScopedResource() } }
        var copy: URL?
        var coordinationError: NSError?
        NSFileCoordinator().coordinate(readingItemAt: url, options: .withoutChanges, error: &coordinationError) { readable in
            copy = try? copyToOwnFolder(readable)
        }
        guard let copy else { return nil }
        let type = UTType(filenameExtension: url.pathExtension) ?? .data
        let kind: SharedItem.Kind = type.conforms(to: .movie) ? .video : type.conforms(to: .image) ? .image : .file
        return item(kind: kind, file: copy, type: type, suggestedName: suggestedName ?? url.lastPathComponent)
    }

    private static func imageObjectCopy(from provider: NSItemProvider) async -> URL? {
        #if os(iOS)
        guard provider.canLoadObject(ofClass: UIImage.self), let image = await object(UIImage.self, from: provider),
              let cgImage = image.cgImage else { return nil }
        #else
        guard provider.canLoadObject(ofClass: NSImage.self), let image = await object(NSImage.self, from: provider),
              let cgImage = image.cgImage(forProposedRect: nil, context: nil, hints: nil) else { return nil }
        #endif
        guard let data = AttachmentPreparer.jpegData(cgImage, quality: AttachmentPreparer.jpegQuality) else { return nil }
        let folder = try? ownFolder()
        guard let url = folder?.appending(path: "photo.jpg"), (try? data.write(to: url)) != nil else { return nil }
        return url
    }

    private static func object<T: _ObjectiveCBridgeable & Sendable>(_ type: T.Type, from provider: NSItemProvider) async -> T?
    where T._ObjectiveCType: NSItemProviderReading {
        guard provider.canLoadObject(ofClass: type) else { return nil }
        return await withCheckedContinuation { continuation in
            _ = provider.loadObject(ofClass: type) { value, _ in continuation.resume(returning: value) }
        }
    }

    private static func object<T: NSItemProviderReading & NSObject>(_ type: T.Type, from provider: NSItemProvider) async -> T? {
        await withCheckedContinuation { continuation in
            _ = provider.loadObject(ofClass: type) { value, _ in
                nonisolated(unsafe) let value = value as? T
                continuation.resume(returning: value)
            }
        }
    }

    /// Where the intake keeps its copies: one folder per item, so each keeps its own file name.
    static var root: URL { FileManager.default.temporaryDirectory.appending(path: "Shared", directoryHint: .isDirectory) }

    private static func ownFolder() throws -> URL {
        let folder = root.appending(path: UUID().uuidString, directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        return folder
    }

    private static func copyToOwnFolder(_ url: URL) throws -> URL {
        let copy = try ownFolder().appending(path: url.lastPathComponent.isEmpty ? "file" : url.lastPathComponent)
        try FileManager.default.copyItem(at: url, to: copy)
        return copy
    }

    /// Removes every copy the intake made. The extension calls it when it ends, and at launch for a run that was killed.
    static func discardAll() { try? FileManager.default.removeItem(at: root) }
}
