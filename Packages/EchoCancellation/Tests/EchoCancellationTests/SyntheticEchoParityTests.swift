import XCTest

/// Pins the Swift signal generators to the Python ones in
/// Tools/linux-harness/synth.py. Every threshold in the other test files was
/// measured on the Python signals, so a drifting port would invalidate them; the
/// reference numbers below were printed by synth.py (see the comment at each).
final class SyntheticEchoParityTests: XCTestCase {
    func test_splitMix64_matchesTheReferenceVectors() {
        var rng = SplitMix64(seed: 0)
        XCTAssertEqual(rng.nextUInt64(), 0xE220_A839_7B1D_CDAF)
        XCTAssertEqual(rng.nextUInt64(), 0x6E78_9E6A_A1B9_65F4)
        XCTAssertEqual(rng.nextUInt64(), 0x06C4_5D18_8009_454F)

        var seeded = SplitMix64(seed: 1)
        XCTAssertEqual(seeded.uniform(), 0.5665615751722809, accuracy: 1e-15)
        XCTAssertEqual(seeded.uniform(), 0.7457817572627011, accuracy: 1e-15)
    }

    func test_speechLike_matchesPython() {
        // synth.speech_like(1, 2.0, 16000, -15.0)
        let x = SyntheticEcho.speechLike(seed: 1, seconds: 2.0, targetRMSdBFS: -15.0)
        XCTAssertEqual(x.count, 32_000)
        XCTAssertEqual(Metrics.energy(x), 826.1337551999272, accuracy: 826.13 * 1e-4)
        let expected: [Int: Double] = [
            3000: -0.2081017643213272, 6000: 0.08926860243082047, 9000: -0.32991400361061096,
            12000: 0.10078936070203781, 15000: -0.00047344432095997036, 20000: 0.12926675379276276,
            25000: 0.0511668361723423, 30000: 0.017561227083206177,
        ]
        for (index, value) in expected {
            XCTAssertEqual(Double(x[index]), value, accuracy: 1e-4, "sample \(index)")
        }
    }

    func test_whiteNoise_matchesPython() {
        // synth.white_noise(3, 2000, -50.0)
        let n = SyntheticEcho.whiteNoise(seed: 3, count: 2000, rmsDbfs: -50.0)
        XCTAssertEqual(Double(n[0]), -0.002740884432569146, accuracy: 1e-7)
        XCTAssertEqual(Double(n[1]), -0.0006762964767403901, accuracy: 1e-7)
        XCTAssertEqual(Double(n[2]), 0.004326538648456335, accuracy: 1e-7)
        XCTAssertEqual(Metrics.energy(n), 0.020320266725578153, accuracy: 1e-6)
    }

    func test_roomImpulseResponse_matchesPython() {
        // synth.room_ir(7, 16000, 40.0, 250.0, 0.5)
        let h = SyntheticEcho.roomImpulseResponse(seed: 7, delayMs: 40.0)
        XCTAssertEqual(h.count, 6400)
        XCTAssertEqual(h[640], 0.5)
        XCTAssertEqual(Double(h[700]), 0.010302909649908543, accuracy: 1e-6)
        XCTAssertEqual(Metrics.energy(h), 0.39999999968051053, accuracy: 1e-6)
        XCTAssertEqual(Double(h[0]), 0)
    }

    func test_convolveAndDcNotch_matchPython() {
        let speech = SyntheticEcho.speechLike(seed: 1, seconds: 2.0, targetRMSdBFS: -15.0)
        let x = Array(speech[0..<8000])
        let h = SyntheticEcho.roomImpulseResponse(seed: 7, delayMs: 40.0)
        // synth.convolve(xs, synth.room_ir(7, 16000, 40.0, 250.0, 0.5))
        let y = SyntheticEcho.convolve(x, h)
        XCTAssertEqual(y.count, 8000)
        XCTAssertEqual(Metrics.energy(y), 132.43541699800355, accuracy: 132.4 * 1e-4)
        XCTAssertEqual(Double(y[5000]), -0.022482508793473244, accuracy: 1e-5)

        // synth.dc_notch(xs[:4000])
        let d = SyntheticEcho.dcNotch(Array(x[0..<4000]))
        XCTAssertEqual(Metrics.energy(d), 249.622226855793, accuracy: 249.6 * 1e-4)
        XCTAssertEqual(Double(d[3000]), -0.2950151264667511, accuracy: 1e-4)
    }

    func test_fft_matchesADirectDFT() {
        let n = 64
        var re = (0..<n).map { sin(Double($0) * 0.3) + 0.5 * cos(Double($0) * 1.7) }
        var im = [Double](repeating: 0, count: n)
        let original = re
        let fft = FFT(size: n)
        fft.transform(&re, &im, inverse: false)
        for k in [0, 1, 5, 17, 32, 63] {
            var sr = 0.0, si = 0.0
            for t in 0..<n {
                let angle = -2.0 * Double.pi * Double(k) * Double(t) / Double(n)
                sr += original[t] * cos(angle)
                si += original[t] * sin(angle)
            }
            XCTAssertEqual(re[k], sr, accuracy: 1e-9, "bin \(k) real")
            XCTAssertEqual(im[k], si, accuracy: 1e-9, "bin \(k) imaginary")
        }
        fft.transform(&re, &im, inverse: true)
        for t in 0..<n {
            XCTAssertEqual(re[t], original[t], accuracy: 1e-12)
            XCTAssertEqual(im[t], 0, accuracy: 1e-12)
        }
    }
}
