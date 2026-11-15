// Build:
//   g++ -std=c++17 -Wall -Wextra -Werror -I QuickVibeMicPad QuickVibeMicPad/tests/test_approval_protocol.cpp -o /tmp/qv_approval_test && /tmp/qv_approval_test
//
// 审批协议 v1(REQ-022)固件侧模块宿主机测试。
// 权威规格:docs/approval-protocol-v1.md
// 向量来源:tests/approval_vectors.py(生成 approval_vectors_generated.h,严禁手改生成文件)
#include <cassert>
#include <cstdint>
#include <cstdio>
#include <cstring>
#include <string>
#include <vector>

#include "approval_protocol.h"
#include "approval_vectors_generated.h"

static int g_testCount = 0;
#define RUN(fn) do { fn(); g_testCount++; printf("  ok: %s\n", #fn); } while (0)

// ---------------------------------------------------------------------------
// 辅助
// ---------------------------------------------------------------------------

// hex 字符串 → 字节
static std::vector<uint8_t> hexToBytes(const char* hex) {
    std::vector<uint8_t> out;
    size_t n = strlen(hex);
    assert(n % 2 == 0);
    for (size_t i = 0; i < n; i += 2) {
        auto nib = [](char c) -> uint8_t {
            if (c >= '0' && c <= '9') return (uint8_t)(c - '0');
            if (c >= 'a' && c <= 'f') return (uint8_t)(c - 'a' + 10);
            if (c >= 'A' && c <= 'F') return (uint8_t)(c - 'A' + 10);
            assert(false);
            return 0;
        };
        out.push_back((uint8_t)((nib(hex[i]) << 4) | nib(hex[i + 1])));
    }
    return out;
}

// 从 C 字符串字段构造 0x55 帧结构(测试用)
static ApprovalRequestFrame makeFrame(uint16_t reqId, uint8_t agentId, uint8_t risk,
                                      uint16_t expires, uint8_t flags,
                                      const char* sess, const char* tool, const char* body) {
    ApprovalRequestFrame f;
    f.reqId = reqId;
    f.agentId = agentId;
    f.riskLevel = risk;
    f.expiresInSec = expires;
    f.flags = flags;
    size_t sl = strlen(sess), tl = strlen(tool), bl = strlen(body);
    assert(sl <= kApprovalSessNameMax && tl <= kApprovalToolMax && bl <= kApprovalBodyMax);
    f.sessNameLen = (uint8_t)sl;
    f.toolLen = (uint8_t)tl;
    f.bodyLen = (uint16_t)bl;
    memcpy(f.sessName, sess, sl);
    memcpy(f.tool, tool, tl);
    memcpy(f.body, body, bl);
    return f;
}

// 帧字段与向量期望值逐一比对
static void assertFrameEqualsVec(const ApprovalRequestFrame& f, const Vec55& v) {
    assert(f.reqId == v.reqId);
    assert(f.agentId == v.agentId);
    assert(f.riskLevel == v.risk);
    assert(f.expiresInSec == v.expires);
    assert(f.flags == v.flags);
    assert(f.sessNameLen == strlen(v.sess));
    assert(f.toolLen == strlen(v.tool));
    assert(f.bodyLen == strlen(v.body));
    assert(memcmp(f.sessName, v.sess, f.sessNameLen) == 0);
    assert(memcmp(f.tool, v.tool, f.toolLen) == 0);
    assert(memcmp(f.body, v.body, f.bodyLen) == 0);
}

// 队列测试用最简帧
static ApprovalRequestFrame qframe(uint16_t reqId, uint8_t risk = 0,
                                   uint16_t expires = 300, uint8_t flags = 0) {
    return makeFrame(reqId, 0, risk, expires, flags, "sess", "Tool", "body");
}

// 断言 4 字节 send 是指定 reqId/decision 的 0x36 帧
static void assertSend36(const ApprovalSend& s, uint16_t reqId, uint8_t decision) {
    assert(s.len == 4);
    assert(s.bytes[0] == 0x36);
    assert(s.bytes[1] == (reqId & 0xFF));
    assert(s.bytes[2] == (reqId >> 8));
    assert(s.bytes[3] == decision);
}

// ---------------------------------------------------------------------------
// 向量测试:0x55
// ---------------------------------------------------------------------------

// ENCODE_55:编码逐字节比对
static void vec_encode_55_bytes_match() {
    for (const Vec55& v : ENCODE_55) {
        ApprovalRequestFrame f = makeFrame(v.reqId, v.agentId, v.risk, v.expires, v.flags,
                                           v.sess, v.tool, v.body);
        uint8_t buf[kApprovalRequestMaxLen];
        size_t n = approvalEncodeRequest(f, buf, sizeof(buf));
        std::vector<uint8_t> exp = hexToBytes(v.hex);
        assert(n == exp.size());
        assert(memcmp(buf, exp.data(), n) == 0);
    }
}

// 编解码往返:encode → decode 字段一致
static void vec_encode_55_roundtrip() {
    for (const Vec55& v : ENCODE_55) {
        ApprovalRequestFrame f = makeFrame(v.reqId, v.agentId, v.risk, v.expires, v.flags,
                                           v.sess, v.tool, v.body);
        uint8_t buf[kApprovalRequestMaxLen];
        size_t n = approvalEncodeRequest(f, buf, sizeof(buf));
        assert(n > 0);
        ApprovalRequestFrame d;
        assert(approvalDecodeRequest(buf, n, &d));
        assertFrameEqualsVec(d, v); // 向量字段均已规范(risk≤2/flags≤7),往返必须逐字段一致
    }
}

// DECODE_55_OK:钳制语义(risk>2 → 2;flags bit3..7 忽略)
static void vec_decode_55_ok_clamp_semantics() {
    for (const Vec55& v : DECODE_55_OK) {
        std::vector<uint8_t> raw = hexToBytes(v.hex);
        ApprovalRequestFrame d;
        assert(approvalDecodeRequest(raw.data(), raw.size(), &d));
        assertFrameEqualsVec(d, v);
    }
}

// DECODE_55_ERR:每条必须整帧拒绝
static void vec_decode_55_err_all_rejected() {
    for (const VecHex& v : DECODE_55_ERR) {
        std::vector<uint8_t> raw = hexToBytes(v.hex);
        ApprovalRequestFrame d;
        assert(!approvalDecodeRequest(raw.data(), raw.size(), &d));
    }
}

// 编码侧字段超限必须拒绝(不静默截断)
static void encode_55_rejects_over_limit_fields() {
    ApprovalRequestFrame f = qframe(1);
    uint8_t buf[kApprovalRequestMaxLen];

    f.sessNameLen = kApprovalSessNameMax + 1;
    assert(approvalEncodeRequest(f, buf, sizeof(buf)) == 0);
    f = qframe(1);
    f.toolLen = kApprovalToolMax + 1;
    assert(approvalEncodeRequest(f, buf, sizeof(buf)) == 0);
    f = qframe(1);
    f.bodyLen = kApprovalBodyMax + 1;
    assert(approvalEncodeRequest(f, buf, sizeof(buf)) == 0);

    // 缓冲不足同样拒绝
    f = qframe(1);
    assert(approvalEncodeRequest(f, buf, 5) == 0);
}

// ---------------------------------------------------------------------------
// 向量测试:0x36
// ---------------------------------------------------------------------------

// ENCODE_36:编码逐字节比对 + decode 往返(反向,供 test-server 打桩)
static void vec_encode_36_bytes_and_roundtrip() {
    for (const Vec36& v : ENCODE_36) {
        uint8_t buf[4];
        size_t n = approvalEncodeResponse(v.reqId, v.decision, buf, sizeof(buf));
        std::vector<uint8_t> exp = hexToBytes(v.hex);
        assert(n == exp.size());
        assert(memcmp(buf, exp.data(), n) == 0);

        uint16_t reqId = 0;
        uint8_t decision = 0xFF;
        assert(approvalDecodeResponse(buf, n, &reqId, &decision));
        assert(reqId == v.reqId);
        assert(decision == v.decision);
    }
}

// DECODE_36_ERR:必须拒绝(decision>3 / 长度不符 / magic 不符 / 空)
static void vec_decode_36_err_all_rejected() {
    for (const VecHex& v : DECODE_36_ERR) {
        std::vector<uint8_t> raw = hexToBytes(v.hex);
        uint16_t reqId = 0;
        uint8_t decision = 0;
        assert(!approvalDecodeResponse(raw.data(), raw.size(), &reqId, &decision));
    }
}

// 编码侧 decision>3 拒绝
static void encode_36_rejects_bad_decision() {
    uint8_t buf[4];
    assert(approvalEncodeResponse(1, 4, buf, sizeof(buf)) == 0);
    assert(approvalEncodeResponse(1, 0xFF, buf, sizeof(buf)) == 0);
}

// ---------------------------------------------------------------------------
// 向量测试:0x56
// ---------------------------------------------------------------------------

// ENCODE_56:编码逐字节比对 + decode 往返(已知 outcome 0..5,treatAs == 原值)
static void vec_encode_56_bytes_and_roundtrip() {
    for (const Vec56& v : ENCODE_56) {
        uint8_t buf[4];
        size_t n = approvalEncodeResolved(v.reqId, v.outcome, buf, sizeof(buf));
        std::vector<uint8_t> exp = hexToBytes(v.hex);
        assert(n == exp.size());
        assert(memcmp(buf, exp.data(), n) == 0);

        uint16_t reqId = 0;
        uint8_t raw = 0xFF, treatAs = 0xFF;
        assert(approvalDecodeResolved(buf, n, &reqId, &raw, &treatAs));
        assert(reqId == v.reqId);
        assert(raw == v.outcome);
        assert(treatAs == v.outcome); // 0..5 已知值不归一
    }
}

// DECODE_56_UNKNOWN:未知 outcome 解码合法,treatAs 归一为 2
static void vec_decode_56_unknown_treat_as() {
    for (const Vec56U& v : DECODE_56_UNKNOWN) {
        std::vector<uint8_t> bytes = hexToBytes(v.hex);
        uint16_t reqId = 0;
        uint8_t raw = 0, treatAs = 0;
        assert(approvalDecodeResolved(bytes.data(), bytes.size(), &reqId, &raw, &treatAs));
        assert(raw == v.raw);
        assert(treatAs == v.treatAs);
    }
}

// DECODE_56_ERR:必须拒绝(长度不符 / magic 不符 / 空)
static void vec_decode_56_err_all_rejected() {
    for (const VecHex& v : DECODE_56_ERR) {
        std::vector<uint8_t> raw = hexToBytes(v.hex);
        uint16_t reqId = 0;
        uint8_t o = 0, t = 0;
        assert(!approvalDecodeResolved(raw.data(), raw.size(), &reqId, &o, &t));
    }
}

// ---------------------------------------------------------------------------
// ApprovalQueue:push 语义
// ---------------------------------------------------------------------------

static void queue_push_arrival_event_and_size() {
    ApprovalQueue q;
    assert(q.empty());
    ApprovalPushResult r = q.push(qframe(10), 0);
    assert(r.event == ApprovalEvent::ARRIVED);
    assert(!r.evicted);
    assert(q.size() == 1);
    assert(q.current() != nullptr);
    assert(q.current()->req.reqId == 10);
    assert(q.current()->state == ApprovalEntryState::ACTIVE);
}

// reqId 重复 push,分支 1:ACTIVE → 原地更新内容 + 重置过期时间,保留队列位置
static void queue_push_update_resets_content_and_expiry() {
    ApprovalQueue q;
    q.push(qframe(1, 0, 10), 0);           // expiresAt = 10000
    q.push(qframe(2, 0, 300), 0);          // 占位,验证更新不改变位置
    ApprovalRequestFrame upd = makeFrame(1, 0, 1, 10, 0, "sess", "Tool", "new-body");
    ApprovalPushResult r = q.push(upd, 5000); // expiresAt 重置为 15000
    assert(r.event == ApprovalEvent::UPDATED);
    assert(q.size() == 2);
    assert(q.entryAt(0)->req.reqId == 1);  // 位置保留(原地更新)
    assert(q.entryAt(0)->req.riskLevel == 1);
    assert(q.entryAt(0)->req.bodyLen == strlen("new-body"));
    assert(memcmp(q.entryAt(0)->req.body, "new-body", strlen("new-body")) == 0);

    // 旧过期时间 10000 处不过期;新过期时间 15000 处过期
    ApprovalTickResult t1 = q.tick(10000);
    assert(t1.eventCount == 0);
    ApprovalTickResult t2 = q.tick(15000);
    assert(t2.eventCount == 1);
    assert(t2.events[0].event == ApprovalEvent::EXPIRED);
    assert(t2.events[0].reqId == 1);
    assert(q.size() == 1);
}

// reqId 重复 push,分支 2:SENT_AWAITING_ACK → 忽略更新(判决优先)
static void queue_push_ignored_while_awaiting_ack() {
    ApprovalQueue q;
    q.push(qframe(1), 0);
    ApprovalDecideResult d = q.decide(1, kApprovalDecisionAllow, 0);
    assert(d.accepted);
    ApprovalRequestFrame upd = makeFrame(1, 0, 2, 300, 0, "sess", "Tool", "changed");
    ApprovalPushResult r = q.push(upd, 100);
    assert(r.event == ApprovalEvent::IGNORED);
    // 内容未变、状态未变
    assert(q.entryAt(0)->state == ApprovalEntryState::SENT_AWAITING_ACK);
    assert(q.entryAt(0)->req.riskLevel == 0);
    assert(memcmp(q.entryAt(0)->req.body, "body", 4) == 0);
}

// SEND_FAILED 收到更新 → 回 ACTIVE(§3"状态回 ACTIVE,除非 SENT_AWAITING_ACK")
static void queue_push_update_reactivates_send_failed() {
    ApprovalQueue q;
    q.push(qframe(1), 0);
    q.decide(1, kApprovalDecisionAllow, 0);
    q.tick(500); q.tick(1000); q.tick(1500); // 重发 3 次
    ApprovalTickResult t = q.tick(2000);      // 耗尽 → SEND_FAILED
    assert(t.events[0].event == ApprovalEvent::SEND_FAILED);
    assert(q.entryAt(0)->state == ApprovalEntryState::SEND_FAILED);

    ApprovalPushResult r = q.push(qframe(1), 3000);
    assert(r.event == ApprovalEvent::UPDATED);
    assert(q.entryAt(0)->state == ApprovalEntryState::ACTIVE);
    assert(q.decide(1, kApprovalDecisionAllow, 3000).accepted); // 可重新判决
}

// 满队列(8)push 第 9 条 → 淘汰最早入队
static void queue_eviction_oldest_when_full() {
    ApprovalQueue q;
    for (uint16_t i = 1; i <= 8; i++) {
        assert(q.push(qframe(i), 0).event == ApprovalEvent::ARRIVED);
    }
    assert(q.size() == 8);
    ApprovalPushResult r = q.push(qframe(9), 0);
    assert(r.event == ApprovalEvent::ARRIVED);
    assert(r.evicted);
    assert(r.evictedReqId == 1);
    assert(q.size() == 8);
    assert(q.findIndex(1) < 0);
    assert(q.entryAt(0)->req.reqId == 2);
    assert(q.entryAt(7)->req.reqId == 9);
}

// 淘汰的最早条目可以处于 SENT_AWAITING_ACK(迟到判决由 Mac 幂等层兜住)
static void queue_eviction_includes_awaiting_ack_entry() {
    ApprovalQueue q;
    for (uint16_t i = 1; i <= 8; i++) q.push(qframe(i), 0);
    assert(q.decide(1, kApprovalDecisionAllow, 0).accepted);
    assert(q.entryAt(0)->state == ApprovalEntryState::SENT_AWAITING_ACK);
    ApprovalPushResult r = q.push(qframe(9), 0);
    assert(r.evicted && r.evictedReqId == 1);
    assert(q.findIndex(1) < 0);
    // 被淘汰条目不再产生重发
    ApprovalTickResult t = q.tick(500);
    assert(t.sendCount == 0);
}

// ---------------------------------------------------------------------------
// ApprovalQueue:decide 合法性矩阵
// ---------------------------------------------------------------------------

static void queue_decide_allow_sends_frame_and_awaits_ack() {
    ApprovalQueue q;
    q.push(qframe(0x1234), 0);
    ApprovalDecideResult d = q.decide(0x1234, kApprovalDecisionAllow, 0);
    assert(d.accepted && d.hasSend && !d.removed);
    assertSend36(d.send, 0x1234, kApprovalDecisionAllow);
    assert(q.entryAt(0)->state == ApprovalEntryState::SENT_AWAITING_ACK);
    assert(q.size() == 1); // 不删条目,等 0x56
}

// notifyOnly:allow/deny/always 全部非法;dismiss 合法
static void queue_decide_matrix_notify_only() {
    ApprovalQueue q;
    q.push(qframe(1, 0, 300, kApprovalFlagNotifyOnly), 0);
    assert(!q.decide(1, kApprovalDecisionAllow, 0).accepted);
    assert(!q.decide(1, kApprovalDecisionDeny, 0).accepted);
    assert(!q.decide(1, kApprovalDecisionAlwaysAllow, 0).accepted);
    ApprovalDecideResult d = q.decide(1, kApprovalDecisionDismiss, 0);
    assert(d.accepted && d.removed);
    assert(q.empty());
}

// alwaysDisabled:仅 always_allow 非法,allow/deny 合法
static void queue_decide_matrix_always_disabled() {
    ApprovalQueue q;
    q.push(qframe(1, 0, 300, kApprovalFlagAlwaysDisabled), 0);
    q.push(qframe(2, 0, 300, kApprovalFlagAlwaysDisabled), 0);
    assert(!q.decide(1, kApprovalDecisionAlwaysAllow, 0).accepted);
    assert(q.decide(1, kApprovalDecisionAllow, 0).accepted);
    assert(q.decide(2, kApprovalDecisionDeny, 0).accepted);
}

// riskLevel==2:allow 与 always 非法,deny 永远合法
static void queue_decide_matrix_risk2() {
    ApprovalQueue q;
    q.push(qframe(1, 2), 0);
    assert(!q.decide(1, kApprovalDecisionAllow, 0).accepted);
    assert(!q.decide(1, kApprovalDecisionAlwaysAllow, 0).accepted);
    ApprovalDecideResult d = q.decide(1, kApprovalDecisionDeny, 0);
    assert(d.accepted && d.hasSend);
    assertSend36(d.send, 1, kApprovalDecisionDeny);
}

// 未知 reqId / 非法 decision 值 → 拒绝
static void queue_decide_unknown_reqid_and_bad_decision() {
    ApprovalQueue q;
    q.push(qframe(1), 0);
    assert(!q.decide(99, kApprovalDecisionAllow, 0).accepted);
    assert(!q.decide(1, 4, 0).accepted);
    assert(q.entryAt(0)->state == ApprovalEntryState::ACTIVE); // 状态未被污染
}

// SENT_AWAITING_ACK / SEND_FAILED 状态不接受任何判决(含 dismiss)
static void queue_decide_rejected_when_not_active() {
    ApprovalQueue q;
    q.push(qframe(1), 0);
    q.decide(1, kApprovalDecisionAllow, 0);
    assert(!q.decide(1, kApprovalDecisionDeny, 0).accepted);
    assert(!q.decide(1, kApprovalDecisionDismiss, 0).accepted);
    q.tick(500); q.tick(1000); q.tick(1500); q.tick(2000); // → SEND_FAILED
    assert(q.entryAt(0)->state == ApprovalEntryState::SEND_FAILED);
    assert(!q.decide(1, kApprovalDecisionAllow, 2000).accepted);
    assert(!q.decide(1, kApprovalDecisionDismiss, 2000).accepted);
}

// SEND_FAILED 时允许仅关闭设备端卡片：不再发送第二个 decision，防止与已发
// allow/deny 冲突；迟到的 0x56 按未知 reqId 安全忽略。
static void queue_close_send_failed_locally() {
    ApprovalQueue q;
    q.push(qframe(1), 0);
    q.decide(1, kApprovalDecisionAllow, 0);
    q.tick(500); q.tick(1000); q.tick(1500); q.tick(2000);
    assert(q.entryAt(0)->state == ApprovalEntryState::SEND_FAILED);
    assert(q.closeFailedLocally(1));
    assert(q.empty());
    assert(!q.closeFailedLocally(1));

    q.push(qframe(2), 0);
    assert(!q.closeFailedLocally(2)); // ACTIVE 不能绕过正常 dismiss 协议
}

// dismiss:立即删条目 + 单发 0x36,后续 tick 不重发
static void queue_dismiss_immediate_remove_single_send() {
    ApprovalQueue q;
    q.push(qframe(0x8001), 0);
    ApprovalDecideResult d = q.decide(0x8001, kApprovalDecisionDismiss, 0);
    assert(d.accepted && d.hasSend && d.removed);
    assertSend36(d.send, 0x8001, kApprovalDecisionDismiss); // 与 ENCODE_36 "dismiss" 向量同构
    assert(q.empty());
    // 单发不重发、不等 ack
    ApprovalTickResult t = q.tick(500);
    assert(t.sendCount == 0 && t.eventCount == 0);
}

// ---------------------------------------------------------------------------
// ApprovalQueue:tick 重发 / SEND_FAILED / 过期
// ---------------------------------------------------------------------------

// 重发计数恰好 3 次(共发 4 帧)后 SEND_FAILED 且不再发
static void queue_resend_exactly_3_then_send_failed() {
    ApprovalQueue q;
    q.push(qframe(1), 0);
    ApprovalDecideResult d = q.decide(1, kApprovalDecisionAllow, 0); // 首发(第 1 帧)
    assert(d.hasSend);

    ApprovalTickResult t = q.tick(499); // 未到 500ms,不重发
    assert(t.sendCount == 0);

    for (uint32_t k = 1; k <= 3; k++) {  // 重发 3 次(第 2/3/4 帧)
        t = q.tick(500 * k);
        assert(t.sendCount == 1);
        assertSend36(t.sends[0], 1, kApprovalDecisionAllow); // 重发同一 0x36
        assert(t.eventCount == 0);
    }

    t = q.tick(2000); // 第 4 次到期:不再发,转 SEND_FAILED
    assert(t.sendCount == 0);
    assert(t.eventCount == 1);
    assert(t.events[0].event == ApprovalEvent::SEND_FAILED);
    assert(t.events[0].reqId == 1);
    assert(q.size() == 1); // 条目保留、可视
    assert(q.entryAt(0)->state == ApprovalEntryState::SEND_FAILED);

    t = q.tick(2500); // 之后不再产生任何发送
    assert(t.sendCount == 0 && t.eventCount == 0);
}

// ack 在重发间隙到达:删条目,后续无重发
static void queue_ack_between_resends() {
    ApprovalQueue q;
    q.push(qframe(1), 0);
    q.decide(1, kApprovalDecisionAllow, 0);
    ApprovalTickResult t = q.tick(500); // 重发 1 次
    assert(t.sendCount == 1);
    ApprovalResolveResult r = q.onResolved(1, kApprovalOutcomeJudgedAllow); // t=700 ack 到达
    assert(r.found && r.event == ApprovalEvent::COMPLETED);
    assert(q.empty());
    t = q.tick(1000); // 不再有重发
    assert(t.sendCount == 0 && t.eventCount == 0);
}

// ACTIVE 过期:nowMs ≥ expiresAtMs 删条目 + EXPIRED
static void queue_expiry_active_entry() {
    ApprovalQueue q;
    q.push(qframe(1, 0, 1), 0); // expiresAt = 1000
    assert(q.tick(999).eventCount == 0);
    ApprovalTickResult t = q.tick(1000);
    assert(t.eventCount == 1);
    assert(t.events[0].event == ApprovalEvent::EXPIRED);
    assert(t.events[0].reqId == 1);
    assert(q.empty());
}

// expiresInSec=0:立即过期(合法,用于测试)
static void queue_expiry_zero_sec_immediate() {
    ApprovalQueue q;
    q.push(qframe(1, 0, 0), 1000); // expiresAt = 1000
    ApprovalTickResult t = q.tick(1000);
    assert(t.eventCount == 1 && t.events[0].event == ApprovalEvent::EXPIRED);
    assert(q.empty());
}

// SENT_AWAITING_ACK 不过期(等 ack 流程结束)
static void queue_awaiting_ack_does_not_expire() {
    ApprovalQueue q;
    q.push(qframe(1, 0, 1), 0); // expiresAt = 1000
    q.decide(1, kApprovalDecisionDeny, 0);
    ApprovalTickResult t = q.tick(1000); // 已过 expiresAt,但状态是 SENT_AWAITING_ACK
    bool sawExpired = false;
    for (uint8_t i = 0; i < t.eventCount; i++) {
        if (t.events[i].event == ApprovalEvent::EXPIRED) sawExpired = true;
    }
    assert(!sawExpired);
    assert(q.size() == 1); // 条目仍在(此 tick 只产生一次重发)
    assert(t.sendCount == 1);
}

// SEND_FAILED 的过期兜底:重发耗尽后条目保留,最终按 expiresAt 过期删除
static void queue_send_failed_expiry_fallback() {
    ApprovalQueue q;
    q.push(qframe(1, 0, 10), 0); // expiresAt = 10000
    q.decide(1, kApprovalDecisionAllow, 0);
    q.tick(500); q.tick(1000); q.tick(1500);
    ApprovalTickResult t = q.tick(2000); // → SEND_FAILED
    assert(t.events[0].event == ApprovalEvent::SEND_FAILED);
    assert(q.tick(5000).eventCount == 0); // 未到 expiresAt,保留
    t = q.tick(10000);                    // 过期兜底
    assert(t.eventCount == 1 && t.events[0].event == ApprovalEvent::EXPIRED);
    assert(q.empty());
}

// SEND_FAILED 转换与过期同一 tick:先 SEND_FAILED 后 EXPIRED,同 tick 删除
static void queue_send_failed_and_expire_same_tick() {
    ApprovalQueue q;
    q.push(qframe(1, 0, 2), 0); // expiresAt = 2000,与第 4 次重发到期重合
    q.decide(1, kApprovalDecisionAllow, 0);
    q.tick(500); q.tick(1000); q.tick(1500);
    ApprovalTickResult t = q.tick(2000);
    assert(t.sendCount == 0);
    assert(t.eventCount == 2);
    assert(t.events[0].event == ApprovalEvent::SEND_FAILED);
    assert(t.events[1].event == ApprovalEvent::EXPIRED);
    assert(q.empty());
}

// SEND_FAILED 期间收到 0x56 → 删条目(等 0x56 兜底路径)
static void queue_send_failed_then_resolved() {
    ApprovalQueue q;
    q.push(qframe(1, 0, 300), 0);
    q.decide(1, kApprovalDecisionAllow, 0);
    q.tick(500); q.tick(1000); q.tick(1500); q.tick(2000); // → SEND_FAILED
    ApprovalResolveResult r = q.onResolved(1, kApprovalOutcomeJudgedAllow);
    assert(r.found && r.event == ApprovalEvent::COMPLETED);
    assert(q.empty());
}

// 多条目独立计时:各自按自己的 deadline 重发/过期
static void queue_tick_multiple_entries_independent() {
    ApprovalQueue q;
    q.push(qframe(1, 0, 1), 0);   // expiresAt = 1000
    q.push(qframe(2, 0, 300), 0);
    q.decide(2, kApprovalDecisionAllow, 200); // nextResend = 700
    ApprovalTickResult t = q.tick(1000); // reqId1 过期 + reqId2 重发,同一 tick
    assert(t.sendCount == 1);
    assertSend36(t.sends[0], 2, kApprovalDecisionAllow);
    assert(t.eventCount == 1);
    assert(t.events[0].event == ApprovalEvent::EXPIRED && t.events[0].reqId == 1);
    assert(q.size() == 1 && q.entryAt(0)->req.reqId == 2);
}

// ---------------------------------------------------------------------------
// ApprovalQueue:onResolved 事件映射
// ---------------------------------------------------------------------------

// outcome 0/1 → COMPLETED,2/4/5/未知 → RESOLVED_ELSEWHERE,3 → EXPIRED
static void queue_on_resolved_event_mapping() {
    struct Case { uint8_t outcome; ApprovalEvent expect; };
    const Case cases[] = {
        { 0, ApprovalEvent::COMPLETED },
        { 1, ApprovalEvent::COMPLETED },
        { 2, ApprovalEvent::RESOLVED_ELSEWHERE },
        { 3, ApprovalEvent::EXPIRED },
        { 4, ApprovalEvent::RESOLVED_ELSEWHERE },
        { 5, ApprovalEvent::RESOLVED_ELSEWHERE },
        { 9, ApprovalEvent::RESOLVED_ELSEWHERE },   // 未知
        { 255, ApprovalEvent::RESOLVED_ELSEWHERE }, // 未知(u8 上界)
    };
    for (const Case& c : cases) {
        ApprovalQueue q;
        q.push(qframe(7), 0);
        ApprovalResolveResult r = q.onResolved(7, c.outcome);
        assert(r.found);
        assert(r.event == c.expect);
        assert(q.empty()); // 无论何种 outcome 都删条目
    }
}

// 未知 reqId 的 0x56 → 静默忽略(§2.5)
static void queue_on_resolved_unknown_reqid_ignored() {
    ApprovalQueue q;
    q.push(qframe(1), 0);
    ApprovalResolveResult r = q.onResolved(99, 0);
    assert(!r.found && r.event == ApprovalEvent::NONE);
    assert(q.size() == 1);
}

// ---------------------------------------------------------------------------
// ApprovalQueue:currentIndex 导航
// ---------------------------------------------------------------------------

// 队列空:current() == nullptr(调用方据此退出模态),导航无副作用
static void queue_nav_empty() {
    ApprovalQueue q;
    assert(q.current() == nullptr);
    q.moveNext();
    q.movePrev();
    assert(q.current() == nullptr);
    assert(q.currentIndex() == 0);
}

// 单条:导航原地循环
static void queue_nav_single_entry() {
    ApprovalQueue q;
    q.push(qframe(1), 0);
    assert(q.current()->req.reqId == 1);
    q.moveNext();
    assert(q.currentIndex() == 0 && q.current()->req.reqId == 1);
    q.movePrev();
    assert(q.currentIndex() == 0);
}

// 多条:旋钮双向循环
static void queue_nav_cycle() {
    ApprovalQueue q;
    q.push(qframe(1), 0); q.push(qframe(2), 0); q.push(qframe(3), 0);
    assert(q.current()->req.reqId == 1);
    q.moveNext(); assert(q.current()->req.reqId == 2);
    q.moveNext(); assert(q.current()->req.reqId == 3);
    q.moveNext(); assert(q.current()->req.reqId == 1); // 越尾回头
    q.movePrev(); assert(q.current()->req.reqId == 3); // 越头回尾
}

// 删当前条 → 自动指向下一条
static void queue_nav_remove_current_points_next() {
    ApprovalQueue q;
    q.push(qframe(1), 0); q.push(qframe(2), 0); q.push(qframe(3), 0);
    q.moveNext(); // 当前 = reqId 2
    q.onResolved(2, 0);
    assert(q.size() == 2);
    assert(q.current()->req.reqId == 3); // 下一条
}

// 删当前条且当前在末尾 → 循环指向队首
static void queue_nav_remove_last_current_wraps() {
    ApprovalQueue q;
    q.push(qframe(1), 0); q.push(qframe(2), 0); q.push(qframe(3), 0);
    q.moveNext(); q.moveNext(); // 当前 = reqId 3(末尾)
    q.onResolved(3, 0);
    assert(q.current()->req.reqId == 1);
}

// 删当前条之前的条目 → currentIndex 左移,仍指向原条目
static void queue_nav_remove_before_current_keeps_target() {
    ApprovalQueue q;
    q.push(qframe(1), 0); q.push(qframe(2), 0); q.push(qframe(3), 0);
    q.moveNext(); q.moveNext(); // 当前 = reqId 3
    q.onResolved(1, 0);
    assert(q.current()->req.reqId == 3);
    assert(q.currentIndex() == 1);
}

// 满队列淘汰 index 0 时导航语义保持
static void queue_nav_after_eviction() {
    ApprovalQueue q;
    for (uint16_t i = 1; i <= 8; i++) q.push(qframe(i), 0);
    q.moveNext(); q.moveNext(); // 当前 = reqId 3(index 2)
    q.push(qframe(9), 0);       // 淘汰 reqId 1,整体左移
    assert(q.current()->req.reqId == 3);
    assert(q.currentIndex() == 1);
}

// 删到空:退出模态由调用方处理,这里验证 current 归 nullptr
static void queue_nav_drain_to_empty() {
    ApprovalQueue q;
    q.push(qframe(1), 0); q.push(qframe(2), 0);
    q.onResolved(1, 0);
    q.onResolved(2, 0);
    assert(q.empty());
    assert(q.current() == nullptr);
    assert(q.currentIndex() == 0);
}

// ---------------------------------------------------------------------------
// main
// ---------------------------------------------------------------------------

int main() {
    printf("test_approval_protocol:\n");

    // 向量:0x55
    RUN(vec_encode_55_bytes_match);
    RUN(vec_encode_55_roundtrip);
    RUN(vec_decode_55_ok_clamp_semantics);
    RUN(vec_decode_55_err_all_rejected);
    RUN(encode_55_rejects_over_limit_fields);
    // 向量:0x36
    RUN(vec_encode_36_bytes_and_roundtrip);
    RUN(vec_decode_36_err_all_rejected);
    RUN(encode_36_rejects_bad_decision);
    // 向量:0x56
    RUN(vec_encode_56_bytes_and_roundtrip);
    RUN(vec_decode_56_unknown_treat_as);
    RUN(vec_decode_56_err_all_rejected);
    // 队列:push
    RUN(queue_push_arrival_event_and_size);
    RUN(queue_push_update_resets_content_and_expiry);
    RUN(queue_push_ignored_while_awaiting_ack);
    RUN(queue_push_update_reactivates_send_failed);
    RUN(queue_eviction_oldest_when_full);
    RUN(queue_eviction_includes_awaiting_ack_entry);
    // 队列:decide
    RUN(queue_decide_allow_sends_frame_and_awaits_ack);
    RUN(queue_decide_matrix_notify_only);
    RUN(queue_decide_matrix_always_disabled);
    RUN(queue_decide_matrix_risk2);
    RUN(queue_decide_unknown_reqid_and_bad_decision);
    RUN(queue_decide_rejected_when_not_active);
    RUN(queue_close_send_failed_locally);
    RUN(queue_dismiss_immediate_remove_single_send);
    // 队列:tick
    RUN(queue_resend_exactly_3_then_send_failed);
    RUN(queue_ack_between_resends);
    RUN(queue_expiry_active_entry);
    RUN(queue_expiry_zero_sec_immediate);
    RUN(queue_awaiting_ack_does_not_expire);
    RUN(queue_send_failed_expiry_fallback);
    RUN(queue_send_failed_and_expire_same_tick);
    RUN(queue_send_failed_then_resolved);
    RUN(queue_tick_multiple_entries_independent);
    // 队列:onResolved
    RUN(queue_on_resolved_event_mapping);
    RUN(queue_on_resolved_unknown_reqid_ignored);
    // 队列:导航
    RUN(queue_nav_empty);
    RUN(queue_nav_single_entry);
    RUN(queue_nav_cycle);
    RUN(queue_nav_remove_current_points_next);
    RUN(queue_nav_remove_last_current_wraps);
    RUN(queue_nav_remove_before_current_keeps_target);
    RUN(queue_nav_after_eviction);
    RUN(queue_nav_drain_to_empty);

    printf("PASS: %d tests\n", g_testCount);
    return 0;
}
