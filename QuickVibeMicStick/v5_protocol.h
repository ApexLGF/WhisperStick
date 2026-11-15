// v5_protocol.h — 协议 v5 帧解析(REQ-007)
// Mac → 设备,经 CLAUDE_STATUS characteristic 写入,首字节 = 帧类型:
//   0x51 SESSIONS   会话列表(事件驱动,500ms 去抖)
//   0x52 AGENT_INFO 每 Agent 用量/统计(60s 周期 + 会话数变化即推)
//   0x53 CONFIG     语音模式 + 自定义 Prompt 标题(连接时下发,变更重推)
// v4 帧首字节是 phase(0..5/0xFF),与 0x5X 无碰撞,可共存路由。
#pragma once
#include <stdint.h>
#include <stddef.h>
#include "ui_model.h"
#include "action_mode_protocol.h"
#include "application_switcher_protocol.h"
#include "task_lifecycle_protocol.h"

#define V5_FRAME_SESSIONS   0x51
#define V5_FRAME_AGENT_INFO 0x52
#define V5_FRAME_CONFIG     0x53
#define V5_FRAME_TIME       0x54    // T-025:Mac 下发当日分钟数(0..1439),固件 millis 累加走时
#define V5_FRAME_PROMPT_RECOMMENDATIONS 0x58
#define V5_FRAME_INPUT_ASSISTANT 0x59

#define V5_MAX_PROMPTS      8      // 自定义条数上限(内置项设备端固定置顶,不占额度)
#define V5_PROMPT_TITLE_CAP 25     // 8 个中文 = 24B UTF-8 + NUL

#define V5_VOICE_MODE_PTT    0
#define V5_VOICE_MODE_TOGGLE 1     // 长语音:单击开始/再单击停止

// T-033:0x53 尾部追加的音源模式(Mac→设备)。老固件不解析尾字节,按 DEVICE 行为。
#define V5_MIC_SOURCE_DEVICE 0     // 设备麦(INMP441/PDM):I2S → ADPCM → BLE 上传
#define V5_MIC_SOURCE_SYSTEM 1     // 系统麦(Mac 侧采集):设备只发 0x19/0x14 命令,不上传音频

// 0x53 第二个可选尾字节:设备界面语言。缺省时保留设备 NVS 中的现有语言。
#define V5_UI_LANGUAGE_EN      0
#define V5_UI_LANGUAGE_ZH_HANS 1
#define V5_UI_LANGUAGE_ZH_HANT 2

// 0x53 第三个可选尾字节:实验室功能开关。缺省为全部关闭。
#define V5_LAB_PROMPT_RECOMMENDATIONS (1u << 0)
#define V5_LAB_INPUT_ASSISTANT        (1u << 1)
#define V5_LAB_KNOWN_MASK (V5_LAB_PROMPT_RECOMMENDATIONS | V5_LAB_INPUT_ASSISTANT)

struct V5Config {
    uint8_t voiceMode;                                   // V5_VOICE_MODE_*
    uint8_t promptCount;                                 // 0..8
    char    promptTitles[V5_MAX_PROMPTS][V5_PROMPT_TITLE_CAP];
    uint8_t micSource;                                   // T-033: V5_MIC_SOURCE_*;缺省 DEVICE
    uint8_t language;                                    // V5_UI_LANGUAGE_*;仅 hasLanguage=true 有效
    bool    hasLanguage;                                 // 老 Host 无第二个尾字节时为 false
    uint8_t laboratoryFeatures;                          // V5_LAB_*;缺省 0
    bool    valid;
};

// 判断此负载是否为 v5 帧(路由用)
static inline bool v5IsFrame(const uint8_t *data, size_t len) {
    return data && len >= 1 &&
           ((data[0] >= V5_FRAME_SESSIONS && data[0] <= V5_FRAME_TIME) ||
            data[0] == V5_FRAME_ACTION_MODE || data[0] == V5_FRAME_PROMPT_RECOMMENDATIONS ||
            data[0] == V5_FRAME_INPUT_ASSISTANT ||
            data[0] == V5_FRAME_TASK_LIFECYCLE ||
            data[0] == V5_FRAME_APPLICATION_SWITCHER);
}

// SESSIONS 帧:只更新 st 的会话部分(agents 保留),成功置 st.valid=true
// layout: [0x51][exclusiveIdx:1 0xFF=无][count:1]
//         × { [agentId:1][state:1][ctxPct:1][colorIdx:1][nameLen:1][name:N] }
//         [inactiveStart:1 可选]  // T-034: 非活跃组起始下标;0xFF/缺省 = 无非活跃组
//   老固件解析完 count 条后不校验 cur==len,尾字节被静默忽略 → 向后兼容,版本仍为 5。
bool v5ParseSessions(const uint8_t *data, size_t len, V5Status &st);

// AGENT_INFO 帧(v1.0.6 扩展,handshake 版本仍为 5,向后兼容):
// layout: [0x52][count:1]
//   × count { [agentId][usage5h][usage7d][resetInHours][active][total] }  // 核心 6B,不变
//   × count { [billingMode:1][dailyTokens:4 LE] }                          // 可选扩展块,新 Mac 才发
//   × count { [metricKind:1][nameLen:1][nameUtf8:N] }                      // 可选动态元数据
// 老固件:len 更长时忽略尾部;新固件:len>=2+count*6+count*5 时解析扩展。
// 只更新 st 的 agents 部分,成功置 st.valid=true
bool v5ParseAgentInfo(const uint8_t *data, size_t len, V5Status &st);

// CONFIG 帧
// layout: [0x53][voiceMode:1][promptCount:1] × { [len:1][titleUtf8:N] }
//         [micSource:1 可选][language:1 可选][laboratoryFeatures:1 可选]
//   micSource 是 T-033 追加的尾字节,老固件按未知尾部忽略(与 0x52 扩展块同法)。
//   language 再追加于 micSource 后:老固件继续忽略;新固件遇到缺省/越界语言时保留 NVS。
//   laboratoryFeatures 再追加于 language 后;缺省为 0(实验功能全部关闭)。
//   micSource 缺省/越界 → V5_MIC_SOURCE_DEVICE。handshake 版本仍为 5,不得 bump。
bool v5ParseConfig(const uint8_t *data, size_t len, V5Config &cfg);

// TIME 帧(T-025):[0x54][minOfDay:2 LE] — 当日分钟数 0..1439;≥1440 = 无效哨兵
// 成功写 *outMinOfDay 且 return true;短包/越界/哨兵 return false(固件保持 --:--)
bool v5ParseTime(const uint8_t *data, size_t len, uint16_t *outMinOfDay);

bool v5ParsePromptRecommendations(const uint8_t *data, size_t len,
                                  uint8_t expectedRequestId, UiModeCtx &ctx);
bool v5ParseInputAssistant(const uint8_t *data, size_t len,
                           uint8_t expectedRequestId, UiModeCtx &ctx);
