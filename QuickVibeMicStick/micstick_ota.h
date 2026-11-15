#pragma once

#include <cstddef>
#include <cstdint>

#include "micstick_ota_protocol.h"

#ifdef ARDUINO
#include <NimBLEDevice.h>
#include "esp_ota_ops.h"
#include "esp_partition.h"
#else
class NimBLECharacteristic;
using esp_ota_handle_t = uint32_t;
struct esp_partition_t;
#endif

namespace micstick_ota {

enum class ChunkDisposition : uint8_t {
    invalid,
    write,
    duplicate,
    gap,
};

inline ChunkDisposition classify_chunk(uint32_t image_size,
                                       uint32_t accepted_offset,
                                       uint32_t offset,
                                       size_t length) {
    if (length == 0) return ChunkDisposition::invalid;
    const uint64_t end = static_cast<uint64_t>(offset) + length;
    if (end > image_size) return ChunkDisposition::invalid;
    if (offset == accepted_offset) return ChunkDisposition::write;
    if (offset < accepted_offset) {
        return end <= accepted_offset ? ChunkDisposition::duplicate
                                      : ChunkDisposition::invalid;
    }
    return ChunkDisposition::gap;
}

inline uint8_t calculate_progress_percent(uint32_t image_size,
                                          uint32_t accepted_offset) {
    if (image_size == 0) return 0;
    if (accepted_offset >= image_size) return 100;
    return static_cast<uint8_t>(
        (static_cast<uint64_t>(accepted_offset) * 100U) / image_size);
}

class MicStickOTASession {
public:
    void begin(NimBLECharacteristic* status_characteristic);
    void confirm_boot();
    void on_control(const uint8_t* data, size_t length);
    void on_data(const uint8_t* data, size_t length);
    void note_runtime_health();
    void note_audio_health();
    void loop();
    bool active() const;
    bool suppress_normal_ble() const;
    bool boot_confirmation_pending() const;
    uint8_t progress_percent() const;
    bool finalizing() const;

private:
    struct RxFrame {
        uint16_t length = 0;
        uint8_t is_data = 0;
        uint8_t bytes[512]{};
    };

    void process_control(const RxFrame& frame);
    void process_begin_fragment(const RxFrame& frame);
    void process_data(const RxFrame& frame);
    void send_info();
    void send_status(Error error = Error::none);
    void maybe_confirm_boot();
    void fail(Error error);
    void abort_transfer();
    bool start_or_resume(const BeginMetadata& metadata);
    bool metadata_matches(const BeginMetadata& metadata) const;
    bool verify_duplicate(const DataFrame& frame) const;
    Error verify_image();
    bool verify_signature(const uint8_t digest[32]) const;
    bool hash_image(uint8_t digest[32]) const;
    void clear_transfer();

    NimBLECharacteristic* status_characteristic_ = nullptr;
    void* control_queue_ = nullptr;
    void* data_queue_ = nullptr;
    esp_ota_handle_t ota_handle_ = 0;
    const esp_partition_t* target_partition_ = nullptr;
    BeginMetadata metadata_{};
    uint32_t accepted_offset_ = 0;
    State state_ = State::idle;
    bool has_metadata_ = false;
    bool reboot_requested_ = false;
    uint32_t reboot_at_ms_ = 0;
    bool boot_confirmation_tracking_ = false;
    volatile bool abort_requested_ = false;
    volatile bool data_queue_overflow_ = false;
    volatile bool active_flag_ = false;
    uint32_t boot_health_started_ms_ = 0;
    volatile uint32_t last_runtime_health_ms_ = 0;
    volatile uint32_t last_audio_health_ms_ = 0;
    std::vector<uint8_t> begin_assembly_;
    std::vector<uint8_t> begin_last_fragment_;
    uint16_t begin_fragment_count_ = 0;
    uint16_t begin_fragment_next_ = 0;
};

}  // namespace micstick_ota
