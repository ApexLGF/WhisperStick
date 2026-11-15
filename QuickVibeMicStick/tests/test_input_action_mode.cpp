#include <assert.h>
#include <stdint.h>
#include <stdio.h>
#include <string.h>
#include <vector>

#include "../action_mode_protocol.h"
#include "../input_gesture.h"

static void appendText(std::vector<uint8_t> &frame, const char *s) {
    size_t n = strlen(s);
    assert(n < 256);
    frame.push_back((uint8_t)n);
    frame.insert(frame.end(), s, s + n);
}

static void testTapGesture() {
    TapGestureState s;
    assert(s.onTap(100, 280) == TAP_GESTURE_WAITING);
    assert(s.tick(380, 280) == TAP_GESTURE_NONE);
    assert(s.tick(381, 280) == TAP_GESTURE_SINGLE);
    assert(!s.pending);

    assert(s.onTap(500, 280) == TAP_GESTURE_WAITING);
    assert(s.onTap(780, 280) == TAP_GESTURE_DOUBLE);
    assert(s.tick(1000, 280) == TAP_GESTURE_NONE);

    assert(s.onTap(UINT32_MAX - 20, 40) == TAP_GESTURE_WAITING);
    assert(s.onTap(10, 40) == TAP_GESTURE_DOUBLE); // millis() wrap

    assert(s.onTap(2000, 280) == TAP_GESTURE_WAITING);
    s.cancel();
    assert(s.tick(3000, 280) == TAP_GESTURE_NONE);
}

static void testIndependentActionRepeats() {
    ActionRepeatState b;
    ActionRepeatState c;
    b.start(100, 300);
    assert(b.tick(100, 50));
    assert(!b.tick(200, 50));
    assert(!c.tick(200, 50));
    c.start(250, 300);
    assert(c.tick(250, 50));
    b.stop();
    assert(!b.tick(1000, 50));
    assert(c.tick(1000, 50));

    ActionRepeatState wrapped;
    wrapped.start(UINT32_MAX - 10, 50);
    assert(wrapped.tick(UINT32_MAX - 10, 50));
    assert(!wrapped.tick(20, 50));
    assert(wrapped.tick(40, 50));
}

static void testPromptRotationMatchesHomeList() {
    // 主页使用 -step：顺时针(+1)向上，逆时针(-1)向下。
    assert(promptSelectionAfterRotate(2, 1, 5) == 1);
    assert(promptSelectionAfterRotate(2, -1, 5) == 3);
    assert(promptSelectionAfterRotate(0, 1, 5) == 0);
    assert(promptSelectionAfterRotate(4, -1, 5) == 4);
    assert(promptSelectionAfterRotate(3, 1, 0) == 0);
}

static std::vector<uint8_t> validFrame() {
    std::vector<uint8_t> f = {V5_FRAME_ACTION_MODE, 1};
    appendText(f, "Custom 1");
    appendText(f, "B Tap Up / Double PgUp");
    appendText(f, "C Tap Down / Double PgDown");
    appendText(f, "D Rotate Left Right");
    appendText(f, "Hold D to exit");
    return f;
}

static void testActionModeFrame() {
    static_assert(ACTION_MODE_CUSTOM_ONE == 1, "wire ID must remain stable");
    static_assert(ACTION_MODE_CHATGPT_APP == 2, "wire ID must remain stable");
    static_assert(ACTION_MODE_MUSIC == 3, "Music Mode wire ID contract");
    auto frame = validFrame();
    ActionModeDefinition d;
    assert(parseActionModeDefinition(frame.data(), frame.size(), d));
    assert(d.valid && d.modeId == 1);
    assert(strcmp(d.title, "Custom 1") == 0);
    assert(strcmp(d.footer, "Hold D to exit") == 0);

    ActionModeDefinition unchanged;
    unchanged.modeId = 99;
    auto shortFrame = frame;
    shortFrame.pop_back();
    assert(!parseActionModeDefinition(shortFrame.data(), shortFrame.size(), unchanged));
    assert(unchanged.modeId == 99); // 失败不得写半截

    auto trailing = frame;
    trailing.push_back(0);
    assert(!parseActionModeDefinition(trailing.data(), trailing.size(), unchanged));

    const uint8_t exitFrame[] = {V5_FRAME_ACTION_MODE, 0};
    assert(parseActionModeDefinition(exitFrame, sizeof(exitFrame), unchanged));
    assert(!unchanged.valid && unchanged.modeId == 0);

    auto musicFrame = validFrame();
    musicFrame[1] = ACTION_MODE_MUSIC;
    assert(parseActionModeDefinition(musicFrame.data(), musicFrame.size(), unchanged));
    assert(unchanged.valid && unchanged.modeId == ACTION_MODE_MUSIC);

    auto dynamicFrame = validFrame();
    dynamicFrame[1] = 0x10;
    assert(parseActionModeDefinition(dynamicFrame.data(), dynamicFrame.size(), unchanged));
    assert(unchanged.valid && unchanged.modeId == 0x10);

    auto invalidExit = frame;
    invalidExit[1] = 0;
    assert(!parseActionModeDefinition(invalidExit.data(), invalidExit.size(), unchanged));
}

int main() {
    testTapGesture();
    testIndependentActionRepeats();
    testPromptRotationMatchesHomeList();
    testActionModeFrame();
    puts("test_input_action_mode: OK");
    return 0;
}
