# 审批协议 v1

> 本文件是 0x55/0x36/0x56 三帧与两侧状态机的**唯一权威定义**。C++(固件)与 Swift(Mac)实现、测试向量均以此为准;改协议先改本文件与向量,再改实现。

## 1. 帧定义

字节序:多字节字段一律 **little-endian**。

### 1.1 `0x55 APPROVAL_REQUEST`(Mac → 设备)

| 偏移 | 字段 | 类型 | 约束 |
|---|---|---|---|
| 0 | magic | u8 | =0x55 |
| 1 | frameVer | u8 | =1;**≠1 整帧丢弃(decode error)** |
| 2..3 | reqId | u16le | 任意;0 合法 |
| 4 | agentId | u8 | 0=ClaudeCode 1=Codex;**未知值合法**(显示回落通用图标) |
| 5 | riskLevel | u8 | 0/1/2;**>2 按 2 处理**(保守) |
| 6..7 | expiresInSec | u16le | 0 = 立即过期(合法,用于测试) |
| 8 | flags | u8 | bit0=truncated bit1=notifyOnly bit2=alwaysDisabled;**bit3..7 解码时忽略** |
| 9 | sessNameLen | u8 | ≤24;**>24 → decode error** |
| 10.. | sessName | bytes | UTF-8(codec 不校验 UTF-8 合法性,渲染层负责) |
| . | toolLen | u8 | ≤64;**>64 → decode error** |
| . | tool | bytes | UTF-8 |
| . | bodyLen | u16le | ≤256;**>256 → decode error** |
| . | body | bytes | UTF-8 |

- **总长必须精确等于** `13 + sessNameLen + toolLen + bodyLen`(固定头 10B 至 sessNameLen 止 + toolLen 1B + bodyLen 2B);长度不符(截尾/尾部多余字节)→ decode error,整帧丢弃。
- 编码侧(Mac/test-server):字段超限直接拒绝编码(编程错误),不做静默截断——截断是上层(Registry 推送前)的职责,codec 只管格式。

### 1.2 `0x36 CMD_APPROVAL_RESPONSE`(设备 → Mac,control char)

| 偏移 | 字段 | 约束 |
|---|---|---|
| 0 | magic=0x36 | |
| 1..2 | reqId u16le | |
| 3 | decision u8 | 0=deny 1=allow 2=dismiss 3=always_allow;**>3 → decode error(Mac 丢弃)** |

总长必须 =4。

### 1.3 `0x56 APPROVAL_RESOLVED`(Mac → 设备)

| 偏移 | 字段 | 约束 |
|---|---|---|
| 0 | magic=0x56 | |
| 1..2 | reqId u16le | |
| 3 | outcome u8 | 0=judged_allow 1=judged_deny 2=resolved_elsewhere 3=expired 4=auto_allowed 5=cancelled;**未知值合法,按 2 处理**(前向兼容:无论何种 outcome 设备都删条目) |

总长必须 =4。

## 2. ack / 重发 / 幂等契约

1. 设备发 `0x36(decision=allow/deny/always_allow)` 后**不删条目**,进入 `SENT_AWAITING_ACK`;收到**任意 outcome** 的对应 `0x56` 才删。
2. `SENT_AWAITING_ACK` 下 **500ms** 未收到 0x56 → 重发同一 0x36;**最多重发 3 次**(共发 4 帧);之后进入 `SEND_FAILED`(条目保留、可视,等 0x56 或过期兜底)。
3. **`dismiss` 例外**:设备本地立即删条目,0x36(dismiss) 单发不重发、不等 ack;Mac 收到后仅标记 deviceDismissed(停止对该 reqId 的一切推送),**不回 0x56**、不判决。丢包最坏后果 = Mac 侧仍认为可推(但本设计 Mac 不重复推送同一 reqId,故无实际影响)。
4. Mac 端幂等:每个 reqId 有终态记录;对已终态/未知 reqId 的 0x36 **静默吞**(零判决副作用)并回 `0x56(outcome=2)`;对同一 reqId 的重复 0x36(重发)只判决一次,每次都回 0x56。
5. 设备对未知 reqId 的 0x56 静默忽略。

## 3. 设备侧队列状态机(`ApprovalQueue`,纯逻辑、时间由外部传入)

- 容量 **8**;满时**淘汰最早入队**的条目(含 SENT_AWAITING_ACK 状态的——迟到判决由 Mac 幂等层兜住)。
- `push(frame, nowMs)`:reqId 已存在 → **原地更新**内容并重置过期时间(状态回 ACTIVE,除非该条已在 SENT_AWAITING_ACK —— 该情况忽略更新,判决优先)。返回事件 `ARRIVED`(新条目)或 `UPDATED`。
- `decide(reqId, decision, nowMs)`:仅 ACTIVE 且 !notifyOnly 且 !(decision==always_allow && alwaysDisabled) 且 !(decision==allow && riskLevel==2) 且 !(decision==always_allow && riskLevel==2) 时合法 → 状态 SENT_AWAITING_ACK,输出"发送 0x36"动作。deny 在任何 riskLevel 下合法。dismiss:立即删条目,输出单发 0x36 动作。
- `tick(nowMs)` 输出动作列表:
  - 过期(nowMs ≥ expiresAtMs):删条目,事件 `EXPIRED`(仅 ACTIVE/SEND_FAILED 状态;SENT_AWAITING_ACK 的条目**过期不删**,等 ack 流程结束,防止判决结果无处对账)
  - 重发到期:见 §2.2
- `onResolved(reqId, outcome)`:删条目;事件映射:outcome 0/1 → `COMPLETED`,2/4/5/未知 → `RESOLVED_ELSEWHERE`,3 → `EXPIRED`。
- 导航:`currentIndex` 随旋钮循环;删除当前条自动指向下一条;队列空 → 退出模态(由调用方处理)。
- 事件枚举(供 buzzer/LED 映射,B7):`ARRIVED / COMPLETED / RESOLVED_ELSEWHERE / EXPIRED / SEND_FAILED`(SEND_FAILED 为接口事件,非协议帧,重发耗尽时通知调用方)。

### 3.1 裁决细则

1. **dismiss 前置条件**:仅要求条目处于 ACTIVE;**不受 notifyOnly 限制**(notifyOnly 条目必须可被移除);SENT_AWAITING_ACK / SEND_FAILED 状态下 dismiss 拒绝(等 0x56 或过期兜底)。
2. **同 tick 顺序**:先做重发耗尽 → SEND_FAILED 转换,再判过期;允许同一 tick 输出 SEND_FAILED + EXPIRED 两事件并删条目。
3. **满队列淘汰**:仅通过 push 返回值携带 `evictedReqId`,不发任何帧、不产生 §3 事件(Mac 侧 pending 不受影响,迟到判决由幂等层兜住)。
4. **SEND_FAILED 收到重复 push**:按 §3 字面回 ACTIVE 可重新判决(实际不可达:Mac 不重复推送同一 reqId)。
5. **编码侧校验**:0x36 编码侧同样拒绝 decision>3;0x55 编码侧仅拒绝三个长度超限,riskLevel/flags 按原值写入不做规范化(钳制/掩码是解码侧规则)。
6. **decode error 的具体原因/检查顺序不作规范**:协议只规范 accept/reject 结果;两侧实现对同一畸形帧报告的错误类别可以不同(如空帧一侧先报长度、一侧先报 magic),属预期差异。上层不得依赖错误类别做逻辑分支。

## 4. Mac 侧 `ApprovalRegistry` 状态机(纯逻辑)

- 键:**(sessionKey, agentId, toolUseId)** 三元组;`reqId` 为设备通信用短句柄,单调递增 u16 回绕,跳过在用值。
- 状态:`pending → terminal(allow|deny|resolvedElsewhere|expired|cancelled|autoAllowed)`;终态记录保留最近 ≥256 条用于幂等吞。
- 入口 `register(...)` → 分配 reqId;若命中 Codex 会话 allowlist(sessionKey, toolName)→ 直接 autoAllowed(输出 respond(allow) 动作,不推设备)。
- `onDeviceResponse(reqId, decision)`:
  - pending + allow/deny → respond 动作 + 终态 + `0x56(outcome=0/1)`
  - pending + always_allow → respond(allow) + 记会话规则动作(CC:updatedPermissions 透传;Codex:写内存 allowlist)+ 终态 + `0x56(outcome=0)`
  - pending + dismiss → 标记 deviceDismissed(**仍 pending**),无 0x56
  - 终态/未知 reqId(dismiss 除外)→ 无副作用 + `0x56(outcome=2)`
- `resolveElsewhere(reqId, reason)`(Mac UI 判决、hook EOF、rollout 后续事件、会话结束)→ 终态 + `0x56(outcome=2 或 5)`
- `expire(nowMs)` → 终态 + `0x56(outcome=3)`
- 所有 0x56 的产生集中于 Registry,单点仲裁。

## 5. 超时

hook 侧统一 300s(本模块不实现 hook,仅约定 `expiresInSec` 由 Mac 按 hook 剩余时间填写,默认 ≤300)。

## 6. 测试向量

两侧使用以下同组测试向量：
- `QuickVibeMicStick/tests/approval_vectors_generated.h`(C++)
- `QuickVibeHost/ApprovalKit/Tests/ApprovalKitTests/ApprovalVectors.generated.swift`(Swift)

两侧测试必须全部通过同一组向量(合法编解码往返 + 每条 decode error 规则至少一个反例)。
