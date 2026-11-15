#pragma once

#include <stdint.h>

enum TapGesture : uint8_t {
    TAP_GESTURE_NONE = 0,
    TAP_GESTURE_WAITING,
    TAP_GESTURE_SINGLE,
    TAP_GESTURE_DOUBLE,
};

// 单击/双击消歧的纯逻辑状态，可在固件和主机 g++ 测试中复用。
// 时间差使用无符号减法，兼容 millis() 回绕。
struct TapGestureState {
    bool pending = false;
    uint32_t lastTapMs = 0;

    TapGesture onTap(uint32_t now, uint32_t windowMs) {
        if (pending && (uint32_t)(now - lastTapMs) <= windowMs) {
            pending = false;
            return TAP_GESTURE_DOUBLE;
        }
        pending = true;
        lastTapMs = now;
        return TAP_GESTURE_WAITING;
    }

    TapGesture tick(uint32_t now, uint32_t windowMs) {
        if (pending && (uint32_t)(now - lastTapMs) > windowMs) {
            pending = false;
            return TAP_GESTURE_SINGLE;
        }
        return TAP_GESTURE_NONE;
    }

    void cancel() { pending = false; }
};

// Generic hold-repeat timer used independently by action-mode B and C.
// It contains no action meaning: every due tick is reported to the Host.
struct ActionRepeatState {
    bool active = false;
    uint32_t nextMs = 0;
    uint32_t intervalMs = 0;

    void start(uint32_t now, uint32_t initialIntervalMs) {
        active = true;
        nextMs = now;
        intervalMs = initialIntervalMs;
    }

    void stop() { active = false; }

    bool tick(uint32_t now, uint32_t minimumIntervalMs) {
        if (!active || (int32_t)(now - nextMs) < 0) return false;
        intervalMs = intervalMs * 85 / 100;
        if (intervalMs < minimumIntervalMs) intervalMs = minimumIntervalMs;
        nextMs = now + intervalMs;
        return true;
    }
};

// Prompt 列表与主页列表保持同一视觉方向：归一后的顺时针 step>0 向上移动。
// 返回值始终限制在 [0, count - 1]；空列表保持 0。
static inline int8_t promptSelectionAfterRotate(int8_t current, int8_t step,
                                                uint8_t count) {
    if (count == 0) return 0;
    int next = (int)current - (int)step;
    if (next < 0) next = 0;
    if (next >= count) next = count - 1;
    return (int8_t)next;
}
