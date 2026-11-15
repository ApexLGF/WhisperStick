// QuickVibeMicStick V14 end-of-line factory test.
// Standalone firmware: automatic electrical checks plus operator-assisted
// display/input/LED/buzzer/microphone verification. It intentionally does not
// implement the product BLE protocol or audio upload path.
#include <Arduino.h>
#include <Adafruit_NeoPixel.h>
#include <NimBLEDevice.h>
#include <Preferences.h>
#include <TFT_eSPI.h>
#include <driver/i2s.h>
#include <esp_system.h>
#include <math.h>

#include "charger_sgm41511.h"
#include "factory_test_policy.h"
#include "pin_config.h"
#include "sgm41511_decode.h"
#include "sgm41511_regs.h"

namespace {

constexpr char kFactoryVersion[] = "1.1";
constexpr char kFactoryNamespace[] = "qvms_fct";
constexpr char kFactoryServiceUuid[] = "19b1f014-e8f2-537e-4f6c-d104768a1214";
constexpr uint8_t kLedCount = 4;
constexpr uint8_t kBuzzerChannel = 2;
constexpr uint32_t kMicBaselineMs = 1800;
constexpr uint32_t kMicVoiceMs = 5000;
constexpr uint32_t kUiRefreshMs = 120;

enum TestId : uint8_t {
    TEST_SYSTEM,
    TEST_CHARGER,
    TEST_USB,
    TEST_BATTERY,
    TEST_NTC,
    TEST_DISPLAY,
    TEST_INPUTS,
    TEST_LED,
    TEST_BUZZER,
    TEST_MICROPHONE,
    TEST_BLE,
    TEST_L3,
    TEST_SHIP,
    TEST_COUNT,
};

enum Result : uint8_t { RESULT_WAIT, RESULT_PASS, RESULT_FAIL };

enum Stage : uint8_t {
    STAGE_DISPLAY,
    STAGE_INPUTS,
    STAGE_LED,
    STAGE_BUZZER,
    STAGE_MIC_BASELINE,
    STAGE_MIC_VOICE,
    STAGE_SUMMARY,
    STAGE_WAIT_L3,
    STAGE_WAIT_SHIP,
};

struct TestRecord {
    const char *name;
    Result result;
    char detail[52];
};

struct Button {
    uint8_t pin;
    bool stableDown;
    bool rawDown;
    uint32_t changedMs;
    bool pressedEdge;
};

TFT_eSPI tft;
Adafruit_NeoPixel strip(kLedCount, PIN_LED_DIN, NEO_GRB + NEO_KHZ800);
TestRecord records[TEST_COUNT] = {
    {"SYSTEM", RESULT_WAIT, ""}, {"CHARGER", RESULT_WAIT, ""},
    {"USB", RESULT_WAIT, ""}, {"BATTERY", RESULT_WAIT, ""},
    {"NTC", RESULT_WAIT, ""}, {"DISPLAY", RESULT_WAIT, ""},
    {"INPUTS", RESULT_WAIT, ""}, {"RGB LED", RESULT_WAIT, ""},
    {"BUZZER", RESULT_WAIT, ""}, {"MIC", RESULT_WAIT, ""},
    {"BLE", RESULT_WAIT, ""}, {"L3 OFF", RESULT_WAIT, ""},
    {"SHIP", RESULT_WAIT, ""},
};

Button buttonA{PIN_BUTTON, false, false, 0, false};
Button buttonB{PIN_BUTTON_B, false, false, 0, false};
Button buttonC{PIN_BUTTON_C, false, false, 0, false};
Button buttonD{PIN_ENC_SW, false, false, 0, false};
Button buttonSide{PIN_SIDE_BUTTON, false, false, 0, false};

Stage stage = STAGE_DISPLAY;
uint32_t stageStartedMs = 0;
uint32_t lastUiMs = 0;
uint32_t batteryMv = 0;
uint16_t batteryPinMv = 0;
char deviceName[28] = "QVMS-V14-FCT";
bool resumeAfterPowerTest = false;
uint8_t resumedPowerTest = 0;
bool microphoneInstalled = false;
uint16_t restoredPassMask = 0;
uint16_t restoredFailMask = 0;
char restoredDetails[TEST_COUNT][52] = {};
bool restoredDetailPresent[TEST_COUNT] = {};

volatile int16_t encoderDelta = 0;
volatile uint8_t encoderState = 0;
volatile int8_t encoderAccum = 0;
volatile uint32_t encoderEdges = 0;
volatile uint32_t encoderCwSteps = 0;
volatile uint32_t encoderCcwSteps = 0;
volatile uint32_t encoderAEdges = 0;
volatile uint32_t encoderBEdges = 0;
constexpr int8_t kEncoderLut[16] = {
    0, -1, +1, 0, +1, 0, 0, -1, -1, 0, 0, +1, 0, +1, -1, 0,
};

bool sawA = false;
bool sawB = false;
bool sawC = false;
bool sawD = false;
bool sawSide = false;
bool sawCw = false;
bool sawCcw = false;
uint32_t inputFailComboStartedMs = 0;
bool powerTestInputArmed = false;

int16_t micBuffer[512];
uint64_t micBaselineSquares = 0;
uint32_t micBaselineSamples = 0;
factory_test::MicrophoneMetrics micMetrics{};

const char *resultName(Result result) {
    return result == RESULT_PASS ? "PASS" : result == RESULT_FAIL ? "FAIL" : "WAIT";
}

uint16_t resultColor(Result result) {
    return result == RESULT_PASS ? TFT_GREEN : result == RESULT_FAIL ? TFT_RED : TFT_YELLOW;
}

void emitEvent(const char *event, const char *detail = "") {
    Serial.printf("FCT_EVENT {\"event\":\"%s\",\"detail\":\"%s\"}\n", event, detail);
}

void setResult(TestId id, Result result, const char *format, ...) {
    records[id].result = result;
    va_list args;
    va_start(args, format);
    vsnprintf(records[id].detail, sizeof(records[id].detail), format, args);
    va_end(args);
    Serial.printf("FCT_RESULT {\"test\":\"%s\",\"result\":\"%s\",\"detail\":\"%s\"}\n",
                  records[id].name, resultName(result), records[id].detail);
}

uint16_t passMask() {
    uint16_t mask = 0;
    for (uint8_t i = 0; i < TEST_COUNT; ++i) {
        if (records[i].result == RESULT_PASS) mask |= static_cast<uint16_t>(1U << i);
    }
    return mask;
}

uint16_t failMask() {
    uint16_t mask = 0;
    for (uint8_t i = 0; i < TEST_COUNT; ++i) {
        if (records[i].result == RESULT_FAIL) mask |= static_cast<uint16_t>(1U << i);
    }
    return mask;
}

void restoreMasks(uint16_t pass, uint16_t fail) {
    for (uint8_t i = 0; i < TEST_COUNT; ++i) {
        if (pass & (1U << i)) records[i].result = RESULT_PASS;
        else if (fail & (1U << i)) records[i].result = RESULT_FAIL;
    }
}

void saveForPowerCycle(uint8_t pending) {
    Preferences preferences;
    if (!preferences.begin(kFactoryNamespace, false)) return;
    preferences.putUShort("pass", passMask());
    preferences.putUShort("fail", failMask());
    preferences.putUChar("pending", pending);
    for (uint8_t i = 0; i < TEST_COUNT; ++i) {
        char key[5];
        snprintf(key, sizeof(key), "d%u", i);
        preferences.putString(key, records[i].detail);
    }
    preferences.end();
}

void clearFactoryProgress() {
    Preferences preferences;
    if (!preferences.begin(kFactoryNamespace, false)) return;
    preferences.clear();
    preferences.end();
}

void loadFactoryProgress() {
    Preferences preferences;
    if (!preferences.begin(kFactoryNamespace, false)) return;
    const uint8_t pending = preferences.getUChar("pending", 0);
    const uint16_t savedPass = preferences.getUShort("pass", 0);
    const uint16_t savedFail = preferences.getUShort("fail", 0);
    const uint16_t completedPowerMask = static_cast<uint16_t>(
        (1U << TEST_L3) | (1U << TEST_SHIP));
    if (pending != 0 || (savedPass & completedPowerMask) == completedPowerMask) {
        resumedPowerTest = pending;
        restoredPassMask = savedPass;
        restoredFailMask = savedFail;
        for (uint8_t i = 0; i < TEST_COUNT; ++i) {
            char key[5];
            snprintf(key, sizeof(key), "d%u", i);
            restoredDetailPresent[i] =
                preferences.getString(key, restoredDetails[i], sizeof(restoredDetails[i])) > 0;
        }
        restoreMasks(restoredPassMask, restoredFailMask);
        if (pending == 1) {
            records[TEST_L3].result = RESULT_PASS;
            snprintf(records[TEST_L3].detail, sizeof(records[TEST_L3].detail), "rail cut + reboot");
            restoredPassMask |= static_cast<uint16_t>(1U << TEST_L3);
            restoredFailMask &= static_cast<uint16_t>(~(1U << TEST_L3));
        } else if (pending == 2) {
            records[TEST_SHIP].result = RESULT_PASS;
            snprintf(records[TEST_SHIP].detail, sizeof(records[TEST_SHIP].detail), "BATFET off + wake");
            restoredPassMask |= static_cast<uint16_t>(1U << TEST_SHIP);
            restoredFailMask &= static_cast<uint16_t>(~(1U << TEST_SHIP));
        }
        preferences.putUShort("pass", restoredPassMask);
        preferences.putUShort("fail", restoredFailMask);
        if (pending == 1 || pending == 2) {
            const uint8_t resultIndex = pending == 1 ? TEST_L3 : TEST_SHIP;
            char key[5];
            snprintf(key, sizeof(key), "d%u", resultIndex);
            preferences.putString(key, records[resultIndex].detail);
        }
        preferences.putUChar("pending", 0);
        resumeAfterPowerTest = true;
    } else {
        preferences.clear();
    }
    preferences.end();
}

void restoreSavedResults() {
    restoreMasks(restoredPassMask, restoredFailMask);
    for (uint8_t i = 0; i < TEST_COUNT; ++i) {
        if (restoredDetailPresent[i]) {
            snprintf(records[i].detail, sizeof(records[i].detail), "%s", restoredDetails[i]);
        } else if ((restoredPassMask | restoredFailMask) & (1U << i)) {
            snprintf(records[i].detail, sizeof(records[i].detail), "restored before power test");
        }
    }
    if (resumedPowerTest == 1) {
        records[TEST_L3].result = RESULT_PASS;
        snprintf(records[TEST_L3].detail, sizeof(records[TEST_L3].detail), "rail cut + reboot");
    } else if (resumedPowerTest == 2 || resumedPowerTest == 0) {
        if (restoredPassMask & (1U << TEST_SHIP)) {
            records[TEST_SHIP].result = RESULT_PASS;
            snprintf(records[TEST_SHIP].detail, sizeof(records[TEST_SHIP].detail), "BATFET off + wake");
        }
    }
}

void emitReport() {
    uint8_t passed = 0;
    uint8_t failed = 0;
    uint8_t waiting = 0;
    for (const TestRecord &record : records) {
        if (record.result == RESULT_PASS) ++passed;
        else if (record.result == RESULT_FAIL) ++failed;
        else ++waiting;
    }
    Serial.printf("FCT_REPORT {\"schema\":1,\"factory_fw\":\"%s\",\"board\":\"V14\","
                  "\"device\":\"%s\",\"passed\":%u,\"failed\":%u,\"waiting\":%u,"
                  "\"battery_mv\":%lu,\"tests\":[",
                  kFactoryVersion, deviceName, passed, failed, waiting,
                  static_cast<unsigned long>(batteryMv));
    for (uint8_t i = 0; i < TEST_COUNT; ++i) {
        if (i) Serial.print(',');
        Serial.printf("{\"name\":\"%s\",\"result\":\"%s\",\"detail\":\"%s\"}",
                      records[i].name, resultName(records[i].result), records[i].detail);
    }
    Serial.println("]}");
}

void IRAM_ATTR onEncoderChange() {
    // Keep this decoder identical to the V14 production firmware. Both GPIOs
    // deliberately share one callback so every transition is evaluated from
    // the same previous A/B state.
    const uint8_t next = static_cast<uint8_t>((digitalRead(PIN_ENC_A) ? 1 : 0) |
                                               (digitalRead(PIN_ENC_B) ? 2 : 0));
    const uint8_t changed = encoderState ^ next;
    if (changed & 0x01) ++encoderAEdges;
    if (changed & 0x02) ++encoderBEdges;
    const int8_t step = kEncoderLut[(encoderState << 2) | next];
    encoderState = next;
    if (step == 0) return;
    ++encoderEdges;
    encoderAccum += step;
    if (encoderAccum >= 4) {
        ++encoderDelta;
        ++encoderCcwSteps;  // ENC_INVERT=1 in production: raw + is physical CCW.
        encoderAccum = 0;
    } else if (encoderAccum <= -4) {
        --encoderDelta;
        ++encoderCwSteps;
        encoderAccum = 0;
    }
}

void updateButton(Button &button) {
    button.pressedEdge = false;
    const bool raw = digitalRead(button.pin) == LOW;
    if (raw != button.rawDown) {
        button.rawDown = raw;
        button.changedMs = millis();
    }
    if (raw != button.stableDown && millis() - button.changedMs >= 25) {
        button.stableDown = raw;
        button.pressedEdge = raw;
    }
}

void updateInputs() {
    updateButton(buttonA);
    updateButton(buttonB);
    updateButton(buttonC);
    updateButton(buttonD);
    updateButton(buttonSide);
}

void title(const char *text, uint16_t color = TFT_CYAN) {
    tft.fillScreen(TFT_BLACK);
    tft.setTextDatum(TC_DATUM);
    tft.setTextFont(2);
    tft.setTextColor(color, TFT_BLACK);
    tft.drawString(text, tft.width() / 2, 8);
    tft.drawFastHLine(5, 30, tft.width() - 10, TFT_DARKGREY);
}

void line(int y, const char *left, const char *right, uint16_t color = TFT_WHITE) {
    tft.setTextFont(2);
    tft.setTextDatum(TL_DATUM);
    tft.setTextColor(TFT_LIGHTGREY, TFT_BLACK);
    tft.drawString(left, 7, y);
    tft.setTextDatum(TR_DATUM);
    tft.setTextColor(color, TFT_BLACK);
    tft.drawString(right, tft.width() - 7, y);
}

void footer(const char *text) {
    tft.fillRect(0, 290, tft.width(), 30, TFT_DARKGREY);
    tft.setTextDatum(MC_DATUM);
    tft.setTextFont(2);
    tft.setTextColor(TFT_WHITE, TFT_DARKGREY);
    tft.drawString(text, tft.width() / 2, 305);
}

void enterStage(Stage next) {
    stage = next;
    stageStartedMs = millis();
    lastUiMs = 0;
    if (next == STAGE_WAIT_L3 || next == STAGE_WAIT_SHIP) powerTestInputArmed = false;
    if (next == STAGE_INPUTS) {
        sawA = sawB = sawC = sawD = sawSide = sawCw = sawCcw = false;
        // Rebind after LCD/charger/BLE initialization. This mirrors the
        // production decoder but also prevents any peripheral bring-up from
        // leaving either encoder GPIO or its interrupt in a changed state.
        detachInterrupt(digitalPinToInterrupt(PIN_ENC_A));
        detachInterrupt(digitalPinToInterrupt(PIN_ENC_B));
        pinMode(PIN_ENC_A, INPUT_PULLUP);
        pinMode(PIN_ENC_B, INPUT_PULLUP);
        noInterrupts();
        encoderDelta = 0;
        encoderAccum = 0;
        encoderState = static_cast<uint8_t>((digitalRead(PIN_ENC_A) ? 1 : 0) |
                                            (digitalRead(PIN_ENC_B) ? 2 : 0));
        encoderEdges = 0;
        encoderCwSteps = 0;
        encoderCcwSteps = 0;
        encoderAEdges = 0;
        encoderBEdges = 0;
        inputFailComboStartedMs = 0;
        interrupts();
        attachInterrupt(digitalPinToInterrupt(PIN_ENC_A), onEncoderChange, CHANGE);
        attachInterrupt(digitalPinToInterrupt(PIN_ENC_B), onEncoderChange, CHANGE);
    }
    emitEvent("STAGE", records[next == STAGE_DISPLAY ? TEST_DISPLAY :
                                next == STAGE_INPUTS ? TEST_INPUTS :
                                next == STAGE_LED ? TEST_LED :
                                next == STAGE_BUZZER ? TEST_BUZZER :
                                next == STAGE_MIC_BASELINE || next == STAGE_MIC_VOICE ? TEST_MICROPHONE :
                                next == STAGE_WAIT_L3 ? TEST_L3 :
                                next == STAGE_WAIT_SHIP ? TEST_SHIP : TEST_SYSTEM].name);
}

uint32_t readBatteryMillivolts() {
    constexpr uint8_t kSamples = 9;
    uint16_t values[kSamples];
    for (uint8_t i = 0; i < kSamples; ++i) {
        values[i] = static_cast<uint16_t>(analogReadMilliVolts(PIN_BAT_VOLT_LOCAL));
        delayMicroseconds(250);
    }
    for (uint8_t i = 1; i < kSamples; ++i) {
        const uint16_t value = values[i];
        uint8_t j = i;
        while (j > 0 && values[j - 1] > value) {
            values[j] = values[j - 1];
            --j;
        }
        values[j] = value;
    }
    batteryPinMv = values[kSamples / 2];
    return sgm41511_diag::restoreDividerMillivolts(
        batteryPinMv, BATTERY_DIVIDER_TOP_OHM, BATTERY_DIVIDER_BOTTOM_OHM);
}

void runAutomaticChecks() {
    const uint32_t psram = ESP.getPsramSize();
    const uint32_t flash = ESP.getFlashChipSize();
    const bool systemOk = psram >= factory_test::kMinimumPsramBytes &&
                          flash >= factory_test::kMinimumFlashBytes;
    setResult(TEST_SYSTEM, systemOk ? RESULT_PASS : RESULT_FAIL, "flash=%luM psram=%luM",
              static_cast<unsigned long>(flash / 1024 / 1024),
              static_cast<unsigned long>(psram / 1024 / 1024));

    const bool chargerStarted = sgm41511_begin(PIN_CHARGER_SDA, PIN_CHARGER_SCL);
    delay(40);
    sgm41511_tick();
    const Sgm41511Snapshot &snapshot = sgm41511_snapshot();
    setResult(TEST_CHARGER,
              chargerStarted && snapshot.reachable && snapshot.configured ? RESULT_PASS : RESULT_FAIL,
              "id=%02X r08=%02X r09=%02X r0a=%02X", snapshot.partInfo,
              snapshot.reg08SystemStatus, snapshot.reg09FaultStatus, snapshot.reg0aInputStatus);
    setResult(TEST_USB, snapshot.vbusGood && snapshot.powerGood ? RESULT_PASS : RESULT_FAIL,
              "VBUS=%u PG=%u", snapshot.vbusGood, snapshot.powerGood);

    analogReadResolution(12);
    analogSetPinAttenuation(PIN_BAT_VOLT_LOCAL, ADC_11db);
    delay(BATTERY_ADC_SETTLE_MS);
    batteryMv = readBatteryMillivolts();
    const bool batteryOk = factory_test::batteryVoltagePass(
        sgm41511_diag::plausibleBatteryMillivolts(batteryMv), batteryMv);
    setResult(TEST_BATTERY, batteryOk ? RESULT_PASS : RESULT_FAIL, "pin=%umV bat=%lumV",
              batteryPinMv, static_cast<unsigned long>(batteryMv));

    const uint8_t ntcCode = sgm41511_diag::ntcCode(snapshot.reg09FaultStatus);
    const sgm41511_diag::NtcZone ntcZone = sgm41511_diag::ntcZone(snapshot.reg09FaultStatus);
    setResult(TEST_NTC, factory_test::roomTemperatureNtcPass(ntcCode) ? RESULT_PASS : RESULT_FAIL,
              "%s code=%u", sgm41511_diag::ntcName(ntcZone), ntcCode);
}

void startBleSelfTest() {
    NimBLEDevice::init(deviceName);
    NimBLEAdvertising *advertising = NimBLEDevice::getAdvertising();
    advertising->enableScanResponse(true);
    advertising->setName(deviceName);
    advertising->addServiceUUID(kFactoryServiceUuid);
    advertising->setMinInterval(160);
    advertising->setMaxInterval(240);
    const bool started = advertising->start();
    setResult(TEST_BLE, started && advertising->isAdvertising() ? RESULT_PASS : RESULT_FAIL,
              "advertising=%u name=%s", advertising->isAdvertising(), deviceName);
}

void drawDisplayPattern() {
    tft.fillScreen(TFT_BLACK);
    const int band = 72;
    tft.fillRect(0, 0, tft.width(), band, TFT_RED);
    tft.fillRect(0, band, tft.width(), band, TFT_GREEN);
    tft.fillRect(0, band * 2, tft.width(), band, TFT_BLUE);
    for (int x = 0; x < tft.width(); x += 10) {
        if ((x / 10) & 1) tft.fillRect(x, band * 3, 10, 34, TFT_WHITE);
    }
    tft.drawRect(0, 0, tft.width(), tft.height(), TFT_YELLOW);
    tft.setTextDatum(MC_DATUM);
    tft.setTextFont(2);
    tft.setTextColor(TFT_WHITE, TFT_BLACK);
    tft.fillRect(0, 250, tft.width(), 40, TFT_BLACK);
    tft.drawString("V14 LCD: color / edge", tft.width() / 2, 260);
    footer("A PASS   C FAIL");
}

void drawInputPage() {
    title("V14 INPUT TEST");
    line(42, "A key", sawA ? "OK" : "WAIT", sawA ? TFT_GREEN : TFT_YELLOW);
    line(68, "B key", sawB ? "OK" : "WAIT", sawB ? TFT_GREEN : TFT_YELLOW);
    line(94, "C key", sawC ? "OK" : "WAIT", sawC ? TFT_GREEN : TFT_YELLOW);
    line(120, "D press", sawD ? "OK" : "WAIT", sawD ? TFT_GREEN : TFT_YELLOW);
    line(146, "Side SW1", sawSide ? "OK" : "WAIT", sawSide ? TFT_GREEN : TFT_YELLOW);
    line(172, "Encoder CW", sawCw ? "OK" : "WAIT", sawCw ? TFT_GREEN : TFT_YELLOW);
    line(198, "Encoder CCW", sawCcw ? "OK" : "WAIT", sawCcw ? TFT_GREEN : TFT_YELLOW);
    char detail[44];
    noInterrupts();
    const uint32_t aEdges = encoderAEdges;
    const uint32_t bEdges = encoderBEdges;
    const uint32_t cwSteps = encoderCwSteps;
    const uint32_t ccwSteps = encoderCcwSteps;
    interrupts();
    snprintf(detail, sizeof(detail), "CW%lu CCW%lu AF%lu BF%lu",
             static_cast<unsigned long>(cwSteps), static_cast<unsigned long>(ccwSteps),
             static_cast<unsigned long>(aEdges), static_cast<unsigned long>(bEdges));
    line(230, "Raw encoder", detail, TFT_CYAN);
    footer("Complete all / hold B+C FAIL");
}

void setAllLeds(uint8_t red, uint8_t green, uint8_t blue) {
    for (uint8_t i = 0; i < kLedCount; ++i) strip.setPixelColor(i, strip.Color(red, green, blue));
    strip.show();
}

void drawManualPage(const char *heading, const char *instruction, const char *detail) {
    title(heading);
    tft.setTextDatum(MC_DATUM);
    tft.setTextFont(2);
    tft.setTextColor(TFT_WHITE, TFT_BLACK);
    tft.drawString(instruction, tft.width() / 2, 100);
    tft.setTextColor(TFT_CYAN, TFT_BLACK);
    tft.drawString(detail, tft.width() / 2, 145);
    footer("A PASS   C FAIL");
}

void buzzerOn(uint16_t frequency) {
    ledcWriteTone(kBuzzerChannel, frequency);
    ledcWrite(kBuzzerChannel, 72);
}

void buzzerOff() {
    ledcWrite(kBuzzerChannel, 0);
    ledcWriteTone(kBuzzerChannel, 0);
}

bool installMicrophone() {
    if (microphoneInstalled) return true;
    i2s_config_t config = {
        .mode = static_cast<i2s_mode_t>(I2S_MODE_MASTER | I2S_MODE_RX | I2S_MODE_PDM),
        .sample_rate = 16000,
        .bits_per_sample = I2S_BITS_PER_SAMPLE_16BIT,
        .channel_format = I2S_CHANNEL_FMT_ONLY_LEFT,
        .communication_format = static_cast<i2s_comm_format_t>(I2S_COMM_FORMAT_STAND_I2S),
        .intr_alloc_flags = ESP_INTR_FLAG_LEVEL1,
        .dma_buf_count = 8,
        .dma_buf_len = 256,
        .use_apll = false,
    };
    i2s_pin_config_t pins = {
        .mck_io_num = I2S_PIN_NO_CHANGE,
        .bck_io_num = I2S_PIN_NO_CHANGE,
        .ws_io_num = PIN_PDM_CLK,
        .data_out_num = I2S_PIN_NO_CHANGE,
        .data_in_num = PIN_PDM_DATA,
    };
    if (i2s_driver_install(I2S_NUM_0, &config, 0, nullptr) != ESP_OK) return false;
    if (i2s_set_pin(I2S_NUM_0, &pins) != ESP_OK) return false;
    if (i2s_set_pdm_rx_down_sample(I2S_NUM_0, I2S_PDM_DSR_16S) != ESP_OK) return false;
    microphoneInstalled = true;
    return true;
}

void sampleMicrophone(bool baseline) {
    size_t bytesRead = 0;
    if (i2s_read(I2S_NUM_0, micBuffer, sizeof(micBuffer), &bytesRead, pdMS_TO_TICKS(80)) != ESP_OK) return;
    const uint32_t count = bytesRead / sizeof(int16_t);
    if (count == 0) return;
    const factory_test::MicrophoneBlock acoustic =
        factory_test::analyzeMicrophoneBlock(micBuffer, count);
    uint32_t zeros = 0;
    uint32_t clipped = 0;
    for (uint32_t i = 0; i < count; ++i) {
        const int32_t sample = micBuffer[i];
        const uint32_t absolute = static_cast<uint32_t>(sample < 0 ? -sample : sample);
        if (sample == 0) ++zeros;
        if (absolute >= 32760) ++clipped;
    }
    const uint32_t blockRms = static_cast<uint32_t>(
        sqrt(static_cast<double>(acoustic.centeredSquares) / count));
    if (baseline) {
        micBaselineSquares += acoustic.centeredSquares;
        micBaselineSamples += count;
    } else {
        micMetrics.samples += count;
        micMetrics.zeroSamples += zeros;
        micMetrics.clippedSamples += clipped;
        if (blockRms > micMetrics.maximumRms) micMetrics.maximumRms = blockRms;
        if (acoustic.centeredPeak > micMetrics.peak) micMetrics.peak = acoustic.centeredPeak;
    }
}

void drawMicPage(bool voice) {
    title(voice ? "MIC: SPEAK NOW" : "MIC: KEEP QUIET");
    const uint32_t elapsed = millis() - stageStartedMs;
    const uint32_t duration = voice ? kMicVoiceMs : kMicBaselineMs;
    const uint32_t remaining = elapsed >= duration ? 0 : (duration - elapsed + 999) / 1000;
    char value[32];
    snprintf(value, sizeof(value), "%lus", static_cast<unsigned long>(remaining));
    line(65, "Remaining", value, TFT_YELLOW);
    snprintf(value, sizeof(value), "%lu", static_cast<unsigned long>(micMetrics.maximumRms));
    line(105, "Max RMS", value, TFT_CYAN);
    snprintf(value, sizeof(value), "%lu", static_cast<unsigned long>(micMetrics.peak));
    line(145, "Peak", value, TFT_CYAN);
    footer(voice ? "Speak / tap near microphone" : "Measure ambient baseline");
}

void finishMicrophoneTest() {
    micMetrics.baselineRms = micBaselineSamples == 0 ? 0 :
        static_cast<uint32_t>(sqrt(static_cast<double>(micBaselineSquares) / micBaselineSamples));
    const bool passed = factory_test::microphonePass(micMetrics);
    setResult(TEST_MICROPHONE, passed ? RESULT_PASS : RESULT_FAIL,
              "base=%lu max=%lu peak=%lu zero=%lu/%lu clip=%lu",
              static_cast<unsigned long>(micMetrics.baselineRms),
              static_cast<unsigned long>(micMetrics.maximumRms),
              static_cast<unsigned long>(micMetrics.peak),
              static_cast<unsigned long>(micMetrics.zeroSamples),
              static_cast<unsigned long>(micMetrics.samples),
              static_cast<unsigned long>(micMetrics.clippedSamples));
    enterStage(STAGE_SUMMARY);
}

void beginMicrophoneRetest() {
    if (!installMicrophone()) {
        setResult(TEST_MICROPHONE, RESULT_FAIL, "I2S/PDM init failed");
        enterStage(STAGE_SUMMARY);
        return;
    }
    micBaselineSquares = 0;
    micBaselineSamples = 0;
    micMetrics = {};
    records[TEST_MICROPHONE].result = RESULT_WAIT;
    records[TEST_MICROPHONE].detail[0] = '\0';
    enterStage(STAGE_MIC_BASELINE);
    drawMicPage(false);
    emitEvent("MIC_RETEST", "keep quiet then speak");
}

void drawSummary() {
    title("V14 FACTORY SUMMARY");
    uint8_t passed = 0;
    uint8_t failed = 0;
    uint8_t waiting = 0;
    for (const TestRecord &record : records) {
        if (record.result == RESULT_PASS) ++passed;
        else if (record.result == RESULT_FAIL) ++failed;
        else ++waiting;
    }
    char counts[42];
    snprintf(counts, sizeof(counts), "PASS %u  FAIL %u  WAIT %u", passed, failed, waiting);
    tft.setTextDatum(MC_DATUM);
    tft.setTextFont(2);
    tft.setTextColor(failed ? TFT_RED : TFT_GREEN, TFT_BLACK);
    tft.drawString(counts, tft.width() / 2, 48);
    int y = 78;
    for (uint8_t i = 0; i < TEST_COUNT; ++i) {
        if (i == TEST_L3 || i == TEST_SHIP || records[i].result == RESULT_FAIL) {
            line(y, records[i].name, resultName(records[i].result), resultColor(records[i].result));
            y += 24;
        }
    }
    if (records[TEST_L3].result == RESULT_WAIT) footer("A START POWER TEST");
    else if (records[TEST_SHIP].result == RESULT_WAIT) footer("A START SHIP TEST");
    else footer("POWER TESTS COMPLETE");
}

void drawPowerInstruction(bool ship) {
    title(ship ? "SHIP MODE TEST" : "L3 RAIL-OFF TEST", TFT_YELLOW);
    tft.setTextDatum(MC_DATUM);
    tft.setTextFont(2);
    tft.setTextColor(TFT_WHITE, TFT_BLACK);
    tft.drawString("1. Unplug USB", tft.width() / 2, 70);
    tft.drawString("2. Wait VBUS OFF", tft.width() / 2, 105);
    tft.drawString("3. Press A", tft.width() / 2, 140);
    tft.setTextColor(TFT_CYAN, TFT_BLACK);
    tft.drawString(ship ? "Wake: SW1/USB" : "Wake: any key", tft.width() / 2, 195);
    footer("C CANCEL");
}

void beginL3Test() {
    saveForPowerCycle(1);
    emitEvent("L3_POWER_CUT", "GPIO9 HIGH");
    delay(30);
    digitalWrite(PIN_PWR_KILL, HIGH);
    while (true) delay(1000);
}

void beginShipTest() {
    if (!sgm41511_prepare_ship_mode()) {
        setResult(TEST_SHIP, RESULT_FAIL, "prepare/verify failed");
        enterStage(STAGE_SUMMARY);
        return;
    }
    saveForPowerCycle(2);
    emitEvent("SHIP_COMMIT", "BATFET_DIS");
    delay(30);
    if (!sgm41511_commit_ship_mode()) {
        saveForPowerCycle(0);
        setResult(TEST_SHIP, RESULT_FAIL, "commit failed");
        enterStage(STAGE_SUMMARY);
        return;
    }
    while (true) delay(1000);
}

void handleSerialCommand(const String &command) {
    if (command == "REPORT") {
        emitReport();
    } else if (command == "L3") {
        enterStage(STAGE_WAIT_L3);
        drawPowerInstruction(false);
        emitEvent("L3_ARMED", "unplug USB then press A");
    } else if (command == "SHIP") {
        enterStage(STAGE_WAIT_SHIP);
        drawPowerInstruction(true);
        emitEvent("SHIP_ARMED", "unplug USB then press A");
    } else if (command == "MIC") {
        beginMicrophoneRetest();
    } else if (command == "RESET") {
        clearFactoryProgress();
        ESP.restart();
    } else if (command == "PING") {
        emitEvent("PONG", deviceName);
    } else if (command.length()) {
        emitEvent("UNKNOWN_COMMAND", command.c_str());
    }
}

void pollSerial() {
    static String command;
    while (Serial.available()) {
        const char character = static_cast<char>(Serial.read());
        if (character == '\n' || character == '\r') {
            command.trim();
            if (command.length()) handleSerialCommand(command);
            command = "";
        } else if (command.length() < 63) {
            command += character;
        }
    }
}

void advanceManual(TestId id, Stage next) {
    if (buttonA.pressedEdge) {
        setResult(id, RESULT_PASS, "operator confirmed");
        enterStage(next);
    } else if (buttonC.pressedEdge) {
        setResult(id, RESULT_FAIL, "operator rejected");
        enterStage(next);
    }
}

}  // namespace

void setup() {
    pinMode(PIN_PWR_KILL, OUTPUT);
    digitalWrite(PIN_PWR_KILL, LOW);
    pinMode(PIN_LCD_BL_LOCAL, OUTPUT);
    digitalWrite(PIN_LCD_BL_LOCAL, LOW);
    pinMode(PIN_LED_DIN, OUTPUT);
    digitalWrite(PIN_LED_DIN, LOW);
    pinMode(PIN_BUZZER, OUTPUT);
    digitalWrite(PIN_BUZZER, LOW);

    Serial.begin(115200);
    Serial.setTxTimeoutMs(0);
    delay(40);

    uint8_t mac[6];
    esp_efuse_mac_get_default(mac);
    snprintf(deviceName, sizeof(deviceName), "QVMS-V14-FCT-%02X%02X", mac[4], mac[5]);
    Serial.printf("\nFCT_BOOT {\"factory_fw\":\"%s\",\"board\":\"V14\",\"device\":\"%s\"}\n",
                  kFactoryVersion, deviceName);

    loadFactoryProgress();

    pinMode(PIN_BUTTON, INPUT_PULLUP);
    pinMode(PIN_BUTTON_B, INPUT_PULLUP);
    pinMode(PIN_BUTTON_C, INPUT_PULLUP);
    pinMode(PIN_ENC_A, INPUT_PULLUP);
    pinMode(PIN_ENC_B, INPUT_PULLUP);
    pinMode(PIN_ENC_SW, INPUT_PULLUP);
    pinMode(PIN_SIDE_BUTTON, INPUT_PULLUP);
    encoderState = static_cast<uint8_t>((digitalRead(PIN_ENC_A) ? 1 : 0) |
                                        (digitalRead(PIN_ENC_B) ? 2 : 0));
    attachInterrupt(digitalPinToInterrupt(PIN_ENC_A), onEncoderChange, CHANGE);
    attachInterrupt(digitalPinToInterrupt(PIN_ENC_B), onEncoderChange, CHANGE);

    ledcSetup(kBuzzerChannel, 2000, 8);
    ledcAttachPin(PIN_BUZZER, kBuzzerChannel);
    buzzerOff();
    strip.begin();
    strip.setBrightness(48);
    strip.clear();
    strip.show();

    tft.init();
    tft.setRotation(0);
    digitalWrite(PIN_LCD_BL_LOCAL, HIGH);
    title("V14 FACTORY TEST");
    footer("Running automatic checks");

    runAutomaticChecks();
    startBleSelfTest();
    if (resumeAfterPowerTest) {
        // USB may still be unplugged when L3 wakes from a key. Preserve the
        // complete pre-power-test verdict instead of turning that expected
        // transition into a false USB/manual-test failure.
        restoreSavedResults();
    }
    emitReport();

    if (resumeAfterPowerTest) {
        if (resumedPowerTest == 1 && records[TEST_SHIP].result == RESULT_WAIT) {
            enterStage(STAGE_WAIT_SHIP);
            drawPowerInstruction(true);
            emitEvent("SHIP_ARMED", "L3 passed; continue without reconnecting USB");
        } else {
            enterStage(STAGE_SUMMARY);
            drawSummary();
            emitEvent("POWER_TEST_RESUMED", "power sequence complete");
        }
    } else {
        enterStage(STAGE_DISPLAY);
        drawDisplayPattern();
    }
}

void loop() {
    pollSerial();
    updateInputs();
    sgm41511_tick();

    switch (stage) {
        case STAGE_DISPLAY:
            advanceManual(TEST_DISPLAY, STAGE_INPUTS);
            if (stage == STAGE_INPUTS) drawInputPage();
            break;

        case STAGE_INPUTS: {
            if (buttonA.pressedEdge) sawA = true;
            if (buttonB.pressedEdge) sawB = true;
            if (buttonC.pressedEdge) sawC = true;
            if (buttonD.pressedEdge) sawD = true;
            if (buttonSide.pressedEdge) sawSide = true;
            noInterrupts();
            const int16_t delta = encoderDelta;
            encoderDelta = 0;
            interrupts();
            if (delta > 0) sawCw = true;
            if (delta < 0) sawCcw = true;
            if (buttonB.stableDown && buttonC.stableDown) {
                if (inputFailComboStartedMs == 0) inputFailComboStartedMs = millis();
                if (millis() - inputFailComboStartedMs >= 1000) {
                    setResult(TEST_INPUTS, RESULT_FAIL,
                              "abort A%u B%u C%u D%u S%u CW%u CCW%u",
                              sawA, sawB, sawC, sawD, sawSide, sawCw, sawCcw);
                    enterStage(STAGE_LED);
                    drawManualPage("RGB LED TEST", "Check all 4 LEDs", "R / G / B / WHITE");
                    break;
                }
            } else {
                inputFailComboStartedMs = 0;
            }
            if (millis() - lastUiMs >= kUiRefreshMs) {
                lastUiMs = millis();
                drawInputPage();
            }
            if (sawA && sawB && sawC && sawD && sawSide && sawCw && sawCcw) {
                setResult(TEST_INPUTS, RESULT_PASS, "A B C D SW1 CW CCW edges=%lu",
                          static_cast<unsigned long>(encoderEdges));
                enterStage(STAGE_LED);
                drawManualPage("RGB LED TEST", "Check all 4 LEDs", "R / G / B / WHITE");
            }
            break;
        }

        case STAGE_LED: {
            const uint8_t phase = static_cast<uint8_t>(((millis() - stageStartedMs) / 700) % 4);
            if (phase == 0) setAllLeds(180, 0, 0);
            else if (phase == 1) setAllLeds(0, 180, 0);
            else if (phase == 2) setAllLeds(0, 0, 180);
            else setAllLeds(100, 100, 100);
            if (buttonA.pressedEdge || buttonC.pressedEdge) {
                setAllLeds(0, 0, 0);
                advanceManual(TEST_LED, STAGE_BUZZER);
                if (stage == STAGE_BUZZER) drawManualPage("BUZZER TEST", "Listen for 3 tones", "1k / 2k / 3k Hz");
            }
            break;
        }

        case STAGE_BUZZER: {
            const uint32_t phase = (millis() - stageStartedMs) % 2400;
            if (phase < 350) buzzerOn(1000);
            else if (phase < 700) buzzerOff();
            else if (phase < 1050) buzzerOn(2000);
            else if (phase < 1400) buzzerOff();
            else if (phase < 1750) buzzerOn(3000);
            else buzzerOff();
            if (buttonA.pressedEdge || buttonC.pressedEdge) {
                buzzerOff();
                const bool passed = buttonA.pressedEdge;
                setResult(TEST_BUZZER, passed ? RESULT_PASS : RESULT_FAIL,
                          passed ? "operator confirmed" : "operator rejected");
                if (!installMicrophone()) {
                    setResult(TEST_MICROPHONE, RESULT_FAIL, "I2S/PDM init failed");
                    enterStage(STAGE_SUMMARY);
                    drawSummary();
                } else {
                    micBaselineSquares = 0;
                    micBaselineSamples = 0;
                    micMetrics = {};
                    enterStage(STAGE_MIC_BASELINE);
                    drawMicPage(false);
                }
            }
            break;
        }

        case STAGE_MIC_BASELINE:
            sampleMicrophone(true);
            if (millis() - lastUiMs >= kUiRefreshMs) {
                lastUiMs = millis();
                drawMicPage(false);
            }
            if (millis() - stageStartedMs >= kMicBaselineMs) {
                enterStage(STAGE_MIC_VOICE);
                drawMicPage(true);
            }
            break;

        case STAGE_MIC_VOICE:
            sampleMicrophone(false);
            if (millis() - lastUiMs >= kUiRefreshMs) {
                lastUiMs = millis();
                drawMicPage(true);
            }
            if (millis() - stageStartedMs >= kMicVoiceMs) {
                finishMicrophoneTest();
                drawSummary();
                emitReport();
                emitEvent("SUMMARY", "non-destructive tests complete");
            }
            break;

        case STAGE_SUMMARY:
            if (buttonA.pressedEdge) {
                if (records[TEST_L3].result == RESULT_WAIT) {
                    enterStage(STAGE_WAIT_L3);
                    drawPowerInstruction(false);
                    emitEvent("L3_ARMED", "unplug USB then press A");
                    break;
                }
                if (records[TEST_SHIP].result == RESULT_WAIT) {
                    enterStage(STAGE_WAIT_SHIP);
                    drawPowerInstruction(true);
                    emitEvent("SHIP_ARMED", "unplug USB then press A");
                    break;
                }
            }
            if (millis() - lastUiMs >= 1000) {
                lastUiMs = millis();
                drawSummary();
            }
            break;

        case STAGE_WAIT_L3:
            if (!powerTestInputArmed) {
                if (millis() - stageStartedMs >= 500 &&
                    !buttonA.stableDown && !buttonC.stableDown) powerTestInputArmed = true;
                break;
            }
            if (buttonC.pressedEdge) {
                enterStage(STAGE_SUMMARY);
                drawSummary();
            } else if (buttonA.pressedEdge) {
                if (sgm41511_snapshot().vbusGood) {
                    emitEvent("L3_BLOCKED", "USB still connected");
                    drawPowerInstruction(false);
                } else {
                    beginL3Test();
                }
            }
            break;

        case STAGE_WAIT_SHIP:
            if (!powerTestInputArmed) {
                if (millis() - stageStartedMs >= 500 &&
                    !buttonA.stableDown && !buttonC.stableDown) powerTestInputArmed = true;
                break;
            }
            if (buttonC.pressedEdge) {
                enterStage(STAGE_SUMMARY);
                drawSummary();
            } else if (buttonA.pressedEdge) {
                if (sgm41511_snapshot().vbusGood) {
                    emitEvent("SHIP_BLOCKED", "USB still connected");
                    drawPowerInstruction(true);
                } else {
                    beginShipTest();
                }
            }
            break;
    }

    delay(5);
}
