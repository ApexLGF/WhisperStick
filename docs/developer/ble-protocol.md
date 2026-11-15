# BLE 接口与电脑端接入

[返回开发入口](README.md)

适用：MicStick V14 固件 1.2.3，应用协议 v5。该接口可供自己的电脑端、移动端或网关使用；不依赖 QuickVibeHost 的 UI。自行开发独立固件时可定义自己的协议。

## 1. 服务发现与握手

设备广播名为 `MicStick-XXXX`。客户端应通过服务 UUID 识别设备，并让用户在多台设备之间选择。连接前关闭其他正在连接该设备的 Host。

| 用途 | UUID | 属性 |
| --- | --- | --- |
| 主服务 | `19b10000-e8f2-537e-4f6c-d104768a1214` | Service |
| Audio Data | `19b10001-e8f2-537e-4f6c-d104768a1214` | Notify |
| Control | `19b10002-e8f2-537e-4f6c-d104768a1214` | Write、Notify |
| Status | `19b10003-e8f2-537e-4f6c-d104768a1214` | Write、Notify |
| Permission Request | `19b10004-e8f2-537e-4f6c-d104768a1214` | Write、Notify；最小接入不需要 |
| Permission Response | `19b10005-e8f2-537e-4f6c-d104768a1214` | Read、Indicate；当前审批响应使用 Control |
| OTA 服务 | `19b10010-e8f2-537e-4f6c-d104768a1214` | Service |
| OTA Control | `19b10011-e8f2-537e-4f6c-d104768a1214` | Write，要求加密链路 |
| OTA Data | `19b10012-e8f2-537e-4f6c-d104768a1214` | Write Without Response，要求加密链路 |
| OTA Status | `19b10013-e8f2-537e-4f6c-d104768a1214` | Read、Notify |

最小连接流程：发现主服务及特征，订阅 Control 和 Audio Data 通知，等待订阅完成，然后向 Control 写入 `20 05`，应收到 `20 05`。普通控制命令与 Status 使用 Write With Response；串行发送，等待写完成再继续。

再向 Control 写入 `3A`，设备回复 6 字节：

```text
3B buzzerPercent ledPercent hardwareRevision capabilities maxAgents
```

本基线的后三字节为 `0E 3F 04`，分别表示 V14、能力位图和最多 4 张 Agent 卡片。音量与亮度来自设备设置。断线重连后重新发现、订阅、握手并发送所需配置。

设备请求 MTU 512，实际协商值由两端决定。控制/状态帧应作为完整的特征值写入；较长写入需由客户端 BLE 栈正确处理。不要把一个 Status 帧自行拆成多次普通写入，固件没有通用的 Status 分片拼接器。

## 2. 配置与最小联调数据

所有数字用小端字节序，字符串用 UTF-8，长度表示字节数。以下十六进制内容应作为二进制字节发送，不是 ASCII 文本。

| 写入特征 | 字节 | 预期行为 |
| --- | --- | --- |
| Control | `20 05` | 握手，回复 `20 05` |
| Control | `3A` | 回复硬件版本、能力、音量与亮度 |
| Status | `53 00 00 00 01 00` | PTT、无自定义 Prompt、设备麦、简体中文、实验功能关闭 |
| Status | `54 1C 02` | 设备时间设为 09:00，540 分钟=`0x021C` |
| Control | `38 08` | RGB 亮度设为 8% |
| Control | `06 01` | 为 buttonId=1 显示识别成功反馈 |

配置帧格式：

```text
53 voiceMode promptCount
   {titleLen titleUtf8} × promptCount
   micSource language laboratoryFeatures
```

`voiceMode` 为 0=PTT、1=点击开始/停止；`promptCount` 最大 8，每个标题最大 24 字节；`micSource` 为 0=设备麦、1=电脑麦；`language` 为 0=英文、1=简中、2=繁中。最小客户端将 `laboratoryFeatures` 设为 0。

## 3. 按键与动作事件

这些是参考固件发出的应用事件；物理按键在不同界面中的作用由固件状态机决定。需要每个按键的原始电平/边沿时，应修改输入层，而不能把此表当成通用 GPIO 事件协议。

| Control Notify | 含义 |
| --- | --- |
| `10` | Enter |
| `11` | Escape |
| `12` | Shift+Tab |
| `13` | Backspace |
| `14` | 本次 PTT 结束，设备麦/电脑麦共用 |
| `15` / `16` / `17` / `18` | 上 / 下 / 左 / 右 |
| `19` | 电脑麦模式的 PTT 开始 |
| `21` | 设备请求客户端重新发送状态 |
| `30 index` | 选择 Prompt；扩展场景可能带 requestId |
| `32 sessionIndex` | 切换会话直通选择 |
| `34 mode ...` | 设备界面模式变化；部分模式带 requestId |
| `3C context control gesture delta` | 动作模式中的语义输入事件 |

`3C` 中 `control` 为 B=1、C=2、旋钮/按压 D=3；`gesture` 为单击=1、双击=2、长按开始=3、长按结束=4、旋转=5、重复=6；`delta` 按有符号 int8 解释。

客户端可在 Status 特征发送自定义动作界面：

```text
57 modeId titleLen title
   line1Len line1 line2Len line2 line3Len line3
   footerLen footer
```

自定义场景使用 `modeId=1`；标题最大 24 字节，三行说明和页脚各最大 48 字节；空字符串仍保留一个值为 0 的长度字节。`57 00` 退出动作模式。客户端收到 `3C` 后自行执行应用操作。

例如下面的短帧展示标题 `Demo` 与三行 `B`、`C`、`D`，页脚为空：

```text
57 01 04 44 65 6D 6F 01 42 01 43 01 44 00
```

解析入口：[action_mode_protocol.h](../../QuickVibeMicStick/action_mode_protocol.h) / [.cpp](../../QuickVibeMicStick/action_mode_protocol.cpp)。首次接入先使用短文本，确认整帧写入和动作回调后再扩展界面。

## 4. 语音采集与解码

设备麦模式按 A 开始 PTT 后，从 Audio Data 收到音频；当前流程没有单独的设备麦开始通知。每次录音序号从 0 开始。停止时 Control 通知 `14`；客户端应考虑末尾音频通知的到达时序，再结束本次识别。

电脑麦模式不上传设备音频，收到 `19` 后启动电脑采集，收到 `14` 后结束。当前固件的正常 PTT 由设备按键触发，不应靠写入 `01` / `02` 来实现远程开始/停止。

每个完整音频包为 261 字节：

| 偏移 | 字节数 | 字段 |
| ---: | ---: | --- |
| 0 | 2 | 固定头 `AA 55` |
| 2 | 1 | `buttonId=01` |
| 3 | 2 | `seq`，uint16，小端 |
| 5 | 256 | IMA ADPCM 数据，每字节两个采样 |

解码结果为 16 kHz、16 bit、有符号单声道 PCM。每字节先解低 4 bit，再解高 4 bit；256 字节得到 512 个采样，约 32 ms。编码器的 predictor/index 在一次录音开始时归零，之后跨包连续保留；解码器也必须这样做。

这是连续 ADPCM 码流的自定义包，不含每包 predictor/index，也不是标准 WAV ADPCM block。掉包会破坏后续解码状态，不能把下一包当成独立块无损恢复。检查序号并给本次录音标记异常；下一次录音重新复位解码器。

当 `MTU-3 < 261` 时，同一音频包会被拆成多次通知，没有额外分片头。客户端要缓存字节、组出完整包并校验头和序号，不能将每次通知当作一整包。参考实现：[ADPCMDecoder.swift](../../QuickVibeHost/QuickVibeHost/ADPCMDecoder.swift) 和 [BLEManager.swift](../../QuickVibeHost/QuickVibeHost/BLEManager.swift) 的音频接收路径。

识别成功向 Control 写 `[06,01]`，失败写 `[07,01,errorUtf8...]`。`03` / `04` / `05` 是处理状态命令；当前固件收到它们主要记录日志，实际成功/失败 UI 反馈使用 `06` / `07`。

## 5. 状态显示与扩展接口

| Status 首字节 | 功能 | 实现入口 |
| --- | --- | --- |
| `51` | 会话列表，最多 12 个 | `v5_protocol.*` |
| `52` | Agent 用量与名称，当前显示最多 4 个 | `v5_protocol.*`、`ui_model.h` |
| `53` | 录音/语言/Prompt 配置 | 本文第 2 节 |
| `54` | 当日分钟数，小端 uint16，范围 0～1439 | 本文第 2 节 |
| `55` / `56` | 审批请求 / 完成 | [审批协议](../approval-protocol-v1.md) |
| `57` | 动作模式界面 | 本文第 3 节 |
| `58` / `59` | Prompt 推荐 / 输入助手 | `v5_protocol.*` |
| `5A` | 任务生命周期事件 | [task_lifecycle_protocol.h](../../QuickVibeMicStick/task_lifecycle_protocol.h) |
| `5B` | 应用切换器 | [application_switcher_protocol.h](../../QuickVibeMicStick/application_switcher_protocol.h) |

会话列表基础格式为 `[51,exclusiveIndex,count] + count×{agentId,state,ctxPct,colorIndex,nameLen,name} + [inactiveStart]`；无选中项或无非活跃组时用 `FF`。QuickVibeHost 将会话名截到 20 字节且不拆断 UTF-8 字符。

复杂帧的完整字段和边界应直接参考 [v5_protocol.h](../../QuickVibeMicStick/v5_protocol.h)、[v5_protocol.cpp](../../QuickVibeMicStick/v5_protocol.cpp) 与 Host 对应的 `sendV5*` 方法。只做按键/音频接入时无需实现全部 Agent、审批与应用切换功能。

## 6. OTA 与权限边界

OTA 是独立服务，签名、公钥、镜像校验和分区约束见 [固件开发指南](firmware-development.md)。基础客户端可以不接入 OTA。

主服务的普通按键、音频和状态特征当前未声明加密写入要求；不要把连接建立或 v5 握手当作操作者身份认证。涉及设备控制、审批或其他高权限操作的新场景，应在自己的应用中设计配对、授权和确认策略。
