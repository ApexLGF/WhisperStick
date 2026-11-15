// Build:
//   g++ -std=c++17 -I. tests/test_audio_agc.cpp -o /tmp/qv_audio_agc && /tmp/qv_audio_agc
#include <cassert>
#include <cmath>
#include <cstdint>
#include <cstdio>
#include <fstream>
#include <string>

#include "audio_agc.h"

static void loud_chunk_reduces_gain_and_avoids_clipping() {
    AudioAgc agc;
    int16_t input[512];
    int16_t output[512];
    for (int i = 0; i < 512; ++i) input[i] = (i & 1) ? 22000 : -22000;

    float before = agc.gain;
    uint32_t clipped = audioAgcProcessChunk(&agc, input, output, 512);

    assert(clipped == 0);
    assert(agc.gain < before);
    for (int i = 0; i < 512; ++i) {
        assert(output[i] < 32767);
        assert(output[i] > -32768);
    }
}

static void quiet_speech_recovers_after_loud_chunk() {
    AudioAgc agc;
    int16_t loud[512];
    int16_t quiet[512];
    int16_t output[512];
    for (int i = 0; i < 512; ++i) {
        loud[i] = (i & 1) ? 22000 : -22000;
        quiet[i] = (i & 1) ? 120 : -120;
    }

    audioAgcProcessChunk(&agc, loud, output, 512);
    float reduced = agc.gain;
    audioAgcProcessChunk(&agc, quiet, output, 512);

    assert(agc.gain > reduced);
}

static std::string read_file(const char *path) {
    std::ifstream in(path);
    assert(in.good());
    return std::string((std::istreambuf_iterator<char>(in)),
                       std::istreambuf_iterator<char>());
}

static void firmware_starts_each_ptt_with_fresh_agc() {
    std::string ino = read_file("QuickVibeMicStick.ino");
    size_t start = ino.find("static void startPTT()");
    size_t end = ino.find("static void stopPTT()", start);
    assert(start != std::string::npos);
    assert(end != std::string::npos);
    std::string body = ino.substr(start, end - start);

    assert(body.find("audioAgc = AudioAgc{};") != std::string::npos);
}

static void firmware_resets_agc_before_prebuffer_arm() {
    std::string ino = read_file("QuickVibeMicStick.ino");
    size_t start = ino.find("static void handleGlobalA(");
    size_t end = ino.find("static void handleNormalInput(", start);
    assert(start != std::string::npos && end != std::string::npos);
    std::string body = ino.substr(start, end - start);
    size_t reset = body.find("audioAgc = AudioAgc{};");
    size_t arm = body.find("preBufActive = true;");
    assert(reset != std::string::npos && arm != std::string::npos && reset < arm);
}

static void firmware_initializes_agc_at_configured_max_gain() {
    std::string ino = read_file("QuickVibeMicStick.ino");

    assert(ino.find("#define AUDIO_AGC_INITIAL_GAIN AUDIO_AGC_MAX_GAIN") != std::string::npos);
}

static void peak_ceiling_keeps_extra_headroom() {
    assert(AUDIO_AGC_PEAK_CEILING == 14000.0f);
}

int main() {
    loud_chunk_reduces_gain_and_avoids_clipping();
    quiet_speech_recovers_after_loud_chunk();
    firmware_starts_each_ptt_with_fresh_agc();
    firmware_resets_agc_before_prebuffer_arm();
    firmware_initializes_agc_at_configured_max_gain();
    peak_ceiling_keeps_extra_headroom();
    std::puts("ALL PASS");
    return 0;
}
