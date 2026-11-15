#pragma once

#include <stddef.h>
#include <stdint.h>
#include <string.h>

#define V5_FRAME_TASK_LIFECYCLE 0x5A
#define TASK_LIFECYCLE_VERSION 1
#define TASK_LIFECYCLE_ID_LEN 16
#define TASK_LIFECYCLE_EVENT_FRAME_LEN (3 + TASK_LIFECYCLE_ID_LEN)

enum TaskLifecycleKind : uint8_t {
    TASK_LIFECYCLE_ENABLE = 0,
    TASK_LIFECYCLE_STARTED = 1,
    TASK_LIFECYCLE_COMPLETED = 2,
    TASK_LIFECYCLE_FAILED = 3,
};

struct TaskLifecycleFrame {
    TaskLifecycleKind kind;
    uint8_t eventId[TASK_LIFECYCLE_ID_LEN];
    bool hasEventId;
};

static inline bool taskLifecycleDecode(const uint8_t *data, size_t len,
                                       TaskLifecycleFrame *out) {
    if (!data || !out || len < 3 || data[0] != V5_FRAME_TASK_LIFECYCLE ||
        data[1] != TASK_LIFECYCLE_VERSION || data[2] > TASK_LIFECYCLE_FAILED) return false;
    out->kind = static_cast<TaskLifecycleKind>(data[2]);
    out->hasEventId = out->kind != TASK_LIFECYCLE_ENABLE;
    if (!out->hasEventId) return len == 3;
    if (len != TASK_LIFECYCLE_EVENT_FRAME_LEN) return false;
    memcpy(out->eventId, data + 3, TASK_LIFECYCLE_ID_LEN);
    return true;
}

/// Bounded connection-scoped dedupe. Event IDs are deterministic hashes from
/// the Host; no persisted state means reconnects never replay queued sounds.
class TaskLifecycleDeduper {
public:
    bool insertIfNew(const uint8_t eventId[TASK_LIFECYCLE_ID_LEN]) {
        for (uint8_t i = 0; i < count_; ++i) {
            if (memcmp(ids_[i], eventId, TASK_LIFECYCLE_ID_LEN) == 0) return false;
        }
        memcpy(ids_[next_], eventId, TASK_LIFECYCLE_ID_LEN);
        next_ = (uint8_t)((next_ + 1) % kCapacity);
        if (count_ < kCapacity) ++count_;
        return true;
    }

    void clear() { count_ = 0; next_ = 0; }

private:
    static constexpr uint8_t kCapacity = 24;
    uint8_t ids_[kCapacity][TASK_LIFECYCLE_ID_LEN] = {};
    uint8_t count_ = 0;
    uint8_t next_ = 0;
};
