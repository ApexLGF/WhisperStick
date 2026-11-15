#pragma once

#include <stdint.h>

namespace sgm41511_diag {

enum class NtcZone : uint8_t {
    Normal = 0,
    Warm,
    Cool,
    Cold,
    Hot,
    Unknown,
};

constexpr uint8_t vbusCode(uint8_t reg08) { return (reg08 >> 5) & 0x07; }
constexpr uint8_t chargeCode(uint8_t reg08) { return (reg08 >> 3) & 0x03; }
constexpr bool powerGood(uint8_t reg08) { return (reg08 & 0x04) != 0; }
constexpr bool thermalRegulation(uint8_t reg08) { return (reg08 & 0x02) != 0; }
constexpr bool vsysRegulation(uint8_t reg08) { return (reg08 & 0x01) != 0; }

constexpr const char *vbusName(uint8_t reg08) {
    return vbusCode(reg08) == 0 ? "NONE" :
           vbusCode(reg08) == 1 ? "USB SDP" :
           vbusCode(reg08) == 2 ? "ADAPTER" :
           vbusCode(reg08) == 7 ? "OTG" : "RESERVED";
}

constexpr const char *chargeName(uint8_t reg08) {
    return chargeCode(reg08) == 0 ? "DISABLED" :
           chargeCode(reg08) == 1 ? "PRECHARGE" :
           chargeCode(reg08) == 2 ? "FAST" : "TERMINATED";
}

constexpr bool watchdogFault(uint8_t reg09) { return (reg09 & 0x80) != 0; }
constexpr bool boostFault(uint8_t reg09) { return (reg09 & 0x40) != 0; }
constexpr uint8_t chargeFaultCode(uint8_t reg09) { return (reg09 >> 4) & 0x03; }
constexpr bool batteryOverVoltage(uint8_t reg09) { return (reg09 & 0x08) != 0; }
constexpr uint8_t ntcCode(uint8_t reg09) { return reg09 & 0x07; }

constexpr const char *chargeFaultName(uint8_t reg09) {
    return chargeFaultCode(reg09) == 0 ? "NORMAL" :
           chargeFaultCode(reg09) == 1 ? "INPUT" :
           chargeFaultCode(reg09) == 2 ? "THERM SHDN" : "SAFETY TIMER";
}

constexpr NtcZone ntcZone(uint8_t reg09) {
    return ntcCode(reg09) == 0x00 ? NtcZone::Normal :
           ntcCode(reg09) == 0x02 ? NtcZone::Warm :
           ntcCode(reg09) == 0x03 ? NtcZone::Cool :
           ntcCode(reg09) == 0x05 ? NtcZone::Cold :
           ntcCode(reg09) == 0x06 ? NtcZone::Hot : NtcZone::Unknown;
}

constexpr const char *ntcName(NtcZone zone) {
    return zone == NtcZone::Normal ? "NORMAL" :
           zone == NtcZone::Warm ? "WARM" :
           zone == NtcZone::Cool ? "COOL" :
           zone == NtcZone::Cold ? "COLD" :
           zone == NtcZone::Hot ? "HOT" : "UNKNOWN";
}

constexpr const char *ntcRange(NtcZone zone) {
    return zone == NtcZone::Normal ? "10..45C" :
           zone == NtcZone::Warm ? "45..60C" :
           zone == NtcZone::Cool ? "0..10C" :
           zone == NtcZone::Cold ? "<0C" :
           zone == NtcZone::Hot ? ">60C" : "UNDEFINED";
}

constexpr bool vbusGood(uint8_t reg0a) { return (reg0a & 0x80) != 0; }
constexpr bool vindpmActive(uint8_t reg0a) { return (reg0a & 0x40) != 0; }
constexpr bool iindpmActive(uint8_t reg0a) { return (reg0a & 0x20) != 0; }
constexpr bool topoffActive(uint8_t reg0a) { return (reg0a & 0x08) != 0; }
constexpr bool acovActive(uint8_t reg0a) { return (reg0a & 0x04) != 0; }
constexpr bool vindpmInterruptMasked(uint8_t reg0a) { return (reg0a & 0x02) != 0; }
constexpr bool iindpmInterruptMasked(uint8_t reg0a) { return (reg0a & 0x01) != 0; }

constexpr uint16_t iindpmMilliamps(uint8_t reg00) {
    return static_cast<uint16_t>(100 + 100 * (reg00 & 0x1F));
}

constexpr uint16_t ichgMilliamps(uint8_t reg02) {
    const uint8_t code = reg02 & 0x3F;
    return static_cast<uint16_t>((code > 50 ? 50 : code) * 60);
}

constexpr uint16_t prechargeMilliamps(uint8_t reg03) {
    const uint8_t code = (reg03 >> 4) & 0x0F;
    return static_cast<uint16_t>(60 + 60 * (code > 12 ? 12 : code));
}

constexpr uint16_t terminationMilliamps(uint8_t reg03) {
    return static_cast<uint16_t>(60 + 60 * (reg03 & 0x0F));
}

constexpr uint16_t regulationMillivolts(uint8_t reg04) {
    const uint8_t code = (reg04 >> 3) & 0x1F;
    if (code == 15) return 4352;
    return static_cast<uint16_t>(3856 + 32 * (code > 24 ? 24 : code));
}

constexpr uint16_t systemMinimumMillivolts(uint8_t reg01) {
    constexpr uint16_t values[] = {2600, 2800, 3000, 3200, 3400, 3500, 3600, 3700};
    return values[(reg01 >> 1) & 0x07];
}

constexpr uint16_t vindpmMillivolts(uint8_t reg06) {
    return static_cast<uint16_t>(3900 + 100 * (reg06 & 0x0F));
}

constexpr bool chargerEnabled(uint8_t reg01) { return (reg01 & 0x10) != 0; }
constexpr bool otgEnabled(uint8_t reg01) { return (reg01 & 0x20) != 0; }
constexpr bool watchdogDisabled(uint8_t reg05) { return (reg05 & 0x30) == 0; }
constexpr uint16_t dieThermalLimitC(uint8_t reg05) { return (reg05 & 0x02) ? 120 : 80; }
constexpr uint8_t coolCurrentPercent(uint8_t reg05) { return (reg05 & 0x01) ? 20 : 50; }
constexpr uint16_t warmVoltageLimitMv(uint8_t reg07, uint8_t reg04) {
    return (reg07 & 0x10) ? regulationMillivolts(reg04) : 4100;
}

constexpr bool plausibleBatteryMillivolts(uint32_t mv) {
    return mv >= 2500 && mv <= 4500;
}

constexpr uint32_t restoreDividerMillivolts(uint32_t adcMv,
                                             uint32_t topOhm,
                                             uint32_t bottomOhm) {
    return bottomOhm == 0 ? 0 :
           static_cast<uint32_t>((static_cast<uint64_t>(adcMv) *
                                  (topOhm + bottomOhm) + bottomOhm / 2) /
                                 bottomOhm);
}

}  // namespace sgm41511_diag
