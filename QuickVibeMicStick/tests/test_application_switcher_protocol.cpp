#include <assert.h>
#include <stdint.h>
#include <stdio.h>
#include <string.h>
#include <vector>

#include "../application_switcher_protocol.h"

static void appendText(std::vector<uint8_t> &frame, const char *text) {
    const size_t length = strlen(text);
    frame.push_back((uint8_t)length);
    frame.insert(frame.end(), text, text + length);
}

int main() {
    ApplicationSwitcherDefinition state;
    std::vector<uint8_t> start = {V5_FRAME_APPLICATION_SWITCHER, 9, APP_SWITCHER_START, 2, 1};
    appendText(start, "Switch Apps");
    appendText(start, "D Rotate/Press C Cancel");
    assert(parseApplicationSwitcherFrame(start.data(), start.size(), state));
    assert(state.loading && !state.valid && state.count == 2 && state.selected == 1);

    std::vector<uint8_t> first = {V5_FRAME_APPLICATION_SWITCHER, 9, APP_SWITCHER_ITEM, 0};
    appendText(first, "Safari");
    std::vector<uint8_t> second = {V5_FRAME_APPLICATION_SWITCHER, 9, APP_SWITCHER_ITEM, 1};
    appendText(second, "ChatGPT");
    assert(parseApplicationSwitcherFrame(first.data(), first.size(), state));
    const uint8_t premature[] = {V5_FRAME_APPLICATION_SWITCHER, 9, APP_SWITCHER_COMMIT};
    assert(!parseApplicationSwitcherFrame(premature, sizeof(premature), state));
    assert(state.loading && !state.valid);
    assert(parseApplicationSwitcherFrame(second.data(), second.size(), state));
    assert(parseApplicationSwitcherFrame(premature, sizeof(premature), state));
    assert(!state.loading && state.valid);
    assert(strcmp(state.names[0], "Safari") == 0 && strcmp(state.names[1], "ChatGPT") == 0);

    // A malformed replacement START must not destroy the committed snapshot.
    const uint8_t malformedReplacement[] = {
        V5_FRAME_APPLICATION_SWITCHER, 10, APP_SWITCHER_START, 1, 0, 8, 'B', 'a', 'd'
    };
    assert(!parseApplicationSwitcherFrame(malformedReplacement,
                                          sizeof(malformedReplacement), state));
    assert(state.valid && state.requestId == 9 && strcmp(state.names[1], "ChatGPT") == 0);

    const uint8_t staleExit[] = {V5_FRAME_APPLICATION_SWITCHER, 8, APP_SWITCHER_EXIT};
    assert(!parseApplicationSwitcherFrame(staleExit, sizeof(staleExit), state));
    const uint8_t exit[] = {V5_FRAME_APPLICATION_SWITCHER, 9, APP_SWITCHER_EXIT};
    assert(parseApplicationSwitcherFrame(exit, sizeof(exit), state));
    assert(!state.valid && !state.loading && state.count == 0);

    std::vector<uint8_t> invalidStart = {V5_FRAME_APPLICATION_SWITCHER, 10,
                                         APP_SWITCHER_START, 1, 1};
    appendText(invalidStart, "Apps");
    appendText(invalidStart, "Footer");
    assert(!parseApplicationSwitcherFrame(invalidStart.data(), invalidStart.size(), state));

    puts("test_application_switcher_protocol: OK");
    return 0;
}
