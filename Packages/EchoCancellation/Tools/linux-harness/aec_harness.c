/* aec_harness.c -- C mirror of Sources/EchoCancellation/SpeexEchoCanceller.swift
 * used to tune the defaults (see TUNING.md).
 *
 * It does exactly what the Swift backend does per frame: Float -> Int16
 * (x32767, clamped, rounded), speex_echo_cancellation(), optional
 * speex_preprocess_run() on the echo-cancelled frame for residual echo
 * suppression, Int16 -> Float (/32768). Keep the two in sync.
 *
 * Two build products (see build.sh):
 *   aec_harness       command line: raw float32 files in, raw float32 file out
 *   libaecharness.so  the same backend as a tiny C API, driven from Python
 *                     (stage_model.py / tune.py) through ctypes
 *
 * Command line:
 *   aec_harness --near mic.f32 --far far.f32 --out out.f32 [options]
 *     --far must already be time-aligned to --near (same length); it is what
 *     EchoCancellationStage feeds the backend. Options mirror
 *     SpeexEchoCanceller.Configuration:
 *     --rate 16000 --frame 160 --filter-ms 300 --residual 1 --supp -40
 *     --supp-active -15 --denoise 1 --noise-supp 0
 *   Prints "latency_samples=<n>" and "delay_ms=<x>" on stderr.
 */
#include <math.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

#include "speex/speex_echo.h"
#include "speex/speex_preprocess.h"

typedef struct {
    int sample_rate;
    int frame_size;
    int filter_length;      /* samples, multiple of frame_size */
    int residual;           /* run the preprocessor for residual echo suppression */
    int supp, supp_active;  /* residual echo suppression, dB */
    int denoise;            /* SPEEX_PREPROCESS_SET_DENOISE */
    int noise_supp;         /* SPEEX_PREPROCESS_SET_NOISE_SUPPRESS, dB */
    SpeexEchoState *echo;
    SpeexPreprocessState *pre;
    spx_int16_t *near_i16, *far_i16, *out_i16;
    spx_int32_t *ir;        /* impulse response scratch (filter_length) */
    long far_active_frames;
} aec_t;

static spx_int16_t to_i16(float x)
{
    float v = x * 32767.0f;
    if (v > 32767.0f) v = 32767.0f;
    if (v < -32768.0f) v = -32768.0f;
    return (spx_int16_t)lrintf(v);
}

static void make_pre(aec_t *a)
{
    int zero = 0;
    a->pre = speex_preprocess_state_init(a->frame_size, a->sample_rate);
    speex_preprocess_ctl(a->pre, SPEEX_PREPROCESS_SET_ECHO_STATE, a->echo);
    speex_preprocess_ctl(a->pre, SPEEX_PREPROCESS_SET_ECHO_SUPPRESS, &a->supp);
    speex_preprocess_ctl(a->pre, SPEEX_PREPROCESS_SET_ECHO_SUPPRESS_ACTIVE, &a->supp_active);
    speex_preprocess_ctl(a->pre, SPEEX_PREPROCESS_SET_DENOISE, &a->denoise);
    speex_preprocess_ctl(a->pre, SPEEX_PREPROCESS_SET_NOISE_SUPPRESS, &a->noise_supp);
    speex_preprocess_ctl(a->pre, SPEEX_PREPROCESS_SET_AGC, &zero);
    speex_preprocess_ctl(a->pre, SPEEX_PREPROCESS_SET_VAD, &zero);
    speex_preprocess_ctl(a->pre, SPEEX_PREPROCESS_SET_DEREVERB, &zero);
}

/* sample_rate/frame_size in Hz/samples; filter_ms rounded UP to whole frames
 * (same rule as the Swift backend); supp/supp_active/noise_supp in dB. */
void *aec_create(int sample_rate, int frame_size, int filter_ms, int residual,
                 int supp, int supp_active, int denoise, int noise_supp)
{
    aec_t *a = (aec_t *)calloc(1, sizeof(aec_t));
    int blocks = (filter_ms * sample_rate / 1000 + frame_size - 1) / frame_size;
    int rate = sample_rate;
    if (blocks < 1) blocks = 1;
    a->sample_rate = sample_rate;
    a->frame_size = frame_size;
    a->filter_length = blocks * frame_size;
    a->residual = residual;
    a->supp = supp;
    a->supp_active = supp_active;
    a->denoise = denoise;
    a->noise_supp = noise_supp;
    a->echo = speex_echo_state_init(frame_size, a->filter_length);
    if (!a->echo) { free(a); return NULL; }
    speex_echo_ctl(a->echo, SPEEX_ECHO_SET_SAMPLING_RATE, &rate);
    if (residual) make_pre(a);
    a->near_i16 = (spx_int16_t *)calloc((size_t)frame_size, sizeof(spx_int16_t));
    a->far_i16 = (spx_int16_t *)calloc((size_t)frame_size, sizeof(spx_int16_t));
    a->out_i16 = (spx_int16_t *)calloc((size_t)frame_size, sizeof(spx_int16_t));
    a->ir = (spx_int32_t *)calloc((size_t)a->filter_length, sizeof(spx_int32_t));
    return a;
}

void aec_destroy(void *h)
{
    aec_t *a = (aec_t *)h;
    if (!a) return;
    if (a->pre) speex_preprocess_state_destroy(a->pre);
    speex_echo_state_destroy(a->echo);
    free(a->near_i16); free(a->far_i16); free(a->out_i16); free(a->ir);
    free(a);
}

void aec_reset(void *h)
{
    aec_t *a = (aec_t *)h;
    speex_echo_state_reset(a->echo);
    a->far_active_frames = 0;
    /* The preprocessor has no reset call: recreate it so its noise and
     * residual-echo history starts clean too (same as the Swift backend). */
    if (a->pre) {
        speex_preprocess_state_destroy(a->pre);
        make_pre(a);
    }
}

int aec_latency_samples(void *h)
{
    aec_t *a = (aec_t *)h;
    return a->residual ? a->frame_size : 0;
}

void aec_process(void *h, const float *near, const float *far, float *out)
{
    aec_t *a = (aec_t *)h;
    int i;
    float far_ms = 0.0f;
    for (i = 0; i < a->frame_size; i++) {
        a->near_i16[i] = to_i16(near[i]);
        a->far_i16[i] = to_i16(far[i]);
        far_ms += far[i] * far[i];
    }
    /* "far-active" = mean square > 1e-6 (about -60 dBFS RMS) */
    if (far_ms > 1e-6f * (float)a->frame_size) a->far_active_frames++;
    speex_echo_cancellation(a->echo, a->near_i16, a->far_i16, a->out_i16);
    if (a->pre) speex_preprocess_run(a->pre, a->out_i16);
    for (i = 0; i < a->frame_size; i++)
        out[i] = (float)a->out_i16[i] / 32768.0f;
}

/* Echo delay in ms (lag of the strongest filter tap, relative to the aligned
 * far stream), or -1 before ~2 s of far-active audio. Mirrors the Swift code. */
double aec_delay_ms(void *h, int require_active_frames)
{
    aec_t *a = (aec_t *)h;
    spx_int32_t n = 0;
    int i, best = 0;
    double bestv = -1.0;
    if (a->far_active_frames < require_active_frames) return -1.0;
    speex_echo_ctl(a->echo, SPEEX_ECHO_GET_IMPULSE_RESPONSE_SIZE, &n);
    if (n <= 0 || n > a->filter_length) return -1.0;
    speex_echo_ctl(a->echo, SPEEX_ECHO_GET_IMPULSE_RESPONSE, a->ir);
    for (i = 0; i < n; i++) {
        double v = fabs((double)a->ir[i]);
        if (v > bestv) { bestv = v; best = i; }
    }
    if (bestv <= 0.0) return -1.0;
    return 1000.0 * (double)best / (double)a->sample_rate;
}

#ifndef AEC_HARNESS_LIB
static float *read_f32(const char *path, size_t *count)
{
    FILE *f = fopen(path, "rb");
    long bytes;
    float *buf;
    if (!f) { perror(path); exit(2); }
    fseek(f, 0, SEEK_END);
    bytes = ftell(f);
    fseek(f, 0, SEEK_SET);
    buf = (float *)malloc((size_t)bytes + 4);
    if (fread(buf, 1, (size_t)bytes, f) != (size_t)bytes) { perror("read"); exit(2); }
    fclose(f);
    *count = (size_t)bytes / sizeof(float);
    return buf;
}

int main(int argc, char **argv)
{
    const char *near_p = NULL, *far_p = NULL, *out_p = NULL;
    int rate = 16000, frame = 160, filter_ms = 300, residual = 1;
    int supp = -40, supp_active = -15, denoise = 1, noise_supp = 0;
    int k;
    for (k = 1; k + 1 < argc; k += 2) {
        const char *key = argv[k], *val = argv[k + 1];
        if (!strcmp(key, "--near")) near_p = val;
        else if (!strcmp(key, "--far")) far_p = val;
        else if (!strcmp(key, "--out")) out_p = val;
        else if (!strcmp(key, "--rate")) rate = atoi(val);
        else if (!strcmp(key, "--frame")) frame = atoi(val);
        else if (!strcmp(key, "--filter-ms")) filter_ms = atoi(val);
        else if (!strcmp(key, "--residual")) residual = atoi(val);
        else if (!strcmp(key, "--supp")) supp = atoi(val);
        else if (!strcmp(key, "--supp-active")) supp_active = atoi(val);
        else if (!strcmp(key, "--denoise")) denoise = atoi(val);
        else if (!strcmp(key, "--noise-supp")) noise_supp = atoi(val);
        else { fprintf(stderr, "unknown option %s\n", key); return 2; }
    }
    if (!near_p || !far_p || !out_p) {
        fprintf(stderr, "usage: aec_harness --near mic.f32 --far far.f32 --out out.f32 [options]\n");
        return 2;
    }
    {
        size_t nn, nf, i;
        float *near = read_f32(near_p, &nn);
        float *far = read_f32(far_p, &nf);
        size_t n = nn < nf ? nn : nf;
        size_t frames = n / (size_t)frame;
        float *out = (float *)calloc(nn + (size_t)frame, sizeof(float));
        void *h = aec_create(rate, frame, filter_ms, residual, supp, supp_active, denoise, noise_supp);
        FILE *fo;
        if (!h) { fprintf(stderr, "init failed\n"); return 1; }
        for (i = 0; i < frames; i++)
            aec_process(h, near + i * (size_t)frame, far + i * (size_t)frame, out + i * (size_t)frame);
        fo = fopen(out_p, "wb");
        fwrite(out, sizeof(float), frames * (size_t)frame, fo);
        fclose(fo);
        fprintf(stderr, "frames=%zu latency_samples=%d delay_ms=%.1f\n", frames,
                aec_latency_samples(h), aec_delay_ms(h, 200));
        aec_destroy(h);
        free(near); free(far); free(out);
    }
    return 0;
}
#endif
