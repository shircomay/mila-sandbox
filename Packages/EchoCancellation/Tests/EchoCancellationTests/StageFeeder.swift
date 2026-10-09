// Delivers a microphone signal and a reference signal to an
// EchoCancellationStage the way the app's two capture callbacks do, in
// arrival order. Port of feed() in Tools/linux-harness/stage_scenarios.py.

import Foundation
import EchoCancellation

struct FeedOptions {
    /// 85.3 ms: what AVAudioEngine delivers at 16 kHz after conversion.
    var micChunk = 1365
    /// 20 ms: ScreenCaptureKit.
    var refChunk = 320
    /// The reference "arrives" this long after its last sample was captured.
    var refLateMs = 0.0
    /// false -> hostTimeSeconds: nil everywhere (contiguous mode).
    var useTimestamps = true
    /// Host-clock seconds of sample 0 of the microphone stream.
    var base = 52_000.0
    /// Host-clock seconds of sample 0 of the reference stream (default: `base`).
    var referenceBase: Double?
    /// Reference delivery starts at this time (ScreenCaptureKit starting late).
    var refStartSeconds = 0.0
    /// Drop all-zero reference chunks, like ScreenCaptureKit during silence.
    var skipSilentReference = false
    /// True capture index of every microphone sample, for streams with gaps or
    /// repeats: chunk timestamps and arrival times follow it.
    var micTrueIndex: [Int]?
    /// Microphone chunk sizes (cycled) instead of the fixed `micChunk`.
    var micChunks: [Int]?
}

enum StageFeeder {
    private struct Event {
        var arrival: Double
        var isReference: Bool
        var position: Int
        var count: Int
    }

    /// Feeds everything, flushes, and returns the concatenated output.
    static func feed(stage: EchoCancellationStage, mic: [Float], reference: [Float],
                     options: FeedOptions = FeedOptions()) -> [Float] {
        let sr = Double(SyntheticEcho.sampleRate)
        var events: [Event] = []

        var pos = 0
        var chunkIndex = 0
        var arrival = 0.0
        while pos < mic.count {
            var size = options.micChunk
            if let sizes = options.micChunks, !sizes.isEmpty {
                size = sizes[chunkIndex % sizes.count]
            }
            chunkIndex += 1
            let count = min(size, mic.count - pos)
            if let trueIndex = options.micTrueIndex {
                arrival = max(arrival, Double(trueIndex[pos + count - 1] + 1) / sr)
            } else {
                arrival = Double(pos + count) / sr
            }
            events.append(Event(arrival: arrival, isReference: false, position: pos, count: count))
            pos += count
        }

        var j = Int(options.refStartSeconds * sr)
        while j < reference.count {
            let count = min(options.refChunk, reference.count - j)
            var drop = false
            if options.skipSilentReference {
                drop = true
                var k = j
                while k < j + count {
                    if reference[k] != 0 {
                        drop = false
                        break
                    }
                    k += 1
                }
            }
            if !drop {
                let when = Double(j + count) / sr + options.refLateMs / 1000.0
                events.append(Event(arrival: when, isReference: true, position: j, count: count))
            }
            j += count
        }

        // Total order: arrival time, microphone before reference on ties, then position.
        events.sort { a, b in
            if a.arrival != b.arrival { return a.arrival < b.arrival }
            if a.isReference != b.isReference { return !a.isReference }
            return a.position < b.position
        }

        let referenceBase = options.referenceBase ?? options.base
        var output: [Float] = []
        output.reserveCapacity(mic.count + 4096)
        for event in events {
            if event.isReference {
                let ts: Double? = options.useTimestamps ? referenceBase + Double(event.position) / sr : nil
                stage.appendReference(Array(reference[event.position..<(event.position + event.count)]), hostTimeSeconds: ts)
            } else {
                var ts: Double?
                if options.useTimestamps {
                    let first = options.micTrueIndex.map { $0[event.position] } ?? event.position
                    ts = options.base + Double(first) / sr
                }
                output.append(contentsOf: stage.processMicrophone(
                    Array(mic[event.position..<(event.position + event.count)]), hostTimeSeconds: ts))
            }
        }
        output.append(contentsOf: stage.flush())
        return output
    }
}
