import XCTest
import AVFoundation
import CoreMedia
import os
@testable import Mila

/// FORK (echo cancellation, spec 03). The capture-timestamp queue is what lets
/// `RecordingSession` give the echo canceller a capture time for every mic and
/// app-audio buffer. Its two contracts that matter: it is strictly FIFO (the
/// n-th pop describes the n-th buffer) and it is invisible unless enabled (so
/// every recording that does not use echo cancellation behaves as before).
final class CaptureTimestampQueueTests: XCTestCase {

    // MARK: - Queue

    func test_pops_in_push_order_then_reports_empty() {
        let queue = CaptureTimestampQueue()
        queue.isEnabled = true
        queue.push(1.5)
        queue.push(2.5)
        queue.push(3.5)
        XCTAssertEqual(queue.pendingCount, 3)
        XCTAssertEqual(queue.pop(), 1.5)
        XCTAssertEqual(queue.pop(), 2.5)
        XCTAssertEqual(queue.pop(), 3.5)
        XCTAssertNil(queue.pop(), "an empty queue pops nil")
        XCTAssertEqual(queue.pendingCount, 0)
    }

    /// A buffer with no usable timestamp must still occupy its slot, or every
    /// later timestamp would be paired with the wrong buffer.
    func test_a_nil_entry_keeps_its_place_in_line() {
        let queue = CaptureTimestampQueue()
        queue.isEnabled = true
        queue.push(10)
        queue.push(nil)
        queue.push(30)
        XCTAssertEqual(queue.pendingCount, 3)
        XCTAssertEqual(queue.pop(), 10)
        XCTAssertNil(queue.pop(), "the buffer without a timestamp pops nil")
        XCTAssertEqual(queue.pendingCount, 1, "...but it consumed its slot")
        XCTAssertEqual(queue.pop(), 30)
    }

    func test_is_disabled_by_default_and_push_is_a_no_op() {
        let queue = CaptureTimestampQueue()
        XCTAssertFalse(queue.isEnabled)
        queue.push(1)
        queue.push(2)
        XCTAssertEqual(queue.pendingCount, 0, "a disabled queue records nothing")
        XCTAssertNil(queue.pop())

        queue.isEnabled = true
        queue.push(3)
        XCTAssertEqual(queue.pop(), 3)

        queue.isEnabled = false
        queue.push(4)
        XCTAssertEqual(queue.pendingCount, 0, "disabling stops recording again")
    }

    func test_full_queue_drops_the_oldest_entries() {
        let queue = CaptureTimestampQueue(capacity: 4)
        queue.isEnabled = true
        for i in 1...6 { queue.push(Double(i)) }
        XCTAssertEqual(queue.pendingCount, 4)
        XCTAssertEqual(queue.overflowCount, 2, "two entries were pushed out")
        XCTAssertEqual([queue.pop(), queue.pop(), queue.pop(), queue.pop()],
                       [3, 4, 5, 6],
                       "the newest `capacity` entries survive, still in order")
        XCTAssertNil(queue.pop())
    }

    /// The ring wraps many times over; order has to survive every lap.
    func test_order_survives_wrapping_the_ring_repeatedly() {
        let queue = CaptureTimestampQueue(capacity: 3)
        queue.isEnabled = true
        var next = 0.0
        var expected = 0.0
        for _ in 0..<50 {
            queue.push(next); next += 1
            queue.push(next); next += 1
            XCTAssertEqual(queue.pop(), expected); expected += 1
            XCTAssertEqual(queue.pop(), expected); expected += 1
        }
        XCTAssertEqual(queue.pendingCount, 0)
        XCTAssertEqual(queue.overflowCount, 0)
    }

    func test_reset_empties_the_queue_but_keeps_it_enabled() {
        let queue = CaptureTimestampQueue(capacity: 2)
        queue.isEnabled = true
        queue.push(1); queue.push(2); queue.push(3)   // one overflow
        XCTAssertEqual(queue.overflowCount, 1)

        queue.reset()
        XCTAssertEqual(queue.pendingCount, 0)
        XCTAssertEqual(queue.overflowCount, 0)
        XCTAssertNil(queue.pop())
        XCTAssertTrue(queue.isEnabled, "reset clears entries, not the switch")

        queue.push(9)
        XCTAssertEqual(queue.pop(), 9, "usable straight after a reset")
    }

    func test_capacity_below_one_is_clamped() {
        let queue = CaptureTimestampQueue(capacity: 0)
        queue.isEnabled = true
        queue.push(1)
        queue.push(2)
        XCTAssertEqual(queue.pop(), 2, "a one-slot queue keeps only the newest entry")
    }

    /// Smoke test for the locking: a producer (the capture thread) and a
    /// consumer (the main actor in production) hammer the queue at once.
    /// Nothing may be lost, duplicated or reordered.
    func test_concurrent_push_and_pop_lose_nothing_and_keep_order() {
        final class Collected: @unchecked Sendable { var values: [Double] = [] }

        let total = 40_000
        let queue = CaptureTimestampQueue(capacity: total)   // large enough that nothing overflows
        queue.isEnabled = true
        let producerDone = OSAllocatedUnfairLock(initialState: false)
        let collected = Collected()
        let group = DispatchGroup()

        group.enter()
        DispatchQueue.global(qos: .userInitiated).async {
            for i in 0..<total { queue.push(Double(i)) }
            producerDone.withLock { $0 = true }
            group.leave()
        }
        group.enter()
        DispatchQueue.global(qos: .userInitiated).async {
            while collected.values.count < total {
                if let value = queue.pop() {
                    collected.values.append(value)
                } else if producerDone.withLock({ $0 }) && queue.pendingCount == 0 {
                    break
                }
            }
            group.leave()
        }

        XCTAssertEqual(group.wait(timeout: .now() + 60), .success, "producer/consumer deadlocked or stalled")
        XCTAssertEqual(collected.values.count, total, "entries were lost")
        XCTAssertEqual(queue.overflowCount, 0)
        XCTAssertEqual(collected.values, (0..<total).map(Double.init),
                       "entries were duplicated or reordered")
    }

    // MARK: - Clock conversions

    func test_audio_time_with_a_valid_host_time_converts_to_seconds() throws {
        let hostTime = mach_absolute_time()
        let seconds = CaptureTimestampQueue.hostTimeSeconds(of: AVAudioTime(hostTime: hostTime))
        XCTAssertEqual(try XCTUnwrap(seconds),
                       AVAudioTime.seconds(forHostTime: hostTime),
                       accuracy: 1e-9)
    }

    func test_audio_time_without_a_host_time_has_no_timestamp() {
        let sampleOnly = AVAudioTime(sampleTime: 1_024, atRate: 16_000)
        XCTAssertNil(CaptureTimestampQueue.hostTimeSeconds(of: sampleOnly))
    }

    func test_presentation_time_conversion_accepts_only_finite_numeric_times() {
        XCTAssertEqual(CaptureTimestampQueue.hostTimeSeconds(
            ofPresentationTime: CMTime(seconds: 12.5, preferredTimescale: 1_000_000_000)) ?? -1,
                       12.5, accuracy: 1e-6)
        XCTAssertNil(CaptureTimestampQueue.hostTimeSeconds(ofPresentationTime: .invalid))
        XCTAssertNil(CaptureTimestampQueue.hostTimeSeconds(ofPresentationTime: .indefinite))
        XCTAssertNil(CaptureTimestampQueue.hostTimeSeconds(ofPresentationTime: .positiveInfinity))
    }

    // MARK: - Recorder hooks

    /// The mic recorder's queue must not record anything until a session turns
    /// it on, and gain must stay in the tap by default — otherwise every
    /// existing recording would change.
    @MainActor
    func test_microphone_recorder_defaults_leave_capture_unchanged() {
        let mic = MicrophoneRecorder()
        XCTAssertFalse(mic.timestamps.isEnabled)
        XCTAssertFalse(mic.deferGainToConsumer)
        mic.timestamps.push(1)
        XCTAssertEqual(mic.timestamps.pendingCount, 0)
    }

    /// The system recorder pushes exactly one entry per delivered buffer — the
    /// timestamp it was given, or nil when it had none — in delivery order,
    /// and nothing at all while the queue is disabled.
    @MainActor
    func test_system_recorder_pushes_one_entry_per_delivered_buffer() {
        let recorder = SystemAudioRecorder()

        recorder.deliverForTesting(Self.tone())
        XCTAssertEqual(recorder.timestamps.pendingCount, 0, "disabled by default: nothing recorded")

        recorder.timestamps.isEnabled = true
        recorder.deliverForTesting(Self.tone(), hostTimeSeconds: 100.25)
        recorder.deliverForTesting(Self.tone())                       // no timestamp
        recorder.deliverForTesting(Self.tone(), hostTimeSeconds: 100.45)
        XCTAssertEqual(recorder.timestamps.pendingCount, 3)
        XCTAssertEqual(recorder.timestamps.pop(), 100.25)
        XCTAssertNil(recorder.timestamps.pop())
        XCTAssertEqual(recorder.timestamps.pop(), 100.45)
        XCTAssertEqual(recorder.timestamps.pendingCount, 0)
    }

    // MARK: - Helpers

    /// 20 ms of a 440 Hz tone in whisper format (pass-through converter).
    private static func tone() -> AVAudioPCMBuffer {
        let format = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: 16_000,
                                   channels: 1, interleaved: false)!
        let frames: AVAudioFrameCount = 320
        let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: frames)!
        buffer.frameLength = frames
        let channel = buffer.floatChannelData![0]
        for i in 0..<Int(frames) {
            channel[i] = 0.3 * sinf(2 * .pi * 440 * Float(i) / 16_000)
        }
        return buffer
    }
}
