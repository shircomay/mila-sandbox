"""Stage-level scenarios (chunked, timestamped) run through stage_model.py.

These mirror the cases in Tests/EchoCancellationTests/EchoCancellationStageTests.swift;
the numbers in TUNING.md and the Swift thresholds come from here.
"""
from __future__ import annotations

import math
import time
from typing import Callable, List, Optional

import numpy as np

import synth
import tune
from backend import BackendConfig
from stage_model import Stage, StageConfig

SR = tune.SR
MIC_CHUNK = 1365      # 85.3 ms: what AVAudioEngine delivers at 16 kHz after conversion
REF_CHUNK = 320       # 20 ms: ScreenCaptureKit
BASE = 52_000.0       # host-clock seconds of sample 0


def feed(stage: Stage, mic: np.ndarray, ref: np.ndarray, *,
         mic_chunk: int = MIC_CHUNK, ref_chunk: int = REF_CHUNK, ref_late_ms: float = 0.0,
         use_ts: bool = True, base: float = BASE, ref_base: Optional[float] = None,
         ref_start_s: float = 0.0, skip_silent_ref: bool = False,
         mic_true_idx: Optional[np.ndarray] = None,
         mic_chunks: Optional[List[int]] = None) -> np.ndarray:
    """Deliver chunks in arrival order (a chunk "arrives" when its last sample was
    captured, plus ref_late_ms for the reference) and return the concatenated
    stage output including flush(). `skip_silent_ref` drops all-zero reference
    chunks like ScreenCaptureKit, which stops delivering during silence.
    `mic_true_idx[i]` (optional) is the true capture index of mic sample i, for
    streams with gaps / repeats: chunk timestamps and arrival times follow it."""
    events = []
    pos = 0
    arrival = 0.0
    sizes = iter(mic_chunks) if mic_chunks is not None else None
    while pos < len(mic):
        size = next(sizes) if sizes is not None else mic_chunk
        c = mic[pos:pos + size]
        if mic_true_idx is not None:
            arrival = max(arrival, (mic_true_idx[pos + len(c) - 1] + 1) / SR)
        else:
            arrival = (pos + len(c)) / SR
        events.append((arrival, 0, "m", pos, c))
        pos += len(c)
    for j in range(int(ref_start_s * SR), len(ref), ref_chunk):
        c = ref[j:j + ref_chunk]
        if skip_silent_ref and not np.any(c):
            continue
        events.append(((j + len(c)) / SR + ref_late_ms / 1000.0, 1, "r", j, c))
    events.sort(key=lambda e: (e[0], e[1]))
    rb = base if ref_base is None else ref_base
    outs: List[np.ndarray] = []
    for _, _, kind, idx, c in events:
        if kind == "m":
            first = idx if mic_true_idx is None else mic_true_idx[idx]
            ts = (base + first / SR) if use_ts else None
            outs.append(stage.process_microphone(c, ts))
        else:
            ts = (rb + idx / SR) if use_ts else None
            stage.append_reference(c, ts)
    outs.append(stage.flush())
    return np.concatenate(outs)


def make_stage(cfg: BackendConfig, **kw) -> Stage:
    return Stage(StageConfig(backend=cfg, **kw))


def gappy_far(seconds: float, gaps: List[tuple]) -> np.ndarray:
    far = tune.far_signal(seconds).copy()
    for a, b in gaps:
        far[int(a * SR):int(b * SR)] = 0.0
    return far


def run_all(cfg: BackendConfig) -> None:
    seconds = 30
    far = tune.far_signal(seconds)
    mic = tune.echo_signal(seconds) + tune.noise_signal(seconds)
    print("\n### Stage scenarios (model of EchoCancellationStage; mic chunks 1365, reference chunks 320, timestamps on)\n")
    rows = []

    def add(name, out, length_ref, notes=""):
        rows.append([name, "yes" if len(out) == length_ref else f"NO ({len(out)} vs {length_ref})",
                     tune.fmt(tune.erle(mic, out, far, 6, 12)), tune.fmt(tune.erle(mic, out, far, 12, 25)), notes])

    st = make_stage(cfg)
    out = feed(st, mic, far)
    s = st.statistics
    add("baseline (all reference chunks delivered)", len(out) and out, len(mic),
        f"offset {s.initial_mic_to_reference_offset_ms:.0f} ms; delay est. {s.estimated_echo_delay_ms} ms; stage ERLE stat {s.echo_reduction_db:.1f} dB")
    st = make_stage(cfg)
    out = feed(st, mic, far, skip_silent_ref=True)
    s = st.statistics
    add("silent reference chunks not delivered (SCK)", out, len(mic),
        f"framesWithReference {s.frames_with_reference}/{s.frames_processed}, heldTooLong {s.frames_held_too_long}, ref re-anchors {s.reference_reanchors}")
    for late in (20, 60, 100, 140):
        st = make_stage(cfg)
        out = feed(st, mic, far, ref_late_ms=late)
        add(f"reference {late} ms later than mic", out, len(mic),
            f"heldTooLong {st.statistics.frames_held_too_long}, late/discarded {st.statistics.reference_samples_discarded}")
    st = make_stage(cfg)
    out = feed(st, mic, far, use_ts=False)
    add("contiguous mode (hostTimeSeconds nil)", out, len(mic))
    st = make_stage(cfg)
    out = feed(st, mic, far, ref_start_s=0.5)
    add("reference stream starts 0.5 s after mic", out, len(mic), f"offset {st.statistics.initial_mic_to_reference_offset_ms:.0f} ms")
    print(tune.table(["scenario", "length conserved", "ERLE 6-12 s", "ERLE 12-25 s", "notes"], rows))

    # ---- gaps -------------------------------------------------------------
    print("\n#### Reference gaps (far end silent, no reference calls) - ERLE before and after\n")
    gaps = [(12.0, 14.5), (19.0, 20.2)]
    gfar = gappy_far(seconds, gaps)
    gmic = tune.synth.convolve(gfar, tune.rir()) + tune.noise_signal(seconds)
    rows = []
    st = make_stage(cfg)
    out = feed(st, gmic, gfar, skip_silent_ref=True)
    rows.append(["before gap 1 (8-12 s)", tune.fmt(tune.erle(gmic, out, gfar, 8, 12))])
    rows.append(["0.5-3 s after gap 1 resumes (15.0-17.5 s)", tune.fmt(tune.erle(gmic, out, gfar, 15.0, 17.5))])
    rows.append(["0.5-3 s after gap 2 resumes (19.7-22.2 s)", tune.fmt(tune.erle(gmic, out, gfar, 20.7, 23.2))])
    rows.append(["0.0-0.5 s after gap 1 resumes (14.5-15.0 s)", tune.fmt(tune.erle(gmic, out, gfar, 14.5, 15.0))])
    s = st.statistics
    print(tune.table(["window", "ERLE (dB)"], rows))
    print(f"\nlength conserved: {len(out) == len(gmic)}; reference re-anchors {s.reference_reanchors}; heldTooLong {s.frames_held_too_long}")

    # ---- mic timestamp jumps ------------------------------------------------
    print("\n#### Microphone timestamp jumps (simulated capture restart)\n")
    # forward jump: 0.35 s of mic audio lost at 10 s (samples removed, timestamps keep running);
    # backward overlap: the last 0.2 s delivered again at 16 s.
    cut0, cut1 = int(10.0 * SR), int(10.35 * SR)
    dup_at = int(16.0 * SR)
    dup = int(0.2 * SR)
    parts = [mic[:cut0], mic[cut1:dup_at], mic[dup_at - dup:]]
    mic2 = np.concatenate(parts)
    far2 = np.concatenate([far[:cut0], far[cut1:dup_at], far[dup_at - dup:]])
    # timestamps are the true capture times of each mic sample
    true_idx = np.concatenate([np.arange(0, cut0), np.arange(cut1, dup_at), np.arange(dup_at - dup, len(mic))])

    st = make_stage(cfg)
    out = feed(st, mic2, far, mic_true_idx=true_idx)
    s = st.statistics
    print(tune.table(["metric", "value"], [
        ["output length == input length", f"{len(out) == len(mic2)} ({len(out)} vs {len(mic2)})"],
        ["mic re-anchors", str(s.mic_reanchors)],
        ["ERLE 6-10 s (before jump)", tune.fmt(tune.erle(mic2, out, far2, 6, 10))],
        ["ERLE 18-28 s (after both jumps)", tune.fmt(tune.erle(mic2, out, far2, 18, 28))]]))

    # ---- no reference -------------------------------------------------------
    print("\n#### No reference ever / contiguous-mode edge cases\n")
    near = tune.near_signal(20) + tune.noise_signal(20)
    st = make_stage(cfg)
    out = feed(st, near, np.zeros(0, dtype=np.float32))
    ref_out = synth.dc_notch(near)
    c = float(np.dot(out, ref_out) / math.sqrt(np.dot(out, out) * np.dot(ref_out, ref_out)))
    craw = float(np.dot(out, near) / math.sqrt(np.dot(out, out) * np.dot(near, near)))
    print(tune.table(["metric", "value"], [
        ["length conserved", str(len(out) == len(near))],
        ["energy vs input (dB)", tune.fmt(tune.db(tune.energy(out) / tune.energy(near)), 2)],
        ["correlation vs DC-notched input", f"{c:.5f}"],
        ["correlation vs raw input", f"{craw:.4f}"],
        ["SNR vs DC-notched input (dB)", tune.fmt(tune.db(tune.energy(ref_out) / tune.energy(out - ref_out)))],
        ["framesHeldTooLong / framesProcessed", f"{st.statistics.frames_held_too_long} / {st.statistics.frames_processed}"]]))

    # ---- absurd timestamp basis ---------------------------------------------
    print("\n#### Absurd timestamp basis (mic ~1e6 s, reference ~5 s)\n")
    st = make_stage(cfg)
    t = time.time()
    out = feed(st, mic[:20 * SR], far[:20 * SR], base=1.0e6, ref_base=5.0)
    s = st.statistics
    print(tune.table(["metric", "value"], [
        ["length conserved", str(len(out) == 20 * SR)],
        ["offset stat (ms)", f"{s.initial_mic_to_reference_offset_ms:.3g}"],
        ["framesWithReference / framesProcessed", f"{s.frames_with_reference} / {s.frames_processed}"],
        ["framesHeldTooLong", str(s.frames_held_too_long)],
        ["ERLE 12-20 s", tune.fmt(tune.erle(mic[:20 * SR], out, far[:20 * SR], 12, 20))],
        ["wall time (s)", f"{time.time() - t:.2f}"]]))

    # ---- random chunking -----------------------------------------------------
    print("\n#### Random chunk sizes (conservation + ordering)\n")
    rng = np.random.default_rng(1234)
    rows = []
    sig = tune.near_signal(10) + tune.noise_signal(10)
    exp = synth.dc_notch(sig)
    for seed in range(5):
        r = np.random.default_rng(seed)
        sizes = list(r.integers(1, 4000, size=400))
        st = make_stage(cfg)
        out = feed(st, sig, far[:10 * SR] * 0.0, mic_chunks=sizes, ref_chunk=int(r.integers(50, 700)))
        c = float(np.dot(out, exp) / math.sqrt(np.dot(out, out) * np.dot(exp, exp)))
        rows.append([str(seed), str(len(out) == len(sig)), f"{c:.5f}"])
    print(tune.table(["seed", "length conserved", "corr vs DC-notched input"], rows))

    # ---- performance -----------------------------------------------------------
    print("\n#### Throughput\n")
    far60 = tune.far_signal(60)
    mic60 = tune.echo_signal(60) + tune.noise_signal(60)
    st = make_stage(cfg)
    t = time.time()
    out = feed(st, mic60, far60)
    print(f"60 s of audio through the stage model (Python overhead included): {time.time() - t:.2f} s")


if __name__ == "__main__":
    import os
    os.environ.setdefault("AEC_HARNESS_LIB", os.path.join("build", "libaecharness.so"))
    run_all(BackendConfig())
