#include "micstick_ota_protocol.h"

#include <cassert>
#include <cstdint>
#include <vector>

int main() {
    using namespace micstick_ota;

    BeginMetadata begin{};
    begin.schema = 1;
    begin.hardware = 14;
    begin.protocol = 5;
    begin.image_size = 1232800;
    begin.resume_offset = 480;
    begin.version = "1.2.0";
    for (size_t i = 0; i < begin.sha256.size(); ++i) {
        begin.sha256[i] = static_cast<uint8_t>(i);
    }
    begin.signature = {0x30, 0x03, 0x02, 0x01, 0x01};

    const auto encoded = encode_begin(begin);
    BeginMetadata decoded{};
    assert(decode_begin(encoded.data(), encoded.size(), decoded));
    assert(decoded.schema == 1);
    assert(decoded.hardware == 14);
    assert(decoded.image_size == 1232800);
    assert(decoded.resume_offset == 480);
    assert(decoded.version == "1.2.0");
    assert(decoded.signature == begin.signature);

    const uint8_t fragment_bytes[] = {kBeginFragment, 0x00, 0x00, 0x02, 0x00,
                                      kBegin, 0x01, 0x0C};
    BeginFragment fragment{};
    assert(decode_begin_fragment(fragment_bytes, sizeof(fragment_bytes), fragment));
    assert(fragment.index == 0);
    assert(fragment.count == 2);
    assert(fragment.payload == std::vector<uint8_t>({kBegin, 0x01, 0x0C}));
    assert(!decode_begin_fragment(fragment_bytes, 5, fragment));

    assert(!decode_begin(encoded.data(), encoded.size() - 1, decoded));
    DataFrame empty{};
    assert(!decode_data(nullptr, 0, empty));

    const uint8_t data[] = {0xE0, 0x01, 0x00, 0x00, 0xAA, 0xBB};
    DataFrame frame{};
    assert(decode_data(data, sizeof(data), frame));
    assert(frame.offset == 480);
    assert(frame.payload == std::vector<uint8_t>({0xAA, 0xBB}));

    const uint8_t bad_opcode[] = {0x7F};
    assert(!decode_control(bad_opcode, sizeof(bad_opcode)));

    InfoMetadata info{};
    info.schema = 1;
    info.product = "micstick";
    info.hardware = 14;
    info.protocol = 5;
    info.state = State::receiving;
    info.version = "1.1.0";
    const auto info_bytes = encode_info(info);
    InfoMetadata decoded_info{};
    assert(decode_info(info_bytes.data(), info_bytes.size(), decoded_info));
    assert(decoded_info.product == "micstick");
    assert(decoded_info.state == State::receiving);
    assert(decoded_info.version == "1.1.0");

    StatusFrame status{};
    status.state = State::receiving;
    status.accepted_offset = 480;
    status.error = Error::none;
    const auto status_bytes = encode_status(status);
    StatusFrame decoded_status{};
    assert(decode_status(status_bytes.data(), status_bytes.size(), decoded_status));
    assert(decoded_status.accepted_offset == 480);
    assert(decoded_status.error == Error::none);
    return 0;
}
