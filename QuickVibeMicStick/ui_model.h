// ui_model.h — 协议 v5 UI 数据模型(REQ-007/008/009)
// 设备端渲染只认这里的结构;数据来源两条路:
//   1) v5 帧解析(v5_protocol,REQ-007)
//   2) 固件 mock(串口 MOCK 命令,REQ-008 布局验证)
#pragma once
#include <stdint.h>
#include "action_mode_protocol.h"
#include "application_switcher_protocol.h"

// ── 会话显示状态(agent-signal-bar 8 态 DisplayState)──────
// 颜色语义:绿=正常 / 黄=仅 needs_review / 红=仅 permission+blocked /
//          灰=暂停或不可信(stale 的"灰黄"归灰,REQ-009 决策)/ 蓝=thinking(模型推理中)
enum SessionDisplayState : uint8_t {
    SDS_READY        = 0,  // 绿 常亮
    SDS_ACTIVE       = 1,  // 绿 呼吸
    SDS_COMPLETED    = 2,  // 绿 短闪
    SDS_STALE        = 3,  // 灰 慢闪
    SDS_NEEDS_REVIEW = 4,  // 黄 慢闪
    SDS_PERMISSION   = 5,  // 红 慢闪+缩放
    SDS_BLOCKED      = 6,  // 红 快闪
    SDS_PAUSED       = 7,  // 灰 静止
    SDS_THINKING     = 8,  // 蓝 呼吸(模型推理中:CC=hook 事件对推断;Codex=rollout reasoning 尾события)
};

#define V5_MAX_AGENTS    4
#define V5_MAX_SESSIONS  12
#define V5_CTX_UNKNOWN   0xFF   // ctx 余量未知(codex 等)→ 显示 "--"
#define V5_RESET_UNKNOWN 0xFF   // 重置时间未知
#define V5_USAGE_UNKNOWN 0xFF   // 用量窗口不存在(codex free 档无 7d 窗)→ 空条 "--"(BUG-023)
#define V5_RESET_DAYS_BASE 200  // resetInHours 编码:≤200=小时;201..254=(值-200)天(BUG-023,长窗口超 UInt8)
#define V5_DEV_INACTIVE_CAP 5   // T-034/REQ-028 §4:设备端非活跃组渲染上限(Mac 也截,固件再兜一次)

// Agent 身份(协议 v5 agentId)
enum AgentId : uint8_t {
    AGENT_CLAUDE_CODE = 0,
    AGENT_CODEX       = 1,
    AGENT_WORKBUDDY   = 2,
};

// billingMode 取值(REQ-020)
#define V5_BILLING_SUBSCRIPTION 0
#define V5_BILLING_API          1
#define V5_BILLING_CREDITS      2
#define V5_DAILY_TOKENS_UNKNOWN 0xFFFFFFFFu  // 无扩展块/不可用 → 显示 "API" 而非数字(A2)

#define V5_AGENT_METRIC_QUOTA               0
#define V5_AGENT_METRIC_DAILY_TOKENS        1
#define V5_AGENT_METRIC_CUMULATIVE_CREDITS  2
#define V5_AGENT_METRIC_COUNTS_ONLY         3

struct AgentInfoV5 {
    uint8_t  agentId;
    uint8_t  usage5hPct;    // 0..100;V5_USAGE_UNKNOWN=窗口不存在
    uint8_t  usage7dPct;    // 0..100;V5_USAGE_UNKNOWN=窗口不存在
    uint8_t  resetInHours;  // 主窗口重置剩余:≤200 小时;201..254=(值-200)天;V5_RESET_UNKNOWN=未知
    uint8_t  activeCount;   // M
    uint8_t  totalCount;    // N
    uint8_t  billingMode;   // V5_BILLING_*;老 Mac 无扩展块时默认 SUBSCRIPTION(A2)
    uint32_t dailyTokens;   // 当日累计 token;V5_DAILY_TOKENS_UNKNOWN=不可用(A2)
    uint8_t  metricKind;    // V5_AGENT_METRIC_*;决定渲染语义
    char     displayName[16]; // Host 下发名称;空串按 agentId 回退
};

struct SessionV5 {
    char    name[48];      // UTF-8,CJK ~15 字
    uint8_t agentId;
    uint8_t state;         // SessionDisplayState
    uint8_t ctxPct;        // context 余量%;V5_CTX_UNKNOWN → "--"
    uint8_t colorIdx;      // 会话颜色索引(直通高亮用,11 色调色板)
};

struct V5Status {
    uint8_t     agentCount;
    AgentInfoV5 agents[V5_MAX_AGENTS];
    uint8_t     sessionCount;
    SessionV5   sessions[V5_MAX_SESSIONS];
    int8_t      exclusiveIdx;   // -1=无直通
    int8_t      inactiveStart;  // T-034: 非活跃组起始下标;-1=无非活跃组。**零初始化不等于无,必须显式置 -1**
    bool        valid;
};

// ── 会话列表视图状态(REQ-013 框选/滚动;REQ-008 先透传默认值)──
struct UiListSel {
    int8_t  framedIdx;   // 线框当前行(全列表索引);-1 无
    bool    visible;     // 线框是否显示(旋转出现,超时隐藏)
    uint8_t scrollTop;   // 列表滚动:首个可见会话的索引
    bool    inactiveExpanded;   // T-034: 非活跃组展开态;默认折叠(REQ-028 §3),BLE 断连复位
};

// ── 设备 UI 模式(REQ-011 Prompt 选择 / REQ-012 文字编辑 / REQ-022 审批模态)──
// 数值同时是 CMD_DEVICE_MODE(0x34)线上枚举:只准追加,不得改既有值
enum DeviceUiMode : uint8_t {
    DEV_MODE_NORMAL   = 0,
    DEV_MODE_EDIT     = 1,
    DEV_MODE_PROMPT   = 2,
    DEV_MODE_APPROVAL = 3,   // REQ-022 设备端审批模态
    DEV_MODE_ACTION   = 4,   // Host 下发定义的通用 B/C/D 动作模式
    DEV_MODE_INPUT_ASSISTANT = 5,
    DEV_MODE_APP_SWITCHER = 6,
};

// 模式渲染上下文(输入侧维护,渲染侧只读)
struct UiModeCtx {
    uint8_t  mode;         // DeviceUiMode
    int8_t   promptSel;    // Prompt 高亮行(0=内置"AI推荐",1..N=自定义)
    bool     deleting;     // REQ-011: B 长按连删进行中(浮窗计数动画)
    uint16_t delCount;     // 连删已删除字符数
    char     editEcho[20]; // REQ-012: 编辑模式按键回显(UTF-8)
    bool     promptDynamic;
    bool     promptLoading;
    uint8_t  promptRequestId;
    uint8_t  promptCount;
    char     promptTitles[8][25];
    uint8_t  assistantRequestId;
    uint8_t  assistantState;       // 0 loading,1 ready,2 processing,3 retryable,4 fatal,5 success
    bool     assistantSelectedScope;
    int8_t   assistantSel;
    uint8_t  assistantCount;
    char     assistantPreview[49];
    char     assistantTitles[8][25];
    ActionModeDefinition actionMode;
    ApplicationSwitcherDefinition applicationSwitcher;
};
