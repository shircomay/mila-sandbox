"""Deterministic synthetic signals for the echo-cancellation tuning harness.

The Swift test helper Tests/EchoCancellationTests/SyntheticEcho.swift is a
line-by-line port of this file: same PRNG (SplitMix64), same Irwin-Hall
Gaussian, same syllable/formant model, same room impulse response. Keep the
two in sync -- the thresholds in the Swift tests were chosen from numbers this
harness measured on these exact signals.

Everything is generated in float64 and rounded to float32 at the end.
Pure Python loops (no scipy needed); results are cached by the callers.
"""
from __future__ import annotations

import math
from typing import List, Tuple

import numpy as np

MASK64 = 0xFFFFFFFFFFFFFFFF


class SplitMix64:
    def __init__(self, seed: int) -> None:
        self.state = seed & MASK64

    def next_u64(self) -> int:
        self.state = (self.state + 0x9E3779B97F4A7C15) & MASK64
        z = self.state
        z = ((z ^ (z >> 30)) * 0xBF58476D1CE4E5B9) & MASK64
        z = ((z ^ (z >> 27)) * 0x94D049BB133111EB) & MASK64
        return z ^ (z >> 31)

    def uniform(self) -> float:
        """Uniform in [0, 1) with 53 random bits."""
        return float(self.next_u64() >> 11) * (1.0 / 9007199254740992.0)

    def uniform_in(self, lo: float, hi: float) -> float:
        return lo + (hi - lo) * self.uniform()

    def gaussian(self) -> float:
        """Approximately Gaussian, mean 0, variance 1: Irwin-Hall sum of four
        uniforms, (sum - 2) * sqrt(3). Cheap and identical in every language."""
        s = self.uniform() + self.uniform() + self.uniform() + self.uniform()
        return (s - 2.0) * 1.7320508075688772


# (F1, F2, F3) in Hz for five vowels.
VOWELS = [
    (730.0, 1090.0, 2440.0),  # a
    (530.0, 1840.0, 2480.0),  # e
    (270.0, 2290.0, 3010.0),  # i
    (570.0, 840.0, 2410.0),   # o
    (300.0, 870.0, 2240.0),   # u
]
BANDWIDTHS = (90.0, 110.0, 160.0)
FRICATIVE_FORMANTS = (2600.0, 4200.0, 6000.0)
FRICATIVE_BANDWIDTHS = (500.0, 800.0, 1000.0)


def _resonator(freq: float, bw: float, sr: float) -> Tuple[float, float, float]:
    """Two-pole resonator y = g*x + a1*y1 + a2*y2 with unity gain at DC-ish
    scale (gain chosen so the peak gain is about 1)."""
    r = math.exp(-math.pi * bw / sr)
    a1 = 2.0 * r * math.cos(2.0 * math.pi * freq / sr)
    a2 = -r * r
    g = 1.0 - r
    return g, a1, a2


def speech_like(seed: int, seconds: float, sr: int = 16000,
                target_rms_dbfs: float = -20.0) -> Tuple[np.ndarray, np.ndarray]:
    """Speech-like signal: syllable-rate amplitude envelope, vowel formants,
    pitch 90-220 Hz, occasional fricatives and 0.3-1.2 s pauses.

    Returns (signal float32, activity float32) where activity is the 0..1
    syllable envelope (> 0.05 means "speech present").
    """
    rng = SplitMix64(seed)
    n_total = int(round(seconds * sr))
    sig = [0.0] * n_total
    env_out = [0.0] * n_total

    # resonator state (3 formants) persists across syllables
    y1 = [0.0, 0.0, 0.0]
    y2 = [0.0, 0.0, 0.0]
    tilt = 0.0
    pos = 0
    phase = 0.0          # pitch phase in [0, 1)
    lp_noise = 0.0
    while pos < n_total:
        # pause?
        if rng.uniform() < 0.18:
            pos += int(rng.uniform_in(0.3, 1.2) * sr)
            continue
        dur = int(rng.uniform_in(0.12, 0.28) * sr)
        amp = rng.uniform_in(0.35, 1.0)
        voiced = rng.uniform() < 0.85
        vowel = int(rng.uniform() * 5.0) % 5
        f0 = rng.uniform_in(90.0, 220.0)
        vib_rate = rng.uniform_in(4.0, 6.0)
        if voiced:
            freqs = VOWELS[vowel]
            bws = BANDWIDTHS
        else:
            freqs = FRICATIVE_FORMANTS
            bws = FRICATIVE_BANDWIDTHS
        coefs = [_resonator(freqs[k], bws[k], sr) for k in range(3)]
        weights = (1.0, 0.7, 0.4) if voiced else (0.6, 1.0, 0.8)
        for i in range(dur):
            n = pos + i
            if n >= n_total:
                break
            t = i / dur
            s_env = math.sin(math.pi * t)
            env = amp * s_env * s_env
            if voiced:
                f = f0 * (1.0 + 0.03 * math.sin(2.0 * math.pi * vib_rate * i / sr))
                phase += f / sr
                pulse = 0.0
                if phase >= 1.0:
                    phase -= 1.0
                    pulse = 1.0
                lp_noise = 0.9 * lp_noise + 0.1 * (rng.uniform() - 0.5) * 3.4641016151377544
                exc = 12.0 * pulse + 0.15 * lp_noise
            else:
                exc = 0.6 * (rng.uniform() - 0.5) * 3.4641016151377544
            acc = 0.0
            for k in range(3):
                g, a1, a2 = coefs[k]
                y = g * exc + a1 * y1[k] + a2 * y2[k]
                y2[k] = y1[k]
                y1[k] = y
                acc += weights[k] * y
            tilt = acc + 0.6 * tilt
            sig[n] = tilt * env
            env_out[n] = env
        pos += dur

    x = np.array(sig, dtype=np.float64)
    env_arr = np.array(env_out, dtype=np.float64)
    active = env_arr > 0.05
    if active.any():
        rms = math.sqrt(float(np.mean(x[active] ** 2)))
        if rms > 0.0:
            x *= (10.0 ** (target_rms_dbfs / 20.0)) / rms
    return x.astype(np.float32), env_arr.astype(np.float32)


def white_noise(seed: int, n: int, rms_dbfs: float) -> np.ndarray:
    rng = SplitMix64(seed)
    scale = 10.0 ** (rms_dbfs / 20.0)
    out = np.empty(n, dtype=np.float64)
    for i in range(n):
        out[i] = rng.gaussian() * scale
    return out.astype(np.float32)


def room_ir(seed: int, sr: int = 16000, delay_ms: float = 40.0, rt60_ms: float = 250.0,
            gain: float = 0.5, tail_to_direct_energy: float = 0.6,
            length_ms: float = 400.0) -> np.ndarray:
    """Synthetic room impulse response: a direct path at `delay_ms` with
    amplitude `gain`, followed by an exponentially decaying Gaussian tail
    (amplitude falls 60 dB over `rt60_ms`) whose energy is
    `tail_to_direct_energy` x the direct-path energy."""
    rng = SplitMix64(seed)
    length = int(round(length_ms * sr / 1000.0))
    d = int(round(delay_ms * sr / 1000.0))
    h = np.zeros(max(length, d + 1), dtype=np.float64)
    h[d] = gain
    tail = np.zeros_like(h)
    k = 6.907755278982137 / (rt60_ms * sr / 1000.0)   # ln(1000) / RT60 in samples
    for i in range(d + 1, len(h)):
        tail[i] = rng.gaussian() * math.exp(-k * (i - d))
    e = float(np.sum(tail ** 2))
    if e > 0.0:
        tail *= math.sqrt(tail_to_direct_energy * gain * gain / e)
    h += tail
    return h.astype(np.float32)


def convolve(x: np.ndarray, h: np.ndarray) -> np.ndarray:
    """Linear convolution truncated to len(x) (FFT based)."""
    n = len(x) + len(h) - 1
    size = 1 << (n - 1).bit_length()
    y = np.fft.irfft(np.fft.rfft(x.astype(np.float64), size) * np.fft.rfft(h.astype(np.float64), size), size)
    return y[:len(x)].astype(np.float32)


def speaker_nonlinearity(x: np.ndarray, drive: float = 3.0) -> np.ndarray:
    """Soft clip with unity small-signal gain: tanh(drive*x)/drive."""
    return (np.tanh(drive * x.astype(np.float64)) / drive).astype(np.float32)


def dbfs(x: np.ndarray) -> float:
    e = float(np.mean(x.astype(np.float64) ** 2))
    return 10.0 * math.log10(max(e, 1e-20))


def multitone(seed: int, seconds: float, sr: int = 16000, tones: int = 24, lo_hz: float = 600.0,
              hi_hz: float = 3400.0, rms_dbfs: float = -25.0) -> np.ndarray:
    """Stationary band-limited test signal (no energy below `lo_hz`): a sum of
    sinusoids with random frequency, amplitude and phase. Unlike speech it has no
    content in the ~60 Hz high-pass of Speex's echo canceller, so "the canceller
    leaves it alone" can be checked against the raw input."""
    rng = SplitMix64(seed)
    n = int(round(seconds * sr))
    params = []
    for _ in range(tones):
        f = rng.uniform_in(lo_hz, hi_hz)
        a = rng.uniform_in(0.2, 1.0)
        p = rng.uniform_in(0.0, 2.0 * math.pi)
        params.append((f, a, p))
    idx = np.arange(n, dtype=np.float64)
    x = np.zeros(n, dtype=np.float64)
    for f, a, p in params:
        x += a * np.sin(2.0 * math.pi * f * idx / sr + p)
    rms = math.sqrt(float(np.mean(x ** 2)))
    x *= (10.0 ** (rms_dbfs / 20.0)) / rms
    return x.astype(np.float32)


def dc_notch(x: np.ndarray, radius: float = 0.982) -> np.ndarray:
    """Replica of the DC-notch high-pass at the input of Speex's echo canceller
    (filter_dc_notch16 in mdf.c, float build, radius 0.982 at 16 kHz). The
    canceller applies it to the microphone signal even when there is no echo,
    so "transparent" means "equal to dc_notch(input)", not "equal to input"."""
    den2 = radius * radius + 0.7 * (1.0 - radius) * (1.0 - radius)
    m0 = 0.0
    m1 = 0.0
    out = np.zeros(len(x), dtype=np.float64)
    for i in range(len(x)):
        v = float(x[i])
        vout = m0 + v
        m0 = m1 + 2.0 * (-v + radius * vout)
        m1 = v - den2 * vout
        out[i] = radius * vout
    return out.astype(np.float32)
