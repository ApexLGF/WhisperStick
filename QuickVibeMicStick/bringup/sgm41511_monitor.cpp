// V14 hardware-engineering monitor: LCD + serial diagnostics for SGM41511 and
// an optional VBAT divider on an ADC pin.  Deliberately excludes BLE, audio,
// RGB effects, buzzer output, NVS writes and power-off/Ship Mode actions.
#include <Arduino.h>
#include <TFT_eSPI.h>
#include <Wire.h>
#include <esp_system.h>

#include "charger_sgm41511.h"
#include "pin_config.h"
#include "sgm41511_decode.h"
#include "sgm41511_regs.h"

#ifndef VBAT_ADC_MONITOR_ENABLED
#define VBAT_ADC_MONITOR_ENABLED 1
#endif
#ifndef VBAT_ADC_PIN
#define VBAT_ADC_PIN 7
#endif
#ifndef VBAT_DIVIDER_TOP_OHM
#define VBAT_DIVIDER_TOP_OHM 100000UL
#endif
#ifndef VBAT_DIVIDER_BOTTOM_OHM
#define VBAT_DIVIDER_BOTTOM_OHM 100000UL
#endif
#ifndef VBAT_ADC_ENABLE_PIN
#define VBAT_ADC_ENABLE_PIN -1
#endif
#ifndef VBAT_ADC_ENABLE_LEVEL
#define VBAT_ADC_ENABLE_LEVEL HIGH
#endif
#ifndef VBAT_ADC_SETTLE_MS
#define VBAT_ADC_SETTLE_MS 10
#endif

namespace {
using namespace sgm41511_diag;

constexpr uint32_t kStatusPollMs = 500;
constexpr uint32_t kFullDumpMs = 2000;
constexpr uint32_t kAdcPollMs = 250;
constexpr uint32_t kRenderMs = 250;
constexpr uint32_t kSerialMs = 1000;
constexpr uint32_t kAutoPageMs = 8000;
constexpr uint8_t kPageCount = 5;

TFT_eSPI tft;
TFT_eSprite screen(&tft);
bool screenReady = false;

struct MonitorState {
    uint8_t regs[sgm41511::kRegisterCount] = {};
    uint8_t bootRegs[sgm41511::kRegisterCount] = {};
    bool bootRegValid[sgm41511::kRegisterCount] = {};
    bool regsValid = false;
    uint32_t lastI2cOkMs = 0;
    uint32_t i2cSnapshotsOk = 0;
    uint32_t i2cSnapshotsFail = 0;
    uint16_t consecutiveI2cFail = 0;
    uint16_t busRecoveries = 0;
    uint8_t faultLatched = 0;
    uint8_t previousFault = 0;
    uint16_t faultTransitions = 0;

    uint16_t adcRaw = 0;
    uint32_t adcPinMv = 0;
    uint32_t batteryMv = 0;
    uint32_t batteryMinMv = UINT32_MAX;
    uint32_t batteryMaxMv = 0;
    float batteryEmaMv = 0.0f;
    uint8_t plausibleAdcSamples = 0;
    bool batteryValid = false;

    uint8_t page = 0;
    bool autoPage = true;
    uint32_t lastPageMs = 0;
} state;

uint32_t lastStatusPollMs = 0;
uint32_t lastFullDumpMs = 0;
uint32_t lastAdcPollMs = 0;
uint32_t lastRenderMs = 0;
uint32_t lastSerialMs = 0;
uint32_t lastRecoveryAttemptMs = 0;

const char *resetReasonName(esp_reset_reason_t reason) {
    switch (reason) {
        case ESP_RST_POWERON: return "POWERON";
        case ESP_RST_EXT: return "EXTERNAL";
        case ESP_RST_SW: return "SOFTWARE";
        case ESP_RST_PANIC: return "PANIC";
        case ESP_RST_INT_WDT: return "INT_WDT";
        case ESP_RST_TASK_WDT: return "TASK_WDT";
        case ESP_RST_WDT: return "WDT";
        case ESP_RST_BROWNOUT: return "BROWNOUT";
        default: return "OTHER";
    }
}

bool readRegisterBlock(uint8_t first, uint8_t last) {
    uint8_t values[sgm41511::kRegisterCount] = {};
    for (uint8_t reg = first; reg <= last; ++reg) {
        if (!sgm41511_read_register(reg, values[reg])) {
            state.i2cSnapshotsFail++;
            state.consecutiveI2cFail++;
            return false;
        }
    }
    for (uint8_t reg = first; reg <= last; ++reg) state.regs[reg] = values[reg];
    state.regsValid = true;
    state.lastI2cOkMs = millis();
    state.i2cSnapshotsOk++;
    state.consecutiveI2cFail = 0;

    const uint8_t fault = state.regs[sgm41511::REG_FAULT_STATUS];
    state.faultLatched |= fault;
    if (fault != state.previousFault) {
        state.faultTransitions++;
        Serial.printf("EVENT,%lu,FAULT,0x%02X,0x%02X,%s,%s\n",
                      static_cast<unsigned long>(millis()), state.previousFault, fault,
                      chargeFaultName(fault), ntcName(ntcZone(fault)));
        state.previousFault = fault;
    }
    return true;
}

void captureBootRegisters() {
    Wire.begin(PIN_CHARGER_SDA, PIN_CHARGER_SCL, 100000);
    for (uint8_t reg = 0; reg < sgm41511::kRegisterCount; ++reg) {
        state.bootRegValid[reg] = sgm41511_read_register(reg, state.bootRegs[reg]);
    }
}

void recoverI2cIfNeeded() {
    if (state.consecutiveI2cFail < 3 || millis() - lastRecoveryAttemptMs < 3000) return;
    lastRecoveryAttemptMs = millis();
    state.busRecoveries++;
    Serial.printf("EVENT,%lu,I2C_RECOVERY,%u,SDA=%d,SCL=%d\n",
                  static_cast<unsigned long>(millis()), state.busRecoveries,
                  digitalRead(PIN_CHARGER_SDA), digitalRead(PIN_CHARGER_SCL));
    Wire.end();
    delay(5);
    sgm41511_begin(PIN_CHARGER_SDA, PIN_CHARGER_SCL);
}

uint16_t medianAdcRaw(uint32_t &medianMv) {
    constexpr uint8_t count = 17;
    uint16_t raw[count];
    uint16_t mv[count];
    for (uint8_t i = 0; i < count; ++i) {
        raw[i] = analogRead(VBAT_ADC_PIN);
        mv[i] = static_cast<uint16_t>(analogReadMilliVolts(VBAT_ADC_PIN));
        delayMicroseconds(150);
    }
    for (uint8_t i = 1; i < count; ++i) {
        uint16_t r = raw[i], v = mv[i];
        int8_t j = static_cast<int8_t>(i) - 1;
        while (j >= 0 && mv[j] > v) {
            raw[j + 1] = raw[j];
            mv[j + 1] = mv[j];
            --j;
        }
        raw[j + 1] = r;
        mv[j + 1] = v;
    }
    medianMv = mv[count / 2];
    return raw[count / 2];
}

void sampleBatteryAdc() {
#if VBAT_ADC_MONITOR_ENABLED
#if VBAT_ADC_ENABLE_PIN >= 0
    digitalWrite(VBAT_ADC_ENABLE_PIN, VBAT_ADC_ENABLE_LEVEL);
    delay(VBAT_ADC_SETTLE_MS);
#endif
    uint32_t pinMv = 0;
    state.adcRaw = medianAdcRaw(pinMv);
    state.adcPinMv = pinMv;
    const uint32_t restored = restoreDividerMillivolts(
        pinMv, VBAT_DIVIDER_TOP_OHM, VBAT_DIVIDER_BOTTOM_OHM);
#if VBAT_ADC_ENABLE_PIN >= 0
    digitalWrite(VBAT_ADC_ENABLE_PIN, !VBAT_ADC_ENABLE_LEVEL);
#endif
    if (plausibleBatteryMillivolts(restored)) {
        if (state.plausibleAdcSamples < 3) state.plausibleAdcSamples++;
        state.batteryEmaMv = state.batteryEmaMv == 0.0f ? restored :
            0.25f * restored + 0.75f * state.batteryEmaMv;
        state.batteryMv = static_cast<uint32_t>(state.batteryEmaMv + 0.5f);
        state.batteryValid = state.plausibleAdcSamples >= 3;
        if (state.batteryValid) {
            if (state.batteryMv < state.batteryMinMv) state.batteryMinMv = state.batteryMv;
            if (state.batteryMv > state.batteryMaxMv) state.batteryMaxMv = state.batteryMv;
        }
    } else {
        state.plausibleAdcSamples = 0;
        state.batteryValid = false;
        state.batteryMv = 0;
        state.batteryEmaMv = 0.0f;
    }
#else
    state.batteryValid = false;
#endif
}

void drawHeader(const char *title, uint8_t page) {
    screen.fillSprite(TFT_BLACK);
    screen.fillRect(0, 0, 170, 25, TFT_DARKGREY);
    screen.setTextColor(TFT_WHITE, TFT_DARKGREY);
    screen.setTextFont(2);
    screen.setTextDatum(ML_DATUM);
    screen.drawString(title, 5, 12);
    char pageText[12];
    snprintf(pageText, sizeof(pageText), "%u/%u", page + 1, kPageCount);
    screen.setTextDatum(MR_DATUM);
    screen.drawString(pageText, 165, 12);
    screen.setTextDatum(TL_DATUM);
}

void drawRow(int y, const char *label, const char *value,
             uint16_t valueColor = TFT_WHITE) {
    // Font 1 keeps the label and decoded value in separate visual columns on
    // the narrow 170px panel. Font 2 is reserved for page titles.
    screen.setTextFont(1);
    screen.setTextColor(TFT_DARKGREY, TFT_BLACK);
    screen.setTextDatum(TL_DATUM);
    screen.drawString(label, 4, y);
    screen.setTextColor(valueColor, TFT_BLACK);
    screen.setTextDatum(TR_DATUM);
    screen.drawString(value, 166, y);
    screen.setTextDatum(TL_DATUM);
}

void drawFlagRow(int y, const char *text, bool active, bool warning = false) {
    screen.setTextFont(1);
    screen.setTextColor(active ? (warning ? TFT_ORANGE : TFT_GREEN) : TFT_DARKGREY,
                        TFT_BLACK);
    screen.drawString(text, 4, y);
}

void formatBattery(char *out, size_t size) {
    if (state.batteryValid) snprintf(out, size, "%lu mV", state.batteryMv);
    else snprintf(out, size, "--");
}

bool dataStale() {
    return !state.regsValid || millis() - state.lastI2cOkMs > 2500;
}

bool severeFault(uint8_t reg09) {
    const NtcZone zone = ntcZone(reg09);
    return watchdogFault(reg09) || boostFault(reg09) || chargeFaultCode(reg09) != 0 ||
           batteryOverVoltage(reg09) || zone == NtcZone::Cold || zone == NtcZone::Hot ||
           zone == NtcZone::Unknown;
}

uint16_t faultColor(uint8_t reg09) {
    if (reg09 == 0) return TFT_GREEN;
    return severeFault(reg09) ? TFT_RED : TFT_ORANGE;
}

void formatCurrentFault(uint8_t reg09, char *out, size_t size) {
    if (reg09 == 0) {
        snprintf(out, size, "0x00 NORMAL");
    } else if (!severeFault(reg09) && ntcZone(reg09) != NtcZone::Normal) {
        snprintf(out, size, "0x%02X NTC %s", reg09, ntcName(ntcZone(reg09)));
    } else {
        snprintf(out, size, "0x%02X %s", reg09, chargeFaultName(reg09));
    }
}

void formatBits3(uint8_t value, char out[4]) {
    out[0] = static_cast<char>('0' + ((value >> 2) & 1));
    out[1] = static_cast<char>('0' + ((value >> 1) & 1));
    out[2] = static_cast<char>('0' + (value & 1));
    out[3] = '\0';
}

void drawOverview() {
    drawHeader("V14 POWER MONITOR", 0);
    char value[36];
    const Sgm41511Snapshot &snapshot = sgm41511_snapshot();
    snprintf(value, sizeof(value), "%s / CFG %s",
             dataStale() ? "I2C FAIL" : "I2C OK", snapshot.configured ? "OK" : "BAD");
    drawRow(32, "CHARGER", value, dataStale() || !snapshot.configured ? TFT_RED : TFT_GREEN);
    snprintf(value, sizeof(value), "0x%02X PN=%u REV=%u", state.regs[0x0B],
             (state.regs[0x0B] >> 3) & 0x0F, state.regs[0x0B] & 0x03);
    drawRow(50, "PART", value);
    formatBattery(value, sizeof(value));
    drawRow(68, "VBAT", value, state.batteryValid ? TFT_CYAN : TFT_ORANGE);
    drawRow(86, "INPUT", vbusName(state.regs[0x08]));
    drawRow(104, "CHARGE", chargeName(state.regs[0x08]));
    snprintf(value, sizeof(value), "PG%d VBUS%d",
             powerGood(state.regs[0x08]), vbusGood(state.regs[0x0A]));
    drawRow(122, "POWER", value);
    snprintf(value, sizeof(value), "V%d I%d", vindpmActive(state.regs[0x0A]),
             iindpmActive(state.regs[0x0A]));
    drawRow(140, "DPM", value,
            (vindpmActive(state.regs[0x0A]) || iindpmActive(state.regs[0x0A])) ? TFT_ORANGE : TFT_GREEN);
    formatCurrentFault(state.regs[0x09], value, sizeof(value));
    drawRow(158, "FAULT", value, faultColor(state.regs[0x09]));
    snprintf(value, sizeof(value), "%s %s", ntcName(ntcZone(state.regs[0x09])),
             ntcRange(ntcZone(state.regs[0x09])));
    drawRow(176, "NTC", value, ntcZone(state.regs[0x09]) == NtcZone::Normal ? TFT_GREEN : TFT_ORANGE);
    snprintf(value, sizeof(value), "VSYS%d DIE%d",
             vsysRegulation(state.regs[0x08]), thermalRegulation(state.regs[0x08]));
    drawRow(194, "REGULATION", value);
    snprintf(value, sizeof(value), "%lus", static_cast<unsigned long>(millis() / 1000));
    drawRow(212, "UPTIME", value);
    snprintf(value, sizeof(value), "%lu/%lu fail=%u", state.i2cSnapshotsOk,
             state.i2cSnapshotsFail, state.consecutiveI2cFail);
    drawRow(230, "I2C", value);
    drawFlagRow(258, "A:auto/freeze  B/C:page", true);
    drawFlagRow(278, "D:clear latch/min/max", true);
    drawFlagRow(298, state.autoPage ? "AUTO PAGE: ON" : "AUTO PAGE: OFF", state.autoPage);
}

void drawStatusRegisters() {
    drawHeader("REG08 / REG09 / REG0A", 1);
    char value[42];
    snprintf(value, sizeof(value), "0x%02X", state.regs[0x08]);
    drawRow(31, "REG08", value, TFT_CYAN);
    drawRow(49, "VBUS_STAT", vbusName(state.regs[0x08]));
    drawRow(67, "CHRG_STAT", chargeName(state.regs[0x08]));
    snprintf(value, sizeof(value), "PG=%d THERM=%d VSYS=%d",
             powerGood(state.regs[0x08]), thermalRegulation(state.regs[0x08]),
             vsysRegulation(state.regs[0x08]));
    drawRow(85, "STATUS", value);

    snprintf(value, sizeof(value), "0x%02X", state.regs[0x09]);
    drawRow(111, "REG09", value, faultColor(state.regs[0x09]));
    snprintf(value, sizeof(value), "WD=%d BOOST=%d BATOVP=%d",
             watchdogFault(state.regs[0x09]), boostFault(state.regs[0x09]),
             batteryOverVoltage(state.regs[0x09]));
    drawRow(129, "FAULTS", value);
    drawRow(147, "CHG_FAULT", chargeFaultName(state.regs[0x09]));
    char ntcBits[4];
    formatBits3(ntcCode(state.regs[0x09]), ntcBits);
    snprintf(value, sizeof(value), "%s (%s) %s", ntcName(ntcZone(state.regs[0x09])),
             ntcBits, ntcRange(ntcZone(state.regs[0x09])));
    drawRow(165, "NTC_FAULT", value);

    snprintf(value, sizeof(value), "0x%02X", state.regs[0x0A]);
    drawRow(191, "REG0A", value, TFT_CYAN);
    snprintf(value, sizeof(value), "VBUS=%d VDPM=%d IDPM=%d",
             vbusGood(state.regs[0x0A]), vindpmActive(state.regs[0x0A]),
             iindpmActive(state.regs[0x0A]));
    drawRow(209, "INPUT", value);
    snprintf(value, sizeof(value), "TOP=%d ACOV=%d", topoffActive(state.regs[0x0A]),
             acovActive(state.regs[0x0A]));
    drawRow(227, "OTHER", value);
    snprintf(value, sizeof(value), "V=%d I=%d", vindpmInterruptMasked(state.regs[0x0A]),
             iindpmInterruptMasked(state.regs[0x0A]));
    drawRow(245, "INT MASK", value);
    snprintf(value, sizeof(value), "0x%02X changes=%u", state.faultLatched,
             state.faultTransitions);
    drawRow(277, "LATCHED", value, state.faultLatched ? TFT_ORANGE : TFT_GREEN);
    drawFlagRow(299, dataStale() ? "STALE DATA" : "LIVE DATA", true, dataStale());
}

void drawThermal() {
    drawHeader("THERMAL / FAULT", 2);
    char value[42];
    const NtcZone zone = ntcZone(state.regs[0x09]);
    drawRow(34, "BATTERY NTC", ntcName(zone), zone == NtcZone::Normal ? TFT_GREEN : TFT_ORANGE);
    drawRow(54, "JEITA RANGE", ntcRange(zone));
    drawFlagRow(80, "NTC is a range, not exact temp", true);
    drawFlagRow(100, "WARM=45..60C, HOT=>60C", true);
    drawFlagRow(120, "THERM_STAT is charger die", true);
    snprintf(value, sizeof(value), "%s", thermalRegulation(state.regs[0x08]) ? "ACTIVE" : "OFF");
    drawRow(150, "DIE REG", value, thermalRegulation(state.regs[0x08]) ? TFT_ORANGE : TFT_GREEN);
    snprintf(value, sizeof(value), "%uC", dieThermalLimitC(state.regs[0x05]));
    drawRow(170, "TREG LIMIT", value);
    snprintf(value, sizeof(value), "%u%% ICHG", coolCurrentPercent(state.regs[0x05]));
    drawRow(190, "COOL JEITA", value);
    snprintf(value, sizeof(value), "%u mV", warmVoltageLimitMv(state.regs[0x07], state.regs[0x04]));
    drawRow(210, "WARM JEITA", value);
    drawRow(230, "CHG FAULT", chargeFaultName(state.regs[0x09]),
            chargeFaultCode(state.regs[0x09]) ? TFT_RED : TFT_GREEN);
    snprintf(value, sizeof(value), "now=%02X latched=%02X", state.regs[0x09], state.faultLatched);
    drawRow(250, "FAULT RAW", value);
    snprintf(value, sizeof(value), "%u", state.faultTransitions);
    drawRow(270, "TRANSITIONS", value);
    drawFlagRow(299, "RT1 fitted: zones meaningful", true);
}

void drawConfiguration() {
    drawHeader("CHARGER CONFIG", 3);
    char value[42];
    snprintf(value, sizeof(value), "%u mA", iindpmMilliamps(state.regs[0x00]));
    drawRow(32, "IINDPM", value);
    snprintf(value, sizeof(value), "%u mA", ichgMilliamps(state.regs[0x02]));
    drawRow(50, "ICHG", value);
    snprintf(value, sizeof(value), "%u / %u mA", prechargeMilliamps(state.regs[0x03]),
             terminationMilliamps(state.regs[0x03]));
    drawRow(68, "PRE / TERM", value);
    snprintf(value, sizeof(value), "%u mV", regulationMillivolts(state.regs[0x04]));
    drawRow(86, "VREG", value);
    snprintf(value, sizeof(value), "%u mV", systemMinimumMillivolts(state.regs[0x01]));
    drawRow(104, "SYS_MIN", value);
    snprintf(value, sizeof(value), "%u mV", vindpmMillivolts(state.regs[0x06]));
    drawRow(122, "VINDPM", value);
    snprintf(value, sizeof(value), "CHG=%d OTG=%d", chargerEnabled(state.regs[0x01]),
             otgEnabled(state.regs[0x01]));
    drawRow(140, "POWER CTRL", value);
    drawRow(158, "WATCHDOG", watchdogDisabled(state.regs[0x05]) ? "DISABLED" : "ENABLED",
            watchdogDisabled(state.regs[0x05]) ? TFT_GREEN : TFT_ORANGE);
    snprintf(value, sizeof(value), "DIS=%d DLY=%d RST=%d",
             (state.regs[0x07] >> 5) & 1, (state.regs[0x07] >> 3) & 1,
             (state.regs[0x07] >> 2) & 1);
    drawRow(176, "BATFET", value);
    snprintf(value, sizeof(value), "I=%u%% V=%umV", coolCurrentPercent(state.regs[0x05]),
             warmVoltageLimitMv(state.regs[0x07], state.regs[0x04]));
    drawRow(194, "JEITA", value);
    drawRow(220, "AUDITOR", sgm41511_snapshot().configured ? "CONFIG MATCH" : "MISMATCH",
            sgm41511_snapshot().configured ? TFT_GREEN : TFT_RED);
    drawFlagRow(252, "Targets: 800mA input", true);
    drawFlagRow(270, "480mA charge, 4.208V", true);
    drawFlagRow(288, "SYS_MIN 3.5V", true);
}

void drawRawAndBoard() {
    drawHeader("RAW / PCB / ADC", 4);
    char text[48];
    screen.setTextFont(1);
    for (uint8_t row = 0; row < 6; ++row) {
        const uint8_t a = row * 2;
        const uint8_t b = a + 1;
        snprintf(text, sizeof(text), "%02X:%02X/%s%02X   %02X:%02X/%s%02X",
                 a, state.regs[a], state.bootRegValid[a] ? "" : "--", state.bootRegs[a],
                 b, state.regs[b], state.bootRegValid[b] ? "" : "--", state.bootRegs[b]);
        screen.setTextColor((state.bootRegValid[a] && state.regs[a] != state.bootRegs[a]) ||
                            (state.bootRegValid[b] && state.regs[b] != state.bootRegs[b]) ?
                            TFT_YELLOW : TFT_WHITE, TFT_BLACK);
        screen.drawString(text, 3, 30 + row * 18);
    }
    snprintf(text, sizeof(text), "ADC%d raw=%u pin=%lumV", VBAT_ADC_PIN, state.adcRaw,
             static_cast<unsigned long>(state.adcPinMv));
    drawRow(147, "ADC", text);
    formatBattery(text, sizeof(text));
    drawRow(167, "VBAT", text, state.batteryValid ? TFT_CYAN : TFT_ORANGE);
    if (state.batteryValid) {
        snprintf(text, sizeof(text), "%lu / %lu mV", state.batteryMinMv, state.batteryMaxMv);
    } else {
        snprintf(text, sizeof(text), "-- / --");
    }
    drawRow(187, "MIN / MAX", text);
    snprintf(text, sizeof(text), "%lu:%lu ohm", static_cast<unsigned long>(VBAT_DIVIDER_TOP_OHM),
             static_cast<unsigned long>(VBAT_DIVIDER_BOTTOM_OHM));
    drawRow(207, "DIVIDER", text);
    snprintf(text, sizeof(text), "SDA=%d SCL=%d recovery=%u", digitalRead(PIN_CHARGER_SDA),
             digitalRead(PIN_CHARGER_SCL), state.busRecoveries);
    drawRow(227, "I2C PINS", text);
    snprintf(text, sizeof(text), "A%d B%d C%d D%d", digitalRead(PIN_BUTTON),
             digitalRead(PIN_BUTTON_B), digitalRead(PIN_BUTTON_C), digitalRead(PIN_ENC_SW));
    drawRow(247, "KEY LEVEL", text);
    drawRow(267, "RESET", resetReasonName(esp_reset_reason()));
    snprintf(text, sizeof(text), "GPIO9=%d heap=%uK", digitalRead(PIN_PWR_KILL),
             ESP.getFreeHeap() / 1024);
    drawRow(287, "BOARD", text, digitalRead(PIN_PWR_KILL) == LOW ? TFT_GREEN : TFT_RED);
}

void render() {
    if (!screenReady) return;
    switch (state.page) {
        case 0: drawOverview(); break;
        case 1: drawStatusRegisters(); break;
        case 2: drawThermal(); break;
        case 3: drawConfiguration(); break;
        default: drawRawAndBoard(); break;
    }
    screen.pushSprite(0, 0);
}

bool pressedEdge(uint8_t pin, bool &previous) {
    const bool pressed = digitalRead(pin) == LOW;
    const bool edge = pressed && !previous;
    previous = pressed;
    return edge;
}

void handleKeys() {
    static bool aWas = false, bWas = false, cWas = false, dWas = false;
    if (pressedEdge(PIN_BUTTON, aWas)) {
        state.autoPage = !state.autoPage;
        state.lastPageMs = millis();
    }
    if (pressedEdge(PIN_BUTTON_B, bWas)) {
        state.page = state.page == 0 ? kPageCount - 1 : state.page - 1;
        state.autoPage = false;
    }
    if (pressedEdge(PIN_BUTTON_C, cWas)) {
        state.page = (state.page + 1) % kPageCount;
        state.autoPage = false;
    }
    if (pressedEdge(PIN_ENC_SW, dWas)) {
        state.faultLatched = state.regs[0x09];
        state.faultTransitions = 0;
        state.batteryMinMv = state.batteryValid ? state.batteryMv : UINT32_MAX;
        state.batteryMaxMv = state.batteryValid ? state.batteryMv : 0;
    }
}

void printSerialSnapshot() {
    static bool headerPrinted = false;
    if (!headerPrinted) {
        Serial.println("CSV,ms,i2c,cfg,reg08,reg09,reg0a,vbus,charge,ntc,ntc_range,pg,therm,vsys,vdpm,idpm,adc_raw,adc_pin_mv,vbat_mv,latched");
        headerPrinted = true;
    }
    char batteryText[16];
    if (state.batteryValid) snprintf(batteryText, sizeof(batteryText), "%lu", state.batteryMv);
    else snprintf(batteryText, sizeof(batteryText), "--");
    Serial.printf("DATA,%lu,%u,%u,%02X,%02X,%02X,%s,%s,%s,%s,%u,%u,%u,%u,%u,%u,%lu,%s,0x%02X\n",
                  static_cast<unsigned long>(millis()), !dataStale(),
                  sgm41511_snapshot().configured, state.regs[0x08], state.regs[0x09],
                  state.regs[0x0A], vbusName(state.regs[0x08]), chargeName(state.regs[0x08]),
                  ntcName(ntcZone(state.regs[0x09])), ntcRange(ntcZone(state.regs[0x09])),
                  powerGood(state.regs[0x08]), thermalRegulation(state.regs[0x08]),
                  vsysRegulation(state.regs[0x08]), vindpmActive(state.regs[0x0A]),
                  iindpmActive(state.regs[0x0A]), state.adcRaw,
                  static_cast<unsigned long>(state.adcPinMv), batteryText, state.faultLatched);
}
}  // namespace

void setup() {
    // V14 invariant: GPIO9 HIGH kills the entire 3.3V rail. Assert LOW before
    // initializing any optional peripheral.
    pinMode(PIN_PWR_KILL, OUTPUT);
    digitalWrite(PIN_PWR_KILL, LOW);
    pinMode(PIN_LCD_BL_LOCAL, OUTPUT);
    digitalWrite(PIN_LCD_BL_LOCAL, LOW);
    pinMode(PIN_LED_DIN, OUTPUT);
    digitalWrite(PIN_LED_DIN, LOW);
    pinMode(PIN_BUZZER, OUTPUT);
    digitalWrite(PIN_BUZZER, LOW);

    pinMode(PIN_BUTTON, INPUT_PULLUP);
    pinMode(PIN_BUTTON_B, INPUT_PULLUP);
    pinMode(PIN_BUTTON_C, INPUT_PULLUP);
    pinMode(PIN_ENC_SW, INPUT_PULLUP);

    Serial.begin(115200);
    Serial.setTxTimeoutMs(0);
    delay(20);
    Serial.println("\n[bringup] V14 SGM41511 LCD power monitor");
    Serial.printf("[board] reset=%s ADC=GPIO%d divider=%lu:%lu enable=GPIO%d\n",
                  resetReasonName(esp_reset_reason()), VBAT_ADC_PIN,
                  static_cast<unsigned long>(VBAT_DIVIDER_TOP_OHM),
                  static_cast<unsigned long>(VBAT_DIVIDER_BOTTOM_OHM), VBAT_ADC_ENABLE_PIN);

    // Capture the power-on values quickly, then immediately apply the safe
    // 480mA/800mA production policy. Never leave the 2.04A POR ICHG active.
    captureBootRegisters();
    const bool chargerReady = sgm41511_begin(PIN_CHARGER_SDA, PIN_CHARGER_SCL);
    Serial.printf("[charger] safe init=%s\n", chargerReady ? "OK" : "FAILED");
    readRegisterBlock(0, sgm41511::kRegisterCount - 1);

#if VBAT_ADC_MONITOR_ENABLED
    pinMode(VBAT_ADC_PIN, INPUT);
    analogReadResolution(12);
    analogSetPinAttenuation(VBAT_ADC_PIN, ADC_11db);
#if VBAT_ADC_ENABLE_PIN >= 0
    pinMode(VBAT_ADC_ENABLE_PIN, OUTPUT);
    digitalWrite(VBAT_ADC_ENABLE_PIN, !VBAT_ADC_ENABLE_LEVEL);
#endif
#endif

    tft.init();
    tft.setRotation(0);
    screen.setColorDepth(16);
    screenReady = screen.createSprite(170, 320) != nullptr;
    if (!screenReady) {
        Serial.println("[display] sprite allocation failed; direct LCD unavailable");
    }
    digitalWrite(PIN_LCD_BL_LOCAL, HIGH);
    state.lastPageMs = millis();
    render();
}

void loop() {
    const uint32_t now = millis();
    sgm41511_tick();  // safety auditor stays active while engineers observe.
    handleKeys();

    if (now - lastStatusPollMs >= kStatusPollMs) {
        lastStatusPollMs = now;
        readRegisterBlock(sgm41511::REG_SYSTEM_STATUS, sgm41511::REG_INPUT_STATUS);
    }
    if (now - lastFullDumpMs >= kFullDumpMs) {
        lastFullDumpMs = now;
        readRegisterBlock(0, sgm41511::kRegisterCount - 1);
    }
    if (now - lastAdcPollMs >= kAdcPollMs) {
        lastAdcPollMs = now;
        sampleBatteryAdc();
    }
    recoverI2cIfNeeded();

    if (state.autoPage && now - state.lastPageMs >= kAutoPageMs) {
        state.page = (state.page + 1) % kPageCount;
        state.lastPageMs = now;
    }
    if (now - lastRenderMs >= kRenderMs) {
        lastRenderMs = now;
        render();
    }
    if (now - lastSerialMs >= kSerialMs) {
        lastSerialMs = now;
        printSerialSnapshot();
    }
    delay(5);
}
