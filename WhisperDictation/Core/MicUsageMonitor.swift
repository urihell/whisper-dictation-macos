import Foundation
import CoreAudio

/// Watches whether **another** process is capturing the microphone, so the app
/// can release its warm-idle Voice-Processing engine the moment a call app
/// (Google Meet, Zoom, FaceTime…) starts recording — avoiding any chance our
/// echo-cancellation interferes with theirs.
///
/// Uses `kAudioHardwarePropertyProcessObjectList` to enumerate every process
/// connected to the audio system, then checks each one's `IsRunningInput` and
/// PID, excluding our own. A property listener fires when the list changes, so
/// detection is event-driven (no polling).
///
/// This process-introspection API postdates the app's macOS 14.0 floor, so the
/// whole monitor is gated on availability; on older systems it's inert and the
/// time-window release is the only mechanism.
@MainActor
final class MicUsageMonitor {
    /// Called (on the main actor) when another process STARTS using the mic input
    /// while we're listening. The controller uses this to release a warm mic.
    var onOtherProcessStartedInput: (() -> Void)?

    private var listening = false
    private let myPID = pid_t(ProcessInfo.processInfo.processIdentifier)

    /// Whether the OS exposes per-process audio introspection (macOS 14.4+).
    static var isSupported: Bool {
        if #available(macOS 14.4, *) { return true }
        return false
    }

    /// Fresh copy per use: the listener/data APIs take a pointer, and a shared
    /// mutable static passed by `&` is a strict-concurrency violation.
    private static func processListAddress() -> AudioObjectPropertyAddress {
        AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyProcessObjectList,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
    }

    /// Begin watching. Call when the mic enters warm idle. Safe to call twice.
    func start() {
        guard Self.isSupported, !listening else { return }
        let block: AudioObjectPropertyListenerBlock = { [weak self] _, _ in
            // Delivered on DispatchQueue.main (passed below) — that IS the main
            // actor's executor, so assert the hop instead of re-dispatching.
            MainActor.assumeIsolated { self?.evaluate() }
        }
        var addr = Self.processListAddress()
        let status = AudioObjectAddPropertyListenerBlock(
            AudioObjectID(kAudioObjectSystemObject),
            &addr,
            DispatchQueue.main,
            block
        )
        guard status == noErr else {
            Log.error("MicUsageMonitor: couldn't add listener (\(status)).")
            return
        }
        activeBlock = block
        listening = true
        Log.info("MicUsageMonitor: watching for other mic users.")
    }

    /// Stop watching. Call when the warm mic is released (or adopted by a session).
    func stop() {
        guard listening, let block = activeBlock else { return }
        var addr = Self.processListAddress()
        AudioObjectRemovePropertyListenerBlock(
            AudioObjectID(kAudioObjectSystemObject),
            &addr,
            DispatchQueue.main,
            block
        )
        activeBlock = nil
        listening = false
    }

    /// Retained so the exact same block can be removed in `stop()`.
    private var activeBlock: AudioObjectPropertyListenerBlock?

    private func evaluate() {
        guard listening else { return }
        guard #available(macOS 14.4, *) else { return }
        if anyOtherProcessUsingInput() {
            Log.info("MicUsageMonitor: another process started mic input — releasing warm mic.")
            onOtherProcessStartedInput?()
        }
    }

    /// System daemons whose mic I/O is really OUR OWN capture surfacing under a
    /// different PID, so they must never count as "another app":
    ///  - `coreaudiod` — the audio HAL daemon; VPIO's aggregate-device I/O can
    ///    appear under it.
    ///  - `corespeechd` — enabling Voice Processing on our engine spins up Apple's
    ///    CoreSpeech daemon for the input pipeline's whole lifetime (verified:
    ///    present during our recording and warm idle, absent when fully released).
    ///    Counting it made the monitor self-trigger and tear the warm engine down
    ///    ~0.3s after every session, defeating warm-up entirely.
    private static let excludedDaemons: Set<String> = ["coreaudiod", "corespeechd"]

    /// True if a real, foreign user app currently has the mic input running.
    /// A valid PID that is neither ours nor an excluded system daemon counts.
    /// Daemon identity is checked by executable name, resolved fresh per check —
    /// a cached PID goes stale when coreaudiod/corespeechd restarts, which would
    /// silently bring the self-trigger bug back. An unresolvable name is treated
    /// as "not another app" so a just-exited process can't spuriously release
    /// the warm mic.
    @available(macOS 14.4, *)
    private func anyOtherProcessUsingInput() -> Bool {
        for processObject in processObjectIDs() {
            guard processIsRunningInput(processObject) else { continue }
            let pid = processPID(processObject)
            guard pid > 0, pid != myPID else { continue }
            guard let name = Self.executableName(of: pid) else { continue }
            if !Self.excludedDaemons.contains(name) {
                return true
            }
        }
        return false
    }

    /// The executable name for a PID via `proc_pidpath` (in-process, no fork),
    /// or nil if the process is gone or unreadable.
    private static func executableName(of pid: pid_t) -> String? {
        var buffer = [CChar](repeating: 0, count: 4 * 1024)
        let length = proc_pidpath(pid, &buffer, UInt32(buffer.count))
        guard length > 0 else { return nil }
        let path = String(cString: buffer)
        return (path as NSString).lastPathComponent
    }

    private func processObjectIDs() -> [AudioObjectID] {
        var size = UInt32(0)
        var addr = Self.processListAddress()
        guard AudioObjectGetPropertyDataSize(AudioObjectID(kAudioObjectSystemObject), &addr, 0, nil, &size) == noErr,
              size > 0 else { return [] }
        let count = Int(size) / MemoryLayout<AudioObjectID>.size
        var ids = [AudioObjectID](repeating: 0, count: count)
        guard AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &addr, 0, nil, &size, &ids) == noErr else {
            return []
        }
        return ids
    }

    private func processIsRunningInput(_ object: AudioObjectID) -> Bool {
        var addr = AudioObjectPropertyAddress(
            mSelector: kAudioProcessPropertyIsRunningInput,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        var running = UInt32(0)
        var size = UInt32(MemoryLayout<UInt32>.size)
        guard AudioObjectGetPropertyData(object, &addr, 0, nil, &size, &running) == noErr else { return false }
        return running != 0
    }

    private func processPID(_ object: AudioObjectID) -> pid_t {
        var addr = AudioObjectPropertyAddress(
            mSelector: kAudioProcessPropertyPID,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        var pid = pid_t(-1)
        var size = UInt32(MemoryLayout<pid_t>.size)
        guard AudioObjectGetPropertyData(object, &addr, 0, nil, &size, &pid) == noErr else { return -1 }
        return pid
    }
}
