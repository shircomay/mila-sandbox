#!/usr/bin/env python3
"""Measures exactly the quantities the Swift XCTest suite asserts, on the same
24 s synthetic scenario, so the thresholds in the tests can be justified (and
re-derived if the signals or defaults change).

    cd Packages/EchoCancellation/Tools/linux-harness
    sh build.sh build && python3 calibrate_tests.py --lib build/libaecharness.so

Each row: test, metric, measured value, threshold used in the Swift test.
"""
from __future__ import annotations

import argparse
import math
import os
import time
from typing import List

import numpy as np

import synth
import tune
import stage_scenarios as ss
from backend import Backend, BackendConfig

SR = tune.SR
S = 24                                     # seconds in the shared scenario
rows: List[List[str]] = []


def row(test: str, metric: str, value, threshold: str) -> None:
    v = f"{value:.3f}" if isinstance(value, float) else str(value)
    rows.append([test, metric, v, threshold])


def corr(a, b) -> float:
    a = np.asarray(a, dtype=np.float64)
    b = np.asarray(b, dtype=np.float64)
    return float(np.dot(a, b) / math.sqrt(np.dot(a, a) * np.dot(b, b)))


def main() -> None:
    ap = argparse.ArgumentParser()
    ap.add_argument("--lib", default=os.path.join("build", "libaecharness.so"))
    args = ap.parse_args()
    os.environ["AEC_HARNESS_LIB"] = args.lib
    cfg = BackendConfig()

    far = tune.far_signal(S)
    near = tune.near_signal(S)
    noise = tune.noise_signal(S)
    echo = tune.echo_signal(S)
    far_al = tune.aligned_far(S)
    mic = echo + noise

    # ---- SpeexEchoCancellerTests -------------------------------------------------
    out, delay = tune.run_backend(cfg, mic, far_al)
    row("backend far-only", "ERLE 12-24 s", tune.erle(mic, out, far_al, 12, 24), ">= 12")
    row("backend far-only", "ERLE 6-12 s", tune.erle(mic, out, far_al, 6, 12), "(not asserted)")
    row("backend far-only", "delay estimate (ms)", delay, "70 +- 10")

    n20 = 20 * SR
    nm = (near + noise)[:n20]
    o_on, _ = tune.run_backend(cfg, nm, np.zeros(n20, dtype=np.float32))
    ref = synth.dc_notch(nm)
    a, b = ref[2 * SR:].astype(np.float64), o_on[2 * SR:].astype(np.float64)
    row("backend near-only", "SNR vs DC-notched input (dB)", tune.db(tune.energy(a) / tune.energy(b - a)), ">= 25")
    row("backend near-only", "energy vs DC-notched input (dB)", tune.db(tune.energy(b) / tune.energy(a)), "abs(x) <= 1")
    row("backend near-only", "correlation vs DC-notched", corr(a, b), ">= 0.999")

    ideal, _ = tune.run_backend(cfg, near + noise, np.zeros(S * SR, dtype=np.float32))
    dt_mic = near + echo + noise
    o_dt, _ = tune.run_backend(cfg, dt_mic, far_al)
    s, e = 12 * SR, S * SR
    dt = (tune.active_mask(near) & tune.active_mask(echo))[s:e]
    o, i, ec = o_dt[s:e][dt].astype(np.float64), ideal[s:e][dt].astype(np.float64), echo[s:e][dt].astype(np.float64)
    g = float(np.dot(o, i) / np.dot(i, i))
    row("backend double-talk", "DT fraction", float(dt.mean()), "(info)")
    row("backend double-talk", "retention gain (dB)", 20 * math.log10(abs(g)), "abs(x) <= 1.5")
    row("backend double-talk", "correlation vs ideal", corr(o, i), ">= 0.90")
    row("backend double-talk", "(out-ideal) vs echo (dB)", tune.db(tune.energy(o - i) / tune.energy(ec)), "<= -6")

    # reset
    b1 = Backend(cfg)
    b2 = Backend(cfg)
    nfr = 160
    def run_frames(b, lo_s, hi_s, out_arr):
        for k in range(int(lo_s * SR) // nfr, int(hi_s * SR) // nfr):
            sl = slice(k * nfr, (k + 1) * nfr)
            b.process(np.ascontiguousarray(mic[sl]), np.ascontiguousarray(far_al[sl]), out_arr[sl])
    oa = np.zeros(S * SR, dtype=np.float32)
    ob = np.zeros(S * SR, dtype=np.float32)
    run_frames(b1, 0, 12, oa)
    run_frames(b2, 0, 12, ob)
    b2.reset()
    row("backend reset", "delay estimate right after reset", b2.delay_ms(), "nil")
    run_frames(b1, 12, 14, oa)
    run_frames(b2, 12, 14, ob)
    L = b1.latency_samples
    oa2 = np.concatenate([oa[L:], np.zeros(L, dtype=np.float32)])
    ob2 = np.concatenate([ob[L:], np.zeros(L, dtype=np.float32)])
    ea = tune.erle(mic, oa2, far_al, 12, 14)
    eb = tune.erle(mic, ob2, far_al, 12, 14)
    row("backend reset", "ERLE 12-14 s without reset", ea, "(info)")
    row("backend reset", "ERLE 12-14 s with reset at 12 s", eb, "<= without - 6")
    run_frames(b2, 14, S, ob)
    ob2 = np.concatenate([ob[L:], np.zeros(L, dtype=np.float32)])
    row("backend reset", "ERLE 20-24 s (re-converged)", tune.erle(mic, ob2, far_al, 20, 24), ">= 8")

    b3 = Backend(cfg)
    one_s = np.zeros(S * SR, dtype=np.float32)
    for k in range(0, 100):
        sl = slice(k * nfr, (k + 1) * nfr)
        b3.process(np.ascontiguousarray(mic[sl]), np.ascontiguousarray(far_al[sl]), one_s[sl])
    row("backend delay", "estimate after 1 s", b3.delay_ms(), "nil")
    for d in (0, 120, 200):
        n14 = 14 * SR      # first 14 s of the shared scenario, like the Swift test
        echo_d = synth.convolve(far[:n14], tune.rir(delay_ms=float(d)))
        mic_d = echo_d + noise[:n14]
        _, dd = tune.run_backend(cfg, mic_d, far_al[:n14])
        row("backend delay", f"estimate, true delay {d} ms, at 14 s", dd, f"{d + 30} +- 10")

    nl_echo = tune.echo_signal(S, nonlinear=True)
    nl_mic = nl_echo + noise
    o_nl, _ = tune.run_backend(cfg, nl_mic, far_al)
    row("backend nonlinear", "ERLE 12-24 s", tune.erle(nl_mic, o_nl, far_al, 12, 24), ">= 6")

    # ---- EchoCancellationStageTests -----------------------------------------------
    st = ss.make_stage(cfg)
    out = ss.feed(st, mic, far)
    stt = st.statistics
    row("stage chunked+ts", "length conserved", len(out) == len(mic), "true")
    row("stage chunked+ts", "ERLE 12-24 s", tune.erle(mic, out, far, 12, 24), ">= 12")
    row("stage chunked+ts", "stat echoReductionDb", stt.echo_reduction_db, ">= 10")
    row("stage chunked+ts", "stat estimatedEchoDelayMs", stt.estimated_echo_delay_ms, "70 +- 10")
    row("stage chunked+ts", "stat offset (ms)", stt.initial_mic_to_reference_offset_ms, "abs(x) < 1")
    row("stage chunked+ts", "framesProcessed", stt.frames_processed, f"== {len(mic) // 160 + 1}")
    row("stage chunked+ts", "framesWithReference", stt.frames_with_reference, "> 0.25 * processed")
    row("stage chunked+ts", "micReanchors/refReanchors", f"{stt.mic_reanchors}/{stt.reference_reanchors}", "0/0")

    st = ss.make_stage(cfg)
    out = ss.feed(st, mic, far, skip_silent_ref=True)
    stt = st.statistics
    row("stage SCK silence", "ERLE 12-24 s", tune.erle(mic, out, far, 12, 24), ">= 12")
    row("stage SCK silence", "referenceReanchors", stt.reference_reanchors, ">= 1")

    st = ss.make_stage(cfg)
    out = ss.feed(st, mic, far, ref_late_ms=60)
    row("stage ref 60ms late", "ERLE 12-24 s", tune.erle(mic, out, far, 12, 24), ">= 12")
    row("stage ref 60ms late", "length conserved", len(out) == len(mic), "true")
    row("stage ref 60ms late", "referenceSamplesDiscarded", st.statistics.reference_samples_discarded, "== 0")

    st = ss.make_stage(cfg)
    out = ss.feed(st, mic, far, use_ts=False)
    row("stage contiguous", "ERLE 12-24 s", tune.erle(mic, out, far, 12, 24), ">= 12")
    row("stage contiguous", "offset stat", st.statistics.initial_mic_to_reference_offset_ms, "nil")

    # gaps
    gaps = [(12.0, 14.5), (19.0, 20.2)]
    gfar = ss.gappy_far(S, gaps)
    gecho = synth.convolve(gfar, tune.rir())
    gmic = gecho + noise
    st = ss.make_stage(cfg)
    out = ss.feed(st, gmic, gfar, skip_silent_ref=True)
    row("stage gaps", "length conserved", len(out) == len(gmic), "true")
    row("stage gaps", "ERLE 8-12 s (before)", tune.erle(gmic, out, gfar, 8, 12), "(info)")
    row("stage gaps", "ERLE 15.0-17.5 s (0.5-3 s after resume)", tune.erle(gmic, out, gfar, 15.0, 17.5), ">= 12")
    row("stage gaps", "ERLE 20.7-23.2 s (0.5-3 s after resume 2)", tune.erle(gmic, out, gfar, 20.7, 23.2), ">= 12")
    row("stage gaps", "referenceReanchors", st.statistics.reference_reanchors, ">= 2")

    # mic jumps
    cut0, cut1 = int(10.0 * SR), int(10.35 * SR)
    dup_at, dup = int(16.0 * SR), int(0.2 * SR)
    mic2 = np.concatenate([mic[:cut0], mic[cut1:dup_at], mic[dup_at - dup:]])
    far2 = np.concatenate([far[:cut0], far[cut1:dup_at], far[dup_at - dup:]])
    true_idx = np.concatenate([np.arange(0, cut0), np.arange(cut1, dup_at), np.arange(dup_at - dup, len(mic))])
    st = ss.make_stage(cfg)
    out = ss.feed(st, mic2, far, mic_true_idx=true_idx)
    row("stage mic jumps", "length conserved", len(out) == len(mic2), "true")
    row("stage mic jumps", "micReanchors", st.statistics.mic_reanchors, "== 2")
    row("stage mic jumps", "ERLE 17-23 s", tune.erle(mic2, out, far2, 17, 23), ">= 12")

    # no reference
    nm24 = near + noise
    st = ss.make_stage(cfg)
    out = ss.feed(st, nm24, np.zeros(0, dtype=np.float32))
    exp = synth.dc_notch(nm24)
    row("stage no reference", "length conserved", len(out) == len(nm24), "true")
    row("stage no reference", "correlation vs DC-notched input", corr(out, exp), "> 0.999")
    row("stage no reference", "energy vs input (dB)", tune.db(tune.energy(out) / tune.energy(nm24)), "abs(x) < 1")

    tones = synth.multitone(5, 8.0)
    tmic = tones + noise[:len(tones)]
    st = ss.make_stage(cfg)
    out = ss.feed(st, tmic, np.zeros(0, dtype=np.float32))
    row("stage no reference (multitone)", "correlation vs raw input", corr(out, tmic), "> 0.99")
    row("stage no reference (multitone)", "energy vs input (dB)", tune.db(tune.energy(out) / tune.energy(tmic)), "abs(x) < 1")

    # absurd basis
    st = ss.make_stage(cfg)
    n10 = 10 * SR
    out = ss.feed(st, mic[:n10], far[:n10], base=1.0e6, ref_base=5.0)
    row("stage absurd basis", "length conserved", len(out) == n10, "true")
    row("stage absurd basis", "offset stat (ms)", st.statistics.initial_mic_to_reference_offset_ms, "~ 1e9")
    row("stage absurd basis", "framesWithReference", st.statistics.frames_with_reference, "== 0")

    # random chunking equality
    sig = (near + noise)[:10 * SR]
    refsig = far[:10 * SR]
    def run_ref_first(sizes):
        stg = ss.make_stage(cfg)
        stg.append_reference(refsig, ss.BASE)
        outs = []
        pos, k = 0, 0
        while pos < len(sig):
            size = sizes[k % len(sizes)]
            k += 1
            c = sig[pos:pos + size]
            outs.append(stg.process_microphone(c, ss.BASE + pos / SR))
            pos += len(c)
        outs.append(stg.flush())
        return np.concatenate(outs)
    canon = run_ref_first([160])
    same = 0
    for seed in range(4):
        r = np.random.default_rng(seed)
        o2 = run_ref_first(list(r.integers(1, 4000, size=300)))
        same += int(np.array_equal(o2, canon))
    row("stage random chunking", "identical to 160-sample chunking (of 4 seeds)", same, "== 4")

    # pause / resume
    st = ss.make_stage(cfg)
    outs = []
    half = 12 * SR
    ev1 = ss.feed(st, mic[:half], far[:half])
    # feed() already flushed; now resume 30 s later on both streams
    st.reset_timeline(reset_filter=False)
    ev2 = ss.feed(st, mic[half:], far[half:], base=ss.BASE + 30.0 + 12.0)
    o_all = np.concatenate([ev1, ev2])
    row("stage pause/resume", "length conserved", len(o_all) == len(mic), "true")
    row("stage pause/resume", "ERLE 14-24 s (filter kept)", tune.erle(mic, o_all, far, 14, 24), ">= 12")
    st = ss.make_stage(cfg)
    ev1 = ss.feed(st, mic[:half], far[:half])
    st.reset_timeline(reset_filter=True)
    ev2 = ss.feed(st, mic[half:], far[half:], base=ss.BASE + 30.0 + 12.0)
    o_all = np.concatenate([ev1, ev2])
    row("stage pause/resume", "ERLE 12-14 s after resetFilter:true", tune.erle(mic, o_all, far, 12, 14), "< 12")

    # throughput
    far60 = np.concatenate([far, far, far[:12 * SR]])
    mic60 = np.concatenate([mic, mic, mic[:12 * SR]])
    st = ss.make_stage(cfg)
    t = time.time()
    out = ss.feed(st, mic60, far60)
    row("stage throughput (python model)", "wall time for 60 s (s)", time.time() - t, "n/a (Swift: < 5)")

    print(tune.table(["test", "metric", "measured", "Swift threshold"], rows))


if __name__ == "__main__":
    main()
