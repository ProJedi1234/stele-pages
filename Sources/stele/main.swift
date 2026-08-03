import Foundation
import Logging
import SteleCore

// Read here rather than in Configuration because the logging system has to exist
// before anything else can report a problem — but the contract is the same as every
// other variable: a bad value stops the process and names itself, rather than being
// silently swapped for the default while someone is trying to turn on debug logging.
let logLevel: Logger.Level
if let raw = ProcessInfo.processInfo.environment["STELE_LOG_LEVEL"]?
    .trimmingCharacters(in: .whitespaces), !raw.isEmpty
{
    guard let parsed = Logger.Level(rawValue: raw.lowercased()) else {
        FileHandle.standardError.write(Data("""
            stele: STELE_LOG_LEVEL is set to '\(raw)', which is not valid. Expected one \
            of: trace, debug, info, notice, warning, error, critical.\n
            """.utf8))
        exit(78)  // EX_CONFIG
    }
    logLevel = parsed
} else {
    logLevel = .info
}

LoggingSystem.bootstrap { label in
    var handler = StreamLogHandler.standardOutput(label: label)
    handler.logLevel = logLevel
    return handler
}

let logger = Logger(label: "stele")

let configuration: Configuration
do {
    configuration = try Configuration()
} catch {
    // Config problems are the most common way this fails to start, and a stack trace
    // helps nobody. Print the variable that's wrong and stop.
    FileHandle.standardError.write(Data("stele: \(error)\n".utf8))
    exit(78)  // EX_CONFIG
}

let app = try await buildApplication(configuration: configuration, logger: logger)
try await app.runService()
