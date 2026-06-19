import Foundation
import os

let logSubsystem = "com.alexspeller.urlhandler"

/// A `JSEngine.Logger` backed by `os.Logger` (visible in Console.app / `log stream`).
public func makeOSLogger(category: String = "agent") -> JSEngine.Logger {
    let logger = os.Logger(subsystem: logSubsystem, category: category)
    return { level, message in
        switch level {
        case "error":
            logger.error("\(message, privacy: .public)")
        case "warn":
            logger.warning("\(message, privacy: .public)")
        default:
            // `.notice` (persisted, shown by default in `log show`) — routing events are useful diagnostics.
            logger.notice("\(message, privacy: .public)")
        }
    }
}

/// A `JSEngine.Logger` that appends timestamped lines to a file (tailable for debugging).
/// Truncates on creation so each agent session starts fresh and the file can't grow unbounded.
public func makeFileLogger(at url: URL, truncate: Bool = true) -> JSEngine.Logger {
    let fm = FileManager.default
    try? fm.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
    if truncate || !fm.fileExists(atPath: url.path) {
        fm.createFile(atPath: url.path, contents: nil)
    }
    let handle = try? FileHandle(forWritingTo: url)
    handle?.seekToEndOfFile()
    let formatter = ISO8601DateFormatter()
    return { level, message in
        let line = "\(formatter.string(from: Date())) [\(level)] \(message)\n"
        handle?.write(Data(line.utf8))
    }
}

/// Combines loggers so a message is delivered to each.
public func combineLoggers(_ loggers: JSEngine.Logger...) -> JSEngine.Logger {
    { level, message in loggers.forEach { $0(level, message) } }
}
