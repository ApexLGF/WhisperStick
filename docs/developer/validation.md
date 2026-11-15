# 当前验证与依赖边界

[返回开发入口](README.md)

本公开版本基于 QuickVibeHost 2.8.1、MicStick 固件 1.2.3、PCB V14 和 BLE 协议 v5。

## 验证状态

- 完整 V14 固件通过编译：Flash 1,297,885 字节 / 3 MiB，静态 RAM 60,796 字节。
- 已运行 `bash tests/test_micstick_native_suite.sh`：协议解析、输入、音量/亮度、音频 AGC、会话、OTA 等现有本机测试通过。
- `my-app-v14`、`micstick-v14-factory`、`micstick-v14-power-monitor` 三个程序均编译通过。最小示例 Flash 312,813 字节，静态 RAM 19,584 字节。构建使用本机已缓存的固定版本依赖。
- macOS App 已检查工程和构建依赖，但本次构建在 Swift Package 解析阶段被执行环境阻止：`sandbox-exec: sandbox_apply: Operation not permitted`。本次未完成 App 编译或生成新的 DMG。
- 本次未连接设备刷写，未完成 BLE、录音、ASR、输入注入、电池和恢复流程的实机验收。

## 公开 Demo 的默认行为

- 统计采集默认关闭；`AnalyticsConfig.projectToken` 为空时，即使已有用户偏好开启统计，也不会启用采集。
- Sentry 崩溃上报不启动。需要时自行配置服务与用户授权。
- App 不自动检查更新；用户手动检查仍访问官方兼容性清单和官方发行包。
- 模型下载、可选云端 ASR、Agent 集成和固件 OTA 保留现有参考实现。云服务凭证由使用者输入。
- 未附带签名证书、OTA 私钥、服务端凭证或作者本机配置。OTA 公钥属于验证接口，可以公开；自行分发 OTA 需要配置自己的密钥对。

## 构建依赖

固件工具链和库版本由 `platformio.ini` 固定。首次运行准备脚本需要联网；该脚本也修正上游字体库错误的依赖名称。

Mac App 的 `setup-frameworks.sh` 使用 HTTPS 和 SHA-256 校验。可通过 `WHISPERSTICK_FRAMEWORK_BASE_URL` 指向包含同名、同校验值归档的镜像。下载服务的长期可用性尚未由本仓库保证，本次受网络环境限制未验证从空缓存下载全部依赖。

FunASR offline bridge 目前包含在预编译框架中，仓库未提供其完整构建源码。需要完全脱离这些预编译包的开发者，可以替换 ASR 引擎；直接开发设备固件或 BLE 客户端不依赖它。

## 硬件资料中待实物确认的项目

V14 的 NTC 料号/B 值与硬件约定存在不一致，见 [硬件说明](hardware-v14.md)。这里公开寄存器状态和当前程序配置，不把尚未核实的电池温度阈值作为规格。BOOT/RST 恢复流程按网表整理，仍需在实际成品上验证测试点可接触性。
