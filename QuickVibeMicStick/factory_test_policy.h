#pragma once

#include <stdint.h>

namespace factory_test {

constexpr uint32_t kBatteryMinimumMv = 3000;
constexpr uint32_t kBatteryMaximumMv = 4400;
constexpr uint32_t kMinimumPsramBytes = 7UL * 1024UL * 1024UL;
constexpr uint32_t kMinimumFlashBytes = 15UL * 1024UL * 1024UL;

inline bool batteryVoltagePass(bool valid, uint32_t batteryMv) {
    return valid && batteryMv >= kBatteryMinimumMv && batteryMv <= kBatteryMaximumMv;
}

// Production is expected to run near room temperature. Warm/Cool are valid
// JEITA states but fail EOL because they cannot distinguish a hot/cold cell
// from an incorrectly fitted RT1/R31 network without an external fixture.
inline bool roomTemperatureNtcPass(uint8_t ntcCode) {
    return ntcCode == 0;
}

struct MicrophoneMetrics {
    uint32_t baselineRms;
    uint32_t maximumRms;
    uint32_t peak;
    uint32_t samples;
    uint32_t zeroSamples;
    uint32_t clippedSamples;
};

struct MicrophoneBlock {
    uint64_t centeredSquares;
    uint32_t centeredPeak;
};

// PDM microphones may carry a sizeable DC offset. EOL acoustic energy must be
// measured around each block's mean; otherwise a healthy, quiet microphone can
// report a larger RMS than speech and fail the response test.
inline MicrophoneBlock analyzeMicrophoneBlock(const int16_t *samples, uint32_t count) {
    if (samples == nullptr || count == 0) return {0, 0};
    int64_t sum = 0;
    for (uint32_t i = 0; i < count; ++i) sum += samples[i];
    const int32_t mean = static_cast<int32_t>(sum / static_cast<int64_t>(count));
    MicrophoneBlock block{0, 0};
    for (uint32_t i = 0; i < count; ++i) {
        const int32_t centered = static_cast<int32_t>(samples[i]) - mean;
        const uint32_t absolute = static_cast<uint32_t>(centered < 0 ? -centered : centered);
        block.centeredSquares += static_cast<uint64_t>(centered) * centered;
        if (absolute > block.centeredPeak) block.centeredPeak = absolute;
    }
    return block;
}

inline bool microphonePass(const MicrophoneMetrics &m) {
    if (m.samples < 16000 || m.peak < 40 || m.peak >= 32767) return false;
    if (m.zeroSamples * 100UL > m.samples * 20UL) return false;
    if (m.clippedSamples * 100UL > m.samples * 5UL) return false;
    const uint32_t rmsIncrease = m.baselineRms / 4UL > 30UL ? m.baselineRms / 4UL : 30UL;
    const uint32_t requiredRms = m.baselineRms < 40 ? 100 : m.baselineRms + rmsIncrease;
    const uint32_t requiredPeak = m.baselineRms * 2UL > 80UL ? m.baselineRms * 2UL : 80UL;
    return m.maximumRms >= requiredRms && m.peak >= requiredPeak;
}

}  // namespace factory_test
