import Foundation
import AVFoundation
import OSLog
import TranscriptionCore

private let aecDebugLog = Logger(subsystem: "io.island.whisper.IslandWhisper", category: "EchoCancellation")

/// FORK (echo cancellation, spec 03). Dumps what the echo canceller saw and
/// produced, for tuning on a real Mac: three 16 kHz mono Float32 WAV files per
/// meeting, in an `aec-debug` folder next to the recording —
///
///   * `<recording>.aec-mic.wav`   the raw microphone, as fed to the canceller
///   * `<recording>.aec-ref.wav`   the aligned meeting audio actually used as the reference
///   * `<recording>.aec-clean.wav` the canceller's output
///
/// The three files are sample-for-sample parallel, so any of them can be loaded
/// alongside the others in an audio editor and compared directly. The cleaned
/// file is exactly what the canceller returned (before any gain the session
/// applies afterwards), time-aligned with the other two and with the recording.
///
/// The canceller's frame observer fires on the main actor with chunks of 1 to
/// 160 samples (the three arrays of a call always have the same length).
/// `append` therefore only hops onto a private serial queue; the batching and
/// the `AVAudioFile` writes happen there. Not used unless the user turned
/// "Save echo-cancellation debug audio" on.
///
/// `@unchecked Sendable`: all mutable state is confined to `queue`.
final class AECDebugAudioWriter: @unchecked Sendable {
    /// Samples buffered per file before a write (1 s). Keeps `AVAudioFile`
    /// from being called 100 times a second with 160 frames.
    private static let batchSamples = 16_000

    private let queue = DispatchQueue(label: "io.island.mila.aec-debug-audio", qos: .utility)
    private var micFile: AVAudioFile?
    private var refFile: AVAudioFile?
    private var cleanFile: AVAudioFile?
    private var pendingMic: [Float] = []
    private var pendingRef: [Float] = []
    private var pendingClean: [Float] = []
    private var loggedWriteFailure = false

    /// Where the files for `recordingURL` go: an `aec-debug` folder beside it.
    static func directory(for recordingURL: URL) -> URL {
        recordingURL.deletingLastPathComponent().appendingPathComponent("aec-debug", isDirectory: true)
    }

    /// Creates the folder and the three (empty) WAV files. Throws if any of
    /// that fails, in which case no file is left open.
    init(recordingURL: URL) throws {
        let directory = Self.directory(for: recordingURL)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let base = recordingURL.deletingPathExtension().lastPathComponent
        let format = WhisperAudioFormat.pcmFloat32
        func makeFile(_ role: String) throws -> AVAudioFile {
            try AVAudioFile(forWriting: directory.appendingPathComponent("\(base).aec-\(role).wav"),
                            settings: format.settings,
                            commonFormat: .pcmFormatFloat32,
                            interleaved: false)
        }
        micFile = try makeFile("mic")
        refFile = try makeFile("ref")
        cleanFile = try makeFile("clean")
    }

    /// One observed chunk of any length (the three arrays have the same length).
    /// Safe to call from any thread; returns immediately.
    func append(near: [Float], far: [Float], out: [Float]) {
        queue.async {
            self.pendingMic.append(contentsOf: near)
            self.pendingRef.append(contentsOf: far)
            self.pendingClean.append(contentsOf: out)
            if self.pendingMic.count >= Self.batchSamples { self.drain() }
        }
    }

    /// Write whatever is still buffered and close the files. Blocks until the
    /// queue has caught up, so everything appended before this call is on disk
    /// when it returns. Idempotent.
    func close() {
        queue.sync {
            drain()
            micFile = nil
            refFile = nil
            cleanFile = nil
        }
    }

    // MARK: - Queue-confined

    private func drain() {
        write(&pendingMic, to: micFile)
        write(&pendingRef, to: refFile)
        write(&pendingClean, to: cleanFile)
    }

    private func write(_ samples: inout [Float], to file: AVAudioFile?) {
        defer { samples.removeAll(keepingCapacity: true) }
        guard let file, !samples.isEmpty,
              let buffer = AVAudioPCMBuffer(pcmFormat: file.processingFormat,
                                            frameCapacity: AVAudioFrameCount(samples.count)),
              let channel = buffer.floatChannelData?[0] else { return }
        buffer.frameLength = AVAudioFrameCount(samples.count)
        samples.withUnsafeBufferPointer { source in
            if let base = source.baseAddress { channel.update(from: base, count: samples.count) }
        }
        do {
            try file.write(from: buffer)
        } catch {
            guard !loggedWriteFailure else { return }
            loggedWriteFailure = true
            // The files live in the user's recordings folder; Cocoa quotes the
            // folder in `localizedDescription`, so only domain + code are public.
            let ns = error as NSError
            aecDebugLog.error("""
                echo-cancellation debug audio write failed \
                [\(ns.domain, privacy: .public) \(ns.code, privacy: .public)]: \
                \(error.localizedDescription, privacy: .private)
                """)
        }
    }
}
