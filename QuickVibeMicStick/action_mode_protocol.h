#pragma once

#include <stddef.h>
#include <stdint.h>

#define V5_FRAME_ACTION_MODE 0x57
#define ACTION_MODE_TITLE_CAP 25
#define ACTION_MODE_LINE_CAP 49
#define ACTION_MODE_FOOTER_CAP 49

enum DeviceActionModeId : uint8_t {
    ACTION_MODE_NONE = 0,
    ACTION_MODE_CUSTOM_ONE = 1,
    ACTION_MODE_CHATGPT_APP = 2,
    ACTION_MODE_MUSIC = 3,
};

enum DeviceActionControl : uint8_t {
    ACTION_CONTROL_B = 1,
    ACTION_CONTROL_C = 2,
    ACTION_CONTROL_D = 3,
};

enum DeviceActionGesture : uint8_t {
    ACTION_GESTURE_TAP = 1,
    ACTION_GESTURE_DOUBLE_TAP = 2,
    ACTION_GESTURE_HOLD_START = 3,
    ACTION_GESTURE_HOLD_END = 4,
    ACTION_GESTURE_ROTATE = 5,
    ACTION_GESTURE_REPEAT = 6,
};

struct ActionModeDefinition {
    uint8_t modeId = 0;
    char title[ACTION_MODE_TITLE_CAP] = {};
    char lines[3][ACTION_MODE_LINE_CAP] = {};
    char footer[ACTION_MODE_FOOTER_CAP] = {};
    bool valid = false;
};

// [0x57][0] 表示退出动作模式；否则：
// [0x57][modeId][titleLen][title]
//       x3 {[lineLen][line]} [footerLen][footer]
bool parseActionModeDefinition(const uint8_t *data, size_t len, ActionModeDefinition &out);
