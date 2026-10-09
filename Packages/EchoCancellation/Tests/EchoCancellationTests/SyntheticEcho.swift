// Deterministic synthetic signals and scoring helpers for the echo-cancellation
// tests.
//
// This file is a line-by-line port of Tools/linux-harness/synth.py (signals) and
// tune.py / stage_scenarios.py (scoring and chunk feeding). The thresholds in the
// tests were chosen from numbers the Python harness measured on exactly these
// signals (calibrate_tests.py prints them); keep the two in sync.
// SyntheticEchoParityTests pins the port against values computed in Python.

import Foundation
import EchoCancellation

// MARK: - PRNG

/// SplitMix64 (public domain, Vigna). Wrapping arithmetic, identical in every language.
struct SplitMix64 {
    private var state: UInt64

    init(seed: UInt64) {
        state = seed
    }

    mutating func nextUInt64() -> UInt64 {
        state = state &+ 0x9E37_79B9_7F4A_7C15
        var z = state
        z = (z ^ (z >> 30)) &* 0xBF58_476D_1CE4_E5B9
        z = (z ^ (z >> 27)) &* 0x94D0_49BB_1331_11EB
        return z ^ (z >> 31)
    }

    /// Uniform in [0, 1) with 53 random bits.
    mutating func uniform() -> Double {
        return Double(nextUInt64() >> 11) * (1.0 / 9_007_199_254_740_992.0)
    }

    mutating func uniform(_ lo: Double, _ hi: Double) -> Double {
        return lo + (hi - lo) * uniform()
    }

    /// Approximately Gaussian (mean 0, variance 1): Irwin-Hall sum of four uniforms.
    mutating func gaussian() -> Double {
        let a = uniform()
        let b = uniform()
        let c = uniform()
        let d = uniform()
        return (a + b + c + d - 2.0) * 1.7320508075688772
    }
}

// MARK: - Signal generators

enum SyntheticEcho {
    static let sampleRate = 16_000

    // (F1, F2, F3) in Hz for five vowels.
    private static let vowels: [[Double]] = [
        [730.0, 1090.0, 2440.0],  // a
        [530.0, 1840.0, 2480.0],  // e
        [270.0, 2290.0, 3010.0],  // i
        [570.0, 840.0, 2410.0],   // o
        [300.0, 870.0, 2240.0],   // u
    ]
    private static let bandwidths: [Double] = [90.0, 110.0, 160.0]
    private static let fricativeFormants: [Double] = [2600.0, 4200.0, 6000.0]
    private static let fricativeBandwidths: [Double] = [500.0, 800.0, 1000.0]

    /// Two-pole resonator y = g*x + a1*y1 + a2*y2.
    private static func resonator(_ freq: Double, _ bw: Double, _ sr: Double) -> (g: Double, a1: Double, a2: Double) {
        let r = exp(-Double.pi * bw / sr)
        let a1 = 2.0 * r * cos(2.0 * Double.pi * freq / sr)
        let a2 = -r * r
        let g = 1.0 - r
        return (g, a1, a2)
    }

    /// Speech-like signal: syllable-rate envelope, vowel formants, pitch 90-220 Hz,
    /// occasional fricatives and 0.3-1.2 s pauses (exact digital silence), scaled so
    /// the RMS over the active part is `targetRMSdBFS`.
    static func speechLike(seed: UInt64, seconds: Double, targetRMSdBFS: Double) -> [Float] {
        let sr = Double(sampleRate)
        var rng = SplitMix64(seed: seed)
        let total = Int((seconds * sr).rounded())
        var signal = [Double](repeating: 0, count: total)
        var envelope = [Double](repeating: 0, count: total)

        var y1 = [0.0, 0.0, 0.0]
        var y2 = [0.0, 0.0, 0.0]
        var tilt = 0.0
        var pos = 0
        var phase = 0.0
        var lpNoise = 0.0
        let noiseScale = 3.4641016151377544

        while pos < total {
            if rng.uniform() < 0.18 {
                pos += Int(rng.uniform(0.3, 1.2) * sr)
                continue
            }
            let dur = Int(rng.uniform(0.12, 0.28) * sr)
            let amp = rng.uniform(0.35, 1.0)
            let voiced = rng.uniform() < 0.85
            let vowel = Int(rng.uniform() * 5.0) % 5
            let f0 = rng.uniform(90.0, 220.0)
            let vibRate = rng.uniform(4.0, 6.0)
            let freqs = voiced ? vowels[vowel] : fricativeFormants
            let bws = voiced ? bandwidths : fricativeBandwidths
            let coefs = [resonator(freqs[0], bws[0], sr), resonator(freqs[1], bws[1], sr), resonator(freqs[2], bws[2], sr)]
            let weights: [Double] = voiced ? [1.0, 0.7, 0.4] : [0.6, 1.0, 0.8]

            var i = 0
            while i < dur {
                let n = pos + i
                if n >= total { break }
                let t = Double(i) / Double(dur)
                let sEnv = sin(Double.pi * t)
                let env = amp * sEnv * sEnv
                let exc: Double
                if voiced {
                    let f = f0 * (1.0 + 0.03 * sin(2.0 * Double.pi * vibRate * Double(i) / sr))
                    phase += f / sr
                    var pulse = 0.0
                    if phase >= 1.0 {
                        phase -= 1.0
                        pulse = 1.0
                    }
                    lpNoise = 0.9 * lpNoise + 0.1 * (rng.uniform() - 0.5) * noiseScale
                    exc = 12.0 * pulse + 0.15 * lpNoise
                } else {
                    exc = 0.6 * (rng.uniform() - 0.5) * noiseScale
                }
                var acc = 0.0
                var k = 0
                while k < 3 {
                    let c = coefs[k]
                    let y = c.g * exc + c.a1 * y1[k] + c.a2 * y2[k]
                    y2[k] = y1[k]
                    y1[k] = y
                    acc += weights[k] * y
                    k += 1
                }
                tilt = acc + 0.6 * tilt
                signal[n] = tilt * env
                envelope[n] = env
                i += 1
            }
            pos += dur
        }

        var sum = 0.0
        var count = 0
        var j = 0
        while j < total {
            if envelope[j] > 0.05 {
                sum += signal[j] * signal[j]
                count += 1
            }
            j += 1
        }
        var gain = 1.0
        if count > 0 {
            let rms = (sum / Double(count)).squareRoot()
            if rms > 0 {
                gain = pow(10.0, targetRMSdBFS / 20.0) / rms
            }
        }
        var result = [Float](repeating: 0, count: total)
        j = 0
        while j < total {
            result[j] = Float(signal[j] * gain)
            j += 1
        }
        return result
    }

    static func whiteNoise(seed: UInt64, count: Int, rmsDbfs: Double) -> [Float] {
        var rng = SplitMix64(seed: seed)
        let scale = pow(10.0, rmsDbfs / 20.0)
        var result = [Float](repeating: 0, count: count)
        var i = 0
        while i < count {
            result[i] = Float(rng.gaussian() * scale)
            i += 1
        }
        return result
    }

    /// Synthetic room impulse response: a direct path at `delayMs` with amplitude
    /// `gain`, then an exponentially decaying Gaussian tail (amplitude -60 dB over
    /// `rt60Ms`) holding `tailToDirectEnergy` x the direct-path energy.
    static func roomImpulseResponse(seed: UInt64, delayMs: Double, rt60Ms: Double = 250.0,
                                    gain: Double = 0.5, tailToDirectEnergy: Double = 0.6,
                                    lengthMs: Double = 400.0) -> [Float] {
        let sr = Double(sampleRate)
        var rng = SplitMix64(seed: seed)
        let length = Int((lengthMs * sr / 1000.0).rounded())
        let d = Int((delayMs * sr / 1000.0).rounded())
        let size = max(length, d + 1)
        var tail = [Double](repeating: 0, count: size)
        let k = 6.907755278982137 / (rt60Ms * sr / 1000.0)
        var i = d + 1
        while i < size {
            tail[i] = rng.gaussian() * exp(-k * Double(i - d))
            i += 1
        }
        var energy = 0.0
        for v in tail { energy += v * v }
        if energy > 0 {
            let scale = (tailToDirectEnergy * gain * gain / energy).squareRoot()
            i = 0
            while i < size {
                tail[i] *= scale
                i += 1
            }
        }
        var h = tail
        h[d] += gain
        return h.map { Float($0) }
    }

    /// Soft clip with unity small-signal gain: tanh(drive*x)/drive.
    static func speakerNonlinearity(_ x: [Float], drive: Double = 3.0) -> [Float] {
        return x.map { Float(tanh(drive * Double($0)) / drive) }
    }

    /// Linear convolution truncated to `x.count` samples (FFT based).
    static func convolve(_ x: [Float], _ h: [Float]) -> [Float] {
        let n = x.count + h.count - 1
        var size = 1
        while size < n { size <<= 1 }
        let fft = FFT(size: size)
        var xr = [Double](repeating: 0, count: size)
        var xi = [Double](repeating: 0, count: size)
        var hr = [Double](repeating: 0, count: size)
        var hi = [Double](repeating: 0, count: size)
        for i in 0..<x.count { xr[i] = Double(x[i]) }
        for i in 0..<h.count { hr[i] = Double(h[i]) }
        fft.transform(&xr, &xi, inverse: false)
        fft.transform(&hr, &hi, inverse: false)
        var i = 0
        while i < size {
            let a = xr[i] * hr[i] - xi[i] * hi[i]
            let b = xr[i] * hi[i] + xi[i] * hr[i]
            xr[i] = a
            xi[i] = b
            i += 1
        }
        fft.transform(&xr, &xi, inverse: true)
        var result = [Float](repeating: 0, count: x.count)
        i = 0
        while i < x.count {
            result[i] = Float(xr[i])
            i += 1
        }
        return result
    }

    /// Replica of the DC-notch high-pass at the input of Speex's echo canceller
    /// (filter_dc_notch16 in mdf.c, float build, radius 0.982 at 16 kHz). The
    /// canceller applies it to the microphone signal even without any echo, so
    /// "transparent" means "equal to dcNotch(input)", not "equal to input".
    static func dcNotch(_ x: [Float], radius: Double = 0.982) -> [Float] {
        let den2 = radius * radius + 0.7 * (1.0 - radius) * (1.0 - radius)
        var m0 = 0.0
        var m1 = 0.0
        var result = [Float](repeating: 0, count: x.count)
        var i = 0
        while i < x.count {
            let v = Double(x[i])
            let vout = m0 + v
            m0 = m1 + 2.0 * (-v + radius * vout)
            m1 = v - den2 * vout
            result[i] = Float(radius * vout)
            i += 1
        }
        return result
    }
}

// MARK: - FFT

/// Plain iterative radix-2 complex FFT on separate real/imaginary Double arrays.
final class FFT {
    let size: Int
    private var cosTable: [Double]
    private var sinTable: [Double]

    init(size: Int) {
        precondition(size > 1 && (size & (size - 1)) == 0, "FFT size must be a power of two")
        self.size = size
        cosTable = [Double](repeating: 0, count: size / 2)
        sinTable = [Double](repeating: 0, count: size / 2)
        var t = 0
        while t < size / 2 {
            let angle = 2.0 * Double.pi * Double(t) / Double(size)
            cosTable[t] = cos(angle)
            sinTable[t] = sin(angle)
            t += 1
        }
    }

    /// In-place transform. The inverse is scaled by 1/size.
    func transform(_ re: inout [Double], _ im: inout [Double], inverse: Bool) {
        let n = size
        let sign: Double = inverse ? 1.0 : -1.0
        re.withUnsafeMutableBufferPointer { rb in
            im.withUnsafeMutableBufferPointer { ib in
                cosTable.withUnsafeBufferPointer { ct in
                    sinTable.withUnsafeBufferPointer { st in
                        let r = rb.baseAddress!
                        let m = ib.baseAddress!
                        // bit reversal
                        var j = 0
                        var i = 1
                        while i < n {
                            var bit = n >> 1
                            while j & bit != 0 {
                                j ^= bit
                                bit >>= 1
                            }
                            j ^= bit
                            if i < j {
                                let tr = r[i]; r[i] = r[j]; r[j] = tr
                                let ti = m[i]; m[i] = m[j]; m[j] = ti
                            }
                            i += 1
                        }
                        var len = 2
                        while len <= n {
                            let half = len >> 1
                            let step = n / len
                            var start = 0
                            while start < n {
                                var k = 0
                                var tw = 0
                                while k < half {
                                    let wr = ct[tw]
                                    let wi = sign * st[tw]
                                    let a = start + k
                                    let b = a + half
                                    let xr = r[b] * wr - m[b] * wi
                                    let xi = r[b] * wi + m[b] * wr
                                    r[b] = r[a] - xr
                                    m[b] = m[a] - xi
                                    r[a] += xr
                                    m[a] += xi
                                    k += 1
                                    tw += step
                                }
                                start += len
                            }
                            len <<= 1
                        }
                        if inverse {
                            let scale = 1.0 / Double(n)
                            var q = 0
                            while q < n {
                                r[q] *= scale
                                m[q] *= scale
                                q += 1
                            }
                        }
                    }
                }
            }
        }
    }
}

// MARK: - Scoring

enum Metrics {
    static func energy(_ x: [Float]) -> Double {
        var sum = 0.0
        for v in x { sum += Double(v) * Double(v) }
        return sum
    }

    static func energy(_ x: ArraySlice<Float>) -> Double {
        var sum = 0.0
        for v in x { sum += Double(v) * Double(v) }
        return sum
    }

    static func db(_ ratio: Double) -> Double {
        return 10.0 * log10(max(ratio, 1e-30))
    }

    static func correlation(_ a: [Float], _ b: [Float]) -> Double {
        var ab = 0.0, aa = 0.0, bb = 0.0
        for i in 0..<min(a.count, b.count) {
            let x = Double(a[i]), y = Double(b[i])
            ab += x * y
            aa += x * x
            bb += y * y
        }
        return ab / (aa * bb).squareRoot()
    }

    /// True where the energy in the window [i - win/2, i + win/2) exceeds
    /// win * threshold (mean square > threshold).
    static func activeMask(_ x: [Float], threshold: Double = 1e-4, window: Int = 160) -> [Bool] {
        let n = x.count
        var cumulative = [Double](repeating: 0, count: n + 1)
        for i in 0..<n {
            cumulative[i + 1] = cumulative[i] + Double(x[i]) * Double(x[i])
        }
        var mask = [Bool](repeating: false, count: n)
        for i in 0..<n {
            let lo = max(0, i - window / 2)
            let hi = min(n, i + window / 2)
            mask[i] = (cumulative[hi] - cumulative[lo]) > Double(window) * threshold
        }
        return mask
    }

    /// ERLE in dB: 10 log10(sum mic^2 / sum out^2) over the samples of [fromSeconds,
    /// toSeconds) where `farMask` is true.
    static func erle(mic: [Float], out: [Float], farMask: [Bool], fromSeconds: Double, toSeconds: Double) -> Double {
        let lo = Int(fromSeconds * Double(SyntheticEcho.sampleRate))
        let hi = min(Int(toSeconds * Double(SyntheticEcho.sampleRate)), mic.count, out.count, farMask.count)
        var m = 0.0, o = 0.0
        var i = lo
        while i < hi {
            if farMask[i] {
                m += Double(mic[i]) * Double(mic[i])
                o += Double(out[i]) * Double(out[i])
            }
            i += 1
        }
        return db(m / max(o, 1e-20))
    }
}

// MARK: - Shared scenario

/// The 24 s scenario most tests share (generated once per test run): speech-like
/// far-end audio, a different speech-like near-end voice, -50 dBFS mic noise, and
/// the far-end's echo through a synthetic room (direct path 40 ms, RT60 250 ms, gain 0.5).
final class EchoScenario {
    static let seconds = 24
    static let leadMs = 30.0
    static let shared = EchoScenario()

    let sampleRate = SyntheticEcho.sampleRate

    let far: [Float]
    let near: [Float]
    let noise: [Float]
    /// Far-end echo only (no noise), linear room.
    let echo: [Float]
    /// Far-end echo + noise: what the microphone hears with the near end silent.
    let micFarOnly: [Float]
    let farMask: [Bool]
    let alignedFar: [Float]

    private init() {
        let n = EchoScenario.seconds
        let farSignal = SyntheticEcho.speechLike(seed: 1, seconds: Double(n), targetRMSdBFS: -15.0)
        let nearSignal = SyntheticEcho.speechLike(seed: 2, seconds: Double(n), targetRMSdBFS: -20.0)
        let noiseSignal = SyntheticEcho.whiteNoise(seed: 3, count: farSignal.count, rmsDbfs: -50.0)
        let rir = SyntheticEcho.roomImpulseResponse(seed: 7, delayMs: 40.0)
        let echoSignal = SyntheticEcho.convolve(farSignal, rir)
        var mic = [Float](repeating: 0, count: farSignal.count)
        for i in 0..<farSignal.count {
            mic[i] = echoSignal[i] + noiseSignal[i]
        }
        far = farSignal
        near = nearSignal
        noise = noiseSignal
        echo = echoSignal
        micFarOnly = mic
        farMask = Metrics.activeMask(farSignal)
        alignedFar = EchoScenario.advance(farSignal, bySamples: Int((EchoScenario.leadMs * 16.0).rounded()))
    }

    var seconds: Int { return EchoScenario.seconds }

    /// x advanced by `samples` (x[n] -> x[n + samples]), zero padded at the end:
    /// the reference as the stage feeds it to the backend (`referenceLeadMs` ahead).
    static func advance(_ x: [Float], bySamples samples: Int) -> [Float] {
        if samples <= 0 { return x }
        return Array(x[samples...]) + [Float](repeating: 0, count: samples)
    }

    /// Echo of the first `seconds` seconds of `far` through a room with a different delay.
    func echoWithDelay(ms delayMs: Double, seconds: Int) -> [Float] {
        let n = seconds * sampleRate
        let rir = SyntheticEcho.roomImpulseResponse(seed: 7, delayMs: delayMs)
        return SyntheticEcho.convolve(Array(far[0..<n]), rir)
    }
}
