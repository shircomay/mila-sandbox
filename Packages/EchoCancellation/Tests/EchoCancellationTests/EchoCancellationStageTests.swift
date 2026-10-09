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

    // MARK: frame observer: aligned, latency-compensated chunks

    /// Everything the observer saw, concatenated, plus the shape of each call.
    private final class ObserverLog {
        var near: [Float] = []
        var far: [Float] = []
        var out: [Float] = []
        var calls = 0
        /// Calls whose arrays differ in length, are empty, or exceed the frame size.
        var badShapes = 0
        /// Samples where out != near - 0.5 * far (only meaningful for `DelayLineBackend`).
        var wrongRelation = 0

        func attach(to stage: EchoCancellationStage, frameSize: Int, checksRelation: Bool = false) {
            stage.frameObserver = { [unowned self] near, far, out in
                self.calls += 1
                if near.isEmpty || near.count != far.count || near.count != out.count || near.count > frameSize {
                    self.badShapes += 1
                }
                if checksRelation {
                    for i in 0..<min(near.count, far.count, out.count)
                    where abs(out[i] - (near[i] - 0.5 * far[i])) > 1e-6 {
                        self.wrongRelation += 1
                    }
                }
                self.near += near
                self.far += far
                self.out += out
            }
        }
    }

    /// y = near - 0.5 * far, delayed by `latencySamples` (a stand-in for a backend with
    /// algorithmic latency). With the stage's compensation, the observed `out` must equal
    /// `near - 0.5 * far` of the SAME observed samples, for any latency.
    private final class DelayLineBackend: EchoCancellerBackend {
        let frameSize = 160
        let latencySamples: Int
        private var line: [Float]

        init(latency: Int) {
            latencySamples = latency
            line = [Float](repeating: 0, count: latency)
        }

        func process(near: UnsafePointer<Float>, far: UnsafePointer<Float>, out: UnsafeMutablePointer<Float>) {
            for i in 0..<frameSize { line.append(near[i] - 0.5 * far[i]) }
            for i in 0..<frameSize { out[i] = line[i] }
            line.removeFirst(frameSize)
        }

        func reset() { line = [Float](repeating: 0, count: latencySamples) }
        func estimatedEchoDelayMs() -> Double? { return nil }
    }

    private enum Boundary { case flush, reset, flushThenReset }

    /// Drives `stage` through 1...5 segments of random-length random audio, in random chunks
    /// (1...1000 samples), ending each segment with `flush()`, `resetTimeline`, or both, and the
    /// session with `flush()`. Each segment's whole reference is delivered before its microphone,
    /// in contiguous mode, so with no lead the aligned far of a sample is exactly the reference
    /// sample of the same index within its run (a run restarts at every `resetTimeline`).
    /// Returns what the caller got back, the microphone input and the reference that was fed.
    private func driveSegments(_ stage: EchoCancellationStage, seed: UInt64)
        -> (returned: [Float], mic: [Float], reference: [Float]) {
        var rng = SplitMix64(seed: seed)
        var returned: [Float] = []
        var mic: [Float] = []
        var reference: [Float] = []
        let segments = 1 + Int(rng.nextUInt64() % 5)
        for _ in 0..<segments {
            let length = 1 + Int(rng.nextUInt64() % 6000)
            var segmentMic: [Float] = []
            var segmentReference: [Float] = []
            for _ in 0..<length {
                segmentMic.append(Float(Double(rng.nextUInt64() % 2_000_001) / 2_000_000.0 - 0.5))
                segmentReference.append(Float(Double(rng.nextUInt64() % 2_000_001) / 2_000_000.0 - 0.5))
            }
            mic += segmentMic
            reference += segmentReference
            stage.appendReference(segmentReference, hostTimeSeconds: nil)
            var position = 0
            while position < length {
                let size = min(1 + Int(rng.nextUInt64() % 1000), length - position)
                returned += stage.processMicrophone(Array(segmentMic[position..<(position + size)]), hostTimeSeconds: nil)
                position += size
            }
            switch [Boundary.flush, .reset, .flushThenReset][Int(rng.nextUInt64() % 3)] {
            case .flush:
                returned += stage.flush()
            case .reset:
                stage.resetTimeline(resetFilter: rng.nextUInt64() % 2 == 0)
            case .flushThenReset:
                returned += stage.flush()
                stage.resetTimeline(resetFilter: false)
            }
        }
        returned += stage.flush()   // also hands out anything a trailing resetTimeline carried
        return (returned, mic, reference)
    }

    private func assertObserverContract(_ label: String, _ log: ObserverLog, returned: [Float], mic: [Float],
                                        file: StaticString = #filePath, line: UInt = #line) {
        XCTAssertGreaterThan(log.calls, 0, label, file: file, line: line)
        XCTAssertEqual(log.badShapes, 0, "\(label): every call has three equal-length arrays of 1...frameSize",
                       file: file, line: line)
        XCTAssertEqual(returned.count, mic.count, "\(label): length conservation", file: file, line: line)
        XCTAssertTrue(log.out == returned, "\(label): observed out == everything the stage returned, in order",
                      file: file, line: line)
        XCTAssertTrue(log.near == mic, "\(label): observed near == all the microphone input, in order",
                      file: file, line: line)
        XCTAssertEqual(log.far.count, mic.count, "\(label): far is parallel to near", file: file, line: line)
    }

    func test_frameObserver_withLatencyBackends_isAlignedAndMatchesWhatTheCallerGets() throws {
        // Latency 0, a non-multiple of the frame (37), exactly one frame (the Speex case), more than one.
        for latency in [0, 37, 160, 400] {
            for seed in 0..<12 {
                var configuration = EchoCancellationStage.Configuration()
                configuration.referenceLeadMs = 0
                let stage = try XCTUnwrap(EchoCancellationStage(configuration: configuration,
                                                                backend: DelayLineBackend(latency: latency)))
                let log = ObserverLog()
                log.attach(to: stage, frameSize: 160, checksRelation: true)
                let run = driveSegments(stage, seed: UInt64(seed) &+ 7000)
                let label = "latency \(latency), seed \(seed)"
                assertObserverContract(label, log, returned: run.returned, mic: run.mic)
                XCTAssertEqual(log.wrongRelation, 0, "\(label): out is the cleaned version of the SAME near/far samples")
                XCTAssertTrue(log.far == run.reference, "\(label): far is the aligned reference of those samples")
                // The returned signal itself, independent of the observer: returned[i] = mic[i] - 0.5 * reference[i].
                for i in 0..<min(run.returned.count, run.mic.count)
                where abs(run.returned[i] - (run.mic[i] - 0.5 * run.reference[i])) > 1e-6 {
                    XCTFail("\(label): returned sample \(i) is not the cleaned sample \(i)")
                    break
                }
            }
        }
    }

    func test_frameObserver_withTheSpeexBackend_matchesWhatTheCallerGets() throws {
        let speex = try XCTUnwrap(SpeexEchoCanceller(configuration: .init()))
        XCTAssertEqual(speex.latencySamples, 160, "the default configuration has the one-frame preprocessor latency")
        for seed in 0..<6 {
            let backend = try XCTUnwrap(SpeexEchoCanceller(configuration: .init()))
            let stage = try XCTUnwrap(EchoCancellationStage(configuration: .init(), backend: backend))
            let log = ObserverLog()
            log.attach(to: stage, frameSize: 160)
            let run = driveSegments(stage, seed: UInt64(seed) &+ 9000)
            assertObserverContract("speex, seed \(seed)", log, returned: run.returned, mic: run.mic)
        }
    }

    func test_frameObserver_withTimestampsAndRealisticChunking_matchesWhatTheCallerGets() throws {
        let stage = try makeStage()
        let log = ObserverLog()
        log.attach(to: stage, frameSize: 160)
        let count = 6 * sr
        let mic = Array(scenario.micFarOnly[0..<count])
        let out = StageFeeder.feed(stage: stage, mic: mic, reference: Array(scenario.far[0..<count]))
        assertObserverContract("feeder", log, returned: out, mic: mic)
        XCTAssertTrue(log.far.contains(where: { $0 != 0 }), "the reference reaches the observer")
    }

    func test_frameObserver_withTheSpeexBackend_reportsOutAlignedWithNear() throws {
        // No reference: Speex only high-passes the microphone, so the observed out must be the
        // DC-notched observed near at lag ZERO. The backend's raw output (the old contract) is a
        // whole frame late and would not correlate.
        let stage = try makeStage()
        let log = ObserverLog()
        log.attach(to: stage, frameSize: 160)
        let mic = sum(scenario.near, scenario.noise)
        let out = StageFeeder.feed(stage: stage, mic: mic, reference: [])
        assertObserverContract("no reference", log, returned: out, mic: mic)
        let correlation = Metrics.correlation(log.out, SyntheticEcho.dcNotch(log.near))
        XCTAssertGreaterThan(correlation, 0.999)       // as in test_noReferenceEver_isTransparent: 0.99999
        XCTAssertTrue(log.far.allSatisfy { $0 == 0 })
    }

    func test_frameObserver_setLate_reportsOnlyWhatItCanPair() throws {
        for latency in [0, 37] {
            var configuration = EchoCancellationStage.Configuration()
            configuration.referenceLeadMs = 0
            let stage = try XCTUnwrap(EchoCancellationStage(configuration: configuration,
                                                            backend: DelayLineBackend(latency: latency)))
            let signal = (0..<5000).map { Float(sin(Double($0) * 0.05)) * 0.5 }
            stage.appendReference(signal, hostTimeSeconds: nil)
            var returned = stage.processMicrophone(Array(signal[0..<1234]), hostTimeSeconds: nil)
            let log = ObserverLog()
            log.attach(to: stage, frameSize: 160, checksRelation: true)
            returned += stage.processMicrophone(Array(signal[1234...]), hostTimeSeconds: nil)
            returned += stage.flush()
            XCTAssertEqual(returned.count, signal.count)
            XCTAssertEqual(log.badShapes, 0)
            XCTAssertEqual(log.wrongRelation, 0)
            XCTAssertEqual(log.near.count, log.out.count)
            XCTAssertGreaterThan(log.out.count, 0)
            XCTAssertTrue(Array(signal.suffix(log.near.count)) == log.near, "latency \(latency): near is a suffix of the input")
            XCTAssertTrue(Array(returned.suffix(log.out.count)) == log.out, "latency \(latency): out is a suffix of the output")
        }
    }

    func test_frameObserver_unsetMidway_stopsReporting() throws {
        var configuration = EchoCancellationStage.Configuration()
        configuration.referenceLeadMs = 0
        let stage = try XCTUnwrap(EchoCancellationStage(configuration: configuration,
                                                        backend: DelayLineBackend(latency: 37)))
        let log = ObserverLog()
        log.attach(to: stage, frameSize: 160)
        let signal = (0..<6000).map { Float(sin(Double($0) * 0.05)) * 0.5 }
        stage.appendReference(signal, hostTimeSeconds: nil)
        var returned = stage.processMicrophone(Array(signal[0..<2000]), hostTimeSeconds: nil)
        stage.frameObserver = nil
        let seen = log.out.count
        returned += stage.processMicrophone(Array(signal[2000...]), hostTimeSeconds: nil)
        returned += stage.flush()
        XCTAssertEqual(returned.count, signal.count)
        XCTAssertGreaterThan(seen, 0)
        XCTAssertEqual(log.out.count, seen, "nothing is reported once the observer is nil")
        XCTAssertTrue(Array(returned.prefix(seen)) == log.out)
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
