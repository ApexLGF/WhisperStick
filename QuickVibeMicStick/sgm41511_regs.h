#pragma once

#include <stdint.h>

namespace sgm41511 {

constexpr uint8_t kAddress = 0x6B;
constexpr uint8_t kRegisterCount = 0x0C;

enum Register : uint8_t {
    REG_INPUT_CTRL = 0x00,
    REG_POWER_CTRL = 0x01,
    REG_CHARGE_CURRENT = 0x02,
    REG_PRE_TERM_CURRENT = 0x03,
    REG_CHARGE_VOLTAGE = 0x04,
    REG_TIMER_CTRL = 0x05,
    REG_INPUT_VOLTAGE = 0x06,
    REG_MISC_CTRL = 0x07,
    REG_SYSTEM_STATUS = 0x08,
    REG_FAULT_STATUS = 0x09,
    REG_INPUT_STATUS = 0x0A,
    REG_PART_INFO = 0x0B,
};

constexpr uint8_t kIindpmMask = 0x1F;
constexpr uint8_t kChargeEnable = 0x10;
constexpr uint8_t kOtgEnable = 0x20;
constexpr uint8_t kSysMinMask = 0x0E;
constexpr uint8_t kIchgMask = 0x3F;
constexpr uint8_t kVregMask = 0xF8;
constexpr uint8_t kWatchdogMask = 0x30;
constexpr uint8_t kJeitaIsetMask = 0x01;  // REG05.D0: 1 = cool charge at 20% ICHG
constexpr uint8_t kJeitaVsetMask = 0x10;  // REG07.D4: 0 = warm charge capped at 4.1V
constexpr uint8_t kBatfetDisable = 0x20;   // REG07.D5: 1 = disconnect BATFET
constexpr uint8_t kBatfetDelay = 0x08;     // REG07.D3: 0 = immediate, 1 = ~8s delay
constexpr uint8_t kBatfetResetEnable = 0x04;  // REG07.D2: nQON may reset/enable BATFET
constexpr uint8_t kNtcFaultMask = 0x07;
constexpr uint8_t kVbusGood = 0x80;
constexpr uint8_t kChrgStatMask = 0x18;
constexpr uint8_t kChrgStatShift = 3;
constexpr uint8_t kPowerGood = 0x04;
constexpr uint8_t kThermalRegulation = 0x02;
constexpr uint8_t kVsysRegulation = 0x01;
constexpr uint8_t kVindpmActive = 0x40;
constexpr uint8_t kIindpmActive = 0x20;
constexpr uint8_t kPartNumberMask = 0x78;
constexpr uint8_t kPartNumberShift = 3;
constexpr uint8_t kExpectedPartNumber = 0x02;

enum class NtcFault : uint8_t {
    Normal = 0x00,
    Warm = 0x02,
    Cool = 0x03,
    Cold = 0x05,
    Hot = 0x06,
    Unknown = 0xFF,
};

constexpr uint8_t replaceField(uint8_t original, uint8_t mask, uint8_t value) {
    return static_cast<uint8_t>((original & ~mask) | (value & mask));
}

constexpr uint8_t iindpmCode(uint16_t milliamps) {
    return milliamps <= 100 ? 0 :
           milliamps >= 3200 ? 31 : static_cast<uint8_t>((milliamps - 100) / 100);
}

constexpr uint8_t ichgCode(uint16_t milliamps) {
    return milliamps >= 3780 ? 63 : static_cast<uint8_t>(milliamps / 60);
}

constexpr uint8_t preTermCode(uint16_t milliamps) {
    return milliamps <= 60 ? 0 :
           milliamps >= 960 ? 15 : static_cast<uint8_t>((milliamps - 60) / 60);
}

constexpr uint8_t vregField(uint16_t millivolts) {
    return millivolts <= 3856 ? 0 :
           millivolts >= 4624 ? kVregMask :
           static_cast<uint8_t>(((millivolts - 3856) / 32) << 3);
}

// REG01.SYS_MIN uses an irregular table: 2.6, 2.8, 3.0, 3.2, 3.4,
// 3.5, 3.6 and 3.7V.  Return the closest supported value without exceeding
// the requested threshold; 3500mV is code 101 and the datasheet default.
constexpr uint8_t sysMinField(uint16_t millivolts) {
    return millivolts < 2800 ? 0x00 :
           millivolts < 3000 ? 0x02 :
           millivolts < 3200 ? 0x04 :
           millivolts < 3400 ? 0x06 :
           millivolts < 3500 ? 0x08 :
           millivolts < 3600 ? 0x0A :
           millivolts < 3700 ? 0x0C : 0x0E;
}

constexpr uint8_t chargeState(uint8_t reg08) {
    return static_cast<uint8_t>((reg08 & kChrgStatMask) >> kChrgStatShift);
}

constexpr NtcFault ntcFault(uint8_t reg09) {
    const uint8_t code = static_cast<uint8_t>(reg09 & kNtcFaultMask);
    return code == 0x00 ? NtcFault::Normal :
           code == 0x02 ? NtcFault::Warm :
           code == 0x03 ? NtcFault::Cool :
           code == 0x05 ? NtcFault::Cold :
           code == 0x06 ? NtcFault::Hot : NtcFault::Unknown;
}

constexpr bool ntcFaultIsSevere(NtcFault fault) {
    return fault == NtcFault::Cold || fault == NtcFault::Hot ||
           fault == NtcFault::Unknown;
}

constexpr uint8_t partNumber(uint8_t reg0b) {
    return static_cast<uint8_t>((reg0b & kPartNumberMask) >> kPartNumberShift);
}

}  // namespace sgm41511
