import Foundation

package struct Baseline: Equatable {
    // File, then rule, then the fingerprints of accepted violations (a multiset), or the allowed value of a measure.
    package typealias Entries = [String: [String: [String]]]

    package private(set) var entries: Entries

    package init(entries: Entries = [:]) {
        self.entries = entries
    }

    package init(recording violations: [Violation]) {
        var out: Entries = [:]
        for violation in violations {
            out[violation.file, default: [:]][violation.rule, default: []].append(violation.baselineEntry)
        }
        entries = out.mapValues { $0.mapValues { $0.sorted() } }
    }

    package static func load(_ path: String) throws -> Baseline {
        guard FileManager.default.fileExists(atPath: path) else { return Baseline() }
        let data = try Data(contentsOf: URL(fileURLWithPath: path))
        guard let entries = try JSONSerialization.jsonObject(with: data) as? Entries else {
            throw UsageError("\(path) is not a slop-check baseline")
        }
        return Baseline(entries: entries)
    }

    package func save(_ path: String) throws {
        let options: JSONSerialization.WritingOptions = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        let data = try JSONSerialization.data(withJSONObject: entries, options: options)
        try (data + Data("\n".utf8)).write(to: URL(fileURLWithPath: path))
    }

    package var count: Int {
        entries.values.flatMap(\.values).map(\.count).reduce(0, +)
    }
}

package struct Comparison {
    package var reported: [Violation] = []
    package var kept: [Violation] = []
    // Entries that no longer occur or allow more than they need: in the checked files, or for a deleted file.
    package var fixed = 0
}

extension Baseline {
    package func compare(_ violations: [Violation], checked: Set<String>) -> Comparison {
        var remaining = entries
        var result = Comparison()
        for violation in violations {
            var pool = remaining[violation.file]?[violation.rule] ?? []
            if let measure = violation.measure {
                let allowed = pool.first.flatMap { Int($0) }
                if let allowed, measure <= allowed {
                    result.kept.append(violation)
                    if measure < allowed { result.fixed += 1 }
                } else {
                    result.reported.append(allowed.map { overAllowance(violation, allowed: $0) } ?? violation)
                }
                remaining[violation.file]?[violation.rule] = nil
            } else if let index = pool.firstIndex(of: violation.fingerprint) {
                pool.remove(at: index)
                remaining[violation.file]?[violation.rule] = pool
                result.kept.append(violation)
            } else {
                result.reported.append(violation)
            }
        }
        let outdated = remaining.filter { checked.contains($0.key) || !Self.exists($0.key) }
        result.fixed += outdated.values.flatMap(\.values).map(\.count).reduce(0, +)
        return result
    }

    // Drops what the checked files no longer contain, and deleted files, and lowers measures; never adds an entry.
    package func shrunk(by comparison: Comparison, checked: Set<String>) -> Baseline {
        var next = entries.filter { !checked.contains($0.key) && Self.exists($0.key) }
        for (file, rules) in Baseline(recording: comparison.kept).entries {
            next[file] = rules
        }
        for violation in comparison.reported where violation.measure != nil {
            if let old = entries[violation.file]?[violation.rule] {
                next[violation.file, default: [:]][violation.rule] = old
            }
        }
        return Baseline(entries: next)
    }

    private static func exists(_ file: String) -> Bool {
        FileManager.default.fileExists(atPath: file)
    }

    private func overAllowance(_ violation: Violation, allowed: Int) -> Violation {
        Violation(file: violation.file, line: violation.line, rule: violation.rule,
                  message: violation.message + " (the baseline allows \(allowed) comment lines here, this has \(violation.measure ?? 0))",
                  fingerprint: violation.fingerprint, measure: violation.measure)
    }
}
