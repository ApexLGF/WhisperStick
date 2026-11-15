# WhisperStick

**拿到 MicStick V14，运行参考 Demo，再开发你自己的硬件应用。**

WhisperStick 提供 ESP32-S3 交互设备的固件、QuickVibeHost macOS 参考应用，以及 GPIO、电源、显示、音频和 BLE 开发文档。可以把它改造成状态面板、快捷控制器、录音终端或其他交互工具。

This repository contains the current MicStick V14 firmware, the QuickVibeHost macOS reference app, and hardware/interface documentation. Start with the [developer guide](docs/developer/README.md). The source directories retain their existing product names.

## 当前基线

| 组成 | 当前版本 / 配置 |
| --- | --- |
| 硬件 | MicStick PCB V14，ESP32-S3-WROOM-1-N16R8 |
| 内存 | 16 MiB Flash，8 MiB OPI PSRAM |
| 交互 | 170×320 彩屏、三颗主按键、旋钮与按压、侧键 |
| 音频与反馈 | PDM 数字麦克风、4 颗 RGB 灯、蜂鸣器 |
| 供电 | USB-C / 锂电池，SGM41511 充电管理 |
| 固件 | 1.2.3，PlatformIO `micstick-v14` |
| Mac App | QuickVibeHost 2.8.1，macOS 14+，Apple Silicon 开发路径 |
| 通信 | BLE GATT，应用协议 v5；USB 用于刷写与调试 |

## 从这里开始

| 目标 | 文档 |
| --- | --- |
| 确认硬件、接线和 GPIO | [硬件配置与引脚表](docs/developer/hardware-v14.md) |
| 构建、刷写、恢复设备 | [固件开发](docs/developer/firmware-development.md) |
| 写自己的第一个硬件程序 | [按键与屏幕示例](QuickVibeMicStick/bringup/my_app.cpp) |
| 用自己的程序连接现有固件 | [BLE 接口](docs/developer/ble-protocol.md) |
| 修改 Mac App | [QuickVibeHost 开发](docs/developer/host-development.md) |

## 运行固件 Demo

安装 [PlatformIO Core](https://docs.platformio.org/en/latest/core/installation/index.html)、Python 3 和 Git，然后执行：

```bash
git clone https://github.com/ApexLGF/WhisperStick.git
cd WhisperStick
bash scripts/setup-firmware.sh micstick-v14
cd QuickVibeMicStick
pio run -e micstick-v14
pio device list
pio run -e micstick-v14 -t upload --upload-port /dev/cu.usbmodemXXXX
```

替换为实际串口：macOS 常见 `/dev/cu.usbmodem...`，Linux 常见 `/dev/ttyACM...`，Windows 为 `COM...`。Windows 可在 Git Bash 执行准备脚本。第一次安装依赖需要联网。

固件默认环境已经设为 V14。准备脚本锁定依赖，并修正上游字体库的依赖名称；它不刷写硬件。刷写前确认板上丝印为 `QVM_V14`。

最小示例通过 A/B 按键改变屏幕数值，可独立于 App、BLE 和语音模型运行：

```bash
# 在仓库根目录执行
bash scripts/setup-firmware.sh my-app-v14
cd QuickVibeMicStick
pio run -e my-app-v14
pio run -e my-app-v14 -t upload --upload-port /dev/cu.usbmodemXXXX
```

该示例仅用于 USB 供电下开发。电池应用需要保留充电器维护与低电量关机策略，具体见硬件和固件文档。

## 运行 Mac App Demo

```bash
cd QuickVibeHost
./setup-frameworks.sh
open QuickVibeHost.xcodeproj
```

在 Xcode 使用自己的本地开发签名。无需作者的签名证书或云服务账户；云端 ASR 凭证由使用者自行配置。本地 ASR 依赖下载的预编译框架和模型，下载地址与 SHA-256 固定在脚本中。完整构建命令和权限设置见 [App 文档](docs/developer/host-development.md)。

公开 Demo 关闭崩溃上报与统计采集，关闭自动检查 App 更新。手动检查更新仍指向官方发行版，可能替换你的开发构建。服务依赖、当前验证结果和已知限制见 [验证说明](docs/developer/validation.md)。

## 仓库内容

- `QuickVibeMicStick/`：完整 V14 固件、外设诊断与最小示例。
- `QuickVibeHost/`：macOS App、资源、本地 Swift 模块和第三方声明。
- `docs/developer/`：硬件/GPIO、开发、通信和刷写说明。
- `tests/`：可在电脑上运行的固件协议测试入口。
- `licenses/`、`THIRD_PARTY_NOTICES.md`：第三方授权说明。

硬件资料覆盖使用现有 V14 设备所需的接口和约束。本仓库未提供用于生产电路板的 CAD/Gerber/BOM 工程包。

## 许可证与贡献

原创代码和开发文档采用 [Apache-2.0](LICENSE)。第三方库、字体和其他已有授权组件继续遵循各自许可证，见 [THIRD_PARTY_NOTICES.md](THIRD_PARTY_NOTICES.md)。项目和第三方名称、标志的商标权不由此授予。

欢迎提交 Issue 描述新场景、硬件版本、复现步骤与日志；提交 PR 时说明修改内容、构建命令与实机验证结果。请不要提交 API Key、设备私钥、签名证书或个人会话日志。
