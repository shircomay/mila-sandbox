/// A fixed-frame-size acoustic echo canceller: removes the echo of a known
/// far-end (reference) signal from a near-end (microphone) signal.
///
/// The backend knows nothing about time: every call receives a microphone
/// frame and the reference samples that were played at the same moment
/// (already aligned by ``EchoCancellationStage``). It is not thread-safe.
public protocol EchoCancellerBackend: AnyObject {
    /// Samples per call (10 ms at the configured rate).
    var frameSize: Int { get }

    /// Cancel `far`'s echo from `near`. Each pointer addresses exactly
    /// `frameSize` Float samples in [-1, 1]. `out` may not alias the inputs.
    func process(near: UnsafePointer<Float>, far: UnsafePointer<Float>,
                 out: UnsafeMutablePointer<Float>)

    /// Forget everything learned (new echo path).
    func reset()

    /// Diagnostics: estimated echo delay in milliseconds from the adaptive
    /// filter's strongest tap, or nil if not available / not converged.
    ///
    /// The value is the lag between the far-end samples passed to `process`
    /// and their echo in `near`, so it includes whatever lead the caller
    /// applied to the reference (``EchoCancellationStage`` feeds the reference
    /// `referenceLeadMs` ahead; subtract that to get the delay on the shared
    /// timeline).
    func estimatedEchoDelayMs() -> Double?

    /// Algorithmic latency, in samples: the output of `process` for frame k
    /// carries the cleaned samples of frame k - latency/frameSize. A backend
    /// with a latency delays its output stream; ``EchoCancellationStage``
    /// compensates (drops the first `latencySamples` output samples and drains
    /// the same number of samples at `flush()`), so its callers never see it.
    ///
    /// Additive to the contract in docs/fork/designs/02-aec-core.md: it has a
    /// default implementation (0), so other conformers compile unchanged.
    var latencySamples: Int { get }
}

extension EchoCancellerBackend {
    /// Default: no algorithmic latency.
    public var latencySamples: Int { 0 }
}
