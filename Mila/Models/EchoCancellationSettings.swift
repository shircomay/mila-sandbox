import Foundation
import Combine

/// FORK (echo cancellation, spec 03). User settings for removing speaker echo
/// from MEETING recordings: the microphone is run through an acoustic echo
/// canceller, with the meeting app's audio (which Mila already captures) as the
/// reference, before the two are mixed. See `RecordingSession+EchoCancellation`.
///
/// Same shape as `AudioInputSettings` / `VoiceRecognitionSettings`:
/// `@Published` properties that write through to namespaced `UserDefaults`
/// keys, with an injectable `defaults` suite so tests never touch the user's
/// real preferences.
///
/// **Code defaults are the upstream behaviour: everything OFF.** The personal
/// build switches echo cancellation on through `UserDefaults.register(defaults:)`
/// (`ForkBuild.registerDefaults()`), which never overrides a value the user has
/// set and which a test suite with its own `suiteName` never sees — so every
/// read below is a plain `bool(forKey:)`, which honours registered defaults, and
/// nothing here special-cases "unset".
///
/// `RecordingSession` reads these through the static helpers at record-start, so
/// a change applies to the NEXT recording, never to one already running.
@MainActor
final class EchoCancellationSettings: ObservableObject {

    enum Keys {
        static let enabled = "echoCancellation.enabled"
        static let saveDebugAudio = "echoCancellation.saveDebugAudio"
        /// Written by `RecordingSession` when a meeting that used (or tried to
        /// use) the canceller stops. Absent until the first such meeting.
        static let lastSessionSummary = "echoCancellation.lastSessionSummary"
    }

    /// Run meeting recordings' microphone through the echo canceller.
    @Published var enabled: Bool {
        didSet {
            guard enabled != oldValue else { return }
            defaults.set(enabled, forKey: Keys.enabled)
        }
    }

    /// Also write the raw mic, the aligned meeting audio and the cleaned mic as
    /// three WAV files per meeting, for tuning.
    @Published var saveDebugAudio: Bool {
        didSet {
            guard saveDebugAudio != oldValue else { return }
            defaults.set(saveDebugAudio, forKey: Keys.saveDebugAudio)
        }
    }

    /// One line describing how echo cancellation went in the last meeting that
    /// used it, e.g. "echo reduced ≈18 dB · echo delay ≈42 ms · reference
    /// present 63% of the time" or "bypassed: …". Read-only for the UI; the
    /// session writes the defaults key directly, so call
    /// `refreshLastSessionSummary()` when the settings view appears.
    @Published private(set) var lastSessionSummary: String?

    private let defaults: UserDefaults

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        self.enabled = Self.isEnabled(defaults)
        self.saveDebugAudio = Self.savesDebugAudio(defaults)
        self.lastSessionSummary = Self.storedSessionSummary(defaults)
    }

    /// Re-read the summary the last meeting stored.
    func refreshLastSessionSummary() {
        let latest = Self.storedSessionSummary(defaults)
        if latest != lastSessionSummary { lastSessionSummary = latest }
    }

    // MARK: - Reads/writes used outside the UI

    static func isEnabled(_ defaults: UserDefaults) -> Bool {
        defaults.bool(forKey: Keys.enabled)
    }

    static func savesDebugAudio(_ defaults: UserDefaults) -> Bool {
        defaults.bool(forKey: Keys.saveDebugAudio)
    }

    static func storedSessionSummary(_ defaults: UserDefaults) -> String? {
        guard let text = defaults.string(forKey: Keys.lastSessionSummary), !text.isEmpty else { return nil }
        return text
    }

    /// Record the outcome of the meeting that just ended. A nil or empty
    /// summary removes the key.
    static func storeSessionSummary(_ summary: String?, in defaults: UserDefaults) {
        if let summary, !summary.isEmpty {
            defaults.set(summary, forKey: Keys.lastSessionSummary)
        } else {
            defaults.removeObject(forKey: Keys.lastSessionSummary)
        }
    }
}

/// Builds the human-readable "Last meeting: …" line. Pure and free of user
/// content (numbers only), so it is safe to log and trivial to test. Takes
/// primitives rather than the canceller's `Statistics` value so it can be tested
/// without constructing one.
enum EchoCancellationSummary {
    static func sessionLine(framesProcessed: Int,
                            framesWithReference: Int,
                            echoReductionDb: Double?,
                            estimatedEchoDelayMs: Double?,
                            timestampsTrusted: Bool) -> String {
        var parts: [String] = []
        if let db = echoReductionDb.flatMap(Self.whole) {
            parts.append("echo reduced ≈\(db) dB")
        } else {
            parts.append("echo reduction not measured")
        }
        if let ms = estimatedEchoDelayMs.flatMap(Self.whole) {
            parts.append("echo delay ≈\(ms) ms")
        }
        if framesProcessed > 0 {
            let share = 100.0 * Double(framesWithReference) / Double(framesProcessed)
            parts.append("reference present \(Self.whole(share) ?? 0)% of the time")
        } else {
            parts.append("no microphone audio was processed")
        }
        if !timestampsTrusted {
            parts.append("clocks disagreed, aligned by arrival order")
        }
        return parts.joined(separator: " · ")
    }

    /// The line stored when the canceller could not run for this meeting.
    static func bypassLine(reason: String) -> String {
        "bypassed: \(reason)"
    }

    /// `x` rounded to a whole number, or nil for NaN / ±infinity (an `Int(_:)`
    /// of those traps). Magnitudes are clamped so a pathological statistic
    /// cannot produce a ten-digit figure in the UI.
    private static func whole(_ x: Double) -> Int? {
        guard x.isFinite else { return nil }
        return Int(max(-999, min(999, x)).rounded())
    }
}
