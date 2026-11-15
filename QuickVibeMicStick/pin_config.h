// pin_config.h — QuickVibeMicPad 引脚单一来源(对应 pcb/GPIO_ALLOCATION.md)
//
// 目标板分流:
//   面包板原型(LilyGo T-Display-S3 + INMP441 + 并口 ST7789)= 默认,env:micpad
//   v10 自制 PCB(ESP32-S3-WROOM-1-N16R8 + ICS-43434 + SPI ST7789P3)= -DBOARD_V10,env:micpad-v10
//   v11 自制 PCB(同 v10,麦换 PDM 顶进声 MSM261DHP006)= -DBOARD_V11,env:micpad-v11
//
// 业务逻辑不依赖具体脚位:换板只改本文件 + platformio.ini 里屏的 build_flags(并口↔SPI)。
// 屏引脚走 TFT_eSPI build_flags(见 platformio.ini),不在此文件。
#pragma once

// MicStick PCB revision is reported to the Host as a hardware capability.
// Future board build environments must set -DHARDWARE_REVISION=<revision>.
#ifndef HARDWARE_REVISION
#define HARDWARE_REVISION 0
#endif

#if defined(BOARD_MICSTICK_V14)
// ─────────── QuickVibeMicStick V14 ───────────
// V14 production PCB formalizes the V13.5 flywire changes. GPIO8/40 remain
// dedicated to SGM41511 I2C. EA6808 enables a 100k/100k VBAT divider whenever
// V3.3 is present, and side SW1/nQON is also readable on active-low GPIO5.
#define PIN_BUTTON            1
#define PIN_BUTTON_B          2
#define PIN_BUTTON_C         47
#define PIN_ENC_A            16
#define PIN_ENC_B            17
#define PIN_ENC_SW           18
#define MIC_PDM               1
#define PIN_PDM_CLK           4
#define PIN_PDM_DATA          6
#ifndef MIC_PDM_GAIN_SHIFT
#define MIC_PDM_GAIN_SHIFT    2
#endif
#define PIN_LED_DIN          38
#define PIN_LCD_BL_LOCAL     21
#define PIN_BUZZER           39
#define PIN_PWR_KILL          9
#define PIN_CHARGER_SDA       8
#define PIN_CHARGER_SCL      40
#define PIN_BAT_VOLT_LOCAL    7   // ADC1_CH6, V14 EA6808 + 100k/100k 电池分压
#define PIN_SIDE_BUTTON       5   // V14 SW1/nQON, 10k 外部上拉，按下为 LOW
#define BATTERY_ADC_SETTLE_MS 300 // 100k/100k + 1uF: 等效 RC 约 50ms，上电后等待 >5τ
#define BATTERY_DIVIDER_TOP_OHM    100000UL
#define BATTERY_DIVIDER_BOTTOM_OHM 100000UL

#elif defined(BOARD_V10) || defined(BOARD_V11) || defined(BOARD_MICSTICK_V12)
// ───────────── v10/v11 自制 PCB / MicStick v12(source of truth: pcb/GPIO_ALLOCATION.md + Netlist_qvm_V12_NOTP22)─────────────
// v11 与 v10 引脚完全一致,唯一差异是麦克风换型(见下方 mic 分支);其余硬件改动
// (LED 供电 VBUS→VSYS / 背光 33→10Ω / J_LCD 转 180° / 电池座卧贴 B.Cu)不涉及 GPIO。
// MicStick v12(2026-07-27,VibeEverythingHardware v12.2 NOTP2 网表核对):GPIO 分配与 v11 一致,
// 差异仅 = 新增第三键 BtnC(IO47)+ LED 电源软使能 EN_LED(IO8)+ 去掉 TP4056 STDBY;
// 屏(SPI CS10/MOSI11/SCK12/DC13/RST14/BL21)、麦(PDM CLK4/DATA6)、滚轮(A16/B17/SW18,器件换接口兼容)全同。
// 电源:v12 用 LY6298 管理(EN_MCU 接芯片 EN 脚);插 USB 时 VBUS keep-alive,bringup 期间不断电。
#define PIN_POWER_ON         42  // ⚠ v10 实测(2026-06-18):GPIO42 在原理图里 NC(悬空),没接任何电源控制!
                                 //   v10 电源是自动路径:USB→D_ORING_VBUS(SS14)→VSYS;电池→Q_BAT_PATH(SI2301 自动PMOS)→VSYS。
                                 //   没有 GPIO 软控电源,也没有软件关机。驱动本脚 HIGH 是无害空操作(保留只为兼容面包板分支代码)。
#define PIN_BUTTON            1   // BtnA(Kailh PG1350 hot-swap)PTT 主键 / 短按 Enter
#define PIN_BUTTON_B         2   // BtnB:short=Esc / long=Shift+Tab
#define PIN_ENC_A           16   // EC11 A 相
#define PIN_ENC_B           17   // EC11 B 相
#define PIN_ENC_SW          18   // EC11 SW 按压
#ifdef BOARD_MICSTICK_V12
// v12 新增:第三键 BtnC(网表 BTNC→R50→U2.24=IO47)+ LED 电源软使能(EN_LED→U2.12=IO8,拉高开 VLED 供电)
#define PIN_BUTTON_C        47   // BtnC(v12 第三键;功能待定,bringup 先验通断)
#define PIN_EN_LED           8   // SK6812 电源使能(HIGH 开;v11 无此软控)
// v12 电源新能力(REQ-029):IO9=1 强制关整条 3.3V(ESP32 全断,待机 50µA),任意按键硬件唤醒。
// 链路:IO9→R24→D8→Q10.gate→拉低 EN3V3→关 U9(TMI3108 buck)。
// ⚠ 默认必须 OUTPUT LOW 锁电源;悬空/读到 HIGH = 自杀。仅 kill 流程末尾才拉 HIGH。
#define PIN_PWR_KILL         9   // 3.3V 电源软关(HIGH=关;LOW=保持)
#endif
#if defined(BOARD_V11) || defined(BOARD_MICSTICK_V12)
// v11 麦 = MSM261DHP006 PDM 顶进声(I2S 款 MSM261S4030H0R JLC 缺货换型,2026-06-26)
// 原理图接线:CLK→原 I2S_SCK 网络(GPIO4)、DATA→原 I2S_SD 网络(GPIO6)、L/R→GND(左声道);
// GPIO5(原 I2S_WS)释放空闲。I2S 外设切 PDM RX 模式,硬件 CIC 直接吐 16-bit PCM。
#define MIC_PDM              1
#define PIN_PDM_CLK          4   // MSM261DHP006 CLK(ESP32 输出,legacy 驱动占用 ws 槽位)
#define PIN_PDM_DATA         6   // MSM261DHP006 DATA(ESP32 输入)
#ifndef MIC_PDM_GAIN_SHIFT
#define MIC_PDM_GAIN_SHIFT   2   // PDM 16-bit PCM 软件增益(<<2=+12dB,带饱和),对齐 v10 ICS
                                 // 路径 32-bit>>14 的电平标定;实测过响/削波则降为 1 或 0
#endif
#else
#define I2S_SCK              4   // ICS-43434 BCLK
#define I2S_WS               5   // ICS-43434 WS / LRCLK
#define I2S_SD               6   // ICS-43434 SD(LR pin → GND 焊死左声道)
#endif
#define PIN_LED_DIN         38   // SK6812MINI-E ×4 DATA(经 SN74AHCT125 3.3→5V 缓冲)
#define PIN_LCD_BL_LOCAL    21   // LCD 背光 PWM(经 SI2302 N-MOSFET 拉 5V 背光地)
#define PIN_BAT_VOLT_LOCAL   7   // ADC1_CH6,LiPo 经 1/2 分压(2×100kΩ)
// v10 新增外设(面包板原型没有)
#define PIN_BUZZER          39   // MLT-5020 蜂鸣器(经 SI2302)
#define PIN_TP4056_CHRG     40   // TP4056 充电中 LOW(开漏,内部上拉)
#if defined(BOARD_MICSTICK_V12)
#define PIN_TP4056_STDBY    -1   // v12 网表未接 STDBY(充电指示只留 CHRG=IO40)
#else
#define PIN_TP4056_STDBY    41   // TP4056 充满 LOW(开漏,内部上拉)
#endif
#define PIN_BAT_EN          42   // ⚠ v10 NC,非电池路径开关(电池路径是自动 PMOS,见上 PIN_POWER_ON 说明)
#else
// ───────────── 面包板原型(LilyGo T-Display-S3)= 现行已验证值,勿改 ─────────────
#define PIN_POWER_ON        15   // T-Display-S3 PWR_ON,全程保持 HIGH
#define PIN_BUTTON           1   // Button A:PTT 主键 / 短按 Enter
#define PIN_BUTTON_B        21   // BtnB:short=Esc / long=Shift+Tab
#define PIN_ENC_A           16   // EC11 A 相
#define PIN_ENC_B            3   // EC11 B 相(GPIO3 strapping,EC11 静止 detent A/B 都 HIGH 不影响 boot)
#define PIN_ENC_SW          17   // EC11 SW 按压(5 脚版独立引脚)
#define I2S_SCK             11
#define I2S_WS              13
#define I2S_SD              12
#define PIN_LED_DIN          2   // GPIO2 → SN74AHCT125N(1A) → SK6812 DIN
#define PIN_LCD_BL_LOCAL    38   // 并口屏背光(T-Display-S3)
#define PIN_BAT_VOLT_LOCAL   4   // ADC 分压(>4300mV 视为 USB)
// 面包板无以下外设,占位 -1(让未来 #ifdef 代码可编译,不真用)
#define PIN_BUZZER          -1
#define PIN_TP4056_CHRG     -1
#define PIN_TP4056_STDBY    -1
#define PIN_BAT_EN          -1
#endif
