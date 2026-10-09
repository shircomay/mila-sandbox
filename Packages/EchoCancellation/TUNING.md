# Tuning notes — echo cancellation core

Everything in here was **measured**, with the C harness in
`Tools/linux-harness/` (it compiles the vendored SpeexDSP sources and mirrors
`SpeexEchoCanceller.swift` frame for frame) and a Python model of
`EchoCancellationStage` (`stage_model.py`, validated against the same backend).
The Swift code could not be compiled or run where this was written (no Swift
toolchain); the Swift tests' thresholds are taken from these numbers with a margin
of 6–10 dB. Real acoustics are not covered: see "Limits" at the end and verify with
the debug audio (spec 03) on the Mac.

## Reproduce

```sh
cd Packages/EchoCancellation/Tools/linux-harness
sh build.sh build                                   # build/aec_harness + build/libaecharness.so  (cc -O2)
python3 tune.py --lib build/libaecharness.so --sections erle,transparency,doubletalk,delay,lead,nonlinear,sweep,stage
python3 calibrate_tests.py --lib build/libaecharness.so       # the quantities the Swift tests assert
python3 tune.py --lib build/libaecharness.so --sections sweep --noise-dbfs -70   # same sweep, quiet microphone
# optional: WebRTC AEC3 comparison (needs numpy + pywebrtc-audio in a venv outside the repo)
python3 -m venv /tmp/aec3-venv && /tmp/aec3-venv/bin/pip install numpy pywebrtc-audio
/tmp/aec3-venv/bin/python aec3_compare.py --lib build/libaecharness.so
```

Needs only `cc` and Python 3 with numpy (no scipy). Signals are generated
deterministically (SplitMix64) and nothing is written to disk except the build
products in `build/` (git-ignored). `aec_harness` also runs on raw float32 files
(`--near mic.f32 --far aligned_far.f32 --out out.f32`), e.g. converted debug audio.

### Signals and scoring

16 kHz mono. `far` = speech-like (syllable envelope, vowel formants, pitch 90–220 Hz,
0.3–1.2 s pauses of exact digital silence) at −15 dBFS RMS while speaking; `near` = a
different voice at −20 dBFS; echo = far through a synthetic room (direct path 40 ms
at gain 0.5, then an exponentially decaying Gaussian tail with RT60 250 ms holding
0.6x the direct-path energy, 400 ms long); `mic` = near + echo + white noise at
−50 dBFS. The backend gets the far stream advanced by the stage's 30 ms lead.

* **ERLE** = 10 log10(Σ mic² / Σ out²) over the samples of the window where the far
  end is active (window mean square > 1e-4). It includes the noise floor on both sides,
  so it saturates near (echo level − noise level) ≈ 27 dB in this setup; "residual vs
  noise floor" says how far above the noise floor the output still is.
* **Near-end transparency / double-talk** are measured against the *same backend run
  on the near-only microphone* (see finding 3 for why not against the raw input).

## Findings that changed the design

1. **Residual echo suppression only works with the denoiser on.** `preprocess.c`
   overwrites the computed gain with 1 when `SPEEX_PREPROCESS_SET_DENOISE` is 0, so
   "preprocessor with denoise off" is sample-for-sample identical to "no
   preprocessor" apart from its one-frame delay (checked: max difference 0.0; rows
   "residual OFF" and "residual ON, denoise OFF" in the sweep below are identical). The spec's `SET_DENOISE = noiseSuppression` would have made the
   residual suppressor a no-op by default. Implemented instead: denoise **on**, and
   `SET_NOISE_SUPPRESS = 0` dB when `noiseSuppression == false` (the denoiser's noise
   floor gain is then 1, so it only attenuates bands dominated by residual echo) or
   −15 dB (Speex's default) when `true`. Measured cost on near-end speech: −0.05 dB
   in double talk (OFF) vs −0.42 dB (ON); −0.45 dB vs −0.40 dB on near-only speech.
   Benefit: +4–5 dB ERLE during the first 12 s, +2 dB later.
2. **The preprocessor delays the output by exactly one frame (10 ms)** — its
   overlap-add emits the previous call's samples. Uncompensated that shifts the cleaned
   microphone by 10 ms against the app audio and loses the last 10 ms of a recording
   at flush. The backend therefore exposes `latencySamples` (an additive protocol
   requirement with a default of 0) and `EchoCancellationStage` drops the first
   `latencySamples` output samples of a pipeline and drains the same number with
   silent frames in `flush()`, so callers still get exactly as many samples as they
   put in, in place. `frameObserver` reports the compensated output, paired with the near/far samples it belongs to.
3. **Speex high-passes the microphone even with no echo** (the DC notch at the input of
   `mdf.c`: −0.9 dB at 100 Hz, −3.9 dB at 60 Hz, −19.5 dB at 20 Hz, with phase shift up
   to ~500 Hz). Waveform SNR against the raw input is therefore only ≈7 dB for a
   low-pitched voice although the signal is audibly unchanged; "transparent" is defined
   as "equal to the DC-notched input" (replica in `synth.dc_notch` / `SyntheticEcho.dcNotch`,
   matches the real thing to 74 dB). It does not matter for Whisper.
4. **Speex calls `exit(1)` for unsupported frame sizes** (kiss FFT: "max radix supported
   is 17" when the frame size has a prime factor above 17, e.g. 163 or 190). That would
   kill the app, so `SpeexEchoCanceller.init?` returns nil for such sizes (and outside
   32…4096 samples / 4…192 kHz).
5. **Convergence takes seconds.** ERLE is ≈6 dB in the first 3 s, ≈14 dB at 3–6 s and
   ≈20 dB from 6–12 s on. The first ~10 s of a meeting are only partly cleaned.
   WebRTC AEC3 converges faster (see the comparison).

## Chosen defaults

| Setting | Value | Why |
|---|---|---|
| `SpeexEchoCanceller.filterLengthMs` | 300 | Must cover echo delay + the stage's 30 ms lead + the room tail. Delay sweep: still 19.4 dB at a 200 ms echo delay (lag 230 ms); 100 ms fails (13–14 dB), 400 ms is slower to converge. A 150–200 ms filter converges 1.5–3 dB faster (sweep) but leaves no room for a long delay + lead + tail (a 200 ms echo delay is a 230 ms lag); configurable if real measurements show short delays. |
| `residualEchoSuppression` | true | +4–5 dB ERLE in the first 12 s / +2 dB later for −0.4 dB of near-end energy (sweep, double talk). |
| `echoSuppressDb` / `echoSuppressActiveDb` | −40 / −15 | Speex's own defaults. ERLE and double-talk retention are insensitive to them (−30/−10 … −60/−35 all within 0.4 dB, also with a −70 dBFS noise floor), so the least aggressive known-good values stay. |
| `noiseSuppression` | false | whisper gets the microphone's own noise floor. The denoiser still runs (finding 1) with a 0 dB noise floor. With −15 dB it would add ≈1–2 dB ERLE, partly just because the measurement counts noise. |
| `EchoCancellationStage.referenceLeadMs` | 30 | A non-causal filter cannot cancel: with the echo arriving *before* the reference (negative lag) ERLE is 1–2 dB; at lag ≥ 0 it is 21–25 dB. 30 ms lets a reference timestamp that is up to 30 ms late plus the true acoustic delay still be causal (lead sweep). |
| `holdMs` | 150 | Reference chunks that arrive up to ≈100 ms after the mic chunk covering the same time are waited for with no loss (stage table); at 140 ms late most frames time out and ERLE drops to ≈6 dB. Raising `holdMs` raises the output latency of the cleaned microphone when there is no reference at all. |
| `reanchorToleranceMs` | 20 | Spec value. Sample counting wins inside it, so timestamp jitter never moves the timeline; real gaps/overlaps (≥ 20 ms) re-anchor. |
| `referenceRetentionSeconds` | 10 | Spec value; the ring is 160 000 floats (640 kB). |

## Results

All numbers: default configuration, noise floor −50 dBFS, `tune.py` / `stage_scenarios.py`.

### Scenario 1 - far-only ERLE (dB) by time window

| 0-3 s | 3-6 s | 6-12 s | 12-25 s | 25-40 s | residual vs noise floor | delay est. |
|---|---|---|---|---|---|---|
| 6.1 | 13.6 | 20.1 | 20.8 | 25.0 | 5.9 dB | 70.0 ms |

### Scenario 2 - near-only transparency

| config | energy vs input (dB) | SNR vs DC-notched input (dB) | raw SNR vs input (dB) | corr vs DC-notched |
|---|---|---|---|---|
| residual suppression ON (default) | -0.45 | 42.4 | 7.2 | 0.99999 |
| residual suppression OFF (DC notch only) | -0.40 | (is the reference) | 7.2 | (is the reference) |

`SNR vs DC-notched input` compares with the input after the ~60 Hz high-pass that Speex's echo canceller always applies (replica in synth.dc_notch); `raw SNR` compares with the untouched input and is dominated by that filter's phase shift on low-pitched voices.

### Scenario 3 - double-talk (near-end speech + echo)

| config | DT frames | near retention energy (dB) | retention gain (dB) | corr vs ideal | (out-ideal) vs echo (dB) | (out-ideal) vs near (dB) |
|---|---|---|---|---|---|---|
| residual suppression ON (default) | 21% | -0.29 | -0.42 | 0.985 | -14.6 | -15.7 |
| residual suppression OFF | 21% | 0.07 | -0.05 | 0.986 | -14.7 | -15.8 |

### Scenario 4 - echo delay sweep (stage lead 30 ms)

| true echo delay | ERLE 6-12 s | ERLE 12-25 s | estimated (lag) | expected (delay+lead) |
|---|---|---|---|---|
| 0 ms | 21.0 | 24.1 | 30.0 ms | 30 ms |
| 20 ms | 19.4 | 21.9 | 50.0 ms | 50 ms |
| 60 ms | 21.2 | 21.1 | 90.0 ms | 90 ms |
| 120 ms | 22.8 | 21.6 | 150.0 ms | 150 ms |
| 200 ms | 20.1 | 19.4 | 230.0 ms | 230 ms |

### Reference lead: ERLE vs the lag between reference and echo (true echo delay 40 ms)

| lead applied to reference | lag of echo behind reference | ERLE 12-25 s | estimated lag |
|---|---|---|---|
| -80 ms | -40 ms | 1.0 | 0.1 ms |
| -60 ms | -20 ms | 1.9 | 26.8 ms |
| -40 ms | +0 ms | 25.1 | 0.0 ms |
| +0 ms | +40 ms | 23.0 | 40.0 ms |
| +30 ms | +70 ms | 20.9 | 70.0 ms |
| +60 ms | +100 ms | 21.2 | 100.0 ms |
| +100 ms | +140 ms | 21.3 | 140.0 ms |

### Scenario 5 - nonlinear echo path (tanh speaker, drive 3)

| echo path | ERLE 6-12 s | ERLE 12-25 s | residual vs noise floor |
|---|---|---|---|
| linear | 20.1 | 20.9 | 6.7 dB |
| tanh soft-clip | 13.4 | 13.2 | 12.2 dB |

### Parameter sweep (far-only ERLE, double-talk retention)

| variant | ERLE 3-6 s | 6-12 s | 12-25 s | 25-40 s | near-only energy (dB) | DT gain (dB) | DT (out-ideal) vs echo (dB) |
|---|---|---|---|---|---|---|---|
| filter 100 ms | 17.8 | 16.1 | 14.0 | 13.4 | -0.45 | -0.47 | -11.3 |
| filter 150 ms | 17.4 | 21.6 | 20.1 | 23.4 | -0.45 | -0.42 | -14.5 |
| filter 200 ms | 16.1 | 22.6 | 21.5 | 25.1 | -0.45 | -0.42 | -14.6 |
| filter 300 ms | 13.6 | 20.1 | 20.8 | 25.0 | -0.45 | -0.42 | -14.6 |
| filter 400 ms | 12.6 | 18.5 | 19.5 | 23.0 | -0.45 | -0.42 | -14.8 |
| residual OFF | 9.6 | 15.0 | 19.0 | 22.9 | -0.40 | -0.05 | -14.7 |
| residual ON, denoise OFF (no-op!) | 9.6 | 15.0 | 19.0 | 22.9 | -0.40 | -0.05 | -14.7 |
| suppress -30/-10 | 13.4 | 19.9 | 20.8 | 24.9 | -0.45 | -0.40 | -14.9 |
| suppress -40/-15 (default) | 13.6 | 20.1 | 20.8 | 25.0 | -0.45 | -0.42 | -14.6 |
| suppress -50/-25 | 13.7 | 20.2 | 20.9 | 25.0 | -0.45 | -0.44 | -14.3 |
| suppress -60/-35 | 13.7 | 20.3 | 20.9 | 25.0 | -0.45 | -0.45 | -14.2 |
| noise suppression -15 dB | 14.0 | 21.0 | 21.6 | 26.8 | -0.50 | -0.42 | -14.6 |

The same sweep with a −70 dBFS noise floor (the echo is then limited by the canceller,
not by the noise):

| variant | ERLE 3-6 s | 6-12 s | 12-25 s | 25-40 s | near-only energy (dB) | DT gain (dB) | DT (out-ideal) vs echo (dB) |
|---|---|---|---|---|---|---|---|
| filter 100 ms | 19.1 | 16.5 | 14.4 | 13.6 | -0.45 | -0.49 | -11.4 |
| filter 150 ms | 19.5 | 23.6 | 22.8 | 25.2 | -0.45 | -0.43 | -14.4 |
| filter 200 ms | 17.9 | 25.7 | 27.0 | 28.4 | -0.45 | -0.45 | -14.3 |
| filter 300 ms | 15.0 | 21.5 | 25.7 | 29.3 | -0.45 | -0.46 | -14.2 |
| filter 400 ms | 14.2 | 19.5 | 23.0 | 28.3 | -0.45 | -0.47 | -14.4 |
| residual OFF | 10.2 | 15.7 | 23.0 | 26.8 | -0.40 | -0.06 | -14.4 |
| residual ON, denoise OFF (no-op!) | 10.2 | 15.7 | 23.0 | 26.8 | -0.40 | -0.06 | -14.4 |
| suppress -30/-10 | 14.7 | 21.2 | 25.6 | 29.2 | -0.45 | -0.44 | -14.5 |
| suppress -40/-15 (default) | 15.0 | 21.5 | 25.7 | 29.3 | -0.45 | -0.46 | -14.2 |
| suppress -50/-25 | 15.1 | 21.7 | 25.8 | 29.4 | -0.45 | -0.48 | -13.9 |
| suppress -60/-35 | 15.1 | 21.8 | 25.8 | 29.5 | -0.45 | -0.49 | -13.8 |
| noise suppression -15 dB | 15.2 | 21.8 | 25.7 | 29.4 | -0.49 | -0.46 | -14.2 |

### Stage-level scenarios

Chunked like the app (mic 1365 samples / 85.3 ms, reference 320 samples / 20 ms,
arrival-ordered, timestamps on), through `stage_model.py`:

| scenario | length conserved | ERLE 6-12 s | ERLE 12-25 s | notes |
|---|---|---|---|---|
| baseline (all reference chunks delivered) | yes | 21.0 | 21.5 | offset 0 ms; delay est. 70.0 ms; stage ERLE stat 20.8 dB |
| silent reference chunks not delivered (SCK) | yes | 21.0 | 21.5 | framesWithReference 1882/3001, heldTooLong 915, ref re-anchors 13 |
| reference 20 ms later than mic | yes | 21.0 | 21.5 | heldTooLong 3, late/discarded 0 |
| reference 60 ms later than mic | yes | 21.0 | 21.5 | heldTooLong 3, late/discarded 0 |
| reference 100 ms later than mic | yes | 21.0 | 21.5 | heldTooLong 9, late/discarded 960 |
| reference 140 ms later than mic | yes | 7.6 | 5.9 | heldTooLong 1243, late/discarded 198560 |
| contiguous mode (hostTimeSeconds nil) | yes | 21.0 | 21.5 |  |
| reference stream starts 0.5 s after mic | yes | 22.9 | 22.0 | offset -500 ms |

#### Reference gaps (far end silent, no reference calls) - ERLE before and after

| window | ERLE (dB) |
|---|---|
| before gap 1 (8-12 s) | 22.0 |
| 0.5-3 s after gap 1 resumes (15.0-17.5 s) | 21.9 |
| 0.5-3 s after gap 2 resumes (19.7-22.2 s) | 24.0 |
| 0.0-0.5 s after gap 1 resumes (14.5-15.0 s) | 20.0 |

length conserved: True; reference re-anchors 12; heldTooLong 1062

#### Microphone timestamp jumps (simulated capture restart)

| metric | value |
|---|---|
| output length == input length | True (477600 vs 477600) |
| mic re-anchors | 2 |
| ERLE 6-10 s (before jump) | 20.9 |
| ERLE 18-28 s (after both jumps) | 23.5 |

#### No reference ever / contiguous-mode edge cases

| metric | value |
|---|---|
| length conserved | True |
| energy vs input (dB) | -0.46 |
| correlation vs DC-notched input | 0.99999 |
| correlation vs raw input | 0.9001 |
| SNR vs DC-notched input (dB) | 42.4 |
| framesHeldTooLong / framesProcessed | 2000 / 2001 |

#### Absurd timestamp basis (mic ~1e6 s, reference ~5 s)

| metric | value |
|---|---|
| length conserved | True |
| offset stat (ms) | 1e+09 |
| framesWithReference / framesProcessed | 0 / 2001 |
| framesHeldTooLong | 2000 |
| ERLE 12-20 s | 0.2 |
| wall time (s) | 0.19 |

#### Random chunk sizes (conservation + ordering)

| seed | length conserved | corr vs DC-notched input |
|---|---|---|
| 0 | True | 0.99999 |
| 1 | True | 0.99999 |
| 2 | True | 0.99999 |
| 3 | True | 0.99999 |
| 4 | True | 0.99999 |

#### Throughput

60 s of audio through the stage model (Python overhead included): 0.69 s

Throughput (this container, `cc -O2`, Speex only): 30 s of audio take about 0.3 s with the
residual suppressor and 0.2 s without (≈100–150x real time, about 1 % of a core). At `-O0`
it is ≈8x slower (1.0 s per 30 s), which is why `Package.swift` forces `-O2` for the
C target in debug builds.

## Swift test thresholds

`calibrate_tests.py` runs the exact scenarios of the XCTest suite (24 s signals) and
prints the measured value next to the threshold each test asserts:

| test | metric | measured | Swift threshold |
|---|---|---|---|
| backend far-only | ERLE 12-24 s | 20.800 | >= 12 |
| backend far-only | ERLE 6-12 s | 20.144 | (not asserted) |
| backend far-only | delay estimate (ms) | 70.000 | 70 +- 10 |
| backend near-only | SNR vs DC-notched input (dB) | 42.397 | >= 25 |
| backend near-only | energy vs DC-notched input (dB) | -0.057 | abs(x) <= 1 |
| backend near-only | correlation vs DC-notched | 1.000 | >= 0.999 |
| backend double-talk | DT fraction | 0.202 | (info) |
| backend double-talk | retention gain (dB) | -0.495 | abs(x) <= 1.5 |
| backend double-talk | correlation vs ideal | 0.985 | >= 0.90 |
| backend double-talk | (out-ideal) vs echo (dB) | -15.444 | <= -6 |
| backend reset | delay estimate right after reset | None | nil |
| backend reset | ERLE 12-14 s without reset | 19.714 | (info) |
| backend reset | ERLE 12-14 s with reset at 12 s | 4.442 | <= without - 6 |
| backend reset | ERLE 20-24 s (re-converged) | 19.929 | >= 8 |
| backend delay | estimate after 1 s | None | nil |
| backend delay | estimate, true delay 0 ms, at 14 s | 30.000 | 30 +- 10 |
| backend delay | estimate, true delay 120 ms, at 14 s | 150.000 | 150 +- 10 |
| backend delay | estimate, true delay 200 ms, at 14 s | 230.000 | 230 +- 10 |
| backend nonlinear | ERLE 12-24 s | 13.132 | >= 6 |
| stage chunked+ts | length conserved | True | true |
| stage chunked+ts | ERLE 12-24 s | 21.338 | >= 12 |
| stage chunked+ts | stat echoReductionDb | 18.411 | >= 10 |
| stage chunked+ts | stat estimatedEchoDelayMs | 70.000 | 70 +- 10 |
| stage chunked+ts | stat offset (ms) | 0.000 | abs(x) < 1 |
| stage chunked+ts | framesProcessed | 2401 | == 2401 |
| stage chunked+ts | framesWithReference | 1498 | > 0.25 * processed |
| stage chunked+ts | micReanchors/refReanchors | 0/0 | 0/0 |
| stage SCK silence | ERLE 12-24 s | 21.338 | >= 12 |
| stage SCK silence | referenceReanchors | 10 | >= 1 |
| stage ref 60ms late | ERLE 12-24 s | 21.338 | >= 12 |
| stage ref 60ms late | length conserved | True | true |
| stage ref 60ms late | referenceSamplesDiscarded | 0 | == 0 |
| stage contiguous | ERLE 12-24 s | 21.338 | >= 12 |
| stage contiguous | offset stat | None | nil |
| stage gaps | length conserved | True | true |
| stage gaps | ERLE 8-12 s (before) | 21.961 | (info) |
| stage gaps | ERLE 15.0-17.5 s (0.5-3 s after resume) | 21.904 | >= 12 |
| stage gaps | ERLE 20.7-23.2 s (0.5-3 s after resume 2) | 23.974 | >= 12 |
| stage gaps | referenceReanchors | 9 | >= 2 |
| stage mic jumps | length conserved | True | true |
| stage mic jumps | micReanchors | 2 | == 2 |
| stage mic jumps | ERLE 17-23 s | 23.900 | >= 12 |
| stage no reference | length conserved | True | true |
| stage no reference | correlation vs DC-notched input | 1.000 | > 0.999 |
| stage no reference | energy vs input (dB) | -0.463 | abs(x) < 1 |
| stage no reference (multitone) | correlation vs raw input | 0.997 | > 0.99 |
| stage no reference (multitone) | energy vs input (dB) | -0.008 | abs(x) < 1 |
| stage absurd basis | length conserved | True | true |
| stage absurd basis | offset stat (ms) | 999995000.000 | ~ 1e9 |
| stage absurd basis | framesWithReference | 0 | == 0 |
| stage random chunking | identical to 160-sample chunking (of 4 seeds) | 4 | == 4 |
| stage pause/resume | length conserved | True | true |
| stage pause/resume | ERLE 14-24 s (filter kept) | 21.370 | >= 12 |
| stage pause/resume | ERLE 12-14 s after resetFilter:true | 4.958 | < 12 |
| stage throughput (python model) | wall time for 60 s (s) | 0.689 | n/a (Swift: < 5) |

## WebRTC AEC3 comparison (optional)

`pywebrtc-audio` 0.2.0 (`EchoCanceller`, AEC3), same signals, same aligned far stream,
10 ms frames, default settings. Speex / AEC3:

#### Speex vs WebRTC AEC3: ERLE (dB), Speex / AEC3

| scenario | 3-6 s | 6-12 s | 12-25 s | 25-40 s |
|---|---|---|---|---|
| far-only (linear room) | 13.6 / 27.1 | 20.1 / 30.0 | 20.8 / 30.3 | 25.0 / 31.2 |
| far-only, tanh speaker | 13.1 / 25.1 | 13.5 / 25.3 | 13.3 / 27.2 | 13.9 / 26.6 |
| far-only, echo delay 120 ms | 16.6 / 26.9 | 22.7 / 29.3 | 21.6 / 29.8 | 24.7 / 30.0 |

#### Double talk (12-40 s): near-end retention vs the same canceller on the near-only microphone

| canceller | retention gain (dB) | correlation | (out-ideal) vs echo (dB) |
|---|---|---|---|
| Speex | -0.42 | 0.985 | -14.6 |
| AEC3 | -4.37 | 0.827 | -4.3 |

#### Near-end only (far silent)

| canceller | energy vs input (dB) | output lag | correlation at that lag |
|---|---|---|---|
| Speex | -0.46 | -0.1 ms | 0.913 |
| AEC3 | -0.45 | 7.9 ms | 0.846 |

Reading: AEC3 converges within 3 s, reaches ≈30 dB (≈25–27 dB through the nonlinear
speaker where Speex stays at ≈13 dB) and is insensitive to the echo delay. It pays for
it in double talk: against the same canceller on the near-only microphone it removes
4.4 dB of near-end speech energy (correlation 0.83) where Speex removes 0.4 dB (0.985),
and it delays the output by ≈8 ms. For transcription that trade-off is not obviously
better, so Speex stays the v1 backend; swapping is cheap because
`EchoCancellationStage` only depends on `EchoCancellerBackend` (and `latencySamples`
handles the delay). If listening tests on real recordings show residual echo, an AEC3
backend is the first thing to try; if they show clipped near-end speech, keep Speex.

## Limits

* Synthetic speech, a synthetic linear room (and one tanh speaker), white noise. Real
  laptop speakers, rooms with moving people, clock drift between the two capture clocks
  and AGC in the microphone path are not modelled. ERLE ≈20 dB here is a statement about
  the algorithm and the stage, not a promise for a particular Mac.
* The reference is only the captured app's audio: notification sounds and music from
  other apps are not in it and are not cancelled.
* ERLE in the table is bounded by the −50 dBFS noise floor in the signal (see the
  −70 dBFS sweep for the headroom of the canceller itself).
* The Python stage model and the Swift stage are two implementations of the same
  algorithm (the model found a real bug in the first draft, a frame straddling two
  timeline segments, before any Swift was written); if either changes, change the other
  and re-run `calibrate_tests.py`.
