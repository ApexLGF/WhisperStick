#include <assert.h>
#include <string.h>
#include "../task_lifecycle_protocol.h"

int main() {
    TaskLifecycleFrame frame{};
    const uint8_t enable[] = {0x5A, 0x01, 0x00};
    assert(taskLifecycleDecode(enable, sizeof(enable), &frame));
    assert(frame.kind == TASK_LIFECYCLE_ENABLE && !frame.hasEventId);

    uint8_t started[TASK_LIFECYCLE_EVENT_FRAME_LEN] = {0x5A, 0x01, 0x01};
    for (uint8_t i = 0; i < TASK_LIFECYCLE_ID_LEN; ++i) started[3 + i] = i;
    assert(taskLifecycleDecode(started, sizeof(started), &frame));
    assert(frame.kind == TASK_LIFECYCLE_STARTED && frame.hasEventId);

    TaskLifecycleDeduper deduper;
    assert(deduper.insertIfNew(frame.eventId));
    assert(!deduper.insertIfNew(frame.eventId));
    deduper.clear();
    assert(deduper.insertIfNew(frame.eventId));

    const uint8_t badVersion[] = {0x5A, 0x02, 0x00};
    assert(!taskLifecycleDecode(badVersion, sizeof(badVersion), &frame));
    assert(!taskLifecycleDecode(started, sizeof(started) - 1, &frame));
    return 0;
}
