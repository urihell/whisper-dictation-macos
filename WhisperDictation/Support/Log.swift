import Foundation
import os

/// Shared logger. Lands in the unified log under this subsystem and also prints
/// to stderr for terminal/Xcode console visibility.
///
/// Messages are redacted as `<private>` in the persistent unified log (the
/// default for dynamic strings) so any user content that ever flows through
/// here can't leak into Console/`log show`/sysdiagnose. Callers should still
/// avoid passing dictated content at all — the full text is visible on stderr
/// when running the binary from a terminal for debugging.
enum Log {
    private static let logger = Logger(subsystem: "com.udabby.WhisperDictation", category: "dictation")

    static func info(_ message: String) {
        logger.info("\(message, privacy: .private)")
        FileHandle.standardError.write(Data("[WD] \(message)\n".utf8))
    }

    static func error(_ message: String) {
        logger.error("\(message, privacy: .private)")
        FileHandle.standardError.write(Data("[WD][ERROR] \(message)\n".utf8))
    }
}
