// power_manager.cpp — REQ-003 Phase 1/2 (0.5.3)
// 见 power_manager.h 头注释。
//
// 关键决策:
//   - 背光 PWM:ESP32 LEDC (8-bit, 5kHz),duty 0-255;ACTIVE=120 IDLE=60 DIM=15 OFF=0
//   - USB 检测:PIN_BAT_VOLT (GPIO 4) ADC 分压 >4300mV 视为 USB
//   - 超时阈值:10s→IDLE / 30s→DIM / 60s→OFF(deep sleep 已废,改靠主 loop
//     setCpuFrequencyMhz(80) + BLE conn 100ms + ST7789 SLPIN)
//   - 进 OFF 真断屏:ledcDetachPin(38) + GPIO 38 LOW 兜底(ledcWrite(0) 在 S3 不可靠);
//     GPIO 15 全程保持 HIGH(LOW 让 IC 信号悬空反而更耗电)

#include "power_manager.h"

#include <Arduino.h>
#include <esp_adc_cal.h>

// 引脚按目标板分流(面包板 BL=38/BAT=4;v10 BL=21/BAT=7),见 pin_config.h
// 注:本文件下方注释/日志里出现的 "GPIO 4/15/38"、"ADC1_CH3" 等是面包板脚位历史记录;
//     实际引脚一律以 pin_config.h 的宏为准(随 -DBOARD_V10 自动取 v10 值)。
#include "pin_config.h"
#include "buzzer_fx.h"   // REQ-022:唤醒重建段同批重建蜂鸣器 LEDC 通道
#include "led_manager.h"
#include "power_disconnect_policy.h"
#ifdef BOARD_MICSTICK_V14
#include "charger_sgm41511.h"
#include "sgm41511_decode.h"
#include "battery_power_policy.h"
#endif

// LEDC 通道 / 频率 / 分辨率
#define BL_LEDC_CHANNEL  0
#define BL_LEDC_FREQ_HZ  5000
#define BL_LEDC_RES_BITS 8

// 4 级亮度 (0..255)
// v10 背光串了 R_LCD_BL_LIMIT 33Ω 限流(BUG-017),同 duty 比面包板暗 → 整体上调
#ifdef BOARD_V10
// 暂:v10 背光偏暗排查中,idle/dim 也设满,确认是否状态机/PWM 导致(确诊后再回调省电值)
static const uint8_t kBrightActive = 255;
static const uint8_t kBrightIdle   = 255;
static const uint8_t kBrightDim    = 255;
#else
static const uint8_t kBrightActive = 120;
static const uint8_t kBrightIdle   = 60;
static const uint8_t kBrightDim    = 15;
#endif
static const uint8_t kBrightOff    = 0;

// REQ-029 v12 默认档位。L2 使用屏幕 SLPIN + CPU 降频的等效实现；当前 Arduino SDK
// 未打开 CONFIG_PM_ENABLE，不能安全使用真正的 esp_light_sleep。
#ifndef POWER_BATTERY_L1_AFTER_MS
#define POWER_BATTERY_L1_AFTER_MS (1UL * 60UL * 1000UL)
#endif
#ifndef POWER_BATTERY_L2_AFTER_MS
#define POWER_BATTERY_L2_AFTER_MS (10UL * 60UL * 1000UL)
#endif
#ifndef POWER_BATTERY_L3_AFTER_MS
#define POWER_BATTERY_L3_AFTER_MS (30UL * 60UL * 1000UL)
#endif
#ifndef POWER_DISCONNECT_L3_AFTER_MS
#define POWER_DISCONNECT_L3_AFTER_MS (5UL * 60UL * 1000UL)
#endif
static const unsigned long kBatteryL1AfterMs = POWER_BATTERY_L1_AFTER_MS;
static const unsigned long kBatteryL2AfterMs = POWER_BATTERY_L2_AFTER_MS;
static const unsigned long kBatteryL3AfterMs = POWER_BATTERY_L3_AFTER_MS;
static const unsigned long kDisconnectL3AfterMs = POWER_DISCONNECT_L3_AFTER_MS;
static const unsigned long kUsbDimAfterMs     = 15UL * 60UL * 1000UL;
static const uint32_t kLowBatteryMv = 3300;

// USB 阈值 (mV)
static const uint32_t kUsbThresholdMv = 4300;

// ADC 读数节流
static const unsigned long kAdcSampleIntervalMs = 2000;

enum PowerState {
    PWR_S_ACTIVE,
    PWR_S_IDLE,
    PWR_S_DIM,
    PWR_S_OFF,
};

static PowerState     s_state = PWR_S_ACTIVE;
static unsigned long  s_lastActivityMs = 0;
static unsigned long  s_lastAdcSampleMs = 0;
static uint32_t       s_lastVoltageMv = 0;
static bool           s_batteryVoltageValid = false;
static bool           s_usbPowered = true;   // 启动默认假定有 USB 供电(开发态)
static bool           s_simBattery = false;  // REQ-014 测试后门:模拟电池供电(串口 PWRSIM)
static float          s_socEma = -1.0f;       // REQ-021: 电压估算 SOC EMA(<0=未初始化)
static uint8_t        s_socDisplay = 0xFF;    // REQ-021: 整数滞回后的显示值(0xFF=未初始化)
static bool           s_initialized = false;
static L3ShutdownGuard s_l3Guard(kBatteryL3AfterMs, kDisconnectL3AfterMs);
#ifdef BOARD_MICSTICK_V14
static uint32_t       s_lastChargerSnapshotMs = 0;
static VsysRegulationDiagnosticGuard s_vsysDiagnosticGuard;
static BatteryVoltageShutdownGuard s_batteryLowGuard;
static uint32_t       s_batteryAdcReadyAtMs = 0;
#endif
// REQ-003 Phase 1b / Phase 2 (2026-05-03)
static bool           s_screenOff = false;
static bool           s_pendingWakeReinit = false;
static bool           s_pendingEnterOff = false;   // 通知主 loop 给 TFT 发 SLPIN(进 IC sleep)

// 把 PowerState 翻译给 ui_renderer
static UiPowerLabel labelOf(PowerState s) {
    switch (s) {
        case PWR_S_ACTIVE: return UI_PWR_ACT;
        case PWR_S_IDLE:   return UI_PWR_IDLE;
        case PWR_S_DIM:    return UI_PWR_DIM;
        case PWR_S_OFF:    return UI_PWR_OFF;
    }
    return UI_PWR_ACT;
}

static const char *stateName(PowerState s) {
    switch (s) {
        case PWR_S_ACTIVE: return "ACTIVE";
        case PWR_S_IDLE:   return "IDLE";
        case PWR_S_DIM:    return "DIM";
        case PWR_S_OFF:    return "OFF";
    }
    return "?";
}

// ── 背光 PWM 应用 ────────────────────────────────────────
static void applyBacklight(uint8_t duty) {
#ifdef BOARD_V10
    // v10 实测:LEDC PWM(5kHz)明显暗于直流常亮(同 duty),改直流驱动,仅 on/off
    // (代价:失去 PWM 平滑调光;v10 背光走 VSYS+33Ω,本就不适合细调)
    digitalWrite(PIN_LCD_BL_LOCAL, duty > 0 ? HIGH : LOW);
#else
    ledcWrite(BL_LEDC_CHANNEL, duty);
#endif
}

static void applyState(PowerState s) {
    switch (s) {
        case PWR_S_ACTIVE:
            // REQ-003 Phase 2 (2026-05-03): 从 OFF 状态过来仅恢复背光 PWM,
            // GPIO 15 全程保持 HIGH(TFT IC 一直供电),只靠 SLPIN/SLPOUT 切 IC 内部 sleep
            if (s_screenOff) {
#ifdef BOARD_V10
                pinMode(PIN_LCD_BL_LOCAL, OUTPUT);   // v10 直流:重设输出即可
#else
                // 2026-07-05 实机(v11 BE60):长睡多次 detach/attach 循环后,裸 ledcAttachPin
                // 概率性挂空 → 唤醒后背光死黑(loop/LED/BLE 全活,只有屏黑)。
                // 修复:唤醒时完整重建 LEDC 通道(setup+attach),不信任残留通道状态
                ledcSetup(BL_LEDC_CHANNEL, BL_LEDC_FREQ_HZ, BL_LEDC_RES_BITS);
                ledcAttachPin(PIN_LCD_BL_LOCAL, BL_LEDC_CHANNEL);
#endif
                // REQ-022:蜂鸣器 LEDC ch2 与背光同批完整重建(同款挂空隐患,防审批
                // 音效在长睡唤醒后哑掉;PIN_BUZZER<0 的板内部空操作)
                buzzer_reinit();
                s_screenOff = false;
                s_pendingWakeReinit = true;  // 通知主 loop 发 SLPOUT + DISPON + 重绘
                Serial.println("[power] wake from OFF, SLPOUT pending");
            }
            applyBacklight(kBrightActive);
            break;
        case PWR_S_IDLE:   applyBacklight(kBrightIdle);   break; // L1 / USB 15min 降亮
        case PWR_S_DIM:    applyBacklight(kBrightDim);    break;
        case PWR_S_OFF:
            // REQ-003 Phase 2 (2026-05-03):
            //   - 背光彻底 LOW(`ledcWrite(0)` 在 ESP32-S3 不可靠,detach + GPIO LOW 兜底)
            //   - GPIO 15 不动(实测 LOW 没真断 TFT IC,仍 ~50mA)。改靠主 loop 给 IC 发 SLPIN(0x10)
            //     让 IC 内部进 sleep(~3µA),保留 LDO 通电避免唤醒重 init 风暴
            applyBacklight(0);
            ledcDetachPin(PIN_LCD_BL_LOCAL);
            pinMode(PIN_LCD_BL_LOCAL, OUTPUT);
            digitalWrite(PIN_LCD_BL_LOCAL, LOW);
            s_screenOff = true;
            s_pendingEnterOff = true;  // 通知主 loop 发 DISPOFF + SLPIN
            Serial.println("[power] PWR_S_OFF: BL off, SLPIN pending");
            break;
    }
    Serial.printf("[power] state -> %s\n", stateName(s));
}

// ── USB / 电池电压检测 ──────────────────────────────────
// REQ-014: VSYS ADC 阈值判 USB 在负载下不可靠(v11 实测:145mA 负载 + SS14 压降把
// VSYS 拉到 4.3V 阈值线附近,USB 在线被误判为电池 → 屏幕降级)。v10/v11 板改用
// TP4056 CHRG/STDBY 开漏脚:USB 在位时二者必有其一为 LOW(充电中或已充满),
// 与电压无关;ADC 阈值仅作兜底(面包板无 TP4056 时唯一判据)。
// v12 只接了 CHRG、未接 STDBY(PIN_TP4056_STDBY=-1),故每个状态脚必须独立
// 编译保护。把 -1 传给 Arduino 的 uint8_t GPIO API 会变成 255，读取结果不可信，
// 曾导致电池供电被持续误判为 USB 在线、空闲计时器每轮被清零。
#ifndef BOARD_MICSTICK_V14
static bool tp4056UsbPresent() {
    bool present = false;
#if PIN_TP4056_CHRG >= 0
    present = present || (digitalRead(PIN_TP4056_CHRG) == LOW);
#endif
#if PIN_TP4056_STDBY >= 0
    present = present || (digitalRead(PIN_TP4056_STDBY) == LOW);
#endif
    return present;
}

static void sampleVoltage() {
    // ADC1_CH3 = GPIO 4 (PIN_BAT_VOLT). 经板内 1/2 分压器,真值 = 读数 × 2
    esp_adc_cal_characteristics_t adc_chars;
    esp_adc_cal_characterize(ADC_UNIT_1, ADC_ATTEN_DB_11, ADC_WIDTH_BIT_12, 1100, &adc_chars);
    uint32_t raw = analogRead(PIN_BAT_VOLT_LOCAL);
    uint32_t mv  = esp_adc_cal_raw_to_voltage(raw, &adc_chars) * 2;
    s_lastVoltageMv = mv;
    s_batteryVoltageValid = true;
    bool wasUsbPowered = s_usbPowered;
    s_usbPowered = (mv > kUsbThresholdMv) || tp4056UsbPresent();
    // 插拔电源本身重开空闲窗口，避免 USB 已经 15 分钟降亮后拔线立即跳到 L2/L3。
    if (s_usbPowered != wasUsbPowered) {
        const uint32_t now = millis();
        s_lastActivityMs = now;
        if (!s_usbPowered) s_l3Guard.beginBatteryWindow(now);
        Serial.printf("[power] USB %s (vbat=%lumV)\n", s_usbPowered ? "online" : "offline", (unsigned long)mv);
    }

    // REQ-021: SOC EMA。ADC 直接采 LiPo 端电压，充电时也应持续显示估算值，
    // 而不是写死 100% 或冻结拔线前的读数。充电端电压受充电电流影响，故用更慢
    // 的 EMA，只作为“电压估算 SOC”；精确 SOC 仍需要库仑计/fuel gauge 硬件。
    float rawPct = (float)power_get_battery_pct();
    const float alpha = s_usbPowered ? 0.08f : 0.20f;
    s_socEma = (s_socEma < 0) ? rawPct : (alpha * rawPct + (1.0f - alpha) * s_socEma);
}
#endif

// ── 公开 API ─────────────────────────────────────────────
#ifdef BOARD_MICSTICK_V14
// V14: EA6808 follows V3.3 and feeds GPIO7 through 100k/100k + 1uF. The
// divider measures VBAT only; SGM41511 REG0A.VBUS_GD remains the USB authority.
static void sampleBatteryVoltageV14(uint32_t now) {
    constexpr uint8_t kSampleCount = 9;
    uint16_t samples[kSampleCount];
    for (uint8_t i = 0; i < kSampleCount; ++i) {
        samples[i] = static_cast<uint16_t>(analogReadMilliVolts(PIN_BAT_VOLT_LOCAL));
        delayMicroseconds(250);
    }
    for (uint8_t i = 1; i < kSampleCount; ++i) {
        const uint16_t value = samples[i];
        uint8_t j = i;
        while (j > 0 && samples[j - 1] > value) {
            samples[j] = samples[j - 1];
            --j;
        }
        samples[j] = value;
    }

    const uint16_t pinMv = samples[kSampleCount / 2];
    const uint32_t batteryMv = sgm41511_diag::restoreDividerMillivolts(
        pinMv, BATTERY_DIVIDER_TOP_OHM, BATTERY_DIVIDER_BOTTOM_OHM);
    const bool valid = sgm41511_diag::plausibleBatteryMillivolts(batteryMv);
    s_batteryLowGuard.observe(valid, s_usbPowered, batteryMv, now);
    if (!valid) {
        s_lastVoltageMv = 0;
        s_batteryVoltageValid = false;
        s_socEma = -1.0f;
        s_socDisplay = 0xFF;
        Serial.printf("[power] V14 VBAT ADC invalid: pin=%umV restored=%lumV\n",
                      pinMv, static_cast<unsigned long>(batteryMv));
        return;
    }

    s_lastVoltageMv = batteryMv;
    s_batteryVoltageValid = true;
    const float rawPct = static_cast<float>(power_get_battery_pct());
    const float alpha = s_usbPowered ? 0.08f : 0.20f;
    s_socEma = (s_socEma < 0) ? rawPct :
        (alpha * rawPct + (1.0f - alpha) * s_socEma);
}
#endif

void power_early_init() {
#ifdef BOARD_MICSTICK_V14
    sgm41511_begin(PIN_CHARGER_SDA, PIN_CHARGER_SCL);
#endif
}

void power_init() {
    // 接管 PIN_LCD_BL (TFT_eSPI tft.begin() 已 digitalWrite HIGH 过,这里覆盖)
#ifdef BOARD_V10
    pinMode(PIN_LCD_BL_LOCAL, OUTPUT);   // v10 直流驱动,不走 LEDC(见 applyBacklight 说明)
#else
    ledcSetup(BL_LEDC_CHANNEL, BL_LEDC_FREQ_HZ, BL_LEDC_RES_BITS);
    ledcAttachPin(PIN_LCD_BL_LOCAL, BL_LEDC_CHANNEL);
#endif
    applyBacklight(kBrightActive);

#ifndef BOARD_MICSTICK_V14
    pinMode(PIN_BAT_VOLT_LOCAL, INPUT);
#if PIN_TP4056_CHRG >= 0
    // TP4056 状态脚(开漏):上拉读取,USB 在位判定用(REQ-014)
    pinMode(PIN_TP4056_CHRG,  INPUT_PULLUP);
#endif
#if PIN_TP4056_STDBY >= 0
    pinMode(PIN_TP4056_STDBY, INPUT_PULLUP);
#endif
#else
    const Sgm41511Snapshot &snapshot = sgm41511_snapshot();
    s_usbPowered = snapshot.reachable && snapshot.vbusGood;
    pinMode(PIN_BAT_VOLT_LOCAL, INPUT);
    analogReadResolution(12);
    analogSetPinAttenuation(PIN_BAT_VOLT_LOCAL, ADC_11db);
#endif

    s_state = PWR_S_ACTIVE;
    s_lastActivityMs = millis();
    s_l3Guard.beginBatteryWindow(s_lastActivityMs);
    s_lastAdcSampleMs = 0;  // 强制下一 tick 立即采样
#ifdef BOARD_MICSTICK_V14
    // Wait for the 100k/100k + 1uF node to settle after V3.3 enables EA6808.
    s_batteryAdcReadyAtMs = s_lastActivityMs + BATTERY_ADC_SETTLE_MS;
    s_lastAdcSampleMs = s_lastActivityMs;
#endif
    s_initialized = true;

#ifdef BOARD_MICSTICK_V14
    const Sgm41511Snapshot &charger = sgm41511_snapshot();
    Serial.printf("[power] init V14 SGM41511=%s configured=%u id=0x%02X VBAT=GPIO%u\n",
                  charger.reachable ? "ready" : "offline",
                  charger.configured, charger.partInfo, PIN_BAT_VOLT_LOCAL);
#else
    Serial.println("[power] init done (PWM bl + ADC vbat ready)");
#endif
}

void power_note_activity() {
    const uint32_t now = millis();
    s_lastActivityMs = now;
    s_l3Guard.noteUserActivity(now);
    if (s_state != PWR_S_ACTIVE) {
        s_state = PWR_S_ACTIVE;
        applyState(s_state);
    }
}

void power_note_system_activity() {
    s_lastActivityMs = millis();
    if (s_state != PWR_S_ACTIVE) {
        s_state = PWR_S_ACTIVE;
        applyState(s_state);
    }
}

void power_note_ble_connection(bool connected) {
    s_l3Guard.noteConnection(connected, millis());
    if (connected) {
        power_note_system_activity();
    }
}

void power_tick() {
    if (!s_initialized) return;

    unsigned long now = millis();

#ifdef BOARD_MICSTICK_V14
    sgm41511_tick();
    const Sgm41511Snapshot &snapshot = sgm41511_snapshot();
    if (snapshot.updatedMs != s_lastChargerSnapshotMs) {
        s_lastChargerSnapshotMs = snapshot.updatedMs;
        const bool wasUsbPowered = s_usbPowered;
        s_usbPowered = snapshot.reachable && snapshot.vbusGood;
        if (s_usbPowered != wasUsbPowered) {
            s_batteryLowGuard.reset();
            s_lastActivityMs = now;
            if (!s_usbPowered) s_l3Guard.beginBatteryWindow(now);
            Serial.printf("[power] VBUS %s\n", s_usbPowered ? "online" : "offline");
        }

        // REG08.D0 means VSYS_MIN regulation, not a voltage ADC. Original V13
        // testing showed it remains asserted during normal battery operation,
        // so retain it only as a diagnostic signal. V14 low-voltage L3 is
        // based exclusively on the restored GPIO7 VBAT divider below.
        const bool wasSustained = s_vsysDiagnosticGuard.sustained();
        s_vsysDiagnosticGuard.observe(snapshot.reachable, snapshot.vbusGood,
                                      snapshot.vsysRegulation, now);
        if (!wasSustained && s_vsysDiagnosticGuard.sustained()) {
            Serial.println("[power] persistent REG08.VSYS_STAT on battery (diagnostic only)");
        }
    }

    if ((long)(now - s_batteryAdcReadyAtMs) >= 0 &&
        now - s_lastAdcSampleMs >= kAdcSampleIntervalMs) {
        s_lastAdcSampleMs = now;
        sampleBatteryVoltageV14(now);
    }
#else
    // ADC 采样节流
    if (now - s_lastAdcSampleMs >= kAdcSampleIntervalMs) {
        s_lastAdcSampleMs = now;
        sampleVoltage();
    }
#endif

    // USB：保持 L0 响应，不进 L2/L3；但空闲 15 分钟降至 40% 背光。
    // s_simBattery 为测试后门，强制按电池路径走。
    if (s_usbPowered && !s_simBattery) {
        PowerState target = (now - s_lastActivityMs >= kUsbDimAfterMs) ? PWR_S_IDLE : PWR_S_ACTIVE;
        if (target != s_state) {
            s_state = target;
            applyState(s_state);
        }
        return;
    }

    // 电池：L0 → L1(1min 40%背光) → L2(10min 息屏待命)。L3 由独立 due API
    // 在主循环安全停外设后执行，避免在录音/审批中直接断轨。
    unsigned long sinceActivity = now - s_lastActivityMs;

    PowerState target = s_state;
    if      (sinceActivity >= kBatteryL2AfterMs) target = PWR_S_OFF;
    else if (sinceActivity >= kBatteryL1AfterMs) target = PWR_S_IDLE;
    else                                     target = PWR_S_ACTIVE;

    if (target != s_state) {
        s_state = target;
        applyState(s_state);
    }
}

UiPowerLabel power_get_label() {
    return labelOf(s_state);
}

bool power_consume_wake_event() {
    if (s_state == PWR_S_OFF) {
        // REQ-003 Phase 2.2 (0.5.1): 不再吞键 —
        //   PTT 主键吞首次按这种 UX 反人类,体验是"按了没反应,得按两次"
        //   现在第一次按既唤醒也透传事件,按下 BtnA 直接进 PTT 录音
        //   屏幕 SLPOUT 还得 ~120ms 才亮,但这只影响视觉反馈,BLE 命令立刻发出去
        s_state = PWR_S_ACTIVE;
        s_lastActivityMs = millis();
        applyState(s_state);
        Serial.println("[power] wake from OFF, event passes through");
    }
    return false;  // 永远不吞键
}

bool power_is_usb_powered() {
    return s_usbPowered;
}

// REQ-014 测试后门:模拟电池供电(true=无视 ADC 强制走超时链)
void power_sim_battery(bool on) {
    s_simBattery = on;
    if (on) {
        const uint32_t now = millis();
        s_lastActivityMs = now;
        s_l3Guard.beginBatteryWindow(now);  // 从当下开始计时
    }
}

uint32_t power_get_voltage_mv() {
    return s_lastVoltageMv;
}

// REQ-003 Phase 1b
bool power_is_sleeping() {
    return s_state == PWR_S_OFF;
}

uint16_t power_get_cpu_target_mhz() {
    if (s_state == PWR_S_OFF)  return 80;   // L2
    if (s_state == PWR_S_IDLE) return 160;  // L1
    return 240;                              // L0
}

bool power_deep_standby_due() {
    if (s_usbPowered && !s_simBattery) return false;
#ifdef BOARD_MICSTICK_V14
    if (s_batteryLowGuard.shutdownDue()) return true;
#else
    if (s_lastVoltageMv > 0 && s_lastVoltageMv <= kLowBatteryMv) return true;
    if (power_get_battery_pct_smoothed() <= 5) return true;
#endif
    return s_l3Guard.shutdownDue(millis());
}

bool power_check_wake_reinit() {
    bool ret = s_pendingWakeReinit;
    s_pendingWakeReinit = false;
    return ret;
}

// REQ-003 Phase 2 (2026-05-03): one-shot,主 loop 应给 TFT 发 DISPOFF + SLPIN
bool power_check_enter_off() {
    bool ret = s_pendingEnterOff;
    s_pendingEnterOff = false;
    return ret;
}

// REQ-003 Phase 1c: LiPo 电压 → 百分比 (分段线性近似)
//   3.3V=0% / 3.5V=10% / 3.6V=20% / 3.7V=40% / 3.8V=60% / 4.0V=80% / 4.2V=100%
uint8_t power_get_battery_pct() {
    if (!s_batteryVoltageValid) return 0;
    uint32_t mv = s_lastVoltageMv;
    if (mv >= 4200) return 100;
    if (mv >= 4000) return 80 + (mv - 4000) * 20 / 200;
    if (mv >= 3800) return 60 + (mv - 3800) * 20 / 200;
    if (mv >= 3700) return 40 + (mv - 3700) * 20 / 100;
    if (mv >= 3600) return 20 + (mv - 3600) * 20 / 100;
    if (mv >= 3500) return 10 + (mv - 3500) * 10 / 100;
    if (mv >= 3300) return  0 + (mv - 3300) * 10 / 200;
    return 0;
}

// REQ-021: 充电三态(TP4056 CHRG/STDBY 开漏脚;面包板无 TP4056 按 USB 供电估)
PowerChargeState power_get_charge_state() {
#ifdef BOARD_MICSTICK_V14
    const Sgm41511Snapshot &snapshot = sgm41511_snapshot();
    if (!snapshot.reachable) return PWR_CHG_DISCHARGE;
    if (snapshot.chargeState == 3) return PWR_CHG_FULL;
    if (snapshot.chargeState == 1 || snapshot.chargeState == 2) return PWR_CHG_CHARGING;
    return PWR_CHG_DISCHARGE;
#else
#if PIN_TP4056_CHRG >= 0
    if (digitalRead(PIN_TP4056_CHRG)  == LOW) return PWR_CHG_CHARGING;   // 充电中
#endif
#if PIN_TP4056_STDBY >= 0
    if (digitalRead(PIN_TP4056_STDBY) == LOW) return PWR_CHG_FULL;       // 已充满
#endif
    // v12 未接 STDBY，ADC 兜底判为 USB 在线时只能知道“在线”，不能区分已满；
    // 用充电中标签表示外部供电，避免对无效 GPIO 读取。
    return s_usbPowered ? PWR_CHG_CHARGING : PWR_CHG_DISCHARGE;
#endif
}

// REQ-021: EMA + 滞回后的显示电量。无论充/放电都基于 LiPo 电压持续更新；
// 充电态 EMA 更慢(见 sampleVoltage)，显示的是估算 SOC，非库仑计精确容量。
uint8_t power_get_battery_pct_smoothed() {
    if (!s_batteryVoltageValid) return 0;
    uint8_t raw = (s_socEma >= 0) ? (uint8_t)(s_socEma + 0.5f) : power_get_battery_pct();
    if (s_socDisplay == 0xFF) { s_socDisplay = raw; return s_socDisplay; }
    int diff = (int)raw - (int)s_socDisplay;
    if (diff >= 2 || diff <= -2) s_socDisplay = raw;   // 死区 ±2%
    return s_socDisplay;
}

bool power_has_battery_percentage() {
    return s_batteryVoltageValid;
}

bool power_has_fault() {
#ifdef BOARD_MICSTICK_V14
    const Sgm41511Snapshot &snapshot = sgm41511_snapshot();
    if (!snapshot.reachable) return false;
    const bool nonNtcFault = (snapshot.fault & ~sgm41511::kNtcFaultMask) != 0;
    return nonNtcFault || sgm41511::ntcFaultIsSevere(snapshot.ntcFault);
#else
    return false;
#endif
}

bool power_charger_reachable() {
#ifdef BOARD_MICSTICK_V14
    return sgm41511_snapshot().reachable;
#else
    return true;
#endif
}

BatteryThermalState power_get_battery_thermal_state() {
#ifdef BOARD_MICSTICK_V14
    switch (sgm41511_snapshot().ntcFault) {
        case sgm41511::NtcFault::Normal: return BAT_THERMAL_NORMAL;
        case sgm41511::NtcFault::Warm:   return BAT_THERMAL_WARM;
        case sgm41511::NtcFault::Cool:   return BAT_THERMAL_COOL;
        case sgm41511::NtcFault::Cold:   return BAT_THERMAL_COLD;
        case sgm41511::NtcFault::Hot:    return BAT_THERMAL_HOT;
        default:                         return BAT_THERMAL_UNKNOWN;
    }
#else
    return BAT_THERMAL_NORMAL;
#endif
}

// ── REQ-029 (v12/v13):IO9 深待机 L3 ──────────────────────
#ifdef PIN_PWR_KILL
#include <Preferences.h>
static const char *kPwrNvsNs   = "pwr";
static const char *kCleanKey   = "clean_off";   // 1=上次干净待机;开机读后清
static const char *kBootKindKey = "last_boot";  // 0=普通冷启动 1=L3 后启动 2=Ship 后启动

bool power_prepare_ship_mode() {
#if HARDWARE_REVISION >= 14 && defined(BOARD_MICSTICK_V14)
    if (power_is_usb_powered()) return false;
    return sgm41511_prepare_ship_mode();
#else
    return false;
#endif
}

void power_cancel_ship_mode() {
#if HARDWARE_REVISION >= 14 && defined(BOARD_MICSTICK_V14)
    sgm41511_cancel_ship_mode();
#endif
}

bool power_enter_ship_mode(const char *reason) {
#if HARDWARE_REVISION >= 14 && defined(BOARD_MICSTICK_V14)
    // Close the VBUS race immediately before the irreversible register write.
    if (power_is_usb_powered()) return false;

    Serial.printf("[PWR] enter SGM41511 Ship Mode, reason=%s\n", reason ? reason : "?");
    Preferences p;
    if (p.begin(kPwrNvsNs, false)) {
        const Sgm41511Snapshot &charger = sgm41511_snapshot();
        p.putString("ship_reason", reason ? reason : "?");
        p.putUInt("ship_ms", millis());
        p.putUChar("ship_r08", charger.reg08SystemStatus);
        p.putUChar("ship_r09", charger.reg09FaultStatus);
        p.putUChar("ship_r0a", charger.reg0aInputStatus);
        p.putUChar("ship_pending", 1);  // commit marker written last
        p.end();
    }

    led_force_off();
#if PIN_BUZZER >= 0
    digitalWrite(PIN_BUZZER, LOW);
#endif
    applyBacklight(0);
    delay(20);  // let NVS and the LED all-off frame settle

    if (!sgm41511_commit_ship_mode()) {
        sgm41511_cancel_ship_mode();
        if (p.begin(kPwrNvsNs, false)) {
            p.putUChar("ship_pending", 0);
            p.end();
        }
        applyBacklight(kBrightActive);
        Serial.println("[PWR] Ship Mode final I2C write failed");
        return false;
    }

    // BATFET_DLY=0: the rail should collapse immediately. Never run the normal
    // charger audit again after the accepted final write.
    while (true) { delay(1000); }
#else
    (void)reason;
    return false;
#endif
}

void power_enter_deep_standby(const char *reason, volatile uint8_t *diagnosticStage) {
    if (diagnosticStage) *diagnosticStage = 43;
    Serial.printf("[PWR] enter deep standby (IO9 kill), reason=%s\n", reason ? reason : "?");
    // Do not call HWCDC::flush() here.  Arduino-ESP32 2.0.14 waits without a
    // timeout for the USB/JTAG TX ring to drain; on battery with no USB host it
    // never drains, so GPIO9 was never asserted and RWDT rebooted at stage 42.

    // 1. 停外设:LED 全灭 + EN_LED 断 SK6812 电源(彻底,不留待机电流)
#ifdef PIN_EN_LED
    pinMode(PIN_EN_LED, OUTPUT);
    digitalWrite(PIN_EN_LED, LOW);
#endif
    // 2. 蜂鸣器脚拉低防噪
#if PIN_BUZZER >= 0
    digitalWrite(PIN_BUZZER, LOW);
#endif
    // 3. 屏背光关(掉电瞬间不留亮)
    applyBacklight(0);

    // 4. NVS 置干净关机标记(区分主动待机 vs 崩溃/欠压;唯一掉电前写入)
    Preferences p;
    if (p.begin(kPwrNvsNs, false)) {
        p.putString("l3_reason", reason ? reason : "?");
#ifdef BOARD_MICSTICK_V14
        const Sgm41511Snapshot &charger = sgm41511_snapshot();
        p.putUInt("l3_ms", millis());
        p.putUChar("l3_r08", charger.reg08SystemStatus);
        p.putUChar("l3_r09", charger.reg09FaultStatus);
        p.putUChar("l3_r0a", charger.reg0aInputStatus);
        p.putUChar("l3_vsys_n", s_vsysDiagnosticGuard.samples());
        p.putUInt("l3_vbat_mv", s_batteryVoltageValid ? s_lastVoltageMv : 0);
        p.putUChar("l3_vbat_n", s_batteryLowGuard.samples());
#endif
        p.putUInt("l3_seq", p.getUInt("l3_seq", 0) + 1);
        // Commit marker last: clean_off=1 guarantees the diagnostic fields
        // above were attempted before the irreversible GPIO9 transition.
        p.putUChar(kCleanKey, 1);
        p.end();
    }
    if (diagnosticStage) *diagnosticStage = 44;

    // 5. 拉 IO9=1 关整条 3.3V。RC 延时内 MCU 还跑几十 ms 才真掉电——此后勿写 flash。
    delay(20);                       // 只等待 NVS 落定；不等待无主机 USB CDC
    digitalWrite(PIN_PWR_KILL, HIGH);
    if (diagnosticStage) *diagnosticStage = 45;
    // 3.3V 塌陷后 MCU 断电,不返回。兜底:若因 USB 供电 VSYS 仍在导致没断,原地等待。
    while (true) { delay(1000); }
}

bool power_was_clean_shutdown() {
    Preferences p;
    if (!p.begin(kPwrNvsNs, false)) return false;
    uint8_t v = p.getUChar(kCleanKey, 0);
    uint8_t ship = p.getUChar("ship_pending", 0);
    const uint8_t bootKind = v ? 1 : (ship ? 2 : 0);
    p.putUInt("boot_seq", p.getUInt("boot_seq", 0) + 1);
    p.putUChar(kBootKindKey, bootKind);
    p.putUChar("last_reset", (uint8_t)esp_reset_reason());
    if (v) p.putUInt("l3_wakes", p.getUInt("l3_wakes", 0) + 1);
    else if (ship) p.putUInt("ship_wakes", p.getUInt("ship_wakes", 0) + 1);
    else p.putUInt("cold_boots", p.getUInt("cold_boots", 0) + 1);
    if (v) {
#ifdef BOARD_MICSTICK_V14
        String reason = p.getString("l3_reason", "?");
        Serial.printf("[PWR] previous L3 reason=%s up=%lums REG08=%02X REG09=%02X REG0A=%02X vsysN=%u\n",
                      reason.c_str(), (unsigned long)p.getUInt("l3_ms", 0),
                      p.getUChar("l3_r08", 0), p.getUChar("l3_r09", 0),
                      p.getUChar("l3_r0a", 0), p.getUChar("l3_vsys_n", 0));
#endif
        p.putUChar(kCleanKey, 0);   // 读后清,下次崩溃就读到 0
    }
    if (ship) {
        Serial.printf("[PWR] previous Ship Mode reason=%s up=%lums REG08=%02X REG09=%02X REG0A=%02X\n",
                      p.getString("ship_reason", "?").c_str(),
                      (unsigned long)p.getUInt("ship_ms", 0),
                      p.getUChar("ship_r08", 0), p.getUChar("ship_r09", 0),
                      p.getUChar("ship_r0a", 0));
        p.putUChar("ship_pending", 0);
    }
    p.end();
    return v != 0 || ship != 0;
}

void power_dump_shutdown_history() {
    Preferences p;
    if (!p.begin(kPwrNvsNs, true)) return;
    const uint8_t kind = p.getUChar(kBootKindKey, 0);
    const char *kindName = kind == 1 ? "L3_WAKE" : (kind == 2 ? "SHIP_WAKE" : "COLD_UNCLASSIFIED");
    Serial.printf("[PWR-HIST] boot=%lu kind=%s reset=%u l3seq=%lu l3wakes=%lu shipwakes=%lu cold=%lu legacyRejects=%lu\n",
                  (unsigned long)p.getUInt("boot_seq", 0), kindName,
                  (unsigned)p.getUChar("last_reset", 0),
                  (unsigned long)p.getUInt("l3_seq", 0),
                  (unsigned long)p.getUInt("l3_wakes", 0),
                  (unsigned long)p.getUInt("ship_wakes", 0),
                  (unsigned long)p.getUInt("cold_boots", 0),
                  // 早期诊断版曾把正常短按唤醒误判并主动关机；只保留旧值
                  // 供时间线取证，新固件不再产生此计数。
                  (unsigned long)p.getUInt("wake_rejects", 0));
    Serial.printf("[PWR-HIST] lastL3 reason=%s up=%lums REG08=%02X REG09=%02X REG0A=%02X vsysN=%u\n",
                  p.getString("l3_reason", "?").c_str(),
                  (unsigned long)p.getUInt("l3_ms", 0),
                  p.getUChar("l3_r08", 0), p.getUChar("l3_r09", 0),
                  p.getUChar("l3_r0a", 0), p.getUChar("l3_vsys_n", 0));
    p.end();
}
#else
bool power_prepare_ship_mode() { return false; }
void power_cancel_ship_mode() {}
bool power_enter_ship_mode(const char *) { return false; }
void power_enter_deep_standby(const char *, volatile uint8_t *) {}
bool power_was_clean_shutdown() { return false; }
void power_dump_shutdown_history() {}
#endif
