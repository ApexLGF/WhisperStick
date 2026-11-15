#include "micstick_ota_protocol.h"

#include <algorithm>

namespace micstick_ota {
namespace {

constexpr size_t kMaxVersionLength = 31;
constexpr size_t kMaxProductLength = 31;

void append_u16(std::vector<uint8_t>& out, uint16_t value) {
    out.push_back(static_cast<uint8_t>(value & 0xFF));
    out.push_back(static_cast<uint8_t>((value >> 8) & 0xFF));
}

void append_u32(std::vector<uint8_t>& out, uint32_t value) {
    out.push_back(static_cast<uint8_t>(value & 0xFF));
    out.push_back(static_cast<uint8_t>((value >> 8) & 0xFF));
    out.push_back(static_cast<uint8_t>((value >> 16) & 0xFF));
    out.push_back(static_cast<uint8_t>((value >> 24) & 0xFF));
}

bool read_u16(const uint8_t* data, size_t length, size_t& index, uint16_t& value) {
    if (index + 2 > length) return false;
    value = static_cast<uint16_t>(data[index]) |
            (static_cast<uint16_t>(data[index + 1]) << 8);
    index += 2;
    return true;
}

bool read_u32(const uint8_t* data, size_t length, size_t& index, uint32_t& value) {
    if (index + 4 > length) return false;
    value = static_cast<uint32_t>(data[index]) |
            (static_cast<uint32_t>(data[index + 1]) << 8) |
            (static_cast<uint32_t>(data[index + 2]) << 16) |
            (static_cast<uint32_t>(data[index + 3]) << 24);
    index += 4;
    return true;
}

bool read_string(const uint8_t* data, size_t length, size_t& index,
                 size_t max_length, std::string& value) {
    if (index >= length) return false;
    const size_t string_length = data[index++];
    if (string_length > max_length || index + string_length > length) return false;
    value.assign(reinterpret_cast<const char*>(data + index), string_length);
    index += string_length;
    return true;
}

bool append_string(std::vector<uint8_t>& out, const std::string& value,
                   size_t max_length) {
    if (value.size() > max_length) return false;
    out.push_back(static_cast<uint8_t>(value.size()));
    out.insert(out.end(), value.begin(), value.end());
    return true;
}

}  // namespace

std::vector<uint8_t> encode_begin(const BeginMetadata& value) {
    if (value.version.size() > kMaxVersionLength || value.signature.size() > UINT16_MAX) {
        return {};
    }

    std::vector<uint8_t> out;
    out.reserve(1 + 3 + 1 + value.version.size() + 4 + 32 + 2 +
                value.signature.size() + 4);
    out.push_back(kBegin);
    out.push_back(value.schema);
    out.push_back(value.hardware);
    out.push_back(value.protocol);
    if (!append_string(out, value.version, kMaxVersionLength)) return {};
    append_u32(out, value.image_size);
    out.insert(out.end(), value.sha256.begin(), value.sha256.end());
    append_u16(out, static_cast<uint16_t>(value.signature.size()));
    out.insert(out.end(), value.signature.begin(), value.signature.end());
    append_u32(out, value.resume_offset);
    return out;
}

bool decode_begin(const uint8_t* data, size_t length, BeginMetadata& value) {
    if (data == nullptr || length < 1 + 3 + 1 + 4 + 32 + 2 + 4 || data[0] != kBegin) {
        return false;
    }

    size_t index = 1;
    value = {};
    value.schema = data[index++];
    value.hardware = data[index++];
    value.protocol = data[index++];
    if (!read_string(data, length, index, kMaxVersionLength, value.version)) return false;
    if (!read_u32(data, length, index, value.image_size)) return false;
    if (index + value.sha256.size() > length) return false;
    std::copy_n(data + index, value.sha256.size(), value.sha256.begin());
    index += value.sha256.size();

    uint16_t signature_length = 0;
    if (!read_u16(data, length, index, signature_length) ||
        index + signature_length + 4 != length) {
        return false;
    }
    value.signature.assign(data + index, data + index + signature_length);
    index += signature_length;
    return read_u32(data, length, index, value.resume_offset) && index == length;
}

bool decode_begin_fragment(const uint8_t* data, size_t length, BeginFragment& value) {
    if (data == nullptr || length < 6 || data[0] != kBeginFragment) return false;
    size_t index = 1;
    value = {};
    if (!read_u16(data, length, index, value.index) ||
        !read_u16(data, length, index, value.count) ||
        value.count == 0 || value.index >= value.count || index >= length) {
        return false;
    }
    value.payload.assign(data + index, data + length);
    return !value.payload.empty();
}

bool decode_control(const uint8_t* data, size_t length) {
    if (data == nullptr || length == 0) return false;
    switch (data[0]) {
        case kInfoRequest:
        case kFinish:
        case kAbort:
            return length == 1;
        case kBegin: {
            BeginMetadata ignored{};
            return decode_begin(data, length, ignored);
        }
        case kBeginFragment: {
            BeginFragment ignored{};
            return decode_begin_fragment(data, length, ignored);
        }
        default:
            return false;
    }
}

bool decode_data(const uint8_t* data, size_t length, DataFrame& value) {
    if (data == nullptr || length < 5) return false;
    size_t index = 0;
    uint32_t offset = 0;
    if (!read_u32(data, length, index, offset)) return false;
    value.offset = offset;
    value.payload.assign(data + index, data + length);
    return !value.payload.empty();
}

std::vector<uint8_t> encode_info(const InfoMetadata& value) {
    std::vector<uint8_t> out;
    out.reserve(1 + 1 + 1 + value.product.size() + 3 + 1 + value.version.size());
    out.push_back(kInfoResponse);
    out.push_back(value.schema);
    if (!append_string(out, value.product, kMaxProductLength)) return {};
    out.push_back(value.hardware);
    out.push_back(value.protocol);
    out.push_back(static_cast<uint8_t>(value.state));
    if (!append_string(out, value.version, kMaxVersionLength)) return {};
    return out;
}

bool decode_info(const uint8_t* data, size_t length, InfoMetadata& value) {
    if (data == nullptr || length < 1 + 1 + 1 + 3 + 1 || data[0] != kInfoResponse) {
        return false;
    }
    size_t index = 1;
    value = {};
    value.schema = data[index++];
    if (!read_string(data, length, index, kMaxProductLength, value.product) ||
        index + 3 > length) return false;
    value.hardware = data[index++];
    value.protocol = data[index++];
    value.state = static_cast<State>(data[index++]);
    return read_string(data, length, index, kMaxVersionLength, value.version) &&
           index == length;
}

std::vector<uint8_t> encode_status(const StatusFrame& value) {
    return {kStatus,
            static_cast<uint8_t>(value.state),
            static_cast<uint8_t>(value.accepted_offset & 0xFF),
            static_cast<uint8_t>((value.accepted_offset >> 8) & 0xFF),
            static_cast<uint8_t>((value.accepted_offset >> 16) & 0xFF),
            static_cast<uint8_t>((value.accepted_offset >> 24) & 0xFF),
            static_cast<uint8_t>(value.error)};
}

bool decode_status(const uint8_t* data, size_t length, StatusFrame& value) {
    if (data == nullptr || length != 7 || data[0] != kStatus) return false;
    size_t index = 1;
    value = {};
    value.state = static_cast<State>(data[index++]);
    if (!read_u32(data, length, index, value.accepted_offset)) return false;
    value.error = static_cast<Error>(data[index]);
    return true;
}

}  // namespace micstick_ota
