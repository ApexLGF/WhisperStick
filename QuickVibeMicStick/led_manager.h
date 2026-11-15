// led_manager.h
// Stage 1b 后半: SK6812 LED 灯条状态指示
//
// 硬件:
//   - SK6812 4 颗 (60珠/m 灯条剪 4 颗)
//   - GPIO 2 → SN74AHCT125N(1A) → 1Y → 470Ω → SK6812 DIN
//   - 5V 来自 USB(VBUS),100µF 电解滤波
//   - 拔 USB 后 LED 自动灭(在 deep sleep 场景符合预期)
//
// 状态联动 UI:
//   - 状态色(持续显示):BLE 未连/已连Idle/PTT/ASR 处理/Permission 请求
//   - 事件色(一次性 ~100-500ms 闪烁):BtnA 短按 / BtnB 短按 / ASR 成功 / ASR 失败
//
// 调度:
//   - led_init()          setup 一次
//   - led_tick()          loop 每帧调,内部按 33ms 节流(30Hz)
//   - led_set_status(s)   主 loop 根据全局态推断后调用
//   - led_fire_event(e)   命令派发瞬间 / VOICE_NOTIFY 收到时调

#pragma once

#include <stdint.h>

enum LedStatus {
    LED_BLE_DISCONNECTED = 0,  // 红色呼吸
    LED_IDLE,                  // 绿色弱光常亮
    LED_PTT,                   // 橙色脉动
    LED_ASR_PROC,              // 蓝色跑马
    LED_PERM_REQUEST,          // 紫色慢闪
    LED_SLEEPING,              // 1 LED 极慢呼吸绿(BLE 已连,设备 alive but sleeping)
    LED_SLEEPING_DISCONNECTED, // 1 LED 极慢呼吸红(BLE 未连 + sleep,提示用户重连)
};

enum LedEvent {
    LED_EV_NONE = 0,
    LED_EV_BTN_A,         // 白色 500ms
    LED_EV_BTN_B,         // 黄色 500ms
    LED_EV_ASR_SUCCESS,   // 绿色 700ms
    LED_EV_ASR_FAILURE,   // 红色 700ms
    LED_EV_PERM_PENDING,  // 紫色心跳 3 次 (REQ-003: light sleep 紧急通知)
};

// skipSelfTest=true:跳过开机 R/G/B 三色自检(REQ-029 唤醒重连提速,省 ~600ms)
void led_init(bool skipSelfTest = false);
void led_tick();

// 主 loop 推断完后调一次,只有 status 变化才重置内部相位
void led_set_status(LedStatus s);

// 事件触发,自动覆盖 status 显示对应时长后回到 status
void led_fire_event(LedEvent e);

// Synchronously transmit an all-off frame before an irreversible power cut.
void led_force_off();

// 主 loop 判断是否有未完成的 LED 事件正在渲染
bool led_has_active_event();

void led_set_brightness_percent(uint8_t pct);
uint8_t led_get_brightness_percent();
