# QuickVibeHost 参考应用开发

[返回开发入口](README.md)

QuickVibeHost 2.8.1 是 macOS 端完整参考应用，负责 BLE 连接、音频解码、语音识别、文字输入与设备状态同步。只编写设备固件，或开发自己的 BLE 客户端时，不需要编译它。

## 1. 构建条件

- Apple Silicon Mac、macOS 14 或更高版本。
- 完整 Xcode 和相应 macOS SDK；使用当前代码能编译的 Xcode 版本，不仅安装 Command Line Tools。
- 联网获取 Swift Package 和本地 ASR 的预编译框架。

本地 FunASR 框架包含 arm64 产物，因此这里提供 arm64 开发命令；本文不承诺 Intel Mac 构建支持。

在仓库根目录执行：

```bash
cd QuickVibeHost
./setup-frameworks.sh
open QuickVibeHost.xcodeproj
```

`setup-frameworks.sh` 下载并校验 ONNX Runtime、FunASR 和 Sherpa-ONNX 框架，放到 `ThirdParty/`；这些大文件不由 Git 提供。框架来自脚本内固定的下载地址，需对应服务可访问。模型权重由 App 内的模型管理器另行下载，不是上述框架的一部分。

在 Xcode 选择 `QuickVibeHost` scheme、My Mac，使用本地开发签名或自己的开发身份。第三方许可证随相应依赖保留。

## 2. 命令行本地构建

以下命令在 `QuickVibeHost/` 目录执行，输出到仓库内 `build-developer/`：

```bash
xcodebuild \
  -project QuickVibeHost.xcodeproj \
  -scheme QuickVibeHost \
  -configuration Debug \
  -destination 'platform=macOS,arch=arm64' \
  -derivedDataPath build-developer \
  build \
  ARCHS=arm64 \
  CODE_SIGN_IDENTITY=- \
  CODE_SIGN_STYLE=Manual \
  DEVELOPMENT_TEAM=""
```

产物为 `build-developer/Build/Products/Debug/QuickVibeHost.app`。本地 ad-hoc 签名用于开发运行；对外分发的签名和公证是另一个发布流程。该命令无需项目作者的签名证书或发布服务凭证。

`ThirdParty/ccusage/ccusage` 是工程嵌入的 helper，构建时也需要它；保留 [ThirdParty/ccusage](../../QuickVibeHost/ThirdParty/ccusage) 及其说明和许可证。`ApprovalKit` 和 `ChineseITN` 等本地模块也须随源码提供，不要只拷贝 `.swift` 文件。

首次依赖解析失败时，先检查网络、`Package.resolved` 和预编译框架目录；不要通过删除依赖引用来掩盖缺失模块。

## 3. 运行与权限

退出其他 QuickVibeHost 实例后启动自己的构建，通过设备页连接 `MicStick-XXXX`。按应用实际使用的能力授权：

| 权限/设置 | 何时需要 |
| --- | --- |
| 蓝牙 | 搜索、连接和传输设备数据 |
| 麦克风 | 使用电脑自身麦克风录音 |
| 辅助功能 / 输入监控 | 所选文字注入、快捷键或目标应用交互路径要求时 |
| 自动化 | 控制其他应用且系统弹出授权时 |
| ASR 模型 | 使用本地语音识别时，在设置中完成模型下载 |
| 云服务凭证 | 选择相应云端识别或后处理服务时，由使用者自己配置 |

仅 BLE 收音不等于能完成文字注入。先在 App 中确认音频和识别结果，再测试目标应用。频繁更换签名或 App 路径后，macOS 可能要求重新授权。

## 4. 从哪里改起

| 要修改的能力 | 主要代码 |
| --- | --- |
| 发现设备、握手、通知、下发状态 | [BLEManager.swift](../../QuickVibeHost/QuickVibeHost/BLEManager.swift) |
| 音频解码 | [ADPCMDecoder.swift](../../QuickVibeHost/QuickVibeHost/ADPCMDecoder.swift) |
| 电脑麦采集 | [AudioCaptureManager.swift](../../QuickVibeHost/QuickVibeHost/AudioCaptureManager.swift) |
| 中文本地 ASR | [FunASRSeacoEngine.swift](../../QuickVibeHost/QuickVibeHost/FunASRSeacoEngine.swift)、`ASRModelManager.swift` |
| 英文本地 ASR | [SherpaEnglishEngine.swift](../../QuickVibeHost/QuickVibeHost/SherpaEnglishEngine.swift)、`EnglishASRModelManager.swift` |
| 云端 ASR | [DoubaoASRClient.swift](../../QuickVibeHost/QuickVibeHost/DoubaoASRClient.swift) |
| 输入目标与路由 | [InputRouter.swift](../../QuickVibeHost/QuickVibeHost/InputRouter.swift)、`KeyboardSimulator.swift` |
| 自定义动作场景 | [DeviceActionModeController.swift](../../QuickVibeHost/QuickVibeHost/DeviceActionModeController.swift)、`DeviceActionMode.swift` |
| 主界面与设置 | [ContentView.swift](../../QuickVibeHost/QuickVibeHost/ContentView.swift)、`SettingsTab.swift` |

新增场景时，先定义“设备事件对应什么应用动作”，再修改动作控制器或输入路由。若现有事件已经够用，可保持固件不变；需要新的采集/交互能力时，再同时修改设备端和 [BLE 协议](ble-protocol.md)。

公开 Demo 已关闭统计采集、Sentry 上报和 App 自动检查更新。模型下载、用户主动发起的官方更新检查和 Agent 集成保留原有实现。分发派生应用前配置自己的端点、应用标识与用户设置。当前构建验证结果、预编译依赖边界见 [验证说明](validation.md)。

## 5. 最小联调流程

1. 连接 V14，确认协议握手成功，设备信息返回硬件版本 14。
2. 选择设备麦，按 A 录音并停止，确认音频解码及 ASR 返回结果。
3. 测试 A/B/旋钮等实际使用的输入事件。
4. 测试一次自定义动作或向自己的目标应用输入文字。
5. 断开并重新连接，确认配置重新下发、录音状态恢复正常。

构建成功只能证明代码和依赖通过编译；蓝牙、系统权限、麦克风、输入注入和固件 OTA 必须在实际设备上分别验证。
