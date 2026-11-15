// v5_protocol.cpp — 见 v5_protocol.h
// 解析原则同 v4 parser:bounds-check 优先,短包/越界整帧丢弃不写半截。
#include "v5_protocol.h"
#include <string.h>

bool v5ParseSessions(const uint8_t *data, size_t len, V5Status &st) {
    if (!data || len < 3 || data[0] != V5_FRAME_SESSIONS) return false;
    uint8_t exIdx = data[1];
    uint8_t count = data[2];
    if (count > V5_MAX_SESSIONS) return false;

    // two-pass:先整体校验
    size_t cur = 3;
    for (uint8_t i = 0; i < count; i++) {
        if (cur + 5 > len) return false;
        uint8_t nameLen = data[cur + 4];
        if (nameLen >= sizeof(st.sessions[0].name)) return false;
        cur += 5 + nameLen;
        if (cur > len) return false;
    }

    SessionV5 tmp[V5_MAX_SESSIONS] = {};
    cur = 3;
    for (uint8_t i = 0; i < count; i++) {
        tmp[i].agentId  = data[cur + 0];
        tmp[i].state    = (data[cur + 1] <= SDS_THINKING) ? data[cur + 1] : (uint8_t)SDS_STALE;  // 未知新状态钳到 STALE;上界随枚举扩展(SDS_THINKING=8, 2026-07-23)
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
    // T-034:尾部可选 inactiveStart。老 Mac 不发 → cur == len → -1(无非活跃组)。
    // 越界值(>=count)同样落 -1,保证渲染侧不会拿到非法边界。
    st.inactiveStart = (cur < len && data[cur] < count) ? (int8_t)data[cur] : -1;
    st.valid        = true;
    return true;
}

bool v5ParseAgentInfo(const uint8_t *data, size_t len, V5Status &st) {
    if (!data || len < 2 || data[0] != V5_FRAME_AGENT_INFO) return false;
    uint8_t count = data[1];
    if (len < (size_t)2 + (size_t)count * 6) return false;
    uint8_t storedCount = (count < V5_MAX_AGENTS) ? count : V5_MAX_AGENTS;

    AgentInfoV5 tmp[V5_MAX_AGENTS] = {};
    size_t cur = 2;
    for (uint8_t i = 0; i < count; i++) {
        if (i < storedCount) {
            tmp[i].agentId      = data[cur + 0];
            // BUG-023: 0xFF = 窗口不存在哨兵,保留原值;其余 clamp 到 100
            tmp[i].usage5hPct   = (data[cur + 1] == V5_USAGE_UNKNOWN) ? V5_USAGE_UNKNOWN
                                : ((data[cur + 1] <= 100) ? data[cur + 1] : 100);
            tmp[i].usage7dPct   = (data[cur + 2] == V5_USAGE_UNKNOWN) ? V5_USAGE_UNKNOWN
                                : ((data[cur + 2] <= 100) ? data[cur + 2] : 100);
            tmp[i].resetInHours = data[cur + 3];
            tmp[i].activeCount  = data[cur + 4];
            tmp[i].totalCount   = data[cur + 5];
        }
        cur += 6;
    }

    // 可选扩展块(v1.0.6):[billingMode:1][dailyTokens:4 LE] × count,新 Mac 才发。
    // 老 Mac 只发核心 6B → hasExt=false,显式降级 SUBSCRIPTION + UNKNOWN(A2),
    // 不依赖 tmp 的零初始化(0=SUBSCRIPTION 恰好,但 dailyTokens 需 UNKNOWN 而非 0)。
    bool hasExt = (len >= (size_t)2 + (size_t)count * 6 + (size_t)count * 5);
    for (uint8_t i = 0; i < storedCount; i++) {
        if (hasExt) {
            size_t e = 2 + (size_t)count * 6 + (size_t)i * 5;
            tmp[i].billingMode = (data[e] <= V5_BILLING_CREDITS)
                ? data[e] : V5_BILLING_SUBSCRIPTION;
            tmp[i].dailyTokens = (uint32_t)data[e+1] | ((uint32_t)data[e+2]<<8)
                               | ((uint32_t)data[e+3]<<16) | ((uint32_t)data[e+4]<<24);
        } else {
            tmp[i].billingMode = V5_BILLING_SUBSCRIPTION;   // A2:老 Mac 走订阅渲染
            tmp[i].dailyTokens = V5_DAILY_TOKENS_UNKNOWN;
        }
        tmp[i].metricKind = (tmp[i].billingMode == V5_BILLING_API)
            ? V5_AGENT_METRIC_DAILY_TOKENS
            : ((tmp[i].billingMode == V5_BILLING_CREDITS)
               ? V5_AGENT_METRIC_CUMULATIVE_CREDITS : V5_AGENT_METRIC_QUOTA);
    }

    // 可选动态元数据:[metricKind][nameLen][name] × 原始 count。
    // 按原始 count 定位，Host 可发送超过本机显示上限的未来 Agent；本机只保存前 4 个。
    size_t meta = (size_t)2 + (size_t)count * 6 + (size_t)count * 5;
    for (uint8_t i = 0; hasExt && i < count && meta < len; i++) {
        if (meta + 2 > len) break;
        uint8_t metric = data[meta++];
        uint8_t nameLen = data[meta++];
        if (meta + nameLen > len) break;
        if (i < storedCount) {
            tmp[i].metricKind = (metric <= V5_AGENT_METRIC_COUNTS_ONLY)
                ? metric : V5_AGENT_METRIC_COUNTS_ONLY;
            size_t copyLen = nameLen < sizeof(tmp[i].displayName)
                ? nameLen : sizeof(tmp[i].displayName) - 1;
            if (copyLen > 0) memcpy(tmp[i].displayName, data + meta, copyLen);
            tmp[i].displayName[copyLen] = '\0';
        }
        meta += nameLen;
    }

    memcpy(st.agents, tmp, sizeof(tmp));
    st.agentCount = storedCount;
    st.valid      = true;
    return true;
}

bool v5ParseConfig(const uint8_t *data, size_t len, V5Config &cfg) {
    if (!data || len < 3 || data[0] != V5_FRAME_CONFIG) return false;
    uint8_t mode  = data[1];
    uint8_t count = data[2];
    if (mode > V5_VOICE_MODE_TOGGLE) return false;
    if (count > V5_MAX_PROMPTS) return false;

    size_t cur = 3;
    for (uint8_t i = 0; i < count; i++) {
        if (cur >= len) return false;
        uint8_t l = data[cur];
        if (l >= V5_PROMPT_TITLE_CAP) return false;
        cur += 1 + l;
        if (cur > len) return false;
    }

    V5Config tmp = {};
    tmp.voiceMode   = mode;
    tmp.promptCount = count;
    cur = 3;
    for (uint8_t i = 0; i < count; i++) {
        uint8_t l = data[cur];
        if (l > 0) memcpy(tmp.promptTitles[i], data + cur + 1, l);
        tmp.promptTitles[i][l] = '\0';
        cur += 1 + l;
    }
    // 尾部扩展按追加顺序解析。老 Host 不发任何尾字节时使用设备麦并保留 NVS 语言;
    // 只发 micSource 的既有 Host 也不会误把它当成语言。
    tmp.micSource = (cur < len && data[cur] <= V5_MIC_SOURCE_SYSTEM)
                    ? data[cur] : V5_MIC_SOURCE_DEVICE;
    if (cur < len) cur++;
    tmp.hasLanguage = cur < len && data[cur] <= V5_UI_LANGUAGE_ZH_HANT;
    tmp.language = tmp.hasLanguage ? data[cur] : V5_UI_LANGUAGE_EN;
    if (cur < len) cur++;
    tmp.laboratoryFeatures = cur < len ? (data[cur] & V5_LAB_KNOWN_MASK) : 0;
    tmp.valid = true;
    cfg = tmp;
    return true;
}

bool v5ParseTime(const uint8_t *data, size_t len, uint16_t *outMinOfDay) {
    if (!data || len < 3 || data[0] != V5_FRAME_TIME || !outMinOfDay) return false;
    uint16_t m = (uint16_t)data[1] | ((uint16_t)data[2] << 8);
    if (m >= 1440) return false;   // 哨兵/越界:固件保持 --:--
    *outMinOfDay = m;
    return true;
}

bool v5ParsePromptRecommendations(const uint8_t *data, size_t len,
                                  uint8_t expectedRequestId, UiModeCtx &ctx) {
    if (!data || len < 3 || data[0] != V5_FRAME_PROMPT_RECOMMENDATIONS ||
        data[1] != expectedRequestId || data[2] > 1) return false;
    if (data[2] == 0) {
        if (len != 3) return false;
        ctx.promptDynamic = true;
        ctx.promptLoading = true;
        return true;
    }
    if (len < 4 || data[3] > V5_MAX_PROMPTS) return false;
    uint8_t count = data[3];
    size_t cur = 4;
    char parsed[V5_MAX_PROMPTS][V5_PROMPT_TITLE_CAP] = {};
    for (uint8_t i = 0; i < count; i++) {
        if (cur >= len) return false;
        uint8_t titleLen = data[cur++];
        if (titleLen == 0 || titleLen >= V5_PROMPT_TITLE_CAP || cur + titleLen > len) return false;
        memcpy(parsed[i], data + cur, titleLen);
        parsed[i][titleLen] = '\0';
        cur += titleLen;
    }
    if (cur != len) return false;
    memcpy(ctx.promptTitles, parsed, sizeof(parsed));
    ctx.promptCount = count;
    ctx.promptDynamic = true;
    ctx.promptLoading = false;
    return true;
}

bool v5ParseInputAssistant(const uint8_t *data, size_t len,
                           uint8_t expectedRequestId, UiModeCtx &ctx) {
    if (!data || len < 3 || data[0] != V5_FRAME_INPUT_ASSISTANT ||
        data[1] != expectedRequestId || data[2] > 5) return false;
    const uint8_t state = data[2];
    if (state != 1) {
        if (len != 3) return false;
        ctx.assistantState = state;
        return true;
    }
    if (len < 7 || data[3] > 1 || data[4] >= sizeof(ctx.assistantPreview)) return false;
    size_t cur = 5;
    const uint8_t previewLen = data[4];
    if (cur + previewLen >= len) return false;
    char preview[sizeof(ctx.assistantPreview)] = {};
    memcpy(preview, data + cur, previewLen); cur += previewLen;
    const uint8_t count = data[cur++];
    if (count == 0 || count > V5_MAX_PROMPTS) return false;
    char titles[V5_MAX_PROMPTS][V5_PROMPT_TITLE_CAP] = {};
    for (uint8_t i = 0; i < count; i++) {
        if (cur >= len) return false;
        const uint8_t n = data[cur++];
        if (n == 0 || n >= V5_PROMPT_TITLE_CAP || cur + n > len) return false;
        memcpy(titles[i], data + cur, n); titles[i][n] = '\0'; cur += n;
    }
    if (cur != len) return false;
    memcpy(ctx.assistantPreview, preview, sizeof(preview));
    memcpy(ctx.assistantTitles, titles, sizeof(titles));
    ctx.assistantSelectedScope = data[3] != 0;
    ctx.assistantCount = count;
    if (ctx.assistantSel < 0 || ctx.assistantSel >= count) ctx.assistantSel = 0;
    ctx.assistantState = state;
    return true;
}
