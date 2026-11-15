# QuickVibeMicStick V14

ESP32-S3 便携交互设备的完整参考固件：屏幕、按键与旋钮、数字麦克风、RGB、蜂鸣器、电池管理和 BLE 通信。

当前基线：PCB V14，固件 **1.2.3**，BLE 应用协议 **v5**。配套参考应用为 QuickVibeHost **2.8.1**。

## 开始开发

从 [开发者指南](../docs/developer/README.md) 开始。仅开发独立固件时不需要安装 QuickVibeHost。

- [硬件配置、完整 GPIO 表与电源初始化](../docs/developer/hardware-v14.md)
- [编译、刷写、首个程序与恢复](../docs/developer/firmware-development.md)
- [BLE 接口与电脑端接入](../docs/developer/ble-protocol.md)
- [QuickVibeHost 参考应用开发](../docs/developer/host-development.md)

## 编译与刷写

安装 PlatformIO 后，在本目录执行。准备脚本修正上游字体库依赖名称，首次运行需要联网。

```bash
bash ../scripts/setup-firmware.sh micstick-v14
pio run -e micstick-v14
pio device list
pio run -e micstick-v14 -t upload --upload-port /dev/cu.usbmodemXXXX
```

将端口替换为实际端口。完整刷写与故障恢复见上述指南。

## 开发入口

| 文件 | 职责 |
| --- | --- |
| `pin_config.h` | V14 GPIO 定义 |
| `platformio.ini` | 工具链、依赖、显示参数与构建环境 |
| `QuickVibeMicStick.ino` | 初始化、输入、音频、BLE 与应用循环 |
| `charger_sgm41511.*` / `power_manager.*` | 充电、电量与运行电源管理 |
| `ui_renderer.*` / `led_manager.*` / `buzzer_fx.*` | 显示与反馈 |
| `v5_protocol.*` / `action_mode_protocol.*` | 电脑端通信与动作场景 |
| `bringup/factory_test_v14.cpp` | 外设自检参考 |

GPIO9 必须在启动最早阶段设为输出 LOW；充电驱动必须尽早初始化并持续维护。写独立程序前先阅读硬件文档中的电源约束。
