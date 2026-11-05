import Foundation

/// Decides when to skip Apple's Voice Processing I/O (VPIO) for an input device
/// after it failed to deliver audio.
///
/// Failures are usually transient: a stale CoreAudio Voice-Processing state
/// (observed after app crashes, on every mic at once, until coreaudiod
/// restarted), or another app holding the audio HAL. So VPIO is skipped for a
/// short cooldown and then tried again. After `giveUpAfter` failures on the
/// same device it stays off until relaunch, so a persistently broken state
/// doesn't cost a dead ~2s start every cooldown. Nothing is persisted: a
/// relaunch (or a CoreAudio restart plus relaunch) always gets a fresh try.
///
/// Devices are keyed by their persistent CoreAudio UID, so a failure on one mic
/// never disables VPIO on another.
struct VPIOFailurePolicy {
    var cooldown: TimeInterval = 30
    var giveUpAfter = 2

    private var failures: [String: Int] = [:]
    private var cooldownUntil: [String: Date] = [:]

    enum Outcome: Equatable {
        case coolingDown(TimeInterval)
        case disabledUntilRelaunch
    }

    /// Records a VPIO failure on `device` and says what happens next.
    mutating func recordFailure(device: String, now: Date = Date()) -> Outcome {
        let count = (failures[device] ?? 0) + 1
        failures[device] = count
        if count >= giveUpAfter {
            cooldownUntil[device] = nil
            return .disabledUntilRelaunch
        }
        cooldownUntil[device] = now.addingTimeInterval(cooldown)
        return .coolingDown(cooldown)
    }

    /// Whether VPIO should be skipped for `device` right now.
    func shouldSkip(device: String, now: Date = Date()) -> Bool {
        if (failures[device] ?? 0) >= giveUpAfter { return true }
        guard let until = cooldownUntil[device] else { return false }
        return now < until
    }
}
