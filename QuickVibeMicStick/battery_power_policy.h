#pragma once

#include <stdint.h>

// REG08.VSYS_STAT is not an ADC and may remain asserted during normal battery
// operation. Keep a debounced diagnostic guard, but never use it to request L3.
class VsysRegulationDiagnosticGuard {
public:
    static constexpr uint8_t kRequiredSamples = 5;
    static constexpr uint32_t kStartupGraceMs = 10000;

    void observe(bool reachable, bool vbusGood, bool vsysRegulation, uint32_t nowMs) {
        if (reachable && !vbusGood && vsysRegulation && nowMs >= kStartupGraceMs) {
            if (samples_ < 0xFF) ++samples_;
        } else {
            samples_ = 0;
        }
    }

    bool sustained() const { return samples_ >= kRequiredSamples; }
    uint8_t samples() const { return samples_; }

private:
    uint8_t samples_ = 0;
};

// V14 has a dedicated VBAT divider. Require five consecutive, plausible
// battery-only samples below the cutoff before requesting L3 so microphone,
// display or radio load transients cannot shut the rail down from one dip.
class BatteryVoltageShutdownGuard {
public:
    static constexpr uint32_t kCutoffMv = 3300;
    static constexpr uint8_t kRequiredSamples = 5;
    static constexpr uint32_t kStartupGraceMs = 10000;

    void observe(bool valid, bool vbusGood, uint32_t batteryMv, uint32_t nowMs) {
        if (valid && !vbusGood && nowMs >= kStartupGraceMs && batteryMv <= kCutoffMv) {
            if (samples_ < 0xFF) ++samples_;
        } else {
            samples_ = 0;
        }
    }

    bool shutdownDue() const { return samples_ >= kRequiredSamples; }
    uint8_t samples() const { return samples_; }
    void reset() { samples_ = 0; }

private:
    uint8_t samples_ = 0;
};
