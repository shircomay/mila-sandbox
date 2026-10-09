"""Executable model of Sources/EchoCancellation/EchoCancellationStage.swift.

The Swift stage cannot be compiled in the agent container, so the timeline /
hold / flush logic was written and exercised here first, on top of the real
Speex backend (libaecharness.so), and then ported line by line. Keep the two in
sync; TUNING.md's stage-level numbers come from this model.

Positions are integer sample indices on one timeline: position p <-> host time
t0 + p / sample_rate, t0 = host time of the first timestamped sample on either
stream.
"""
from __future__ import annotations

import math
from dataclasses import dataclass, field
from typing import Callable, List, Optional

import numpy as np

from backend import Backend, BackendConfig


def rnd(x: float) -> int:
    """Round half away from zero (Swift's .rounded())."""
    return int(math.floor(abs(x) + 0.5)) * (1 if x >= 0 else -1)


@dataclass
class StageConfig:
    sample_rate: float = 16000.0
    hold_ms: float = 150.0
    reference_lead_ms: float = 30.0
    reanchor_tolerance_ms: float = 20.0
    reference_retention_seconds: float = 10.0
    backend: BackendConfig = field(default_factory=BackendConfig)


@dataclass
class Statistics:
    frames_processed: int = 0
    frames_with_reference: int = 0
    frames_held_too_long: int = 0
    mic_reanchors: int = 0
    reference_reanchors: int = 0
    reference_samples_discarded: int = 0
    echo_reduction_db: Optional[float] = None
    estimated_echo_delay_ms: Optional[float] = None
    initial_mic_to_reference_offset_ms: Optional[float] = None


class _Stream:
    def __init__(self) -> None:
        self.next = 0
        self.has_timestamp = False
        self.first_timestamp: Optional[float] = None


ERLE_WINDOW_FRAMES = 500       # ~5 s of far-active frames
ERLE_MIN_FRAMES = 100          # ~1 s before a value is reported
STATS_REFRESH_FRAMES = 50      # recompute ERLE / delay every 0.5 s
FAR_ACTIVE_MEAN_SQUARE = 1e-6  # about -60 dBFS RMS
DOUBLE_TALK_RATIO = 4.0
MAX_TIMESTAMP_SPAN_SAMPLES = 4.0e15


class Stage:
    def __init__(self, cfg: Optional[StageConfig] = None, backend: Optional[Backend] = None) -> None:
        self.cfg = cfg or StageConfig()
        self.backend = backend or Backend(self.cfg.backend)
        sr = self.cfg.sample_rate
        self.n = self.backend.frame_size
        self.latency = self.backend.latency_samples
        self.lead = max(0, rnd(self.cfg.reference_lead_ms * sr / 1000.0))
        self.tolerance = max(1, rnd(self.cfg.reanchor_tolerance_ms * sr / 1000.0))
        self.hold = max(self.n, rnd(self.cfg.hold_ms * sr / 1000.0))
        self.capacity = max(rnd(self.cfg.reference_retention_seconds * sr), 4 * (self.lead + self.n))
        self.ring = np.zeros(self.capacity, dtype=np.float32)
        self.ref_high: Optional[int] = None
        self.ref_consumed_end: Optional[int] = None
        self.t0: Optional[float] = None
        self.mic = _Stream()
        self.ref = _Stream()
        # held microphone samples + run-length encoded positions
        self.fifo = np.zeros(0, dtype=np.float32)
        self.fifo_head = 0
        self.segments: List[List[int]] = []      # [start, count]
        self.total_in = 0
        self.returned = 0
        self.pending: List[np.ndarray] = []      # output produced but not yet returned
        self.pending_count = 0
        self.skip_remaining = self.latency
        self.next_frame_pos = 0                  # position of the next frame (for drain frames)
        self.carry = np.zeros(0, dtype=np.float32)   # output produced by reset_timeline's implicit flush
        self.statistics = Statistics()
        self.frame_observer: Optional[Callable[[np.ndarray, np.ndarray, np.ndarray], None]] = None
        self._near = np.zeros(self.n, dtype=np.float32)
        self._far = np.zeros(self.n, dtype=np.float32)
        self._out = np.zeros(self.n, dtype=np.float32)
        self.erle_window: List[tuple] = []       # (near_energy, far_energy, out_energy)
        self.far_smooth = 0.0
        self.frames_since_refresh = 0

    # ------------------------------------------------------------- timeline
    def _place(self, stream: _Stream, is_mic: bool, ts: Optional[float]) -> None:
        if ts is None or not math.isfinite(ts):
            return
        sr = self.cfg.sample_rate
        if self.t0 is None:
            self.t0 = ts - stream.next / sr
        span = (ts - self.t0) * sr
        if not math.isfinite(span) or abs(span) > MAX_TIMESTAMP_SPAN_SAMPLES:
            return  # absurd timestamp: ignore it, keep counting samples
        measured = rnd(span)
        if not stream.has_timestamp:
            stream.has_timestamp = True
            stream.first_timestamp = ts
            stream.next = measured
            if self.mic.first_timestamp is not None and self.ref.first_timestamp is not None:
                self.statistics.initial_mic_to_reference_offset_ms = \
                    (self.mic.first_timestamp - self.ref.first_timestamp) * 1000.0
        elif abs(measured - stream.next) > self.tolerance:
            stream.next = measured
            if is_mic:
                self.statistics.mic_reanchors += 1
                self.ref_consumed_end = None
            else:
                self.statistics.reference_reanchors += 1

    # ------------------------------------------------------------ reference
    def append_reference(self, samples: np.ndarray, host_time: Optional[float]) -> None:
        self._place(self.ref, False, host_time)
        count = len(samples)
        if count == 0:
            return
        start = self.ref.next
        self.ref.next += count
        self._write_reference(np.asarray(samples, dtype=np.float32), start)

    def _write_reference(self, samples: np.ndarray, start: int) -> None:
        cap = self.capacity
        count = len(samples)
        end = start + count
        if self.ref_high is None:
            self.ref_high = start
        new_high = max(self.ref_high, end)
        window_start = new_high - cap
        if end <= window_start:
            self.statistics.reference_samples_discarded += count
            return
        s = start
        offset = 0
        if s < window_start:
            d = window_start - s
            self.statistics.reference_samples_discarded += d
            s += d
            offset += d
        if s > self.ref_high:
            gap = s - self.ref_high
            if gap >= cap:
                self.ring[:] = 0.0
            else:
                self._ring_fill_zero(self.ref_high, s)
        if self.ref_consumed_end is not None and s < self.ref_consumed_end:
            self.statistics.reference_samples_discarded += min(end, self.ref_consumed_end) - s
        self._ring_copy_in(s, samples[offset:])
        self.ref_high = new_high

    def _ring_fill_zero(self, lo: int, hi: int) -> None:
        cap = self.capacity
        i = lo % cap
        remaining = hi - lo
        while remaining > 0:
            run = min(remaining, cap - i)
            self.ring[i:i + run] = 0.0
            remaining -= run
            i = 0

    def _ring_copy_in(self, pos: int, data: np.ndarray) -> None:
        cap = self.capacity
        i = pos % cap
        k = 0
        remaining = len(data)
        while remaining > 0:
            run = min(remaining, cap - i)
            self.ring[i:i + run] = data[k:k + run]
            k += run
            remaining -= run
            i = 0

    def _read_reference(self, pos: int, out: np.ndarray) -> None:
        out[:] = 0.0
        if self.ref_high is None:
            return
        cap = self.capacity
        lo = max(pos, self.ref_high - cap)
        hi = min(pos + len(out), self.ref_high)
        if lo >= hi:
            return
        i = lo % cap
        k = lo - pos
        remaining = hi - lo
        while remaining > 0:
            run = min(remaining, cap - i)
            out[k:k + run] = self.ring[i:i + run]
            k += run
            remaining -= run
            i = 0

    # ----------------------------------------------------------- microphone
    def _queued(self) -> int:
        return len(self.fifo) - self.fifo_head

    def process_microphone(self, samples: np.ndarray, host_time: Optional[float]) -> np.ndarray:
        self._place(self.mic, True, host_time)
        count = len(samples)
        if count > 0:
            start = self.mic.next
            if self.segments and self.segments[-1][0] + self.segments[-1][1] == start:
                self.segments[-1][1] += count
            else:
                self.segments.append([start, count])
            self.mic.next += count
            if self.fifo_head > 0 and self.fifo_head >= len(self.fifo) // 2:
                self.fifo = self.fifo[self.fifo_head:]
                self.fifo_head = 0
            self.fifo = np.concatenate([self.fifo, np.asarray(samples, dtype=np.float32)])
            self.total_in += count
        self._drain(flush=False)
        return self._with_carry(self._take_pending(self.pending_count))

    def _with_carry(self, produced: np.ndarray) -> np.ndarray:
        if len(self.carry) == 0:
            return produced
        joined = np.concatenate([self.carry, produced])
        self.carry = np.zeros(0, dtype=np.float32)
        return joined

    def _drain(self, flush: bool) -> None:
        n = self.n
        while True:
            queued = self._queued()
            if queued == 0:
                break
            if queued < n and not flush:
                break
            pos = self.segments[0][0]
            ready = self.ref_high is not None and self.ref_high >= pos + self.lead + n
            waited = queued >= self.hold
            if not (ready or waited or flush):
                break
            self._process_held_frame(pos, ready)

    def _process_held_frame(self, pos: int, ready: bool) -> None:
        n = self.n
        m = min(n, self._queued())
        self._near[:m] = self.fifo[self.fifo_head:self.fifo_head + m]
        self._near[m:] = 0.0
        self.fifo_head += m
        remaining = m
        while remaining > 0:      # a frame may straddle a mic re-anchor (two segments)
            seg = self.segments[0]
            take = min(remaining, seg[1])
            seg[0] += take
            seg[1] -= take
            remaining -= take
            if seg[1] == 0:
                self.segments.pop(0)
        self._read_reference(pos + self.lead, self._far)
        has_ref = bool(np.any(self._far != 0.0))
        if has_ref:
            self.statistics.frames_with_reference += 1
        elif not ready:
            self.statistics.frames_held_too_long += 1
        self._run_backend(account=True)
        self.ref_consumed_end = pos + self.lead + n
        self.next_frame_pos = pos + n

    def _run_backend(self, account: bool) -> None:
        self.backend.process(self._near, self._far, self._out)
        self.statistics.frames_processed += 1
        if self.frame_observer is not None:
            self.frame_observer(self._near.copy(), self._far.copy(), self._out.copy())
        if account:
            self._account(self._near, self._far, self._out)
        emit = self._out
        if self.skip_remaining > 0:
            drop = min(self.skip_remaining, len(emit))
            self.skip_remaining -= drop
            emit = emit[drop:]
        if len(emit) > 0:
            self.pending.append(emit.copy())
            self.pending_count += len(emit)

    def _take_pending(self, count: int) -> np.ndarray:
        if count <= 0 or self.pending_count == 0:
            return np.zeros(0, dtype=np.float32)
        allp = np.concatenate(self.pending) if len(self.pending) > 1 else self.pending[0]
        take = allp[:count]
        rest = allp[count:]
        self.pending = [rest] if len(rest) else []
        self.pending_count = len(rest)
        self.returned += len(take)
        return take.copy()

    # ----------------------------------------------------------------- flush
    def flush(self) -> np.ndarray:
        self._drain(flush=True)
        owed = self.total_in - self.returned
        if owed <= 0:
            self.pending = []
            self.pending_count = 0
            self._finish_segment()
            return self._with_carry(np.zeros(0, dtype=np.float32))
        # drain the backend's algorithmic latency with silent frames
        self._near[:] = 0.0
        self._far[:] = 0.0
        guard = 0
        while self.pending_count < owed and guard < 64:
            self._run_backend(account=False)
            guard += 1
        result = self._take_pending(owed)
        self.pending = []
        self.pending_count = 0
        self._finish_segment()
        self._refresh_statistics()
        return self._with_carry(result)

    def _finish_segment(self) -> None:
        self.skip_remaining = self.latency

    def reset_timeline(self, reset_filter: bool) -> None:
        self.carry = self.flush()   # includes any earlier carry; handed out by the next call
        self.t0 = None
        self.mic.next = 0
        self.mic.has_timestamp = False
        self.ref.next = 0
        self.ref.has_timestamp = False
        self.ref_high = None
        self.ref_consumed_end = None
        self.ring[:] = 0.0
        self.segments = []
        self.fifo = np.zeros(0, dtype=np.float32)
        self.fifo_head = 0
        self.next_frame_pos = 0
        if reset_filter:
            self.backend.reset()
            self.erle_window = []
            self.far_smooth = 0.0
        self.skip_remaining = self.latency

    # ------------------------------------------------------------ statistics
    def _account(self, near: np.ndarray, far: np.ndarray, out: np.ndarray) -> None:
        ne = float(np.dot(near, near))
        fe = float(np.dot(far, far))
        oe = float(np.dot(out, out))
        n = len(near)
        if fe > FAR_ACTIVE_MEAN_SQUARE * n and ne > 0.0:
            self.erle_window.append((ne, fe, oe))
            if len(self.erle_window) > ERLE_WINDOW_FRAMES:
                self.erle_window.pop(0)
        self.frames_since_refresh += 1
        if self.frames_since_refresh >= STATS_REFRESH_FRAMES:
            self._refresh_statistics()

    def _refresh_statistics(self) -> None:
        self.frames_since_refresh = 0
        w = self.erle_window
        if len(w) >= ERLE_MIN_FRAMES:
            ratios = sorted(ne / fe for (ne, fe, _) in w)
            median = ratios[len(ratios) // 2]
            sn = so = 0.0
            for ne, fe, oe in w:
                if ne <= DOUBLE_TALK_RATIO * median * fe:
                    sn += ne
                    so += oe
            if sn > 0.0 and so > 0.0:
                self.statistics.echo_reduction_db = 10.0 * math.log10(sn / so)
        self.statistics.estimated_echo_delay_ms = self.backend.delay_ms()
