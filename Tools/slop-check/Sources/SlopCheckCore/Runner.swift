import Foundation

package struct UsageError: Error, CustomStringConvertible {
    package let description: String

    init(_ description: String) {
        self.description = description
    }
}

package struct Options {
    package static let usage = """
        usage: slop-check [--baseline FILE [--shrink-baseline | --fail-on-fixed]] PATH...
               slop-check --write-baseline FILE PATH...
        PATHs are Swift files or directories. Exit status 1 means violations the baseline does not cover.
        --shrink-baseline drops baseline entries the checked files no longer need; it never adds one.
        --fail-on-fixed exits 1 while the baseline holds such entries, so an improvement cannot slip back.
        """

    var baselinePath: String?
    var writeBaselinePath: String?
    var shrink = false
    var failOnFixed = false
    var paths: [String] = []

    package init(arguments: [String]) throws {
        var rest = arguments[...]
        while let argument = rest.popFirst() {
            switch argument {
            case "--baseline": baselinePath = try Self.value(of: argument, from: &rest)
            case "--write-baseline": writeBaselinePath = try Self.value(of: argument, from: &rest)
            case "--shrink-baseline": shrink = true
            case "--fail-on-fixed": failOnFixed = true
            case "-h", "--help": throw UsageError(Self.usage)
            default: paths.append(argument)
            }
        }
        if shrink && baselinePath == nil { throw UsageError("--shrink-baseline needs --baseline\n" + Self.usage) }
    }

    private static func value(of option: String, from rest: inout ArraySlice<String>) throws -> String {
        guard let value = rest.popFirst() else { throw UsageError("\(option) needs a file\n" + usage) }
        return value
    }
}

package enum Runner {
    package static func run(_ options: Options) async throws -> Int32 {
        let files = swiftFiles(in: options.paths)
        let violations = try await check(files)
        if let path = options.writeBaselinePath {
            let baseline = Baseline(recording: violations)
            try baseline.save(path)
            write("wrote \(path): \(baseline.count) entries in \(baseline.entries.count) files\n")
            return 0
        }
        let baseline = try options.baselinePath.map(Baseline.load) ?? Baseline()
        let checked = Set(files)
        let comparison = baseline.compare(violations, checked: checked)
        if options.shrink, let path = options.baselinePath {
            let next = baseline.shrunk(by: comparison, checked: checked)
            if next != baseline { try next.save(path) }
        }
        let unlocked = options.shrink ? 0 : comparison.fixed
        report(comparison, unlocked: unlocked, failOnFixed: options.failOnFixed)
        return comparison.reported.isEmpty && !(options.failOnFixed && unlocked > 0) ? 0 : 1
    }

    private static func report(_ comparison: Comparison, unlocked: Int, failOnFixed: Bool) {
        let sorted = comparison.reported.sorted { ($0.file, $0.line) < ($1.file, $1.line) }
        var out = sorted.map { "\($0.file):\($0.line): error: \($0.message) [\($0.rule)]\n" }.joined()
        if unlocked > 0 {
            let level = failOnFixed ? "error" : "note"
            out += "\(level): \(unlocked) baseline entries are fixed or stale; run Tools/check.sh shrink and commit\n"
        }
        if !sorted.isEmpty {
            out += "\n\(sorted.count) slop-check violation(s). Each message names the fix. Fix the comment or the code, not the baseline.\n"
        }
        write(out)
    }

    private static func write(_ text: String) {
        FileHandle.standardOutput.write(Data(text.utf8))
    }

    static func swiftFiles(in paths: [String]) -> [String] {
        var files: [String] = []
        for path in paths {
            var isDirectory: ObjCBool = false
            guard FileManager.default.fileExists(atPath: path, isDirectory: &isDirectory) else { continue }
            if !isDirectory.boolValue {
                if path.hasSuffix(".swift") { files.append(path) }
                continue
            }
            let found = FileManager.default.enumerator(atPath: path)?.compactMap { $0 as? String } ?? []
            files += found.filter { $0.hasSuffix(".swift") && !$0.contains(".build/") }
                .map { (path as NSString).appendingPathComponent($0) }
        }
        return files.map { $0.hasPrefix("./") ? String($0.dropFirst(2)) : $0 }.sorted()
    }

    private static func check(_ files: [String]) async throws -> [Violation] {
        try await withThrowingTaskGroup(of: [Violation].self) { group in
            for path in files {
                group.addTask {
                    FileChecker.check(path: path, text: try String(contentsOfFile: path, encoding: .utf8))
                }
            }
            var all: [Violation] = []
            for try await found in group {
                all += found
            }
            return all
        }
    }
}
