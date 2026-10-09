import Foundation
import AVFoundation
import CoreMedia

/// FIFO of per-buffer host timestamps, filled by a capture callback right
/// before it yields a buffer and drained by the consumer as it receives the
/// same buffers, in the same order. Lock-protected; bounded.
///
/// FORK (echo cancellation, spec 03). Acoustic echo cancellation has to know
/// WHEN each microphone buffer and each app-audio buffer was captured, on one
/// shared clock, because `RecordingSession` otherwise pairs the two streams by
/// arrival order — and ScreenCaptureKit delivers nothing while the app is
/// silent, so the mic/app offset jumps every time the far end goes quiet.
/// `AsyncStream<AVAudioPCMBuffer>` carries no per-element metadata and the
/// stream types are shared with code that must not change, so the timestamp
/// travels beside the buffer: the producer pushes one entry per yielded buffer
/// (immediately BEFORE `yield`), the consumer pops one entry per received
/// buffer (as the FIRST thing it does, before any early-return gate). Both
/// sides are strictly FIFO, so the n-th pop describes the n-th buffer.
///
/// Disabled by default: `push` is then a no-op, so nothing accumulates for
/// recordings that don't use echo cancellation and the existing capture paths
/// behave exactly as they did before this file existed.
///
/// An entry is `Double?` because a buffer can arrive without a usable
/// timestamp; a `nil` entry still occupies its slot, which is what keeps the
/// queue aligned with the stream. `pop()` returns `nil` both for such an entry
/// and for an empty queue — a consumer treats both as "no timestamp".
final class CaptureTimestampQueue: @unchecked Sendable {
    private let lock = NSLock()
    private let capacity: Int
    private var ring: [Double?]
    /// Index of the oldest entry.
    private var head = 0
    /// Number of live entries.
    private var size = 0
    private var enabled = false
    private var overflows = 0

    /// `capacity` is clamped to at least 1. The default holds ~5.8 minutes of
    /// mic buffers (~85 ms each) or ~82 s of ScreenCaptureKit buffers (~20 ms
    /// each): the consumer runs on the main actor and pops every buffer as it
    /// is delivered, so a backlog that large means the app itself is hung.
    init(capacity: Int = 4096) {
        let bounded = max(1, capacity)
        self.capacity = bounded
        self.ring = [Double?](repeating: nil, count: bounded)
    }

    /// Whether `push` records anything. Set by `RecordingSession` for the
    /// recordings that run echo cancellation; the producer reads it on every
    /// call, so flipping it takes effect on the next buffer.
    var isEnabled: Bool {
        get {
            lock.lock()
            defer { lock.unlock() }
            return enabled
        }
        set {
            lock.lock()
            defer { lock.unlock() }
            enabled = newValue
        }
    }

    /// Entries currently queued (diagnostics and tests).
    var pendingCount: Int {
        lock.lock()
        defer { lock.unlock() }
        return size
    }

    /// Entries discarded because the queue was full since the last `reset()`.
    /// Non-zero means the consumer fell so far behind that timestamps no longer
    /// line up with buffers, which a caller may want to report.
    var overflowCount: Int {
        lock.lock()
        defer { lock.unlock() }
        return overflows
    }

    /// Producer side. Records `hostTimeSeconds` (nil = the buffer has no usable
    /// timestamp) when enabled; does nothing otherwise. When full, the OLDEST
    /// entry is dropped so the queue always describes the most recent buffers.
    func push(_ hostTimeSeconds: Double?) {
        lock.lock()
        defer { lock.unlock() }
        guard enabled else { return }
        if size == capacity {
            ring[head] = nil
            head = (head + 1) % capacity
            size -= 1
            overflows += 1
        }
        ring[(head + size) % capacity] = hostTimeSeconds
        size += 1
    }

    /// Consumer side. Removes and returns the oldest entry; nil when the queue
    /// is empty (or the oldest entry was a buffer without a timestamp).
    func pop() -> Double? {
        lock.lock()
        defer { lock.unlock() }
        guard size > 0 else { return nil }
        let value = ring[head]
        ring[head] = nil
        head = (head + 1) % capacity
        size -= 1
        return value
    }

    /// Drop every queued entry and clear the overflow count. Does not change
    /// `isEnabled`.
    func reset() {
        lock.lock()
        defer { lock.unlock() }
        for i in 0..<capacity { ring[i] = nil }
        head = 0
        size = 0
        overflows = 0
    }
}

// MARK: - Clock conversions

extension CaptureTimestampQueue {
    /// Host time (seconds, the mach host clock) at which the first sample of
    /// an `AVAudioEngine` tap buffer was captured; nil when the tap did not
    /// supply a valid host time. Safe to call on the audio thread.
    static func hostTimeSeconds(of time: AVAudioTime) -> Double? {
        time.isHostTimeValid ? AVAudioTime.seconds(forHostTime: time.hostTime) : nil
    }

    /// Host time (seconds) of a ScreenCaptureKit audio sample buffer's first
    /// sample, from its presentation timestamp; nil when the timestamp is
    /// invalid or not a finite number.
    ///
    /// ScreenCaptureKit stamps its sample buffers on the host time clock
    /// (`CMClockGetHostTimeClock`), the same mach clock `AVAudioTime`'s host
    /// time uses, so no offset is applied. That is an assumption about a system
    /// framework, not a contract this code can enforce: `RecordingSession`
    /// verifies it at runtime (the mic and app streams' clocks must agree to
    /// within seconds) and falls back to arrival order if they don't.
    static func hostTimeSeconds(of sampleBuffer: CMSampleBuffer) -> Double? {
        hostTimeSeconds(ofPresentationTime: CMSampleBufferGetPresentationTimeStamp(sampleBuffer))
    }

    /// The conversion behind `hostTimeSeconds(of: CMSampleBuffer)`, split out so
    /// it can be tested without constructing a sample buffer.
    static func hostTimeSeconds(ofPresentationTime pts: CMTime) -> Double? {
        guard pts.isValid, pts.isNumeric else { return nil }
        let seconds = CMTimeGetSeconds(pts)
        return seconds.isFinite ? seconds : nil
    }
}
