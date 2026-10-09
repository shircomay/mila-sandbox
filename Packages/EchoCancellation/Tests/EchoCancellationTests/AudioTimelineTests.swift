import Foundation
import XCTest
@testable import EchoCancellation

/// The internal building blocks of EchoCancellationStage, tested directly.
final class AudioTimelineTests: XCTestCase {
    // MARK: ReferenceRing

    private func read(_ ring: ReferenceRing, _ position: Int, _ count: Int) -> [Float] {
        var out = [Float](repeating: -99, count: count)
        out.withUnsafeMutableBufferPointer { buffer in
            ring.read(from: position, count: count, into: buffer.baseAddress!)
        }
        return out
    }

    private func ramp(_ count: Int, from first: Float = 1) -> [Float] {
        return (0..<count).map { first + Float($0) }
    }

    func test_ring_contiguousWriteAndRead() {
        var ring = ReferenceRing(capacity: 100)
        XCTAssertNil(ring.highWater)
        XCTAssertEqual(read(ring, 0, 5), [0, 0, 0, 0, 0], "nothing written yet reads as silence")

        let samples = ramp(60)
        let result = ring.write(samples, at: 0)
        XCTAssertEqual(result, ReferenceRing.WriteResult(dropped: 0, storedStart: 0))
        XCTAssertEqual(ring.highWater, 60)
        XCTAssertEqual(read(ring, 0, 60), samples)
        XCTAssertEqual(read(ring, 50, 20), Array(samples[50...]) + [Float](repeating: 0, count: 10),
                       "beyond the highest written position reads as silence")
        XCTAssertEqual(read(ring, -5, 8), [0, 0, 0, 0, 0, 1, 2, 3])
    }

    func test_ring_skippedSpanReadsAsSilence_notAsStaleAudio() {
        var ring = ReferenceRing(capacity: 100)
        _ = ring.write([Float](repeating: 1, count: 100), at: 0)
        // 50 samples skipped (the reference stream was silent), then 10 more.
        let result = ring.write([Float](repeating: 2, count: 10), at: 150)
        XCTAssertEqual(result.dropped, 0)
        XCTAssertEqual(ring.highWater, 160)
        XCTAssertEqual(read(ring, 100, 50), [Float](repeating: 0, count: 50), "the gap cells held positions 0..<50 before")
        XCTAssertEqual(read(ring, 150, 10), [Float](repeating: 2, count: 10))
        XCTAssertEqual(read(ring, 60, 40), [Float](repeating: 1, count: 40), "still inside the retained window [60, 160)")
        XCTAssertEqual(read(ring, 50, 10), [Float](repeating: 0, count: 10), "older than the window")
    }

    func test_ring_jumpBeyondTheWindowClearsEverything() {
        var ring = ReferenceRing(capacity: 100)
        _ = ring.write([Float](repeating: 1, count: 100), at: 0)
        _ = ring.write(ramp(10), at: 1_000)
        XCTAssertEqual(ring.highWater, 1_010)
        XCTAssertEqual(read(ring, 1_000, 10), ramp(10))
        XCTAssertEqual(read(ring, 910, 90), [Float](repeating: 0, count: 90))
        XCTAssertEqual(read(ring, 0, 100), [Float](repeating: 0, count: 100))
    }

    func test_ring_backwardRewriteOverwrites() {
        var ring = ReferenceRing(capacity: 100)
        _ = ring.write([Float](repeating: 1, count: 100), at: 0)
        let result = ring.write([Float](repeating: 3, count: 20), at: 40)
        XCTAssertEqual(result, ReferenceRing.WriteResult(dropped: 0, storedStart: 40))
        XCTAssertEqual(ring.highWater, 100)
        XCTAssertEqual(read(ring, 30, 40), [Float](repeating: 1, count: 10) + [Float](repeating: 3, count: 20) + [Float](repeating: 1, count: 10))
    }

    func test_ring_samplesOlderThanTheWindowAreDroppedAndCounted() {
        var ring = ReferenceRing(capacity: 100)
        _ = ring.write(ramp(500), at: 0)                 // window is now [400, 500)
        XCTAssertEqual(read(ring, 0, 400), [Float](repeating: 0, count: 400))
        XCTAssertEqual(read(ring, 400, 100), Array(ramp(500)[400...]))

        // entirely older than the window
        let old = ring.write(ramp(50), at: 100)
        XCTAssertEqual(old.dropped, 50)
        XCTAssertEqual(ring.highWater, 500)
        // straddling the window start: 20 dropped, 20 stored
        let partial = ring.write([Float](repeating: 7, count: 40), at: 380)
        XCTAssertEqual(partial, ReferenceRing.WriteResult(dropped: 20, storedStart: 400))
        XCTAssertEqual(read(ring, 395, 30), [Float](repeating: 0, count: 5) + [Float](repeating: 7, count: 20) + Array(ramp(500)[420..<425]))
    }

    func test_ring_wrapsAroundTheEndOfTheStorage() {
        var ring = ReferenceRing(capacity: 64)
        for chunk in 0..<10 {
            _ = ring.write(ramp(20, from: Float(chunk * 20 + 1)), at: chunk * 20)
        }
        // positions 136..<200 are retained; the storage wrapped three times
        XCTAssertEqual(read(ring, 136, 64), ramp(64, from: 137))
        XCTAssertEqual(read(ring, 100, 36), [Float](repeating: 0, count: 36))
    }

    func test_ring_negativeAndHugePositions() {
        var ring = ReferenceRing(capacity: 100)
        _ = ring.write(ramp(100), at: -50)
        XCTAssertEqual(ring.highWater, 50)
        XCTAssertEqual(read(ring, -50, 100), ramp(100))
        XCTAssertEqual(read(ring, -60, 10), [Float](repeating: 0, count: 10))

        var far = ReferenceRing(capacity: 100)
        let huge = -16_000_000_000
        _ = far.write(ramp(30), at: huge)
        XCTAssertEqual(far.highWater, huge + 30)
        XCTAssertEqual(read(far, huge, 30), ramp(30))
        XCTAssertEqual(read(far, 0, 10), [Float](repeating: 0, count: 10))
    }

    func test_ring_removeAll() {
        var ring = ReferenceRing(capacity: 100)
        _ = ring.write(ramp(100), at: 0)
        ring.removeAll()
        XCTAssertNil(ring.highWater)
        XCTAssertEqual(read(ring, 0, 100), [Float](repeating: 0, count: 100))
    }

    // MARK: MicQueue

    private func pop(_ queue: inout MicQueue, _ max: Int) -> (taken: Int, samples: [Float]) {
        var out = [Float](repeating: -99, count: max)
        var taken = 0
        out.withUnsafeMutableBufferPointer { buffer in
            taken = queue.pop(into: buffer.baseAddress!, max: max)
        }
        return (taken, out)
    }

    func test_micQueue_contiguousAppendsShareASegment() {
        var queue = MicQueue()
        XCTAssertNil(queue.firstPosition)
        queue.append(ramp(100), at: 0)
        queue.append(ramp(50, from: 101), at: 100)
        XCTAssertEqual(queue.count, 150)
        XCTAssertEqual(queue.firstPosition, 0)

        let first = pop(&queue, 120)
        XCTAssertEqual(first.taken, 120)
        XCTAssertEqual(first.samples, ramp(120))
        XCTAssertEqual(queue.count, 30)
        XCTAssertEqual(queue.firstPosition, 120)
    }

    func test_micQueue_aFrameCanStraddleAReanchor() {
        var queue = MicQueue()
        queue.append(ramp(100), at: 0)
        queue.append(ramp(100, from: 101), at: 5_000)   // timestamps jumped forward
        let frame = pop(&queue, 150)
        XCTAssertEqual(frame.taken, 150)
        XCTAssertEqual(frame.samples, ramp(150), "samples keep their order across the re-anchor")
        XCTAssertEqual(queue.firstPosition, 5_050, "the next frame starts 50 samples into the second segment")
        XCTAssertEqual(queue.count, 50)
    }

    func test_micQueue_popZeroPadsAShortFinalFrame() {
        var queue = MicQueue()
        queue.append(ramp(10), at: 0)
        let frame = pop(&queue, 16)
        XCTAssertEqual(frame.taken, 10)
        XCTAssertEqual(frame.samples, ramp(10) + [Float](repeating: 0, count: 6))
        XCTAssertEqual(queue.count, 0)
        XCTAssertNil(queue.firstPosition)
        let empty = pop(&queue, 4)
        XCTAssertEqual(empty.taken, 0)
        XCTAssertEqual(empty.samples, [0, 0, 0, 0])
    }

    func test_micQueue_manyAppendsAndPopsKeepOrder() {
        var queue = MicQueue()
        var nextIn: Float = 0
        var nextOut: Float = 0
        var position = 0
        for round in 0..<200 {
            let size = 37 + (round * 53) % 300
            queue.append((0..<size).map { nextIn + Float($0) }, at: position)
            nextIn += Float(size)
            position += size
            while queue.count >= 160 {
                let frame = pop(&queue, 160)
                XCTAssertEqual(frame.taken, 160)
                for v in frame.samples {
                    XCTAssertEqual(v, nextOut)
                    nextOut += 1
                }
            }
        }
        XCTAssertEqual(Int(nextOut) + queue.count, Int(nextIn))
    }

    // MARK: EchoReductionTracker

    func test_reductionTracker_reportsErleOfEchoOnlyFrames() {
        var tracker = EchoReductionTracker()
        for _ in 0..<99 { tracker.add(nearEnergy: 1, farEnergy: 1, outEnergy: 0.01) }
        XCTAssertNil(tracker.reductionDb(), "needs ~1 s of far-active frames")
        tracker.add(nearEnergy: 1, farEnergy: 1, outEnergy: 0.01)
        XCTAssertEqual(try XCTUnwrap(tracker.reductionDb()), 20, accuracy: 1e-9)
    }

    func test_reductionTracker_excludesFramesDominatedByNearEndSpeech() {
        var tracker = EchoReductionTracker()
        for _ in 0..<300 { tracker.add(nearEnergy: 2, farEnergy: 1, outEnergy: 0.02) }      // echo only: 20 dB
        for _ in 0..<100 { tracker.add(nearEnergy: 500, farEnergy: 1, outEnergy: 400) }     // near-end speech
        XCTAssertEqual(try XCTUnwrap(tracker.reductionDb()), 20, accuracy: 1e-9)
    }

    func test_reductionTracker_windowRolls() {
        var tracker = EchoReductionTracker()
        for _ in 0..<500 { tracker.add(nearEnergy: 1, farEnergy: 1, outEnergy: 0.1) }       // 10 dB
        for _ in 0..<500 { tracker.add(nearEnergy: 1, farEnergy: 1, outEnergy: 0.001) }     // 30 dB
        XCTAssertEqual(try XCTUnwrap(tracker.reductionDb()), 30, accuracy: 1e-9)
        tracker.reset()
        XCTAssertNil(tracker.reductionDb())
    }
}
