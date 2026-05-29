import Foundation
import os

/// Shared logger. Lands in the unified log under this subsystem and also prints
/// to stderr for terminal/Xcode console visibility.
enum Log {
    private static let logger = Logger(subsystem: "com.udabby.WhisperDictation", category: "dictation")

    static func info(_ message: String) {
        logger.info("\(message, privacy: .public)")
        FileHandle.standardError.write(Data("[WD] \(message)\n".utf8))
    }

    static func error(_ message: String) {
        logger.error("\(message, privacy: .public)")
        FileHandle.standardError.write(Data("[WD][ERROR] \(message)\n".utf8))
    }
}
