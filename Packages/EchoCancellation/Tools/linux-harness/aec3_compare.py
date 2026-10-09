#!/usr/bin/env python3
"""Optional: run the same scenarios through WebRTC AEC3 (pip package
pywebrtc-audio, a pybind11 wrapper of the WebRTC audio processing module) next
to the Speex backend, to tell whether swapping the backend later could pay off.

    python3 -m venv /tmp/aec3-venv && /tmp/aec3-venv/bin/pip install numpy pywebrtc-audio
    cd Packages/EchoCancellation/Tools/linux-harness && sh build.sh build
    /tmp/aec3-venv/bin/python aec3_compare.py --lib build/libaecharness.so

Not needed to build or test the package. Do not commit the venv.
AEC3 gets exactly what the Speex backend gets (frames of 10 ms, the far stream
already time-aligned and advanced by the stage's 30 ms lead); it estimates its
own delay internally.
"""
from __future__ import annotations

import argparse
import math
import os

import numpy as np

import synth
import tune
from backend import BackendConfig

SR = tune.SR


def run_aec3(mic: np.ndarray, far_al: np.ndarray, stream_delay_ms: int = 0) -> np.ndarray:
    import pywebrtc_audio as webrtc

    ec = webrtc.EchoCanceller(sample_rate=SR, num_channels=1, stream_delay_ms=stream_delay_ms)
    n = 160
    frames = min(len(mic), len(far_al)) // n
    out = np.zeros(frames * n, dtype=np.float32)
    mic = np.ascontiguousarray(mic, dtype=np.float32)
    far_al = np.ascontiguousarray(far_al, dtype=np.float32)
    for i in range(frames):
        s = slice(i * n, (i + 1) * n)
        out[s] = ec.process(mic[s], far_al[s])
    return out


def main() -> None:
    ap = argparse.ArgumentParser()
    ap.add_argument("--lib", default=os.path.join("build", "libaecharness.so"))
    args = ap.parse_args()
    os.environ["AEC_HARNESS_LIB"] = args.lib
    cfg = BackendConfig()
    seconds = 40
    far_al = tune.aligned_far(seconds)
    near = tune.near_signal(seconds)
    noise = tune.noise_signal(seconds)
    rows = []

    def compare(name, mic, echo=None, nonlinear=False):
        speex, _ = tune.run_backend(cfg, mic, far_al)
        aec3 = run_aec3(mic, far_al)
        r = []
        for (a, b) in ((3, 6), (6, 12), (12, 25), (25, 40)):
            r.append(f"{tune.erle(mic, speex, far_al, a, b):.1f} / {tune.erle(mic, aec3, far_al, a, b):.1f}")
        rows.append([name] + r)

    echo = tune.echo_signal(seconds)
    compare("far-only (linear room)", echo + noise)
    compare("far-only, tanh speaker", tune.echo_signal(seconds, nonlinear=True) + noise)
    compare("far-only, echo delay 120 ms", tune.echo_signal(seconds, delay_ms=120.0) + noise)
    print("\n### Speex vs WebRTC AEC3: ERLE (dB), Speex / AEC3\n")
    print(tune.table(["scenario", "3-6 s", "6-12 s", "12-25 s", "25-40 s"], rows))

    # double talk and near-only transparency
    mic = near + echo + noise
    speex, _ = tune.run_backend(cfg, mic, far_al)
    aec3 = run_aec3(mic, far_al)
    ideal_in = near + noise
    s, e = 12 * SR, seconds * SR
    dt = (tune.active_mask(near) & tune.active_mask(echo))[s:e]
    rows = []
    for name, out in (("Speex", speex), ("AEC3", aec3)):
        # compare with the near-only microphone passed through the SAME canceller
        if name == "Speex":
            ideal, _ = tune.run_backend(cfg, ideal_in, np.zeros_like(near))
        else:
            ideal = run_aec3(ideal_in, np.zeros_like(near))
        o = out[s:e][dt].astype(np.float64)
        i = ideal[s:e][dt].astype(np.float64)
        ec = echo[s:e][dt].astype(np.float64)
        g = float(np.dot(o, i) / np.dot(i, i))
        rows.append([name, f"{20 * math.log10(abs(g)):.2f}", f"{float(np.dot(o, i) / math.sqrt(np.dot(o, o) * np.dot(i, i))):.3f}",
                     f"{tune.db(tune.energy(o - i) / tune.energy(ec)):.1f}"])
    print("\n### Double talk (12-40 s): near-end retention vs the same canceller on the near-only microphone\n")
    print(tune.table(["canceller", "retention gain (dB)", "correlation", "(out-ideal) vs echo (dB)"], rows))

    rows = []
    for name, fn in (("Speex", lambda m: tune.run_backend(cfg, m, np.zeros_like(near))[0]),
                     ("AEC3", lambda m: run_aec3(m, np.zeros_like(near)))):
        out = fn(ideal_in)
        a = ideal_in[2 * SR:len(out) - 1000].astype(np.float64)
        best = (0.0, 0)
        for lag in range(-400, 401):          # AEC3 delays its output by a few ms
            b = out[2 * SR + lag:len(out) - 1000 + lag].astype(np.float64)
            c = float(np.dot(a, b) / math.sqrt(np.dot(a, a) * np.dot(b, b)))
            if abs(c) > abs(best[0]):
                best = (c, lag)
        b0 = out[2 * SR:len(out) - 1000].astype(np.float64)
        rows.append([name, f"{tune.db(tune.energy(b0) / tune.energy(a)):.2f}", f"{best[1] / 16:.1f} ms", f"{best[0]:.3f}"])
    print("\n### Near-end only (far silent)\n")
    print(tune.table(["canceller", "energy vs input (dB)", "output lag", "correlation at that lag"], rows))


if __name__ == "__main__":
    main()
