import Foundation
import AVFoundation
import OSLog
import EchoCancellation

private let aecLog = Logger(subsystem: "io.island.whisper.IslandWhisper", category: "EchoCancellation")

/// The two capture clocks (microphone host time and ScreenCaptureKit
/// presentation time) are assumed to be the same mach host clock. When the
/// first timestamps of the two streams are further apart than this they are
/// not, and the canceller is switched to contiguous (arrival-order) mode.
private let maxClockMismatchSeconds = 5.0

/// FORK (echo cancellation, spec 03). Everything `RecordingSession` needs to
/// know about echo cancellation for the recording in progress.
///
/// Lives in its own object, created once per session, so the upstream file
/// carries a single stored property and the extension in this file (which cannot
/// see `RecordingSession`'s `private` members) can reach the state. Touched only
/// from the main actor, like the session itself.
final class EchoCancellationSessionState {
    /// Non-nil only while a MEETING recording that has echo cancellation on is
    /// running. `startFakeForTesting` never creates one.
    var stage: EchoCancellationStage?

    /// False once the mic and app-audio clocks were found to disagree: from
    /// then on no timestamps are passed to the stage (contiguous mode).
    var timestampsTrusted = true

    /// True when the mic tap was told NOT to apply adaptive gain, so the session
    /// must apply it to the cleaned samples.
    var deferredGain = false

    /// The recorder's gain controller, captured on first use. `MicrophoneRecorder.stop()`
    /// clears `gain`, but the final flush at `RecordingSession.stop()` happens after it.
    var gain: AdaptiveGainController?

    /// Most recent timestamp seen on each stream, for the one-off clock check.
    var lastMicTimestamp: Double?
    var lastReferenceTimestamp: Double?
    var clockChecked = false

    /// Cleaned samples already pulled out of the stage (by the clock check, which
    /// can run from the reference path) but not yet handed to the mixer. They
    /// precede everything the stage emits next, so they are prepended to it.
    var carry: [Float] = []

    var debugAudio: AECDebugAudioWriter?

    /// Where the settings and the last-meeting summary are read/written.
    /// `.standard` in the app; tests inject a throwaway suite.
    var defaults: UserDefaults = .standard
}

extension RecordingSession {

    // MARK: - Start / teardown

    /// Called by `start()` before the mic starts. Decides whether this recording
    /// runs the canceller and, if so, arms the timestamp queues and the deferred
    /// gain. Every other source — and a meeting with the setting off — ends up
    /// with no stage, disabled queues and gain left in the tap: exactly today's
    /// behaviour.
    func beginEchoCancellation(source: RecordingSource, outputURL: URL) {
        discardEchoCancellation()
        guard source == .meeting, EchoCancellationSettings.isEnabled(echo.defaults) else { return }
        guard let stage = EchoCancellationStage(configuration: .init()) else {
            // Bypass, and say so: the Settings pane shows this line.
            aecLog.error("echo canceller could not be created — recording this meeting without echo cancellation")
            EchoCancellationSettings.storeSessionSummary(
                EchoCancellationSummary.bypassLine(reason: "the echo canceller could not start"),
                in: echo.defaults)
            return
        }
        activateEchoCancellation(stage: stage, deferGain: true, gain: nil)
        attachDebugAudioIfEnabled(outputURL: outputURL)
        aecLog.log("echo cancellation on for this meeting")
    }

    /// Drop the stage and put the recorders back to their default behaviour.
    /// Never writes audio. Used by `cancelAll()`, by `start()`'s failure path
    /// and, after the final flush, by `stop()`.
    func discardEchoCancellation() {
        echo.stage?.frameObserver = nil
        echo.debugAudio?.close()
        echo.debugAudio = nil
        echo.stage = nil
        echo.timestampsTrusted = true
        echo.deferredGain = false
        echo.gain = nil
        echo.lastMicTimestamp = nil
        echo.lastReferenceTimestamp = nil
        echo.clockChecked = false
        echo.carry.removeAll(keepingCapacity: false)
        mic.timestamps.isEnabled = false
        mic.timestamps.reset()
        system.timestamps.isEnabled = false
        system.timestamps.reset()
        mic.deferGainToConsumer = false
    }

    /// Test seam: install (or, with nil, remove) a stage the way `start()` would,
    /// without a real recorder. The upstream tests never call this, so they
    /// never see a stage. `deferGain: false` models "the tap already applied
    /// gain" (the setting was off for the tap), `gain` is the controller the
    /// session applies when it is deferred, and `defaults` is where the session
    /// reads the debug-audio setting and writes its summary.
    func installEchoStageForTesting(_ stage: EchoCancellationStage?,
                                    deferGain: Bool,
                                    gain: AdaptiveGainController? = nil,
                                    defaults: UserDefaults = .standard) {
        discardEchoCancellation()
        echo.defaults = defaults
        guard let stage else { return }
        activateEchoCancellation(stage: stage, deferGain: deferGain, gain: gain)
        attachDebugAudioIfEnabled(outputURL: fileURL)
    }

    private func activateEchoCancellation(stage: EchoCancellationStage,
                                          deferGain: Bool,
                                          gain: AdaptiveGainController?) {
        echo.stage = stage
        echo.deferredGain = deferGain
        echo.gain = gain
        echo.timestampsTrusted = true
        echo.lastMicTimestamp = nil
        echo.lastReferenceTimestamp = nil
        echo.clockChecked = false
        echo.carry.removeAll(keepingCapacity: false)
        // Fresh queues, THEN enabled: nothing pushed for an earlier recording
        // may be popped as this one's first timestamp.
        mic.timestamps.reset()
        system.timestamps.reset()
        mic.timestamps.isEnabled = true
        system.timestamps.isEnabled = true
        mic.deferGainToConsumer = deferGain
    }

    // MARK: - Per-buffer path

    /// App audio for the reference. Called from `consumeSystem`'s meeting branch
    /// with the timestamp popped for THIS buffer.
    func echoAppendReference(_ samples: [Float], hostTime ts: Double?) {
        guard let stage = echo.stage else { return }
        if let ts { echo.lastReferenceTimestamp = ts }
        checkClockBasis(stage)
        stage.appendReference(samples, hostTimeSeconds: echo.timestampsTrusted ? ts : nil)
    }

    /// Cancel the echo in one mic buffer. Returns nil when this recording has no
    /// stage (the caller then takes today's path untouched); otherwise the
    /// cleaned — and, if the tap deferred it, gained — samples that are ready,
    /// which can be more or fewer than `samples.count` and empty.
    ///
    /// TODO(aec): a mid-session mic rebuild (input device change) jumps the mic
    /// timestamps and the stage re-anchors on its own. The echo PATH also changes
    /// then (different microphone, different gain), so resetting the filter on an
    /// input-device change (`resetTimeline(resetFilter: true)`) could help. Not
    /// done: `MicrophoneRecorder` posts no event for it and resetting on every
    /// configuration notice would throw away a converged filter for nothing.
    func echoProcessMic(_ samples: [Float], hostTime ts: Double?) -> [Float]? {
        guard let stage = echo.stage else { return nil }
        if let ts { echo.lastMicTimestamp = ts }
        checkClockBasis(stage)
        var ready = echo.carry
        echo.carry.removeAll(keepingCapacity: true)
        let clean = stage.processMicrophone(samples, hostTimeSeconds: echo.timestampsTrusted ? ts : nil)
        ready.append(contentsOf: applyDeferredGain(clean))
        return ready
    }

    /// Pull everything the stage still holds out of it (missing reference counts
    /// as silence), then restart its timeline. For pause and stop; the caller
    /// mixes the result and writes it. Empty when there is no stage.
    func echoFlushHeldMic() -> [Float] {
        guard let stage = echo.stage else { return [] }
        var ready = echo.carry
        echo.carry.removeAll(keepingCapacity: true)
        ready.append(contentsOf: applyDeferredGain(stage.flush()))
        stage.resetTimeline(resetFilter: false)
        return ready
    }

    /// Called by `stop()` once the held mic audio has been written: log the
    /// stage's numbers, store the one-line summary for Settings, release
    /// everything.
    func finishEchoCancellation() {
        defer { discardEchoCancellation() }
        guard let stage = echo.stage else { return }
        let s = stage.statistics
        // Numbers only — no content. `.public` so a diagnostic bundle can show how
        // a meeting went.
        aecLog.log("""
            echo cancellation finished: frames=\(s.framesProcessed, privacy: .public) \
            withReference=\(s.framesWithReference, privacy: .public) \
            heldTooLong=\(s.framesHeldTooLong, privacy: .public) \
            micReanchors=\(s.micReanchors, privacy: .public) \
            referenceReanchors=\(s.referenceReanchors, privacy: .public) \
            referenceSamplesDiscarded=\(s.referenceSamplesDiscarded, privacy: .public) \
            reductionDb=\(s.echoReductionDb ?? -1, privacy: .public) \
            delayMs=\(s.estimatedEchoDelayMs ?? -1, privacy: .public) \
            initialOffsetMs=\(s.initialMicToReferenceOffsetMs ?? 0, privacy: .public) \
            timestampsTrusted=\(self.echo.timestampsTrusted, privacy: .public) \
            micQueueOverflows=\(self.mic.timestamps.overflowCount, privacy: .public) \
            systemQueueOverflows=\(self.system.timestamps.overflowCount, privacy: .public)
            """)
        let line = EchoCancellationSummary.sessionLine(
            framesProcessed: s.framesProcessed,
            framesWithReference: s.framesWithReference,
            echoReductionDb: s.echoReductionDb,
            estimatedEchoDelayMs: s.estimatedEchoDelayMs,
            timestampsTrusted: echo.timestampsTrusted)
        EchoCancellationSettings.storeSessionSummary(line, in: echo.defaults)
    }

    // MARK: - Internals

    /// Gain AFTER the canceller. Gain that moves underneath an adaptive echo
    /// filter looks like a changing echo path, so when echo cancellation is on
    /// the tap leaves the signal alone and the controller runs here instead —
    /// on the main actor, the only caller of `process` while recording (the
    /// tap stopped calling it when `deferGainToConsumer` was set).
    private func applyDeferredGain(_ samples: [Float]) -> [Float] {
        guard echo.deferredGain, !samples.isEmpty else { return samples }
        // `MicrophoneRecorder` builds the controller in `start()`, which has
        // returned by the time the first buffer arrives. Keep our own reference:
        // its `stop()` clears `gain` before the session's final flush.
        if echo.gain == nil { echo.gain = mic.gain }
        guard let gain = echo.gain else { return samples }
        return gain.process(samples)
    }

    /// Once per recording, when both streams have produced a timestamp: check
    /// that they are on the same clock. ScreenCaptureKit stamps its buffers on
    /// the host time clock, like `AVAudioTime` — an assumption about a system
    /// framework that is verified here rather than trusted.
    ///
    /// Compares each stream's NEWEST timestamp at the moment the second stream
    /// delivers its first, i.e. "what time does each clock say it is right now".
    /// (Comparing first timestamps would flag a perfectly healthy meeting whose
    /// far end was silent for the first few seconds — ScreenCaptureKit delivers
    /// nothing until the app makes a sound.)
    ///
    /// On a mismatch the canceller keeps working in contiguous mode: held mic
    /// audio is flushed (and handed to the mixer ahead of whatever comes next),
    /// the timeline is reset, and from here on no timestamps are passed in.
    private func checkClockBasis(_ stage: EchoCancellationStage) {
        guard !echo.clockChecked,
              let micNow = echo.lastMicTimestamp,
              let referenceNow = echo.lastReferenceTimestamp else { return }
        echo.clockChecked = true
        let gap = abs(micNow - referenceNow)
        guard gap > maxClockMismatchSeconds else {
            aecLog.log("capture clocks agree: mic and app-audio timestamps are \(gap, privacy: .public)s apart")
            return
        }
        echo.timestampsTrusted = false
        echo.carry.append(contentsOf: applyDeferredGain(stage.flush()))
        stage.resetTimeline(resetFilter: false)
        aecLog.error("mic and app-audio capture clocks disagree by \(gap, privacy: .public)s (> \(maxClockMismatchSeconds, privacy: .public)s) — echo cancellation falls back to arrival-order alignment")
    }

    /// Write the raw mic, the aligned reference and the cleaned mic to
    /// `<recordings>/aec-debug/` — only when the user asked for it.
    private func attachDebugAudioIfEnabled(outputURL: URL?) {
        guard let stage = echo.stage, let outputURL,
              EchoCancellationSettings.savesDebugAudio(echo.defaults) else { return }
        do {
            let writer = try AECDebugAudioWriter(recordingURL: outputURL)
            echo.debugAudio = writer
            // Fires on the main actor with aligned chunks of 1...160 samples
            // (out == what the stage returned); `append` only hops onto the
            // writer's own queue.
            stage.frameObserver = { near, far, out in
                writer.append(near: near, far: far, out: out)
            }
            aecLog.log("echo-cancellation debug audio is being saved")
        } catch {
            // The folder is the user's recordings folder, which Cocoa quotes in
            // `localizedDescription`; domain + code say what failed.
            let ns = error as NSError
            aecLog.error("""
                could not create the echo-cancellation debug audio files \
                [\(ns.domain, privacy: .public) \(ns.code, privacy: .public)]: \
                \(error.localizedDescription, privacy: .private)
                """)
        }
    }
}
