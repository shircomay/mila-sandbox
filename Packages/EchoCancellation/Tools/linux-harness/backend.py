"""ctypes binding for libaecharness.so (see aec_harness.c): the same Speex echo
canceller + preprocessor pipeline as Sources/EchoCancellation/SpeexEchoCanceller.swift.

Environment: AEC_HARNESS_LIB = path to libaecharness.so (default: ./build/libaecharness.so
next to the current directory, as produced by build.sh build).
"""
from __future__ import annotations

import ctypes
import os
from dataclasses import dataclass

import numpy as np


@dataclass
class BackendConfig:
    """Mirrors SpeexEchoCanceller.Configuration (plus the denoise/noise knobs
    discussed in TUNING.md)."""
    sample_rate: int = 16000
    frame_size: int = 160
    filter_length_ms: int = 300
    residual_echo_suppression: bool = True
    echo_suppress_db: int = -40
    echo_suppress_active_db: int = -15
    # Speex only applies its residual-echo gain when SET_DENOISE is on, so
    # "noise suppression off" means denoise on with a 0 dB noise floor.
    denoise: bool = True
    noise_suppress_db: int = 0


_lib = None


def _load():
    global _lib
    if _lib is not None:
        return _lib
    path = os.environ.get("AEC_HARNESS_LIB", os.path.join("build", "libaecharness.so"))
    lib = ctypes.CDLL(path)
    lib.aec_create.restype = ctypes.c_void_p
    lib.aec_create.argtypes = [ctypes.c_int] * 8
    lib.aec_destroy.argtypes = [ctypes.c_void_p]
    lib.aec_reset.argtypes = [ctypes.c_void_p]
    lib.aec_latency_samples.restype = ctypes.c_int
    lib.aec_latency_samples.argtypes = [ctypes.c_void_p]
    lib.aec_process.argtypes = [ctypes.c_void_p] + [ctypes.c_void_p] * 3
    lib.aec_delay_ms.restype = ctypes.c_double
    lib.aec_delay_ms.argtypes = [ctypes.c_void_p, ctypes.c_int]
    _lib = lib
    return lib


class Backend:
    def __init__(self, cfg: BackendConfig | None = None) -> None:
        self.cfg = cfg or BackendConfig()
        c = self.cfg
        self.lib = _load()
        self.h = self.lib.aec_create(
            c.sample_rate, c.frame_size, c.filter_length_ms,
            int(c.residual_echo_suppression), c.echo_suppress_db, c.echo_suppress_active_db,
            int(c.denoise), c.noise_suppress_db)
        if not self.h:
            raise RuntimeError("aec_create failed")
        self.frame_size = c.frame_size
        self.latency_samples = self.lib.aec_latency_samples(self.h)

    def __del__(self) -> None:
        h = getattr(self, "h", None)
        if h:
            self.lib.aec_destroy(h)
            self.h = None

    def reset(self) -> None:
        self.lib.aec_reset(self.h)

    def process(self, near: np.ndarray, far: np.ndarray, out: np.ndarray) -> None:
        """near/far/out: float32 contiguous arrays of exactly frame_size."""
        self.lib.aec_process(self.h, near.ctypes.data, far.ctypes.data, out.ctypes.data)

    def delay_ms(self) -> float | None:
        d = self.lib.aec_delay_ms(self.h, 200)
        return None if d < 0 else d

    def run(self, near: np.ndarray, far_aligned: np.ndarray) -> np.ndarray:
        """Offline helper: run whole signals (already time-aligned, same length)
        and return the raw backend output (delayed by latency_samples if the
        residual suppressor is on). Trailing partial frames are dropped."""
        n = self.frame_size
        frames = min(len(near), len(far_aligned)) // n
        near = np.ascontiguousarray(near[:frames * n], dtype=np.float32)
        far = np.ascontiguousarray(far_aligned[:frames * n], dtype=np.float32)
        out = np.zeros(frames * n, dtype=np.float32)
        for i in range(frames):
            s = i * n
            self.process(near[s:s + n], far[s:s + n], out[s:s + n])
        return out
