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

    private static var processListAddress = AudioObjectPropertyAddress(
        mSelector: kAudioHardwarePropertyProcessObjectList,
        mScope: kAudioObjectPropertyScopeGlobal,
        mElement: kAudioObjectPropertyElementMain
    )

    /// Begin watching. Call when the mic enters warm idle. Safe to call twice.
    func start() {
        guard Self.isSupported, !listening else { return }
        let block: AudioObjectPropertyListenerBlock = { [weak self] _, _ in
            // Listener may fire on an arbitrary queue — hop to the main actor.
            Task { @MainActor in self?.evaluate() }
        }
        let status = AudioObjectAddPropertyListenerBlock(
            AudioObjectID(kAudioObjectSystemObject),
            &Self.processListAddress,
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
        AudioObjectRemovePropertyListenerBlock(
            AudioObjectID(kAudioObjectSystemObject),
            &Self.processListAddress,
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

    /// PID of `coreaudiod`, resolved once. VPIO's own I/O can surface under the
    /// audio daemon rather than our app, so we must not count it as "another app".
    private lazy var coreAudiodPID: pid_t = Self.pidOfProcess(named: "coreaudiod")

    /// True if a real, foreign user app currently has the mic input running.
    /// We require a valid PID that is neither ours nor coreaudiod's — an
    /// unresolvable/system PID is treated as "not another app" so the warm window
    /// isn't defeated by our own VPIO engine or transient audio objects.
    @available(macOS 14.4, *)
    private func anyOtherProcessUsingInput() -> Bool {
        for processObject in processObjectIDs() {
            guard processIsRunningInput(processObject) else { continue }
            let pid = processPID(processObject)
            // A real, foreign user of the mic: valid PID, not ours, not the audio
            // daemon (which can surface our own VPIO I/O under its PID).
            if pid > 0, pid != myPID, pid != coreAudiodPID { return true }
        }
        return false
    }

    /// First PID matching a process name, or -1. Used to resolve coreaudiod.
    private static func pidOfProcess(named name: String) -> pid_t {
        var pid: pid_t = -1
        let task = Process()
        task.executableURL = URL(fileURLWithPath: "/usr/bin/pgrep")
        task.arguments = ["-x", name]
        let pipe = Pipe()
        task.standardOutput = pipe
        do {
            try task.run()
            task.waitUntilExit()
            let data = pipe.fileHandleForReading.readDataToEndOfFile()
            if let s = String(data: data, encoding: .utf8)?
                .trimmingCharacters(in: .whitespacesAndNewlines)
                .split(separator: "\n").first,
               let p = pid_t(s) { pid = p }
        } catch {
            Log.error("MicUsageMonitor: couldn't resolve \(name) pid: \(error.localizedDescription)")
        }
        return pid
    }

    private func processObjectIDs() -> [AudioObjectID] {
        var size = UInt32(0)
        var addr = Self.processListAddress
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
