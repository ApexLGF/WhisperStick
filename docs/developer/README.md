# MicStick V14 开发者指南

拿到 MicStick V14 后，可以为它编写独立固件，也可以通过 BLE 把现有固件接到自己的应用。QuickVibeHost 与配套固件提供一套完整的语音、显示、按键和电脑交互参考实现。

## 当前开发基线

| 项目 | 配置 |
| --- | --- |
| 硬件 | QuickVibeMicStick PCB V14，板上丝印 `QVM_V14` |
| 主控 | ESP32-S3-WROOM-1-N16R8，16 MiB Flash、8 MiB OPI PSRAM |
| 固件参考实现 | 1.2.3，PlatformIO 环境 `micstick-v14` |
| 电脑端参考实现 | QuickVibeHost 2.8.1，macOS 14+；当前开发路径使用 Apple Silicon |
| 设备通信 | BLE 自定义 GATT，应用协议 v5 |
| USB | 固件下载、恢复和串口调试 |

版本来源：[VERSION](../../VERSION)、[platformio.ini](../../QuickVibeMicStick/platformio.ini)、[compatibility.json](../../Website/compatibility.json)。本文档只描述上述组合。

## 从这里开始

| 你想做什么 | 阅读文档 | 第一个可验证结果 |
| --- | --- | --- |
| 了解硬件并重新编写固件 | [硬件与 GPIO](hardware-v14.md) → [固件开发与刷写](firmware-development.md) | 屏幕显示自己的文字，按 A/B 改变数值 |
| 保留设备固件，开发自己的电脑端 | [BLE 接口](ble-protocol.md) | 收到握手回复、按键通知和音频数据 |
| 修改现有 Mac App | [QuickVibeHost 开发](host-development.md) | 本地构建 App，连接设备并完成一次录音 |

仅开发设备固件时不需要安装 Xcode、QuickVibeHost 或语音识别模型。开发自己的 BLE 客户端时，可以只实现所需的数据通道。

## 硬件能做什么

设备有 170×320 彩屏、三颗主按键、带按压的旋钮、侧键、数字麦克风、四颗可寻址 RGB 灯、蜂鸣器和电池管理。现有固件演示了语音采集、BLE 音频传输、状态显示和输入事件处理。

可以据此开发状态面板、快捷操作控制器、录音终端或其他交互设备。USB HID、USB MIDI、BLE HID、Wi-Fi/MQTT 属于需要另行实现的应用方向；当前参考固件没有提供这些现成接口。

## 开发完成的检查点

1. 能从源码构建，并通过 USB 刷写及恢复参考固件。
2. GPIO9、电源初始化、充电器配置与所用外设符合 [硬件约束](hardware-v14.md)。
3. 按键、屏幕、音频等实际使用的功能，在 USB 和目标供电方式下均正常。
4. 若兼容 QuickVibeHost，完成 BLE 握手、通知订阅、录音开始/停止及断线重连验证。

本组文档按当前源码、V14 硬件资料和构建配置整理。涉及电气参数的修改，应结合实际设备测量；资料不能替代实机验证。代码和文档的使用授权以发布仓库中的许可证为准。
