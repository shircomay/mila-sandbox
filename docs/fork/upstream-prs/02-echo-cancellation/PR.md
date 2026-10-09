# feat(audio): opt-in acoustic echo cancellation for meeting recordings (draft)

Closes #ISSUE_NUMBER

> **Draft, and a question.** This is complete and its full build and test
> suite pass in CI (run linked below), but it has **not**
> been tried with real speakers and a real microphone, and it adds a vendored C
> library and touches the meeting-recording path. I would like to know whether
> you want it in Mila before anyone spends review time on it. It is off by
> default and does nothing unless a user turns it on.

## What & why

In Meeting mode the microphone and the captured app audio are averaged into one
WAV. Without headphones the microphone also hears the other participants from
the speakers, so each remote voice is recorded twice: clean from the app, and
delayed and reverberant from the microphone. The current mix pairs the two
streams by arrival order, and ScreenCaptureKit delivers nothing while the app
is silent, so the offset between the two moves whenever the far end pauses. An
echo canceller has to know that offset, and arrival order does not tell it.
This PR cancels the echo from the microphone, using the app audio as the
reference, before the mix, so the app audio stays in the recording once.

**How it works**

- **Timestamped streams.** `CaptureTimestampQueue` is a small bounded,
  lock-protected FIFO of host capture times. The microphone tap and the
  ScreenCaptureKit output push one entry right before they yield a buffer;
  `RecordingSession` pops one per buffer it receives (first thing, before the
  pause gate, so the queue stays aligned even for buffers dropped while paused).
  The existing `AsyncStream` types do not change. Disabled by default, in which
  case `push` is a no-op.
- **`Packages/EchoCancellation`** (new local package, no dependencies):
  - `EchoCancellationStage` puts both streams on one integer sample timeline
    from those timestamps. Sample counting wins over timestamp jitter; a gap or
    overlap of 20 ms or more re-anchors. Reference gaps (ScreenCaptureKit
    silence) are zeros. A microphone frame waits up to **150 ms** for its
    reference, and the reference is fed **30 ms ahead** of mic time so a
    slightly late timestamp is still causal for the filter. The stage never adds
    or drops a microphone sample: over a session, output length equals input
    length, in order, including `flush()`.
  - `SpeexEchoCanceller` is SpeexDSP's MDF adaptive filter (300 ms) plus its
    preprocessor used for residual echo suppression, behind a small
    `EchoCancellerBackend` protocol so another canceller can be swapped in.
  - `CSpeexDSP` is SpeexDSP vendored as a C target (BSD-3-Clause, files
    byte-identical to Xiph commit `7a158783df74efe7c2d1c6ee8363c1e695c71226`,
    only `config.h`, a module map and a generated types header are ours; see
    `VENDORED.md`). About 6,000 lines of C and headers. Attribution is added to
    `THIRD_PARTY_NOTICES.md`.
  - `Tools/linux-harness` is a small C and Python harness (needs only `cc` and
    numpy) that produced the numbers in `TUNING.md`; it is how the defaults were
    chosen and how to re-check them.
- **Gain moves after the canceller.** The mic tap's adaptive gain (200 ms
  attack) would change the signal under an adaptive filter, which looks like a
  changing echo path. When echo cancellation is on, the tap skips the gain
  (`deferGainToConsumer`, read at every bring-up including rebuilds) and
  `RecordingSession` applies the same controller to the cleaned samples.
- **Session flow.** `RecordingSession` feeds the app audio to the stage as the
  reference, mixes the stage's output instead of the raw microphone, flushes
  held microphone audio on pause and stop (and restarts the stage's timeline on
  pause). Once per recording it checks that the two capture
  clocks agree (the assumption that ScreenCaptureKit stamps on the host clock is
  verified at run time); if they are more than 5 s apart it falls back to
  arrival order. A stage that cannot be created bypasses to today's behaviour
  and says so.
- **Debug audio (optional, off by default).** Writes the raw microphone, the
  aligned reference and the cleaned microphone as three sample-parallel 16 kHz
  WAVs per meeting in an `aec-debug` folder next to the recording, so the result
  can be judged by ear.
- **Session summary.** On stop, one line of numbers only (echo reduction, echo
  delay, how often a reference was present, or the reason for a bypass) is
  stored and shown in Settings > Audio as "Last meeting: …".

**Measured, synthetic only.** Speech-like signals through a synthetic room, so
these describe the algorithm and the stage, not a particular laptop. Full
tables and the commands to reproduce are in `Packages/EchoCancellation/TUNING.md`.

| Scenario (default configuration) | Result |
| --- | --- |
| Echo reduction (ERLE) over time, linear room, −50 dBFS noise | 6.1 dB (0–3 s), 13.6 (3–6 s), 20.1 (6–12 s), 20.8 (12–25 s), 25.0 (25–40 s) |
| Echo delay 0 / 20 / 60 / 120 / 200 ms | 24.1 / 21.9 / 21.1 / 21.6 / 19.4 dB (12–25 s) |
| Speaker nonlinearity (tanh soft clip) | about 13 dB |
| Near-end speech alone | −0.45 dB energy, correlation 0.99999 against the same signal after Speex's fixed ~60 Hz high-pass |
| Double talk (near-end speech plus echo) | near-end energy −0.42 dB, correlation 0.985 against the ideal |
| Reference arriving up to ≈100 ms after the mic chunk for the same time | no loss (≈21 dB); at 140 ms late, ≈6–8 dB |
| Reference silence gaps (as ScreenCaptureKit does) | back to ≈20 dB within 0.5 s of the far end resuming |
| Mic timestamp jumps (simulated capture restart) | output length conserved, 2 re-anchors, ≈23 dB afterwards |

Convergence takes seconds: the first ~10 s of a meeting are only partly cleaned.
I also compared WebRTC AEC3 on the same signals (also in `TUNING.md`): it
reaches about 30 dB and converges within 3 s, but removes 4.4 dB of near-end
speech in double talk (correlation 0.83) and delays output by about 8 ms, so
Speex is the first backend.

**Settings** (Settings > Audio; `UserDefaults` keys `echoCancellation.*`):

| Setting | Key | Default |
| --- | --- | --- |
| Remove speaker echo from meeting recordings | `echoCancellation.enabled` | **off** |
| Save echo-cancellation debug audio | `echoCancellation.saveDebugAudio` | **off** |
| "Last meeting" summary (written by the app, not a setting) | `echoCancellation.lastSessionSummary` | absent until a meeting used (or was bypassed by) the canceller |

Changes apply to the next recording, never to one in progress. Reads go through
`object(forKey:)` so an unset or malformed value is the code default, and the
settings object never calls `register(defaults:)`.

**Where it hooks in**

- `MicrophoneRecorder`: a `timestamps` queue filled in the tap (from the
  `AVAudioTime` it already receives), and `deferGainToConsumer`.
- `SystemAudioRecorder`: a `timestamps` queue filled in the sample-buffer
  callback from the presentation time; `deliver` and `deliverForTesting` gain a
  defaulted `hostTimeSeconds` parameter, so existing callers and tests compile
  unchanged.
- `RecordingSession`: one stored property (`echo`) plus single calls at start,
  pause, stop, `cancelAll`, `consumeMic` and `consumeSystem`. The logic lives in
  `RecordingSession+EchoCancellation.swift` and `AECDebugAudioWriter`.
  `consumeSystem` becomes internal, as `consumeMic` already is, for tests.
- `EchoCancellationSettings` is an app-wide `@StateObject` created in
  `MilaApp.init()`, registered with the churn probe and injected into both the
  main window and the Settings scene. It publishes only on user actions (and
  on appear of the Settings view), nothing at audio cadence.
- `project.yml`: the package and the dependency from the `Mila` and `MilaTests`
  targets. Nothing else in the build changes.

**What is unchanged when it is off**

- No stage is created. The timestamp queues stay disabled, so `push` is a no-op
  and nothing accumulates. The mic tap applies gain exactly as before.
  `consumeMic` and `consumeSystem` take the existing path (a test mixes known
  samples and asserts the result is the plain average, with the queues
  untouched).
- Microphone-only and app-audio-only recordings never create a stage, with the
  setting on or off.
- The mixer, the live-transcript feed and the WAV format are untouched. The
  existing session tests drive `startFakeForTesting`, which never creates a
  stage, and run unchanged.

**Known limits**

- Only the **captured app's** audio is cancelled. Anything else playing through
  the speakers (notification sounds, music from another app) is not in the
  reference and is not removed.
- **Microphone-only recordings cannot be cancelled**: there is no reference.
  It works in Meeting mode only.
- About **10 s of convergence** at the start of a meeting; the filter is kept
  across pause and resume but starts fresh for each recording. A mid-session
  input-device change is not treated as a new echo path yet (there is a `TODO`).
- **Real acoustic quality is not yet verified on hardware.** Real laptop
  speakers, moving people, clock drift between the two capture clocks and
  microphone-side AGC are not modelled by the synthetic tests.
- The vendored library adds about 6,000 lines of C to the repo.

## How it was tested

CI evidence: the "Upstream PR check" workflow in the contributor's fork builds
this exact patch series on top of `island-io/mila`
`605babbd5c2639841fc4ea366f9d3cf9f4a21118` (Release 1.9.6, build 68) on a
`macos-26` runner with Xcode. It clones upstream at that commit, applies the four
commits here with `git am --3way`, runs the `swift test` suites of the local
packages that have tests (MilaKit and the new EchoCancellation package), then
`make project`, a Debug build of the `Mila` scheme, and the **full** `MilaTests`
suite (not only the one class upstream's CI runs). Run: https://github.com/shircomay/mila-sandbox/actions/runs/38004705474

New tests, all with synthetic audio, seeded generators and private
`UserDefaults` suites:

- `EchoCancellation` package (59 tests): the Speex backend (ERLE, near-end
  transparency, double talk, reset, delay estimate, a nonlinear echo path), the
  timeline pieces (reference ring buffer with gaps, overlap and wrap-around, the
  microphone frame queue, the ERLE tracker), the Swift test-signal generators
  against reference vectors from the Python harness, and the stage (reference
  arriving late, silent-reference gaps as ScreenCaptureKit does, microphone
  timestamp jumps, output length and order conservation over random chunking
  and `flush()`, no reference at all, contiguous mode, an absurd timestamp
  basis, `frameObserver`, throughput).
- `CaptureTimestampQueueTests`: order, disabled no-op, capacity and
  drop-oldest, reset, concurrent push and pop, and the recorder hooks.
- `RecordingSessionEchoCancellationTests`: a fake meeting session fed synthetic
  echo through the real `consumeMic` / `consumeSystem` / `pause` / `stop` paths.
  Echo in the saved mix is far lower than in the same run without a stage; a
  late-starting or late-arriving reference is aligned by timestamp; no sample is
  lost across pause, resume and stop; a clock-basis mismatch falls back to
  arrival order without losing audio; a quiet far end is not mistaken for a
  mismatch; deferred gain is applied once; the summary is stored on stop; debug
  audio files are aligned and complete; and a session without a stage, or the
  plain fake session, is untouched.
- `EchoCancellationSettingsTests`: code defaults, persistence under the
  namespaced keys, malformed values, the summary line.

**Not yet done:** the Settings section was not exercised by hand, the debug
audio was not listened to, and **nothing has been tested with real speakers and
a microphone**. The synthetic measurements and the CI run above are the only
evidence so far. That is the main reason this is a draft.

Not touched, in case you want them: `make package-test` and `ci.yml` still run
only the TranscriptionCore and MilaKit package tests, so the new package's own
tests (which the check above does run) would need a line in each to run in your
CI.

## Checklist

- [x] Builds locally (`make build`) and tests pass (`make test`) — verified by the CI run above rather than on the author's own Mac
- [x] No secrets, credentials, tokens, or internal infrastructure references added
- [x] Follows the conventions in `CLAUDE.md` (app-wide `@StateObject` injected in both scenes and registered with the churn probe, nothing high-frequency published from it, namespaced keys, private `UserDefaults` suites in tests, log lines carry numbers only and file paths are `.private`)
- [x] User-facing change is noted in the README changelog (if applicable)

🤖 Generated with [Claude Code](https://claude.com/claude-code)
