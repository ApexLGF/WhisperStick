# 固件开发、刷写与恢复

[返回开发入口](README.md)

## 1. 准备环境

准备 MicStick V14、可传输数据的 USB-C 线和电脑。安装 PlatformIO Core 或 VS Code 的 PlatformIO 扩展；命令行确认 `pio --version` 可运行。安装方法见 [PlatformIO 文档](https://docs.platformio.org/en/latest/core/installation/index.html)。

在下载或克隆的仓库根目录操作。需要联网下载首次构建依赖；固件开发不需要 Mac App 或云端 API Key。

| 依赖 | 当前配置 |
| --- | --- |
| PlatformIO 平台 | `espressif32 @ ~6.7.0` |
| Arduino ESP32 | `3.20014.231204`，对应 Arduino 2.0.14 |
| 语言 | GNU C++17 |
| TFT_eSPI | 2.5.43 |
| NimBLE-Arduino | 2.5.0 |
| Adafruit NeoPixel | 1.12.3 |
| U8g2_for_TFT_eSPI | commit `a170ef8b6d8414b1ee2ecc97b5b913e08f5597ac` |

依赖和板级参数由 [platformio.ini](../../QuickVibeMicStick/platformio.ini) 提供。默认环境为 `micstick-v14`；命令中仍显式指定环境，便于区分完整固件和最小示例。Arduino 3.x 的外设 API 不属于当前文档的构建基线。

## 2. 先构建并运行完整参考固件

```bash
./scripts/setup-firmware.sh micstick-v14
cd QuickVibeMicStick
pio run -e micstick-v14
pio device list
```

产物在 `.pio/build/micstick-v14/`。`firmware.bin` 为 app 镜像，`bootloader.bin` 和 `partitions.bin` 用于完整刷写。单个 app 上限为 3 MiB。

把下列端口替换为 `pio device list` 中的实际端口；macOS 通常为 `/dev/cu.usbmodem...`，Linux 通常为 `/dev/ttyACM...`，Windows 为 `COM...`。

```bash
pio run -e micstick-v14 -t upload --upload-port /dev/cu.usbmodemXXXX
pio device monitor --port /dev/cu.usbmodemXXXX --baud 115200 --dtr 0 --rts 0
```

刷写前关闭其他串口监视器。复位后 USB 端口名称可能变化，重新执行 `pio device list`。正常启动应出现 `MicStick-XXXX` 广播，串口报告 V14 与充电器状态。

PlatformIO 的 USB upload 写入以下四段内容；它不等于擦除整片 Flash，NVS 设置可能保留。

| 地址 | 文件 |
| --- | --- |
| `0x0` | `bootloader.bin` |
| `0x8000` | `partitions.bin` |
| `0xe000` | 当前 Arduino 框架附带的 `boot_app0.bin` |
| `0x10000` | `firmware.bin` |

首次开发、恢复参考程序或更换分区表时使用完整刷写。仅向 `0x10000` 写入 app 不能复位 OTA 活动分区，因此不把这种 app-only 操作作为通用恢复步骤。

## 3. 先验证所用外设

当前仓库提供两个可独立构建的 V14 程序：

| 环境 | 用途 | 代码 |
| --- | --- | --- |
| `micstick-v14-power-monitor` | 屏幕显示充电器寄存器、电池 ADC 和输入电源状态 | [sgm41511_monitor.cpp](../../QuickVibeMicStick/bringup/sgm41511_monitor.cpp) |
| `micstick-v14-factory` | 屏幕、按键、旋钮、麦克风、RGB、蜂鸣器和 BLE 基础检查 | [factory_test_v14.cpp](../../QuickVibeMicStick/bringup/factory_test_v14.cpp) |

例如：

```bash
pio run -e micstick-v14-factory -t upload --upload-port /dev/cu.usbmodemXXXX
```

按屏幕提示操作；结束后按第 2 节刷回 `micstick-v14`。工厂程序的屏幕/灯/声音项目需要人确认，程序运行成功不等于这些外设已经通过测试。开发入门不需要执行运输模式或断电专项测试。

## 4. 编写自己的第一段程序

仓库已经提供 `QuickVibeMicStick/bringup/my_app.cpp`，内容如下。它保留充电器初始化，显示文字，并用 A/B 键修改屏幕上的数值。它是 **USB 连接下的开发示例**；电池独立运行应接入完整电源策略。

```cpp
#include <Arduino.h>
#include <TFT_eSPI.h>
#include <Adafruit_NeoPixel.h>
#include "pin_config.h"
#include "charger_sgm41511.h"

TFT_eSPI display;
Adafruit_NeoPixel pixels(4, PIN_LED_DIN, NEO_GRB + NEO_KHZ800);
int value = 0;
bool lastA = false;
bool lastB = false;
bool ready = false;
uint32_t lastScan = 0;

void redraw() {
    display.fillScreen(TFT_BLACK);
    display.setTextColor(TFT_WHITE, TFT_BLACK);
    display.setTextSize(2);
    display.setCursor(8, 20);
    display.println("My MicStick");
    display.setCursor(8, 60);
    display.printf("Value: %d", value);
}

void setup() {
    pinMode(PIN_PWR_KILL, OUTPUT);
    digitalWrite(PIN_PWR_KILL, LOW);
    pinMode(PIN_LCD_BL_LOCAL, OUTPUT);
    digitalWrite(PIN_LCD_BL_LOCAL, LOW);
    pinMode(PIN_BUZZER, OUTPUT);
    digitalWrite(PIN_BUZZER, LOW);
    const bool chargerOK = sgm41511_begin(PIN_CHARGER_SDA, PIN_CHARGER_SCL);

    Serial.begin(115200);
    Serial.setTxTimeoutMs(0);
    pixels.begin();
    pixels.clear();
    pixels.show();
    if (!chargerOK) {
        Serial.println("Charger init failed; stop and check hardware.");
        return;
    }
    if (!sgm41511_snapshot().vbusGood) {
        digitalWrite(PIN_PWR_KILL, HIGH);  // 此示例仅在 USB 供电时运行。
        return;
    }
    pinMode(PIN_BUTTON, INPUT_PULLUP);
    pinMode(PIN_BUTTON_B, INPUT_PULLUP);
    display.init();
    display.setRotation(0);
    redraw();
    digitalWrite(PIN_LCD_BL_LOCAL, HIGH);
    ready = true;
}

void loop() {
    if (!ready) { delay(20); return; }
    sgm41511_tick();
    const auto &power = sgm41511_snapshot();
    if (!power.reachable || !power.configured || !power.vbusGood) {
        digitalWrite(PIN_LCD_BL_LOCAL, LOW);
        ready = false;
        digitalWrite(PIN_PWR_KILL, HIGH);
        return;
    }
    if (millis() - lastScan < 30) { delay(1); return; }
    lastScan = millis();
    const bool a = digitalRead(PIN_BUTTON) == LOW;
    const bool b = digitalRead(PIN_BUTTON_B) == LOW;
    const bool changed = (a && !lastA) || (b && !lastB);
    if (a && !lastA) ++value;
    if (b && !lastB) --value;
    lastA = a;
    lastB = b;
    if (changed) redraw();
}
```

同目录 `platformio.ini` 已包含独立构建环境：

```ini
[env:my-app-v14]
extends = env:micstick-v14
build_src_filter = -<*> +<bringup/my_app.cpp> +<charger_sgm41511.cpp>
lib_deps =
    bodmer/TFT_eSPI @ 2.5.43
    adafruit/Adafruit NeoPixel @ 1.12.3
```

然后执行：

```bash
pio run -e my-app-v14
pio run -e my-app-v14 -t upload --upload-port /dev/cu.usbmodemXXXX
```

`build_src_filter` 确保只编译你的入口和充电驱动，避免两份 `setup()` / `loop()` 冲突；正式环境会排除 `bringup/`。这段示例采用简单的 30 ms 输入扫描，产品化手势应使用消抖状态机。

增加功能时按 [硬件表](hardware-v14.md) 逐项加入：先 C 键与旋钮，再 RGB/蜂鸣器，再音频和通信。麦克风初始化参考正式程序的 `installI2S()`；完整外设检查参考工厂程序。使用板载外设本身不要求实现 QuickVibeHost 协议。

## 5. 无法正常刷写时恢复

先换数据线、确认 USB 端口与 3.3 V 供电，关闭占用串口的程序。若自定义固件关闭了 USB、启动崩溃或无法自动进入下载模式，可使用 PCB 的 BOOT/RST/GND 测试点。

1. 根据 [PCB 定位图](hardware-v14.md) 确认测试点；BOOT 接 GPIO0，RST 接 MCU EN。
2. 让设备保持 USB 供电，将 BOOT 接 GND。
3. 将 RST 短暂接 GND 后释放；复位采样时保持 BOOT 为 LOW。
4. 电脑识别下载端口后释放 BOOT，重新列出串口并完整刷写参考固件。
5. 断开测试点连线，正常复位；必要时重新插 USB、按主键启动。

这是根据 V14 网表及 ESP32-S3 ROM 下载机制给出的恢复步骤。GPIO46 必须保持低或悬空的下载允许状态；成品测试点的实际可接触性和恢复流程需在设备上验证。侧面 SW1 是 nQON/输入键，不能当作 MCU 的 RST 或 BOOT。

不要触碰相邻电源测试点或写入 eFuse、启用 Flash 加密来尝试修复普通刷写失败。相关参考：[Espressif 下载模式说明](https://docs.espressif.com/projects/esptool/en/latest/esp32s3/advanced-topics/boot-mode-selection.html)。

## 6. USB 开发与 BLE OTA

自行编译的固件优先走 USB。当前 BLE OTA 校验目标硬件、协议、SHA-256 和 ECDSA P-256 签名，不能直接用官方 OTA 通道安装任意自编译镜像。

若为自己的产品建立 OTA，需要管理自己的签名密钥、公钥与主机校验逻辑，并先通过 USB 安装相应固件。保留 OTA 时还要保留新镜像健康确认流程；只改 UI 或协议不应随意改分区表。实现入口为 [micstick_ota.cpp](../../QuickVibeMicStick/micstick_ota.cpp) 和 [micstick_ota_protocol.h](../../QuickVibeMicStick/micstick_ota_protocol.h)。

## 7. 排错

| 现象 | 优先检查 |
| --- | --- |
| 一上电就掉电 | GPIO9 是否在最开始设为 OUTPUT LOW |
| 有串口但屏幕黑 | V14 构建环境、SPI 引脚、GPIO21 背光 |
| 屏幕颜色不对 | BGR、反色参数与 TFT_eSPI 版本 |
| 麦克风全零 | PDM 模式、GPIO4/6、左声道、`DSR_16S` |
| 插拔 USB 后充电状态异常 | `sgm41511_tick()` 是否持续运行、寄存器是否读回成功 |
| 自定义程序收不到按键 | LOW 有效、上拉、引脚宏、消抖与主循环是否阻塞 |
| Host 连接后断开 | 协议 v5 握手、通知订阅、硬件能力回复 |
| 刷写成功但仍运行另一程序 | OTA 活动分区；使用完整刷写恢复 |

做电池应用前验证 USB 拔插、低电量、长时间空闲、唤醒与恢复；做音频应用前验证连续录音、结束通知和丢包处理。本文的编译与协议示例不能替代这些实机检查。
