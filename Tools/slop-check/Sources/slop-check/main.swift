import Foundation
import SlopCheckCore

do {
    let options = try Options(arguments: Array(CommandLine.arguments.dropFirst()))
    exit(try await Runner.run(options))
} catch {
    FileHandle.standardError.write(Data("slop-check: \(error)\n".utf8))
    exit(2)
}
