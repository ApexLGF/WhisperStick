#include "charger_sgm41511.h"

#ifdef BOARD_MICSTICK_V14

#include <Arduino.h>
#include <Wire.h>

#include "sgm41511_regs.h"

namespace {
constexpr uint16_t kInputLimitMa = 800;
constexpr uint16_t kChargeCurrentMa = 480;
constexpr uint16_t kPrechargeCurrentMa = 120;
constexpr uint16_t kTerminationCurrentMa = 120;
constexpr uint16_t kChargeVoltageMv = 4208;
constexpr uint16_t kSystemMinimumMv = 3500;
constexpr uint32_t kPollIntervalMs = 1000;

Sgm41511Snapshot s_snapshot = {};
uint32_t s_lastPollMs = 0;
bool s_shipModePrepared = false;
bool s_shipModeCommitted = false;

bool updateField(uint8_t reg, uint8_t mask, uint8_t value) {
    uint8_t before = 0;
    if (!sgm41511_read_register(reg, before)) return false;
    const uint8_t desired = sgm41511::replaceField(before, mask, value);
    if (desired != before && !sgm41511_write_register(reg, desired)) return false;
    uint8_t verify = 0;
    return sgm41511_read_register(reg, verify) && (verify & mask) == (desired & mask);
}

bool applyConfiguration() {
    // Fail safe: stop charging/OTG before touching current limits. The POR
    // charge current is 2.04A, well above the 1000mAh cell's 0.5C rating.
    if (!updateField(sgm41511::REG_POWER_CTRL,
                     sgm41511::kOtgEnable | sgm41511::kChargeEnable |
                         sgm41511::kSysMinMask,
                     sgm41511::sysMinField(kSystemMinimumMv))) {
        return false;
    }

    bool ok = true;
    ok = updateField(sgm41511::REG_CHARGE_CURRENT, sgm41511::kIchgMask,
                     sgm41511::ichgCode(kChargeCurrentMa)) && ok;
    const uint8_t preTerm = static_cast<uint8_t>(
        (sgm41511::preTermCode(kPrechargeCurrentMa) << 4) |
         sgm41511::preTermCode(kTerminationCurrentMa));
    ok = updateField(sgm41511::REG_PRE_TERM_CURRENT, 0xFF, preTerm) && ok;
    ok = updateField(sgm41511::REG_CHARGE_VOLTAGE, sgm41511::kVregMask,
                     sgm41511::vregField(kChargeVoltageMv)) && ok;
    // Own the JEITA response explicitly: cool range uses 20% ICHG; warm range
    // is capped at the lower of VREG and 4.1V.  Comparator thresholds remain
    // hardware-defined by the TS bias network.
    ok = updateField(sgm41511::REG_TIMER_CTRL,
                     sgm41511::kWatchdogMask | sgm41511::kJeitaIsetMask,
                     sgm41511::kJeitaIsetMask) && ok;
    ok = updateField(sgm41511::REG_MISC_CTRL,
                     sgm41511::kJeitaVsetMask | sgm41511::kBatfetDisable |
                         sgm41511::kBatfetDelay | sgm41511::kBatfetResetEnable,
                     sgm41511::kBatfetDelay | sgm41511::kBatfetResetEnable) && ok;
    // Apply last: input detection can replace IINDPM based on PSEL after VBUS insertion.
    ok = updateField(sgm41511::REG_INPUT_CTRL, sgm41511::kIindpmMask,
                     sgm41511::iindpmCode(kInputLimitMa)) && ok;
    if (!ok) return false;  // Leave CHG_CONFIG=0 until every field verifies.

    // nCE is held low by hardware; CHG_CONFIG is the final enable gate.
    return updateField(sgm41511::REG_POWER_CTRL,
                       sgm41511::kOtgEnable | sgm41511::kChargeEnable |
                           sgm41511::kSysMinMask,
                       sgm41511::kChargeEnable |
                           sgm41511::sysMinField(kSystemMinimumMv));
}

struct ControlledField {
    uint8_t reg;
    uint8_t mask;
    uint8_t value;
};

bool configurationMatches(bool &ioOk) {
    const uint8_t preTerm = static_cast<uint8_t>(
        (sgm41511::preTermCode(kPrechargeCurrentMa) << 4) |
         sgm41511::preTermCode(kTerminationCurrentMa));
    const ControlledField fields[] = {
        {sgm41511::REG_INPUT_CTRL, sgm41511::kIindpmMask,
         sgm41511::iindpmCode(kInputLimitMa)},
        {sgm41511::REG_POWER_CTRL,
         static_cast<uint8_t>(sgm41511::kOtgEnable | sgm41511::kChargeEnable |
                              sgm41511::kSysMinMask),
         static_cast<uint8_t>(sgm41511::kChargeEnable |
                              sgm41511::sysMinField(kSystemMinimumMv))},
        {sgm41511::REG_CHARGE_CURRENT, sgm41511::kIchgMask,
         sgm41511::ichgCode(kChargeCurrentMa)},
        {sgm41511::REG_PRE_TERM_CURRENT, 0xFF, preTerm},
        {sgm41511::REG_CHARGE_VOLTAGE, sgm41511::kVregMask,
         sgm41511::vregField(kChargeVoltageMv)},
        {sgm41511::REG_TIMER_CTRL,
         static_cast<uint8_t>(sgm41511::kWatchdogMask | sgm41511::kJeitaIsetMask),
         sgm41511::kJeitaIsetMask},
        {sgm41511::REG_MISC_CTRL,
         static_cast<uint8_t>(sgm41511::kJeitaVsetMask | sgm41511::kBatfetDisable |
                              sgm41511::kBatfetDelay | sgm41511::kBatfetResetEnable),
         static_cast<uint8_t>(sgm41511::kBatfetDelay |
                              sgm41511::kBatfetResetEnable)},
    };

    ioOk = true;
    for (const ControlledField &field : fields) {
        uint8_t actual = 0;
        if (!sgm41511_read_register(field.reg, actual)) {
            ioOk = false;
            return false;
        }
        if ((actual & field.mask) != (field.value & field.mask)) return false;
    }
    return true;
}

void refreshSnapshot() {
    uint8_t reg08 = 0, reg09 = 0, reg0a = 0, reg0b = 0;
    const bool ok = sgm41511_read_register(sgm41511::REG_SYSTEM_STATUS, reg08) &&
                    sgm41511_read_register(sgm41511::REG_FAULT_STATUS, reg09) &&
                    sgm41511_read_register(sgm41511::REG_INPUT_STATUS, reg0a) &&
                    sgm41511_read_register(sgm41511::REG_PART_INFO, reg0b);
    s_snapshot.reg08SystemStatus = reg08;
    s_snapshot.reg09FaultStatus = reg09;
    s_snapshot.reg0aInputStatus = reg0a;
    s_snapshot.reachable = ok;
    s_snapshot.updatedMs = millis();
    if (!ok) {
        s_snapshot.configured = false;
        return;
    }

    s_snapshot.vbusGood = (reg0a & sgm41511::kVbusGood) != 0;
    s_snapshot.powerGood = (reg08 & sgm41511::kPowerGood) != 0;
    s_snapshot.thermalRegulation = (reg08 & sgm41511::kThermalRegulation) != 0;
    s_snapshot.vsysRegulation = (reg08 & sgm41511::kVsysRegulation) != 0;
    s_snapshot.vindpmActive = (reg0a & sgm41511::kVindpmActive) != 0;
    s_snapshot.iindpmActive = (reg0a & sgm41511::kIindpmActive) != 0;
    s_snapshot.chargeState = sgm41511::chargeState(reg08);
    s_snapshot.fault = reg09;
    s_snapshot.ntcFault = sgm41511::ntcFault(reg09);
    s_snapshot.partInfo = reg0b;
}
}  // namespace

bool sgm41511_read_register(uint8_t reg, uint8_t &value) {
    Wire.beginTransmission(sgm41511::kAddress);
    Wire.write(reg);
    if (Wire.endTransmission(false) != 0) return false;
    if (Wire.requestFrom(sgm41511::kAddress, static_cast<uint8_t>(1)) != 1) return false;
    value = Wire.read();
    return true;
}

bool sgm41511_write_register(uint8_t reg, uint8_t value) {
    Wire.beginTransmission(sgm41511::kAddress);
    Wire.write(reg);
    Wire.write(value);
    return Wire.endTransmission() == 0;
}

bool sgm41511_begin(uint8_t sdaPin, uint8_t sclPin) {
    Wire.begin(sdaPin, sclPin, 100000);
    s_snapshot = {};
    s_shipModePrepared = false;
    s_shipModeCommitted = false;

    uint8_t partInfo = 0;
    bool identified = false;
    for (uint8_t attempt = 0; attempt < 3; ++attempt) {
        if (sgm41511_read_register(sgm41511::REG_PART_INFO, partInfo) &&
            sgm41511::partNumber(partInfo) == sgm41511::kExpectedPartNumber) {
            identified = true;
            break;
        }
        delay(20);
    }
    s_snapshot.reachable = identified;
    s_snapshot.partInfo = partInfo;
    if (!identified) return false;

    s_snapshot.configured = applyConfiguration();
    refreshSnapshot();
    return s_snapshot.configured;
}

void sgm41511_tick() {
    // Once the irreversible final write has been accepted, never let the
    // configuration auditor clear BATFET_DIS while the rail is collapsing.
    if (s_shipModePrepared || s_shipModeCommitted) return;
    const uint32_t now = millis();
    if (now - s_lastPollMs < kPollIntervalMs) return;
    s_lastPollMs = now;

    refreshSnapshot();
    if (!s_snapshot.reachable) return;
    if (sgm41511::partNumber(s_snapshot.partInfo) != sgm41511::kExpectedPartNumber) {
        s_snapshot.reachable = false;
        s_snapshot.configured = false;
        return;
    }
    // Audit every field owned by this driver. Register reset, watchdog reset or
    // PSEL input detection can restore unsafe/default values at runtime.  A
    // mismatch runs the same fail-safe sequence as boot: disable charging first,
    // rewrite all fields, verify them, and only then re-enable charging.
    bool ioOk = false;
    const bool matches = configurationMatches(ioOk);
    if (!ioOk) {
        s_snapshot.reachable = false;
        s_snapshot.configured = false;
        return;
    }
    s_snapshot.configured = matches ? true : applyConfiguration();
}

const Sgm41511Snapshot &sgm41511_snapshot() {
    return s_snapshot;
}

bool sgm41511_prepare_ship_mode() {
    if (!s_snapshot.reachable || s_shipModeCommitted) return false;

    // Configure immediate shutdown and nQON recovery first, with BATFET still
    // enabled. This reversible write can be read back before the final step.
    const uint8_t mask = sgm41511::kBatfetDisable | sgm41511::kBatfetDelay |
                         sgm41511::kBatfetResetEnable;
    if (!updateField(sgm41511::REG_MISC_CTRL, mask,
                     sgm41511::kBatfetResetEnable)) {
        s_shipModePrepared = false;
        return false;
    }
    s_shipModePrepared = true;
    return true;
}

void sgm41511_cancel_ship_mode() {
    if (s_shipModeCommitted) return;
    s_shipModePrepared = false;
    // Restore the driver's normal REG07 ownership (DIS=0, DLY=1, RST_EN=1)
    // and all other audited charging fields after a VBUS race or failed commit.
    s_snapshot.configured = applyConfiguration();
}

bool sgm41511_commit_ship_mode() {
    if (!s_shipModePrepared || s_shipModeCommitted) return false;

    uint8_t reg07 = 0;
    if (!sgm41511_read_register(sgm41511::REG_MISC_CTRL, reg07)) return false;
    const uint8_t preparedMask = sgm41511::kBatfetDelay |
                                 sgm41511::kBatfetResetEnable;
    if ((reg07 & preparedMask) != sgm41511::kBatfetResetEnable ||
        (reg07 & sgm41511::kBatfetDisable) != 0) {
        s_shipModePrepared = false;
        return false;
    }

    // Final irreversible write. Do not attempt a readback: BATFET_DLY=0 means
    // VSYS can disappear as soon as the charger accepts this transaction.
    const uint8_t desired = static_cast<uint8_t>(reg07 | sgm41511::kBatfetDisable);
    if (!sgm41511_write_register(sgm41511::REG_MISC_CTRL, desired)) return false;
    s_shipModeCommitted = true;
    return true;
}

#endif  // BOARD_MICSTICK_V14
