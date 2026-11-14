import Foundation
import MessageStore
import OSLog

// Kept by the system as the task's `taskDescription`. A task identifier is unique only within one session object, which
// a relaunch makes anew; the tag names the message and where the attempt's bytes land, so a late completion still
// settles the right row with the right URL.
struct UploadTag: Codable, Hashable, Sendable {
    let account: String
    let messageID: String
    let url: String

    var taskDescription: String? {
        let encoder = JSONEncoder()
        encoder.outputFormatting = .sortedKeys
        return (try? encoder.encode(self)).map { String(decoding: $0, as: UTF8.self) }
    }

    init(account: String, messageID: String, url: String) {
        self.account = account; self.messageID = messageID; self.url = url
    }

    init?(taskDescription: String?) {
        guard let data = taskDescription?.data(using: .utf8), let tag = try? JSONDecoder().decode(Self.self, from: data) else { return nil }
        self = tag
    }
}

struct UploadOutcome: Codable, Equatable, Sendable {
    let tag: UploadTag
    let succeeded: Bool
    let finishedAt: Date
}

struct UploadTaskState: Equatable, Sendable {
    enum Phase: Equatable, Sendable { case live, finished(succeeded: Bool) }
    let taskID: Int
    let tag: UploadTag?
    let phase: Phase
}

protocol UploadTasks: Sendable {
    func states() async -> [UploadTaskState]
    func apply(resume: Set<Int>, cancel: Set<Int>) async
}

// The system delivers a completion once, and a relaunch for session events may end before storage opens: each is on
// disk before the delegate returns. `lock` serialises the state below. Before the first unlock the file can be
// neither read nor written: entries live in memory and merge with the file's once it opens.
final class UploadJournal: @unchecked Sendable {
    // Bounds what an account that never comes back leaves behind.
    static let retention: TimeInterval = 14 * 24 * 60 * 60
    private let file: URL?
    private let lock = NSLock()
    private var entries: [UploadOutcome] = []
    private var loaded = false
    private var tail: Task<Void, Never>?

    init(file: URL?) {
        self.file = file
        lock.withLock { load() }
    }

    static func file(scope: String) -> URL? {
        do {
            let support = try FileManager.default.url(for: .applicationSupportDirectory, in: .userDomainMask, appropriateFor: nil, create: true)
            return support.appending(path: "Uploads", directoryHint: .isDirectory).appending(path: scope + ".json")
        } catch {
            Logger(subsystem: "haus.xmpp.ios", category: "uploads").error("upload journal has no folder: \(error.localizedDescription, privacy: .public)")
            return nil
        }
    }

    func record(_ outcome: UploadOutcome) {
        lock.withLock {
            load()
            entries.removeAll { $0.tag == outcome.tag }
            entries.append(outcome)
            save()
        }
    }

    // One settle at a time, so two passes never both apply, and count, the same outcome.
    func serially<Value: Sendable>(_ work: @escaping @Sendable () async -> Value) async -> Value {
        let next: Task<Value, Never> = lock.withLock {
            let previous = tail
            let next = Task { await previous?.value; return await work() }
            tail = Task { _ = await next.value }
            return next
        }
        return await next.value
    }

    func outcomes(account: String) -> [UploadOutcome] {
        lock.withLock {
            load()
            return entries.filter { $0.tag.account == account }
        }
    }

    func remove(_ settled: Set<UploadTag>, now: Date) {
        lock.withLock {
            load()
            let before = entries.count
            entries.removeAll { settled.contains($0.tag) || now.timeIntervalSince($0.finishedAt) > Self.retention }
            if entries.count != before { save() }
        }
    }

    private func load() {
        guard !loaded, let file else { return }
        do {
            let stored = try JSONDecoder().decode([UploadOutcome].self, from: Data(contentsOf: file))
            entries = stored.filter { old in !entries.contains { $0.tag == old.tag } } + entries
            loaded = true
        } catch CocoaError.fileReadNoSuchFile {
            loaded = true
        } catch is DecodingError {
            // A torn or foreign file holds nothing to keep; the next write replaces it.
            loaded = true
        } catch {
            Logger(subsystem: "haus.xmpp.ios", category: "uploads").notice("upload journal not readable yet: \(error.localizedDescription, privacy: .public)")
        }
    }

    private func save() {
        guard let file, loaded else { return }
        do {
            let data = try JSONEncoder().encode(entries)
            var directory = file.deletingLastPathComponent()
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            var values = URLResourceValues()
            values.isExcludedFromBackup = true
            // Best effort: the journal is written whether or not backups skip it.
            try? directory.setResourceValues(values)
            // Readable when the system relaunches the app for session events on a locked device.
            try data.write(to: file, options: [.atomic, .completeFileProtectionUntilFirstUserAuthentication])
        } catch {
            Logger(subsystem: "haus.xmpp.ios", category: "uploads").error("upload journal not written: \(error.localizedDescription, privacy: .public)")
        }
    }
}

// `queued` is false for a file whose message shows Not sent.
struct UploadRow: Equatable, Sendable {
    let messageID: String
    let url: String?
    let taskID: Int?
    let queued: Bool
}

// Matches the account's rows to the session's tasks and the recorded outcomes by tag. A success of any attempt wins,
// since every attempt carries the same staged ciphertext; a failure counts only for the attempt the row names.
enum UploadPlan {
    struct Adoption: Equatable, Sendable { let taskID: Int; let url: String }

    struct Result: Equatable, Sendable {
        var uploaded: [String: String] = [:]
        // The row's own attempt failed, which counts against its budget; a stranded slot is cleared uncounted.
        var failed: Set<String> = []
        var stranded: Set<String> = []
        var adopted: [String: Adoption] = [:]
        var resume: Set<Int> = []
        var cancel: Set<Int> = []
        var settled: Set<UploadTag> = []
    }

    // A message absent from `rows` no longer waits for an upload. `detectsStranded` holds only once the session has
    // delivered what finished while the app was away.
    static func make(account: String, rows: [UploadRow], tasks: [UploadTaskState], outcomes: [UploadOutcome],
                     detectsStranded: Bool) -> Result {
        var result = Result()
        // Nothing tells which attempt an untagged task carries; its row takes a new slot instead.
        result.cancel.formUnion(tasks.filter { $0.tag == nil && $0.phase == .live }.map(\.taskID))
        let recorded = outcomes.filter { $0.tag.account == account }
        var finished: [UploadTag: Bool] = [:]
        for outcome in recorded { finished[outcome.tag] = finished[outcome.tag] == true || outcome.succeeded }
        let mine = tasks.filter { $0.tag?.account == account }
        for task in mine {
            if case .finished(let succeeded) = task.phase, let tag = task.tag { finished[tag] = finished[tag] == true || succeeded }
        }
        let live = mine.filter { $0.phase == .live }
        let rowsByID = Dictionary(rows.map { ($0.messageID, $0) }, uniquingKeysWith: { first, _ in first })
        var messageIDs = Set(rows.map(\.messageID))
        messageIDs.formUnion(finished.keys.map(\.messageID))
        messageIDs.formUnion(live.compactMap { $0.tag?.messageID })

        for id in messageIDs {
            let ends = finished.filter { $0.key.messageID == id }
            let running = live.filter { $0.tag?.messageID == id }
            result.settled.formUnion(recorded.filter { $0.tag.messageID == id }.map(\.tag))
            guard let row = rowsByID[id] else {
                result.cancel.formUnion(running.map(\.taskID))
                continue
            }
            let successes = ends.filter(\.value).map(\.key)
            if let success = successes.first(where: { $0.url == row.url }) ?? successes.min(by: { $0.url < $1.url }) {
                result.uploaded[id] = success.url
                result.cancel.formUnion(running.map(\.taskID))
                continue
            }
            let keep = running.first { $0.tag?.url == row.url } ?? running.min { $0.taskID < $1.taskID }
            if let keep, let tag = keep.tag {
                if row.url != tag.url || row.taskID != keep.taskID { result.adopted[id] = Adoption(taskID: keep.taskID, url: tag.url) }
                result.resume.insert(keep.taskID)
                result.cancel.formUnion(running.map(\.taskID).filter { $0 != keep.taskID })
                continue
            }
            guard let url = row.url else { continue }
            if ends.keys.contains(where: { $0.url == url }) {
                if row.queued { result.failed.insert(id) } else { result.stranded.insert(id) }
            } else if detectsStranded {
                result.stranded.insert(id)
            }
        }
        return result
    }
}

// Reads and writes under the given account, whichever account is active when the writes land.
struct UploadSettler: Sendable {
    struct Settlement: Equatable, Sendable {
        var uploaded: [String] = []
        var failed: [StoredMessage] = []
    }

    let store: MessageStore
    let tasks: any UploadTasks
    let journal: UploadJournal

    func settle(account: String, detectsStranded: Bool, now: Date) async -> Settlement {
        await journal.serially { await settleNow(account: account, detectsStranded: detectsStranded, now: now) }
    }

    private func settleNow(account: String, detectsStranded: Bool, now: Date) async -> Settlement {
        let states = await tasks.states()
        let outcomes = journal.outcomes(account: account)
        // An unreadable store settles nothing; the journal keeps the outcomes for the next pass.
        let awaiting = (try? await store.attachmentsAwaitingUpload(accountID: account)) ?? []
        var messages = Dictionary(awaiting.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        var rows = awaiting.compactMap { Self.row($0, queued: true) }
        // The awaiting list is capped and leaves out failed messages, so what a task or outcome names is read directly.
        var named = Set(outcomes.map(\.tag.messageID))
        named.formUnion(states.compactMap { $0.tag?.account == account ? $0.tag?.messageID : nil })
        for id in named.subtracting(messages.keys) {
            // A row that cannot be read is treated as gone, as a deleted one is.
            guard let message = try? await store.message(accountID: account, messageID: id),
                  message.attachment?.uploadState == .pending, let row = Self.row(message, queued: false) else { continue }
            messages[id] = message
            rows.append(row)
        }
        let plan = UploadPlan.make(account: account, rows: rows, tasks: states, outcomes: outcomes, detectsStranded: detectsStranded)

        var settlement = Settlement()
        var unwritten = Set<String>()
        for (id, url) in plan.uploaded {
            do {
                try await store.recordAttachmentUploaded(accountID: account, messageID: id, url: url)
                settlement.uploaded.append(id)
            } catch { unwritten.insert(id) }
        }
        for (id, adoption) in plan.adopted {
            do {
                try await store.setAttachmentUploadTask(accountID: account, messageID: id, taskID: adoption.taskID, url: adoption.url)
            } catch { unwritten.insert(id) }
        }
        for id in plan.failed.union(plan.stranded) {
            do {
                try await store.setAttachmentUploadTask(accountID: account, messageID: id, taskID: nil, url: nil)
                if plan.failed.contains(id), let message = messages[id] { settlement.failed.append(message) }
            } catch { unwritten.insert(id) }
        }
        await tasks.apply(resume: plan.resume, cancel: plan.cancel)
        journal.remove(plan.settled.filter { !unwritten.contains($0.messageID) }, now: now)
        if !plan.uploaded.isEmpty || !plan.failed.isEmpty || !plan.stranded.isEmpty || !plan.adopted.isEmpty || !plan.cancel.isEmpty {
            Logger(subsystem: "haus.xmpp.ios", category: "uploads").notice("""
                uploads settled: uploaded \(plan.uploaded.count, privacy: .public) failed \(plan.failed.count, privacy: .public) \
                stranded \(plan.stranded.count, privacy: .public) adopted \(plan.adopted.count, privacy: .public) \
                resumed \(plan.resume.count, privacy: .public) cancelled \(plan.cancel.count, privacy: .public)
                """)
        }
        return settlement
    }

    private static func row(_ message: StoredMessage, queued: Bool) -> UploadRow? {
        guard let attachment = message.attachment else { return nil }
        return UploadRow(messageID: message.id, url: attachment.url, taskID: attachment.uploadTaskID, queued: queued)
    }
}
