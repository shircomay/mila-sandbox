import Foundation

/// Cancels the meeting app's audio (the reference) out of the microphone
/// signal, aligning the two streams by host time.
///
/// Why host time: Mila pairs microphone and app audio by arrival order, and
/// ScreenCaptureKit stops delivering buffers while the app is silent, so the
/// mic/app offset jumps every time the far end goes quiet. An adaptive echo
/// filter cannot track that. This stage places both streams on one integer
/// sample timeline (position p <-> host time t0 + p / sampleRate), feeds the
/// reference to the backend at the position the microphone frame was
/// *captured*, and treats spans where the reference never arrived as silence.
///
/// Per stream the stage keeps a predicted position for the next sample and
/// follows the sample count, not the timestamp jitter; a timestamp further than
/// `reanchorToleranceMs` from the prediction re-anchors the stream (gap,
/// overlap, device change).
///
/// Microphone samples are held in a FIFO and processed in whole backend frames
/// as soon as the reference for the frame has arrived, or after `holdMs`. They
/// are never inserted, dropped or reordered: across a session (including
/// `flush()`) the total output length equals the total input length.
///
/// Not thread-safe: the caller serialises all calls (the app calls from the
/// main actor). Not `Sendable`.
public final class EchoCancellationStage {
    public struct Configuration: Equatable, Sendable {
        public var sampleRate: Double = 16_000
        /// Max time a mic frame waits for its reference to arrive.
        public var holdMs: Double = 150
        /// Feed the reference this far AHEAD of mic time, so a reference
        /// timestamp that is slightly late is still causal for the filter.
        public var referenceLeadMs: Double = 30
        /// A timestamp further than this from the sample-count prediction
        /// re-anchors the stream (gap, overlap, device change).
        public var reanchorToleranceMs: Double = 20
        /// Reference history retained (ring buffer length). Clamped to 1...60 s.
        public var referenceRetentionSeconds: Double = 10
        public var backend: SpeexEchoCanceller.Configuration = .init()

        public init() {}
    }

    public struct Statistics: Equatable, Sendable {
        public var framesProcessed: Int = 0
        /// Far frame had any non-zero sample.
        public var framesWithReference: Int = 0
        /// Processed on hold timeout with missing reference.
        public var framesHeldTooLong: Int = 0
        public var micReanchors: Int = 0
        public var referenceReanchors: Int = 0
        /// Arrived too late (after the mic frame that needed them was processed) or beyond retention.
        public var referenceSamplesDiscarded: Int = 0
        /// Rolling ERLE over far-active frames that do not look like double talk.
        public var echoReductionDb: Double?
        /// From the backend: lag of the filter's strongest tap behind the reference
        /// the backend was fed. Includes `referenceLeadMs`; subtract it for the
        /// echo delay on the shared timeline.
        public var estimatedEchoDelayMs: Double?
        /// First mic timestamp minus first reference timestamp, in ms.
        public var initialMicToReferenceOffsetMs: Double?

        public init() {}
    }

    public let configuration: Configuration
    public private(set) var statistics = Statistics()

    /// Debug tap: called once per processed frame with copies of near, the
    /// aligned far frame actually used, and the output. nil by default; only
    /// set it for debug dumps (it allocates per frame). `out` is the backend's
    /// raw output for that call, which for a backend with `latencySamples > 0`
    /// is delayed by that many samples relative to `near`.
    public var frameObserver: ((_ near: [Float], _ far: [Float], _ out: [Float]) -> Void)?

    // Timestamps further than this from t0 (in samples) are ignored as absurd.
    private static let maxTimestampSpanSamples = 4.0e15
    // Far frames below this mean square (about -60 dBFS RMS) are not "far-active".
    private static let farActiveMeanSquare = 1e-6
    private static let statisticsRefreshFrames = 50
    // Upper bound on frames fed to drain the backend's latency at flush.
    private static let maxDrainFrames = 64

    private let backend: EchoCancellerBackend
    private let sampleRate: Double
    private let frameSize: Int
    private let latency: Int
    private let leadSamples: Int
    private let toleranceSamples: Int
    private let holdSamples: Int

    // Timeline.
    private var t0: Double?
    private var micTimeline = StreamTimeline()
    private var referenceTimeline = StreamTimeline()
    private var ring: ReferenceRing
    /// End (exclusive) of the reference span read by the most recent frame; reference
    /// arriving below it came too late to be used. nil after a mic re-anchor/reset.
    private var consumedReferenceEnd: Int?

    // Microphone side.
    private var micQueue = MicQueue()
    private var totalIn = 0
    private var totalReturned = 0
    /// Backend output that is ready but not yet handed to the caller.
    private var produced: [Float] = []
    /// Output samples still to drop to compensate the backend's latency.
    private var skipRemaining: Int
    /// Output flushed by `resetTimeline`, handed out by the next call.
    private var carry: [Float] = []

    // Preallocated frame buffers.
    private let nearFrame: UnsafeMutablePointer<Float>
    private let farFrame: UnsafeMutablePointer<Float>
    private let outFrame: UnsafeMutablePointer<Float>

    private var reduction = EchoReductionTracker()
    private var framesSinceRefresh = 0

    /// `backend` nil -> a SpeexEchoCanceller with `configuration.backend`.
    /// Returns nil only if the backend cannot be created.
    public init?(configuration: Configuration = .init(), backend: EchoCancellerBackend? = nil) {
        let resolved: EchoCancellerBackend
        if let backend {
            resolved = backend
        } else if let speex = SpeexEchoCanceller(configuration: configuration.backend) {
            resolved = speex
        } else {
            return nil
        }
        let frameSize = resolved.frameSize
        let sampleRate = configuration.sampleRate
        guard frameSize > 0, sampleRate.isFinite, sampleRate > 0 else { return nil }

        let lead = EchoCancellationStage.samples(ms: configuration.referenceLeadMs, sampleRate: sampleRate, limit: 10_000)
        let tolerance = EchoCancellationStage.samples(ms: configuration.reanchorToleranceMs, sampleRate: sampleRate, limit: 10_000)
        let hold = EchoCancellationStage.samples(ms: configuration.holdMs, sampleRate: sampleRate, limit: 10_000)
        let retention = EchoCancellationStage.samples(ms: configuration.referenceRetentionSeconds * 1000,
                                                      sampleRate: sampleRate, limit: 60_000)
        let latency = max(0, resolved.latencySamples)

        self.configuration = configuration
        self.backend = resolved
        self.sampleRate = sampleRate
        self.frameSize = frameSize
        self.latency = latency
        self.leadSamples = lead
        self.toleranceSamples = max(1, tolerance)
        self.holdSamples = max(frameSize, hold)
        self.ring = ReferenceRing(capacity: max(retention, 4 * (lead + frameSize)))
        self.skipRemaining = latency

        let near = UnsafeMutablePointer<Float>.allocate(capacity: frameSize)
        near.initialize(repeating: 0, count: frameSize)
        let far = UnsafeMutablePointer<Float>.allocate(capacity: frameSize)
        far.initialize(repeating: 0, count: frameSize)
        let out = UnsafeMutablePointer<Float>.allocate(capacity: frameSize)
        out.initialize(repeating: 0, count: frameSize)
        self.nearFrame = near
        self.farFrame = far
        self.outFrame = out
    }

    deinit {
        nearFrame.deallocate()
        farFrame.deallocate()
        outFrame.deallocate()
    }

    /// Milliseconds -> whole samples, rounded, clamped to 0...limit-in-ms worth of samples.
    private static func samples(ms: Double, sampleRate: Double, limit: Double) -> Int {
        guard ms.isFinite else { return 0 }
        let clamped = min(max(ms, 0), limit)
        return Int((clamped * sampleRate / 1000).rounded())
    }

    // MARK: - Reference (far-end) audio

    /// Far-end (app) audio. `hostTimeSeconds` = time of `samples[0]` on the
    /// shared monotonic host clock; nil = contiguous with the previous call.
    public func appendReference(_ samples: [Float], hostTimeSeconds: Double?) {
        let placement = place(hostTimeSeconds, on: referenceTimeline)
        referenceTimeline = placement.timeline
        if placement.reanchored {
            statistics.referenceReanchors += 1
        }
        if placement.firstTimestamp {
            updateInitialOffset()
        }
        guard !samples.isEmpty else { return }

        let start = referenceTimeline.next
        referenceTimeline.next += samples.count
        let result = ring.write(samples, at: start)
        statistics.referenceSamplesDiscarded += result.dropped
        if let consumed = consumedReferenceEnd, result.storedStart < consumed {
            // Arrived after the mic frame that needed it was processed.
            let late = min(start + samples.count, consumed) - result.storedStart
            if late > 0 {
                statistics.referenceSamplesDiscarded += late
            }
        }
    }

    // MARK: - Microphone (near-end) audio

    /// Near-end (mic) audio. Returns cleaned mic samples that are ready, in
    /// order. May return fewer or more samples than passed (held frames), but
    /// across the whole session (including `flush()`) total output length ==
    /// total input length, and output order == input order. Never inserts or
    /// drops mic samples.
    public func processMicrophone(_ samples: [Float], hostTimeSeconds: Double?) -> [Float] {
        let placement = place(hostTimeSeconds, on: micTimeline)
        micTimeline = placement.timeline
        if placement.reanchored {
            statistics.micReanchors += 1
            consumedReferenceEnd = nil
        }
        if placement.firstTimestamp {
            updateInitialOffset()
        }
        if !samples.isEmpty {
            micQueue.append(samples, at: micTimeline.next)
            micTimeline.next += samples.count
            totalIn += samples.count
        }
        drainQueue(flushing: false)
        return takeProduced(count: produced.count)
    }

    /// Process everything still held, treating missing reference as silence.
    /// Returns exactly the held samples' count (partial last frame zero-padded
    /// internally, padding dropped from the output). For a backend with
    /// latency that is the held samples plus the samples still inside the
    /// backend, so that the session total stays input == output.
    public func flush() -> [Float] {
        drainQueue(flushing: true)
        let owed = totalIn - totalReturned
        var result: [Float] = []
        if owed > 0 {
            // Push silence through to drain the backend's algorithmic latency.
            nearFrame.update(repeating: 0, count: frameSize)
            farFrame.update(repeating: 0, count: frameSize)
            var guardFrames = 0
            while produced.count < owed && guardFrames < EchoCancellationStage.maxDrainFrames {
                runBackend(accountStatistics: false)
                guardFrames += 1
            }
            result = takeProduced(count: owed)
        }
        produced.removeAll(keepingCapacity: true)   // padding beyond what is owed
        skipRemaining = latency                      // the next segment starts a fresh pipeline
        refreshStatistics()
        return withCarry(result)
    }

    /// Drop timeline anchors and pending reference (after pause/resume or a
    /// capture restart). Held mic samples must be flushed by the caller first
    /// (if they are not, they are flushed here and returned by the next call,
    /// so nothing is lost). `resetFilter: true` also resets the backend (echo
    /// path changed).
    public func resetTimeline(resetFilter: Bool) {
        carry = flush()
        t0 = nil
        micTimeline = StreamTimeline()
        referenceTimeline = StreamTimeline()
        ring.removeAll()
        consumedReferenceEnd = nil
        micQueue.removeAll()
        if resetFilter {
            backend.reset()
            reduction.reset()
            statistics.echoReductionDb = nil
            statistics.estimatedEchoDelayMs = nil
        }
        skipRemaining = latency
    }

    // MARK: - Timeline

    private struct Placement {
        var timeline: StreamTimeline
        var reanchored = false
        /// This call carried the stream's first usable timestamp.
        var firstTimestamp = false
    }

    private func place(_ timestamp: Double?, on timeline: StreamTimeline) -> Placement {
        var result = Placement(timeline: timeline)
        guard let ts = timestamp, ts.isFinite else { return result }   // contiguous
        if t0 == nil {
            // The first timestamp anywhere defines the time origin; choose it so
            // that this stream's current position maps to this timestamp.
            t0 = ts - Double(timeline.next) / sampleRate
        }
        let origin = t0 ?? ts
        let span = (ts - origin) * sampleRate
        guard span.isFinite, abs(span) <= EchoCancellationStage.maxTimestampSpanSamples else {
            return result    // absurd timestamp: ignore it, keep counting samples
        }
        let measured = Int(span.rounded())
        if !result.timeline.hasTimestamp {
            result.timeline.hasTimestamp = true
            result.timeline.firstTimestamp = ts
            result.timeline.next = measured
            result.firstTimestamp = true
        } else if abs(measured - result.timeline.next) > toleranceSamples {
            result.timeline.next = measured
            result.reanchored = true
        }
        return result
    }

    private func updateInitialOffset() {
        if let mic = micTimeline.firstTimestamp, let reference = referenceTimeline.firstTimestamp {
            statistics.initialMicToReferenceOffsetMs = (mic - reference) * 1000
        }
    }

    // MARK: - Frame processing

    /// Processes whole frames from the head of the mic queue while the
    /// reference for the frame has arrived, or it has waited `holdMs`.
    private func drainQueue(flushing: Bool) {
        while true {
            let queued = micQueue.count
            if queued == 0 { break }
            if queued < frameSize && !flushing { break }
            guard let position = micQueue.firstPosition else { break }
            var ready = false
            if let high = ring.highWater {
                ready = high >= position + leadSamples + frameSize
            }
            let waited = queued >= holdSamples
            if !(ready || waited || flushing) { break }
            processHeldFrame(at: position, referenceReady: ready)
        }
    }

    private func processHeldFrame(at position: Int, referenceReady: Bool) {
        _ = micQueue.pop(into: nearFrame, max: frameSize)
        ring.read(from: position + leadSamples, count: frameSize, into: farFrame)
        var hasReference = false
        var i = 0
        while i < frameSize {
            if farFrame[i] != 0 {
                hasReference = true
                break
            }
            i += 1
        }
        if hasReference {
            statistics.framesWithReference += 1
        } else if !referenceReady {
            statistics.framesHeldTooLong += 1
        }
        runBackend(accountStatistics: true)
        consumedReferenceEnd = position + leadSamples + frameSize
    }

    /// Runs the backend on nearFrame/farFrame -> outFrame and queues the output.
    private func runBackend(accountStatistics: Bool) {
        backend.process(near: nearFrame, far: farFrame, out: outFrame)
        statistics.framesProcessed += 1
        if let observer = frameObserver {
            observer(copyOfFrame(nearFrame), copyOfFrame(farFrame), copyOfFrame(outFrame))
        }
        if accountStatistics {
            account()
        }
        // Compensate the backend's latency: its first `latency` output samples
        // of a pipeline carry no input yet.
        var skip = 0
        if skipRemaining > 0 {
            skip = min(skipRemaining, frameSize)
            skipRemaining -= skip
        }
        if skip < frameSize {
            produced.append(contentsOf: UnsafeBufferPointer(start: UnsafePointer(outFrame + skip),
                                                            count: frameSize - skip))
        }
    }

    private func copyOfFrame(_ frame: UnsafeMutablePointer<Float>) -> [Float] {
        return Array(UnsafeBufferPointer(start: UnsafePointer(frame), count: frameSize))
    }

    /// Removes and returns the first `count` produced samples.
    private func takeProduced(count: Int) -> [Float] {
        let n = min(count, produced.count)
        let result: [Float]
        if n == produced.count {
            result = produced
            produced.removeAll(keepingCapacity: true)
        } else {
            result = Array(produced[0..<n])
            produced.removeFirst(n)
        }
        totalReturned += n
        return withCarry(result)
    }

    private func withCarry(_ result: [Float]) -> [Float] {
        guard !carry.isEmpty else { return result }
        let joined = carry + result
        carry.removeAll()
        return joined
    }

    // MARK: - Statistics

    private func account() {
        var nearEnergy = 0.0
        var farEnergy = 0.0
        var outEnergy = 0.0
        var i = 0
        while i < frameSize {
            let n = Double(nearFrame[i])
            let f = Double(farFrame[i])
            let o = Double(outFrame[i])
            nearEnergy += n * n
            farEnergy += f * f
            outEnergy += o * o
            i += 1
        }
        if farEnergy > EchoCancellationStage.farActiveMeanSquare * Double(frameSize) && nearEnergy > 0 {
            reduction.add(nearEnergy: nearEnergy, farEnergy: farEnergy, outEnergy: outEnergy)
        }
        framesSinceRefresh += 1
        if framesSinceRefresh >= EchoCancellationStage.statisticsRefreshFrames {
            refreshStatistics()
        }
    }

    private func refreshStatistics() {
        framesSinceRefresh = 0
        if let reductionDb = reduction.reductionDb() {
            statistics.echoReductionDb = reductionDb
        }
        statistics.estimatedEchoDelayMs = backend.estimatedEchoDelayMs()
    }
}
