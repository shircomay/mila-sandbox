import Foundation
import XCTest
import EchoCancellation

/// Stage-level tests: timestamps on, realistic chunking (mic chunks of 1365
/// samples every 85.3 ms, reference chunks of 320 samples every 20 ms), on the
/// shared 24 s scenario.
///
/// Thresholds come from Tools/linux-harness/calibrate_tests.py, which runs these
/// scenarios through a Python model of the stage on the real Speex backend (the
/// measured value is quoted next to each threshold). The stage's ERLE is about
/// 21 dB; thresholds sit ~9 dB below it for a different CPU and compiler.
final class EchoCancellationStageTests: XCTestCase {
    private let scenario = EchoScenario.shared
    private let sr = SyntheticEcho.sampleRate

    // MARK: helpers

    private func makeStage(_ configure: ((inout EchoCancellationStage.Configuration) -> Void)? = nil) throws -> EchoCancellationStage {
        var configuration = EchoCancellationStage.Configuration()
        configure?(&configuration)
        return try XCTUnwrap(EchoCancellationStage(configuration: configuration))
    }

    private func erle(mic: [Float], out: [Float], mask: [Bool], from: Double, to: Double) -> Double {
        return Metrics.erle(mic: mic, out: out, farMask: mask, fromSeconds: from, toSeconds: to)
    }

    /// Mixes two equal-length signals.
    private func sum(_ a: [Float], _ b: [Float]) -> [Float] {
        var result = [Float](repeating: 0, count: a.count)
        for i in 0..<a.count { result[i] = a[i] + b[i] }
        return result
    }

    // MARK: baseline

    func test_realisticChunkingWithTimestamps_cancelsTheEcho() throws {
        let stage = try makeStage()
        let mic = scenario.micFarOnly
        let out = StageFeeder.feed(stage: stage, mic: mic, reference: scenario.far)

        XCTAssertEqual(out.count, mic.count, "total output length == total input length")
        let erle = self.erle(mic: mic, out: out, mask: scenario.farMask, from: 12, to: 24)
        print("EchoCancellationStage ERLE 12-24 s: \(erle) dB; statistics: \(stage.statistics)")
        XCTAssertGreaterThanOrEqual(erle, 12)   // measured 21.3

        let s = stage.statistics
        let frames = mic.count / 160
        XCTAssertGreaterThanOrEqual(s.framesProcessed, frames)
        XCTAssertLessThanOrEqual(s.framesProcessed, frames + 2)   // + the frame that drains the backend's latency
        XCTAssertGreaterThan(s.framesWithReference, s.framesProcessed / 4)   // measured 62 %
        XCTAssertEqual(s.micReanchors, 0)
        XCTAssertEqual(s.referenceReanchors, 0)
        XCTAssertEqual(s.referenceSamplesDiscarded, 0)
        XCTAssertEqual(try XCTUnwrap(s.initialMicToReferenceOffsetMs), 0, accuracy: 1)
        // The delay is reported on the backend's lead-shifted reference: 40 ms + 30 ms lead.
        XCTAssertEqual(try XCTUnwrap(s.estimatedEchoDelayMs), 70, accuracy: 10)
        XCTAssertGreaterThanOrEqual(try XCTUnwrap(s.echoReductionDb), 10)   // measured 18.4
    }

    func test_silentReferenceChunksNeverDelivered_likeScreenCaptureKit() throws {
        let stage = try makeStage()
        var options = FeedOptions()
        options.skipSilentReference = true
        let out = StageFeeder.feed(stage: stage, mic: scenario.micFarOnly, reference: scenario.far, options: options)

        XCTAssertEqual(out.count, scenario.micFarOnly.count)
        let erle = self.erle(mic: scenario.micFarOnly, out: out, mask: scenario.farMask, from: 12, to: 24)
        XCTAssertGreaterThanOrEqual(erle, 12)   // measured 21.3 (same as with the silent chunks delivered)
        // The skipped spans make the reference timestamps jump: re-anchors, not trouble.
        XCTAssertGreaterThanOrEqual(stage.statistics.referenceReanchors, 1)
        XCTAssertGreaterThan(stage.statistics.framesHeldTooLong, 0)
    }

    // MARK: late reference

    func test_referenceArrivingSixtyMillisecondsLate_isWaitedFor() throws {
        let stage = try makeStage()
        var options = FeedOptions()
        options.refLateMs = 60
        let out = StageFeeder.feed(stage: stage, mic: scenario.micFarOnly, reference: scenario.far, options: options)

        XCTAssertEqual(out.count, scenario.micFarOnly.count)
        let erle = self.erle(mic: scenario.micFarOnly, out: out, mask: scenario.farMask, from: 12, to: 24)
        print("EchoCancellationStage reference 60 ms late: ERLE \(erle) dB")
        XCTAssertGreaterThanOrEqual(erle, 12)   // measured 21.3, identical to on-time delivery
        XCTAssertEqual(stage.statistics.referenceSamplesDiscarded, 0, "nothing arrived too late: the hold covers 60 ms")
    }

    func test_referenceFarLaterThanTheHold_degradesGracefully() throws {
        // 300 ms late > holdMs (150): mic frames are processed without their reference
        // and the late reference is counted as discarded. No crash, nothing lost.
        let stage = try makeStage()
        var options = FeedOptions()
        options.refLateMs = 300
        let out = StageFeeder.feed(stage: stage, mic: scenario.micFarOnly, reference: scenario.far, options: options)
        XCTAssertEqual(out.count, scenario.micFarOnly.count)
        XCTAssertGreaterThan(stage.statistics.framesHeldTooLong, 0)
        XCTAssertGreaterThan(stage.statistics.referenceSamplesDiscarded, 0)
    }

    // MARK: reference gaps

    func test_referenceGaps_recoverQuickly() throws {
        // The far end is silent for 2.5 s and 1.2 s; no reference calls at all in those spans.
        var gappyFar = scenario.far
        for (from, to) in [(12.0, 14.5), (19.0, 20.2)] {
            for i in Int(from * Double(sr))..<Int(to * Double(sr)) { gappyFar[i] = 0 }
        }
        let gappyEcho = SyntheticEcho.convolve(gappyFar, SyntheticEcho.roomImpulseResponse(seed: 7, delayMs: 40.0))
        let mic = sum(gappyEcho, scenario.noise)
        let mask = Metrics.activeMask(gappyFar)

        let stage = try makeStage()
        var options = FeedOptions()
        options.skipSilentReference = true
        let out = StageFeeder.feed(stage: stage, mic: mic, reference: gappyFar, options: options)

        XCTAssertEqual(out.count, mic.count)
        let before = erle(mic: mic, out: out, mask: mask, from: 8, to: 12)
        let afterFirst = erle(mic: mic, out: out, mask: mask, from: 15.0, to: 17.5)    // 0.5-3 s after the far end resumed
        let afterSecond = erle(mic: mic, out: out, mask: mask, from: 20.7, to: 23.2)
        print("EchoCancellationStage gaps: ERLE before \(before) dB, after first gap \(afterFirst) dB, after second \(afterSecond) dB")
        // measured 22.0 / 21.9 / 24.0
        XCTAssertGreaterThanOrEqual(afterFirst, 12)
        XCTAssertGreaterThanOrEqual(afterSecond, 12)
        XCTAssertGreaterThanOrEqual(stage.statistics.referenceReanchors, 2)
    }

    // MARK: microphone timestamp jumps

    func test_microphoneTimestampJumps_conserveLengthAndAreCounted() throws {
        // Simulated capture restart: 0.35 s of microphone audio is lost at 10 s
        // (the timestamps jump forward), and the last 0.2 s is delivered twice at 16 s
        // (the timestamps jump backward).
        let mic = scenario.micFarOnly
        let cut0 = 10 * sr, cut1 = Int(10.35 * Double(sr))
        let dupAt = 16 * sr, dup = Int(0.2 * Double(sr))
        var mic2: [Float] = []
        var far2: [Float] = []
        var trueIndex: [Int] = []
        for range in [0..<cut0, cut1..<dupAt, (dupAt - dup)..<mic.count] {
            mic2.append(contentsOf: mic[range])
            far2.append(contentsOf: scenario.far[range])
            trueIndex.append(contentsOf: range)
        }
        XCTAssertEqual(trueIndex.count, mic2.count)

        let stage = try makeStage()
        var options = FeedOptions()
        options.micTrueIndex = trueIndex
        let out = StageFeeder.feed(stage: stage, mic: mic2, reference: scenario.far, options: options)

        XCTAssertEqual(out.count, mic2.count, "re-anchoring never inserts or drops microphone samples")
        XCTAssertEqual(stage.statistics.micReanchors, 2)
        let erle = self.erle(mic: mic2, out: out, mask: Metrics.activeMask(far2), from: 17, to: 23)
        print("EchoCancellationStage after mic timestamp jumps: ERLE \(erle) dB")
        XCTAssertGreaterThanOrEqual(erle, 12)   // measured 23.9
    }

    // MARK: conservation and ordering

    func test_randomChunking_conservesLengthAndOrder() throws {
        // With the whole reference delivered first, every frame sees the same inputs
        // whatever the microphone chunking, so the outputs must be IDENTICAL: nothing
        // lost, duplicated, reordered or shifted, however the chunks fall.
        let seconds = 10
        let count = seconds * sr
        let mic = Array(sum(scenario.near, scenario.noise)[0..<count])
        let reference = Array(scenario.far[0..<count])

        func run(chunkSizes: [Int]) throws -> [Float] {
            let stage = try makeStage()
            stage.appendReference(reference, hostTimeSeconds: 52_000)
            var output: [Float] = []
            var position = 0
            var k = 0
            while position < mic.count {
                let size = min(chunkSizes[k % chunkSizes.count], mic.count - position)
                k += 1
                output.append(contentsOf: stage.processMicrophone(
                    Array(mic[position..<(position + size)]),
                    hostTimeSeconds: 52_000 + Double(position) / Double(sr)))
                position += size
            }
            output.append(contentsOf: stage.flush())
            return output
        }

        let canonical = try run(chunkSizes: [160])
        XCTAssertEqual(canonical.count, count)
        for seed in 0..<4 {
            var rng = SplitMix64(seed: UInt64(seed) + 1234)
            var sizes: [Int] = []
            for _ in 0..<300 { sizes.append(1 + Int(rng.nextUInt64() % 4000)) }
            let out = try run(chunkSizes: sizes)
            XCTAssertEqual(out.count, count, "seed \(seed)")
            XCTAssertTrue(out == canonical, "seed \(seed): output differs from the 160-sample chunking")
        }
    }

    func test_randomInterleaving_conservesLength() throws {
        // Microphone and reference chunks of random sizes arriving in random order.
        let count = 8 * sr
        let mic = Array(scenario.micFarOnly[0..<count])
        for seed in 0..<5 {
            var rng = SplitMix64(seed: UInt64(seed) &+ 99)
            let stage = try makeStage()
            var micPos = 0, refPos = 0
            var produced = 0
            while micPos < count || refPos < count {
                let doMic = micPos < count && (refPos >= count || rng.nextUInt64() % 2 == 0)
                if doMic {
                    let size = min(1 + Int(rng.nextUInt64() % 3000), count - micPos)
                    produced += stage.processMicrophone(Array(mic[micPos..<(micPos + size)]),
                                                        hostTimeSeconds: 52_000 + Double(micPos) / Double(sr)).count
                    micPos += size
                } else {
                    let size = min(1 + Int(rng.nextUInt64() % 900), count - refPos)
                    stage.appendReference(Array(scenario.far[refPos..<(refPos + size)]),
                                          hostTimeSeconds: 52_000 + Double(refPos) / Double(sr))
                    refPos += size
                }
                XCTAssertLessThanOrEqual(produced, micPos, "never returns more than was passed in")
            }
            produced += stage.flush().count
            XCTAssertEqual(produced, count, "seed \(seed)")
        }
    }

    func test_flush_returnsExactlyTheHeldSamples() throws {
        let stage = try makeStage()
        // No reference at all: frames are held up to holdMs (2400 samples) before processing.
        var passedIn = 0, returned = 0
        for _ in 0..<7 {
            let chunk = [Float](repeating: 0.01, count: 1000)
            returned += stage.processMicrophone(chunk, hostTimeSeconds: 52_000 + Double(passedIn) / Double(sr)).count
            passedIn += chunk.count
        }
        let held = passedIn - returned
        XCTAssertGreaterThan(held, 0, "the hold keeps some samples back")
        let flushed = stage.flush()
        XCTAssertEqual(flushed.count, held)
        XCTAssertTrue(stage.flush().isEmpty, "a second flush has nothing to return")
        XCTAssertTrue(stage.processMicrophone([], hostTimeSeconds: nil).isEmpty)
    }

    func test_emptyInputs_areHarmless() throws {
        let stage = try makeStage()
        XCTAssertTrue(stage.flush().isEmpty)
        XCTAssertTrue(stage.processMicrophone([], hostTimeSeconds: 1).isEmpty)
        stage.appendReference([], hostTimeSeconds: 1)
        stage.resetTimeline(resetFilter: true)
        XCTAssertTrue(stage.flush().isEmpty)
        // fewer samples than one frame
        let few = [Float](repeating: 0.1, count: 37)
        let out = stage.processMicrophone(few, hostTimeSeconds: 2)
        XCTAssertEqual(out.count + stage.flush().count, few.count)
    }

    // MARK: no reference / contiguous mode

    func test_noReferenceEver_isTransparent() throws {
        let mic = sum(scenario.near, scenario.noise)
        let stage = try makeStage()
        let out = StageFeeder.feed(stage: stage, mic: mic, reference: [])
        XCTAssertEqual(out.count, mic.count)
        // Speex high-passes the microphone (see SpeexEchoCancellerTests); the rest is untouched.
        let expected = SyntheticEcho.dcNotch(mic)
        let correlation = Metrics.correlation(out, expected)
        let energyRatio = Metrics.db(Metrics.energy(out) / Metrics.energy(mic))
        print("EchoCancellationStage without reference: corr \(correlation), energy \(energyRatio) dB")
        XCTAssertGreaterThan(correlation, 0.999)       // measured 0.99999
        XCTAssertLessThan(abs(energyRatio), 1.0)        // measured -0.46 dB
        XCTAssertEqual(stage.statistics.framesWithReference, 0)
    }

    func test_noReferenceEver_bandLimitedSignalIsNearlyUnchanged() throws {
        // The spec's check read literally: output ~ input (correlation > 0.99, energy
        // within 1 dB), for a signal without content under Speex's ~60 Hz high-pass.
        var mic = SyntheticEcho.multitone(seed: 5, seconds: 8.0)
        for i in 0..<mic.count { mic[i] += scenario.noise[i] }
        let stage = try makeStage()
        let out = StageFeeder.feed(stage: stage, mic: mic, reference: [])
        XCTAssertEqual(out.count, mic.count)
        let correlation = Metrics.correlation(out, mic)
        let energyRatio = Metrics.db(Metrics.energy(out) / Metrics.energy(mic))
        print("EchoCancellationStage without reference, band-limited input: corr \(correlation), energy \(energyRatio) dB")
        XCTAssertGreaterThan(correlation, 0.99)         // measured 0.997
        XCTAssertLessThan(abs(energyRatio), 1.0)         // measured -0.01 dB
    }

    func test_contiguousMode_withoutTimestamps() throws {
        let stage = try makeStage()
        var options = FeedOptions()
        options.useTimestamps = false
        let out = StageFeeder.feed(stage: stage, mic: scenario.micFarOnly, reference: scenario.far, options: options)
        XCTAssertEqual(out.count, scenario.micFarOnly.count)
        let erle = self.erle(mic: scenario.micFarOnly, out: out, mask: scenario.farMask, from: 12, to: 24)
        XCTAssertGreaterThanOrEqual(erle, 12)   // measured 21.3
        XCTAssertNil(stage.statistics.initialMicToReferenceOffsetMs)
        XCTAssertEqual(stage.statistics.micReanchors + stage.statistics.referenceReanchors, 0)
    }

    func test_referenceStreamStartingLate_reportsTheOffset() throws {
        let stage = try makeStage()
        var options = FeedOptions()
        options.refStartSeconds = 0.5
        let out = StageFeeder.feed(stage: stage, mic: scenario.micFarOnly, reference: scenario.far, options: options)
        XCTAssertEqual(out.count, scenario.micFarOnly.count)
        // first mic timestamp - first reference timestamp = 0 - 0.5 s
        XCTAssertEqual(try XCTUnwrap(stage.statistics.initialMicToReferenceOffsetMs), -500, accuracy: 1)
        let erle = self.erle(mic: scenario.micFarOnly, out: out, mask: scenario.farMask, from: 12, to: 24)
        XCTAssertGreaterThanOrEqual(erle, 12)
    }

    // MARK: absurd timestamp basis

    func test_absurdTimestampBasis_doesNotCrashOrGrow() throws {
        // Microphone clock ~1e6 s, reference clock ~5 s: the streams can never be
        // aligned (the app guards against this, spec 03). Documented behaviour: the
        // stage keeps counting samples, the reference never lines up (frames are
        // released by the hold timeout with silence as reference), nothing is lost,
        // and memory stays bounded by the fixed-size ring buffer.
        let count = 10 * sr
        let stage = try makeStage()
        var options = FeedOptions()
        options.base = 1.0e6
        options.referenceBase = 5.0
        let out = StageFeeder.feed(stage: stage, mic: Array(scenario.micFarOnly[0..<count]),
                                   reference: Array(scenario.far[0..<count]), options: options)
        XCTAssertEqual(out.count, count)
        let s = stage.statistics
        XCTAssertEqual(try XCTUnwrap(s.initialMicToReferenceOffsetMs), 999_995_000, accuracy: 1)
        XCTAssertEqual(s.framesWithReference, 0)
        XCTAssertGreaterThan(s.framesHeldTooLong, 0)

        // Non-finite and astronomically large timestamps are ignored, not trapped on.
        let weird = try makeStage()
        var produced = 0
        for ts in [Double.nan, Double.infinity, -Double.infinity, 1.0e300, -1.0e300, 12.0, Double.greatestFiniteMagnitude] {
            weird.appendReference([Float](repeating: 0.1, count: 320), hostTimeSeconds: ts)
            produced += weird.processMicrophone([Float](repeating: 0.1, count: 1365), hostTimeSeconds: ts).count
        }
        produced += weird.flush().count
        XCTAssertEqual(produced, 7 * 1365)
    }

    // MARK: pause / resume

    func test_pauseAndResume_keepsTheFilterUnlessAskedToReset() throws {
        let mic = scenario.micFarOnly
        let half = 12 * sr
        var resumedOptions = FeedOptions()
        resumedOptions.base = 52_000 + 30 + 12   // resumes 30 s later on both streams

        func run(resetFilter: Bool) throws -> [Float] {
            let stage = try makeStage()
            var out = StageFeeder.feed(stage: stage, mic: Array(mic[0..<half]), reference: Array(scenario.far[0..<half]))
            stage.resetTimeline(resetFilter: resetFilter)
            out += StageFeeder.feed(stage: stage, mic: Array(mic[half...]), reference: Array(scenario.far[half...]),
                                    options: resumedOptions)
            return out
        }

        let kept = try run(resetFilter: false)
        XCTAssertEqual(kept.count, mic.count)
        let keptErle = erle(mic: mic, out: kept, mask: scenario.farMask, from: 14, to: 24)
        XCTAssertGreaterThanOrEqual(keptErle, 12)   // measured 21.4

        let fresh = try run(resetFilter: true)
        XCTAssertEqual(fresh.count, mic.count)
        let freshErle = erle(mic: mic, out: fresh, mask: scenario.farMask, from: 12, to: 14)
        XCTAssertLessThan(freshErle, 12)            // measured 5.0: relearning from scratch
    }

    func test_resetTimelineWithoutFlush_losesNothing() throws {
        let stage = try makeStage()
        let mic = scenario.micFarOnly
        var passedIn = 0, returned = 0
        for i in 0..<5 {
            let chunk = Array(mic[(i * 1365)..<((i + 1) * 1365)])
            returned += stage.processMicrophone(chunk, hostTimeSeconds: 100 + Double(passedIn) / Double(sr)).count
            passedIn += chunk.count
        }
        stage.resetTimeline(resetFilter: false)     // the caller forgot to flush
        for i in 5..<8 {
            let chunk = Array(mic[(i * 1365)..<((i + 1) * 1365)])
            returned += stage.processMicrophone(chunk, hostTimeSeconds: 500 + Double(i) * 0.0853).count
            passedIn += chunk.count
        }
        returned += stage.flush().count
        XCTAssertEqual(returned, passedIn)
    }

    // MARK: observer, statistics, custom backends

    func test_frameObserver_seesEveryProcessedFrame() throws {
        let stage = try makeStage()
        var calls = 0
        var wrongSizes = 0
        var sawReference = false
        stage.frameObserver = { near, far, out in
            calls += 1
            if near.count != 160 || far.count != 160 || out.count != 160 { wrongSizes += 1 }
            if far.contains(where: { $0 != 0 }) { sawReference = true }
        }
        let count = 6 * sr
        let out = StageFeeder.feed(stage: stage, mic: Array(scenario.micFarOnly[0..<count]),
                                   reference: Array(scenario.far[0..<count]))
        XCTAssertEqual(out.count, count)
        XCTAssertEqual(calls, stage.statistics.framesProcessed)
        XCTAssertEqual(wrongSizes, 0)
        XCTAssertTrue(sawReference)
    }

    func test_customBackend_isUsedAndItsLatencyCompensated() throws {
        /// y = x - far: removes the reference exactly when it is aligned, one frame late.
        final class DelayedSubtractor: EchoCancellerBackend {
            let frameSize = 160
            let latencySamples = 160
            private var previous = [Float](repeating: 0, count: 160)
            var processed = 0
            func process(near: UnsafePointer<Float>, far: UnsafePointer<Float>, out: UnsafeMutablePointer<Float>) {
                processed += 1
                for i in 0..<frameSize {
                    out[i] = previous[i]
                    previous[i] = near[i] - far[i]
                }
            }
            func reset() { previous = [Float](repeating: 0, count: 160) }
            func estimatedEchoDelayMs() -> Double? { return nil }
        }

        // A signal and the same signal as "reference", with no lead and in contiguous mode:
        // the backend outputs 0, delayed by a frame, and the stage must give back exactly
        // as many samples as it received.
        var configuration = EchoCancellationStage.Configuration()
        configuration.referenceLeadMs = 0
        let backend = DelayedSubtractor()
        let stage = try XCTUnwrap(EchoCancellationStage(configuration: configuration, backend: backend))
        let signal = (0..<5000).map { Float(sin(Double($0) * 0.05)) * 0.5 }
        stage.appendReference(signal, hostTimeSeconds: nil)
        var out = stage.processMicrophone(signal, hostTimeSeconds: nil)
        out += stage.flush()
        XCTAssertEqual(out.count, signal.count)
        XCTAssertGreaterThan(backend.processed, 0)
        for v in out { XCTAssertEqual(v, 0, accuracy: 1e-6) }
    }

    func test_customBackendWithoutLatencyProperty_usesTheDefault() throws {
        final class PassThrough: EchoCancellerBackend {
            let frameSize = 160
            func process(near: UnsafePointer<Float>, far: UnsafePointer<Float>, out: UnsafeMutablePointer<Float>) {
                for i in 0..<frameSize { out[i] = near[i] }
            }
            func reset() {}
            func estimatedEchoDelayMs() -> Double? { return nil }
        }
        let backend = PassThrough()
        XCTAssertEqual(backend.latencySamples, 0)
        let stage = try XCTUnwrap(EchoCancellationStage(backend: backend))
        let signal = (0..<1000).map { Float($0) / 1000 }
        var out = stage.processMicrophone(signal, hostTimeSeconds: nil)
        out += stage.flush()
        XCTAssertEqual(out, signal, "a pass-through backend returns the microphone untouched, in order")
    }

    // MARK: performance

    func test_throughput_sixtySecondsOfAudio() throws {
        let mic = scenario.micFarOnly
        let far = scenario.far
        // 24 s + 24 s + 12 s of the scenario = 60 s of audio
        let mic60 = mic + mic + Array(mic[0..<(12 * sr)])
        let far60 = far + far + Array(far[0..<(12 * sr)])
        let stage = try makeStage()
        let start = Date()
        let out = StageFeeder.feed(stage: stage, mic: mic60, reference: far60)
        let elapsed = Date().timeIntervalSince(start)
        print("EchoCancellationStage: 60 s of audio in \(elapsed) s")
        XCTAssertEqual(out.count, mic60.count)
        XCTAssertLessThan(elapsed, 5.0, "spec target: well under 3 s on CI; 5 s asserted for slow debug builds")
    }
}
