# feat: remove speaker echo from meeting recordings (opt-in echo cancellation against the captured app audio)

**Problem / use case**

In Meeting mode Mila records two things: the microphone and the meeting app's
audio (ScreenCaptureKit), and mixes them into one WAV. With headphones that is
exactly right. Without headphones it is not: the laptop speakers play the
other participants, the microphone picks them up again, and every remote voice
ends up in the recording twice, once clean from the app and once from the
microphone, delayed and reverberant. Whisper can then transcribe the same
sentences twice, or a blend of the two copies, and the recording is simply
harder to listen to.

It is not something the current mix can fix by itself. `RecordingSession`
pairs the two streams by arrival order: each microphone chunk pulls an equal
span out of the buffered app audio. ScreenCaptureKit delivers nothing while the
app is silent, so the offset between "what the app played" and "what the
microphone heard" changes every time the far end pauses and resumes. To cancel
an echo you have to know how far behind the reference the echo is, and that
number is not recoverable from arrival order. It needs to know when each buffer
was actually captured, on one clock.

**Proposed solution**

An opt-in acoustic echo canceller on the microphone, using the app audio Mila
already captures as the reference, run before the mix so the app audio stays
in the recording exactly once:

1. **Capture timestamps.** The microphone tap and the ScreenCaptureKit output
   record the host time of every buffer they yield, in a small bounded FIFO
   beside the existing `AsyncStream`s (the stream types stay as they are).
   Disabled and free unless echo cancellation is on.
2. **A local Swift package, `EchoCancellation`.** A stage that places both
   streams on one sample timeline from those timestamps, waits briefly (150 ms)
   for a frame's reference, feeds the reference slightly ahead of mic time
   (30 ms), treats reference gaps as silence, and never adds or drops a
   microphone sample. The canceller itself is SpeexDSP's adaptive filter plus
   its residual-echo suppressor, vendored as a small C target (BSD-3-Clause)
   behind a backend protocol.
3. **Meeting recordings only, behind a setting** in Settings > Audio ("Remove
   speaker echo from meeting recordings"), off by default, applied from the next
   recording. Adaptive gain moves to after the canceller when it is on (gain
   that changes under an adaptive filter looks like a changing echo path).
   Pause and stop write out whatever the stage is still holding.
4. **Diagnostics:** a one-line "last meeting" summary in Settings (estimated
   echo reduction, echo delay, how often a reference was present, or why the
   canceller was bypassed), and an optional, off-by-default "save debug audio"
   switch that writes the raw microphone, the aligned reference and the cleaned
   microphone as three parallel WAVs, so the result can be judged by ear.

With the setting off, nothing changes: no stage is created, the timestamp queues
stay disabled, and the recording path is the one that exists today.

**Alternatives considered**

- *Apple's voice-processing I/O* (`AVAudioEngine` voice processing). It cancels
  audio that your own engine plays out, which is not the situation here: the
  echo comes from another application's audio, which Mila only sees as a
  ScreenCaptureKit capture, not as output of its own audio unit. It also
  changes how the microphone is processed for every recording.
- *WebRTC AEC3.* A stronger canceller: in the same synthetic scenarios it
  converges within about 3 s and reaches roughly 30 dB, against Speex's roughly
  20 dB after ~6 s. The measured comparison is in
  `Packages/EchoCancellation/TUNING.md`. But in double talk it also removed about
  4.4 dB of the near-end speaker (correlation 0.83 against 0.985 for Speex),
  delays its output by about 8 ms, and is a much heavier dependency to build and vendor.
  For transcription, losing the near-end voice seems the worse trade, so the
  first version uses Speex; the stage only depends on a small backend protocol,
  so AEC3 can be tried later if real recordings call for it.
- *Headphones.* Works, and is the right advice, but not always an option
  (laptop in a meeting room, a guest at the desk).
- *Doing nothing and living with duplicates.* That is the status quo this issue
  is about.

**Additional context**

I have this implemented, with unit tests plus a full build and test run in CI.
The tuning numbers come from synthetic speech and a synthetic room, so they
describe the algorithm, not a particular laptop: I have **not** yet tried it
with real speakers and a real microphone. Because of that I will open the pull
request as a **draft** linked to this issue, and I would like to hear first
whether this is something you want in Mila at all, given that it adds a
vendored C library (about 6,000 lines, BSD-3-Clause) and touches the meeting
recording path. Happy to change the shape, the defaults or the scope (for
example, shipping only the timestamps and the package first).
