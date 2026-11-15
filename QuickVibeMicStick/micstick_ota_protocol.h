#pragma once

#include <array>
#include <cstddef>
#include <cstdint>
#include <string>
#include <vector>

namespace micstick_ota {

constexpr uint8_t kInfoRequest = 0x01;
constexpr uint8_t kBegin = 0x02;
constexpr uint8_t kFinish = 0x03;
constexpr uint8_t kAbort = 0x04;
constexpr uint8_t kBeginFragment = 0x05;
constexpr uint8_t kInfoResponse = 0x81;
constexpr uint8_t kStatus = 0x82;

enum class State : uint8_t {
    idle = 0,
    prepared = 1,
    receiving = 2,
    validating = 3,
    reboot_pending = 4,
    rebooted = 5,
    confirmed = 6,
};

enum class Error : uint8_t {
    none = 0,
    bad_frame = 1,
    incompatible = 2,
    bad_state = 3,
    bad_offset = 4,
    too_large = 5,
    sha256 = 6,
    signature = 7,
    flash = 8,
};

struct BeginMetadata {
    uint8_t schema = 0;
    uint8_t hardware = 0;
    uint8_t protocol = 0;
    std::string version;
    uint32_t image_size = 0;
    std::array<uint8_t, 32> sha256{};
    std::vector<uint8_t> signature;
    uint32_t resume_offset = 0;
};

struct DataFrame {
    uint32_t offset = 0;
    std::vector<uint8_t> payload;
};

struct BeginFragment {
    uint16_t index = 0;
    uint16_t count = 0;
    std::vector<uint8_t> payload;
};

struct InfoMetadata {
    uint8_t schema = 0;
    std::string product;
    uint8_t hardware = 0;
    uint8_t protocol = 0;
    State state = State::idle;
    std::string version;
};

struct StatusFrame {
    State state = State::idle;
    uint32_t accepted_offset = 0;
    Error error = Error::none;
};

std::vector<uint8_t> encode_begin(const BeginMetadata& value);
bool decode_begin(const uint8_t* data, size_t length, BeginMetadata& value);
bool decode_begin_fragment(const uint8_t* data, size_t length, BeginFragment& value);
bool decode_control(const uint8_t* data, size_t length);

bool decode_data(const uint8_t* data, size_t length, DataFrame& value);

std::vector<uint8_t> encode_info(const InfoMetadata& value);
bool decode_info(const uint8_t* data, size_t length, InfoMetadata& value);
std::vector<uint8_t> encode_status(const StatusFrame& value);
bool decode_status(const uint8_t* data, size_t length, StatusFrame& value);

}  // namespace micstick_ota
