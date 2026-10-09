import XCTest
import EchoCancellation

/// Backend-level tests: frames are fed directly, with the reference already
/// time-aligned (advanced by the stage's 30 ms lead), on the shared 24 s scenario.
///
/// Thresholds come from Tools/linux-harness/calibrate_tests.py (measured values in
/// the comments, TUNING.md has the tables); each leaves a margin of several dB
/// because CI is a different CPU and compiler (floating-point contraction changes
/// the adaptive trajectory slightly).
final class SpeexEchoCancellerTests: XCTestCase {
    private let scenario = EchoScenario.shared
    private let sr = SyntheticEcho.sampleRate

    // MARK: helpers

    private func makeBackend(_ configure: ((inout SpeexEchoCanceller.Configuration) -> Void)? = nil) throws -> SpeexEchoCanceller {
        var configuration = SpeexEchoCanceller.Configuration()
        configure?(&configuration)
        return try XCTUnwrap(SpeexEchoCanceller(configuration: configuration))
    }

    /// Runs frames [fromFrame, toFrame) and writes the raw backend output into `output`.
    private func run(_ backend: SpeexEchoCanceller, near: [Float], far: [Float],
                     fromFrame: Int, toFrame: Int, output: inout [Float]) {
        let n = backend.frameSize
        near.withUnsafeBufferPointer { nearPointer in
            far.withUnsafeBufferPointer { farPointer in
                output.withUnsafeMutableBufferPointer { outPointer in
                    var frame = fromFrame
                    while frame < toFrame {
                        backend.process(near: nearPointer.baseAddress! + frame * n,
                                        far: farPointer.baseAddress! + frame * n,
                                        out: outPointer.baseAddress! + frame * n)
                        frame += 1
                    }
                }
            }
        }
    }

    /// Whole-signal run; the output is shifted back by the backend's latency so it
    /// lines up with `near` (the stage does the same).
    private func runAll(_ backend: SpeexEchoCanceller, near: [Float], far: [Float]) -> [Float] {
        let n = backend.frameSize
        let frames = min(near.count, far.count) / n
        var output = [Float](repeating: 0, count: frames * n)
        run(backend, near: near, far: far, fromFrame: 0, toFrame: frames, output: &output)
        return compensate(output, latency: backend.latencySamples)
    }

    private func compensate(_ raw: [Float], latency: Int) -> [Float] {
        if latency <= 0 { return raw }
        return Array(raw[latency...]) + [Float](repeating: 0, count: latency)
    }

    private func erle(mic: [Float], out: [Float], mask: [Bool], from: Double, to: Double) -> Double {
        return Metrics.erle(mic: mic, out: out, farMask: mask, fromSeconds: from, toSeconds: to)
    }

    // MARK: scenario 1 - far-end only

    func test_farOnlyEcho_isCancelled() throws {
        let backend = try makeBackend()
        let out = runAll(backend, near: scenario.micFarOnly, far: scenario.alignedFar)
        let erle = self.erle(mic: scenario.micFarOnly, out: out, mask: scenario.farMask, from: 12, to: 24)
        print("SpeexEchoCanceller far-only ERLE 12-24 s: \(erle) dB")
        // measured 20.8 dB
        XCTAssertGreaterThanOrEqual(erle, 12, "echo reduction after convergence")
        XCTAssertEqual(backend.latencySamples, 160)
    }

    // MARK: scenario 2 - near-end only

    func test_nearOnly_passesThroughTransparently() throws {
        let seconds = 20
        let count = seconds * sr
        var mic = [Float](repeating: 0, count: count)
        for i in 0..<count { mic[i] = scenario.near[i] + scenario.noise[i] }
        let silence = [Float](repeating: 0, count: count)

        let backend = try makeBackend()
        let out = runAll(backend, near: mic, far: silence)
        // Speex high-passes the microphone (DC notch) even without echo; transparent
        // means "equals the notched input", measured after 2 s of settling.
        let expected = SyntheticEcho.dcNotch(mic)
        let a = Array(expected[(2 * sr)...])
        let b = Array(out[(2 * sr)...])
        var errorEnergy = 0.0
        for i in 0..<a.count {
            let d = Double(b[i]) - Double(a[i])
            errorEnergy += d * d
        }
        let snr = Metrics.db(Metrics.energy(a) / errorEnergy)
        let energyRatio = Metrics.db(Metrics.energy(b) / Metrics.energy(a))
        let correlation = Metrics.correlation(a, b)
        print("SpeexEchoCanceller near-only: SNR \(snr) dB, energy \(energyRatio) dB, corr \(correlation)")
        // measured 42.4 dB, -0.06 dB, 0.99999
        XCTAssertGreaterThanOrEqual(snr, 25)
        XCTAssertLessThanOrEqual(abs(energyRatio), 1.0)
        XCTAssertGreaterThanOrEqual(correlation, 0.999)
    }

    // MARK: scenario 3 - double talk

    func test_doubleTalk_retainsTheNearEndVoice() throws {
        let count = scenario.far.count
        var mic = [Float](repeating: 0, count: count)
        var nearPlusNoise = [Float](repeating: 0, count: count)
        for i in 0..<count {
            nearPlusNoise[i] = scenario.near[i] + scenario.noise[i]
            mic[i] = scenario.near[i] + scenario.echo[i] + scenario.noise[i]
        }
        let out = runAll(try makeBackend(), near: mic, far: scenario.alignedFar)
        // What a perfect canceller would output: the same backend on the near-only microphone.
        let ideal = runAll(try makeBackend(), near: nearPlusNoise, far: [Float](repeating: 0, count: count))

        let nearMask = Metrics.activeMask(scenario.near)
        let echoMask = Metrics.activeMask(scenario.echo)
        var oi = 0.0, ii = 0.0, oo = 0.0, diff = 0.0, echoEnergy = 0.0
        var doubleTalkSamples = 0
        for i in (12 * sr)..<count where nearMask[i] && echoMask[i] {
            let o = Double(out[i]), p = Double(ideal[i])
            oi += o * p
            ii += p * p
            oo += o * o
            diff += (o - p) * (o - p)
            echoEnergy += Double(scenario.echo[i]) * Double(scenario.echo[i])
            doubleTalkSamples += 1
        }
        XCTAssertGreaterThan(doubleTalkSamples, 10 * sr / 10, "the scenario must contain double talk")
        let retentionDb = 20 * log10(abs(oi / ii))
        let correlation = oi / (oo * ii).squareRoot()
        let leakDb = Metrics.db(diff / echoEnergy)
        print("SpeexEchoCanceller double-talk: retention \(retentionDb) dB, corr \(correlation), (out-ideal) vs echo \(leakDb) dB")
        // measured -0.50 dB, 0.985, -15.4 dB
        XCTAssertLessThanOrEqual(abs(retentionDb), 1.5, "near-end energy retained")
        XCTAssertGreaterThanOrEqual(correlation, 0.90)
        XCTAssertLessThanOrEqual(leakDb, -6, "residual echo / distortion relative to the echo")
    }

    // MARK: reset

    func test_reset_forgetsTheEchoPath() throws {
        let n = 160
        let totalFrames = scenario.micFarOnly.count / n
        let resetFrame = 12 * sr / n
        let afterFrame = 14 * sr / n

        let continued = try makeBackend()
        var outContinued = [Float](repeating: 0, count: totalFrames * n)
        run(continued, near: scenario.micFarOnly, far: scenario.alignedFar, fromFrame: 0, toFrame: afterFrame, output: &outContinued)

        let reset = try makeBackend()
        var outReset = [Float](repeating: 0, count: totalFrames * n)
        run(reset, near: scenario.micFarOnly, far: scenario.alignedFar, fromFrame: 0, toFrame: resetFrame, output: &outReset)
        XCTAssertNotNil(reset.estimatedEchoDelayMs(), "converged before the reset")
        reset.reset()
        XCTAssertNil(reset.estimatedEchoDelayMs(), "a reset backend has no delay estimate")
        run(reset, near: scenario.micFarOnly, far: scenario.alignedFar, fromFrame: resetFrame, toFrame: afterFrame, output: &outReset)

        let a = erle(mic: scenario.micFarOnly, out: compensate(outContinued, latency: 160), mask: scenario.farMask, from: 12, to: 14)
        let b = erle(mic: scenario.micFarOnly, out: compensate(outReset, latency: 160), mask: scenario.farMask, from: 12, to: 14)
        print("SpeexEchoCanceller reset: ERLE 12-14 s continued \(a) dB, after reset \(b) dB")
        // measured 19.7 dB vs 4.4 dB
        XCTAssertLessThanOrEqual(b, a - 6, "right after a reset the echo is no longer cancelled")

        // ...and it learns the path again.
        run(reset, near: scenario.micFarOnly, far: scenario.alignedFar, fromFrame: afterFrame, toFrame: totalFrames, output: &outReset)
        let relearned = erle(mic: scenario.micFarOnly, out: compensate(outReset, latency: 160), mask: scenario.farMask, from: 20, to: 24)
        // measured 19.9 dB
        XCTAssertGreaterThanOrEqual(relearned, 8)
    }

    // MARK: echo delay estimate

    func test_delayEstimate_isTheTrueDelayPlusLead() throws {
        let backend = try makeBackend()
        _ = runAll(backend, near: scenario.micFarOnly, far: scenario.alignedFar)
        let estimate = try XCTUnwrap(backend.estimatedEchoDelayMs())
        // true delay 40 ms + 30 ms lead; measured 70.0 ms
        XCTAssertEqual(estimate, 70, accuracy: 10)
    }

    func test_delayEstimate_otherDelays() throws {
        let seconds = 14
        let count = seconds * sr
        let farAligned = Array(scenario.alignedFar[0..<count])
        for delayMs in [0.0, 120.0, 200.0] {
            let echo = scenario.echoWithDelay(ms: delayMs, seconds: seconds)
            var mic = [Float](repeating: 0, count: count)
            for i in 0..<count { mic[i] = echo[i] + scenario.noise[i] }
            let backend = try makeBackend()
            _ = runAll(backend, near: mic, far: farAligned)
            let estimate = try XCTUnwrap(backend.estimatedEchoDelayMs(), "no estimate for \(delayMs) ms")
            // measured delay + 30 ms exactly
            XCTAssertEqual(estimate, delayMs + 30, accuracy: 10, "true echo delay \(delayMs) ms")
        }
    }

    func test_delayEstimate_isNilBeforeTwoSecondsOfFarEndAudio() throws {
        let backend = try makeBackend()
        var output = [Float](repeating: 0, count: scenario.micFarOnly.count)
        run(backend, near: scenario.micFarOnly, far: scenario.alignedFar, fromFrame: 0, toFrame: 100, output: &output)  // 1 s
        XCTAssertNil(backend.estimatedEchoDelayMs())
        // no far-end signal at all: still nil however long it runs
        let silent = try makeBackend()
        let zeros = [Float](repeating: 0, count: 10 * sr)
        var scratch = [Float](repeating: 0, count: 10 * sr)
        run(silent, near: zeros, far: zeros, fromFrame: 0, toFrame: 1000, output: &scratch)
        XCTAssertNil(silent.estimatedEchoDelayMs())
    }

    // MARK: scenario 5 - nonlinear echo path

    func test_nonlinearEchoPath_isStillReduced() throws {
        let squashed = SyntheticEcho.speakerNonlinearity(scenario.far)
        let rir = SyntheticEcho.roomImpulseResponse(seed: 7, delayMs: 40.0)
        let echo = SyntheticEcho.convolve(squashed, rir)
        var mic = [Float](repeating: 0, count: echo.count)
        for i in 0..<echo.count { mic[i] = echo[i] + scenario.noise[i] }
        let out = runAll(try makeBackend(), near: mic, far: scenario.alignedFar)
        let erle = self.erle(mic: mic, out: out, mask: scenario.farMask, from: 12, to: 24)
        print("SpeexEchoCanceller nonlinear echo ERLE 12-24 s: \(erle) dB")
        // measured 13.1 dB (linear path: 20.8 dB)
        XCTAssertGreaterThanOrEqual(erle, 6)
    }

    // MARK: configuration

    func test_configuration_frameSizeLatencyAndFilterLength() throws {
        let standard = try makeBackend()
        XCTAssertEqual(standard.frameSize, 160)
        XCTAssertEqual(standard.latencySamples, 160, "the preprocessor's overlap-add delays the output by one frame")
        XCTAssertEqual(standard.filterLengthSamples, 4800)

        let noResidual = try makeBackend { $0.residualEchoSuppression = false }
        XCTAssertEqual(noResidual.latencySamples, 0)

        let rounded = try makeBackend { $0.filterLengthMs = 305 }
        XCTAssertEqual(rounded.filterLengthSamples, 4960, "rounded up to whole frames")

        let noiseSuppression = try makeBackend { $0.noiseSuppression = true }
        XCTAssertEqual(noiseSuppression.latencySamples, 160)
    }

    func test_configuration_invalidValuesFailInitialisation() {
        var c = SpeexEchoCanceller.Configuration()
        c.frameSize = 0
        XCTAssertNil(SpeexEchoCanceller(configuration: c))
        c = SpeexEchoCanceller.Configuration()
        c.sampleRate = 0
        XCTAssertNil(SpeexEchoCanceller(configuration: c))
        c = SpeexEchoCanceller.Configuration()
        c.filterLengthMs = 0
        XCTAssertNil(SpeexEchoCanceller(configuration: c))
        // Speex's kiss FFT calls exit(1) for frame sizes with a prime factor above 17
        // (163 is prime, 190 = 2*5*19); the initialiser must refuse them instead.
        for badFrameSize in [163, 190, 31, 5_000] {
            c = SpeexEchoCanceller.Configuration()
            c.frameSize = badFrameSize
            XCTAssertNil(SpeexEchoCanceller(configuration: c), "frame size \(badFrameSize)")
        }
        // 20 ms @ 16 kHz and 10 ms @ 48 kHz are fine.
        c = SpeexEchoCanceller.Configuration()
        c.frameSize = 320
        XCTAssertNotNil(SpeexEchoCanceller(configuration: c))
        c = SpeexEchoCanceller.Configuration(sampleRate: 48_000, frameSize: 480, filterLengthMs: 300,
                                             residualEchoSuppression: true, echoSuppressDb: -40,
                                             echoSuppressActiveDb: -15, noiseSuppression: false)
        XCTAssertNotNil(SpeexEchoCanceller(configuration: c))
        XCTAssertNotNil(SpeexEchoCanceller(configuration: .init()))
        XCTAssertEqual(SpeexEchoCanceller.Configuration(), SpeexEchoCanceller.Configuration())
    }

    // MARK: robustness

    func test_extremeInput_staysFiniteAndBounded() throws {
        let backend = try makeBackend()
        let n = backend.frameSize
        var near = [Float](repeating: 0, count: n)
        var far = [Float](repeating: 0, count: n)
        var out = [Float](repeating: 0, count: n)
        for frame in 0..<400 {
            for i in 0..<n {
                switch (frame + i) % 5 {
                case 0: near[i] = 4.0
                case 1: near[i] = -4.0
                case 2: near[i] = Float.nan
                case 3: near[i] = 1.0
                default: near[i] = 0.25
                }
                far[i] = (frame % 3 == 0) ? Float.infinity : -1.0
            }
            backend.process(near: near, far: far, out: &out)
            for v in out {
                XCTAssertTrue(v.isFinite)
                XCTAssertLessThanOrEqual(abs(v), 1.0)
            }
        }
    }
}
