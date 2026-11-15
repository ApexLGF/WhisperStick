// buzzer_fx.cpp — AI 状态提示音(REQ-022 音效批次)非阻塞蜂鸣器驱动;设计说明见 buzzer_fx.h
// 音符表由 Resources/SoundsEffect/LYMCompose_v1_low_octave/*.qvbuzzer 转换:
//   源 NOTE{freq,soundMs,gapMs,dutyPercent} → 发声条目 {freq,soundMs,duty} +
//   gapMs>0 时的休止条目 {0,gapMs,0};duty = round(1023 * dutyPercent / 100)。
//   duty% 对照:18%→184 19%→194 20%→205 21%→215 22%→225 23%→235
//                24%→246 25%→256 26%→266 28%→286
#include <Arduino.h>
#include <Preferences.h>
#include "buzzer_fx.h"
#include "buzzer_volume.h"
#include "pin_config.h"

// ── 音量 0..100,20% 步进(NVS 持久化;PIN_BUZZER<0 的桩也保留 get/set 语义)──
static uint8_t s_volPct = 60;

#if PIN_BUZZER >= 0

#define BUZ_LEDC_CH   2    // 背光占通道 0(power_manager.cpp),蜂鸣器用 2(对齐 bringup 实测)
#define BUZ_LEDC_RES  10   // 10-bit → duty 0..1023
#define BUZ_NVS_NS    "buzzer"
#define BUZ_NVS_KEY   "vol"

// 音符:freq=0 表示休止(静音间隔);duty 为 100% 音量档的基准值,播放时按 s_volPct 缩放
struct BuzNote {
    uint16_t freq;
    uint16_t ms;
    uint16_t duty;
};

// 1. 任务开始:纯五度二音上行
static const BuzNote kFxTaskStarted[] = {
    {  932,  80, 246 }, { 0, 15, 0 },   // NOTE 932 80 15 24
    { 1397, 180, 225 },                 // NOTE 1397 180 0 22
};
// 2. 任务错误:四级半音下行,末音延长
static const BuzNote kFxTaskError[] = {
    { 1865, 115, 184 }, { 0, 67, 0 },   // NOTE 1865 115 67 18
    { 1760, 115, 194 }, { 0, 67, 0 },   // NOTE 1760 115 67 19
    { 1661, 115, 205 }, { 0, 67, 0 },   // NOTE 1661 115 67 20
    { 1568, 260, 215 },                 // NOTE 1568 260 0 21
};
// 3. 审批到来:增四度快速交替三组
static const BuzNote kFxApprovalRequired[] = {
    { 1245,  60, 225 }, { 0, 31, 0 },   // NOTE 1245 60 31 22
    { 1760,  60, 184 }, { 0, 31, 0 },   // NOTE 1760 60 31 18
    { 1245,  60, 225 }, { 0, 31, 0 },
    { 1760,  60, 184 }, { 0, 31, 0 },
    { 1245,  60, 225 }, { 0, 31, 0 },
    { 1760, 100, 184 },                 // NOTE 1760 100 0 18
};
// 4. 审批被他人处理:四音下行,末音延长
static const BuzNote kFxApprovalTaken[] = {
    { 1760,  95, 184 }, { 0, 41, 0 },   // NOTE 1760 95 41 18
    { 1568,  95, 215 }, { 0, 41, 0 },   // NOTE 1568 95 41 21
    { 1245,  95, 225 }, { 0, 41, 0 },   // NOTE 1245 95 41 22
    { 1175, 260, 235 },                 // NOTE 1175 260 0 23
};
// 5. 审批超时:三音下行 + 长低音结尾
static const BuzNote kFxApprovalExpired[] = {
    { 1661,  70, 205 }, { 0, 21, 0 },   // NOTE 1661 70 21 20
    { 1568,  85, 215 }, { 0, 24, 0 },   // NOTE 1568 85 24 21
    { 1397, 200, 225 },                 // NOTE 1397 200 0 22
};
// 6. 审批通过:纯四度二音上行,高音延长
static const BuzNote kFxApprovalAccepted[] = {
    { 1397, 110, 225 }, { 0, 45, 0 },   // NOTE 1397 110 45 22
    { 1865, 260, 184 },                 // NOTE 1865 260 0 18
};
// 7. 审批拒绝:单次纯四度下降
static const BuzNote kFxApprovalRejected[] = {
    { 1865, 110, 184 }, { 0, 45, 0 },   // NOTE 1865 110 45 18
    { 1397, 220, 225 },                 // NOTE 1397 220 0 22
};
// 8. 等待输入:两个同音呼叫后上行提问,完整重复两轮
static const BuzNote kFxInputRequired[] = {
    {  932,  70, 246 }, { 0,  66, 0 },  // NOTE 932 70 66 24
    {  932,  70, 246 }, { 0,  44, 0 },  // NOTE 932 70 44 24
    { 1175, 120, 235 }, { 0, 680, 0 },  // NOTE 1175 120 680 23
    {  932,  70, 246 }, { 0,  66, 0 },
    {  932,  70, 246 }, { 0,  44, 0 },
    { 1175, 160, 235 },                 // NOTE 1175 160 0 23
};
// 9. 任务完成:五音上行琶音,末音延长
static const BuzNote kFxTaskCompleted[] = {
    {  466,  80, 286 }, { 0, 56, 0 },   // NOTE 466 80 56 28
    {  623,  80, 266 }, { 0, 56, 0 },   // NOTE 623 80 56 26
    {  699,  80, 256 }, { 0, 56, 0 },   // NOTE 699 80 56 25
    {  932,  80, 246 }, { 0, 56, 0 },   // NOTE 932 80 56 24
    { 1175, 300, 235 },                 // NOTE 1175 300 0 23
};
// 音量试听:低八度版本的 2 秒持续单音。
static const BuzNote kFxVolumePreview[] = {
    { kBuzzerPreviewFreq, kBuzzerPreviewMs, 246 },  // NOTE 932 2000 0 24
};

struct BuzSeq {
    const char    *name;
    const BuzNote *notes;
    uint8_t        len;
};

#define BUZ_SEQ(name, tbl) { name, tbl, (uint8_t)(sizeof(tbl) / sizeof(BuzNote)) }

// 下标 = BuzzerFx - 1(BZ_NONE 无表)
static const BuzSeq kSeqs[] = {
    BUZ_SEQ("TASK_STARTED",      kFxTaskStarted),
    BUZ_SEQ("TASK_ERROR",        kFxTaskError),
    BUZ_SEQ("APPROVAL_REQUIRED", kFxApprovalRequired),
    BUZ_SEQ("APPROVAL_TAKEN",    kFxApprovalTaken),
    BUZ_SEQ("APPROVAL_EXPIRED",  kFxApprovalExpired),
    BUZ_SEQ("APPROVAL_ACCEPTED", kFxApprovalAccepted),
    BUZ_SEQ("APPROVAL_REJECTED", kFxApprovalRejected),
    BUZ_SEQ("INPUT_REQUIRED",    kFxInputRequired),
    BUZ_SEQ("TASK_COMPLETED",    kFxTaskCompleted),
};
static const uint8_t kSeqCount = sizeof(kSeqs) / sizeof(kSeqs[0]);

static const BuzNote *s_seq      = nullptr;   // 当前序列(nullptr = 空闲)
static uint8_t        s_seqLen   = 0;
static uint8_t        s_idx      = 0;
static BuzzerFx       s_curFx    = BZ_NONE;   // 当前播放中的音效(优先级判定用)
static unsigned long  s_noteEndMs = 0;

// 审批类可打断任务类;任务类不打断审批类(见 buzzer_fx.h 文件头)
static bool buzIsApprovalClass(BuzzerFx fx) {
    switch (fx) {
        case BZ_APPROVAL_REQUIRED:
        case BZ_APPROVAL_TAKEN:
        case BZ_APPROVAL_EXPIRED:
        case BZ_APPROVAL_ACCEPTED:
        case BZ_APPROVAL_REJECTED:
        case BZ_INPUT_REQUIRED:
            return true;
        default:
            return false;
    }
}

static void buzOff() {
    ledcWrite(BUZ_LEDC_CH, 0);
}

static void buzNote(const BuzNote &n) {
    uint32_t duty = buzzerScaleDuty(n.duty, s_volPct);
    if (duty > 1023) duty = 1023;
    if (n.freq == 0 || duty == 0) {
        buzOff();
    } else {
        ledcChangeFrequency(BUZ_LEDC_CH, n.freq, BUZ_LEDC_RES);
        ledcWrite(BUZ_LEDC_CH, duty);
    }
    s_noteEndMs = millis() + n.ms;
}

void buzzer_init() {
    Preferences p;
    if (p.begin(BUZ_NVS_NS, false)) {
        s_volPct = buzzerClampVolumePercent(p.getUChar(BUZ_NVS_KEY, 60));
        p.end();
    }
    ledcSetup(BUZ_LEDC_CH, kBuzzerPreviewFreq, BUZ_LEDC_RES);
    ledcAttachPin(PIN_BUZZER, BUZ_LEDC_CH);
    buzOff();
    Serial.printf("[bz] init vol=%u%% (nvs)\n", s_volPct);
}

// 唤醒后完整重建(不信任长睡后的残留通道状态,见 buzzer_fx.h 注释);
// 顺带丢弃睡眠期间未播完的序列,避免醒来补播陈旧音效
void buzzer_reinit() {
    s_seq = nullptr;
    s_seqLen = 0;
    s_idx = 0;
    s_curFx = BZ_NONE;
    ledcSetup(BUZ_LEDC_CH, kBuzzerPreviewFreq, BUZ_LEDC_RES);
    ledcAttachPin(PIN_BUZZER, BUZ_LEDC_CH);
    buzOff();
}

void buzzer_set_volume(uint8_t pct) {
    uint8_t v = buzzerClampVolumePercent(pct);
    if (v == s_volPct) {
        Serial.printf("[bz] vol %u -> %u%% (unchanged)\n", pct, v);
        return;
    }
    s_volPct = v;
    Preferences p;
    if (p.begin(BUZ_NVS_NS, false)) {
        p.putUChar(BUZ_NVS_KEY, v);
        p.end();
    }
    Serial.printf("[bz] vol %u -> %u%% (nvs saved)\n", pct, v);
}

uint8_t buzzer_get_volume() {
    return s_volPct;
}

void buzzer_preview_volume() {
    if (s_volPct == 0) {
        Serial.println("[bz] muted drop preview");
        return;
    }
    s_seq = kFxVolumePreview;
    s_seqLen = (uint8_t)(sizeof(kFxVolumePreview) / sizeof(BuzNote));
    s_curFx = BZ_NONE;
    s_idx = 0;
    Serial.printf("[bz] preview vol=%u%%\n", s_volPct);
    buzNote(s_seq[0]);
}

void buzzer_play(BuzzerFx fx) {
    if (fx == BZ_NONE || fx > kSeqCount) {
        s_seq = nullptr; s_seqLen = 0; s_curFx = BZ_NONE; buzOff();
        return;
    }
    // 静音态(vol=0):直接丢弃(触发点日志,不排队不入序列)
    if (s_volPct == 0) {
        Serial.printf("[bz] muted drop fx=%u (%s)\n", (unsigned)fx, kSeqs[fx - 1].name);
        return;
    }
    // 优先级:任务类不打断正在播的审批类(丢弃,不排队)
    if (!buzIsApprovalClass(fx) && s_seq != nullptr && buzIsApprovalClass(s_curFx)) {
        Serial.printf("[bz] drop %s (approval fx %s playing)\n",
                      kSeqs[fx - 1].name, kSeqs[s_curFx - 1].name);
        return;
    }
    const BuzSeq &sq = kSeqs[fx - 1];
    s_seq    = sq.notes;
    s_seqLen = sq.len;
    s_curFx  = fx;
    s_idx    = 0;
    uint32_t totalMs = 0;
    for (uint8_t i = 0; i < sq.len; i++) totalMs += sq.notes[i].ms;
    Serial.printf("[bz] play %s notes=%u total=%lums vol=%u%%\n",
                  sq.name, sq.len, (unsigned long)totalMs, s_volPct);
    buzNote(s_seq[0]);
}

void buzzer_tick() {
    if (s_seq == nullptr) return;
    if ((long)(millis() - s_noteEndMs) < 0) return;   // 当前音符未播完
    s_idx++;
    if (s_idx >= s_seqLen) {
        s_seq = nullptr;
        s_curFx = BZ_NONE;
        buzOff();
        return;
    }
    buzNote(s_seq[s_idx]);
}

bool buzzer_is_busy() { return s_seq != nullptr; }

#else  // 面包板无蜂鸣器:播放空操作,音量语义保留(NVS 不写)

void buzzer_init() {}
void buzzer_play(BuzzerFx fx) { (void)fx; }
void buzzer_tick() {}
bool buzzer_is_busy() { return false; }
void buzzer_reinit() {}
void buzzer_set_volume(uint8_t pct) { s_volPct = buzzerClampVolumePercent(pct); }
uint8_t buzzer_get_volume() { return s_volPct; }
void buzzer_preview_volume() { buzzer_play(BZ_NONE); }

#endif
