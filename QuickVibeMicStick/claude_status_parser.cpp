// claude_status_parser.cpp - 见 .h 设计说明
// 注意:Arduino IDE 会把同目录下 .h/.cpp 自动加入编译。

#include "claude_status_parser.h"
#include <string.h>
#include <stdio.h>

// ── ClaudeStatus V4 payload ──────────────────────────────
// [phase:1][sessionCount:1][colorIndex:1][projLen:1][projName:N]
// [toolLen:1][toolName:N][usagePct:1][ctxPct:1]
// [tokenInK:2LE][tokenOutK:2LE][linesAdded:2LE][linesRemoved:2LE]
// [dashCount:1] x dashCount: [nameLen:1][name:N][colorIdx:1][phase:1]
// [exclusiveIdx:1]   ← V4 新增,可选(老 Mac App 没有就置 -1)
bool parseClaudeStatus(const uint8_t *data, size_t len, ClaudeStatusState &out) {
    // 最少需要:phase + sessionCount + colorIndex + projLen
    if (data == nullptr || len < 4) return false;

    ClaudeStatusState tmp = {};
    tmp.exclusiveIdx = -1;

    tmp.phase        = data[0];
    tmp.sessionCount = data[1];
    tmp.colorIndex   = data[2];

    // -- project name --
    uint8_t projLen = data[3];
    if (projLen > sizeof(tmp.projName) - 1) projLen = sizeof(tmp.projName) - 1;
    if ((size_t)(4 + projLen) > len) return false;
    if (projLen > 0) memcpy(tmp.projName, data + 4, projLen);
    tmp.projName[projLen] = '\0';

    size_t toolOff = 4 + projLen;

    // -- tool name (optional) --
    uint8_t toolLen = 0;
    if (toolOff < len) {
        toolLen = data[toolOff];
        if (toolLen > sizeof(tmp.toolName) - 1) toolLen = sizeof(tmp.toolName) - 1;
        if (toolOff + 1 + toolLen > len) return false;
        if (toolLen > 0) memcpy(tmp.toolName, data + toolOff + 1, toolLen);
    }
    tmp.toolName[toolLen] = '\0';

    // -- usage / ctx --
    size_t usageOff = toolOff + 1 + toolLen;
    if (usageOff + 2 <= len) {
        tmp.usagePct = data[usageOff];
        tmp.ctxPct   = data[usageOff + 1];
    }

    // -- v3+ dashboard suffix (optional) --
    size_t dashOff = usageOff + 2;
    tmp.dashCount = 0;
    if (dashOff + 9 <= len) {
        // 2-byte LE x 4 -> tokens / lines
        memcpy(&tmp.tokenInK,    data + dashOff + 0, 2);
        memcpy(&tmp.tokenOutK,   data + dashOff + 2, 2);
        memcpy(&tmp.linesAdded,  data + dashOff + 4, 2);
        memcpy(&tmp.linesRemoved,data + dashOff + 6, 2);

        uint8_t declared = data[dashOff + 8];
        // Mac 端宣告超过设备上限 → 拒绝整个 dashboard(对齐 Stick S3 行为)
        if (declared > DASH_MAX_SESSIONS) {
            tmp.dashCount = 0;
        } else {
            // Two-pass:先 validate,失败就整体丢弃,不写半截。
            size_t cursor = dashOff + 9;
            bool dashValid = true;
            for (uint8_t i = 0; i < declared; i++) {
                if (cursor >= len) { dashValid = false; break; }
                uint8_t nameLen = data[cursor];
                if (nameLen > sizeof(tmp.dashes[0].name) - 1) { dashValid = false; break; }
                if (cursor + 1 + nameLen + 2 > len) { dashValid = false; break; }
                cursor += 1 + nameLen + 2;
            }
            if (dashValid) {
                cursor = dashOff + 9;
                for (uint8_t i = 0; i < declared; i++) {
                    uint8_t nameLen = data[cursor++];
                    if (nameLen > 0) memcpy(tmp.dashes[i].name, data + cursor, nameLen);
                    tmp.dashes[i].name[nameLen] = '\0';
                    cursor += nameLen;
                    tmp.dashes[i].colorIdx = data[cursor++];
                    tmp.dashes[i].phase    = data[cursor++];
                }
                tmp.dashCount = declared;

                // -- V4: exclusive index (1 byte after dash list) --
                if (cursor < len) {
                    uint8_t exIdx = data[cursor];
                    tmp.exclusiveIdx = (exIdx < declared) ? (int8_t)exIdx : -1;
                }
            }
        }
    }

    tmp.valid = true;
    out = tmp;
    return true;
}

// ── Permission Request (JSON) ────────────────────────────
// 极简 JSON 提取器(只支持 "key":"value" 形式,处理 \", \\, \/, \n)
static void extract_json_string(const char *json, size_t jlen,
                                const char *key,
                                char *out, size_t outCap) {
    if (outCap == 0) return;
    out[0] = '\0';

    char needle[40];
    int n = snprintf(needle, sizeof(needle), "\"%s\":\"", key);
    if (n <= 0 || (size_t)n >= sizeof(needle)) return;

    // 在 json 里找 needle(简单 strstr,jlen 受 BLE 包限制 < 600B)
    size_t needleLen = (size_t)n;
    if (jlen < needleLen) return;
    size_t start = (size_t)-1;
    for (size_t i = 0; i + needleLen <= jlen; i++) {
        if (memcmp(json + i, needle, needleLen) == 0) {
            start = i + needleLen;
            break;
        }
    }
    if (start == (size_t)-1) return;

    size_t wi = 0;
    for (size_t i = start; i < jlen && wi < outCap - 1; i++) {
        char c = json[i];
        if (c == '\\' && i + 1 < jlen) {
            char nx = json[i + 1];
            if (nx == '"' || nx == '\\' || nx == '/') {
                out[wi++] = nx;
            } else if (nx == 'n') {
                out[wi++] = ' ';   // 与 Stick S3 一致:换行 → 空格
            } else {
                out[wi++] = c;
                if (wi < outCap - 1) out[wi++] = nx;
            }
            i++;
        } else if (c == '"') {
            break;
        } else {
            out[wi++] = c;
        }
    }
    out[wi] = '\0';
}

bool parsePermissionRequest(const uint8_t *data, size_t len, PermissionToastState &out) {
    if (data == nullptr || len == 0) return false;

    PermissionToastState tmp = {};
    extract_json_string((const char*)data, len, "tool",  tmp.tool,  sizeof(tmp.tool));
    extract_json_string((const char*)data, len, "input", tmp.input, sizeof(tmp.input));

    // 至少要有 tool 字段才算有效
    if (tmp.tool[0] == '\0') return false;

    tmp.active = true;
    out = tmp;
    return true;
}

// ── VOICE_NOTIFY (control char payload) ──────────────────
//   SUCCESS: [0x06, buttonId]
//   FAILURE: [0x07, buttonId, errorMsg...]
bool parseVoiceNotify(uint8_t cmd, const uint8_t *data, size_t len, AsrFeedbackState &out) {
    if (data == nullptr || len < 1) return false;
    if (cmd != 0x06 && cmd != 0x07) return false;

    AsrFeedbackState tmp = {};
    tmp.isFailure = (cmd == 0x07);
    tmp.buttonId  = (len >= 2) ? data[1] : 0x01;

    if (tmp.isFailure) {
        if (len > 2) {
            size_t msgLen = len - 2;
            if (msgLen > sizeof(tmp.message) - 1) msgLen = sizeof(tmp.message) - 1;
            memcpy(tmp.message, data + 2, msgLen);
            tmp.message[msgLen] = '\0';
        } else {
            // 默认占位字串
            const char *fallback = "Failed";
            size_t fl = strlen(fallback);
            memcpy(tmp.message, fallback, fl);
            tmp.message[fl] = '\0';
        }
    } else {
        tmp.message[0] = '\0';
    }

    tmp.active = true;
    out = tmp;
    return true;
}
