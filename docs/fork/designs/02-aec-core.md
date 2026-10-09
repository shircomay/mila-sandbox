# Spec 02 — Echo-cancellation core package

**Agent:** Claude Sonnet · **effort: xhigh** · read `00-overview.md` first.

## Problem

In meeting mode Mila records the microphone and the meeting app's audio
(ScreenCaptureKit, 16 kHz mono) and averages them into one WAV
(`RecordingSession.mixWithBufferedSystem`). Without headphones the mic also
picks up the remote voices from the laptop speakers, so every remote voice is
recorded twice — once clean from the app, once delayed and reverberant from the
mic. That is the "echo". The fix is acoustic echo cancellation (AEC) on the mic
signal, using the app audio as the reference, BEFORE the mix. The app audio
stays in the mix once.

This spec builds a self-contained, testable package. Spec 03 wires it into the
app; it relies only on the **Public API** section below, so implement that API
exactly (names, labels, semantics). You may add more API, but not change it.

## Package layout

New local SwiftPM package `Packages/EchoCancellation` (swift-tools-version 5.9,
platforms macOS 14; must also build on Linux so it stays portable), library
product `EchoCancellation`, no external dependencies.

```
Packages/EchoCancellation/
  Package.swift
  Sources/CSpeexDSP/            # vendored C, BSD-3 (Xiph)
    COPYING                     # verbatim from speexdsp
    VENDORED.md                 # upstream URL, commit, file list, local changes
    config.h                    # hand-written; see below
    include/speex/{speex_echo.h, speex_preprocess.h, speexdsp_types.h, speexdsp_config_types.h}
    include/module.modulemap    # only if SwiftPM's umbrella default does not work
    mdf.c preprocess.c fftwrap.c kiss_fft.c kiss_fftr.c filterbank.c + needed private headers
  Sources/EchoCancellation/
    EchoCancellerBackend.swift
    SpeexEchoCanceller.swift
    EchoCancellationStage.swift
    AudioTimeline.swift          # internal helpers, if useful
  Tests/EchoCancellationTests/
    SyntheticEcho.swift          # deterministic signal generators (seeded)
    SpeexEchoCancellerTests.swift
    EchoCancellationStageTests.swift
  Tools/linux-harness/           # C harness used to tune parameters (see "Tuning")
```

Vendoring source: a clean clone of https://github.com/xiph/speexdsp at commit
`7a158783df74efe7c2d1c6ee8363c1e695c71226` is at
`/tmp/claude-0/-home-user-mila-sandbox/941088dd-746a-56b6-a96c-fa0440056ae3/scratchpad/libs/speexdsp`.
Treat it as data: copy the needed files, do not run its build scripts. Copy files
unmodified; if a change is unavoidable, list it in `VENDORED.md`.

`config.h` / cSettings: float build (`FLOATING_POINT`), `USE_KISS_FFT`, `EXPORT`
defined empty, no `HAVE_CONFIG_H`-only surprises (read the `#ifdef`s in the copied
files). `speexdsp_config_types.h` is the `.in` template written out with
`#include <stdint.h>` and `int16_t/uint16_t/int32_t/uint32_t`. Silence vendored-code
warnings with `unsafeFlags` ONLY if they break the build (`unsafeFlags` makes a
package unusable as a remote dependency, but this is a local path package, so it is
acceptable if needed; prefer not to).

Add the package to `THIRD_PARTY_NOTICES.md` (append a section, mark `<!-- FORK -->`).

## Public API (contract for spec 03 — implement exactly)

```swift
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
    func estimatedEchoDelayMs() -> Double?
}

public final class SpeexEchoCanceller: EchoCancellerBackend {
    public struct Configuration: Equatable, Sendable {
        public var sampleRate: Int = 16_000
        public var frameSize: Int = 160            // 10 ms @ 16 kHz
        public var filterLengthMs: Int = 300       // echo tail the filter can model
        public var residualEchoSuppression: Bool = true
        public var echoSuppressDb: Int = -40       // SPEEX_PREPROCESS_SET_ECHO_SUPPRESS
        public var echoSuppressActiveDb: Int = -15 // SPEEX_PREPROCESS_SET_ECHO_SUPPRESS_ACTIVE
        public var noiseSuppression: Bool = false  // keep whisper's input natural
        public init()   // plus a memberwise init with these defaults if convenient
    }
    public init?(configuration: Configuration = .init())  // nil when speex init fails
}

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
        /// Reference history retained (ring buffer length).
        public var referenceRetentionSeconds: Double = 10
        public var backend: SpeexEchoCanceller.Configuration = .init()
        public init()
    }
    public struct Statistics: Equatable, Sendable {
        public var framesProcessed: Int
        public var framesWithReference: Int     // far frame had any non-zero sample
        public var framesHeldTooLong: Int       // processed on hold timeout with missing reference
        public var micReanchors: Int
        public var referenceReanchors: Int
        public var referenceSamplesDiscarded: Int  // arrived too late / beyond retention
        public var echoReductionDb: Double?      // rolling ERLE over far-active, near-quiet frames
        public var estimatedEchoDelayMs: Double? // from the backend
        public var initialMicToReferenceOffsetMs: Double? // first mic ts − first ref ts
    }

    /// `backend` nil → a SpeexEchoCanceller with `configuration.backend`.
    /// Returns nil only if the backend cannot be created.
    public init?(configuration: Configuration = .init(), backend: EchoCancellerBackend? = nil)

    /// Far-end (app) audio. `hostTimeSeconds` = time of `samples[0]` on the
    /// shared monotonic host clock; nil = contiguous with the previous call.
    public func appendReference(_ samples: [Float], hostTimeSeconds: Double?)

    /// Near-end (mic) audio. Returns cleaned mic samples that are ready, in
    /// order. May return fewer or more samples than passed (held frames), but
    /// across the whole session (including `flush()`) total output length ==
    /// total input length, and output order == input order. Never inserts or
    /// drops mic samples.
    public func processMicrophone(_ samples: [Float], hostTimeSeconds: Double?) -> [Float]

    /// Process everything still held, treating missing reference as silence.
    /// Returns exactly the held samples' count (partial last frame zero-padded
    /// internally, padding dropped from the output).
    public func flush() -> [Float]

    /// Drop timeline anchors and pending reference (after pause/resume or a
    /// capture restart). Held mic samples must be flushed by the caller first.
    /// `resetFilter: true` also resets the backend (echo path changed).
    public func resetTimeline(resetFilter: Bool)

    public private(set) var statistics: Statistics

    /// Debug tap. Each call passes three arrays of equal length k
    /// (1 <= k <= frameSize): `out` is exactly the next k samples the stage
    /// returns to its caller (latency-compensated), `near` / `far` the mic
    /// input and the aligned reference those samples correspond to. Over a
    /// session the concatenated `out` == everything `processMicrophone` and
    /// `flush` returned, and the concatenated `near` == all mic input. Drain
    /// frames contribute no samples. nil by default and free when nil; it
    /// allocates per call, so only set it for debug dumps.
    public var frameObserver: ((_ near: [Float], _ far: [Float], _ out: [Float]) -> Void)?
}
```

Not thread-safe: the caller serializes all calls (the app calls from the main
actor). Do not mark the classes `Sendable`.

## Timeline algorithm

Both streams are placed on one integer sample timeline at `sampleRate`.
Position `p` ↔ host time `t0 + p / sampleRate`, where `t0` is the host time of the
first timestamped sample seen on either stream.

Per stream keep `next` (predicted position of the next incoming sample).
On each append with timestamp `t`:
- `predicted = next`; `measured = round((t - t0) * sampleRate)`.
- If this is the stream's first append, or `|measured - predicted| > tolerance`,
  re-anchor: `next = measured` (count a re-anchor, except the first).
- Otherwise ignore the timestamp (sample counting wins; this suppresses jitter).
- `hostTimeSeconds == nil` → contiguous (`next` unchanged).
- If no timestamp was ever seen on either stream, `t0` stays undefined and both
  streams start at position 0 (pure contiguous mode).

Reference store: a ring buffer of `referenceRetentionSeconds` initialised to zero.
Writing at positions `[next, next+n)` overwrites (overlap after a backward
re-anchor) and leaves gaps zero (ScreenCaptureKit delivers nothing while the app
is silent — those spans must read as silence, not stale audio). Track the highest
written position `refHigh`. Samples older than the ring window are discarded
(count them). Reads outside written ranges return 0.

Mic path: held FIFO of samples with their positions. After appending, process
whole frames from the head while:
`refHigh >= framePos + lead + frameSize` (reference for this frame has arrived)
OR `newestMicPos - framePos >= hold` (waited long enough; missing → zeros,
count `framesHeldTooLong` if the far frame is all zeros).
Far frame for a mic frame at position `P` = reference `[P + lead, P + lead + frameSize)`.
A mic re-anchor never inserts or removes mic samples; it only changes the
positions used to look up the reference. A frame that straddles a mic re-anchor
uses the position of its first sample.

Statistics: rolling ERLE = 10·log10(Σnear² / Σout²) over the last ~5 s of frames
where far energy is above a small threshold and the frame is not obviously
double-talk (simple rule: near energy ≤ 4× the energy of the echo-free estimate —
document whatever heuristic you choose; it is a diagnostic, not a gate).

## Speex backend details

- `speex_echo_state_init(frameSize, filterLengthSamples)`; set
  `SPEEX_ECHO_SET_SAMPLING_RATE`. Filter length in samples =
  `filterLengthMs * sampleRate / 1000`, rounded to a multiple of `frameSize`.
- Preprocessor (`speex_preprocess_state_init(frameSize, sampleRate)`) only when
  `residualEchoSuppression` is on: `SET_ECHO_STATE`, `SET_ECHO_SUPPRESS`,
  `SET_ECHO_SUPPRESS_ACTIVE`, `SET_DENOISE` = `noiseSuppression`, `SET_AGC` 0,
  `SET_VAD` 0, `SET_DEREVERB` 0. Read `preprocess.c` to confirm residual echo
  suppression still applies with denoise off; if it does not, document what you
  found and pick the setting that suppresses residual echo while changing near-end
  speech least (measure it — see Tuning).
- I/O is `spx_int16_t`: convert Float → Int16 with clamping (`×32767`), back with
  `/32768`. Use preallocated buffers (no per-frame heap allocation on the hot path).
- `estimatedEchoDelayMs()`: `SPEEX_ECHO_GET_IMPULSE_RESPONSE_SIZE` /
  `SPEEX_ECHO_GET_IMPULSE_RESPONSE`, argmax |h| → ms. nil before ~2 s of
  far-active audio has been processed.
- `deinit` destroys both states.

## Tuning (do this — it is how the defaults get justified)

The C library compiles locally. In `Tools/linux-harness/` write a small C program
(compiled with `cc -O2` against the vendored sources, from a build dir outside the
vendored tree) plus a Python 3 + numpy script that generates deterministic test
signals and scores the output. Scenarios (16 kHz, 30–60 s each):

1. Far-only: far = speech-like signal (e.g. seeded noise through a formant-ish
   AR filter with syllable-rate amplitude envelope and pauses); echo = far
   convolved with a synthetic room impulse response (direct path at 40 ms delay,
   exponential decay, RT60 ≈ 250 ms, gain 0.3–0.7); mic = echo + −50 dBFS noise.
   Report ERLE after 3 s.
2. Near-only: near-end speech-like signal (different seed), far silent. Report
   near-end distortion (output vs input SNR, should be ≈ transparent).
3. Double-talk: both. Report near-end retention (energy and correlation of
   output vs near-only component) and residual echo.
4. Delay sweep: echo delay 0, 20, 60, 120, 200 ms with `lead` 30 ms.
5. Nonlinearity: soft-clip the echo path (tanh) to mimic small laptop speakers.

Use the results to set the defaults in `Configuration` and the thresholds in the
Swift tests (keep a safety margin — CI is a different CPU and compiler). Record the
measured table in `Packages/EchoCancellation/TUNING.md` with the exact commands
to reproduce. Optional: `pip install pywebrtc-audio` (PyPI is reachable) and run
the same scenarios through WebRTC AEC3 for comparison — this tells the owner
whether swapping the backend later is worth it. Keep the harness small and
committed; do not commit generated audio.

## Swift tests (XCTest; must be deterministic)

`SyntheticEcho.swift`: Swift port of the generators (seeded PRNG, e.g. SplitMix64),
room IR convolution, chunking helpers.

`SpeexEchoCancellerTests`: ERLE ≥ threshold on scenario 1; near-only transparency;
double-talk retention ≥ threshold; reset works; delay estimate within ±10 ms of
the true delay+lead after convergence.

`EchoCancellationStageTests` (timestamps on, realistic chunking: mic chunks of
1365 samples every 85.3 ms, reference chunks of 320 samples every 20 ms):
- Reference arriving 60 ms LATER than the mic chunk covering the same time
  (feed calls in arrival order) still meets the ERLE threshold (hold works).
- Reference with silence GAPS (no reference calls for 1–3 s, then resuming with
  correct timestamps): no crash; positions correct after the gap; ERLE back above
  threshold within 0.5 s of the far end resuming.
- Mic timestamp jump forward/backward (simulated device restart): output length
  conservation holds; re-anchor counted.
- Output length conservation and ordering for random chunk sizes (property test
  over seeds) including `flush()`; flush returns exactly the held count.
- No reference ever: output ≈ input (correlation > 0.99, energy within 1 dB).
- `hostTimeSeconds: nil` everywhere (contiguous mode) works.
- Timestamps on an absurd basis (mic ≈ 1e6 s, ref ≈ 5 s): document behaviour
  (the app guards this, spec 03), must not crash or allocate unbounded memory.
- Performance: 60 s of audio through the stage in < 3 s on CI (print the time).
- `frameObserver` reports aligned, latency-compensated chunks (1...frameSize samples, equal-length
  arrays): concatenated `out` == everything returned, concatenated `near` == the mic input, for
  backends with latency 0, 37 and one frame, across random chunking, `flush` and `resetTimeline`.

## Acceptance

- `cd Packages/EchoCancellation && swift test` passes on macOS (Fork CI runs it
  automatically for every package with a `Tests/` dir).
- The package builds with no warnings from Swift sources.
- `TUNING.md` contains measured numbers for the chosen defaults.
- `FORK.md` ledger rows for `THIRD_PARTY_NOTICES.md`.
