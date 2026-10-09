# Spec 03 — Wire echo cancellation into meeting recordings

**Agent:** Claude Sonnet · **effort: xhigh** · read `00-overview.md` and the
**Public API** section of `02-aec-core.md` first. Use ONLY that public API of
`EchoCancellation` (another agent is implementing the package in parallel; it
may not exist in your worktree yet — write against the contract).

## Goal

In meeting recordings (`RecordingSource.meeting`), run the microphone through
`EchoCancellationStage` with the app audio as reference, before
`mixWithBufferedSystem`. Mic-only and system-only recordings are untouched. A
setting turns it on/off; failures bypass to today's behaviour and say so.

Relevant code (read all of it before editing):
`Mila/Audio/RecordingSession.swift` (start, pause, resume, stop, cancelAll,
consumeMic, consumeSystem, mixWithBufferedSystem, flushPendingSystemTail, write),
`Mila/Audio/MicrophoneRecorder.swift` (tap at ~line 800, gain, rebuild path),
`Mila/Audio/SystemAudioRecorder.swift` (SCStream output ~line 460, `deliver`),
`Mila/Audio/AdaptiveGainController.swift`, and the tests
`RecordingSessionMetersTests`, `RecordingSessionPauseTests`, `AppSceneChurnTests`,
`MicrophoneRecorderTests`, `SystemAudioSessionStreamTests`.
Project settings: Swift 5.10, `SWIFT_STRICT_CONCURRENCY: minimal`.

## Part A — capture timestamps (new file + two tiny hooks)

New file `Mila/Audio/CaptureTimestampQueue.swift`:

```swift
/// FIFO of per-buffer host timestamps, filled by a capture callback right
/// before it yields a buffer and drained by the consumer as it receives the
/// same buffers, in the same order. Lock-protected; bounded.
final class CaptureTimestampQueue: @unchecked Sendable {
    init(capacity: Int = 4096)
    var isEnabled: Bool { get set }          // producer records only when enabled
    func push(_ hostTimeSeconds: Double?)    // producer; no-op when disabled; drops oldest when full
    func pop() -> Double?                    // consumer; nil when empty
    func reset()
}
```

Hooks (mark `// FORK:`):
- `MicrophoneRecorder`: add `let timestamps = CaptureTimestampQueue()`. In the tap
  closure, change `{ buffer, _ in` to `{ buffer, when in` and, immediately before
  `continuation.yield(toMutate)`, push
  `when.isHostTimeValid ? AVAudioTime.seconds(forHostTime: when.hostTime) : nil`.
  The tap closure is created in a static/nonisolated bring-up function — pass the
  queue in the same way `gain`/`stats` are passed (read `realBringUp`). The queue
  is `@unchecked Sendable`, so capturing it is fine.
- `SystemAudioRecorder`: add `let timestamps = CaptureTimestampQueue()` reachable
  from its sample-queue output object. In `stream(_:didOutputSampleBuffer:of:)`
  read `CMSampleBufferGetPresentationTimeStamp(sampleBuffer)`; pass it through
  `deliver(_:hostTimeSeconds:)` (new defaulted parameter, so existing callers and
  tests compile unchanged) and push it right before `continuation?.yield(converted)`.
  Conversion: ScreenCaptureKit sample-buffer timestamps are on the host time clock;
  use `CMTimeGetSeconds(pts)` when `pts.isValid && pts.isNumeric`, else nil.
  `AVAudioTime.seconds(forHostTime:)` is on the same mach host clock. This
  assumption is checked at runtime (Part C, sanity guard) — do not skip that guard.
- Converter latency (`StreamingWhisperConverter`) is ignored (a few ms; the stage's
  lead + filter length absorb it).

## Part B — gain after cancellation

`AdaptiveGainController` (200 ms attack) runs inside the mic tap today. Gain that
moves underneath an adaptive echo filter looks like a changing echo path, so with
AEC on, apply gain AFTER the canceller:
- `MicrophoneRecorder`: add `var deferGainToConsumer = false` (set before
  `start()`). The tap applies `gain.process` only when it is false. The value must
  be captured at bring-up AND at every rebuild (read the rebuild path).
- `RecordingSession` applies `mic.gain` to the cleaned samples when it deferred
  gain (`AdaptiveGainController.process(_ samples: [Float]) -> [Float]` exists —
  verify). Gain state is then touched only from the main actor while recording;
  confirm nothing else calls `process` on that controller concurrently.
- `DictationController` uses its own recorder and never sets the flag: unchanged.

## Part C — `RecordingSession` integration (hooks, marked `// FORK:`)

State: `private var echoStage: EchoCancellationStage?`,
`private var echoTimestampsTrusted = true`, `private var deferredGain = false`.

`start(source:outputURL:)` — before the mic starts:
- If `source == .meeting` and `EchoCancellationSettings.isEnabled(.standard)`:
  create the stage (`EchoCancellationStage(configuration: .init())`). On nil:
  log an error, record a bypass summary (Part E), continue without AEC.
  On success: `mic.timestamps.isEnabled = true`, `system.timestamps.isEnabled = true`,
  reset both queues, `mic.deferGainToConsumer = true`, `deferredGain = true`.
- Otherwise: queues disabled, `mic.deferGainToConsumer = false`, stage nil.
- `startFakeForTesting` never creates a stage (upstream tests drive it and must
  see unchanged behaviour). Add an internal test seam instead, e.g.
  `func installEchoStageForTesting(_ stage: EchoCancellationStage?, deferGain: Bool)`.
- Put the stage construction/teardown in a new file
  (`Mila/Audio/RecordingSession+EchoCancellation.swift`, an extension) and keep the
  hooks inside `RecordingSession.swift` to single calls where possible.

`consumeSystem(_:)`:
- FIRST line (before the pause guard): `let ts = system.timestamps.pop()` — the
  queue must be drained for every buffer, including ones dropped while paused.
- In the meeting branch, before `pendingSystem.append`, call
  `echoStage?.appendReference(samples, hostTimeSeconds: echoTimestampsTrusted ? ts : nil)`.

`consumeMic(_:)`:
- FIRST line: `let ts = mic.timestamps.pop()`.
- Meeting branch: when `echoStage != nil`, `let clean = stage.processMicrophone(samples, hostTimeSeconds: echoTimestampsTrusted ? ts : nil)`,
  then gain if deferred, then `mixWithBufferedSystem(mic: clean)` → live feed →
  write. If `clean` is empty, skip the mix/live/write calls for this buffer. Keep
  the meter on the raw buffer as today.
- Sanity guard (once per session, after both streams have produced a timestamp):
  if `abs(firstMicTs - firstRefTs) > 5 s`, set `echoTimestampsTrusted = false`,
  call `resetTimeline(resetFilter: false)` after flushing held samples, and log it
  (`.public` numbers only). The stage then runs in contiguous mode.

`pause()`: before `flushPendingSystemTail()`, flush the stage
(`stage.flush()` → gain if deferred → mix with pending system → write; NOT the
live feed if upstream pause doesn't feed it — mirror what `flushPendingSystemTail`
does), then `stage.resetTimeline(resetFilter: false)`.

`resume()`: nothing extra (timeline already reset; `pendingSystem` is cleared
upstream).

`stop()`: after `mic.stop()`/`system.stop()` and task cancellation, BEFORE
`flushPendingSystemTail()`: flush the stage the same way as pause, log the stage
statistics (public numbers only), write the session summary (Part E), set
`echoStage = nil`, disable the queues, `mic.deferGainToConsumer = false`.
Note `state` is `.stopping` here; `write` does not check state — confirm.

`cancelAll()`: drop the stage, disable queues, reset flags (no writes).

Mic capture rebuild mid-session (device change): the mic timestamps will jump;
the stage re-anchors by itself. Do NOT reset the filter on every configuration
notice; leave a TODO noting that resetting on an input-device change could help.

## Part D — settings + UI

New `Mila/Models/EchoCancellationSettings.swift` (`ObservableObject`, pattern of
existing small settings classes):
- `@Published var enabled: Bool` ↔ `echoCancellation.enabled` (code default false)
- `@Published var saveDebugAudio: Bool` ↔ `echoCancellation.saveDebugAudio` (false)
- `var lastSessionSummary: String?` ↔ `echoCancellation.lastSessionSummary` (read-only for UI; refreshed on appear)
- `static func isEnabled(_ defaults: UserDefaults) -> Bool`, `static func savesDebugAudio(_:)`
- `init(defaults: UserDefaults = .standard)`

`@StateObject` in `MilaApp.init()`, injected into the main window and Settings scene.

New `Mila/Views/EchoCancellationSettingsSection.swift`, inserted with one line
where the microphone/input settings live (find where `AudioInputSettings` /
automatic gain is shown in Settings):
- Toggle "Remove speaker echo from meeting recordings"
- Caption: "When you use speakers instead of headphones, your microphone also
  records the other participants. Mila removes that echo using the meeting audio
  it already captures. Works in Meeting recordings only. Changes apply to the next
  recording."
- Toggle "Save echo-cancellation debug audio" + caption: "Saves three extra WAV
  files per meeting (raw mic, aligned meeting audio, cleaned mic) in an
  `aec-debug` folder inside your recordings folder, for tuning. Delete them when
  done."
- Read-only "Last meeting: …" line from `lastSessionSummary`, e.g.
  "echo reduced ≈18 dB · echo delay ≈42 ms · reference present 63% of the time"
  or "bypassed: <reason>".

## Part E — session summary + debug audio

- At stop, build a one-line human summary from `statistics` and store it in
  `echoCancellation.lastSessionSummary` (no user content).
- Debug audio (only when `saveDebugAudio` and a stage exists): set
  `stage.frameObserver` to append near/far/out frames to three 16 kHz mono Float32
  WAV writers (`AVAudioFile`) under `<recordingsDirectory>/aec-debug/`, named from
  the recording's audio file base name + `.aec-mic.wav` / `.aec-ref.wav` /
  `.aec-clean.wav`. Derive the directory from `outputURL` (the WAV being
  written) so no store plumbing is needed. Write on a serial background queue (the
  frame observer fires on the main actor). Close the files at stop/cancel. Log
  paths `.private` only.

## Part F — project wiring

`project.yml` (mark `# FORK:`): add under `packages:`
`EchoCancellation: { path: Packages/EchoCancellation }` and add
`- package: EchoCancellation` to the `Mila` target dependencies and to `MilaTests`
if tests import it. Follow the exact YAML shape used for `MilaKit`.

## Tests (new files only)

- `MilaTests/CaptureTimestampQueueTests.swift`: order, disabled no-op, capacity
  drop-oldest, reset, concurrent push/pop smoke test.
- `MilaTests/RecordingSessionEchoCancellationTests.swift`: drive a fake session
  through the test seam, push synthetic mic buffers (echo of a known far signal)
  and system buffers with consistent timestamps via the queues, then stop and read
  the WAV back: echo energy in far-only spans is ≥ 10 dB lower than the same run
  with the stage absent; total written frame count equals mic frames (+ the system
  tail, as upstream); pause/resume/stop flush writes the held samples (no lost
  audio); a 5 s+ timestamp basis mismatch triggers contiguous mode. If
  `consumeSystem` is `private`, relax it to `internal` (smallest possible hook)
  with a `// FORK: internal for tests` comment, as upstream did for `consumeMic`.
- `MilaTests/EchoCancellationSettingsTests.swift`.
- Upstream tests (meters, pause, churn, mic, system stream) must pass unchanged:
  they never create a stage, and the timestamp queues are disabled by default.

## Acceptance

Fork CI green (build + full MilaTests + package tests). `FORK.md` ledger rows for
every upstream file touched. Final report lists the exact hook lines added to
`RecordingSession.swift`, `MicrophoneRecorder.swift`, `SystemAudioRecorder.swift`.

## Known limits to state in the report (do not try to solve them now)

- Only the captured app's audio is cancelled; other sounds playing through the
  speakers (notifications, music) are not in the reference.
- Mic-only recordings cannot be cancelled (no reference). The owner must use
  Meeting mode with speakers.
- Real acoustic quality must be verified on the Mac with the debug audio.
