#pragma once
// approval_protocol.h —— 审批协议 v1(REQ-022)固件侧纯逻辑模块(header-only)
//
// 权威规格:docs/approval-protocol-v1.md(唯一权威,本文件不得偏离)
// 测试向量:tests/approval_vectors.py → QuickVibeMicPad/tests/approval_vectors_generated.h
// 宿主机测试:QuickVibeMicPad/tests/test_approval_protocol.cpp
//
// 设计约束:
// - 零 Arduino 依赖:不 include Arduino.h、不用 millis();时间一律由调用方以 uint32_t nowMs 传入
// - 无堆分配:全部定长数组,适合固件侧常驻
// - 动作/事件用返回值结构体表达,不用回调
// - 双向编解码齐备:设备视角 decode 0x55/0x56、encode 0x36;反向 encode 0x55/0x56、
//   decode 0x36 供 Mac 侧 test-server 打桩用

#include <stdint.h>
#include <stddef.h>
#include <string.h>

// ---------------------------------------------------------------------------
// 常量(规格 §1)
// ---------------------------------------------------------------------------

static const uint8_t kApprovalMagicRequest  = 0x55; // APPROVAL_REQUEST  (Mac → 设备)
static const uint8_t kApprovalMagicResponse = 0x36; // CMD_APPROVAL_RESPONSE(设备 → Mac)
static const uint8_t kApprovalMagicResolved = 0x56; // APPROVAL_RESOLVED (Mac → 设备)
static const uint8_t kApprovalFrameVer      = 1;    // frameVer ≠1 整帧丢弃

// 字段上限(§1.1);解码超限 → decode error;编码超限 → 拒绝编码
static const uint8_t  kApprovalSessNameMax = 24;
static const uint8_t  kApprovalToolMax     = 64;
static const uint16_t kApprovalBodyMax     = 256;

// 0x55 帧总长 = 13 + sessNameLen + toolLen + bodyLen(固定头 10B + toolLen 1B + bodyLen 2B)
static const size_t kApprovalRequestFixedLen = 13;
static const size_t kApprovalRequestMaxLen =
    kApprovalRequestFixedLen + kApprovalSessNameMax + kApprovalToolMax + kApprovalBodyMax; // 357
static const size_t kApprovalShortFrameLen = 4; // 0x36 / 0x56 总长必须 =4

// flags 位定义(§1.1);bit3..7 解码时忽略
static const uint8_t kApprovalFlagTruncated      = 0x01;
static const uint8_t kApprovalFlagNotifyOnly     = 0x02;
static const uint8_t kApprovalFlagAlwaysDisabled = 0x04;
static const uint8_t kApprovalFlagsMask          = 0x07;

// decision(§1.2);>3 → decode error
static const uint8_t kApprovalDecisionDeny        = 0;
static const uint8_t kApprovalDecisionAllow       = 1;
static const uint8_t kApprovalDecisionDismiss     = 2;
static const uint8_t kApprovalDecisionAlwaysAllow = 3;
static const uint8_t kApprovalDecisionMax         = 3;

// outcome(§1.3);未知值合法,语义按 2(resolved_elsewhere)处理
static const uint8_t kApprovalOutcomeJudgedAllow       = 0;
static const uint8_t kApprovalOutcomeJudgedDeny        = 1;
static const uint8_t kApprovalOutcomeResolvedElsewhere = 2;
static const uint8_t kApprovalOutcomeExpired           = 3;
static const uint8_t kApprovalOutcomeAutoAllowed       = 4;
static const uint8_t kApprovalOutcomeCancelled         = 5;
static const uint8_t kApprovalOutcomeKnownMax          = 5;

// 队列参数(§2 / §3)
static const uint8_t  kApprovalQueueCap         = 8;   // 容量 8,满时淘汰最早入队
static const uint32_t kApprovalResendIntervalMs = 500; // SENT_AWAITING_ACK 重发间隔
static const uint8_t  kApprovalMaxResendCount   = 3;   // 最多重发 3 次(共发 4 帧)

// ---------------------------------------------------------------------------
// 小端读写辅助
// ---------------------------------------------------------------------------

static inline uint16_t approvalRd16le(const uint8_t* p) {
    return (uint16_t)(p[0] | ((uint16_t)p[1] << 8));
}

static inline void approvalWr16le(uint8_t* p, uint16_t v) {
    p[0] = (uint8_t)(v & 0xFF);
    p[1] = (uint8_t)(v >> 8);
}

// 时间比较(u32 回绕安全):now 是否已到达 deadline
static inline bool approvalTimeReached(uint32_t nowMs, uint32_t deadlineMs) {
    return (int32_t)(nowMs - deadlineMs) >= 0;
}

// ---------------------------------------------------------------------------
// 0x55 APPROVAL_REQUEST 帧
// ---------------------------------------------------------------------------

struct ApprovalRequestFrame {
    uint16_t reqId       = 0;
    uint8_t  agentId     = 0; // 0=ClaudeCode 1=Codex;未知值合法(显示回落通用图标)
    uint8_t  riskLevel   = 0; // 解码后已钳制到 0..2
    uint16_t expiresInSec = 0; // 0 = 立即过期(合法)
    uint8_t  flags       = 0; // 解码后 bit3..7 已清零
    uint8_t  sessNameLen = 0;
    uint8_t  toolLen     = 0;
    uint16_t bodyLen     = 0;
    char sessName[kApprovalSessNameMax] = {}; // UTF-8,无 NUL 结尾,长度看 sessNameLen
    char tool[kApprovalToolMax]         = {};
    char body[kApprovalBodyMax]         = {};

    bool truncated() const      { return (flags & kApprovalFlagTruncated) != 0; }
    bool notifyOnly() const     { return (flags & kApprovalFlagNotifyOnly) != 0; }
    bool alwaysDisabled() const { return (flags & kApprovalFlagAlwaysDisabled) != 0; }
};

// 解码 0x55(设备侧)。严格执行 §1.1 全部校验:
// magic / frameVer / 各字段上限 / 总长精确匹配;risk>2 钳制为 2;flags bit3..7 忽略。
// 返回 false = decode error,整帧丢弃,out 内容未定义。
static inline bool approvalDecodeRequest(const uint8_t* data, size_t len, ApprovalRequestFrame* out) {
    if (data == nullptr || out == nullptr) return false;
    if (len < kApprovalRequestFixedLen) return false;             // 截尾(连定长部分都不够)
    if (data[0] != kApprovalMagicRequest) return false;           // magic
    if (data[1] != kApprovalFrameVer) return false;               // ver ≠1 整帧丢弃

    uint8_t sessNameLen = data[9];
    if (sessNameLen > kApprovalSessNameMax) return false;         // sessNameLen > 24
    size_t pos = 10;
    if (pos + sessNameLen + 1 > len) return false;                // sessName + toolLen 越界
    const uint8_t* sessPtr = data + pos;
    pos += sessNameLen;

    uint8_t toolLen = data[pos++];
    if (toolLen > kApprovalToolMax) return false;                 // toolLen > 64
    if (pos + toolLen + 2 > len) return false;                    // tool + bodyLen 越界
    const uint8_t* toolPtr = data + pos;
    pos += toolLen;

    uint16_t bodyLen = approvalRd16le(data + pos);
    pos += 2;
    if (bodyLen > kApprovalBodyMax) return false;                 // bodyLen > 256
    if (pos + bodyLen != len) return false;                       // 总长必须精确等于声明长度
    const uint8_t* bodyPtr = data + pos;

    out->reqId       = approvalRd16le(data + 2);
    out->agentId     = data[4];
    out->riskLevel   = (data[5] > 2) ? (uint8_t)2 : data[5];      // >2 按 2 处理(保守)
    out->expiresInSec = approvalRd16le(data + 6);
    out->flags       = (uint8_t)(data[8] & kApprovalFlagsMask);   // bit3..7 解码时忽略
    out->sessNameLen = sessNameLen;
    out->toolLen     = toolLen;
    out->bodyLen     = bodyLen;
    memcpy(out->sessName, sessPtr, sessNameLen);
    memcpy(out->tool, toolPtr, toolLen);
    memcpy(out->body, bodyPtr, bodyLen);
    return true;
}

// 编码 0x55(Mac / test-server 打桩用)。字段超限直接拒绝编码(编程错误),不做静默截断。
// 其余字段(agentId/riskLevel/flags)按原值写入,不做规范化——规范化是解码侧规则。
// 返回帧长;0 = 拒绝编码(字段超限或缓冲不足)。
static inline size_t approvalEncodeRequest(const ApprovalRequestFrame& f, uint8_t* out, size_t cap) {
    if (out == nullptr) return 0;
    if (f.sessNameLen > kApprovalSessNameMax) return 0;
    if (f.toolLen > kApprovalToolMax) return 0;
    if (f.bodyLen > kApprovalBodyMax) return 0;
    size_t total = kApprovalRequestFixedLen + f.sessNameLen + f.toolLen + f.bodyLen;
    if (cap < total) return 0;

    out[0] = kApprovalMagicRequest;
    out[1] = kApprovalFrameVer;
    approvalWr16le(out + 2, f.reqId);
    out[4] = f.agentId;
    out[5] = f.riskLevel;
    approvalWr16le(out + 6, f.expiresInSec);
    out[8] = f.flags;
    out[9] = f.sessNameLen;
    size_t pos = 10;
    memcpy(out + pos, f.sessName, f.sessNameLen);
    pos += f.sessNameLen;
    out[pos++] = f.toolLen;
    memcpy(out + pos, f.tool, f.toolLen);
    pos += f.toolLen;
    approvalWr16le(out + pos, f.bodyLen);
    pos += 2;
    memcpy(out + pos, f.body, f.bodyLen);
    pos += f.bodyLen;
    return pos; // == total
}

// ---------------------------------------------------------------------------
// 0x36 CMD_APPROVAL_RESPONSE 帧(设备 → Mac)
// ---------------------------------------------------------------------------

// 编码 0x36(设备侧)。decision>3 视为编程错误拒绝编码(与解码侧 §1.2 规则对称)。
// 返回帧长 4;0 = 拒绝。
static inline size_t approvalEncodeResponse(uint16_t reqId, uint8_t decision, uint8_t* out, size_t cap) {
    if (out == nullptr || cap < kApprovalShortFrameLen) return 0;
    if (decision > kApprovalDecisionMax) return 0;
    out[0] = kApprovalMagicResponse;
    approvalWr16le(out + 1, reqId);
    out[3] = decision;
    return kApprovalShortFrameLen;
}

// 解码 0x36(Mac / test-server 打桩用)。总长必须 =4;decision>3 → decode error(丢弃)。
static inline bool approvalDecodeResponse(const uint8_t* data, size_t len,
                                          uint16_t* reqId, uint8_t* decision) {
    if (data == nullptr || reqId == nullptr || decision == nullptr) return false;
    if (len != kApprovalShortFrameLen) return false;
    if (data[0] != kApprovalMagicResponse) return false;
    if (data[3] > kApprovalDecisionMax) return false;
    *reqId = approvalRd16le(data + 1);
    *decision = data[3];
    return true;
}

// ---------------------------------------------------------------------------
// 0x56 APPROVAL_RESOLVED 帧(Mac → 设备)
// ---------------------------------------------------------------------------

// 编码 0x56(Mac / test-server 打桩用)。outcome 任意 u8 均可编码(前向兼容,未知值由解码侧归一)。
static inline size_t approvalEncodeResolved(uint16_t reqId, uint8_t outcome, uint8_t* out, size_t cap) {
    if (out == nullptr || cap < kApprovalShortFrameLen) return 0;
    out[0] = kApprovalMagicResolved;
    approvalWr16le(out + 1, reqId);
    out[3] = outcome;
    return kApprovalShortFrameLen;
}

// 解码 0x56(设备侧)。总长必须 =4;未知 outcome 合法,treatAs 归一为 2(resolved_elsewhere)。
// rawOutcome 保留线上原值,treatAs 给语义值。
static inline bool approvalDecodeResolved(const uint8_t* data, size_t len,
                                          uint16_t* reqId, uint8_t* rawOutcome, uint8_t* treatAs) {
    if (data == nullptr || reqId == nullptr || rawOutcome == nullptr || treatAs == nullptr) return false;
    if (len != kApprovalShortFrameLen) return false;
    if (data[0] != kApprovalMagicResolved) return false;
    *reqId = approvalRd16le(data + 1);
    *rawOutcome = data[3];
    *treatAs = (data[3] > kApprovalOutcomeKnownMax) ? kApprovalOutcomeResolvedElsewhere : data[3];
    return true;
}

// ---------------------------------------------------------------------------
// 设备侧队列状态机 ApprovalQueue(规格 §3;纯逻辑,时间由外部传入)
// ---------------------------------------------------------------------------

// 条目状态(§2 / §3)
enum class ApprovalEntryState : uint8_t {
    ACTIVE,            // 待用户判决
    SENT_AWAITING_ACK, // 已发判决 0x36,等对应 0x56;过期不删,更新忽略
    SEND_FAILED,       // 重发 3 次仍无 ack;条目保留可视,等 0x56 或过期兜底
};

// 事件(§3 事件枚举 ARRIVED/COMPLETED/RESOLVED_ELSEWHERE/EXPIRED 供 buzzer/LED 映射;
// UPDATED/IGNORED/SEND_FAILED 为接口补充,调用方可自行决定是否映射提示)
enum class ApprovalEvent : uint8_t {
    NONE,               // 无事件(如 onResolved 未知 reqId)
    ARRIVED,            // 新条目入队
    UPDATED,            // 已有 reqId 原地更新
    IGNORED,            // SENT_AWAITING_ACK 期间收到更新,忽略(判决优先)
    COMPLETED,          // outcome 0/1:本设备判决被采纳
    RESOLVED_ELSEWHERE, // outcome 2/4/5/未知:他处已解决
    EXPIRED,            // 本地过期删除,或 outcome 3
    SEND_FAILED,        // 重发耗尽转入 SEND_FAILED 状态
};

struct ApprovalEntry {
    ApprovalRequestFrame req;
    ApprovalEntryState state = ApprovalEntryState::ACTIVE;
    uint32_t expiresAtMs   = 0; // 入队/更新时刻 + expiresInSec*1000
    uint32_t nextResendAtMs = 0; // SENT_AWAITING_ACK 下次重发时刻
    uint8_t  resendCount   = 0; // 已重发次数(不含首发)
    uint8_t  sentDecision  = 0; // 已发送的判决,重发时复用
};

// 待发送帧(0x36 固定 4 字节)
struct ApprovalSend {
    uint8_t bytes[kApprovalShortFrameLen] = {};
    uint8_t len = 0;
};

struct ApprovalEventRec {
    ApprovalEvent event = ApprovalEvent::NONE;
    uint16_t reqId = 0;
};

// push 结果
struct ApprovalPushResult {
    ApprovalEvent event = ApprovalEvent::NONE; // ARRIVED / UPDATED / IGNORED
    bool evicted = false;                      // 满队列淘汰了最早条目
    uint16_t evictedReqId = 0;
};

// decide 结果
struct ApprovalDecideResult {
    bool accepted = false; // 判决是否合法被受理(非法时其余字段无效)
    bool hasSend = false;  // 需要发送 0x36
    ApprovalSend send;
    bool removed = false;  // dismiss 时条目已立即删除
};

// tick 结果:需发送的帧 + 事件列表
struct ApprovalTickResult {
    uint8_t sendCount = 0;
    ApprovalSend sends[kApprovalQueueCap];             // 每条目每 tick 至多 1 帧
    uint8_t eventCount = 0;
    ApprovalEventRec events[kApprovalQueueCap * 2];    // 每条目每 tick 至多 2 事件(SEND_FAILED+EXPIRED)
};

// onResolved 结果
struct ApprovalResolveResult {
    bool found = false;                        // 未知 reqId → false,静默忽略(§2.5)
    ApprovalEvent event = ApprovalEvent::NONE; // COMPLETED / RESOLVED_ELSEWHERE / EXPIRED
};

// 存储期约束:sizeof(ApprovalQueue) ≈ 2.9KB(372B × 8 槽)。
// 必须以 static/global 生命周期持有;严禁在函数局部作用域按值声明
// (ESP32 部分 FreeRTOS 任务栈仅 2-4KB,栈上实例化会溢出)。
struct ApprovalQueue {
    ApprovalEntry entries[kApprovalQueueCap]; // 按入队先后有序,entries[0] 最早
    uint8_t count = 0;
    uint8_t curIndex = 0; // 当前导航位置;队列空时无意义(固定 0)

    // ---- 查询 ----

    uint8_t size() const { return count; }
    bool empty() const { return count == 0; }

    int findIndex(uint16_t reqId) const {
        for (uint8_t i = 0; i < count; i++) {
            if (entries[i].req.reqId == reqId) return (int)i;
        }
        return -1;
    }

    const ApprovalEntry* entryAt(uint8_t idx) const {
        return (idx < count) ? &entries[idx] : nullptr;
    }

    // 当前条目;队列空 → nullptr(调用方据此退出模态)
    const ApprovalEntry* current() const {
        return (count > 0) ? &entries[curIndex] : nullptr;
    }

    uint8_t currentIndex() const { return curIndex; }

    // ---- 导航(旋钮循环)----

    void moveNext() { if (count > 0) curIndex = (uint8_t)((curIndex + 1) % count); }
    void movePrev() { if (count > 0) curIndex = (uint8_t)((curIndex + count - 1) % count); }

    // ---- push(§3):新条目 ARRIVED / 已有 reqId 原地更新 UPDATED / 判决优先 IGNORED ----

    ApprovalPushResult push(const ApprovalRequestFrame& frame, uint32_t nowMs) {
        ApprovalPushResult r;
        int idx = findIndex(frame.reqId);
        if (idx >= 0) {
            ApprovalEntry& e = entries[idx];
            if (e.state == ApprovalEntryState::SENT_AWAITING_ACK) {
                // 已发判决等 ack:忽略更新,判决优先
                r.event = ApprovalEvent::IGNORED;
                return r;
            }
            // 原地更新内容并重置过期时间,状态回 ACTIVE(保留队列位置)
            e.req = frame;
            e.state = ApprovalEntryState::ACTIVE;
            e.expiresAtMs = nowMs + (uint32_t)frame.expiresInSec * 1000u;
            e.resendCount = 0;
            r.event = ApprovalEvent::UPDATED;
            return r;
        }
        // 新条目:满则淘汰最早入队(含 SENT_AWAITING_ACK——迟到判决由 Mac 幂等层兜住)
        if (count == kApprovalQueueCap) {
            r.evicted = true;
            r.evictedReqId = entries[0].req.reqId;
            removeAt(0);
        }
        ApprovalEntry& e = entries[count];
        e.req = frame;
        e.state = ApprovalEntryState::ACTIVE;
        e.expiresAtMs = nowMs + (uint32_t)frame.expiresInSec * 1000u;
        e.nextResendAtMs = 0;
        e.resendCount = 0;
        e.sentDecision = 0;
        count++;
        r.event = ApprovalEvent::ARRIVED;
        return r;
    }

    // ---- decide(§3)----
    // allow/deny/always_allow:仅 ACTIVE 且 !notifyOnly 且 !(always && alwaysDisabled)
    //   且 !(allow && risk==2) 且 !(always && risk==2) 合法(deny 在任何 riskLevel 下合法)
    //   → SENT_AWAITING_ACK,输出发送 0x36 动作(首发)
    // dismiss:仅 ACTIVE 合法(notifyOnly 条目也可 dismiss);立即删条目,单发 0x36 不重发不等 ack

    ApprovalDecideResult decide(uint16_t reqId, uint8_t decision, uint32_t nowMs) {
        ApprovalDecideResult r;
        if (decision > kApprovalDecisionMax) return r;
        int idx = findIndex(reqId);
        if (idx < 0) return r;
        ApprovalEntry& e = entries[idx];
        if (e.state != ApprovalEntryState::ACTIVE) return r; // SENT_AWAITING_ACK / SEND_FAILED 不接受判决

        if (decision == kApprovalDecisionDismiss) {
            r.accepted = true;
            r.hasSend = true;
            r.send.len = (uint8_t)approvalEncodeResponse(reqId, decision, r.send.bytes, sizeof(r.send.bytes));
            r.removed = true;
            removeAt((uint8_t)idx);
            return r;
        }

        // 判决三态的合法性矩阵
        if (e.req.notifyOnly()) return r;
        if (decision == kApprovalDecisionAllow && e.req.riskLevel == 2) return r;
        if (decision == kApprovalDecisionAlwaysAllow &&
            (e.req.alwaysDisabled() || e.req.riskLevel == 2)) return r;
        // deny 永远合法(在 ACTIVE 且 !notifyOnly 前提下)

        r.accepted = true;
        r.hasSend = true;
        r.send.len = (uint8_t)approvalEncodeResponse(reqId, decision, r.send.bytes, sizeof(r.send.bytes));
        e.state = ApprovalEntryState::SENT_AWAITING_ACK;
        e.sentDecision = decision;
        e.resendCount = 0;
        e.nextResendAtMs = nowMs + kApprovalResendIntervalMs;
        return r;
    }

    // SEND_FAILED 的本地关闭：设备端停止展示这张已无法同步的卡片，但不再发送
    // 第二个 0x36，以免与先前已发送的 allow/deny 产生语义冲突。迟到的 0x56
    // 按未知 reqId 安全忽略；Mac 端原审批仍可在其自身 UI/超时路径继续处理。
    // SENT_AWAITING_ACK 不可走此路径，避免在传输仅暂时延迟时丢失可见反馈。
    bool closeFailedLocally(uint16_t reqId) {
        int idx = findIndex(reqId);
        if (idx < 0 || entries[idx].state != ApprovalEntryState::SEND_FAILED) return false;
        removeAt((uint8_t)idx);
        return true;
    }

    // ---- tick(§2.2 / §3)----
    // 重发:SENT_AWAITING_ACK 且到期 → 重发同一 0x36(≤3 次);耗尽 → SEND_FAILED(条目保留)
    // 过期:仅 ACTIVE/SEND_FAILED 且 nowMs ≥ expiresAtMs → 删条目 + EXPIRED;
    //       SENT_AWAITING_ACK 过期不删(等 ack 流程结束,防判决结果无处对账)

    ApprovalTickResult tick(uint32_t nowMs) {
        ApprovalTickResult r;
        uint8_t i = 0;
        while (i < count) {
            ApprovalEntry& e = entries[i];
            bool removed = false;

            if (e.state == ApprovalEntryState::SENT_AWAITING_ACK &&
                approvalTimeReached(nowMs, e.nextResendAtMs)) {
                if (e.resendCount < kApprovalMaxResendCount) {
                    // 重发同一 0x36
                    e.resendCount++;
                    e.nextResendAtMs = nowMs + kApprovalResendIntervalMs;
                    ApprovalSend& s = r.sends[r.sendCount++];
                    s.len = (uint8_t)approvalEncodeResponse(e.req.reqId, e.sentDecision,
                                                            s.bytes, sizeof(s.bytes));
                } else {
                    // 重发耗尽(共发 4 帧)→ SEND_FAILED,不再发
                    e.state = ApprovalEntryState::SEND_FAILED;
                    r.events[r.eventCount++] = { ApprovalEvent::SEND_FAILED, e.req.reqId };
                }
            }

            // 转入 SEND_FAILED 后同 tick 即参与过期判定(过期兜底)
            if ((e.state == ApprovalEntryState::ACTIVE ||
                 e.state == ApprovalEntryState::SEND_FAILED) &&
                approvalTimeReached(nowMs, e.expiresAtMs)) {
                r.events[r.eventCount++] = { ApprovalEvent::EXPIRED, e.req.reqId };
                removeAt(i);
                removed = true;
            }

            if (!removed) i++;
        }
        return r;
    }

    // ---- onResolved(§3):任意 outcome 都删条目 ----
    // 事件映射:0/1 → COMPLETED,2/4/5/未知 → RESOLVED_ELSEWHERE,3 → EXPIRED
    // 未知 reqId → 静默忽略(§2.5)

    ApprovalResolveResult onResolved(uint16_t reqId, uint8_t rawOutcome) {
        ApprovalResolveResult r;
        int idx = findIndex(reqId);
        if (idx < 0) return r;
        r.found = true;
        if (rawOutcome == kApprovalOutcomeJudgedAllow || rawOutcome == kApprovalOutcomeJudgedDeny) {
            r.event = ApprovalEvent::COMPLETED;
        } else if (rawOutcome == kApprovalOutcomeExpired) {
            r.event = ApprovalEvent::EXPIRED;
        } else {
            r.event = ApprovalEvent::RESOLVED_ELSEWHERE; // 2/4/5/未知
        }
        removeAt((uint8_t)idx);
        return r;
    }

    // ---- 内部:删除并保持导航语义(删当前条自动指向下一条,循环)----

    void removeAt(uint8_t idx) {
        if (idx >= count) return;
        for (uint8_t i = idx; (uint8_t)(i + 1) < count; i++) {
            entries[i] = entries[i + 1];
        }
        count--;
        if (count == 0) {
            curIndex = 0;
            return;
        }
        if (idx < curIndex) {
            curIndex--;            // 删的是当前条之前:位置左移,仍指向原条目
        } else if (curIndex >= count) {
            curIndex = 0;          // 删的是末尾且当前指向末尾:循环回到队首
        }
        // idx == curIndex 且未越界:index 不变,后续条目左移后自然指向"下一条"
    }
};
