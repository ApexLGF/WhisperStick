// claude_status_parser.h
// Stage 2: V4 ClaudeStatus / PermissionRequest / VOICE_NOTIFY 解析器
// 从 QuickVibeStickS3 移植,简化为纯解析(不渲染屏幕)。
// 设计原则:
//   - bounds-check 优先;短包/越界返回 false,不写出。
//   - 2 字节 LE 字段统一用 memcpy(避免对齐 + endianness 隐患)。
//   - dashCount 上限截断到 DASH_MAX_SESSIONS,防止结构体越界。

#pragma once
#include <stdint.h>
#include <stddef.h>

// ── 常量 ─────────────────────────────────────────────────
#define DASH_MAX_SESSIONS 5

// ── 内存结构体(供 .ino 全局变量引用) ─────────────────────
struct ClaudeStatusState {
    uint8_t  phase;
    uint8_t  sessionCount;
    uint8_t  colorIndex;
    char     projName[48];
    char     toolName[48];
    uint8_t  usagePct;
    uint8_t  ctxPct;
    uint16_t tokenInK;
    uint16_t tokenOutK;
    uint16_t linesAdded;
    uint16_t linesRemoved;
    uint8_t  dashCount;
    struct Dash {
        char    name[48];   // CJK 一字 3 字节,48B 容 ~15 汉字 / 47 ASCII
        uint8_t colorIdx;
        uint8_t phase;
    } dashes[DASH_MAX_SESSIONS];
    int8_t   exclusiveIdx;   // V4 新增;-1 表示无 exclusive(老 Mac App)
    bool     valid;
};

struct PermissionToastState {
    char          tool[64];
    char          input[256];
    unsigned long expiresAt;   // millis() + 3000
    bool          active;
};

struct AsrFeedbackState {
    bool          isFailure;
    uint8_t       buttonId;
    char          message[64];
    unsigned long expiresAt;
    bool          active;
};

// ── Parsers ──────────────────────────────────────────────
// 返回 false 时 out 状态未保证(调用方应当忽略本帧)。
bool parseClaudeStatus(const uint8_t *data, size_t len, ClaudeStatusState &out);

// JSON: {"tool":"X","input":"Y","id":"Z"}
bool parsePermissionRequest(const uint8_t *data, size_t len, PermissionToastState &out);

// cmd = VOICE_NOTIFY_SUCCESS (0x06) | VOICE_NOTIFY_FAILURE (0x07)
// data 是 control char 的完整 payload(含 cmd 头)。
bool parseVoiceNotify(uint8_t cmd, const uint8_t *data, size_t len, AsrFeedbackState &out);
