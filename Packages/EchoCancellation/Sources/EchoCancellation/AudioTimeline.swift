// Internal building blocks of EchoCancellationStage: the shared sample
// timeline's per-stream state, the reference ring buffer, the held-microphone
// queue and the rolling ERLE tracker. Everything here is plain value-type code
// with no knowledge of the backend; it is covered by AudioTimelineTests.
//
// Positions are integer sample indices on one timeline: position p <-> host
// time t0 + p / sampleRate (t0 = host time of the first timestamped sample on
// either stream). Positions may be negative or huge (an absurd timestamp
// basis); nothing here allocates in proportion to a position.

import Foundation

/// Per-stream bookkeeping for the shared timeline.
struct StreamTimeline {
    /// Predicted position of the next incoming sample.
    var next = 0
    /// True once a usable timestamp has anchored this stream.
    var hasTimestamp = false
    /// Raw host time of the first timestamped append.
    var firstTimestamp: Double?
}

// MARK: - Reference ring

/// Ring buffer of reference (far-end) audio addressed by absolute timeline
/// position. Positions never written, positions beyond the highest written one
/// and positions older than the retained window all read as silence.
struct ReferenceRing {
    struct WriteResult: Equatable {
        /// Samples dropped because they were older than the retained window.
        var dropped: Int
        /// Position of the first stored sample (start + dropped).
        var storedStart: Int
    }

    let capacity: Int
    /// One past the highest position ever written; nil until the first write.
    private(set) var highWater: Int?
    private var storage: [Float]

    init(capacity: Int) {
        precondition(capacity > 0)
        self.capacity = capacity
        self.storage = [Float](repeating: 0, count: capacity)
    }

    mutating func removeAll() {
        storage.withUnsafeMutableBufferPointer { buffer in
            guard let base = buffer.baseAddress else { return }
            base.update(repeating: 0, count: buffer.count)
        }
        highWater = nil
    }

    /// Writes `samples` at `start`. Overwrites on overlap (a backward
    /// re-anchor); a forward jump leaves the skipped span silent.
    mutating func write(_ samples: [Float], at start: Int) -> WriteResult {
        let count = samples.count
        guard count > 0 else { return WriteResult(dropped: 0, storedStart: start) }
        let end = start + count
        let previousHigh = highWater ?? start
        let newHigh = Swift.max(previousHigh, end)
        let windowStart = newHigh - capacity
        if end <= windowStart {
            // Entirely older than the retained window.
            if highWater == nil { highWater = previousHigh }
            return WriteResult(dropped: count, storedStart: end)
        }
        var from = start
        var offset = 0
        if from < windowStart {
            offset = windowStart - from
            from = windowStart
        }
        if from > previousHigh {
            // Skipped span reads as silence, not as stale audio from `capacity` ago.
            if from - previousHigh >= capacity {
                zero(from: 0, to: capacity)   // the whole ring
            } else {
                zero(from: previousHigh, to: from)
            }
        }
        copyIn(samples, fromOffset: offset, at: from)
        highWater = newHigh
        return WriteResult(dropped: offset, storedStart: from)
    }

    /// Copies `count` samples starting at `position` into `destination`;
    /// anything not stored reads as 0.
    func read(from position: Int, count: Int, into destination: UnsafeMutablePointer<Float>) {
        destination.update(repeating: 0, count: count)
        guard let high = highWater else { return }
        let lo = Swift.max(position, high - capacity)
        let hi = Swift.min(position + count, high)
        guard lo < hi else { return }
        var ringIndex = ReferenceRing.wrap(lo, capacity)
        var written = lo - position
        var remaining = hi - lo
        let cap = capacity
        storage.withUnsafeBufferPointer { source in
            guard let base = source.baseAddress else { return }
            while remaining > 0 {
                let run = Swift.min(remaining, cap - ringIndex)
                (destination + written).update(from: base + ringIndex, count: run)
                written += run
                remaining -= run
                ringIndex = 0
            }
        }
    }

    // MARK: private

    private static func wrap(_ position: Int, _ capacity: Int) -> Int {
        let r = position % capacity
        return r < 0 ? r + capacity : r
    }

    private mutating func zero(from lo: Int, to hi: Int) {
        var remaining = hi - lo
        guard remaining > 0 else { return }
        var ringIndex = ReferenceRing.wrap(lo, capacity)
        let cap = capacity
        storage.withUnsafeMutableBufferPointer { dest in
            guard let base = dest.baseAddress else { return }
            while remaining > 0 {
                let run = Swift.min(remaining, cap - ringIndex)
                (base + ringIndex).update(repeating: 0, count: run)
                remaining -= run
                ringIndex = 0
            }
        }
    }

    private mutating func copyIn(_ samples: [Float], fromOffset offset: Int, at position: Int) {
        var remaining = samples.count - offset
        guard remaining > 0 else { return }
        var ringIndex = ReferenceRing.wrap(position, capacity)
        var source = offset
        let cap = capacity
        storage.withUnsafeMutableBufferPointer { dest in
            samples.withUnsafeBufferPointer { src in
                guard let destBase = dest.baseAddress, let srcBase = src.baseAddress else { return }
                while remaining > 0 {
                    let run = Swift.min(remaining, cap - ringIndex)
                    (destBase + ringIndex).update(from: srcBase + source, count: run)
                    source += run
                    remaining -= run
                    ringIndex = 0
                }
            }
        }
    }
}

// MARK: - Held microphone samples

/// FIFO of microphone samples that also remembers each sample's timeline
/// position, run-length encoded: consecutive appends that are contiguous on the
/// timeline share a segment, a re-anchor starts a new one. Samples are never
/// inserted, dropped or reordered; only the positions used to look up the
/// reference change.
struct MicQueue {
    private struct Segment {
        var start: Int
        var count: Int
    }

    private var samples: [Float] = []
    private var head = 0
    private var segments: [Segment] = []

    var count: Int { samples.count - head }

    /// Timeline position of the oldest held sample.
    var firstPosition: Int? { segments.first?.start }

    mutating func append(_ new: [Float], at position: Int) {
        guard !new.isEmpty else { return }
        if head > 0 && head >= samples.count / 2 {
            samples.removeFirst(head)
            head = 0
        }
        samples.append(contentsOf: new)
        if let last = segments.last, last.start + last.count == position {
            segments[segments.count - 1].count += new.count
        } else {
            segments.append(Segment(start: position, count: new.count))
        }
    }

    /// Removes up to `max` samples from the front into `destination`
    /// (zero-padded to `max`). Returns the number of real samples removed.
    /// A frame may straddle two segments; it is identified by its first sample.
    mutating func pop(into destination: UnsafeMutablePointer<Float>, max: Int) -> Int {
        let taken = Swift.min(max, count)
        if taken > 0 {
            let start = head
            samples.withUnsafeBufferPointer { source in
                if let base = source.baseAddress {
                    destination.update(from: base + start, count: taken)
                }
            }
        }
        if taken < max {
            (destination + taken).update(repeating: 0, count: max - taken)
        }
        head += taken
        var remaining = taken
        while remaining > 0, !segments.isEmpty {
            let take = Swift.min(remaining, segments[0].count)
            segments[0].start += take
            segments[0].count -= take
            remaining -= take
            if segments[0].count == 0 {
                segments.removeFirst()
            }
        }
        if head == samples.count {
            samples.removeAll(keepingCapacity: true)
            head = 0
        }
        return taken
    }

    mutating func removeAll() {
        samples.removeAll(keepingCapacity: true)
        head = 0
        segments.removeAll(keepingCapacity: true)
    }
}

// MARK: - Rolling ERLE

/// Rolling echo return loss enhancement over the last ~5 s of far-active
/// frames that do not look like double talk.
///
/// Diagnostic only (it never gates processing). For every far-active frame the
/// near/far energy ratio is recorded; a frame counts as echo-only when its
/// ratio is at most 4x (6 dB above) the window's median ratio, i.e. the
/// microphone is not much louder than the typical echo coupling would explain,
/// which excludes frames dominated by near-end speech. ERLE is then
/// 10 log10(sum near^2 / sum out^2) over those frames.
struct EchoReductionTracker {
    static let windowFrames = 500        // ~5 s at 10 ms frames
    static let minimumFrames = 100       // ~1 s before a value is reported
    static let doubleTalkRatio = 4.0

    private struct Entry {
        var near: Double
        var far: Double
        var out: Double
    }

    private var entries: [Entry] = []
    private var nextIndex = 0

    mutating func add(nearEnergy: Double, farEnergy: Double, outEnergy: Double) {
        let entry = Entry(near: nearEnergy, far: farEnergy, out: outEnergy)
        if entries.count < EchoReductionTracker.windowFrames {
            entries.append(entry)
        } else {
            entries[nextIndex] = entry
            nextIndex = (nextIndex + 1) % EchoReductionTracker.windowFrames
        }
    }

    mutating func reset() {
        entries.removeAll(keepingCapacity: true)
        nextIndex = 0
    }

    /// nil until `minimumFrames` far-active frames have been seen.
    func reductionDb() -> Double? {
        guard entries.count >= EchoReductionTracker.minimumFrames else { return nil }
        var ratios = [Double]()
        ratios.reserveCapacity(entries.count)
        for entry in entries {
            ratios.append(entry.near / entry.far)
        }
        ratios.sort()
        let median = ratios[ratios.count / 2]
        var nearSum = 0.0
        var outSum = 0.0
        for entry in entries where entry.near <= EchoReductionTracker.doubleTalkRatio * median * entry.far {
            nearSum += entry.near
            outSum += entry.out
        }
        guard nearSum > 0, outSum > 0 else { return nil }
        return 10 * log10(nearSum / outSum)
    }
}
