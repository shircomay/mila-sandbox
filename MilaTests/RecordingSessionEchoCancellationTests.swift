import XCTest
import AVFoundation
import TranscriptionCore
import EchoCancellation
@testable import Mila

// FORK (echo cancellation, spec 03).
//
// Drives a fake MEETING `RecordingSession` (a real WAV, no mic / ScreenCaptureKit
// bring-up) through its real `consumeMic` / `consumeSystem` / `pause` / `stop`
// paths with synthetic audio: a speech-like far-end signal, and a microphone that
// hears only its echo (a few delayed, scaled copies). Capture timestamps are
// pushed into the recorders' queues exactly as the capture callbacks would.
//
// Every signal is generated from a seeded SplitMix64, so the runs are
// deterministic. The numbers were calibrated against the vendored SpeexDSP in a
// C harness (default filter, 30 ms lead): the cancellation measured there is
// ~40 dB in steady state, against the 10 dB these tests require.

// MARK: - Deterministic signals

private struct SplitMix64 {
    var state: UInt64
    init(seed: UInt64) { state = seed }

    mutating func next() -> UInt64 {
        state = state &+ 0x9E37_79B9_7F4A_7C15
        var z = state
        z = (z ^ (z >> 30)) &* 0xBF58_476D_1CE4_E5B9
        z = (z ^ (z >> 27)) &* 0x94D0_49BB_1331_11EB
        return z ^ (z >> 31)
    }

    /// Uniform in [0, 1).
    mutating func unit() -> Double {
        Double(next() >> 11) / 9_007_199_254_740_992.0
    }

    /// Uniform in [-1, 1).
    mutating func symmetric() -> Double {
        unit() * 2.0 - 1.0
    }
}

private enum Synthetic {
    static let sampleRate = 16_000.0

    /// Speech-like: white noise through a two-pole resonator, gated into
    /// "syllables" of 200–400 ms separated by 100–300 ms of silence, normalised
    /// to `targetRMS` over its active samples.
    static func speechLike(count: Int, seed: UInt64, targetRMS: Double = 0.12) -> [Float] {
        var envelopeRNG = SplitMix64(seed: seed)
        var noiseRNG = SplitMix64(seed: seed &+ 1)

        var envelope = [Double](repeating: 0, count: count)
        var position = 0
        var voiced = true
        while position < count {
            let length: Int
            let amplitude: Double
            if voiced {
                length = 3_200 + Int(envelopeRNG.unit() * 3_200)
                amplitude = 0.5 + 0.5 * envelopeRNG.unit()
            } else {
                length = 1_600 + Int(envelopeRNG.unit() * 3_200)
                amplitude = 0
            }
            for k in 0..<length where position + k < count {
                let ramp = min(1.0, Double(min(k, length - 1 - k)) / 160.0)
                envelope[position + k] = amplitude * ramp
            }
            position += length
            voiced.toggle()
        }

        var values = [Double](repeating: 0, count: count)
        var y1 = 0.0
        var y2 = 0.0
        var sumSquares = 0.0
        var active = 0
        for i in 0..<count {
            let y = noiseRNG.symmetric() + 1.2 * y1 - 0.5 * y2
            y2 = y1
            y1 = y
            let v = y * envelope[i]
            values[i] = v
            if envelope[i] > 0 {
                sumSquares += v * v
                active += 1
            }
        }
        let scale = targetRMS / (sumSquares / Double(max(active, 1))).squareRoot()
        return values.map { Float($0 * scale) }
    }

    /// What a laptop microphone hears of `far` played from its own speakers:
    /// a direct path at 40 ms and three weaker reflections, plus a −63 dBFS
    /// noise floor. Nobody is talking near the mic.
    static let echoTaps: [(delay: Int, gain: Double)] = [(640, 0.45), (880, 0.18), (1_440, -0.10), (2_240, 0.05)]

    static func echo(of far: [Float], noiseSeed: UInt64 = 99, noiseAmplitude: Double = 0.0005) -> [Float] {
        var rng = SplitMix64(seed: noiseSeed)
        var mic = [Float](repeating: 0, count: far.count)
        for i in 0..<far.count {
            var v = 0.0
            for tap in echoTaps where i >= tap.delay {
                v += tap.gain * Double(far[i - tap.delay])
            }
            v += rng.symmetric() * noiseAmplitude
            mic[i] = Float(v)
        }
        return mic
    }

    static func energy(_ x: [Float], _ range: Range<Int>) -> Double {
        var sum = 0.0
        for i in range { sum += Double(x[i]) * Double(x[i]) }
        return sum
    }

    /// 10·log10(Σnear² / Σout²) over `range`.
    static func reductionDb(near: [Float], out: [Float], over range: Range<Int>) -> Double {
        10 * log10(max(energy(near, range), 1e-20) / max(energy(out, range), 1e-20))
    }

    static func buffer(_ samples: ArraySlice<Float>) -> AVAudioPCMBuffer {
        let format = WhisperAudioFormat.pcmFloat32
        let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(samples.count))!
        buffer.frameLength = AVAudioFrameCount(samples.count)
        let channel = buffer.floatChannelData![0]
        for (i, value) in samples.enumerated() { channel[i] = value }
        return buffer
    }
}

// MARK: - Delivering audio the way the capture callbacks would

/// Feeds a session mic and reference chunks in capture order, pushing each
/// chunk's host timestamp into the matching recorder's queue first — the
/// producer side of `CaptureTimestampQueue`, which `consumeMic` /
/// `consumeSystem` then pop.
@MainActor
private final class Pump {
    let session: RecordingSession
    let mic: [Float]
    let reference: [Float]
    let micChunk = 1_365          // one mic tap buffer at 16 kHz (4096 frames @ 48 kHz)
    let refChunk = 320            // one ScreenCaptureKit buffer (20 ms)
    /// How far (in media time) reference delivery runs ahead of the mic chunk
    /// being delivered, in samples.
    let refAhead: Int
    let hostBase: Double
    /// Added to every mic timestamp: a mic clock on a different basis.
    let micClockOffset: Double
    /// Push real timestamps (true) or `nil` for every buffer (false).
    let sendTimestamps: Bool

    private(set) var micIndex = 0
    private(set) var refDelivered: Int

    var micChunksTotal: Int { mic.count / micChunk }

    init(session: RecordingSession, mic: [Float], reference: [Float],
         refAhead: Int = 32_000, referenceStart: Int = 0,
         hostBase: Double = 250_000, micClockOffset: Double = 0, sendTimestamps: Bool = true) {
        self.session = session
        self.mic = mic
        self.reference = reference
        self.refAhead = refAhead
        self.refDelivered = referenceStart
        self.hostBase = hostBase
        self.micClockOffset = micClockOffset
        self.sendTimestamps = sendTimestamps
    }

    /// Deliver `count` more mic chunks, each preceded by the reference up to
    /// `refAhead` samples past that chunk's end.
    func advance(micChunks count: Int) async {
        for _ in 0..<count {
            guard micIndex < micChunksTotal else { return }
            let target = min(reference.count, (micIndex + 1) * micChunk + refAhead)
            while refDelivered < target { await deliverReferenceChunk() }
            await deliverMicChunk()
        }
    }

    func deliverReferenceChunk() async {
        let end = min(reference.count, refDelivered + refChunk)
        session.system.timestamps.push(sendTimestamps ? hostBase + Double(refDelivered) / Synthetic.sampleRate : nil)
        await session.consumeSystem(Synthetic.buffer(reference[refDelivered..<end]))
        refDelivered = end
    }

    func deliverMicChunk() async {
        let start = micIndex * micChunk
        session.mic.timestamps.push(sendTimestamps
                                    ? hostBase + micClockOffset + Double(start) / Synthetic.sampleRate
                                    : nil)
        await session.consumeMic(Synthetic.buffer(mic[start..<start + micChunk]))
        micIndex += 1
    }

    /// Whatever reference is left (the meeting's tail).
    func drainReference() async {
        while refDelivered < reference.count { await deliverReferenceChunk() }
    }

    /// Everything, in ARRIVAL order: mic chunk j shows up when its last sample
    /// has been captured; reference chunk k shows up `lateness` seconds after
    /// its last sample was played. (ScreenCaptureKit delivery lags the mic in
    /// practice, which is what the canceller's hold exists for.)
    func runInArrivalOrder(referenceLateness lateness: Double) async {
        struct Event { var time: Double; var isMic: Bool }
        var events: [Event] = []
        var end = refDelivered
        while end < reference.count {
            end = min(reference.count, end + refChunk)
            events.append(Event(time: Double(end) / Synthetic.sampleRate + lateness, isMic: false))
        }
        for j in micIndex..<micChunksTotal {
            events.append(Event(time: Double((j + 1) * micChunk) / Synthetic.sampleRate, isMic: true))
        }
        events.sort { lhs, rhs in
            if lhs.time != rhs.time { return lhs.time < rhs.time }
            return !lhs.isMic && rhs.isMic
        }
        for event in events {
            if event.isMic {
                await deliverMicChunk()
            } else {
                await deliverReferenceChunk()
            }
        }
    }
}

// MARK: - Tests

@MainActor
final class RecordingSessionEchoCancellationTests: XCTestCase {

    // 160 mic chunks ≈ 13.65 s, a multiple of the canceller's 160-sample frame.
    private let micChunks = 160
    private var micCount: Int { micChunks * 1_365 }
    private let referenceTail = 48_000

    // MARK: Helpers

    private func freshDefaults(saveDebugAudio: Bool = false) -> UserDefaults {
        let suite = "RecordingSessionEchoCancellationTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defaults.removePersistentDomain(forName: suite)
        // Explicit values for both keys: a suite is never assumed to read the
        // code defaults (or anyone's personal defaults).
        defaults.set(false, forKey: EchoCancellationSettings.Keys.enabled)
        defaults.set(saveDebugAudio, forKey: EchoCancellationSettings.Keys.saveDebugAudio)
        addTeardownBlock { defaults.removePersistentDomain(forName: suite) }
        return defaults
    }

    private func makeStage() throws -> EchoCancellationStage {
        try XCTUnwrap(EchoCancellationStage(), "the echo canceller should be creatable")
    }

    private func tempWAV(_ label: String) -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("aec-\(label)-\(UUID().uuidString).wav")
        addTeardownBlock {
            try? FileManager.default.removeItem(at: url)
            let base = url.deletingPathExtension().lastPathComponent
            for role in ["mic", "ref", "clean"] {
                try? FileManager.default.removeItem(
                    at: AECDebugAudioWriter.directory(for: url).appendingPathComponent("\(base).aec-\(role).wav"))
            }
        }
        return url
    }

    /// A fake MEETING session writing a real WAV, with `stage` installed through
    /// the test seam (nil = the upstream path, no stage).
    private func makeSession(stage: EchoCancellationStage?,
                             deferGain: Bool = true,
                             gain: AdaptiveGainController? = nil,
                             defaults: UserDefaults? = nil,
                             label: String = "session") async throws -> (session: RecordingSession, url: URL) {
        let url = tempWAV(label)
        let session = RecordingSession()
        try await session.startFakeMeetingForTesting(outputURL: url)
        session.installEchoStageForTesting(stage, deferGain: deferGain, gain: gain,
                                           defaults: defaults ?? freshDefaults())
        return (session, url)
    }

    private func samples(of url: URL) throws -> [Float] {
        try AudioConvert.loadAsWhisperSamples(url: url)
    }

    /// `AVAudioFile` may not hand back the last partial 1024-frame block of a WAV
    /// it wrote (see the note in `AudioConvertTests`), so a read-back is the
    /// written audio minus at most 1023 trailing frames — never more, never extra.
    private func assertReadBackCount(_ readBack: Int, wrote expected: Int, _ message: String = "",
                                     file: StaticString = #filePath, line: UInt = #line) {
        XCTAssertLessThanOrEqual(readBack, expected, "read back more than was written. \(message)", file: file, line: line)
        XCTAssertGreaterThan(readBack, expected - 1024, "lost more than AVAudioFile's last partial block. \(message)",
                             file: file, line: line)
    }

    /// `readBack` is `expected` up to AVAudioFile's trailing partial block, sample for sample.
    private func assertReadBack(_ readBack: [Float], equals expected: [Float], _ message: String = "",
                                file: StaticString = #filePath, line: UInt = #line) {
        assertReadBackCount(readBack.count, wrote: expected.count, message, file: file, line: line)
        let n = min(readBack.count, expected.count)
        XCTAssertEqual(Array(readBack[0..<n]), Array(expected[0..<n]), message, file: file, line: line)
    }

    private func debugAudio(for url: URL) throws -> (mic: [Float], ref: [Float], clean: [Float]) {
        let directory = AECDebugAudioWriter.directory(for: url)
        let base = url.deletingPathExtension().lastPathComponent
        func load(_ role: String) throws -> [Float] {
            try samples(of: directory.appendingPathComponent("\(base).aec-\(role).wav"))
        }
        return (try load("mic"), try load("ref"), try load("clean"))
    }

    /// Raw-mic vs cleaned-mic energy over the last 5 s of the recording, from the
    /// debug audio dump (which, unlike the mix, does not depend on how the mixer
    /// happened to pair the two legs).
    private func steadyStateReduction(_ dump: (mic: [Float], ref: [Float], clean: [Float])) -> Double {
        // Up to 1023 trailing frames may be missing from a read-back (see `assertReadBackCount`).
        let end = min(dump.mic.count, dump.clean.count, micCount)
        guard end > micCount - 1_024 else {
            XCTFail("debug audio is shorter than the recording: \(dump.mic.count) / \(dump.clean.count) < \(micCount)")
            return -.infinity
        }
        return Synthetic.reductionDb(near: dump.mic, out: dump.clean, over: (end - 80_000)..<end)
    }

    /// The part of the mix that came from the microphone: the mixer averages
    /// (mic + app) wherever both are buffered, so given the app audio that was
    /// paired with it, `2·file − app` is the mic path alone.
    private func micPath(ofMix file: [Float], app: [Float], count: Int) -> [Float] {
        (0..<count).map { 2 * file[$0] - app[$0] }
    }

    // MARK: - Echo is actually removed from the saved mix

    /// The headline: the same meeting through the same session code, once
    /// without the stage (today's behaviour) and once with it. The mic path of
    /// the saved WAV must carry at least 10 dB less echo energy with the stage.
    ///
    /// The app audio is delivered well ahead of the mic (2 s) so the mixer pairs
    /// mic sample i with app sample i exactly — which lets the test subtract the
    /// app audio back out of the WAV and look at the mic path alone. It also
    /// means arrival order cannot align the two streams; only the capture
    /// timestamps do.
    func test_the_saved_mix_has_far_less_echo_with_the_stage_than_without() async throws {
        let reference = Synthetic.speechLike(count: micCount + referenceTail, seed: 7)
        let mic = Array(Synthetic.echo(of: reference).prefix(micCount))

        // Baseline: no stage — exactly the upstream path.
        let baseline = try await makeSession(stage: nil, label: "baseline")
        let baselinePump = Pump(session: baseline.session, mic: mic, reference: reference)
        await baselinePump.advance(micChunks: micChunks)
        await baselinePump.drainReference()
        _ = await baseline.session.stop()
        let baselineMix = try samples(of: baseline.url)

        // With the stage.
        let stage = try makeStage()
        let withStage = try await makeSession(stage: stage, label: "with-stage")
        let pump = Pump(session: withStage.session, mic: mic, reference: reference)
        await pump.advance(micChunks: micChunks)
        await pump.drainReference()
        XCTAssertTrue(withStage.session.echo.timestampsTrusted, "consistent clocks must stay trusted")
        _ = await withStage.session.stop()
        let cleanedMix = try samples(of: withStage.url)

        // Nothing lost, nothing added: mic samples + the app-audio tail, as upstream.
        assertReadBackCount(baselineMix.count, wrote: reference.count)
        XCTAssertEqual(cleanedMix.count, baselineMix.count,
                       "the stage must not change how much audio is written")

        // The extraction is exact when the stage is absent (mic path == raw mic)...
        let baselineMic = micPath(ofMix: baselineMix, app: reference, count: micCount)
        var worstDifference: Float = 0
        for i in 0..<micCount { worstDifference = max(worstDifference, abs(baselineMic[i] - mic[i])) }
        XCTAssertLessThan(worstDifference, 1e-4, "test harness: the mic path should be recoverable from the mix")

        // ...so the same arithmetic on the stage run is the cleaned mic.
        let cleanedMic = micPath(ofMix: cleanedMix, app: reference, count: micCount)
        let steadyState = (micCount - 80_000)..<micCount        // last 5 s, after convergence
        let reduction = Synthetic.reductionDb(near: mic, out: cleanedMic, over: steadyState)
        let baselineReduction = Synthetic.reductionDb(near: mic, out: baselineMic, over: steadyState)
        XCTAssertEqual(baselineReduction, 0, accuracy: 0.1, "without the stage nothing is removed")
        XCTAssertGreaterThanOrEqual(reduction, 10,
                                    "echo energy in the saved mic path should drop by >= 10 dB (got \(reduction) dB)")
        XCTAssertGreaterThan(stage.statistics.framesProcessed, 0)
    }

    // MARK: - Timestamps are what align the streams

    /// ScreenCaptureKit delivers nothing while the app is silent, so the
    /// reference stream can start seconds after the mic. Arrival order cannot
    /// recover that gap; the capture timestamps can.
    func test_a_late_starting_reference_is_aligned_by_timestamps_and_not_by_arrival_order() async throws {
        let silentStart = 32_000                                         // 2 s of nothing from the app
        var reference = Synthetic.speechLike(count: micCount + referenceTail, seed: 11)
        for i in 0..<silentStart { reference[i] = 0 }
        let mic = Array(Synthetic.echo(of: reference).prefix(micCount))

        func reduction(sendTimestamps: Bool, label: String) async throws -> Double {
            let run = try await makeSession(stage: try makeStage(),
                                            defaults: freshDefaults(saveDebugAudio: true),
                                            label: label)
            let pump = Pump(session: run.session, mic: mic, reference: reference,
                            refAhead: 0, referenceStart: silentStart, sendTimestamps: sendTimestamps)
            await pump.advance(micChunks: micChunks)
            await pump.drainReference()
            _ = await run.session.stop()
            let dump = try debugAudio(for: run.url)
            XCTAssertEqual(dump.mic.count, dump.clean.count)
            return steadyStateReduction(dump)
        }

        let withTimestamps = try await reduction(sendTimestamps: true, label: "late-ref-ts")
        let withoutTimestamps = try await reduction(sendTimestamps: false, label: "late-ref-nots")
        XCTAssertGreaterThanOrEqual(withTimestamps, 10,
                                    "with timestamps the gap is understood (got \(withTimestamps) dB)")
        XCTAssertLessThan(withoutTimestamps, 6,
                          "without timestamps the 2 s gap misaligns the streams — this is the case the feature exists for (got \(withoutTimestamps) dB)")
    }

    /// The reference arriving AFTER the mic chunk that covers the same moment
    /// (the usual order: the SCK callback lags the mic tap). The canceller holds
    /// mic frames until the reference shows up; the session must cope with
    /// `echoProcessMic` returning nothing for a while and then a burst.
    func test_a_reference_that_arrives_after_the_mic_is_still_cancelled() async throws {
        let reference = Synthetic.speechLike(count: micCount + referenceTail, seed: 7)
        let mic = Array(Synthetic.echo(of: reference).prefix(micCount))
        let stage = try makeStage()
        let run = try await makeSession(stage: stage,
                                        defaults: freshDefaults(saveDebugAudio: true),
                                        label: "late-reference")
        let pump = Pump(session: run.session, mic: mic, reference: reference, refAhead: 0)
        await pump.runInArrivalOrder(referenceLateness: 0.060)
        _ = await run.session.stop()

        let dump = try debugAudio(for: run.url)
        let reduction = steadyStateReduction(dump)
        XCTAssertGreaterThanOrEqual(reduction, 10, "got \(reduction) dB")
        // Every mic frame is processed exactly once. The Speex preprocessor delays its output by one
        // frame, so the final flush feeds the stage one extra silence frame to drain it.
        XCTAssertGreaterThanOrEqual(stage.statistics.framesProcessed, micCount / 160)
        XCTAssertLessThanOrEqual(stage.statistics.framesProcessed, micCount / 160 + 1)
        let mix = try samples(of: run.url)
        XCTAssertGreaterThanOrEqual(mix.count, micCount, "no mic audio may be lost")
    }

    // MARK: - Capture clocks

    /// Mic and app-audio timestamps on bases further apart than 5 s mean the SCK
    /// clock assumption does not hold: the session stops passing timestamps in,
    /// keeps every mic sample, and says so.
    func test_a_clock_basis_mismatch_switches_to_arrival_order_without_losing_audio() async throws {
        let stage = try makeStage()
        let defaults = freshDefaults()
        let run = try await makeSession(stage: stage, defaults: defaults, label: "clock-mismatch")
        let mic = Synthetic.speechLike(count: 40 * 1_365, seed: 3, targetRMS: 0.05)
        let silence = [Float](repeating: 0, count: 320)
        let pump = Pump(session: run.session, mic: mic, reference: [], micClockOffset: 0)

        await pump.deliverMicChunk()                                       // the mic always starts first
        XCTAssertTrue(run.session.echo.timestampsTrusted)
        XCTAssertFalse(run.session.echo.clockChecked, "nothing to compare against yet")

        // The app audio's first buffer, stamped on a clock 1000 s away.
        run.session.system.timestamps.push(249_000.0)
        await run.session.consumeSystem(Synthetic.buffer(silence[...]))
        XCTAssertTrue(run.session.echo.clockChecked)
        XCTAssertFalse(run.session.echo.timestampsTrusted, "a 1000 s gap is not the same clock")

        await pump.advance(micChunks: 39)
        _ = await run.session.stop()

        // The 320 app samples are mixed into the first 320 mic samples (their
        // average with silence); everything else is the mic at full scale.
        // All 40 chunks of mic audio must have been written, none twice.
        let written = try samples(of: run.url)
        assertReadBackCount(written.count, wrote: 40 * 1_365)
        XCTAssertEqual(defaults.string(forKey: EchoCancellationSettings.Keys.lastSessionSummary)?
            .contains("clocks disagreed"), true,
                       "the Settings summary should say the clocks disagreed")
    }

    func test_clocks_that_agree_stay_trusted() async throws {
        let stage = try makeStage()
        let run = try await makeSession(stage: stage, label: "clock-agree")
        let mic = Synthetic.speechLike(count: 10 * 1_365, seed: 3, targetRMS: 0.05)
        let pump = Pump(session: run.session, mic: mic, reference: [])
        await pump.deliverMicChunk()
        run.session.system.timestamps.push(250_000.010)                    // 10 ms off: ordinary jitter
        await run.session.consumeSystem(Synthetic.buffer([Float](repeating: 0, count: 320)[...]))
        XCTAssertTrue(run.session.echo.clockChecked)
        XCTAssertTrue(run.session.echo.timestampsTrusted)
        await run.session.cancelAll()
    }

    /// ScreenCaptureKit sends nothing until the app makes a sound, so on a
    /// healthy meeting the first app-audio timestamp can be far later than the
    /// first mic timestamp. That is NOT a clock mismatch: the check compares
    /// what each clock says "now", not where each stream began.
    func test_a_far_end_that_stays_silent_for_a_while_is_not_mistaken_for_a_clock_mismatch() async throws {
        let stage = try makeStage()
        let run = try await makeSession(stage: stage, label: "silent-start")
        let chunks = 300                                                    // ≈ 25 s of mic audio
        let mic = Synthetic.speechLike(count: chunks * 1_365, seed: 5, targetRMS: 0.05)
        let pump = Pump(session: run.session, mic: mic, reference: [])
        await pump.advance(micChunks: chunks - 1)

        // 25 s in, the app finally plays something — stamped on the SAME clock.
        let now = 250_000 + Double((chunks - 1) * 1_365) / 16_000
        run.session.system.timestamps.push(now)
        await run.session.consumeSystem(Synthetic.buffer([Float](repeating: 0.01, count: 320)[...]))
        XCTAssertTrue(run.session.echo.clockChecked)
        XCTAssertTrue(run.session.echo.timestampsTrusted,
                      "a late first reference on a consistent clock must not trip the 5 s check")
        await run.session.cancelAll()
    }

    // MARK: - Pause, resume, stop: no audio held back, no timestamp left behind

    /// The canceller holds the last ~150 ms of mic audio waiting for reference.
    /// A pause must write it (it is audio from before the pause), and the final
    /// stop must write what is held then. Mic-only here (no reference at all),
    /// so every mic sample must come out exactly once.
    func test_pause_resume_and_stop_write_every_held_sample() async throws {
        let stage = try makeStage()
        let run = try await makeSession(stage: stage, label: "pause-flush")
        final class Counter { var samples = 0 }
        let live = Counter()
        run.session.onLiveSamples = { live.samples += $0.count }

        let mic = Synthetic.speechLike(count: 100 * 1_365, seed: 21, targetRMS: 0.05)
        let pump = Pump(session: run.session, mic: mic, reference: [])

        await pump.advance(micChunks: 40)
        XCTAssertLessThan(live.samples, 40 * 1_365, "the canceller is holding some audio back")
        await run.session.pause()
        XCTAssertEqual(live.samples, 40 * 1_365,
                       "pause() must flush what the canceller was holding")

        // Paused: buffers are dropped, but their timestamps are still consumed.
        await pump.advance(micChunks: 20)
        XCTAssertEqual(live.samples, 40 * 1_365, "nothing is written while paused")
        XCTAssertEqual(run.session.mic.timestamps.pendingCount, 0,
                       "a dropped buffer must still pop its timestamp or the queue slides out of step")

        run.session.resume()
        await pump.advance(micChunks: 40)
        _ = await run.session.stop()

        XCTAssertEqual(live.samples, 80 * 1_365)
        assertReadBackCount(try samples(of: run.url).count, wrote: 80 * 1_365,
                            "every mic sample outside the pause is in the WAV")
    }

    func test_system_timestamps_are_consumed_while_paused_too() async throws {
        let run = try await makeSession(stage: try makeStage(), label: "paused-system")
        await run.session.pause()
        for i in 0..<5 {
            run.session.system.timestamps.push(250_000 + Double(i) * 0.02)
            await run.session.consumeSystem(Synthetic.buffer([Float](repeating: 0, count: 320)[...]))
        }
        XCTAssertEqual(run.session.system.timestamps.pendingCount, 0)
        run.session.resume()
        _ = await run.session.stop()
    }

    // MARK: - Gain goes after the canceller

    /// With echo cancellation on, the tap leaves the mic alone and the session
    /// applies the gain controller to the cleaned samples — once, and only when
    /// the tap deferred it. A controller pinned to ×4 makes that exact: the
    /// mic path of the mix must be four times the same run without gain.
    func test_deferred_gain_is_applied_once_to_the_cleaned_samples() async throws {
        let mic = Synthetic.speechLike(count: 64 * 1_365, seed: 31, targetRMS: 0.02)   // peaks stay far below clipping at ×4

        func run(deferGain: Bool, gain: AdaptiveGainController?, label: String) async throws -> [Float] {
            let result = try await makeSession(stage: try makeStage(), deferGain: deferGain, gain: gain, label: label)
            let pump = Pump(session: result.session, mic: mic, reference: [])
            await pump.advance(micChunks: 64)
            _ = await result.session.stop()
            return try samples(of: result.url)
        }
        func fixedGainFour() -> AdaptiveGainController {
            // Min == max pins the gain at ×4; a zero floor multiplier lets any
            // non-silent frame adapt immediately.
            AdaptiveGainController(maxGain: 4, minGain: 4, noiseFloorMultiplier: 0)
        }

        let plain = try await run(deferGain: true, gain: nil, label: "gain-none")
        let deferred = try await run(deferGain: true, gain: fixedGainFour(), label: "gain-deferred")
        let alreadyInTap = try await run(deferGain: false, gain: fixedGainFour(), label: "gain-in-tap")

        assertReadBackCount(plain.count, wrote: 64 * 1_365)
        XCTAssertEqual(deferred.count, plain.count)
        XCTAssertEqual(alreadyInTap.count, plain.count)

        var worstDeferred: Float = 0
        var worstTap: Float = 0
        for i in 0..<plain.count {
            worstDeferred = max(worstDeferred, abs(deferred[i] - 4 * plain[i]))
            worstTap = max(worstTap, abs(alreadyInTap[i] - plain[i]))
        }
        XCTAssertLessThan(worstDeferred, 1e-5, "deferred gain: the cleaned mic must be scaled by the controller exactly once")
        XCTAssertEqual(worstTap, 0, accuracy: 1e-7,
                       "when the tap already applied gain (deferGain false) the session must not apply it again")
    }

    // MARK: - Lifecycle and the upstream path

    /// A meeting WITHOUT a stage — the setting off, or any other source — must be
    /// the unchanged upstream path, queues untouched.
    func test_without_a_stage_the_recorders_and_the_mix_are_untouched() async throws {
        let run = try await makeSession(stage: nil, label: "no-stage")
        XCTAssertNil(run.session.echo.stage)
        XCTAssertFalse(run.session.mic.timestamps.isEnabled)
        XCTAssertFalse(run.session.system.timestamps.isEnabled)
        XCTAssertFalse(run.session.mic.deferGainToConsumer)

        let mic = [Float](repeating: 0.2, count: 1_365)
        let app = [Float](repeating: 0.1, count: 1_365)
        run.session.mic.timestamps.push(1)                                 // disabled: a no-op
        run.session.system.timestamps.push(1)
        await run.session.consumeSystem(Synthetic.buffer(app[...]))
        await run.session.consumeMic(Synthetic.buffer(mic[...]))
        XCTAssertEqual(run.session.mic.timestamps.pendingCount, 0)
        XCTAssertEqual(run.session.system.timestamps.pendingCount, 0)
        _ = await run.session.stop()

        let written = try samples(of: run.url)
        XCTAssertEqual(written.count, 1_365)
        XCTAssertEqual(written[0], (0.2 + 0.1) * 0.5, accuracy: 1e-6, "mic and app averaged, as upstream")
    }

    /// `startFakeForTesting` — what every upstream test drives — never creates a stage.
    func test_the_upstream_fake_session_never_has_a_stage() async {
        let session = RecordingSession()
        let url = tempWAV("upstream-fake")
        await session.startFakeForTesting(outputURL: url)
        XCTAssertNil(session.echo.stage)
        XCTAssertFalse(session.mic.timestamps.isEnabled)
        XCTAssertFalse(session.system.timestamps.isEnabled)
        XCTAssertFalse(session.mic.deferGainToConsumer)
        await session.pause()
        session.resume()
        _ = await session.stop()
        XCTAssertNil(session.echo.stage)
    }

    func test_stop_stores_the_summary_and_releases_everything() async throws {
        let stage = try makeStage()
        let defaults = freshDefaults()
        let run = try await makeSession(stage: stage, defaults: defaults, label: "summary")
        XCTAssertTrue(run.session.mic.timestamps.isEnabled)
        XCTAssertTrue(run.session.system.timestamps.isEnabled)
        XCTAssertTrue(run.session.mic.deferGainToConsumer)
        XCTAssertNil(EchoCancellationSettings.storedSessionSummary(defaults), "no summary before the meeting ends")

        let mic = Synthetic.speechLike(count: 20 * 1_365, seed: 9, targetRMS: 0.05)
        let pump = Pump(session: run.session, mic: mic, reference: [])
        await pump.advance(micChunks: 20)
        _ = await run.session.stop()

        let summary = try XCTUnwrap(EchoCancellationSettings.storedSessionSummary(defaults))
        XCTAssertTrue(summary.hasPrefix("echo reduc"), summary)
        XCTAssertTrue(summary.contains("reference present"), summary)
        XCTAssertNil(run.session.echo.stage)
        XCTAssertFalse(run.session.mic.timestamps.isEnabled)
        XCTAssertFalse(run.session.system.timestamps.isEnabled)
        XCTAssertFalse(run.session.mic.deferGainToConsumer)
    }

    func test_cancelAll_drops_the_stage_without_writing_a_summary() async throws {
        let defaults = freshDefaults()
        let run = try await makeSession(stage: try makeStage(), defaults: defaults, label: "cancel")
        let mic = Synthetic.speechLike(count: 5 * 1_365, seed: 9, targetRMS: 0.05)
        let pump = Pump(session: run.session, mic: mic, reference: [])
        await pump.advance(micChunks: 5)

        await run.session.cancelAll()
        XCTAssertNil(run.session.echo.stage)
        XCTAssertFalse(run.session.mic.timestamps.isEnabled)
        XCTAssertFalse(run.session.system.timestamps.isEnabled)
        XCTAssertFalse(run.session.mic.deferGainToConsumer)
        XCTAssertNil(EchoCancellationSettings.storedSessionSummary(defaults))
    }

    /// `start()` decides from the settings: a meeting with the setting on gets a
    /// stage, deferred gain and armed queues; anything else gets none of it.
    func test_begin_creates_a_stage_only_for_a_meeting_with_the_setting_on() throws {
        let on = freshDefaults()
        on.set(true, forKey: EchoCancellationSettings.Keys.enabled)
        let off = freshDefaults()                   // freshDefaults() sets `enabled = false` explicitly
        let url = tempWAV("begin")

        let meetingOn = RecordingSession()
        meetingOn.echo.defaults = on
        meetingOn.beginEchoCancellation(source: .meeting, outputURL: url)
        XCTAssertNotNil(meetingOn.echo.stage)
        XCTAssertTrue(meetingOn.mic.timestamps.isEnabled)
        XCTAssertTrue(meetingOn.system.timestamps.isEnabled)
        XCTAssertTrue(meetingOn.mic.deferGainToConsumer)
        XCTAssertTrue(meetingOn.echo.deferredGain)
        meetingOn.discardEchoCancellation()
        XCTAssertNil(meetingOn.echo.stage)
        XCTAssertFalse(meetingOn.mic.deferGainToConsumer)

        let meetingOff = RecordingSession()
        meetingOff.echo.defaults = off
        meetingOff.beginEchoCancellation(source: .meeting, outputURL: url)
        XCTAssertNil(meetingOff.echo.stage, "setting off: today's behaviour")
        XCTAssertFalse(meetingOff.mic.timestamps.isEnabled)
        XCTAssertFalse(meetingOff.mic.deferGainToConsumer)

        for source in [RecordingSource.microphone, .systemAudio] {
            let other = RecordingSession()
            other.echo.defaults = on
            other.beginEchoCancellation(source: source, outputURL: url)
            XCTAssertNil(other.echo.stage, "\(source.rawValue) recordings have no reference to cancel against")
            XCTAssertFalse(other.mic.timestamps.isEnabled)
            XCTAssertFalse(other.system.timestamps.isEnabled)
            XCTAssertFalse(other.mic.deferGainToConsumer)
        }
    }

    // MARK: - Debug audio

    /// The three files are parallel, the raw mic is what went in, and the clean
    /// file is what the mixer wrote (mic-only: no app audio). The debug "clean"
    /// file is the canceller's output BEFORE gain, so gain must be identity here:
    /// `deferGain: false` models a tap that already applied it, and the session
    /// has no controller of its own to apply.
    func test_debug_audio_files_capture_the_raw_aligned_and_cleaned_streams() async throws {
        let chunks = 64                                                       // 87 360 samples = 546 whole frames
        let mic = Synthetic.speechLike(count: chunks * 1_365, seed: 41, targetRMS: 0.05)
        let run = try await makeSession(stage: try makeStage(),
                                        deferGain: false,
                                        defaults: freshDefaults(saveDebugAudio: true),
                                        label: "debug-audio")
        let pump = Pump(session: run.session, mic: mic, reference: [])
        await pump.advance(micChunks: chunks)
        _ = await run.session.stop()

        let dump = try debugAudio(for: run.url)
        let written = try samples(of: run.url)
        assertReadBackCount(dump.mic.count, wrote: chunks * 1_365)
        XCTAssertEqual(dump.ref.count, dump.mic.count)
        XCTAssertEqual(dump.clean.count, dump.mic.count)
        XCTAssertEqual(written.count, dump.mic.count)
        // Every sample, not a sample of them: a shift anywhere must fail.
        var worstMic: Float = 0, worstRef: Float = 0, worstClean: Float = 0
        for i in 0..<min(dump.mic.count, dump.ref.count, dump.clean.count, written.count, mic.count) {
            worstMic = max(worstMic, abs(dump.mic[i] - mic[i]))
            worstRef = max(worstRef, abs(dump.ref[i]))
            worstClean = max(worstClean, abs(dump.clean[i] - written[i]))
        }
        XCTAssertLessThan(worstMic, 1e-4, "raw mic is what went in, sample for sample")
        XCTAssertLessThan(worstRef, 1e-7, "no reference was delivered")
        XCTAssertLessThan(worstClean, 1e-6, "cleaned mic is what the mixer wrote, sample for sample")
    }

    /// A pause flushes the stage and restarts its timeline. The dump must stay
    /// parallel and complete across it: exactly the audio that was recorded
    /// (nothing from the paused span), with the clean file equal to the recording.
    func test_debug_audio_stays_aligned_and_complete_across_a_pause() async throws {
        let mic = Synthetic.speechLike(count: 100 * 1_365, seed: 43, targetRMS: 0.05)
        let run = try await makeSession(stage: try makeStage(),
                                        deferGain: false,
                                        defaults: freshDefaults(saveDebugAudio: true),
                                        label: "debug-pause")
        let pump = Pump(session: run.session, mic: mic, reference: [])
        await pump.advance(micChunks: 40)
        await run.session.pause()
        await pump.advance(micChunks: 20)                                    // dropped while paused
        run.session.resume()
        await pump.advance(micChunks: 40)
        _ = await run.session.stop()

        let recorded = Array(mic[0..<(40 * 1_365)]) + Array(mic[(60 * 1_365)..<(100 * 1_365)])
        let dump = try debugAudio(for: run.url)
        let written = try samples(of: run.url)
        assertReadBackCount(written.count, wrote: recorded.count)
        XCTAssertEqual(dump.mic.count, written.count)
        XCTAssertEqual(dump.ref.count, written.count)
        XCTAssertEqual(dump.clean.count, written.count)
        var worstMic: Float = 0, worstClean: Float = 0
        for i in 0..<min(dump.mic.count, dump.clean.count, written.count, recorded.count) {
            worstMic = max(worstMic, abs(dump.mic[i] - recorded[i]))
            worstClean = max(worstClean, abs(dump.clean[i] - written[i]))
        }
        XCTAssertLessThan(worstMic, 1e-4, "raw mic is the audio outside the pause, in order")
        XCTAssertLessThan(worstClean, 1e-6, "cleaned mic is the recording, across the pause")
    }

    func test_debug_audio_is_off_unless_asked_for() async throws {
        let mic = Synthetic.speechLike(count: 8 * 1_365, seed: 41, targetRMS: 0.05)
        let run = try await makeSession(stage: try makeStage(), defaults: freshDefaults(), label: "debug-off")
        let pump = Pump(session: run.session, mic: mic, reference: [])
        await pump.advance(micChunks: 8)
        _ = await run.session.stop()
        let base = run.url.deletingPathExtension().lastPathComponent
        let micDump = AECDebugAudioWriter.directory(for: run.url).appendingPathComponent("\(base).aec-mic.wav")
        XCTAssertFalse(FileManager.default.fileExists(atPath: micDump.path))
        XCTAssertNil(run.session.echo.debugAudio)
    }

    /// The writer on its own: batches across its internal flush threshold and
    /// closes cleanly.
    func test_debug_writer_round_trips_frames_across_its_batch_boundary() throws {
        let url = tempWAV("writer")
        let writer = try AECDebugAudioWriter(recordingURL: url)
        var near: [Float] = [], far: [Float] = [], out: [Float] = []
        for frame in 0..<260 {                                               // 41 600 samples: > 2 batches
            let n = (0..<160).map { Float(frame * 160 + $0) / 100_000 }
            writer.append(near: n, far: n.map { -$0 }, out: n.map { 2 * $0 })
            near += n
            far += n.map { -$0 }
            out += n.map { 2 * $0 }
        }
        writer.close()
        writer.close()                                                        // idempotent

        let dump = try debugAudio(for: url)
        assertReadBack(dump.mic, equals: near)
        assertReadBack(dump.ref, equals: far)
        assertReadBack(dump.clean, equals: out)
    }

    /// The canceller's observer delivers chunks of 1...160 samples, not whole
    /// frames: the writer must keep the three files parallel whatever the sizes.
    func test_debug_writer_round_trips_chunks_of_any_length() throws {
        let url = tempWAV("writer-variable")
        let writer = try AECDebugAudioWriter(recordingURL: url)
        let sizes = [1, 160, 37, 159, 160, 2, 100]
        var near: [Float] = [], far: [Float] = [], out: [Float] = []
        var next = 0
        var k = 0
        while near.count < 50_000 {                                           // > 3 batches
            var n: [Float] = []
            for _ in 0..<sizes[k % sizes.count] {
                n.append(Float(next % 90_000) / 100_000)
                next += 1
            }
            k += 1
            writer.append(near: n, far: n.map { -$0 }, out: n.map { 2 * $0 })
            near += n
            far += n.map { -$0 }
            out += n.map { 2 * $0 }
        }
        writer.close()

        let dump = try debugAudio(for: url)
        assertReadBack(dump.mic, equals: near)
        assertReadBack(dump.ref, equals: far)
        assertReadBack(dump.clean, equals: out)
    }
}
