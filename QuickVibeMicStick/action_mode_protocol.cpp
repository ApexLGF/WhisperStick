#include "action_mode_protocol.h"

#include <string.h>

static bool readText(const uint8_t *data, size_t len, size_t &cursor,
                     char *out, size_t cap) {
    if (cursor >= len) return false;
    uint8_t count = data[cursor++];
    if ((size_t)count >= cap || cursor + count > len) return false;
    if (count > 0) memcpy(out, data + cursor, count);
    out[count] = '\0';
    cursor += count;
    return true;
}

bool parseActionModeDefinition(const uint8_t *data, size_t len, ActionModeDefinition &out) {
    if (!data || len < 2 || data[0] != V5_FRAME_ACTION_MODE) return false;

    if (data[1] == 0) {
        if (len != 2) return false;
        out = ActionModeDefinition{};
        return true;
    }
    if (len < 7) return false;

    ActionModeDefinition tmp;
    tmp.modeId = data[1];
    size_t cursor = 2;
    if (!readText(data, len, cursor, tmp.title, sizeof(tmp.title))) return false;
    for (uint8_t i = 0; i < 3; i++) {
        if (!readText(data, len, cursor, tmp.lines[i], sizeof(tmp.lines[i]))) return false;
    }
    if (!readText(data, len, cursor, tmp.footer, sizeof(tmp.footer))) return false;
    if (cursor != len) return false;
    tmp.valid = true;
    out = tmp;
    return true;
}
