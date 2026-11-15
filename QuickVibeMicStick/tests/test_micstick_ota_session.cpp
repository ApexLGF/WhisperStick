#include "micstick_ota.h"

#include <cassert>
#include <fstream>
#include <iterator>
#include <string>

static std::string read_file(const char *path) {
    std::ifstream in(path);
    assert(in.good());
    return std::string((std::istreambuf_iterator<char>(in)),
                       std::istreambuf_iterator<char>());
}

static void clear_transfer_resets_control_and_data_queues() {
    const std::string source = read_file("QuickVibeMicStick/micstick_ota.cpp");
    const size_t start = source.find("void MicStickOTASession::clear_transfer()");
    const size_t end = source.find("\n}", start);
    assert(start != std::string::npos && end != std::string::npos);
    const std::string body = source.substr(start, end - start);
    assert(body.find("xQueueReset(queue_of(control_queue_))") != std::string::npos);
    assert(body.find("xQueueReset(queue_of(data_queue_))") != std::string::npos);
}

static void begin_fragments_are_supported() {
    const std::string source = read_file("QuickVibeMicStick/micstick_ota.cpp");
    assert(source.find("kBeginFragment") != std::string::npos);
    assert(source.find("begin_assembly_") != std::string::npos);
}

static void boot_confirmation_is_reported() {
    const std::string source = read_file("QuickVibeMicStick/micstick_ota.cpp");
    const size_t start = source.find("void MicStickOTASession::confirm_boot()");
    const size_t end = source.find("\n}", start);
    assert(start != std::string::npos && end != std::string::npos);
    const std::string body = source.substr(start, end - start);
    assert(body.find("state_ = State::confirmed") != std::string::npos);
    assert(body.find("send_info()") != std::string::npos);
}

static void ota_hardware_must_match_the_running_firmware() {
    const std::string source = read_file("QuickVibeMicStick/micstick_ota.cpp");
    assert(source.find("metadata.hardware != static_cast<uint8_t>(HARDWARE_REVISION)") != std::string::npos);
}

static void active_ota_renders_an_exclusive_progress_screen() {
    const std::string header = read_file("QuickVibeMicStick/micstick_ota.h");
    const std::string sketch = read_file("QuickVibeMicStick/QuickVibeMicStick.ino");
    const std::string renderer = read_file("QuickVibeMicStick/ui_renderer.cpp");
    assert(header.find("uint8_t progress_percent() const") != std::string::npos);
    assert(sketch.find("ui_render_firmware_update(otaProgress, otaFinalizing)") != std::string::npos);
    assert(renderer.find("UI_STR_OTA_CONTROLS_LOCKED") != std::string::npos);
}

int main() {
    using namespace micstick_ota;

    assert(calculate_progress_percent(0, 0) == 0);
    assert(calculate_progress_percent(1000, 0) == 0);
    assert(calculate_progress_percent(1000, 1) == 0);
    assert(calculate_progress_percent(1000, 500) == 50);
    assert(calculate_progress_percent(1000, 999) == 99);
    assert(calculate_progress_percent(1000, 1000) == 100);
    assert(calculate_progress_percent(1000, 1200) == 100);
    assert(calculate_progress_percent(UINT32_MAX, UINT32_MAX - 1) == 99);

    assert(classify_chunk(1000, 0, 0, 100) == ChunkDisposition::write);
    assert(classify_chunk(1000, 480, 480, 32) == ChunkDisposition::write);
    assert(classify_chunk(1000, 480, 0, 32) == ChunkDisposition::duplicate);
    assert(classify_chunk(1000, 480, 500, 32) == ChunkDisposition::gap);
    assert(classify_chunk(1000, 480, 980, 32) == ChunkDisposition::invalid);
    assert(classify_chunk(1000, 480, 480, 0) == ChunkDisposition::invalid);
    assert(classify_chunk(1000, 480, 990, 20) == ChunkDisposition::invalid);
    clear_transfer_resets_control_and_data_queues();
    begin_fragments_are_supported();
    boot_confirmation_is_reported();
    ota_hardware_must_match_the_running_firmware();
    active_ota_renders_an_exclusive_progress_screen();
    return 0;
}
