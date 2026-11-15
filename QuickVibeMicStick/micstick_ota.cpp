#include "micstick_ota.h"

#ifdef ARDUINO

#include <Arduino.h>
#include <cstring>
#include <vector>

#include "esp_partition.h"
#include "esp_system.h"
#include "freertos/FreeRTOS.h"
#include "freertos/queue.h"
#include "mbedtls/ecdsa.h"
#include "mbedtls/ecp.h"
#include "mbedtls/sha256.h"
#include "micstick_ota_public_key.h"

#ifndef FW_VERSION_STR
#define FW_VERSION_STR "1.1.1"
#endif

#ifndef HARDWARE_REVISION
#define HARDWARE_REVISION 12
#endif

namespace micstick_ota {
namespace {

constexpr size_t kControlQueueLength = 4;
constexpr size_t kDataQueueLength = 8;
constexpr size_t kHashChunkSize = 4096;
constexpr size_t kMaxSignatureLength = 256;
constexpr char kProduct[] = "micstick";
constexpr uint32_t kBootHealthWindowMs = 5000;
constexpr uint32_t kHealthHeartbeatTimeoutMs = 2000;

QueueHandle_t queue_of(void* queue) {
    return static_cast<QueueHandle_t>(queue);
}

}  // namespace

void MicStickOTASession::begin(NimBLECharacteristic* status_characteristic) {
    status_characteristic_ = status_characteristic;
    if (control_queue_ == nullptr) {
        control_queue_ = xQueueCreate(kControlQueueLength, sizeof(RxFrame));
    }
    if (data_queue_ == nullptr) {
        data_queue_ = xQueueCreate(kDataQueueLength, sizeof(RxFrame));
    }
    abort_requested_ = false;
    data_queue_overflow_ = false;
    boot_confirmation_tracking_ = boot_confirmation_pending();
    if (boot_confirmation_tracking_) {
        boot_health_started_ms_ = millis();
        last_runtime_health_ms_ = 0;
        last_audio_health_ms_ = 0;
        Serial.println("[ota] boot pending verification");
    }
    // Keep INFO as the readable characteristic value from boot. Hosts can
    // display the running firmware version without first opening an encrypted
    // OTA control transaction; update writes remain encryption-protected.
    send_info();
}

void MicStickOTASession::confirm_boot() {
    if (!boot_confirmation_pending()) return;
    const esp_err_t result = esp_ota_mark_app_valid_cancel_rollback();
    if (result == ESP_OK) {
        state_ = State::confirmed;
        send_info();
        Serial.println("[ota] boot confirmed");
    } else {
        Serial.printf("[ota] boot confirmation failed: %d\n", result);
    }
}

bool MicStickOTASession::boot_confirmation_pending() const {
    esp_ota_img_states_t image_state{};
    const esp_partition_t* running = esp_ota_get_running_partition();
    return running != nullptr &&
           esp_ota_get_state_partition(running, &image_state) == ESP_OK &&
           image_state == ESP_OTA_IMG_PENDING_VERIFY;
}

bool MicStickOTASession::active() const {
    return active_flag_;
}

bool MicStickOTASession::suppress_normal_ble() const {
    return active_flag_;
}

uint8_t MicStickOTASession::progress_percent() const {
    return active_flag_
        ? calculate_progress_percent(metadata_.image_size, accepted_offset_)
        : 0;
}

bool MicStickOTASession::finalizing() const {
    return active_flag_ && state_ != State::receiving;
}

void MicStickOTASession::note_runtime_health() {
    last_runtime_health_ms_ = millis();
}

void MicStickOTASession::note_audio_health() {
    last_audio_health_ms_ = millis();
}

void MicStickOTASession::on_control(const uint8_t* data, size_t length) {
    if (data == nullptr || length == 0 || length > sizeof(RxFrame::bytes)) {
        return;
    }
    if (length == 1 && data[0] == kAbort) {
        abort_requested_ = true;
        return;
    }
    if (control_queue_ == nullptr) return;
    RxFrame frame{};
    frame.length = static_cast<uint16_t>(length);
    frame.is_data = 0;
    memcpy(frame.bytes, data, length);
    if (xQueueSend(queue_of(control_queue_), &frame, pdMS_TO_TICKS(100)) != pdTRUE) {
        Serial.println("[ota] control queue full");
    }
}

void MicStickOTASession::on_data(const uint8_t* data, size_t length) {
    if (data == nullptr || length == 0 || length > sizeof(RxFrame::bytes) || data_queue_ == nullptr) {
        return;
    }
    RxFrame frame{};
    frame.length = static_cast<uint16_t>(length);
    frame.is_data = 1;
    memcpy(frame.bytes, data, length);
    if (xQueueSend(queue_of(data_queue_), &frame, 0) != pdTRUE) {
        data_queue_overflow_ = true;
    }
}

void MicStickOTASession::loop() {
    maybe_confirm_boot();
    if (abort_requested_) {
        abort_requested_ = false;
        abort_transfer();
        send_status();
    } else if (control_queue_ != nullptr) {
        RxFrame frame{};
        if (xQueueReceive(queue_of(control_queue_), &frame, 0) == pdTRUE) {
            process_control(frame);
        } else if (data_queue_ != nullptr &&
                   xQueueReceive(queue_of(data_queue_), &frame, 0) == pdTRUE) {
            process_data(frame);
        }
    }

    if (data_queue_overflow_) {
        data_queue_overflow_ = false;
        if (active_flag_ && state_ == State::receiving) {
            send_status(Error::bad_offset);
        }
    }

    if (reboot_requested_ && static_cast<int32_t>(millis() - reboot_at_ms_) >= 0) {
        esp_restart();
    }
}

void MicStickOTASession::maybe_confirm_boot() {
    if (!boot_confirmation_tracking_ || !boot_confirmation_pending()) return;

    const uint32_t now = millis();
    const bool health_window_complete = now - boot_health_started_ms_ >= kBootHealthWindowMs;
    const bool healthy = last_runtime_health_ms_ != 0 && last_audio_health_ms_ != 0 &&
                         now - last_runtime_health_ms_ <= kHealthHeartbeatTimeoutMs &&
                         now - last_audio_health_ms_ <= kHealthHeartbeatTimeoutMs;
    if (!health_window_complete) return;
    if (!healthy) {
        Serial.println("[ota] boot health check failed; rolling back");
        const esp_err_t result = esp_ota_mark_app_invalid_rollback_and_reboot();
        Serial.printf("[ota] rollback failed: %d; restarting\n", result);
        esp_restart();
        return;
    }
    confirm_boot();
}

void MicStickOTASession::process_control(const RxFrame& frame) {
    if (frame.length > 0 && frame.bytes[0] == kBeginFragment) {
        process_begin_fragment(frame);
        return;
    }
    if (!decode_control(frame.bytes, frame.length)) {
        fail(Error::bad_frame);
        return;
    }

    switch (frame.bytes[0]) {
        case kInfoRequest:
            send_info();
            return;
        case kBegin: {
            BeginMetadata metadata{};
            if (!decode_begin(frame.bytes, frame.length, metadata)) {
                fail(Error::bad_frame);
                return;
            }
            start_or_resume(metadata);
            return;
        }
        case kFinish: {
            if (!active_flag_ || state_ != State::receiving) {
                fail(Error::bad_state);
                return;
            }
            state_ = State::validating;
            send_status();
            if (accepted_offset_ != metadata_.image_size) {
                fail(Error::bad_offset);
                return;
            }
            if (esp_ota_end(ota_handle_) != ESP_OK) {
                ota_handle_ = 0;
                fail(Error::flash);
                return;
            }
            ota_handle_ = 0;
            const Error verification_error = verify_image();
            if (verification_error != Error::none) {
                fail(verification_error);
                return;
            }
            if (esp_ota_set_boot_partition(target_partition_) != ESP_OK) {
                fail(Error::flash);
                return;
            }
            state_ = State::reboot_pending;
            reboot_requested_ = true;
            reboot_at_ms_ = millis() + 250;
            send_status();
            return;
        }
        case kAbort:
            abort_transfer();
            send_status();
            return;
        default:
            fail(Error::bad_frame);
            return;
    }
}

void MicStickOTASession::process_begin_fragment(const RxFrame& frame) {
    BeginFragment fragment{};
    if (!decode_begin_fragment(frame.bytes, frame.length, fragment)) {
        fail(Error::bad_frame);
        return;
    }

    if (fragment.count == begin_fragment_count_ &&
        fragment.index + 1 == begin_fragment_next_ &&
        fragment.payload == begin_last_fragment_) {
        if (begin_fragment_next_ == begin_fragment_count_ && !begin_assembly_.empty()) {
            RxFrame assembled{};
            assembled.length = static_cast<uint16_t>(begin_assembly_.size());
            memcpy(assembled.bytes, begin_assembly_.data(), assembled.length);
            process_control(assembled);
        }
        return;
    }

    if (fragment.index == 0) {
        begin_assembly_.clear();
        begin_last_fragment_.clear();
        begin_fragment_count_ = fragment.count;
        begin_fragment_next_ = 0;
    }

    if (fragment.count != begin_fragment_count_ ||
        fragment.index != begin_fragment_next_ ||
        begin_assembly_.size() + fragment.payload.size() > sizeof(RxFrame::bytes)) {
        fail(Error::bad_frame);
        return;
    }

    begin_assembly_.insert(begin_assembly_.end(),
                           fragment.payload.begin(), fragment.payload.end());
    begin_last_fragment_ = fragment.payload;
    ++begin_fragment_next_;
    if (begin_fragment_next_ != begin_fragment_count_) return;

    RxFrame assembled{};
    assembled.length = static_cast<uint16_t>(begin_assembly_.size());
    memcpy(assembled.bytes, begin_assembly_.data(), assembled.length);
    process_control(assembled);
}

void MicStickOTASession::process_data(const RxFrame& frame) {
    if (!active_flag_ || state_ != State::receiving) {
        fail(Error::bad_state);
        return;
    }

    DataFrame data{};
    if (!decode_data(frame.bytes, frame.length, data)) {
        fail(Error::bad_frame);
        return;
    }

    switch (classify_chunk(metadata_.image_size, accepted_offset_, data.offset,
                           data.payload.size())) {
        case ChunkDisposition::invalid:
            fail(Error::bad_offset);
            return;
        case ChunkDisposition::gap:
            send_status(Error::bad_offset);
            return;
        case ChunkDisposition::duplicate:
            if (!verify_duplicate(data)) {
                fail(Error::bad_offset);
                return;
            }
            send_status();
            return;
        case ChunkDisposition::write:
            break;
    }

    if (esp_ota_write_with_offset(ota_handle_, data.payload.data(),
                                  data.payload.size(), data.offset) != ESP_OK) {
        fail(Error::flash);
        return;
    }
    accepted_offset_ = data.offset + static_cast<uint32_t>(data.payload.size());
    send_status();
}

bool MicStickOTASession::start_or_resume(const BeginMetadata& metadata) {
    const esp_partition_t* next = esp_ota_get_next_update_partition(nullptr);
    if (next == nullptr || metadata.schema != 1 ||
        metadata.hardware != static_cast<uint8_t>(HARDWARE_REVISION) ||
        metadata.protocol != 5 || metadata.version.empty() || metadata.image_size == 0 ||
        metadata.image_size > next->size || metadata.signature.empty() ||
        metadata.signature.size() > kMaxSignatureLength ||
        metadata.resume_offset > metadata.image_size) {
        fail(metadata.image_size > (next == nullptr ? 0 : next->size)
                 ? Error::too_large
                 : Error::incompatible);
        return false;
    }

    if (has_metadata_) {
        if (!metadata_matches(metadata)) {
            abort_transfer();
            if (metadata.resume_offset != 0) {
                fail(Error::bad_offset);
                return false;
            }
        } else if (metadata.resume_offset != accepted_offset_) {
            send_status(Error::bad_offset);
            return false;
        } else {
            state_ = State::receiving;
            active_flag_ = true;
            send_status();
            return true;
        }
    } else if (metadata.resume_offset != 0) {
        fail(Error::bad_offset);
        return false;
    }

    target_partition_ = next;
    metadata_ = metadata;
    accepted_offset_ = 0;
    if (esp_ota_begin(target_partition_, metadata_.image_size, &ota_handle_) != ESP_OK) {
        clear_transfer();
        send_status(Error::flash);
        return false;
    }
    has_metadata_ = true;
    state_ = State::receiving;
    active_flag_ = true;
    send_status();
    return true;
}

bool MicStickOTASession::metadata_matches(const BeginMetadata& metadata) const {
    return has_metadata_ && metadata.schema == metadata_.schema &&
           metadata.hardware == metadata_.hardware &&
           metadata.protocol == metadata_.protocol &&
           metadata.version == metadata_.version &&
           metadata.image_size == metadata_.image_size &&
           metadata.sha256 == metadata_.sha256 &&
           metadata.signature == metadata_.signature;
}

bool MicStickOTASession::verify_duplicate(const DataFrame& frame) const {
    std::vector<uint8_t> existing(frame.payload.size());
    return target_partition_ != nullptr &&
           esp_partition_read(target_partition_, frame.offset, existing.data(),
                              existing.size()) == ESP_OK &&
           existing == frame.payload;
}

bool MicStickOTASession::hash_image(uint8_t digest[32]) const {
    if (target_partition_ == nullptr) return false;
    mbedtls_sha256_context context;
    mbedtls_sha256_init(&context);
    bool ok = mbedtls_sha256_starts_ret(&context, 0) == 0;
    uint8_t buffer[kHashChunkSize];
    for (uint32_t offset = 0; ok && offset < metadata_.image_size;) {
        const size_t count = min<size_t>(sizeof(buffer), metadata_.image_size - offset);
        ok = esp_partition_read(target_partition_, offset, buffer, count) == ESP_OK;
        if (ok) ok = mbedtls_sha256_update_ret(&context, buffer, count) == 0;
        offset += static_cast<uint32_t>(count);
    }
    if (ok) ok = mbedtls_sha256_finish_ret(&context, digest) == 0;
    mbedtls_sha256_free(&context);
    return ok;
}

bool MicStickOTASession::verify_signature(const uint8_t digest[32]) const {
    if (metadata_.signature.empty()) return false;
    mbedtls_ecdsa_context context;
    mbedtls_ecdsa_init(&context);
    bool ok = mbedtls_ecp_group_load(&context.grp, MBEDTLS_ECP_DP_SECP256R1) == 0;
    if (ok) {
        ok = mbedtls_ecp_point_read_binary(
                 &context.grp, &context.Q, kPublicKey, sizeof(kPublicKey)) == 0;
    }
    if (ok) {
        ok = mbedtls_ecdsa_read_signature(
                 &context, digest, 32, metadata_.signature.data(),
                 metadata_.signature.size()) == 0;
    }
    mbedtls_ecdsa_free(&context);
    return ok;
}

Error MicStickOTASession::verify_image() {
    uint8_t digest[32]{};
    if (!hash_image(digest) ||
        memcmp(digest, metadata_.sha256.data(), sizeof(digest)) != 0) {
        return Error::sha256;
    }
    return verify_signature(digest) ? Error::none : Error::signature;
}

void MicStickOTASession::send_info() {
    if (status_characteristic_ == nullptr) return;
    InfoMetadata info{};
    info.schema = 1;
    info.product = kProduct;
    info.hardware = HARDWARE_REVISION;
    info.protocol = 5;
    info.state = state_;
    info.version = FW_VERSION_STR;
    const auto payload = encode_info(info);
    status_characteristic_->setValue(payload.data(), payload.size());
    status_characteristic_->notify();
}

void MicStickOTASession::send_status(Error error) {
    if (status_characteristic_ == nullptr) return;
    StatusFrame status{};
    status.state = state_;
    status.accepted_offset = accepted_offset_;
    status.error = error;
    const auto payload = encode_status(status);
    status_characteristic_->setValue(payload.data(), payload.size());
    status_characteristic_->notify();
}

void MicStickOTASession::fail(Error error) {
    if (ota_handle_ != 0) {
        esp_ota_abort(ota_handle_);
    }
    clear_transfer();
    send_status(error);
}

void MicStickOTASession::abort_transfer() {
    if (ota_handle_ != 0) {
        esp_ota_abort(ota_handle_);
    }
    clear_transfer();
}

void MicStickOTASession::clear_transfer() {
    if (control_queue_ != nullptr) {
        xQueueReset(queue_of(control_queue_));
    }
    if (data_queue_ != nullptr) {
        xQueueReset(queue_of(data_queue_));
    }
    ota_handle_ = 0;
    target_partition_ = nullptr;
    metadata_ = {};
    accepted_offset_ = 0;
    state_ = State::idle;
    has_metadata_ = false;
    data_queue_overflow_ = false;
    active_flag_ = false;
    reboot_requested_ = false;
    begin_assembly_.clear();
    begin_last_fragment_.clear();
    begin_fragment_count_ = 0;
    begin_fragment_next_ = 0;
}

}  // namespace micstick_ota

#endif  // ARDUINO
