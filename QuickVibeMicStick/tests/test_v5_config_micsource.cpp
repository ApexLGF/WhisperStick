// 0x53 CONFIG 帧尾部 micSource/language 字节的解析与向后兼容测试。
// 纯 assert,不依赖 gtest(见 README.md:19「gtest 未安装」)。
//
//   g++ -std=c++17 -I.. test_v5_config_micsource.cpp ../v5_protocol.cpp -o /tmp/t033 && /tmp/t033
#include <assert.h>
#include <stdint.h>
#include <stddef.h>
#include <stdio.h>
#include <string.h>

#include "../v5_protocol.h"

// 基线(T-033 之前)的 v5ParseConfig 逐字拷贝 —— 用于用例 5「老固件吃新帧」。
// 与 v5_protocol.cpp 当前实现的唯一差别:没有尾字节 micSource 的处理。
struct LegacyV5Config {
    uint8_t voiceMode;
    uint8_t promptCount;
    char    promptTitles[V5_MAX_PROMPTS][V5_PROMPT_TITLE_CAP];
    bool    valid;
};

static bool legacyParseConfig(const uint8_t *data, size_t len, LegacyV5Config &cfg) {
    if (!data || len < 3 || data[0] != V5_FRAME_CONFIG) return false;
    uint8_t mode  = data[1];
    uint8_t count = data[2];
    if (mode > V5_VOICE_MODE_TOGGLE) return false;
    if (count > V5_MAX_PROMPTS) return false;

    size_t cur = 3;
    for (uint8_t i = 0; i < count; i++) {
        if (cur >= len) return false;
        uint8_t l = data[cur];
        if (l >= V5_PROMPT_TITLE_CAP) return false;
        cur += 1 + l;
        if (cur > len) return false;
    }

    LegacyV5Config tmp = {};
    tmp.voiceMode   = mode;
    tmp.promptCount = count;
    cur = 3;
    for (uint8_t i = 0; i < count; i++) {
        uint8_t l = data[cur];
        if (l > 0) memcpy(tmp.promptTitles[i], data + cur + 1, l);
        tmp.promptTitles[i][l] = '\0';
        cur += 1 + l;
    }
    tmp.valid = true;
    cfg = tmp;
    return true;
}

int main() {
    // 1) 老 Mac 帧(无尾字节)→ micSource 落 DEVICE
    {
        const uint8_t frame[] = { V5_FRAME_CONFIG, 0, 0 };
        V5Config cfg = {};
        assert(v5ParseConfig(frame, sizeof(frame), cfg));
        assert(cfg.valid);
        assert(cfg.micSource == V5_MIC_SOURCE_DEVICE);
        assert(!cfg.hasLanguage);
        assert(cfg.laboratoryFeatures == 0);
    }

    // 2) 新帧 micSource=1 → SYSTEM
    {
        const uint8_t frame[] = { V5_FRAME_CONFIG, 0, 0, 1 };
        V5Config cfg = {};
        assert(v5ParseConfig(frame, sizeof(frame), cfg));
        assert(cfg.micSource == V5_MIC_SOURCE_SYSTEM);
        assert(!cfg.hasLanguage);
        assert(cfg.laboratoryFeatures == 0);
    }

    // 3) 带 2 个 prompt 的新帧 → title 正确 **且** micSource==1
    //    (证明尾部追加不破坏 title 解析)
    {
        const uint8_t frame[] = {
            V5_FRAME_CONFIG, 1, 2,
            2, 'h', 'i',
            3, 'a', 'b', 'c',
            1
        };
        V5Config cfg = {};
        assert(v5ParseConfig(frame, sizeof(frame), cfg));
        assert(cfg.voiceMode == V5_VOICE_MODE_TOGGLE);
        assert(cfg.promptCount == 2);
        assert(strcmp(cfg.promptTitles[0], "hi") == 0);
        assert(strcmp(cfg.promptTitles[1], "abc") == 0);
        assert(cfg.micSource == V5_MIC_SOURCE_SYSTEM);
        assert(!cfg.hasLanguage);
        assert(cfg.laboratoryFeatures == 0);
    }

    // 4) 越界值 → 钳到 DEVICE
    {
        const uint8_t frame[] = { V5_FRAME_CONFIG, 0, 0, 7 };
        V5Config cfg = {};
        assert(v5ParseConfig(frame, sizeof(frame), cfg));
        assert(cfg.micSource == V5_MIC_SOURCE_DEVICE);
        assert(!cfg.hasLanguage);
        assert(cfg.laboratoryFeatures == 0);
    }

    // 5) 语言尾字节紧跟 micSource,三种合法值均被接受。
    for (uint8_t language = V5_UI_LANGUAGE_EN; language <= V5_UI_LANGUAGE_ZH_HANT; language++) {
        const uint8_t frame[] = { V5_FRAME_CONFIG, 0, 0, V5_MIC_SOURCE_SYSTEM, language };
        V5Config cfg = {};
        assert(v5ParseConfig(frame, sizeof(frame), cfg));
        assert(cfg.micSource == V5_MIC_SOURCE_SYSTEM);
        assert(cfg.hasLanguage);
        assert(cfg.language == language);
    }

    // 6) 实验室尾字节按位解析,未知位被屏蔽；老 Host 缺省为全部关闭。
    {
        const uint8_t frame[] = {
            V5_FRAME_CONFIG, 0, 0, V5_MIC_SOURCE_DEVICE, V5_UI_LANGUAGE_ZH_HANS,
            (uint8_t)(V5_LAB_PROMPT_RECOMMENDATIONS | V5_LAB_INPUT_ASSISTANT | 0x80)
        };
        V5Config cfg = {};
        assert(v5ParseConfig(frame, sizeof(frame), cfg));
        assert(cfg.laboratoryFeatures == V5_LAB_KNOWN_MASK);
    }

    // 7) 越界语言不生效,设备应保留已持久化语言。
    {
        const uint8_t frame[] = { V5_FRAME_CONFIG, 0, 0, V5_MIC_SOURCE_DEVICE, 9 };
        V5Config cfg = {};
        assert(v5ParseConfig(frame, sizeof(frame), cfg));
        assert(!cfg.hasLanguage);
    }

    // 8) Prompt + 三个尾字节不能互相错位。
    {
        const uint8_t frame[] = {
            V5_FRAME_CONFIG, 0, 1, 3, 'a', 'b', 'c',
            V5_MIC_SOURCE_DEVICE, V5_UI_LANGUAGE_ZH_HANT, V5_LAB_INPUT_ASSISTANT
        };
        V5Config cfg = {};
        assert(v5ParseConfig(frame, sizeof(frame), cfg));
        assert(strcmp(cfg.promptTitles[0], "abc") == 0);
        assert(cfg.micSource == V5_MIC_SOURCE_DEVICE);
        assert(cfg.hasLanguage && cfg.language == V5_UI_LANGUAGE_ZH_HANT);
        assert(cfg.laboratoryFeatures == V5_LAB_INPUT_ASSISTANT);
    }

    // 9) 向后兼容硬证据:基线 parser 吃含三个尾字节的新帧 → 仍 return true 且 title 正确,
    //    尾字节被静默忽略(不错位、不整帧丢弃)。
    {
        const uint8_t frame[] = {
            V5_FRAME_CONFIG, 1, 2,
            2, 'h', 'i',
            3, 'a', 'b', 'c',
            V5_MIC_SOURCE_SYSTEM, V5_UI_LANGUAGE_ZH_HANS, V5_LAB_KNOWN_MASK
        };
        LegacyV5Config old = {};
        assert(legacyParseConfig(frame, sizeof(frame), old));
        assert(old.valid);
        assert(old.voiceMode == V5_VOICE_MODE_TOGGLE);
        assert(old.promptCount == 2);
        assert(strcmp(old.promptTitles[0], "hi") == 0);
        assert(strcmp(old.promptTitles[1], "abc") == 0);
    }

    printf("ALL PASS (9 cases + 3 locale values)\n");
    return 0;
}
