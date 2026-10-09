#!/usr/bin/env python3
"""Tuning scenarios for the Speex echo-cancellation backend and the
timestamp-aligned stage. Prints Markdown tables (pasted into TUNING.md).

    cd Packages/EchoCancellation/Tools/linux-harness
    sh build.sh build                          # -> build/libaecharness.so
    python3 tune.py --lib build/libaecharness.so --sections all

Sections (comma separated): erle, transparency, doubletalk, delay, nonlinear,
sweep (filter length / suppression settings), stage (chunked, timestamped
scenarios through stage_model.py), all.

Scoring conventions (also used by the Swift tests):
  * Signals are 16 kHz mono; far = "app audio", echo = far through a synthetic
    room, mic = near + echo + white noise at -50 dBFS.
  * The backend is fed the far stream advanced by LEAD (30 ms), exactly as the
    stage does, so the strongest filter tap sits at (echo delay + 30 ms).
  * "far-active" frames: 160-sample windows whose far mean-square > 1e-4.
  * ERLE = 10 log10( sum mic^2 / sum out^2 ) over far-active samples in the
    given window. It includes the -50 dBFS noise floor in both, so it
    saturates near (echo level - noise level) ~ 27 dB.
  * Transparency / double-talk are measured against the same backend run on the
    near-only signal (the static ~60 Hz DC-notch high-pass inside Speex's
    echo canceller changes the waveform of low-pitched voices, so comparing
    to the raw input would measure that filter, not the canceller).
"""
from __future__ import annotations

import argparse
import math
import os
import sys
import time
from typing import Dict, List, Optional, Tuple

import numpy as np

import synth
from backend import Backend, BackendConfig

SR = 16000
LEAD_MS = 30.0
LEAD = int(round(LEAD_MS * SR / 1000.0))

# Signal parameters (mirrored in SyntheticEcho.swift).
FAR_SEED, NEAR_SEED, NOISE_SEED, RIR_SEED = 1, 2, 3, 7
FAR_RMS_DBFS, NEAR_RMS_DBFS, NOISE_DBFS = -15.0, -20.0, -50.0
RIR_DELAY_MS, RIR_RT60_MS, RIR_GAIN = 40.0, 250.0, 0.5

_cache: Dict[tuple, object] = {}


def cached(key, fn):
    if key not in _cache:
        _cache[key] = fn()
    return _cache[key]


def far_signal(seconds: float) -> np.ndarray:
    return cached(("far", seconds), lambda: synth.speech_like(FAR_SEED, seconds, SR, FAR_RMS_DBFS)[0])


def near_signal(seconds: float) -> np.ndarray:
    return cached(("near", seconds), lambda: synth.speech_like(NEAR_SEED, seconds, SR, NEAR_RMS_DBFS)[0])


def noise_signal(seconds: float, dbfs: Optional[float] = None) -> np.ndarray:
    level = NOISE_DBFS if dbfs is None else dbfs
    return cached(("noise", seconds, level), lambda: synth.white_noise(NOISE_SEED, int(round(seconds * SR)), level))


def rir(delay_ms: float = RIR_DELAY_MS, rt60_ms: float = RIR_RT60_MS, gain: float = RIR_GAIN) -> np.ndarray:
    return cached(("rir", delay_ms, rt60_ms, gain), lambda: synth.room_ir(RIR_SEED, SR, delay_ms, rt60_ms, gain))


def echo_signal(seconds: float, delay_ms: float = RIR_DELAY_MS, rt60_ms: float = RIR_RT60_MS,
                gain: float = RIR_GAIN, nonlinear: bool = False) -> np.ndarray:
    def make():
        far = far_signal(seconds)
        if nonlinear:
            far = synth.speaker_nonlinearity(far)
        return synth.convolve(far, rir(delay_ms, rt60_ms, gain))
    return cached(("echo", seconds, delay_ms, rt60_ms, gain, nonlinear), make)


def aligned_far(seconds: float, lead: int = LEAD) -> np.ndarray:
    """The reference as the stage feeds it: advanced by `lead` samples
    (x[n] = far[n + lead]); a negative lead delays it instead."""
    far = far_signal(seconds)
    if lead >= 0:
        return np.concatenate([far[lead:], np.zeros(lead, dtype=np.float32)])
    return np.concatenate([np.zeros(-lead, dtype=np.float32), far[:lead]])


def energy(x) -> float:
    return float(np.sum(np.asarray(x, dtype=np.float64) ** 2))


def db(ratio: float) -> float:
    return 10.0 * math.log10(max(ratio, 1e-30))


def active_mask(x: np.ndarray, threshold: float = 1e-4, win: int = 160) -> np.ndarray:
    """True where the energy in the window [i - win/2, i + win/2) exceeds
    win * threshold (mean square > threshold). Same definition as the Swift tests."""
    sq = np.asarray(x, dtype=np.float64) ** 2
    c = np.concatenate([[0.0], np.cumsum(sq)])
    n = len(sq)
    i = np.arange(n)
    lo = np.clip(i - win // 2, 0, n)
    hi = np.clip(i + win // 2, 0, n)
    return (c[hi] - c[lo]) > win * threshold


def run_backend(cfg: BackendConfig, mic: np.ndarray, far_al: np.ndarray) -> Tuple[np.ndarray, Optional[float]]:
    """Run the backend and undo its algorithmic latency (the stage does the same)."""
    b = Backend(cfg)
    out = b.run(mic, far_al)
    lat = b.latency_samples
    out = np.concatenate([out[lat:], np.zeros(lat, dtype=np.float32)])
    return out, b.delay_ms()


def erle(mic, out, far_al, t0: float, t1: float) -> float:
    m = active_mask(far_al)[int(t0 * SR):int(t1 * SR)]
    s, e = int(t0 * SR), int(t1 * SR)
    return db(energy(np.asarray(mic)[s:e][m]) / max(energy(np.asarray(out)[s:e][m]), 1e-20))


# ----------------------------------------------------------------- scenarios
def scenario_far_only(cfg: BackendConfig, seconds: float = 40, **echo_kw) -> Dict[str, float]:
    far_al = aligned_far(seconds)
    mic = echo_signal(seconds, **echo_kw) + noise_signal(seconds)
    out, delay = run_backend(cfg, mic, far_al)
    res = {
        "0-3s": erle(mic, out, far_al, 0, 3), "3-6s": erle(mic, out, far_al, 3, 6),
        "6-12s": erle(mic, out, far_al, 6, 12), "12-25s": erle(mic, out, far_al, 12, 25),
        "25-40s": erle(mic, out, far_al, 25, min(40, seconds)),
    }
    # residual level vs the noise floor in the last window (0 dB = at the noise floor)
    s, e = 12 * SR, int(seconds * SR)
    m = active_mask(far_al)[s:e]
    res["excess_over_noise_db"] = db(energy(out[s:e][m]) / energy(noise_signal(seconds)[s:e][m]))
    res["delay_ms"] = -1.0 if delay is None else delay
    return res


def scenario_near_only(cfg: BackendConfig, seconds: float = 20) -> Dict[str, float]:
    near = near_signal(seconds) + noise_signal(seconds)
    far0 = np.zeros_like(near)
    out, _ = run_backend(cfg, near, far0)
    ref_cfg = BackendConfig(**{**cfg.__dict__, "residual_echo_suppression": False})
    out_notch, _ = run_backend(ref_cfg, near, far0)      # only the DC notch + quantisation
    s = 2 * SR
    a, b, c = near[s:].astype(np.float64), out[s:].astype(np.float64), out_notch[s:].astype(np.float64)
    return {
        "energy_vs_input_db": db(energy(b) / energy(a)),
        "snr_vs_dc_notched_input_db": db(energy(c) / energy(b - c)) if cfg.residual_echo_suppression else db(energy(c) / max(energy(b - c), 1e-20)),
        "raw_snr_vs_input_db": db(energy(a) / energy(b - a)),
        "corr_vs_notched": float(np.dot(b, c) / math.sqrt(energy(b) * energy(c))),
    }


def scenario_double_talk(cfg: BackendConfig, seconds: float = 40) -> Dict[str, float]:
    far_al = aligned_far(seconds)
    near = near_signal(seconds)
    echo = echo_signal(seconds)
    noise = noise_signal(seconds)
    mic = near + echo + noise
    out, _ = run_backend(cfg, mic, far_al)
    # what a perfect canceller would output: the same backend on the near-only mic, far silent
    ideal, _ = run_backend(cfg, near + noise, np.zeros_like(near))
    s, e = 12 * SR, int(seconds * SR)
    dt = (active_mask(near, 1e-4) & active_mask(echo, 1e-4))[s:e]
    o, i, ec = out[s:e][dt].astype(np.float64), ideal[s:e][dt].astype(np.float64), echo[s:e][dt].astype(np.float64)
    nn = near[s:e][dt].astype(np.float64)
    g = float(np.dot(o, i) / np.dot(i, i))
    return {
        "dt_fraction": float(dt.mean()),
        "retention_energy_db": db(energy(o) / energy(i)),
        "retention_gain_db": 20 * math.log10(abs(g)),
        "correlation": float(np.dot(o, i) / math.sqrt(energy(o) * energy(i))),
        "leak_vs_echo_db": db(energy(o - i) / energy(ec)),       # (output - ideal) relative to the echo energy
        "leak_vs_near_db": db(energy(o - i) / energy(nn)),
    }


def fmt(v: float, p: int = 1) -> str:
    return f"{v:.{p}f}"


def table(headers: List[str], rows: List[List[str]]) -> str:
    out = ["| " + " | ".join(headers) + " |", "|" + "|".join(["---"] * len(headers)) + "|"]
    for r in rows:
        out.append("| " + " | ".join(r) + " |")
    return "\n".join(out)


# ------------------------------------------------------------------ sections
def section_erle(cfg: BackendConfig) -> None:
    print("\n### Scenario 1 - far-only ERLE (dB) by time window\n")
    r = scenario_far_only(cfg)
    print(table(["0-3 s", "3-6 s", "6-12 s", "12-25 s", "25-40 s", "residual vs noise floor", "delay est."],
                [[fmt(r["0-3s"]), fmt(r["3-6s"]), fmt(r["6-12s"]), fmt(r["12-25s"]), fmt(r["25-40s"]),
                  fmt(r["excess_over_noise_db"]) + " dB", fmt(r["delay_ms"]) + " ms"]]))


def section_transparency(cfg: BackendConfig) -> None:
    print("\n### Scenario 2 - near-only transparency\n")
    rows = []
    for name, c in (("residual suppression ON (default)", cfg),
                    ("residual suppression OFF (DC notch only)", BackendConfig(**{**cfg.__dict__, "residual_echo_suppression": False}))):
        r = scenario_near_only(c)
        on = c.residual_echo_suppression
        rows.append([name, fmt(r["energy_vs_input_db"], 2),
                     fmt(r["snr_vs_dc_notched_input_db"]) if on else "(is the reference)",
                     fmt(r["raw_snr_vs_input_db"]), fmt(r["corr_vs_notched"], 5) if on else "(is the reference)"])
    print(table(["config", "energy vs input (dB)", "SNR vs DC-notched input (dB)", "raw SNR vs input (dB)", "corr vs DC-notched"], rows))
    print("\n`SNR vs DC-notched input` compares with the input after the ~60 Hz high-pass that Speex's echo canceller "
          "always applies (replica in synth.dc_notch); `raw SNR` compares with the untouched input and is dominated by "
          "that filter's phase shift on low-pitched voices.")


def section_doubletalk(cfg: BackendConfig) -> None:
    print("\n### Scenario 3 - double-talk (near-end speech + echo)\n")
    rows = []
    for name, c in (("residual suppression ON (default)", cfg),
                    ("residual suppression OFF", BackendConfig(**{**cfg.__dict__, "residual_echo_suppression": False}))):
        r = scenario_double_talk(c)
        rows.append([name, fmt(r["dt_fraction"] * 100, 0) + "%", fmt(r["retention_energy_db"], 2),
                     fmt(r["retention_gain_db"], 2), fmt(r["correlation"], 3), fmt(r["leak_vs_echo_db"]), fmt(r["leak_vs_near_db"])])
    print(table(["config", "DT frames", "near retention energy (dB)", "retention gain (dB)", "corr vs ideal",
                 "(out-ideal) vs echo (dB)", "(out-ideal) vs near (dB)"], rows))


def section_delay(cfg: BackendConfig) -> None:
    print("\n### Scenario 4 - echo delay sweep (stage lead 30 ms)\n")
    rows = []
    for d in (0, 20, 60, 120, 200):
        r = scenario_far_only(cfg, 30, delay_ms=float(d))
        rows.append([f"{d} ms", fmt(r["6-12s"]), fmt(r["12-25s"]), fmt(r["delay_ms"]) + " ms", f"{d + LEAD_MS:.0f} ms"])
    print(table(["true echo delay", "ERLE 6-12 s", "ERLE 12-25 s", "estimated (lag)", "expected (delay+lead)"], rows))


def section_lead(cfg: BackendConfig) -> None:
    print("\n### Reference lead: ERLE vs the lag between reference and echo (true echo delay 40 ms)\n")
    rows = []
    mic = echo_signal(30) + noise_signal(30)
    for lead_ms in (-80, -60, -40, 0, 30, 60, 100):
        lead = int(round(lead_ms * SR / 1000.0))
        far_al = aligned_far(30, lead)
        out, delay = run_backend(cfg, mic, far_al)
        lag = RIR_DELAY_MS + lead_ms
        rows.append([f"{lead_ms:+d} ms", f"{lag:+.0f} ms", fmt(erle(mic, out, far_al, 12, 25)),
                     "-" if delay is None else fmt(delay) + " ms"])
    print(table(["lead applied to reference", "lag of echo behind reference", "ERLE 12-25 s", "estimated lag"], rows))


def section_nonlinear(cfg: BackendConfig) -> None:
    print("\n### Scenario 5 - nonlinear echo path (tanh speaker, drive 3)\n")
    rows = []
    for label, kw in (("linear", {}), ("tanh soft-clip", {"nonlinear": True})):
        r = scenario_far_only(cfg, 30, **kw)
        rows.append([label, fmt(r["6-12s"]), fmt(r["12-25s"]), fmt(r["excess_over_noise_db"]) + " dB"])
    print(table(["echo path", "ERLE 6-12 s", "ERLE 12-25 s", "residual vs noise floor"], rows))


def section_sweep(cfg: BackendConfig) -> None:
    print("\n### Parameter sweep (far-only ERLE, double-talk retention)\n")
    rows = []
    variants = [("filter 100 ms", dict(filter_length_ms=100)), ("filter 150 ms", dict(filter_length_ms=150)),
                ("filter 200 ms", dict(filter_length_ms=200)), ("filter 300 ms", dict(filter_length_ms=300)),
                ("filter 400 ms", dict(filter_length_ms=400)),
                ("residual OFF", dict(residual_echo_suppression=False)),
                ("residual ON, denoise OFF (no-op!)", dict(denoise=False)),
                ("suppress -30/-10", dict(echo_suppress_db=-30, echo_suppress_active_db=-10)),
                ("suppress -40/-15 (default)", dict()),
                ("suppress -50/-25", dict(echo_suppress_db=-50, echo_suppress_active_db=-25)),
                ("suppress -60/-35", dict(echo_suppress_db=-60, echo_suppress_active_db=-35)),
                ("noise suppression -15 dB", dict(noise_suppress_db=-15))]
    for name, kw in variants:
        c = BackendConfig(**{**cfg.__dict__, **kw})
        a = scenario_far_only(c, 40)
        d = scenario_double_talk(c, 40)
        n = scenario_near_only(c, 20)
        rows.append([name, fmt(a["3-6s"]), fmt(a["6-12s"]), fmt(a["12-25s"]), fmt(a["25-40s"]),
                     fmt(n["energy_vs_input_db"], 2), fmt(d["retention_gain_db"], 2), fmt(d["leak_vs_echo_db"])])
    print(table(["variant", "ERLE 3-6 s", "6-12 s", "12-25 s", "25-40 s", "near-only energy (dB)",
                 "DT gain (dB)", "DT (out-ideal) vs echo (dB)"], rows))


SECTIONS = {
    "erle": section_erle, "transparency": section_transparency, "doubletalk": section_doubletalk,
    "delay": section_delay, "lead": section_lead, "nonlinear": section_nonlinear, "sweep": section_sweep,
}


def main() -> None:
    global NOISE_DBFS
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("--lib", default=os.path.join("build", "libaecharness.so"))
    ap.add_argument("--sections", default="erle,transparency,doubletalk,delay,nonlinear")
    ap.add_argument("--filter-ms", type=int, default=BackendConfig().filter_length_ms)
    ap.add_argument("--noise-dbfs", type=float, default=NOISE_DBFS, help="mic noise floor (spec: -50)")
    args = ap.parse_args()
    NOISE_DBFS = args.noise_dbfs
    os.environ["AEC_HARNESS_LIB"] = args.lib
    names = list(SECTIONS) + ["stage"] if args.sections == "all" else args.sections.split(",")
    cfg = BackendConfig(filter_length_ms=args.filter_ms)
    print(f"<!-- tune.py: {cfg} -->")
    for name in names:
        if name == "stage":
            import stage_scenarios
            stage_scenarios.run_all(cfg)
        else:
            t = time.time()
            SECTIONS[name](cfg)
            print(f"\n<!-- {name}: {time.time() - t:.1f}s -->")


if __name__ == "__main__":
    sys.modules.setdefault("tune", sys.modules[__name__])   # stage_scenarios does `import tune`: share this module
    main()
