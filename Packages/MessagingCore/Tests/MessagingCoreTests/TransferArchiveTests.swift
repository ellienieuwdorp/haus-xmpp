import Foundation
import Testing
@testable import MessagingCore

/// The transfer archive: what one install writes and another reads with the code shown on the first.
struct TransferArchiveTests {
    private let schema = 26

    private func scratch() throws -> URL {
        let directory = FileManager.default.temporaryDirectory.appending(path: "transfer-\(UUID())", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        return directory
    }

    /// A file of `size` bytes whose content depends on `seed`, so a misplaced or reordered chunk shows.
    private func file(_ name: String, size: Int, seed: UInt8, in directory: URL) throws -> URL {
        let url = directory.appending(path: name)
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data((0..<size).map { UInt8(truncatingIfNeeded: $0 &* 31) &+ seed }).write(to: url)
        return url
    }

    private func manifest(_ entries: [TransferManifest.Entry], schema: Int? = nil) -> TransferManifest {
        TransferManifest(transferID: UUID().uuidString, createdAt: Date(timeIntervalSince1970: 1_790_000_000), appVersion: "1.0",
                         appBuild: "3", platform: "iOS", schemaVersion: schema ?? self.schema, accountID: "ellie@example.org", entries: entries)
    }

    /// An archive of a database, two attachments across several frames, an empty file and a Keychain record, with a
    /// small chunk size so entries straddle frames.
    private func archive(in directory: URL, code: TransferCode, schema: Int? = nil) throws -> (URL, TransferManifest, [String: Data]) {
        let source = directory.appending(path: "source", directoryHint: .isDirectory)
        let files: [(String, URL)] = [
            ("messaging/messages.sqlite", try file("messages.sqlite", size: 10_000, seed: 1, in: source)),
            ("messaging/attachments/ab12/cache/photo.jpg", try file("a/photo.jpg", size: 4_096, seed: 2, in: source)),
            ("messaging/attachments/ab12/staging/m1.enc", try file("a/m1.enc", size: 1, seed: 3, in: source)),
            ("messaging/avatars/empty.png", try file("empty.png", size: 0, seed: 4, in: source))
        ]
        let secret = Data("{\"password\":\"synthetic\"}".utf8)
        var sources: [String: TransferSource] = ["keychain/account": .data(secret)]
        var entries = [try TransferArchive.describe(name: "keychain/account", source: .data(secret))]
        var expected = ["keychain/account": secret]
        for (name, url) in files {
            sources[name] = .file(url)
            entries.append(try TransferArchive.describe(name: name, source: .file(url)))
            expected[name] = try Data(contentsOf: url)
        }
        let manifest = manifest(entries, schema: schema)
        let url = directory.appending(path: "transfer.\(TransferArchive.fileExtension)")
        try TransferArchive.write(manifest, sources: sources, to: url, code: code, chunkSize: 1_000)
        return (url, manifest, expected)
    }

    @Test func aWrittenArchiveReadsBackEntryForEntryWithTheSameCode() throws {
        let directory = try scratch()
        defer { try? FileManager.default.removeItem(at: directory) }
        let code = TransferCode.generate()
        let (url, written, expected) = try archive(in: directory, code: code)

        // As the target reads it: the code as the user typed it, in lower case with spaces.
        let typed = try #require(TransferCode(code.groups.joined(separator: " ").lowercased()))
        let reader = try TransferArchive.open(url, code: typed, supportedSchema: schema)
        #expect(reader.manifest == written)
        let target = directory.appending(path: "target", directoryHint: .isDirectory)
        var reported: Int64 = 0
        let kept = try reader.extract(into: target, inMemory: { $0.name.hasPrefix("keychain/") }, progress: { reported = $0 })
        #expect(kept == ["keychain/account": expected["keychain/account"]!])
        for (name, data) in expected where !name.hasPrefix("keychain/") {
            #expect(try Data(contentsOf: target.appending(path: name)) == data, "\(name)")
        }
        #expect(!FileManager.default.fileExists(atPath: target.appending(path: "keychain").path))
        #expect(reported == written.totalBytes)
        // The secret never appears in the file as written.
        #expect(try Data(contentsOf: url).range(of: Data("synthetic".utf8)) == nil)
    }

    @Test func anotherCodeIsRefusedBeforeAnythingIsDecrypted() throws {
        let directory = try scratch()
        defer { try? FileManager.default.removeItem(at: directory) }
        let (url, _, _) = try archive(in: directory, code: .generate())
        #expect(throws: TransferArchiveError.wrongCode) { try TransferArchive.open(url, code: .generate(), supportedSchema: schema) }
    }

    /// One changed byte anywhere after the header, or a changed header, fails; nothing is extracted from a frame that
    /// did not open.
    @Test func aChangedByteIsDetected() throws {
        let directory = try scratch()
        defer { try? FileManager.default.removeItem(at: directory) }
        let code = TransferCode.generate()
        let (url, _, _) = try archive(in: directory, code: code)
        let original = try Data(contentsOf: url)
        // In the manifest's frame, in an entry's frame, in the last frame, and in the header's chunk size.
        for offset in [TransferArchive.headerLength + 10, original.count / 2, original.count - 3, 14] {
            var changed = original
            changed[offset] ^= 0x01
            try changed.write(to: url)
            #expect(throws: (any Error).self, "offset \(offset)") {
                let reader = try TransferArchive.open(url, code: code, supportedSchema: schema)
                _ = try reader.extract(into: directory.appending(path: "out-\(offset)"), inMemory: { _ in false })
            }
        }
        var changed = original
        changed[original.count / 2] ^= 0x01
        try changed.write(to: url)
        #expect(throws: TransferArchiveError.damaged) {
            try TransferArchive.open(url, code: code, supportedSchema: schema).verify()
        }
    }

    /// An interrupted copy: cut inside a frame, or exactly between two frames (where every remaining frame still opens
    /// on its own).
    @Test func aCutShortFileIsTruncated() throws {
        let directory = try scratch()
        defer { try? FileManager.default.removeItem(at: directory) }
        let code = TransferCode.generate()
        let (url, _, _) = try archive(in: directory, code: code)
        let original = try Data(contentsOf: url)
        let frame = 4 + 1_000 + 16
        for length in [original.count - 7, TransferArchive.headerLength + frame * 6] {
            try original.prefix(length).write(to: url)
            #expect(throws: TransferArchiveError.truncated, "length \(length)") {
                try TransferArchive.open(url, code: code, supportedSchema: schema).verify()
            }
        }
        try Data("not a transfer at all".utf8).write(to: url)
        #expect(throws: TransferArchiveError.notATransfer) { try TransferArchive.open(url, code: code, supportedSchema: schema) }
    }

    @Test func dataFromANewerSchemaIsRefusedAndAnOlderOneOpens() throws {
        let directory = try scratch()
        defer { try? FileManager.default.removeItem(at: directory) }
        let code = TransferCode.generate()
        let (url, _, _) = try archive(in: directory, code: code, schema: schema + 1)
        #expect(throws: TransferArchiveError.newerSchema(found: schema + 1, supported: schema)) {
            try TransferArchive.open(url, code: code, supportedSchema: schema)
        }
        #expect(try TransferArchive.open(url, code: code, supportedSchema: schema + 2).manifest.schemaVersion == schema + 1)
    }

    /// Entry names are logical: nothing that could reach outside the folder it is extracted into, and nothing the
    /// writing install's paths could leak through.
    @Test func namesThatCouldLeaveTheTargetFolderAreRefused() throws {
        let directory = try scratch()
        defer { try? FileManager.default.removeItem(at: directory) }
        for name in ["../escape", "/var/mobile/abs", "messaging//double", "messaging/./here", "a\\b", ""] {
            #expect(throws: TransferArchiveError.self, "\(name)") {
                let entry = TransferManifest.Entry(name: name, size: 1, sha256: String(repeating: "0", count: 64))
                try TransferArchive.write(manifest([entry]), sources: [name: .data(Data([0]))], to: directory.appending(path: "x"), code: .generate())
            }
        }
        // A file that is also another entry's folder could not be extracted either.
        let data = Data([1])
        let entries = try ["messaging/a", "messaging/a/b"].map { try TransferArchive.describe(name: $0, source: .data(data)) }
        #expect(throws: TransferArchiveError.self) {
            try TransferArchive.write(manifest(entries), sources: ["messaging/a": .data(data), "messaging/a/b": .data(data)],
                                      to: directory.appending(path: "y"), code: .generate())
        }
    }

    @Test func aSourceFileThatChangesAfterItWasDescribedFailsTheWrite() throws {
        let directory = try scratch()
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = try file("db", size: 100, seed: 9, in: directory)
        let entry = try TransferArchive.describe(name: "messaging/messages.sqlite", source: .file(url))
        try Data(repeating: 7, count: 100).write(to: url)
        #expect(throws: TransferArchiveError.sourceChanged("messaging/messages.sqlite")) {
            try TransferArchive.write(manifest([entry]), sources: [entry.name: .file(url)], to: directory.appending(path: "out"), code: .generate())
        }
    }

    @Test func codesCarry120RandomBitsAndForgiveHowTheyAreTyped() throws {
        let code = TransferCode.generate()
        #expect(code.groups.count == 6 && code.groups.allSatisfy { $0.count == 4 })
        #expect(code.keyMaterial.count == 15)
        #expect(TransferCode(code.grouped) == code)
        #expect(TransferCode("\n " + code.groups.joined(separator: "  ").lowercased() + "\n") == code)
        // Crockford's look-alikes: O is 0, I and L are 1.
        #expect(TransferCode("OOOO-IIII-LLLL-0000-1111-2222") == TransferCode("0000-1111-1111-0000-1111-2222"))
        #expect(TransferCode("UUUU-0000-0000-0000-0000-0000") == nil)
        #expect(TransferCode("0000-0000-0000-0000-0000") == nil)
        #expect(!String(describing: code).contains(code.groups[0]))
        #expect(Set((0..<64).map { _ in TransferCode.generate().grouped }).count == 64)
    }
}
