/* config.h -- hand-written build configuration for the vendored SpeexDSP
 * subset in this directory. NOT part of upstream (upstream generates its
 * config.h with autoconf); see VENDORED.md.
 *
 * Every vendored .c/.h file does `#ifdef HAVE_CONFIG_H / #include "config.h"`,
 * so Package.swift only has to define HAVE_CONFIG_H and this file carries the
 * rest of the configuration in one place.
 */
#ifndef CSPEEXDSP_CONFIG_H
#define CSPEEXDSP_CONFIG_H

/* 32-bit float build of the echo canceller (mdf.c) and preprocessor. */
#ifndef FLOATING_POINT
#define FLOATING_POINT 1
#endif

/* Bundled kiss FFT (no external FFT library). */
#ifndef USE_KISS_FFT
#define USE_KISS_FFT 1
#endif

/* Upstream marks exported symbols with EXPORT (a visibility attribute);
 * for a statically linked SwiftPM target it is simply empty. */
#ifndef EXPORT
#define EXPORT
#endif

/* Drops the unused print_vec() debugging helper from os_support.h. */
#ifndef RELEASE
#define RELEASE 1
#endif

/* The library otherwise prints diagnostics such as "The echo canceller
 * started acting funny and got slapped (reset)" to stderr. An app should not
 * write to stderr from the audio path; the Tools/linux-harness build defines
 * CSPEEXDSP_KEEP_WARNINGS to keep them while tuning. */
#ifndef CSPEEXDSP_KEEP_WARNINGS
#define DISABLE_WARNINGS 1
#define DISABLE_NOTIFICATIONS 1
#endif

#endif /* CSPEEXDSP_CONFIG_H */
