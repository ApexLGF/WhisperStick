#pragma once

#include <stdint.h>
#include <math.h>

#ifndef AUDIO_AGC_MAX_GAIN
#define AUDIO_AGC_MAX_GAIN 8.0f
#endif

#ifndef AUDIO_AGC_INITIAL_GAIN
#define AUDIO_AGC_INITIAL_GAIN AUDIO_AGC_MAX_GAIN
#endif

#define AUDIO_AGC_MIN_GAIN       0.25f
#define AUDIO_AGC_TARGET_RMS     3277.0f   // -20 dBFS
#define AUDIO_AGC_PEAK_CEILING   14000.0f  // ~-7.4 dBFS
#define AUDIO_AGC_NOISE_FLOOR      260.0f  // ~-42 dBFS
#define AUDIO_AGC_RECOVERY_FLOOR    40.0f
#define AUDIO_AGC_RELEASE_STEP       0.03f

struct AudioAgc {
    float gain = AUDIO_AGC_INITIAL_GAIN;
};

static inline float audioAgcClampGain(float gain) {
    if (gain < AUDIO_AGC_MIN_GAIN) return AUDIO_AGC_MIN_GAIN;
    if (gain > AUDIO_AGC_MAX_GAIN) return AUDIO_AGC_MAX_GAIN;
    return gain;
}

static inline float audioAgcUpdateGain(AudioAgc *agc, float rms, float peak) {
    float desired = agc->gain;

    if (peak > 1.0f) {
        float peakSafe = AUDIO_AGC_PEAK_CEILING / peak;
        if (peakSafe < desired) desired = peakSafe;
    }

    if (rms > AUDIO_AGC_RECOVERY_FLOOR) {
        float rmsTarget = AUDIO_AGC_TARGET_RMS / rms;
        if (rmsTarget < desired) {
            desired = rmsTarget;
        } else if (rms > AUDIO_AGC_NOISE_FLOOR || agc->gain < AUDIO_AGC_INITIAL_GAIN) {
            desired = agc->gain + (rmsTarget - agc->gain) * AUDIO_AGC_RELEASE_STEP;
        }
    }

    agc->gain = audioAgcClampGain(desired);
    return agc->gain;
}

static inline uint32_t audioAgcProcessChunk(AudioAgc *agc, const int16_t *pcmIn, int16_t *pcmOut, int samples) {
    float peak = 0.0f;
    double sumSq = 0.0;

    for (int i = 0; i < samples; i++) {
        float s = (float)pcmIn[i];
        float a = fabsf(s);
        if (a > peak) peak = a;
        sumSq += (double)s * (double)s;
    }

    float rms = samples > 0 ? sqrtf((float)(sumSq / (double)samples)) : 0.0f;
    float gain = audioAgcUpdateGain(agc, rms, peak);
    uint32_t clipped = 0;

    for (int i = 0; i < samples; i++) {
        float out = (float)pcmIn[i] * gain;
        if (out > 32767.0f) { out = 32767.0f; clipped++; }
        if (out < -32768.0f) { out = -32768.0f; clipped++; }
        pcmOut[i] = (int16_t)out;
    }

    return clipped;
}
