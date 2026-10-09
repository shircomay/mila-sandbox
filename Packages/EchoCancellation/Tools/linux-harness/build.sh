#!/bin/sh
# Build the tuning harness from the vendored SpeexDSP sources (float build,
# kiss FFT) and aec_harness.c.
#
#   Tools/linux-harness/build.sh <build-dir> [extra cc flags, e.g. -O0]
#
# The build directory must be OUTSIDE the vendored tree (objects are never
# written next to the sources). Produces
#   <build-dir>/aec_harness       command-line tool (raw float32 in/out)
#   <build-dir>/libaecharness.so  same backend as a C API for ctypes (Python)
# (use .dylib naming on macOS: pass the output name via AEC_LIB_NAME).
set -eu

out="${1:?usage: build.sh <build-dir> [extra cc flags]}"
shift
here="$(cd "$(dirname "$0")" && pwd)"
vendor="$here/../../Sources/CSpeexDSP"
lib="${AEC_LIB_NAME:-libaecharness.so}"
opt="-O2"
if [ "$#" -gt 0 ]; then opt="$*"; fi

mkdir -p "$out"
srcs="$vendor/mdf.c $vendor/preprocess.c $vendor/fftwrap.c $vendor/kiss_fft.c $vendor/kiss_fftr.c $vendor/filterbank.c"
flags="-std=gnu11 -Wall -DHAVE_CONFIG_H -DCSPEEXDSP_KEEP_WARNINGS -I$vendor -I$vendor/include"

# shellcheck disable=SC2086
cc $opt $flags "$here/aec_harness.c" $srcs -lm -o "$out/aec_harness"
# shellcheck disable=SC2086
cc $opt $flags -shared -fPIC -DAEC_HARNESS_LIB "$here/aec_harness.c" $srcs -lm -o "$out/$lib"
echo "built $out/aec_harness and $out/$lib ($opt)"
