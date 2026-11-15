#include "application_switcher_protocol.h"

#include <string.h>

void resetApplicationSwitcherDefinition(ApplicationSwitcherDefinition &out) {
    memset(&out, 0, sizeof(out));
}

static bool readText(const uint8_t *data, size_t len, size_t &cursor,
                     char *out, size_t cap) {
    if (cursor >= len) return false;
    const uint8_t count = data[cursor++];
    if ((size_t)count >= cap || cursor + count > len) return false;
    if (count > 0) memcpy(out, data + cursor, count);
    out[count] = '\0';
    cursor += count;
    return true;
}

bool parseApplicationSwitcherFrame(const uint8_t *data, size_t len,
                                   ApplicationSwitcherDefinition &out) {
    if (!data || len < 3 || data[0] != V5_FRAME_APPLICATION_SWITCHER) return false;
    const uint8_t requestId = data[1];
    const uint8_t operation = data[2];

    if (operation == APP_SWITCHER_START) {
        if (len < 7 || data[3] > APP_SWITCHER_MAX_APPS) return false;
        const uint8_t count = data[3];
        const uint8_t selected = data[4];
        if (count > 0 && selected >= count) return false;
        // Validate into small fixed fields first, then reset the large target
        // in place. A full temporary here overflows the NimBLE host task stack
        // on ESP32-S3 when START arrives from the Mac.
        char title[APP_SWITCHER_TITLE_CAP] = {};
        char footer[APP_SWITCHER_FOOTER_CAP] = {};
        size_t cursor = 5;
        if (!readText(data, len, cursor, title, sizeof(title)) ||
            !readText(data, len, cursor, footer, sizeof(footer)) ||
            cursor != len) return false;
        resetApplicationSwitcherDefinition(out);
        out.requestId = requestId;
        out.count = count;
        out.selected = (int8_t)selected;
        memcpy(out.title, title, sizeof(title));
        memcpy(out.footer, footer, sizeof(footer));
        out.loading = true;
        return true;
    }

    if (operation == APP_SWITCHER_EXIT) {
        if (len != 3 || requestId != out.requestId) return false;
        resetApplicationSwitcherDefinition(out);
        return true;
    }
    if (requestId != out.requestId || !out.loading) return false;
    if (operation == APP_SWITCHER_ITEM) {
        if (len < 5) return false;
        const uint8_t index = data[3];
        if (index >= out.count) return false;
        size_t cursor = 4;
        char name[APP_SWITCHER_NAME_CAP] = {};
        if (!readText(data, len, cursor, name, sizeof(name)) || cursor != len) return false;
        strncpy(out.names[index], name, sizeof(out.names[index]) - 1);
        out.receivedMask |= (uint32_t)1u << index;
        return true;
    }
    if (operation == APP_SWITCHER_COMMIT) {
        if (len != 3) return false;
        const uint32_t expected = out.count == 32
            ? UINT32_MAX : (out.count == 0 ? 0 : (((uint32_t)1u << out.count) - 1u));
        if (out.receivedMask != expected) return false;
        out.loading = false;
        out.valid = true;
        return true;
    }
    return false;
}
