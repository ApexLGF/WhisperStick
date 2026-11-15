// led_manager.cpp — SK6812 4-LED 状态指示实现
#include "led_manager.h"

#include <Arduino.h>
#include <Adafruit_NeoPixel.h>
#include <Preferences.h>

// ── 配置 ──────────────────────────────────────────────────
#include "led_brightness.h"
#include "pin_config.h"   // PIN_LED_DIN 按目标板(面包板=2 / v10=38)
#define LED_COUNT       4
#define LED_TICK_MS    33   // 30 Hz 刷新
#define LED_NVS_NS     "led"
#define LED_NVS_KEY    "bri"

// ── 内部状态 ──────────────────────────────────────────────
static Adafruit_NeoPixel s_strip(LED_COUNT, PIN_LED_DIN, NEO_GRB + NEO_KHZ800);
static LedStatus  s_status        = LED_BLE_DISCONNECTED;
static LedEvent   s_event         = LED_EV_NONE;
static uint32_t   s_eventStartMs  = 0;
static uint32_t   s_lastTickMs    = 0;
static uint32_t   s_statusPhaseMs = 0;  // status 切换时重置,做相位起点
static uint8_t    s_brightnessPct = 32;

// ── 工具 ──────────────────────────────────────────────────
static inline uint32_t mkRGB(uint8_t r, uint8_t g, uint8_t b) {
    return s_strip.Color(
        ledScaleChannel(r, s_brightnessPct),
        ledScaleChannel(g, s_brightnessPct),
        ledScaleChannel(b, s_brightnessPct)
    );
}

static inline void fillAll(uint32_t color) {
    for (uint16_t i = 0; i < LED_COUNT; i++) s_strip.setPixelColor(i, color);
}

// 0..1 phase → 0..1 sin breathing (full sine wave half cycle)
static inline float breathPhase(uint32_t now, uint32_t periodMs) {
    float p = (float)((now - s_statusPhaseMs) % periodMs) / (float)periodMs;
    return (sinf(p * 2.0f * 3.14159265f) * 0.5f) + 0.5f;
}

// ── 渲染:event 优先,否则 status ──────────────────────────
// 普通事件:fillAll(color) 持续 duration ms
// 心跳事件 (PERM_PENDING):200ms 亮 + 100ms 灭 × 3 = 1500ms 紫色急促心跳
static bool renderEvent(uint32_t now) {
    if (s_event == LED_EV_NONE) return false;

    uint32_t elapsed = now - s_eventStartMs;

    // PERM_PENDING 是节奏型,单独走 — 紫色心跳 3 次(每次 200ms 亮 + 100ms 灭)
    if (s_event == LED_EV_PERM_PENDING) {
        const uint32_t totalDur = 1500;  // 3 × (200+100) + 0 buffer
        if (elapsed >= totalDur) {
            s_event = LED_EV_NONE;
            return false;
        }
        // 单格 = 300ms (200 亮 + 100 灭)
        uint32_t phaseInBeat = elapsed % 300;
        bool on = (phaseInBeat < 200);
        fillAll(on ? mkRGB(140, 0, 200) : 0);
        return true;
    }

    // 其他事件:固定颜色 + 时长。亮度 ≤ 100/255 防 720mA 浪涌
    uint32_t duration = 500;
    uint32_t color    = 0;
    switch (s_event) {
        case LED_EV_BTN_A:        color = mkRGB( 80,  80,  80); duration = 500; break;  // 白
        case LED_EV_BTN_B:        color = mkRGB( 80,  60,   0); duration = 500; break;  // 黄
        case LED_EV_ASR_SUCCESS:  color = mkRGB(  0, 100,   0); duration = 700; break;  // 绿
        case LED_EV_ASR_FAILURE:  color = mkRGB(100,   0,   0); duration = 700; break;  // 红
        default: break;
    }
    if (elapsed >= duration) {
        s_event = LED_EV_NONE;
        return false;
    }
    fillAll(color);
    return true;
}

static void renderStatus(uint32_t now) {
    switch (s_status) {
        case LED_BLE_DISCONNECTED: {
            float bri = breathPhase(now, 2000);
            uint8_t r = (uint8_t)(40 + 215.0f * bri);
            fillAll(mkRGB(r, 0, 0));
            break;
        }
        case LED_IDLE: {
            // 呼吸绿,3 秒一周期,告知设备活着
            float bri = breathPhase(now, 3000);
            uint8_t g = (uint8_t)(10 + 35.0f * bri);
            fillAll(mkRGB(0, g, 0));
            break;
        }
        case LED_PTT: {
            float bri = breathPhase(now, 700);
            uint8_t r = (uint8_t)(80 + 175.0f * bri);
            uint8_t g = (uint8_t)(20 +  60.0f * bri);
            fillAll(mkRGB(r, g, 0));
            break;
        }
        case LED_ASR_PROC: {
            uint16_t pos = ((now - s_statusPhaseMs) / 180) % LED_COUNT;
            for (uint16_t i = 0; i < LED_COUNT; i++) {
                if (i == pos) s_strip.setPixelColor(i, mkRGB(0, 80, 220));
                else          s_strip.setPixelColor(i, mkRGB(0,  5,  20));
            }
            break;
        }
        case LED_PERM_REQUEST: {
            bool on = (((now - s_statusPhaseMs) / 500) & 1) == 0;
            fillAll(on ? mkRGB(140, 0, 200) : 0);
            break;
        }
        case LED_SLEEPING: {
            // REQ-029 L2：保留第 1、4 颗弱绿灯，表明仍在线；静态显示避免额外动画唤醒。
            s_strip.setPixelColor(0, mkRGB(0, 64, 0));
            s_strip.setPixelColor(1, 0);
            s_strip.setPixelColor(2, 0);
            s_strip.setPixelColor(3, mkRGB(0, 64, 0));
            break;
        }
        case LED_SLEEPING_DISCONNECTED: {
            // 同上,BLE 未连用红色
            s_strip.setPixelColor(0, mkRGB(3, 0, 0));
            for (uint16_t i = 1; i < LED_COUNT; i++) {
                s_strip.setPixelColor(i, 0);
            }
            break;
        }
    }
}

// ── 公开 API ──────────────────────────────────────────────
void led_init(bool skipSelfTest) {
    // v12(MicStick):SK6812 的 VLED 供电经 Q9→Q8 开关管,栅极受 EN_LED(IO8)控制。
    // v11 无此软控(LED 直接供电),故 v11 固件不驱动此脚。必须先拉高使能 VLED,
    // 否则灯珠无电,任何 show() 都不亮。DIN 之前完成上电,给电源建立留 2ms。
#ifdef PIN_EN_LED
    pinMode(PIN_EN_LED, OUTPUT);
    digitalWrite(PIN_EN_LED, HIGH);
    delay(2);
#endif
    Preferences p;
    if (p.begin(LED_NVS_NS, false)) {
        s_brightnessPct = ledClampBrightnessPercent(p.getUChar(LED_NVS_KEY, 32));
        p.end();
    }
    s_strip.begin();
    s_strip.setBrightness(255);
    fillAll(0);
    s_strip.show();

    // 启动自检:R/G/B 三色滚一遍,每色 200ms(REQ-029:唤醒重连时跳过,省 ~600ms)
    if (!skipSelfTest) {
        const uint32_t selfTest[] = {
            mkRGB(80, 0, 0), mkRGB(0, 80, 0), mkRGB(0, 0, 80)
        };
        for (uint8_t c = 0; c < 3; c++) {
            fillAll(selfTest[c]);
            s_strip.show();
            delay(200);
        }
        fillAll(0);
        s_strip.show();
    }

    s_lastTickMs    = millis();
    s_statusPhaseMs = millis();
    Serial.printf("[LED] init brightness=%u%% (nvs)\n", s_brightnessPct);
}

void led_tick() {
    uint32_t now = millis();
    if (now - s_lastTickMs < LED_TICK_MS) return;
    s_lastTickMs = now;

    if (!renderEvent(now)) {
        renderStatus(now);
    }
    s_strip.show();
}

void led_set_status(LedStatus s) {
    if (s != s_status) {
        Serial.printf("[LED] status %d → %d\n", s_status, s);
        s_status = s;
        s_statusPhaseMs = millis();  // 重置相位,从 0 开始动画
    }
}

void led_fire_event(LedEvent e) {
    Serial.printf("[LED] event=%d fired\n", e);
    s_event = e;
    s_eventStartMs = millis();
}

void led_force_off() {
    s_event = LED_EV_NONE;
    fillAll(0);
    s_strip.show();
}

bool led_has_active_event() {
    return s_event != LED_EV_NONE;
}

void led_set_brightness_percent(uint8_t pct) {
    uint8_t v = ledClampBrightnessPercent(pct);
    if (v == s_brightnessPct) {
        Serial.printf("[LED] brightness %u -> %u%% (unchanged)\n", pct, v);
        return;
    }
    s_brightnessPct = v;
    Preferences p;
    if (p.begin(LED_NVS_NS, false)) {
        p.putUChar(LED_NVS_KEY, v);
        p.end();
    }
    Serial.printf("[LED] brightness %u -> %u%% (nvs saved)\n", pct, v);
}

uint8_t led_get_brightness_percent() {
    return s_brightnessPct;
}
