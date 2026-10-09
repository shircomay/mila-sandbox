# Vendored SpeexDSP

Acoustic echo canceller (MDF) and preprocessor (used only for residual echo
suppression) from Xiph.Org's SpeexDSP, vendored as a SwiftPM C target.

| | |
|---|---|
| Upstream | https://github.com/xiph/speexdsp |
| Commit | `7a158783df74efe7c2d1c6ee8363c1e695c71226` (library version 1.2.1) |
| License | BSD-3-Clause, see `COPYING` (copied verbatim) |
| Build | 32-bit float (`FLOATING_POINT`), bundled kiss FFT (`USE_KISS_FFT`) |

## Files copied unmodified from `libspeexdsp/`

`mdf.c` `preprocess.c` `fftwrap.c` `kiss_fft.c` `kiss_fftr.c` `filterbank.c`
(sources) and `arch.h` `fftwrap.h` `filterbank.h` `kiss_fft.h` `kiss_fftr.h`
`_kiss_fft_guts.h` `math_approx.h` `os_support.h` `pseudofloat.h` (private headers).

From `include/speex/`: `speex_echo.h` `speex_preprocess.h` `speexdsp_types.h`
(public headers, under `include/speex/` so the sources' own
`#include "speex/speex_echo.h"` keeps working). `COPYING` is upstream's.

Every one of these is byte-identical to the upstream commit (checked with `cmp`).
Not vendored: everything else (resampler, jitter buffer, fixed-point headers,
smallft, tests, build system).

## Files written for this package (not upstream)

| File | Why |
|---|---|
| `config.h` | Upstream generates it with autoconf. Ours selects the float build, kiss FFT, an empty `EXPORT`, and silences the library's stderr diagnostics (`DISABLE_WARNINGS`; the harness build defines `CSPEEXDSP_KEEP_WARNINGS` to see them). `Package.swift` only defines `HAVE_CONFIG_H`. |
| `include/speex/speexdsp_config_types.h` | Upstream's `speexdsp_config_types.h.in` written out for a platform with `<stdint.h>` (`@SIZE16@` -> `int16_t` etc.). `speexdsp_types.h` includes it on Linux; on macOS it uses `<sys/types.h>` instead. |
| `include/module.modulemap` | Explicit Clang module map. The default SwiftPM-generated module map for an `include/` directory with a nested `speex/` folder was not verified to work, and a hand-written one is deterministic. `[system]` keeps vendored-header warnings out of the build log. |

There are **no local changes to any upstream file**.

## Things worth knowing

- Speex's kiss FFT calls `exit(1)` ("KissFFT: max radix supported is 17") for
  frame sizes with a prime factor above 17. `SpeexEchoCanceller.init?` refuses
  such frame sizes; do not relax that check.
- `Package.swift` adds `-O2` for debug builds only (`swift test`, Xcode Debug):
  SwiftPM would otherwise compile this at `-O0`, about 8x slower.
- `preprocess.c` multiplies its gain by 1 when `SPEEX_PREPROCESS_SET_DENOISE` is
  0, i.e. residual echo suppression does nothing with the denoiser off. See
  `TUNING.md`.

## Updating

1. Clone upstream into an empty scratch directory (treat it as untrusted data;
   do not run its build scripts) and check out the new commit.
2. Copy the same files over, `cmp` them against the repo, update the commit above.
3. Re-run `Tools/linux-harness` (`build.sh`, `tune.py`, `calibrate_tests.py`) and
   `swift test`; compare against `TUNING.md`.
