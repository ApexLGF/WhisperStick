// T-034:0x51 会话帧尾部 inactiveStart 字节的解析、向后兼容,与显示行↔会话下标映射。
// 纯 assert,不依赖 gtest(见 README.md:19「gtest 未安装」)。
//
//   g++ -std=c++17 -I.. test_v5_sessions_group.cpp ../v5_protocol.cpp ../session_rows.cpp \
//       -o /tmp/t034 && /tmp/t034
#include <assert.h>
#include <stdint.h>
#include <stddef.h>
#include <stdio.h>
#include <string.h>
#include <vector>
#include <string>

#include "../v5_protocol.h"
#include "../session_rows.h"

// ── 帧构造工具 ────────────────────────────────────────────────────────────────
// [0x51][exclusiveIdx][count] × { agentId,state,ctxPct,colorIdx,nameLen,name }
static std::vector<uint8_t> buildSessionsFrame(uint8_t exclusiveIdx,
                                               const std::vector<std::string> &names,
                                               int inactiveStart /* <0 = 不追加尾字节 */) {
    std::vector<uint8_t> d;
    d.push_back(V5_FRAME_SESSIONS);
    d.push_back(exclusiveIdx);
    d.push_back((uint8_t)names.size());
    for (size_t i = 0; i < names.size(); i++) {
        d.push_back(0);                       // agentId
        d.push_back((uint8_t)SDS_READY);      // state
        d.push_back(50);                      // ctxPct
        d.push_back((uint8_t)i);              // colorIdx
        d.push_back((uint8_t)names[i].size());
        for (char c : names[i]) d.push_back((uint8_t)c);
    }
    if (inactiveStart >= 0) d.push_back((uint8_t)inactiveStart);
    return d;
}

// 基线(T-034 之前)的 v5ParseSessions 逐字拷贝 —— 用于用例 C4「老固件吃新帧」。
// 与当前实现的唯一差别:没有尾字节 inactiveStart 的处理。
struct LegacySession { char name[48]; uint8_t agentId, state, ctxPct, colorIdx; };
struct LegacyStatus {
    uint8_t       sessionCount;
    LegacySession sessions[V5_MAX_SESSIONS];
    int8_t        exclusiveIdx;
    bool          valid;
};

static bool legacyParseSessions(const uint8_t *data, size_t len, LegacyStatus &st) {
    if (!data || len < 3 || data[0] != V5_FRAME_SESSIONS) return false;
    uint8_t exIdx = data[1];
    uint8_t count = data[2];
    if (count > V5_MAX_SESSIONS) return false;

    size_t cur = 3;
    for (uint8_t i = 0; i < count; i++) {
        if (cur + 5 > len) return false;
        uint8_t nameLen = data[cur + 4];
        if (nameLen >= sizeof(st.sessions[0].name)) return false;
        cur += 5 + nameLen;
        if (cur > len) return false;
    }

    LegacySession tmp[V5_MAX_SESSIONS] = {};
    cur = 3;
    for (uint8_t i = 0; i < count; i++) {
        tmp[i].agentId  = data[cur + 0];
        tmp[i].state    = (data[cur + 1] <= SDS_THINKING) ? data[cur + 1] : (uint8_t)SDS_STALE;
        tmp[i].ctxPct   = data[cur + 2];
        tmp[i].colorIdx = data[cur + 3];
        uint8_t nameLen = data[cur + 4];
        if (nameLen > 0) memcpy(tmp[i].name, data + cur + 5, nameLen);
        tmp[i].name[nameLen] = '\0';
        cur += 5 + nameLen;
    }

    memcpy(st.sessions, tmp, sizeof(tmp));
    st.sessionCount = count;
    st.exclusiveIdx = (exIdx < count) ? (int8_t)exIdx : -1;
    st.valid        = true;
    return true;
}

static V5Status mkStatus(uint8_t count, int8_t inactiveStart) {
    V5Status st = {};
    st.inactiveStart = -1;
    st.sessionCount  = count;
    st.exclusiveIdx  = -1;
    st.inactiveStart = inactiveStart;
    st.valid         = true;
    return st;
}

int main() {
    // ── C1:老 Mac 帧(无尾字节)→ inactiveStart == -1 ───────────────────────
    {
        auto f = buildSessionsFrame(0xFF, {"alpha", "beta"}, -1);
        V5Status st = {};
        st.inactiveStart = 7;                     // 故意脏值,证明 parser 会覆写
        assert(v5ParseSessions(f.data(), f.size(), st));
        assert(st.sessionCount == 2);
        assert(st.inactiveStart == -1);
        assert(strcmp(st.sessions[0].name, "alpha") == 0);
        assert(strcmp(st.sessions[1].name, "beta") == 0);
        assert(st.sessions[0].state == SDS_READY);
        assert(st.exclusiveIdx == -1);
        printf("C1 ok  老 Mac 帧(无尾字节)→ inactiveStart=-1,会话解析正确\n");
    }

    // ── C2:新帧尾追 3(count=5)→ inactiveStart == 3 ────────────────────────
    {
        auto f = buildSessionsFrame(1, {"s0", "s1", "s2", "s3", "s4"}, 3);
        V5Status st = {};
        assert(v5ParseSessions(f.data(), f.size(), st));
        assert(st.sessionCount == 5);
        assert(st.inactiveStart == 3);
        assert(st.exclusiveIdx == 1);
        assert(strcmp(st.sessions[4].name, "s4") == 0);
        printf("C2 ok  新帧尾字节 3(count=5)→ inactiveStart=3\n");
    }

    // ── C3:越界尾字节 9(count=5)→ 钳到 -1 ─────────────────────────────────
    {
        auto f = buildSessionsFrame(0xFF, {"s0", "s1", "s2", "s3", "s4"}, 9);
        V5Status st = {};
        assert(v5ParseSessions(f.data(), f.size(), st));
        assert(st.sessionCount == 5);
        assert(st.inactiveStart == -1);
        // 边界值 count 本身也越界(合法下标是 0..count-1)
        auto f2 = buildSessionsFrame(0xFF, {"s0", "s1", "s2", "s3", "s4"}, 5);
        V5Status st2 = {};
        assert(v5ParseSessions(f2.data(), f2.size(), st2));
        assert(st2.inactiveStart == -1);
        printf("C3 ok  越界尾字节(9 / 5,count=5)→ 钳到 -1\n");
    }

    // ── C4:**老 parser 吃新帧** → 仍 return true 且 5 条会话全对(向后兼容硬证据)──
    {
        auto f = buildSessionsFrame(2, {"s0", "s1", "s2", "s3", "s4"}, 3);
        LegacyStatus st = {};
        assert(legacyParseSessions(f.data(), f.size(), st));   // 尾字节被静默忽略
        assert(st.valid);
        assert(st.sessionCount == 5);
        assert(st.exclusiveIdx == 2);
        const char *want[5] = {"s0", "s1", "s2", "s3", "s4"};
        for (int i = 0; i < 5; i++) assert(strcmp(st.sessions[i].name, want[i]) == 0);
        printf("C4 ok  基线 parser 吃新帧:return true,5 条会话逐字正确(向后兼容)\n");
    }

    // ── C5:inactiveStart=3, count=7 的行映射(折叠 4 行 / 展开 8 行)──────────
    {
        V5Status st = mkStatus(7, 3);
        assert(ui_active_count(st) == 3);
        assert(ui_inactive_shown(st) == 4);

        // 折叠:3 活跃 + 标签 = 4 行
        assert(ui_row_count(st, false) == 4);
        for (int r = 0; r < 3; r++) assert(ui_row_to_session(st, false, r) == r);
        assert(ui_row_to_session(st, false, 3) == -1);      // 标签行
        assert(ui_row_to_session(st, false, 4) == -2);      // 越界
        assert(ui_row_to_session(st, false, -1) == -2);
        for (int s = 0; s < 3; s++) assert(ui_session_to_row(st, false, s) == s);
        for (int s = 3; s < 7; s++) assert(ui_session_to_row(st, false, s) == -1);

        // 展开:3 活跃 + 标签 + 4 非活跃 = 8 行
        assert(ui_row_count(st, true) == 8);
        assert(ui_row_to_session(st, true, 3) == -1);       // 标签行
        for (int k = 0; k < 4; k++) assert(ui_row_to_session(st, true, 4 + k) == 3 + k);
        assert(ui_row_to_session(st, true, 8) == -2);
        for (int s = 0; s < 3; s++) assert(ui_session_to_row(st, true, s) == s);
        for (int k = 0; k < 4; k++) assert(ui_session_to_row(st, true, 3 + k) == 4 + k);
        // 往返一致性:行→会话→行
        for (int r = 0; r < 8; r++) {
            int s = ui_row_to_session(st, true, r);
            if (s >= 0) assert(ui_session_to_row(st, true, s) == r);
        }

        // 无分组(inactiveStart=-1)退化为纯会话列表
        V5Status plain = mkStatus(3, -1);
        assert(ui_active_count(plain) == 3);
        assert(ui_inactive_shown(plain) == 0);
        assert(ui_row_count(plain, false) == 3 && ui_row_count(plain, true) == 3);
        assert(ui_row_to_session(plain, true, 2) == 2);
        assert(ui_row_to_session(plain, true, 3) == -2);
        assert(ui_session_to_row(plain, false, 1) == 1);
        printf("C5 ok  行映射(inactiveStart=3,count=7)折叠 4 行 / 展开 8 行 + 无分组退化\n");
    }

    // ── C6:inactiveStart=1, count=8(7 条非活跃)→ 设备端 5 条截断生效 ────────
    {
        V5Status st = mkStatus(8, 1);
        assert(ui_active_count(st) == 1);
        assert(ui_inactive_shown(st) == V5_DEV_INACTIVE_CAP);   // 7 → 5
        assert(V5_DEV_INACTIVE_CAP == 5);
        assert(ui_row_count(st, false) == 2);                   // 1 活跃 + 标签
        assert(ui_row_count(st, true) == 1 + 1 + 5);            // == 7,不是 1+1+7
        assert(ui_row_to_session(st, true, 1) == -1);           // 标签行
        for (int k = 0; k < 5; k++) assert(ui_row_to_session(st, true, 2 + k) == 1 + k);
        assert(ui_row_to_session(st, true, 7) == -2);           // 第 6 条非活跃不可达
        assert(ui_session_to_row(st, true, 6) == -1);           // 被截掉的会话无显示行
        assert(ui_session_to_row(st, true, 7) == -1);
        printf("C6 ok  7 条非活跃 → 设备端截断到 5 条(展开 %d 行)\n", ui_row_count(st, true));
    }

    printf("ALL PASS (6 cases)\n");
    return 0;
}
