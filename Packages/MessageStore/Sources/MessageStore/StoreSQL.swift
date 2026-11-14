import Darwin
import Foundation

enum Value {
    case text(String), integer(Int), real(Double), blob(Data), null
    var data: Data? { if case let .blob(value) = self { return value }; return nil }
    var string: String { if case let .text(value) = self { return value }; return "" }
    var optionalString: String? { if case let .text(value) = self { return value }; return nil }
    var integer: Int { if case let .integer(value) = self { return value }; return 0 }
    var double: Double {
        if case let .real(value) = self { return value }
        if case let .integer(value) = self { return Double(value) }
        return 0
    }
    // A nullable REAL column holding seconds since 1970.
    var optionalDate: Date? {
        switch self {
        case .real(let seconds): Date(timeIntervalSince1970: seconds)
        case .integer(let seconds): Date(timeIntervalSince1970: TimeInterval(seconds))
        default: nil
        }
    }
}

extension Connection {
    // Inside a transaction: a throw undoes only the body's writes.
    func savepoint<T>(_ name: String, _ body: () throws -> T) throws -> T {
        try execute("SAVEPOINT \(name)")
        do { let value = try body(); try execute("RELEASE \(name)"); return value }
        catch {
            // The body's error is the one to report; a failed rollback leaves the outer transaction to roll back.
            try? execute("ROLLBACK TO \(name)")
            // Releasing an already rolled-back savepoint fails only when it no longer exists.
            try? execute("RELEASE \(name)")
            throw error
        }
    }
}

// Which file a connection opened, compared again once the lease is held.
struct FileIdentity: Equatable, Sendable {
    let device: UInt64
    let inode: UInt64
    init?(path: String) {
        var info = stat()
        guard stat(path, &info) == 0 else { return nil }
        device = UInt64(info.st_dev); inode = UInt64(info.st_ino)
    }
}
