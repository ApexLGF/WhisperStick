#pragma once

#include <stddef.h>
#include <stdint.h>

#define V5_FRAME_APPLICATION_SWITCHER 0x5B
#define APP_SWITCHER_CONTEXT_ID 0xFF
#define APP_SWITCHER_MAX_APPS 32
#define APP_SWITCHER_NAME_CAP 49
#define APP_SWITCHER_TITLE_CAP 25
#define APP_SWITCHER_FOOTER_CAP 49

enum ApplicationSwitcherFrameOperation : uint8_t {
    APP_SWITCHER_START = 0,
    APP_SWITCHER_ITEM = 1,
    APP_SWITCHER_COMMIT = 2,
    APP_SWITCHER_EXIT = 3,
};

struct ApplicationSwitcherDefinition {
    uint8_t requestId = 0;
    uint8_t count = 0;
    int8_t selected = 0;
    uint32_t receivedMask = 0;
    char title[APP_SWITCHER_TITLE_CAP] = {};
    char names[APP_SWITCHER_MAX_APPS][APP_SWITCHER_NAME_CAP] = {};
    char footer[APP_SWITCHER_FOOTER_CAP] = {};
    bool loading = false;
    bool valid = false;
};

// Keep clearing explicit: aggregate value-initialization may materialize this
// ~1.7 KB object on the caller's stack, which is unsafe in NimBLE callbacks.
void resetApplicationSwitcherDefinition(ApplicationSwitcherDefinition &out);

// START:  [0x5B][req][0][count][selected][titleLen][title][footerLen][footer]
// ITEM:   [0x5B][req][1][index][nameLen][name]
// COMMIT: [0x5B][req][2]
// EXIT:   [0x5B][req][3]
bool parseApplicationSwitcherFrame(const uint8_t *data, size_t len,
                                   ApplicationSwitcherDefinition &out);
