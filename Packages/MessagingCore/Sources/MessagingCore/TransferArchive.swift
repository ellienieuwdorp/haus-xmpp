import Foundation
import CryptoKit

/// One file that carries an install's data to another install: a manifest followed by every entry's bytes, encrypted
/// as one stream under a key derived from a `TransferCode`.
///
/// Layout (format 1):
///
///     header   64 bytes, in the clear: "HAUSXFER", version (UInt16), 0 (UInt16), chunk size (UInt32), salt (32),
///              code check (16). Every integer is big-endian.
///     frames   until the end of the file: sealed length (UInt32), then AES-GCM ciphertext and its 16-byte tag.
///
/// The plaintext the frames carry, in order: the manifest's length (UInt32) and its JSON, then each entry's bytes in
/// the manifest's order. Every frame but the last holds exactly one chunk of plaintext.
///
/// The key and the code check come from the code through HKDF-SHA256 with the header's random salt, so every archive
/// has its own key. Each frame is sealed with a nonce made of its index and a final-frame flag, and authenticates the
/// whole header: frames cannot be reordered, dropped, cut short or moved to another archive without failing to open.
/// The code check tells a mistyped code apart from a damaged file before anything is decrypted. Each entry's size
/// and SHA-256 in the manifest are checked as well as it is read.
///
/// Names in the manifest are logical (`messaging/messages.sqlite`, `keychain/account`), never paths or identifiers of
/// the install that wrote them: the reader maps them onto its own storage, and refuses any name that could reach
/// outside the folder it extracts into.
public enum TransferArchive {
    public static let fileExtension = "hausxmpp"
    public static let formatVersion = 1
    static let magic = Data("HAUSXFER".utf8)
    static let headerLength = 64
    static let tagLength = 16
    public static let defaultChunkSize = 1 << 20
    /// Larger chunks are refused on reading: a frame is held in memory whole.
    static let maximumChunkSize = 16 << 20
    static let maximumManifestLength = 64 << 20
    /// An entry kept in memory (a Keychain item, preferences) is never larger than this.
    public static let maximumInMemoryEntry = 4 << 20

    /// The size and SHA-256 of one entry, read in pieces.
    public static func describe(name: String, source: TransferSource) throws -> TransferManifest.Entry {
        guard TransferManifest.isValidName(name) else { throw TransferArchiveError.invalidManifest("name") }
        switch source {
        case .data(let data):
            return TransferManifest.Entry(name: name, size: Int64(data.count), sha256: hex(SHA256.hash(data: data)))
        case .file(let url):
            let handle = try FileHandle(forReadingFrom: url)
            defer { try? handle.close() }
            var hash = SHA256(), size: Int64 = 0
            while let piece = try handle.read(upToCount: defaultChunkSize), !piece.isEmpty {
                hash.update(data: piece)
                size += Int64(piece.count)
            }
            return TransferManifest.Entry(name: name, size: size, sha256: hex(hash.finalize()))
        }
    }

    /// Writes `manifest` and every entry's bytes from `sources` (keyed by entry name) to a new file at `url`. Each
    /// file is hashed again as it is written: one that changed since `describe` fails the write. `progress` receives
    /// the entry bytes written so far. A failed write leaves a partial file for the caller to remove.
    public static func write(_ manifest: TransferManifest, sources: [String: TransferSource], to url: URL, code: TransferCode,
                             chunkSize: Int = defaultChunkSize, progress: (Int64) -> Void = { _ in }) throws {
        try manifest.validate()
        guard chunkSize > 0, chunkSize <= maximumChunkSize else { throw TransferArchiveError.invalidManifest("chunk size") }
        let writer = try FrameWriter(url: url, code: code, chunkSize: chunkSize)
        defer { writer.close() }
        let encoded = try TransferManifest.encoder.encode(manifest)
        guard encoded.count <= maximumManifestLength else { throw TransferArchiveError.invalidManifest("too many entries") }
        try writer.append(bigEndian: UInt32(encoded.count))
        try writer.append(encoded)
        var written: Int64 = 0
        for entry in manifest.entries {
            guard let source = sources[entry.name] else { throw TransferArchiveError.invalidManifest("missing \(entry.name)") }
            var hash = SHA256(), size: Int64 = 0
            switch source {
            case .data(let data):
                hash.update(data: data); size = Int64(data.count)
                try writer.append(data)
                written += size
                progress(written)
            case .file(let file):
                let handle = try FileHandle(forReadingFrom: file)
                defer { try? handle.close() }
                while let piece = try handle.read(upToCount: chunkSize), !piece.isEmpty {
                    hash.update(data: piece); size += Int64(piece.count)
                    guard size <= entry.size else { throw TransferArchiveError.sourceChanged(entry.name) }
                    try writer.append(piece)
                    written += Int64(piece.count)
                    progress(written)
                }
            }
            guard size == entry.size, hex(hash.finalize()) == entry.sha256 else { throw TransferArchiveError.sourceChanged(entry.name) }
        }
        try writer.finish()
    }

    /// Opens an archive: checks the header and the code, then reads and checks the manifest. A manifest from a newer
    /// format, or of data at a newer schema than `supportedSchema`, is refused before any entry is read.
    public static func open(_ url: URL, code: TransferCode, supportedSchema: Int) throws -> TransferArchiveReader {
        try TransferArchiveReader(url: url, code: code, supportedSchema: supportedSchema)
    }

    static func hex(_ digest: SHA256.Digest) -> String { digest.map { String(format: "%02x", $0) }.joined() }

    static func keys(code: TransferCode, salt: Data) -> (key: SymmetricKey, check: Data) {
        let material = SymmetricKey(data: code.keyMaterial)
        let key = HKDF<SHA256>.deriveKey(inputKeyMaterial: material, salt: salt, info: Data("haus.xmpp transfer v1 key".utf8), outputByteCount: 32)
        let check = HKDF<SHA256>.deriveKey(inputKeyMaterial: material, salt: salt, info: Data("haus.xmpp transfer v1 check".utf8), outputByteCount: 16)
        return (key, check.withUnsafeBytes { Data($0) })
    }

    static func nonce(index: UInt64, final: Bool) throws -> AES.GCM.Nonce {
        var bytes = Data(count: 12)
        for shift in 0..<8 { bytes[shift] = UInt8((index >> UInt64(56 - shift * 8)) & 0xFF) }
        bytes[11] = final ? 1 : 0
        return try AES.GCM.Nonce(data: bytes)
    }
}

/// Where an entry's bytes come from when writing.
public enum TransferSource: Sendable {
    case file(URL)
    case data(Data)
}

public enum TransferArchiveError: Error, Equatable, Sendable {
    /// Not a transfer archive at all (another file was picked).
    case notATransfer
    /// Written by a newer build in a format this one cannot read.
    case newerFormat(Int)
    /// The code does not open this archive.
    case wrongCode
    /// The code is right but the contents do not check out: changed, corrupted, or not what the manifest lists.
    case damaged
    /// The file ends before the archive does (an interrupted copy or download).
    case truncated
    case invalidManifest(String)
    /// The data is at a schema newer than this build can open.
    case newerSchema(found: Int, supported: Int)
    /// A file changed while it was being written into the archive.
    case sourceChanged(String)
}

/// What an archive holds. Written first and checked before any entry is extracted.
public struct TransferManifest: Codable, Sendable, Equatable {
    public struct Entry: Codable, Sendable, Equatable {
        public let name: String
        public let size: Int64
        public let sha256: String
        public init(name: String, size: Int64, sha256: String) { self.name = name; self.size = size; self.sha256 = sha256 }
    }

    public var formatVersion: Int
    /// Random for every transfer: a target records it, so the same archive is never restored twice.
    public var transferID: String
    public var createdAt: Date
    public var appVersion: String
    public var appBuild: String
    /// "iOS" or "macOS": the platform that wrote it.
    public var platform: String
    /// The store's schema: a newer one than the reader's is refused, an older one is migrated as usual.
    public var schemaVersion: Int
    /// The signed-in account, or empty.
    public var accountID: String
    public var entries: [Entry]

    public init(transferID: String, createdAt: Date, appVersion: String, appBuild: String, platform: String,
                schemaVersion: Int, accountID: String, entries: [Entry]) {
        formatVersion = TransferArchive.formatVersion
        self.transferID = transferID; self.createdAt = createdAt; self.appVersion = appVersion; self.appBuild = appBuild
        self.platform = platform; self.schemaVersion = schemaVersion; self.accountID = accountID; self.entries = entries
    }

    public var totalBytes: Int64 { entries.reduce(0) { $0 + $1.size } }

    public func entry(named name: String) -> Entry? { entries.first { $0.name == name } }

    /// A name is one or more components joined by "/": none empty, "." or "..", none with a NUL or a backslash, and
    /// not too long. So an entry can only land inside the folder it is extracted into.
    public static func isValidName(_ name: String) -> Bool {
        guard !name.isEmpty, name.utf8.count <= 1024, !name.contains("\0"), !name.contains("\\") else { return false }
        return name.split(separator: "/", omittingEmptySubsequences: false).allSatisfy { component in
            !component.isEmpty && component != "." && component != ".." && component.utf8.count <= 255
        }
    }

    func validate() throws {
        guard formatVersion <= TransferArchive.formatVersion else { throw TransferArchiveError.newerFormat(formatVersion) }
        guard formatVersion == TransferArchive.formatVersion else { throw TransferArchiveError.invalidManifest("format") }
        guard !transferID.isEmpty else { throw TransferArchiveError.invalidManifest("transfer ID") }
        var seen = Set<String>()
        for entry in entries {
            guard Self.isValidName(entry.name) else { throw TransferArchiveError.invalidManifest("name") }
            guard seen.insert(entry.name).inserted else { throw TransferArchiveError.invalidManifest("duplicate \(entry.name)") }
            guard entry.size >= 0, entry.sha256.count == 64, entry.sha256.allSatisfy({ $0.isHexDigit && !$0.isUppercase }) else {
                throw TransferArchiveError.invalidManifest("entry \(entry.name)")
            }
        }
        // A file and a folder of the same name cannot both be extracted.
        for name in seen {
            var prefix = Substring(name)
            while let slash = prefix.lastIndex(of: "/") {
                prefix = prefix[..<slash]
                guard !seen.contains(String(prefix)) else { throw TransferArchiveError.invalidManifest("\(prefix) is a file and a folder") }
            }
        }
    }

    static var encoder: JSONEncoder {
        let encoder = JSONEncoder()
        encoder.outputFormatting = .sortedKeys
        encoder.dateEncodingStrategy = .iso8601
        return encoder
    }

    static var decoder: JSONDecoder {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return decoder
    }
}

/// Reads an archive opened with its code, entry by entry in the manifest's order, holding at most one frame in memory.
public final class TransferArchiveReader {
    public let manifest: TransferManifest
    private let frames: FrameReader

    init(url: URL, code: TransferCode, supportedSchema: Int) throws {
        frames = try FrameReader(url: url, code: code)
        let length = try frames.readUInt32()
        guard length > 0, length <= TransferArchive.maximumManifestLength else { throw TransferArchiveError.damaged }
        let data = try frames.read(exactly: Int(length))
        let manifest: TransferManifest
        do { manifest = try TransferManifest.decoder.decode(TransferManifest.self, from: data) }
        catch {
            // A newer format may have changed the manifest's shape; its version field is still read.
            if let version = (try? JSONSerialization.jsonObject(with: data) as? [String: Any])?["formatVersion"] as? Int,
               version > TransferArchive.formatVersion { throw TransferArchiveError.newerFormat(version) }
            throw TransferArchiveError.invalidManifest("unreadable")
        }
        try manifest.validate()
        guard manifest.schemaVersion <= supportedSchema else {
            throw TransferArchiveError.newerSchema(found: manifest.schemaVersion, supported: supportedSchema)
        }
        self.manifest = manifest
    }

    deinit { frames.close() }

    /// Extracts every entry: those `inMemory` selects are returned by name (each at most
    /// `TransferArchive.maximumInMemoryEntry` bytes), the rest are written under `directory` at their names. Every
    /// entry's size and SHA-256 are checked, and the archive must end exactly after the last one. Throws on the first
    /// problem; the caller removes `directory`. `progress` receives the entry bytes read so far.
    public func extract(into directory: URL, inMemory: (TransferManifest.Entry) -> Bool,
                        progress: (Int64) -> Void = { _ in }) throws -> [String: Data] {
        let files = FileManager.default
        let root = directory.standardizedFileURL.path + "/"
        var kept: [String: Data] = [:], read: Int64 = 0
        for entry in manifest.entries {
            var hash = SHA256(), remaining = entry.size
            if inMemory(entry) {
                guard entry.size <= TransferArchive.maximumInMemoryEntry else { throw TransferArchiveError.invalidManifest("\(entry.name) too large") }
                let data = try frames.read(exactly: Int(entry.size))
                hash.update(data: data)
                kept[entry.name] = data
                read += entry.size
                progress(read)
            } else {
                let target = directory.appending(path: entry.name)
                guard target.standardizedFileURL.path.hasPrefix(root) else { throw TransferArchiveError.invalidManifest("name") }
                try files.createDirectory(at: target.deletingLastPathComponent(), withIntermediateDirectories: true)
                guard files.createFile(atPath: target.path, contents: nil) else { throw CocoaError(.fileWriteUnknown) }
                let handle = try FileHandle(forWritingTo: target)
                defer { try? handle.close() }
                while remaining > 0 {
                    let piece = try frames.read(upTo: Int(min(remaining, Int64(TransferArchive.defaultChunkSize))))
                    hash.update(data: piece)
                    try handle.write(contentsOf: piece)
                    remaining -= Int64(piece.count)
                    read += Int64(piece.count)
                    progress(read)
                }
                try handle.synchronize()
            }
            guard TransferArchive.hex(hash.finalize()) == entry.sha256 else { throw TransferArchiveError.damaged }
        }
        try frames.requireEnd()
        return kept
    }

    /// Reads and checks everything without keeping any of it: the writer's last step, before the archive is offered.
    public func verify(progress: (Int64) -> Void = { _ in }) throws {
        var read: Int64 = 0
        for entry in manifest.entries {
            var hash = SHA256(), remaining = entry.size
            while remaining > 0 {
                let piece = try frames.read(upTo: Int(min(remaining, Int64(TransferArchive.defaultChunkSize))))
                hash.update(data: piece)
                remaining -= Int64(piece.count)
                read += Int64(piece.count)
                progress(read)
            }
            guard TransferArchive.hex(hash.finalize()) == entry.sha256 else { throw TransferArchiveError.damaged }
        }
        try frames.requireEnd()
    }
}

// MARK: Frames

private final class FrameWriter {
    private let handle: FileHandle
    private let header: Data
    private let key: SymmetricKey
    private let chunkSize: Int
    private var buffer = Data()
    private var index: UInt64 = 0
    private var finished = false

    init(url: URL, code: TransferCode, chunkSize: Int) throws {
        let files = FileManager.default
        try? files.removeItem(at: url)
        #if os(iOS)
        let attributes: [FileAttributeKey: Any] = [.protectionKey: FileProtectionType.completeUntilFirstUserAuthentication]
        #else
        let attributes: [FileAttributeKey: Any] = [:]
        #endif
        guard files.createFile(atPath: url.path, contents: nil, attributes: attributes) else { throw CocoaError(.fileWriteUnknown) }
        handle = try FileHandle(forWritingTo: url)
        // A random key's bytes: CryptoKit draws them from the system's secure generator.
        let salt = SymmetricKey(size: .bits256).withUnsafeBytes { Data($0) }
        let (key, check) = TransferArchive.keys(code: code, salt: salt)
        var header = TransferArchive.magic
        header.append(bigEndian: UInt16(TransferArchive.formatVersion))
        header.append(bigEndian: UInt16(0))
        header.append(bigEndian: UInt32(chunkSize))
        header.append(salt)
        header.append(check)
        self.header = header; self.key = key; self.chunkSize = chunkSize
        try handle.write(contentsOf: header)
    }

    func append(bigEndian value: UInt32) throws {
        var data = Data(); data.append(bigEndian: value)
        try append(data)
    }

    func append(_ data: Data) throws {
        buffer.append(data)
        // A full chunk is sealed only once more follows, so the final frame is never empty unless the whole stream is.
        while buffer.count > chunkSize {
            try seal(buffer.prefix(chunkSize), final: false)
            buffer = Data(buffer.dropFirst(chunkSize))
        }
    }

    func finish() throws {
        try seal(buffer, final: true)
        buffer = Data()
        finished = true
        try handle.synchronize()
    }

    func close() { try? handle.close() }

    private func seal(_ plaintext: Data, final: Bool) throws {
        let box = try AES.GCM.seal(plaintext, using: key, nonce: try TransferArchive.nonce(index: index, final: final), authenticating: header)
        index += 1
        var frame = Data()
        frame.append(bigEndian: UInt32(box.ciphertext.count + box.tag.count))
        frame.append(box.ciphertext)
        frame.append(box.tag)
        try handle.write(contentsOf: frame)
    }
}

private final class FrameReader {
    private let handle: FileHandle
    private let header: Data
    private let key: SymmetricKey
    private let chunkSize: Int
    private var plaintext = Data()
    private var index: UInt64 = 0
    private var sawFinal = false
    /// The next frame's length, read ahead to tell whether the current frame is the last.
    private var nextLength: UInt32?

    init(url: URL, code: TransferCode) throws {
        handle = try FileHandle(forReadingFrom: url)
        let header = try handle.read(upToCount: TransferArchive.headerLength) ?? Data()
        guard header.count == TransferArchive.headerLength, header.prefix(8) == TransferArchive.magic else {
            try? handle.close()
            throw TransferArchiveError.notATransfer
        }
        let version = header.bigEndianUInt16(at: 8)
        guard Int(version) <= TransferArchive.formatVersion else { try? handle.close(); throw TransferArchiveError.newerFormat(Int(version)) }
        let chunkSize = Int(header.bigEndianUInt32(at: 12))
        guard version == TransferArchive.formatVersion, chunkSize > 0, chunkSize <= TransferArchive.maximumChunkSize else {
            try? handle.close()
            throw TransferArchiveError.notATransfer
        }
        let salt = header.subdata(in: header.startIndex + 16..<header.startIndex + 48)
        let expected = header.subdata(in: header.startIndex + 48..<header.startIndex + 64)
        let (key, check) = TransferArchive.keys(code: code, salt: salt)
        guard zip(check, expected).reduce(UInt8(0), { $0 | ($1.0 ^ $1.1) }) == 0 else { try? handle.close(); throw TransferArchiveError.wrongCode }
        self.header = header; self.key = key; self.chunkSize = chunkSize
        nextLength = try readLength()
    }

    func close() { try? handle.close() }

    func readUInt32() throws -> UInt32 { try read(exactly: 4).bigEndianUInt32(at: 0) }

    func read(exactly count: Int) throws -> Data {
        while plaintext.count < count {
            guard try openNextFrame() else { throw TransferArchiveError.damaged }
        }
        let result = Data(plaintext.prefix(count))
        plaintext = Data(plaintext.dropFirst(count))
        return result
    }

    /// Between 1 and `count` bytes: what the current frame still holds, or the next one.
    func read(upTo count: Int) throws -> Data {
        while plaintext.isEmpty {
            guard try openNextFrame() else { throw TransferArchiveError.damaged }
        }
        let result = Data(plaintext.prefix(count))
        plaintext = Data(plaintext.dropFirst(result.count))
        return result
    }

    /// Everything was read: no plaintext left over, the final frame seen, and nothing after it.
    func requireEnd() throws {
        while !sawFinal {
            guard try openNextFrame() else { throw TransferArchiveError.damaged }
        }
        guard plaintext.isEmpty else { throw TransferArchiveError.damaged }
    }

    /// False once the final frame was read. Throws `truncated` when the file stops before it, `damaged` when a frame
    /// does not open.
    private func openNextFrame() throws -> Bool {
        guard !sawFinal else { return false }
        guard let length = nextLength else { throw TransferArchiveError.truncated }
        guard Int(length) >= TransferArchive.tagLength, Int(length) <= chunkSize + TransferArchive.tagLength else { throw TransferArchiveError.damaged }
        let sealed = try handle.read(upToCount: Int(length)) ?? Data()
        guard sealed.count == Int(length) else { throw TransferArchiveError.truncated }
        nextLength = try readLength()
        // The last frame in the file must be sealed as the final one: a file cut at a frame boundary fails here.
        let final = nextLength == nil
        let box: AES.GCM.SealedBox
        do {
            box = try AES.GCM.SealedBox(nonce: try TransferArchive.nonce(index: index, final: final),
                                        ciphertext: sealed.prefix(sealed.count - TransferArchive.tagLength),
                                        tag: sealed.suffix(TransferArchive.tagLength))
        } catch { throw TransferArchiveError.damaged }
        let opened: Data
        do { opened = try AES.GCM.open(box, using: key, authenticating: header) }
        catch { throw final ? TransferArchiveError.truncated : TransferArchiveError.damaged }
        guard final || opened.count == chunkSize else { throw TransferArchiveError.damaged }
        index += 1
        plaintext.append(opened)
        sawFinal = final
        return true
    }

    /// The next frame's length; nil at the end of the file.
    private func readLength() throws -> UInt32? {
        let bytes = try handle.read(upToCount: 4) ?? Data()
        if bytes.isEmpty { return nil }
        guard bytes.count == 4 else { throw TransferArchiveError.truncated }
        return bytes.bigEndianUInt32(at: 0)
    }
}

private extension Data {
    mutating func append(bigEndian value: UInt16) { append(contentsOf: [UInt8(value >> 8), UInt8(value & 0xFF)]) }
    mutating func append(bigEndian value: UInt32) {
        append(contentsOf: [UInt8(value >> 24), UInt8((value >> 16) & 0xFF), UInt8((value >> 8) & 0xFF), UInt8(value & 0xFF)])
    }
    func bigEndianUInt16(at offset: Int) -> UInt16 {
        let start = startIndex + offset
        return UInt16(self[start]) << 8 | UInt16(self[start + 1])
    }
    func bigEndianUInt32(at offset: Int) -> UInt32 {
        let start = startIndex + offset
        return UInt32(self[start]) << 24 | UInt32(self[start + 1]) << 16 | UInt32(self[start + 2]) << 8 | UInt32(self[start + 3])
    }
}
