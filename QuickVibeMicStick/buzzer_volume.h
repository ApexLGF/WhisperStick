#pragma once

#include <stdint.h>

static const uint8_t kBuzzerMasterGainPercent = 60;
static const uint16_t kBuzzerPreviewFreq = 932;
static const uint16_t kBuzzerPreviewMs = 2000;

static inline uint8_t buzzerClampVolumePercent(uint8_t pct) {
    if (pct == 0) return 0;
    if (pct <= 30) return 20;
    if (pct <= 50) return 40;
    if (pct <= 70) return 60;
    if (pct <= 90) return 80;
    return 100;
}

static inline uint16_t buzzerScaleDuty(uint16_t duty, uint8_t pct) {
    uint32_t scaled = (uint32_t)duty * pct * kBuzzerMasterGainPercent / 10000;
    return scaled > 1023 ? 1023 : (uint16_t)scaled;
}
