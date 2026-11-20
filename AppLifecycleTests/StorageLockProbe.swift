import Darwin
import Foundation

// POSIX record locks belong to the process, so a store file this process has no descriptor on holds none of its locks.
// The transport lock file stays open by design and is probed apart.
enum StorageLockProbe {
    static func sqliteDescriptors(_ database: URL) -> Set<String> {
        guard let resolved = realpath(database.deletingLastPathComponent().path, nil) else { return [] }
        let prefix = String(cString: resolved) + "/"
        free(resolved)
        var found: Set<String> = []
        var path = [CChar](repeating: 0, count: Int(MAXPATHLEN))
        for descriptor in 0..<getdtablesize() where fcntl(descriptor, F_GETPATH, &path) != -1 {
            let name = String(decoding: path.prefix { $0 != 0 }.map { UInt8(bitPattern: $0) }, as: UTF8.self)
            if name.hasPrefix(prefix + "messages.sqlite"), !name.hasSuffix(".transport-lock") {
                found.insert(String(name.dropFirst(prefix.count)))
            }
        }
        return found
    }

    // flock conflicts between open file descriptions of one process too, so a fresh one sees any store's lease.
    static func transportLockIsFree(_ database: URL) -> Bool {
        let descriptor = open(database.path + ".transport-lock", O_RDWR | O_CLOEXEC)
        guard descriptor >= 0 else { return false }
        defer { close(descriptor) }
        guard flock(descriptor, LOCK_EX | LOCK_NB) == 0 else { return false }
        flock(descriptor, LOCK_UN)
        return true
    }
}
