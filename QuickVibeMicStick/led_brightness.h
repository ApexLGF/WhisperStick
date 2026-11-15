#pragma once

#include <stdint.h>

static inline uint8_t ledClampBrightnessPercent(uint8_t pct) {
    if (pct == 0) return 0;
    if (pct <= 19) return 8;
    if (pct <= 51) return 32;
    return 70;
}

static inline uint8_t ledScaleChannel(uint8_t value, uint8_t pct) {
    if (value == 0 || pct == 0) return 0;
    uint16_t scaled = ((uint16_t)value * pct + 50) / 100;
    return scaled == 0 ? 1 : (uint8_t)scaled;
}
