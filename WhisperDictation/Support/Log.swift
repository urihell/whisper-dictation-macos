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
///
/// That redaction also makes field debugging impossible through Console — so a
/// small in-memory tail of recent lines is kept for the menu's "Copy
/// Diagnostics Report". Messages contain no dictated text by design, the
/// buffer never touches disk, and export happens only on explicit user action.
enum Log {
    private static let logger = Logger(subsystem: "com.udabby.WhisperDictation", category: "dictation")
    private static let recent = RingBuffer()

    static func info(_ message: String) {
        logger.info("\(message, privacy: .private)")
        FileHandle.standardError.write(Data("[WD] \(message)\n".utf8))
        recent.append(level: "INFO", message)
    }

    static func error(_ message: String) {
        logger.error("\(message, privacy: .private)")
        FileHandle.standardError.write(Data("[WD][ERROR] \(message)\n".utf8))
        recent.append(level: "ERROR", message)
    }

    /// The in-memory tail (oldest first) for the diagnostics report.
    static func recentLines() -> [String] {
        recent.snapshot()
    }

    /// Lock-guarded ring of recent lines. Log is called from the main actor,
    /// background tasks, and real-time audio tap threads alike.
    private final class RingBuffer: @unchecked Sendable {
        private let lock = NSLock()
        private var lines: [String] = []
        private let capacity = 300

        private static let stamp: DateFormatter = {
            let f = DateFormatter()
            f.dateFormat = "HH:mm:ss.SSS"
            return f
        }()

        func append(level: String, _ message: String) {
            let line = "\(Self.stamp.string(from: Date())) [\(level)] \(message)"
            lock.lock()
            lines.append(line)
            if lines.count > capacity {
                lines.removeFirst(lines.count - capacity)
            }
            lock.unlock()
        }

        func snapshot() -> [String] {
            lock.lock(); defer { lock.unlock() }
            return lines
        }
    }
}
