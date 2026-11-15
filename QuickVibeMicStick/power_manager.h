// power_manager.h
// 电源 / 亮度 / OFF(屏幕 sleep)管理 — REQ-003 Phase 1/2 (0.5.3)
//
// 职责:
//   - 4 级背光 PWM (ACTIVE/IDLE/DIM/OFF) on GPIO PIN_LCD_BL = 38
//   - 无操作超时状态机 (10s→IDLE / 30s→DIM / 60s→OFF),不再走 deep sleep
//   - 进 OFF:背光 detach + 通知主 loop 给 ST7789 发 SLPIN(IC 内部 sleep)
//   - 出 OFF:背光 attach + 通知主 loop 发 SLPOUT + DISPON,framebuffer 不丢
//   - USB 供电检测 + 真实电池电量(GPIO 4 ADC,LiPo 分段曲线)
//
// 主 loop 协作:
//   - power_check_enter_off() / power_check_wake_reinit() 拿 SLPIN/SLPOUT 触发标志
//   - power_is_sleeping() 配合 setCpuFrequencyMhz(80/240) + BLE conn 切换
//   - ui_render(... power_get_label(), ...) 拿 ACT/IDLE/DIM/OFF 标签

#pragma once

#include <stdint.h>
#include "ui_renderer.h"   // UiPowerLabel

void power_init();

// V13-only early power hold/charger setup. Call immediately after GPIO9 has
// been forced LOW and high-power outputs have been forced off.
void power_early_init();

// 任意按键事件 / BLE 收到状态推送时调用 — 重置无操作计时器,切回 ACTIVE；
// BLE 断连期间还会重开完整的 5 分钟重连窗口。
void power_note_activity();

// BLE reconnects and remote UI notifications may wake the display, but are not
// physical user activity and therefore must not extend the 30-minute L3 deadline.
void power_note_system_activity();

// BLE 连接边沿：连接只唤屏、不刷新 30 分钟真实用户空闲计时；断连开始 5 分钟计时。
// 断连后的物理按键/旋钮活动会重新开始完整的 5 分钟窗口。
void power_note_ble_connection(bool connected);

// 每个 loop 调一次 — 推进状态机,检查 deep sleep 触发条件
void power_tick();

// 当前 UiPowerLabel,给 ui_render 显示用
UiPowerLabel power_get_label();

// 屏幕关闭吞键守卫:
//   - 当前 PWR_OFF 且检测到按键事件时,调用此函数会把状态切回 ACTIVE 并 return true(吞掉本轮按键)
//   - 否则 return false(按键正常处理)
// 调用时机: loop 顶部检测到 anyEvent==true 立即调
bool power_consume_wake_event();

// 监控用:当前是否 USB 供电 (>4300mV)
bool power_is_usb_powered();

// REQ-014 测试后门:模拟电池供电(串口 PWRSIM,验证超时链;重启恢复)
void power_sim_battery(bool on);

// 监控用:最近一次 ADC 电池电压(mV)。V14 使用 GPIO7 的 100k/100k
// 受控分压；采样尚未稳定或读数不可信时，调用方必须依据
// power_has_battery_percentage() 隐藏电压/百分比，不得把 0 当实测值。
uint32_t power_get_voltage_mv();
bool power_has_battery_percentage();
bool power_has_fault();
bool power_charger_reachable();
BatteryThermalState power_get_battery_thermal_state();

// REQ-003 Phase 1b: 当前是否处于 OFF 状态(TFT IC SLPIN + LED 灭)
bool power_is_sleeping();

// 当前建议的 CPU 频率：L0=240MHz，L1=160MHz，L2=80MHz。
// L2 受当前 Arduino SDK 限制，不会进入真正的 esp_light_sleep。
uint16_t power_get_cpu_target_mhz();

// 电池供电下满足任一 REQ-029 L3 条件时为 true：空闲 30 分钟、BLE 断连 5 分钟；
// V12/V14 还使用 ADC/SOC。V14 的低电压关机要求 GPIO7 连续 5 次有效
// 采样 <=3.3V；REG08.VSYS_STAT 在正常电池运行时也可能置位，仅作诊断。
// 调用方只应为真实进行中的录音延迟断轨；远程弹窗/审批不得无限阻止 L3。
bool power_deep_standby_due();

// V14 SGM41511 Ship Mode. prepare is reversible and verifies that REG07 is
// ready for immediate BATFET cut-off. enter performs the final irreversible
// write and normally never returns; false means the final I2C write failed.
bool power_prepare_ship_mode();
void power_cancel_ship_mode();
bool power_enter_ship_mode(const char *reason);

// REQ-003 Phase 2 (2026-05-03): 进入 OFF 时,主 loop 应给 TFT 发 SLPIN 命令。one-shot
bool power_check_enter_off();

// REQ-003 Phase 1b/2: 退出 OFF 时,主 loop 应给 TFT 发 SLPOUT 命令 + 重绘。one-shot
bool power_check_wake_reinit();

// ── REQ-029 (v12 MicStick):IO9 深待机(L3)──────────────────
// 进入深待机:停外设 → LED 全灭(EN_LED=0)→ NVS 置干净关机标记 → IO9=1 关整条 3.3V。
// 此调用不返回(3.3V 掉后 MCU 断电);唤醒=硬件 waken_EN 任意按键 → 冷启动。
// BOARD_MICSTICK_V12/V13 有 PIN_PWR_KILL；其它板此函数空实现。
// diagnosticStage 可选：黑匣子阶段标记。42=业务外设已停，43=进入关机函数，
// 44=NVS 已保存，45=GPIO9 已拉高；用于区分关机链路具体停点。
void power_enter_deep_standby(const char *reason, volatile uint8_t *diagnosticStage = nullptr);

// 上电时读"上次是否干净关机"(供黑匣子区分主动待机 vs 崩溃/欠压)。读后清标记。
// true=上次是主动 power_enter_deep_standby(不是崩溃)。
bool power_was_clean_shutdown();

// 持久化输出最近一次冷启动是否承接正常 L3/Ship Mode，以及累计次数。
// BB? 调用它，避免启动早期串口无人监听时丢失关键证据。
void power_dump_shutdown_history();

// REQ-003 Phase 1c: 电压估算电量 (0-100)
//   V12/V14 均从独立的电池分压读取 VBAT；USB 在线时也不写死 100%。
//   LiPo 静态电压 → 百分比分段线性曲线，不等同于库仑计 SOC。
uint8_t power_get_battery_pct();

// REQ-021: 充电三态(状态栏充电标识用)
//   TP4056: CHRG LOW=充电中 / STDBY LOW=充满;面包板(pin=-1)按 USB 供电估
enum PowerChargeState : uint8_t {
    PWR_CHG_DISCHARGE = 0,
    PWR_CHG_CHARGING  = 1,
    PWR_CHG_FULL      = 2,
};
PowerChargeState power_get_charge_state();

// REQ-021: EMA + 滞回后的电量显示值(状态栏用)
//   充电/USB 时冻结平滑值(不虚跳 100,解决 USB 在线 V_BAT 回灌);
//   电池路径做整数滞回(与上次显示差 <2% 不变,防秒级跳变)
uint8_t power_get_battery_pct_smoothed();
