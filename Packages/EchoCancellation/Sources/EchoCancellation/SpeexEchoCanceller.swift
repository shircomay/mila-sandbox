import CSpeexDSP

/// ``EchoCancellerBackend`` built on SpeexDSP's MDF echo canceller (an adaptive
/// frequency-domain block filter with a foreground/background double path),
/// optionally followed by Speex's preprocessor, whose only job here is
/// residual echo suppression.
///
/// Tuning rationale and measurements: `TUNING.md` next to `Package.swift`. The
/// C harness in `Tools/linux-harness/aec_harness.c` mirrors `process(...)`
/// exactly; keep them in sync.
public final class SpeexEchoCanceller: EchoCancellerBackend {
    public struct Configuration: Equatable, Sendable {
        public var sampleRate: Int = 16_000
        public var frameSize: Int = 160            // 10 ms @ 16 kHz
        public var filterLengthMs: Int = 300       // echo tail the filter can model
        public var residualEchoSuppression: Bool = true
        public var echoSuppressDb: Int = -40       // SPEEX_PREPROCESS_SET_ECHO_SUPPRESS
        public var echoSuppressActiveDb: Int = -15 // SPEEX_PREPROCESS_SET_ECHO_SUPPRESS_ACTIVE
        public var noiseSuppression: Bool = false  // keep whisper's input natural

        public init() {}

        public init(sampleRate: Int, frameSize: Int, filterLengthMs: Int,
                    residualEchoSuppression: Bool, echoSuppressDb: Int,
                    echoSuppressActiveDb: Int, noiseSuppression: Bool) {
            self.sampleRate = sampleRate
            self.frameSize = frameSize
            self.filterLengthMs = filterLengthMs
            self.residualEchoSuppression = residualEchoSuppression
            self.echoSuppressDb = echoSuppressDb
            self.echoSuppressActiveDb = echoSuppressActiveDb
            self.noiseSuppression = noiseSuppression
        }
    }

    public let configuration: Configuration
    public let frameSize: Int

    /// With residual echo suppression on, the preprocessor's overlap-add adds
    /// exactly one frame of latency; otherwise zero. See ``EchoCancellerBackend/latencySamples``.
    public let latencySamples: Int

    /// Echo-filter length actually used: `filterLengthMs` rounded up to whole frames.
    public let filterLengthSamples: Int

    // Far frames below this mean square (about -60 dBFS RMS) do not count as
    // "far-end active" for the delay estimate.
    private static let farActiveMeanSquare: Float = 1e-6
    // ~2 s of far-active audio before the delay estimate is offered.
    private static let minActiveFramesForDelay = 200

    private let echoState: OpaquePointer
    private var preprocessState: OpaquePointer?
    private let nearBuffer: UnsafeMutablePointer<Int16>
    private let farBuffer: UnsafeMutablePointer<Int16>
    private let outBuffer: UnsafeMutablePointer<Int16>
    private let impulseResponse: UnsafeMutablePointer<Int32>
    private var farActiveFrames = 0

    /// Returns nil when the configuration is unusable or Speex cannot allocate.
    ///
    /// Besides sane ranges the frame size must factor into primes <= 17: Speex's
    /// kiss FFT calls exit(1) ("max radix supported is 17") for anything else,
    /// which would take the whole app down instead of failing this initialiser.
    public init?(configuration: Configuration = .init()) {
        guard (4_000...192_000).contains(configuration.sampleRate),
              (32...4_096).contains(configuration.frameSize),
              SpeexEchoCanceller.hasSupportedFFTLength(configuration.frameSize),
              (1...2_000).contains(configuration.filterLengthMs)
        else { return nil }

        let frameSize = configuration.frameSize
        let wantedSamples = (configuration.filterLengthMs * configuration.sampleRate + 999) / 1000
        let blocks = max(1, (wantedSamples + frameSize - 1) / frameSize)
        let filterLength = blocks * frameSize

        guard let echo = speex_echo_state_init(Int32(frameSize), Int32(filterLength)) else {
            return nil
        }
        var rate = Int32(configuration.sampleRate)
        _ = speex_echo_ctl(echo, SPEEX_ECHO_SET_SAMPLING_RATE, &rate)

        var preprocess: OpaquePointer?
        if configuration.residualEchoSuppression {
            preprocess = SpeexEchoCanceller.makePreprocessor(
                configuration: configuration, echo: echo)
            if preprocess == nil {
                speex_echo_state_destroy(echo)
                return nil
            }
        }

        let nearBuffer = UnsafeMutablePointer<Int16>.allocate(capacity: frameSize)
        nearBuffer.initialize(repeating: 0, count: frameSize)
        let farBuffer = UnsafeMutablePointer<Int16>.allocate(capacity: frameSize)
        farBuffer.initialize(repeating: 0, count: frameSize)
        let outBuffer = UnsafeMutablePointer<Int16>.allocate(capacity: frameSize)
        outBuffer.initialize(repeating: 0, count: frameSize)
        let impulseResponse = UnsafeMutablePointer<Int32>.allocate(capacity: filterLength)
        impulseResponse.initialize(repeating: 0, count: filterLength)

        self.configuration = configuration
        self.frameSize = frameSize
        self.filterLengthSamples = filterLength
        self.latencySamples = preprocess == nil ? 0 : frameSize
        self.echoState = echo
        self.preprocessState = preprocess
        self.nearBuffer = nearBuffer
        self.farBuffer = farBuffer
        self.outBuffer = outBuffer
        self.impulseResponse = impulseResponse
    }

    deinit {
        // The preprocessor holds a pointer to the echo state: destroy it first.
        if let preprocessState {
            speex_preprocess_state_destroy(preprocessState)
        }
        speex_echo_state_destroy(echoState)
        nearBuffer.deallocate()
        farBuffer.deallocate()
        outBuffer.deallocate()
        impulseResponse.deallocate()
    }

    // MARK: - EchoCancellerBackend

    public func process(near: UnsafePointer<Float>, far: UnsafePointer<Float>,
                        out: UnsafeMutablePointer<Float>) {
        var farEnergy: Float = 0
        for i in 0..<frameSize {
            nearBuffer[i] = SpeexEchoCanceller.int16(from: near[i])
            let f = far[i]
            farBuffer[i] = SpeexEchoCanceller.int16(from: f)
            farEnergy += f * f
        }
        if farEnergy > SpeexEchoCanceller.farActiveMeanSquare * Float(frameSize) {
            farActiveFrames += 1
        }

        speex_echo_cancellation(echoState, nearBuffer, farBuffer, outBuffer)
        if let preprocessState {
            // In place; residual echo is estimated from the echo state set up in makePreprocessor.
            _ = speex_preprocess_run(preprocessState, outBuffer)
        }

        for i in 0..<frameSize {
            out[i] = Float(outBuffer[i]) / 32768
        }
    }

    public func reset() {
        speex_echo_state_reset(echoState)
        farActiveFrames = 0
        // The preprocessor has no reset call: recreate it so its noise and
        // residual-echo history starts clean as well.
        if let old = preprocessState {
            speex_preprocess_state_destroy(old)
            preprocessState = SpeexEchoCanceller.makePreprocessor(
                configuration: configuration, echo: echoState)
        }
        nearBuffer.update(repeating: 0, count: frameSize)
        farBuffer.update(repeating: 0, count: frameSize)
        outBuffer.update(repeating: 0, count: frameSize)
    }

    public func estimatedEchoDelayMs() -> Double? {
        guard farActiveFrames >= SpeexEchoCanceller.minActiveFramesForDelay else { return nil }
        var size: Int32 = 0
        _ = speex_echo_ctl(echoState, SPEEX_ECHO_GET_IMPULSE_RESPONSE_SIZE, &size)
        let taps = Int(size)
        guard taps > 0, taps <= filterLengthSamples else { return nil }
        _ = speex_echo_ctl(echoState, SPEEX_ECHO_GET_IMPULSE_RESPONSE, impulseResponse)

        var bestIndex = 0
        var bestMagnitude: UInt64 = 0
        for i in 0..<taps {
            let magnitude = Int64(impulseResponse[i]).magnitude
            if magnitude > bestMagnitude {
                bestMagnitude = magnitude
                bestIndex = i
            }
        }
        guard bestMagnitude > 0 else { return nil }
        return 1000 * Double(bestIndex) / Double(configuration.sampleRate)
    }

    // MARK: - Helpers

    /// True when `n` has no prime factor above 17 (the largest radix kiss FFT supports).
    static func hasSupportedFFTLength(_ n: Int) -> Bool {
        var remaining = n
        for prime in [2, 3, 5, 7, 11, 13, 17] {
            while remaining % prime == 0 {
                remaining /= prime
            }
        }
        return remaining == 1
    }

    /// Float [-1, 1] -> Int16, scaled by 32767, rounded and clamped.
    @inline(__always)
    private static func int16(from x: Float) -> Int16 {
        if x.isNaN { return 0 }
        let v = x * 32767
        if v >= 32767 { return 32767 }
        if v <= -32768 { return -32768 }
        return Int16(v.rounded())
    }

    private static func makePreprocessor(configuration c: Configuration,
                                         echo: OpaquePointer) -> OpaquePointer? {
        guard let state = speex_preprocess_state_init(Int32(c.frameSize), Int32(c.sampleRate)) else {
            return nil
        }
        // The residual-echo estimate is taken from the echo canceller's state.
        _ = speex_preprocess_ctl(state, SPEEX_PREPROCESS_SET_ECHO_STATE, UnsafeMutableRawPointer(echo))
        setControl(state, SPEEX_PREPROCESS_SET_ECHO_SUPPRESS, Int32(c.echoSuppressDb))
        setControl(state, SPEEX_PREPROCESS_SET_ECHO_SUPPRESS_ACTIVE, Int32(c.echoSuppressActiveDb))
        // Speex applies its residual-echo gain only while the denoiser runs
        // (preprocess.c overwrites the gain with 1 when SET_DENOISE is 0), so
        // the denoiser stays on. With noiseSuppression == false its noise floor
        // is 0 dB, i.e. it does not attenuate noise, only residual echo.
        setControl(state, SPEEX_PREPROCESS_SET_DENOISE, 1)
        setControl(state, SPEEX_PREPROCESS_SET_NOISE_SUPPRESS, c.noiseSuppression ? -15 : 0)
        setControl(state, SPEEX_PREPROCESS_SET_AGC, 0)
        setControl(state, SPEEX_PREPROCESS_SET_VAD, 0)
        setControl(state, SPEEX_PREPROCESS_SET_DEREVERB, 0)
        return state
    }

    private static func setControl(_ state: OpaquePointer, _ request: Int32, _ value: Int32) {
        var v = value
        _ = speex_preprocess_ctl(state, request, &v)
    }
}
