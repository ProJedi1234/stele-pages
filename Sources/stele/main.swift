import Foundation
import Logging
import SteleCore

LoggingSystem.bootstrap { label in
    var handler = StreamLogHandler.standardOutput(label: label)
    handler.logLevel = ProcessInfo.processInfo.environment["STELE_LOG_LEVEL"]
        .flatMap { Logger.Level(rawValue: $0.lowercased()) } ?? .info
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
