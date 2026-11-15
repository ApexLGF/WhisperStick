/*
 * ESP32StickDemo - BLE Audio PTT Demo
 *
 * Hardware: LILYGO T-Display-S3 + INMP441 + Button + RGB LED
 * Protocol: Compatible with QuickVibeHost Mac App
 * Device Name: MicPad-XXXX (XXXX = MAC 后 2 字节 hex,运行时动态生成)
 */

#include <driver/i2s.h>
#include <TFT_eSPI.h>
#include <NimBLEDevice.h>   // REQ-021: 已传递包含 host/ble_gap.h → ble_gap_conn_rssi 可用
#include <esp_sleep.h>
#include <esp_task_wdt.h>
#include <Preferences.h>
#include <atomic>
#include "hal/wdt_hal.h"   // RWDT(RTC 看门狗):S3 上 legacy soc/rtc_wdt.h 宏残缺不可用
#include "soc/rtc.h"
#include <math.h>
#include "adpcm_types.h"
#include "claude_status_parser.h"
#include "v5_protocol.h"
#include "ui_renderer.h"
#include "power_manager.h"
#include "led_manager.h"
#include "approval_protocol.h"   // REQ-022 审批协议纯逻辑模块(只调用,不修改)
#include "buzzer_fx.h"           // REQ-022 §B7 审批事件音效(非阻塞)
#include "input_gesture.h"
#include "action_mode_protocol.h"
#include "i18n_catalog.generated.h"
#include "micstick_ota.h"

// ── Firmware version (Stage 3a 显示在电池条) ─────────────
#ifndef FW_VERSION_STR
#define FW_VERSION_STR "1.2.3"   // 兜底值;正式口径由 platformio.ini 对应生产环境注入,bump-firmware-version.sh 三处同步
#endif

// ── Pin Definitions ──────────────────────────────────────
// 引脚常量按目标板分流到 pin_config.h(面包板 / v10 PCB),业务逻辑不依赖具体脚位:
//   面包板 = env:micpad ; v10 自制板 = env:micpad-v10(-DBOARD_V10)
#include "pin_config.h"
// 编码器方向:目标 CW→Down/CCW→Up(用户偏好)。v10 PCB 的 EC11 A/B 相位与面包板相反
// (2026-06-18 bring-up 实测),故 v10 取反才能保持同一物理方向。
// v10/v11/v12 的 A/B 接线相位一致；统一取反后 step>0 才代表物理顺时针。
#if defined(BOARD_V10) || defined(BOARD_V11) || defined(BOARD_MICSTICK_V12) || defined(BOARD_MICSTICK_V14)
#define ENC_INVERT     1   // PCB:相位反,取反保持 CW→Down
#else
#define ENC_INVERT     0   // 面包板:CW→Down
#endif

// ── Audio Config ─────────────────────────────────────────
#define SAMPLE_RATE     16000
#define PCM_CHUNK       512      // samples per chunk
#define ADPCM_CHUNK     256      // bytes per ADPCM output
// Stage 5: HP 跟 Stick S3 对齐;增益按硬件分别调
//   HP=0.91 ≈ 250Hz cutoff @16kHz  砍工频/DC 漂移,人声共振峰不动
//   GAIN=8 (Stage 6: 修正 INMP441 24-bit MSB-aligned 读法后, 主信号回到正常量级。
//          INMP441 是 24-bit 数据放在 32-bit slot 的高位; 之前用 16-bit 读直接丢了
//          低 8 bit 灵敏度。改 32-bit 读后 main RMS 从 ~50 涨到 ~200, GAIN 回 8 即足
//          够过阈值, 同时大声讲话(main~800)peak 留 4× crest 余量不削波)
#define HP_FILTER_ALPHA 0.91f
// v10 实测(2026-06-18):底部进声+小孔,正常距离语音到不了麦(~噪声底),必须近讲(1-3cm)。
// 近讲实测 main~200-400(峰值约 -45dBFS),与面包板基线持平。取 GAIN=6 使送出 RMS ~1500
// (≈面包板 200×8),近讲峰值有余量不削波;吹气这种极端过压会削但无所谓。
#ifdef BOARD_V10
#define AUDIO_GAIN      6.0f
#else
#define AUDIO_GAIN      8.0f
#endif
#ifndef MIC_PDM_GAIN_SHIFT
#define MIC_PDM_GAIN_SHIFT 0
#endif
#define AUDIO_AGC_MAX_GAIN     (AUDIO_GAIN * (float)(1 << MIC_PDM_GAIN_SHIFT))
#define AUDIO_AGC_INITIAL_GAIN AUDIO_AGC_MAX_GAIN
#include "audio_agc.h"

// Stage 5: 200ms 预录环形缓冲(BtnA 按下瞬间到 hold thresh 这 500ms 间录到环形,
// 真正进入 PTT 时把最近 200ms 一起送出去 — 抢说话不掉字)
// PREBUF_CHUNKS = ceil(3200/512) = 7 chunks × 512 × 2 = 7168 字节
#define PREBUF_MS        400   // REQ-010: 长语音模式单击有 ~280ms 双击窗口延迟,预录加深到 400ms 保证不掉字
#define PREBUF_SAMPLES   (SAMPLE_RATE * PREBUF_MS / 1000)
#define PREBUF_CHUNKS    ((PREBUF_SAMPLES + PCM_CHUNK - 1) / PCM_CHUNK)

// ── Mic Topology (阶段6.4 后置开关) ────────────────────
#define DUAL_MIC_ENABLED 0  // ⭐ 硬件开关: 1=双麦立体声(L=Mic1主, R=Mic2参考), 0=单麦(仅 Mic1, L/R=GND) | 默认单麦, 详见父项目阶段6.3 结论

// ── NLMS Config (阶段6.3 双麦自适应降噪) ───────────────
#define NLMS_ENABLED 0      // ⭐ 算法开关: 1=ANC 开启(需 DUAL_MIC_ENABLED=1), 0=旁路(HP+增益直通) | 默认关闭
#define NLMS_TAPS  64       // 滤波器阶数; 16kHz 下覆盖 ~4ms 声学路径
#define NLMS_MU    0.05f    // 步长; 偏保守, 语音期不易破坏权值
#define NLMS_EPS   1e-4f    // 归一化防除零

#if NLMS_ENABLED && !DUAL_MIC_ENABLED
#error "NLMS_ENABLED=1 requires DUAL_MIC_ENABLED=1 (no reference mic available in single-mic mode)"
#endif

// ── BLE UUIDs (compatible with QuickVibeHost) ────────────
#define AUDIO_SERVICE_UUID        "19b10000-e8f2-537e-4f6c-d104768a1214"
#define AUDIO_DATA_CHAR_UUID      "19b10001-e8f2-537e-4f6c-d104768a1214"
#define AUDIO_CONTROL_CHAR_UUID   "19b10002-e8f2-537e-4f6c-d104768a1214"
#define CLAUDE_STATUS_CHAR_UUID   "19b10003-e8f2-537e-4f6c-d104768a1214"
#define PERM_REQUEST_CHAR_UUID    "19b10004-e8f2-537e-4f6c-d104768a1214"
#define PERM_RESPONSE_CHAR_UUID   "19b10005-e8f2-537e-4f6c-d104768a1214"
#define OTA_SERVICE_UUID           "19b10010-e8f2-537e-4f6c-d104768a1214"
#define OTA_CONTROL_CHAR_UUID      "19b10011-e8f2-537e-4f6c-d104768a1214"
#define OTA_DATA_CHAR_UUID         "19b10012-e8f2-537e-4f6c-d104768a1214"
#define OTA_STATUS_CHAR_UUID       "19b10013-e8f2-537e-4f6c-d104768a1214"

// ── Control Commands ─────────────────────────────────────
#define CMD_START_REC         0x01
#define CMD_STOP_REC          0x02
#define CMD_VOICE_RECOGNIZING 0x03
#define CMD_VOICE_DONE        0x04
#define CMD_VOICE_ERROR       0x05
#define VOICE_NOTIFY_SUCCESS  0x06   // Async ASR success [0x06, buttonId]
#define VOICE_NOTIFY_FAILURE  0x07   // Async ASR failure [0x07, buttonId, errorMsg...]
#define CMD_ENTER             0x10   // BtnA 短按 = 模拟回车
#define CMD_ESC               0x11   // BtnB 短按 = 模拟 Esc
#define CMD_SHIFT_TAB         0x12   // BtnB 长按 = Mac 注入 Shift+Tab(模式切换)
#define CMD_BACKSPACE         0x13   // EC11 SW 短按 = 模拟 Backspace(删除)
#define CMD_BTN_A_PTT_STOP    0x14
#define CMD_UP                0x15   // 上键 = 模拟 ↑
#define CMD_DOWN              0x16   // 下键 = 模拟 ↓
#define CMD_LEFT              0x17   // v5: 编辑模式光标左移 ←
#define CMD_RIGHT             0x18   // v5: 编辑模式光标右移 →
#define CMD_BTN_A_PTT_START   0x19   // T-033: 系统麦模式 PTT 按下(设备→Mac);仅 micSource=SYSTEM 时发
#define CMD_HANDSHAKE         0x20
#define CMD_REQUEST_STATUS    0x21   // 让 Mac 主动推状态帧 (v3+)
// ── v5 设备→Mac 新命令(REQ-011/012/013) ──
#define CMD_PROMPT_SELECT     0x30   // [0x30, idx] idx=0 内置"AI推荐(→+回车)",1..8 自定义
#define CMD_INPUT_ASSISTANT_ACTION 0x31 // [0x31,requestId,operation];0xFE=改为全文
#define CMD_EXCLUSIVE_TOGGLE  0x32   // [0x32, sessionIdx] 直通切换(Mac 端判定 set/clear)
#define CMD_DEVICE_MODE       0x34   // [0x34, mode] 0=normal 1=edit 2=prompt 3=approval(REQ-022;Mac 胶囊 UI 联动,既有值不变)
#define CMD_BUZZER_VOLUME     0x37   // [0x37, pct] Mac→设备 蜂鸣器音量 0..100,20% 步进(REQ-022 音效批次;0x36 已被审批响应占用)
#define CMD_LED_BRIGHTNESS    0x38   // [0x38, pct] Mac→设备 指示灯亮度 0/8/32/70
#define CMD_BUZZER_PREVIEW    0x39   // [0x39, pct] Mac→设备 设置蜂鸣器音量并播放短试听音
#define CMD_DEVICE_PREFS_GET  0x3A   // Mac→设备 查询 NVS 硬件偏好
#define CMD_DEVICE_PREFS      0x3B   // 设备→Mac [0x3B,buzzerPct,ledPct]
#define CMD_ACTION_EVENT      0x3C   // [0x3C,context,control,gesture,delta]
#define CMD_SHIP_MODE_REQUEST  0x3D   // Mac→设备:显示运输模式确认页；B确认/C取消
#define PROTOCOL_VERSION      5

// 按键长按阈值（ms）：超过 = PTT 模式，未到 = 短按发 Enter/Esc
// 与 Stick S3 M5.BtnA.setHoldThresh(500) 保持一致
#define BTN_HOLD_THRESH_MS    250   // 2026-05-05 全局阈值 500→250(对齐 Stick S3 BtnB 长按节奏)
// EC11 按压需兼顾单击确认与长按进入编辑模式；独立放宽，避免正常按压被误判为长按。
#define ENC_SW_HOLD_THRESH_MS 600
// V14 侧面 SW1 与 SGM41511 nQON 共线；软件长按 2s 只打开运输模式确认页。
#define SIDE_BUTTON_HOLD_THRESH_MS 2000

// ── Button State / Events (须前置，否则 Arduino 自动原型会引用未定义类型) ──
struct ButtonState {
    uint8_t pin;
    bool wasPressed;
    unsigned long pressStartMs;
    bool isHolding;
};

enum ButtonEvent {
    BTN_NONE,
    BTN_RAW_PRESS,   // 按下瞬间（下降沿）— Stage 5 用于激活预录环形缓冲
    BTN_TAP,         // 短按松开（< 阈值）
    BTN_HOLD_START,  // 按住到达阈值（仅触发一次）
    BTN_HOLD_END,    // 长按后松开
};

// ── Audio Packet ─────────────────────────────────────────
typedef struct {
    uint8_t  header[2];         // 0xAA, 0x55
    uint8_t  buttonId;          // 0x01
    uint16_t seq;
    uint8_t  adpcm[ADPCM_CHUNK];
} __attribute__((packed)) AudioPacket;

// ── ADPCM Tables ─────────────────────────────────────────
static const int16_t stepTable[89] = {
    7, 8, 9, 10, 11, 12, 13, 14, 16, 17,
    19, 21, 23, 25, 28, 31, 34, 37, 41, 45,
    50, 55, 60, 66, 73, 80, 88, 97, 107, 118,
    130, 143, 157, 173, 190, 209, 230, 253, 279, 307,
    337, 371, 408, 449, 494, 544, 598, 658, 724, 796,
    876, 963, 1060, 1166, 1282, 1411, 1552, 1707, 1878, 2066,
    2272, 2499, 2749, 3024, 3327, 3660, 4026, 4428, 4871, 5358,
    5894, 6484, 7132, 7845, 8630, 9493, 10442, 11487, 12635, 13899,
    15289, 16818, 18500, 20350, 22385, 24623, 27086, 29794, 32767
};

static const int8_t indexTable[16] = {
    -1, -1, -1, -1, 2, 4, 6, 8,
    -1, -1, -1, -1, 2, 4, 6, 8
};

// ── Globals ──────────────────────────────────────────────
TFT_eSPI tft = TFT_eSPI();

// 动态设备名:MicPad-XXXX(MAC 后 2 字节 hex),由 setup() 填充
#if defined(BOARD_MICSTICK_V12) || defined(BOARD_MICSTICK_V14)
char devName[16] = "MicStick-XXXX";   // v12 新产品线广播名
#else
char devName[16] = "MicPad-XXXX";
#endif

NimBLEServer* pServer = nullptr;
NimBLECharacteristic* pAudioDataChar = nullptr;
NimBLECharacteristic* pAudioControlChar = nullptr;
NimBLECharacteristic* pClaudeStatusChar = nullptr;
NimBLECharacteristic* pPermRequestChar = nullptr;
micstick_ota::MicStickOTASession micstickOta;

volatile bool bleConnected = false;
volatile uint16_t currentMTU = 23;
volatile bool isRecording = false;
// REQ-003 Phase 2.1 (2026-05-03): 跟踪 conn handle 用于按 power state 切连接间隔
volatile uint16_t s_bleConnHandle = 0xFFFF;

// ── Stage 2: Claude / Permission / ASR 状态(只解析,不渲染) ──
ClaudeStatusState     g_claudeStatus = {};
PermissionToastState  g_permToast    = {};
AsrFeedbackState      g_asrFeedback  = {};

// ── v1.0.0: v5 UI 数据模型(渲染唯一数据源,见 ui_model.h)──
V5Status  g_v5      = {};
V5Config  g_v5cfg   = {};   // 语音模式 + Prompt 标题(连接时 Mac 下发,不持久化)
static std::atomic<uint8_t> g_pendingUiLocale{0xFF};
// Mac 只能请求确认页，不能直接断开电池。NimBLE 回调仅置位；设备端 B
// 完成物理确认后，主循环才执行不可逆的 SGM41511 BATFET_DIS 写入。
static std::atomic<bool> g_pendingShipModeRequest{false};
static bool g_shipModeCommitPending = false;
static unsigned long g_shipModeCommitAtMs = 0;
static constexpr unsigned long SHIP_MODE_FINAL_NOTICE_MS = 500;
// BLE callbacks run on NimBLE's task. Defer UI mutation to loop() so a host
// disconnect cannot leave the device trapped in an action mode.
static std::atomic<bool> g_actionModeExitOnDisconnect{false};
static std::atomic<bool> g_laboratoryModeExitPending{false};
// T-033: Mac 下发的音源模式(0x53 尾字节)。老 Mac 不发 → cfg.micSource=DEVICE。
// 定义在此(而非 startPTT 旁)因为 audioTask 也用,须先于其定义可见。
static inline bool micSourceIsSystem() {
    return g_v5cfg.valid && g_v5cfg.micSource == V5_MIC_SOURCE_SYSTEM;
}
static inline bool promptRecommendationsEnabled() {
    return g_v5cfg.valid &&
           (g_v5cfg.laboratoryFeatures & V5_LAB_PROMPT_RECOMMENDATIONS) != 0;
}
static inline bool inputAssistantEnabled() {
    return g_v5cfg.valid &&
           (g_v5cfg.laboratoryFeatures & V5_LAB_INPUT_ASSISTANT) != 0;
}
UiListSel g_listSel = { -1, false, 0 };
// REQ-021 v2 / T-025:Mac 下发当日分钟数 + 本地 millis 走时(顶栏 HH:MM)
bool          g_haveTime    = false;
uint16_t      g_timeBaseMin = 0;     // 同步时刻的当日分钟数
unsigned long g_timeBaseMs  = 0;     // 同步时刻的 millis()
// mock 布局验证(串口 MOCK n):置位期间 v4/v5 帧不覆盖 g_v5
static bool g_mockHold = false;
// REQ-023 二期布局验证:SPL 1=强制未连接 splash / 2=强制已连接 splash / 0=恢复
static uint8_t g_splashDemo = 0;

// ── 合成输入注入(串口 TAP/HOLD/REL/ENC,自主验证用;与真实按键同一事件路径)──
static ButtonEvent g_synthA = BTN_NONE, g_synthB = BTN_NONE,
                   g_synthC = BTN_NONE, g_synthSw = BTN_NONE;
static int8_t g_synthEnc = 0;

// ── 按键手势状态 ──
static TapGestureState g_tapA;
static TapGestureState g_tapB;
static TapGestureState g_tapC;
static unsigned long g_recStartMs = 0;          // 录音起始(长语音 60min 超时)
static unsigned long g_aSuppressTapUntilMs = 0; // 切换录音停止后吞掉同一双击的第二击
static bool g_toggleRecording = false;
static bool g_holdRecording = false;
static bool g_appSwitcherActive = false;
static bool g_appSwitcherHostAcked = false;
static unsigned long g_appSwitcherRequestMs = 0;
static unsigned long g_appSwitcherTouchMs = 0;
#define APP_SWITCHER_LEGACY_FALLBACK_MS 1200UL
#define APP_SWITCHER_LOADING_TIMEOUT_MS 5000UL
#define APP_SWITCHER_MODE_TIMEOUT_MS 15000UL
#define DBL_CLICK_MS 280
// 审批模态专用双击窗口:更短=单击判定更快 + 更难误触发 always_allow(用户 2026-07-23 定 200ms;
// 其他模式手势维持 280ms 不变)
#define APV_DBL_CLICK_MS 200
#define LONG_VOICE_TIMEOUT_MS (60UL * 60UL * 1000UL)
// 60min 超时的运行时覆盖(串口 TMO n 秒,仅测试用;重启恢复默认)
static unsigned long g_voiceTimeoutMs = LONG_VOICE_TIMEOUT_MS;

// ── v1.0.0 设备 UI 模式(REQ-011/012/013)──
static DeviceUiMode g_uiMode  = DEV_MODE_NORMAL;
UiModeCtx           g_modeCtx = {};

// ── REQ-022 审批队列 + 模态视图 ──
// 存储期约束(approval_protocol.h 文件头):sizeof(ApprovalQueue)≈2.9KB,
// 必须 static/global 生命周期持有,严禁在函数局部作用域按值声明(任务栈会溢出)。
static ApprovalQueue  g_approvalQueue;
static ApprovalUiView g_approvalView = {};
static uint8_t g_apvLastTx[kApprovalShortFrameLen] = {0};  // 最近一次待发 0x36(APVTX 调试)
static uint8_t g_apvLastTxLen = 0;

// ── REQ-022 竞态修复(code review CRITICAL)──
// NimBLE GATT onWrite 跑在 nimble_host 独立 FreeRTOS 任务,与 loop() 双核真并发;
// ApprovalQueue 纯逻辑无锁,removeAt 的数组搬移在两侧并发下会损坏 count/curIndex。
// 方案(与 Mac 侧串行队列设计对称):onWrite 只判别首字节并把原始帧投进 FreeRTOS
// Queue(定长元素,深度 8,满则丢弃计数打日志);loop() 每帧顶部取出后才调
// handleApprovalFrame —— ApprovalQueue 的全部读写收敛到 loop 单任务。
struct ApprovalRxMsg {
    uint16_t len;
    uint8_t  bytes[360];   // ≥ kApprovalRequestMaxLen(357);0x36/0x56 短帧同容器
};
static QueueHandle_t g_apvRxQueue = nullptr;   // setup 里 xQueueCreate(8, sizeof(ApprovalRxMsg))
// 丢弃计数:onWrite(nimble_host 任务)侧递增,仅诊断用;非原子递增的竞态最坏丢计数,无一致性影响
static volatile uint32_t g_apvRxDropCount = 0;

struct TaskLifecycleRxMsg {
    uint8_t len;
    uint8_t bytes[TASK_LIFECYCLE_EVENT_FRAME_LEN];
};
static QueueHandle_t g_taskLifecycleRxQueue = nullptr;
static std::atomic<bool> g_taskLifecycleResetPending{true};
static bool g_explicitTaskAudio = false;
static TaskLifecycleDeduper g_taskLifecycleDeduper;
#define TASK_AUDIO_QUEUE_CAP 24
static BuzzerFx g_taskAudioQueue[TASK_AUDIO_QUEUE_CAP] = {};
static uint8_t g_taskAudioHead = 0;
static uint8_t g_taskAudioCount = 0;

// REQ-011: B 长按连删(频率 300ms 起步,每次 ×0.85 加速到 50ms 下限)
#define B_DEL_START_MS 300
#define B_DEL_MIN_MS   50
static bool          g_bDeleting      = false;
static unsigned long g_bDelNextMs     = 0;
static unsigned long g_bDelIntervalMs = 300;
static uint16_t      g_bDelCount      = 0;

// Action-mode repeat is generic: the firmware reports repeat ticks for both
// B and C and leaves their meaning entirely to the Host configuration.
static ActionRepeatState g_actionRepeatB;
static ActionRepeatState g_actionRepeatC;

// REQ-011: Prompt 选择模式
static int8_t        g_promptSel     = 0;
static unsigned long g_promptTouchMs = 0;
static unsigned long g_promptRequestMs = 0;
static bool          g_promptHostAcked = false;
static uint8_t       g_promptNextRequestId = 0;
#define PROMPT_LEGACY_FALLBACK_MS 1200UL
#define PROMPT_LOADING_TIMEOUT_MS 20000UL
#define PROMPT_MODE_TIMEOUT_MS 30000UL

static unsigned long g_assistantRequestMs = 0;
static unsigned long g_assistantTouchMs = 0;
static unsigned long g_assistantStatusMs = 0;
static bool g_assistantHostAcked = false;
static uint8_t g_assistantNextRequestId = 0;
#define ASSISTANT_LEGACY_FALLBACK_MS 1200UL
#define ASSISTANT_LOADING_TIMEOUT_MS 20000UL
#define ASSISTANT_MODE_TIMEOUT_MS 60000UL

// REQ-012: 编辑模式内 PTT(固定按住式,与全局语音模式无关)
static bool g_editPtt = false;

// REQ-013: 会话框选(旋转出现,5s 无操作隐藏)
static unsigned long g_frameTouchMs = 0;
#define FRAME_HIDE_MS 5000UL

// v4 phase → v5 DisplayState(REQ-007 落地前的临时映射,让现网 Mac app 可用)
static uint8_t phaseToState(uint8_t phase) {
    switch (phase) {
        case 1:  return SDS_ACTIVE;      // processing
        case 2:  return SDS_READY;       // waiting input
        case 3:  return SDS_PERMISSION;  // waiting approval
        case 4:  return SDS_ACTIVE;      // compacting
        case 5:  return SDS_PAUSED;      // ended
        default: return SDS_READY;       // idle
    }
}

static void mapV4ToV5(const ClaudeStatusState &cs, V5Status &out) {
    V5Status v = {};
    v.agentCount             = 1;
    v.agents[0].agentId      = AGENT_CLAUDE_CODE;
    v.agents[0].usage5hPct   = cs.usagePct;
    v.agents[0].usage7dPct   = 0;
    v.agents[0].resetInHours = V5_RESET_UNKNOWN;
    v.agents[0].totalCount   = cs.sessionCount;
    v.agents[0].activeCount  = cs.dashCount;   // v4 无活跃细分,近似取 dash 数
    uint8_t n = (cs.dashCount > V5_MAX_SESSIONS) ? V5_MAX_SESSIONS : cs.dashCount;
    v.sessionCount = n;
    for (uint8_t i = 0; i < n; i++) {
        strncpy(v.sessions[i].name, cs.dashes[i].name, sizeof(v.sessions[i].name) - 1);
        v.sessions[i].agentId  = AGENT_CLAUDE_CODE;
        v.sessions[i].state    = phaseToState(cs.dashes[i].phase);
        // v4 只有全局 ctx(已用%),折算成首会话的余量;其余未知
        v.sessions[i].ctxPct   = (i == 0 && cs.ctxPct <= 100)
                                 ? (uint8_t)(100 - cs.ctxPct) : V5_CTX_UNKNOWN;
        v.sessions[i].colorIdx = cs.dashes[i].colorIdx;
    }
    v.exclusiveIdx = (cs.exclusiveIdx < (int8_t)n) ? cs.exclusiveIdx : -1;
    v.inactiveStart = -1;   // T-034: V5Status v = {} 会把它零初始化成 0(=全部非活跃),必须显式置 -1
    v.valid        = cs.valid;
    out = v;
}

// ── REQ-008 布局 mock 数据集(串口 MOCK 0..8 / MOCK 9=关) ──
static void mockSession(V5Status &v, uint8_t i, const char *name, uint8_t agentId,
                        uint8_t state, uint8_t ctx, uint8_t color) {
    strncpy(v.sessions[i].name, name, sizeof(v.sessions[i].name) - 1);
    v.sessions[i].agentId  = agentId;
    v.sessions[i].state    = state;
    v.sessions[i].ctxPct   = ctx;
    v.sessions[i].colorIdx = color;
}

static void applyMock(int n) {
    if (n == 9) {
        g_mockHold = false;
        g_v5 = {};
        g_v5.inactiveStart = -1;   // T-034: {} 零初始化 = 0 = "全部非活跃",必须显式置 -1
        g_listSel = { -1, false, 0 };
        Serial.println("[mock] off, live data resumes");
        return;
    }
    g_mockHold = true;
    V5Status v = {};
    v.exclusiveIdx = -1;
    v.inactiveStart = -1;
    v.valid = true;
    g_listSel = { -1, false, 0 };

    switch (n) {
        case 0:   // 空状态:跳舞动画
            break;
        case 1: { // 单 agent,3 会话
            v.agentCount = 1;
            v.agents[0] = { AGENT_CLAUDE_CODE, 37, 62, 3, 2, 3 };
            v.sessionCount = 3;
            mockSession(v, 0, "VibeEverything", AGENT_CLAUDE_CODE, SDS_ACTIVE, 84, 4);
            mockSession(v, 1, "文档整理", AGENT_CLAUDE_CODE, SDS_NEEDS_REVIEW, 46, 2);
            mockSession(v, 2, "QuickVibeHost", AGENT_CLAUDE_CODE, SDS_READY, 71, 6);
            break;
        }
        case 2: { // 双 agent,8 会话,直通第 2 行
            v.agentCount = 2;
            v.agents[0] = { AGENT_CLAUDE_CODE, 83, 41, 2, 3, 5 };
            v.agents[1] = { AGENT_CODEX, 12, 55, V5_RESET_UNKNOWN, 1, 3 };
            v.sessionCount = 8;
            mockSession(v, 0, "VibeEverything", AGENT_CLAUDE_CODE, SDS_ACTIVE, 84, 4);
            mockSession(v, 1, "PCB-v12-布线", AGENT_CLAUDE_CODE, SDS_PERMISSION, 32, 0);
            mockSession(v, 2, "固件重构v1.0.0", AGENT_CLAUDE_CODE, SDS_ACTIVE, 58, 2);
            mockSession(v, 3, "codex-web-app", AGENT_CODEX, SDS_ACTIVE, V5_CTX_UNKNOWN, 5);
            mockSession(v, 4, "外壳打印", AGENT_CLAUDE_CODE, SDS_COMPLETED, 91, 3);
            mockSession(v, 5, "数据分析脚本", AGENT_CODEX, SDS_READY, V5_CTX_UNKNOWN, 7);
            mockSession(v, 6, "翻译批处理", AGENT_CLAUDE_CODE, SDS_PAUSED, 12, 8);
            mockSession(v, 7, "夜间巡检", AGENT_CODEX, SDS_STALE, V5_CTX_UNKNOWN, 10);
            v.exclusiveIdx = 2;
            break;
        }
        case 3:   // 双 agent,12 会话(滚动 + 8 态全集),框选第 5 行
        case 4: { // 同 3 但 scrollTop=5(滚动视图)
            v.agentCount = 2;
            v.agents[0] = { AGENT_CLAUDE_CODE, 83, 92, 1, 5, 8 };
            v.agents[1] = { AGENT_CODEX, 47, 30, 4, 2, 4 };
            v.sessionCount = 12;
            mockSession(v, 0,  "ready状态", AGENT_CLAUDE_CODE, SDS_READY, 90, 0);
            mockSession(v, 1,  "active呼吸", AGENT_CLAUDE_CODE, SDS_ACTIVE, 80, 1);
            mockSession(v, 2,  "completed短闪", AGENT_CLAUDE_CODE, SDS_COMPLETED, 70, 2);
            mockSession(v, 3,  "stale灰", AGENT_CODEX, SDS_STALE, V5_CTX_UNKNOWN, 3);
            mockSession(v, 4,  "needs_review黄", AGENT_CLAUDE_CODE, SDS_NEEDS_REVIEW, 50, 4);
            mockSession(v, 5,  "permission红慢", AGENT_CLAUDE_CODE, SDS_PERMISSION, 40, 5);
            mockSession(v, 6,  "blocked红快", AGENT_CODEX, SDS_BLOCKED, V5_CTX_UNKNOWN, 6);
            mockSession(v, 7,  "paused灰静", AGENT_CLAUDE_CODE, SDS_PAUSED, 20, 7);
            mockSession(v, 8,  "很长的会话名称测试截断效果如何", AGENT_CLAUDE_CODE, SDS_ACTIVE, 15, 8);
            mockSession(v, 9,  "session-10", AGENT_CODEX, SDS_READY, V5_CTX_UNKNOWN, 9);
            mockSession(v, 10, "session-11", AGENT_CLAUDE_CODE, SDS_READY, 99, 10);
            mockSession(v, 11, "session-12", AGENT_CODEX, SDS_READY, V5_CTX_UNKNOWN, 0);
            v.exclusiveIdx = 1;
            g_listSel = { 4, true, (uint8_t)((n == 4) ? 5 : 0) };
            break;
        }
        case 5: { // REQ-023:混合计费(Claude 订阅 40px + Codex API 24px)
            v.agentCount = 2;
            v.agents[0] = { AGENT_CLAUDE_CODE, 20, 47, 4, 1, 2, V5_BILLING_SUBSCRIPTION, 0 };
            v.agents[1] = { AGENT_CODEX, V5_USAGE_UNKNOWN, V5_USAGE_UNKNOWN, V5_RESET_UNKNOWN,
                            2, 5, V5_BILLING_API, 348000UL };
            v.sessionCount = 3;
            mockSession(v, 0, "lgfobsidian-a5", AGENT_CLAUDE_CODE, SDS_ACTIVE, 25, 1);
            mockSession(v, 1, "确认审批模式", AGENT_CLAUDE_CODE, SDS_PERMISSION, 48, 2);
            mockSession(v, 2, "查间 Codex 键", AGENT_CODEX, SDS_PAUSED, V5_CTX_UNKNOWN, 3);
            v.exclusiveIdx = 1;
            break;
        }
        case 6: { // REQ-023:双 API(会话区上移到 y=76)
            v.agentCount = 2;
            v.agents[0] = { AGENT_CLAUDE_CODE, V5_USAGE_UNKNOWN, V5_USAGE_UNKNOWN, V5_RESET_UNKNOWN,
                            1, 2, V5_BILLING_API, 1200000UL };
            v.agents[1] = { AGENT_CODEX, V5_USAGE_UNKNOWN, V5_USAGE_UNKNOWN, V5_RESET_UNKNOWN,
                            2, 5, V5_BILLING_API, 348000UL };
            v.sessionCount = 4;
            mockSession(v, 0, "lgfobsidian-a5", AGENT_CLAUDE_CODE, SDS_ACTIVE, 25, 1);
            mockSession(v, 1, "了解软件界面", AGENT_CLAUDE_CODE, SDS_READY, 8, 2);
            mockSession(v, 2, "确认审批模式", AGENT_CLAUDE_CODE, SDS_THINKING, 48, 3);
            mockSession(v, 3, "testcc-8a", AGENT_CODEX, SDS_NEEDS_REVIEW, V5_CTX_UNKNOWN, 4);
            v.exclusiveIdx = 2;
            break;
        }
        case 7: { // T-034:活跃 3 + 非活跃 4(折叠/展开截图用)
            v.agentCount = 2;
            v.agents[0] = { AGENT_CLAUDE_CODE, 37, 62, 3, 3, 7 };
            v.agents[1] = { AGENT_CODEX, 12, 55, V5_RESET_UNKNOWN, 0, 0 };
            v.sessionCount = 7;
            mockSession(v, 0, "等审批-项目", AGENT_CLAUDE_CODE, SDS_PERMISSION, 32, 0);
            mockSession(v, 1, "工作中-项目", AGENT_CLAUDE_CODE, SDS_ACTIVE, 84, 4);
            mockSession(v, 2, "挂着-TUI", AGENT_CODEX, SDS_READY, V5_CTX_UNKNOWN, 5);
            mockSession(v, 3, "非活跃-一", AGENT_CLAUDE_CODE, SDS_STALE, 46, 2);
            mockSession(v, 4, "非活跃-二", AGENT_CODEX, SDS_STALE, V5_CTX_UNKNOWN, 6);
            mockSession(v, 5, "非活跃-三", AGENT_CLAUDE_CODE, SDS_STALE, 71, 3);
            mockSession(v, 6, "非活跃-四", AGENT_CODEX, SDS_STALE, V5_CTX_UNKNOWN, 7);
            v.inactiveStart = 3;
            break;
        }
        case 8: { // T-034:活跃 1 + 非活跃 7 → 验证设备端 ≤5 条截断
            v.agentCount = 1;
            v.agents[0] = { AGENT_CLAUDE_CODE, 20, 47, 4, 1, 8 };
            v.sessionCount = 8;
            mockSession(v, 0, "唯一活跃", AGENT_CLAUDE_CODE, SDS_ACTIVE, 25, 1);
            mockSession(v, 1, "旧会话1", AGENT_CLAUDE_CODE, SDS_STALE, 10, 2);
            mockSession(v, 2, "旧会话2", AGENT_CLAUDE_CODE, SDS_STALE, 11, 3);
            mockSession(v, 3, "旧会话3", AGENT_CLAUDE_CODE, SDS_STALE, 12, 4);
            mockSession(v, 4, "旧会话4", AGENT_CLAUDE_CODE, SDS_STALE, 13, 5);
            mockSession(v, 5, "旧会话5", AGENT_CLAUDE_CODE, SDS_STALE, 14, 6);
            mockSession(v, 6, "旧会话6", AGENT_CLAUDE_CODE, SDS_STALE, 15, 7);
            mockSession(v, 7, "旧会话7", AGENT_CLAUDE_CODE, SDS_STALE, 16, 8);
            v.inactiveStart = 1;
            break;
        }
        default:
            Serial.printf("[mock] unknown set %d\n", n);
            g_mockHold = false;
            return;
    }
    g_v5 = v;
    Serial.printf("[mock] set %d applied (agents=%u sessions=%u)\n",
                  n, v.agentCount, v.sessionCount);
}

// ══════════════════════════════════════════════════════════
// REQ-022 音效批次:会话状态边沿检测(任务级音效)
// 数据源实况:渲染统一数据源 g_v5(v5 0x52 帧直写;v4 ClaudeStatus dash 的
//   phase(0=idle 1=processing 2=waitingForInput 3=waitingForApproval 4=compacting 5=ended)
//   经 phaseToState 折算后同样落 g_v5),loop 侧每帧扫描,两条协议路径统一覆盖。
// 线上 state 域 = SessionDisplayState(ui_model.h 8 态);Mac v5State 实发:
//   idle→SDS_READY(0) processing/compacting→SDS_ACTIVE(1) 非活跃→SDS_STALE(3)
//   waitingForInput→SDS_NEEDS_REVIEW(4) waitingForApproval→SDS_PERMISSION(5) ended→SDS_PAUSED(7);
//   SDS_COMPLETED(2)/SDS_BLOCKED(6) 现网 Mac 未发,规则仍预留覆盖。
// 边沿规则(running = SDS_ACTIVE):
//   非 running → running                    BZ_TASK_STARTED(同会话 5s 冷却防抖)
//   → SDS_BLOCKED(error)                   BZ_TASK_ERROR
//   running → SDS_COMPLETED/SDS_READY(idle) BZ_TASK_COMPLETED
//   → SDS_NEEDS_REVIEW(waitingForInput)    不响(INPUT_REQUIRED 只由 notifyOnly 审批帧触发)
// 新会话首帧不算边沿;会话消失/断连(valid=false)清槽 → 重连首帧不轰鸣。
// ══════════════════════════════════════════════════════════
#define SESS_EDGE_SLOTS 12                     // = V5_MAX_SESSIONS
#define SESS_EDGE_START_COOLDOWN_MS 5000UL
struct SessEdgeSlot {
    bool          used;
    uint32_t      nameHash;       // FNV-1a(会话名);同名会话按扫描序各占一槽
    uint8_t       lastState;      // SessionDisplayState
    unsigned long lastStartFxMs;  // 上次 TASK_STARTED 播放时刻(冷却用;0=未播过)
};
static SessEdgeSlot g_sessEdge[SESS_EDGE_SLOTS] = {};

static uint32_t sessNameHash(const char *s) {
    uint32_t h = 2166136261u;                  // FNV-1a 32-bit
    while (*s) { h ^= (uint8_t)*s++; h *= 16777619u; }
    return h;
}

static void sessionEdgeScan() {
    if (g_explicitTaskAudio) {
        for (int k = 0; k < SESS_EDGE_SLOTS; k++) g_sessEdge[k].used = false;
        return;
    }
    if (!g_v5.valid) {                         // 断连/清空:全表清槽
        for (int k = 0; k < SESS_EDGE_SLOTS; k++) g_sessEdge[k].used = false;
        return;
    }
    bool claimed[SESS_EDGE_SLOTS] = {};        // 本轮已匹配的槽(同名会话去重)
    uint8_t n = g_v5.sessionCount;
    if (n > SESS_EDGE_SLOTS) n = SESS_EDGE_SLOTS;
    unsigned long now = millis();

    for (uint8_t i = 0; i < n; i++) {
        const SessionV5 &s = g_v5.sessions[i];
        uint32_t h = sessNameHash(s.name);
        int idx = -1, freeIdx = -1;
        for (int k = 0; k < SESS_EDGE_SLOTS; k++) {
            if (claimed[k]) continue;
            if (g_sessEdge[k].used) {
                if (idx < 0 && g_sessEdge[k].nameHash == h) idx = k;
            } else if (freeIdx < 0) {
                freeIdx = k;
            }
        }
        if (idx < 0) {                         // 新会话:登记状态,首帧不算边沿
            if (freeIdx < 0) continue;         // 理论不可达(槽数=会话上限 12)
            g_sessEdge[freeIdx] = { true, h, s.state, 0 };
            claimed[freeIdx] = true;
            continue;
        }
        claimed[idx] = true;
        SessEdgeSlot &sl = g_sessEdge[idx];
        uint8_t prev = sl.lastState;
        if (s.state == prev) continue;
        sl.lastState = s.state;
        Serial.printf("[bz] edge \"%s\" state %u->%u\n", s.name, prev, s.state);

        // running 集合 = {ACTIVE, THINKING}(SDS_THINKING=8,蓝呼吸"模型推理中"):
        // 1↔8 互转静音;进集合响开始,出集合到 completed/idle 响完成
        bool nowRun  = (s.state == SDS_ACTIVE || s.state == SDS_THINKING);
        bool prevRun = (prev    == SDS_ACTIVE || prev    == SDS_THINKING);
        if (nowRun && !prevRun) {              // 非 running → running
            if (sl.lastStartFxMs == 0 || now - sl.lastStartFxMs >= SESS_EDGE_START_COOLDOWN_MS) {
                sl.lastStartFxMs = now;
                buzzer_play(BZ_TASK_STARTED);
            } else {
                Serial.printf("[bz] TASK_STARTED cooldown, skip \"%s\"\n", s.name);
            }
        } else if (s.state == SDS_BLOCKED) {   // → error
            buzzer_play(BZ_TASK_ERROR);
        } else if (prevRun &&
                   (s.state == SDS_COMPLETED || s.state == SDS_READY)) {
            buzzer_play(BZ_TASK_COMPLETED);    // running → completed/idle
        }
        // SDS_NEEDS_REVIEW/SDS_PERMISSION/SDS_STALE/SDS_PAUSED:静音(见文件头规则)
    }
    // 会话从列表消失:清槽
    for (int k = 0; k < SESS_EDGE_SLOTS; k++)
        if (g_sessEdge[k].used && !claimed[k]) g_sessEdge[k].used = false;
}

// CMD_REQUEST_STATUS 30s 轮询 + 退避
#define STATUS_POLL_INTERVAL_MS  30000UL
#define STATUS_POLL_BACKOFF_MS   60000UL
#define STATUS_POLL_BACKOFF_THRESHOLD 3
static unsigned long lastStatusReqMs   = 0;
static int           statusFailCount   = 0;
static unsigned long currentPollIvlMs  = STATUS_POLL_INTERVAL_MS;

ADPCMState adpcmState;
uint16_t packetSeq = 0;
static AudioAgc audioAgc;

// Stage 5: 削波统计 (调音质 + 监控增益是否合理)
static volatile uint32_t clipCount    = 0;
static volatile uint32_t totalSamples = 0;

// Stage 5: 200ms 预录环形缓冲
static int16_t  preBuf[PREBUF_CHUNKS][PCM_CHUNK];
static volatile int  preBufWriteIdx = 0;
static volatile int  preBufCount    = 0;
static volatile bool preBufActive   = false;

// HP filter state (per-channel, 一阶高通去 DC)
typedef struct {
    float prev_in;
    float prev_out;
} HPState;
static HPState hp_main_state = {0, 0};
static HPState hp_ref_state  = {0, 0};

// NLMS 自适应滤波器状态 (ring buffer + weights + running power)
static float nlms_w[NLMS_TAPS] = {0};       // 滤波器权值
static float nlms_x[NLMS_TAPS] = {0};       // 参考信号历史 (环形)
static int   nlms_x_head = 0;               // 环形缓冲写指针
static float nlms_power  = 0.0f;            // ‖X‖² 滑动估计

// Audio queue
QueueHandle_t audioQueue;

// Display state (Stage 3a: 旧 4 文字状态枚举废除,Dashboard 是唯一主屏)
volatile int displayVolume = 0;   // audio task → display 音量峰值,Stage 3b PTT 动画用

// ── 2026-07 voice_ui 改版:录音页真实波形 + dBFS 电平(audio task 发布,渲染侧快照)──
// 跨核共享:db10 为 int16 单字放大 10 倍整数;波形逐字节写,10FPS 渲染下轻微撕裂可接受
volatile int16_t displayLevelDb10 = -600;      // -600 = -60.0 dBFS
volatile uint8_t displayWaveform[21] = {0};    // 21 段峰值 0..255
static unsigned long lastDashboardRenderMs = 0;
#define DASHBOARD_RENDER_INTERVAL_MS  100  // ≤ 10Hz,防 BLE 中断冲突

// Stage 3b: overlay 状态机(PTT 三阶段 / ASR 反馈)
UiOverlayCtx g_overlayCtx = {};
#define ASR_FEEDBACK_HOLD_MS  2000UL  // Success/Failure 显示 2s 后回 Dashboard

static void loadPersistedUiLocale() {
#if !defined(BOARD_MICSTICK_V12) && !defined(BOARD_MICSTICK_V14)
    // MicPad 不是本次多语言产品范围,保持升级前的简体中文默认体验。
    i18nSetLocale(UI_LOCALE_ZH_HANS);
    Serial.printf("[i18n] MicPad fixed locale=%u\n", (unsigned)i18nGetLocale());
    return;
#else
    Preferences prefs;
    uint8_t locale = UI_LOCALE_EN;
    if (prefs.begin("ui", true)) {
        locale = prefs.getUChar("lang", UI_LOCALE_EN);
        prefs.end();
    }
    if (!i18nSetLocale(locale)) i18nSetLocale(UI_LOCALE_EN);
    Serial.printf("[i18n] boot locale=%u\n", (unsigned)i18nGetLocale());
#endif
}

// NimBLE 回调只发布待应用值;NVS 写入和 UI 状态更新统一放在 loop 任务。
static void queueUiLocale(uint8_t locale) {
    if (locale >= UI_LOCALE_COUNT) return;
    g_pendingUiLocale.store(locale, std::memory_order_release);
}

static void applyPendingUiLocale() {
    uint8_t locale = g_pendingUiLocale.exchange(0xFF, std::memory_order_acq_rel);
    if (locale == 0xFF) return;
    if (locale >= UI_LOCALE_COUNT || locale == i18nGetLocale()) return;
    i18nSetLocale(locale);
    Preferences prefs;
    if (prefs.begin("ui", false)) {
        prefs.putUChar("lang", locale);
        prefs.end();
    }
    // 回显和超时提示是缓存文本;语言切换后清除/重建,防止同屏混用旧语言。
    g_modeCtx.editEcho[0] = '\0';
    if (g_overlayCtx.infoNote[0]) {
        snprintf(g_overlayCtx.infoNote, sizeof(g_overlayCtx.infoNote), "%s",
                 i18nText(UI_STR_RECORDING_TIMEOUT_STOPPED));
    }
    lastDashboardRenderMs = 0;
    Serial.printf("[i18n] locale changed=%u\n", (unsigned)locale);
}

// ── ADPCM Encoder ────────────────────────────────────────
uint8_t adpcm_encode_sample(int16_t sample, ADPCMState* state) {
    int diff = sample - state->prevSample;
    uint8_t code = 0;
    int step = stepTable[state->index];

    if (diff < 0) { code = 8; diff = -diff; }
    if (diff >= step) { code |= 4; diff -= step; }
    if (diff >= step >> 1) { code |= 2; diff -= step >> 1; }
    if (diff >= step >> 2) { code |= 1; }

    // Reconstruct
    int predicted = state->prevSample;
    int delta = (step >> 3);
    if (code & 4) delta += step;
    if (code & 2) delta += step >> 1;
    if (code & 1) delta += step >> 2;
    if (code & 8) predicted -= delta; else predicted += delta;

    if (predicted > 32767) predicted = 32767;
    if (predicted < -32768) predicted = -32768;
    state->prevSample = (int16_t)predicted;

    state->index += indexTable[code];
    if (state->index < 0) state->index = 0;
    if (state->index > 88) state->index = 88;

    return code & 0x0F;
}

void adpcm_encode(int16_t* pcm, uint8_t* adpcm, int numSamples, ADPCMState* state) {
    for (int i = 0; i < numSamples; i += 2) {
        uint8_t lo = adpcm_encode_sample(pcm[i], state);
        uint8_t hi = adpcm_encode_sample(pcm[i + 1], state);
        adpcm[i / 2] = lo | (hi << 4);
    }
}

// ── DSP Helpers ──────────────────────────────────────────

// 一阶高通滤波 (去 DC 漂移), 每通道独立状态
static inline float hp_filter_sample(float in, HPState* st) {
    float out = HP_FILTER_ALPHA * (st->prev_out + in - st->prev_in);
    st->prev_in  = in;
    st->prev_out = out;
    return out;
}

// NLMS 单样本处理: d=主麦, x=参考麦 (都已归一化到 [-1,1])
// 返回: 降噪后的干净输出 e = d - W^T·X
static inline float nlms_process_sample(float d, float x) {
    // 环形缓冲 + 滑动功率估计 (加入新样本, 移除最老样本)
    float oldest = nlms_x[nlms_x_head];
    nlms_power += x * x - oldest * oldest;
    if (nlms_power < 0.0f) nlms_power = 0.0f;   // 数值安全
    nlms_x[nlms_x_head] = x;
    nlms_x_head = (nlms_x_head + 1) % NLMS_TAPS;

    // 滤波器输出 y = Σ w[k] · x[n-k]
    float y = 0.0f;
    int idx = (nlms_x_head == 0) ? NLMS_TAPS - 1 : nlms_x_head - 1;  // 最新样本位置
    for (int k = 0; k < NLMS_TAPS; k++) {
        y += nlms_w[k] * nlms_x[idx];
        idx = (idx == 0) ? NLMS_TAPS - 1 : idx - 1;
    }

    float e = d - y;

    // 归一化权值更新: W += (μ / (‖X‖² + ε)) · X · e
    float mu_norm = NLMS_MU / (nlms_power + NLMS_EPS);
    idx = (nlms_x_head == 0) ? NLMS_TAPS - 1 : nlms_x_head - 1;
    for (int k = 0; k < NLMS_TAPS; k++) {
        nlms_w[k] += mu_norm * e * nlms_x[idx];
        // 安全钳位, 防止数值异常导致权值爆炸
        if (nlms_w[k] >  4.0f) nlms_w[k] =  4.0f;
        if (nlms_w[k] < -4.0f) nlms_w[k] = -4.0f;
        idx = (idx == 0) ? NLMS_TAPS - 1 : idx - 1;
    }

    return e;
}

static void nlms_reset(void) {
    for (int i = 0; i < NLMS_TAPS; i++) {
        nlms_w[i] = 0.0f;
        nlms_x[i] = 0.0f;
    }
    nlms_x_head = 0;
    nlms_power  = 0.0f;
}

static void hp_reset(void) {
    hp_main_state.prev_in = 0; hp_main_state.prev_out = 0;
    hp_ref_state.prev_in  = 0; hp_ref_state.prev_out  = 0;
}

// ── Audio DSP helper ────────────────────────────────────
// 单麦 HP+Gain 路径,preBuf 模式调用(不需要双麦/NLMS/RMS 统计,代码紧凑)
static inline void audioDspMonoChunk(const int16_t *pcmIn, int16_t *pcmOut, int samples) {
    for (int i = 0; i < samples; i++) {
        float d_hp = hp_filter_sample((float)pcmIn[i], &hp_main_state);
        if (d_hp >  32767.0f) d_hp =  32767.0f;
        if (d_hp < -32768.0f) d_hp = -32768.0f;
        pcmOut[i] = (int16_t)d_hp;
    }
    clipCount += audioAgcProcessChunk(&audioAgc, pcmOut, pcmOut, samples);
    totalSamples += samples;
}

// ── Audio Task (Core 1) ─────────────────────────────────
// 三分支:
//   isRecording: 进入边沿先 flush preBuf (按下前 200ms 抢说),然后正常 I2S → DSP → ADPCM → BLE
//   preBufActive(按下瞬间到 hold thresh 这 500ms): I2S → DSP → 写 preBuf 环形(不发包)
//   idle: vTaskDelay 20ms,reset 状态
static void installI2S();   // 前置声明:定义在 setup 前(睡眠唤醒重装用)
static wdt_hal_context_t g_rwdt;   // RWDT HAL 上下文(setup 配置,loop 喂)

void audioTask(void* param) {
    // INMP441 在 32-bit slot 高位对齐 24-bit 数据;先读 int32_t,再 >>14 落到 int16_t
    // 移位 14 = 抹掉最低 6 bit 噪声 + 给说话峰值留 ~4× crest 余量(主信号大致用满 int16)
    static int32_t i2sScratch[PCM_CHUNK * 2];  // DUAL_MIC 时是 stereo 帧;mono 时只用前半
    int16_t pcmMain[PCM_CHUNK];      // Mic1 主麦(对嘴), L 声道 — shift 后 int16
#if DUAL_MIC_ENABLED
    int16_t pcmRef [PCM_CHUNK];      // Mic2 参考麦(环境), R 声道
#endif
    int16_t pcmClean[PCM_CHUNK];     // 最终输出 (BLE 发送)
    uint32_t rmsPrintCounter = 0;

    AudioPacket packet;
    packet.header[0] = 0xAA;
    packet.header[1] = 0x55;
    packet.buttonId = 0x01;  // BtnA 是唯一 PTT 源,固定 0x01

    bool wasPrebuffering = false;    // 检测 isRecording 上升沿,用于 flush preBuf
    bool i2sStopped = false;         // 省电①:OFF 息屏态停 I2S 的状态标志

    while (true) {
        if (micstickOta.active()) {
            isRecording = false;
            preBufActive = false;
            wasPrebuffering = false;
            vTaskDelay(pdMS_TO_TICKS(1));
            continue;
        }

        // ── 省电①(2026-07-05,0.6.3 修正):OFF 息屏且不在录音 → 卸载 I2S 驱动 ──
        //   PDM CLK(2.048MHz)停输出,MSM261 无时钟自动进待机(~10µA),DMA 中断也停,
        //   合计省 ~5-8mA。100ms 轮询恢复,远早于 PTT 500ms 长按判定,不丢录音。
        //   ⚠ 0.6.2 教训:i2s_stop/i2s_start 对 legacy PDM RX 不可靠——start 后时钟
        //   起不来,i2s_read 永久阻塞,麦克风装死。必须 uninstall/install 完整重建。
        if (power_is_sleeping() && !isRecording) {
            if (!i2sStopped) {
                i2s_driver_uninstall(I2S_NUM_0);
                i2sStopped = true;
                Serial.println("[Audio] i2s uninstalled (sleep)");
            }
            vTaskDelay(pdMS_TO_TICKS(100));
            continue;
        }
        if (i2sStopped) {
            installI2S();
            i2sStopped = false;
            Serial.println("[Audio] i2s reinstalled (wake)");
        }

        if (isRecording && bleConnected && !micSourceIsSystem()) {   // T-033: 系统麦不编码不上传
            // === 进入录音边沿:flush preBuf 7 chunks (200ms) ===
            if (!wasPrebuffering && preBufCount > 0) {
                int startIdx = (preBufWriteIdx - preBufCount + PREBUF_CHUNKS) % PREBUF_CHUNKS;
                Serial.printf("[Audio] Flushing %d pre-buffer chunks\n", preBufCount);
                for (int i = 0; i < preBufCount; i++) {
                    int idx = (startIdx + i) % PREBUF_CHUNKS;
                    adpcm_encode(preBuf[idx], packet.adpcm, PCM_CHUNK, &adpcmState);
                    packet.seq = packetSeq++;
                    if (xQueueSend(audioQueue, &packet, pdMS_TO_TICKS(10)) != pdTRUE) {
                        Serial.println("[Audio] preBuf flush queue full");
                    }
                }
                preBufCount = 0;
            }
            wasPrebuffering = true;

            // === 正常录音 ===
            size_t bytesRead = 0;
#if DUAL_MIC_ENABLED
            i2s_read(I2S_NUM_0, i2sScratch, sizeof(i2sScratch), &bytesRead, pdMS_TO_TICKS(300));
            if (bytesRead == 0) continue;   // I2S 停转/超时:跳过本轮,绝不永久阻塞或发空包
            int samples = (bytesRead / 4) / 2;  // 32-bit, 双声道
            // 解交错 + 24-bit 高位 → int16
            for (int i = 0; i < samples; i++) {
                pcmMain[i] = (int16_t)(i2sScratch[2 * i]     >> 14);
                pcmRef[i]  = (int16_t)(i2sScratch[2 * i + 1] >> 14);
            }
#elif defined(MIC_PDM)
            // PDM RX 直接吐 16-bit PCM;交给 AGC 调整,避免 AGC 前先左移削波。
            i2s_read(I2S_NUM_0, i2sScratch, PCM_CHUNK * sizeof(int16_t), &bytesRead, pdMS_TO_TICKS(300));
            if (bytesRead == 0) continue;   // I2S 停转/超时:跳过本轮,绝不永久阻塞或发空包
            int samples = bytesRead / 2;  // 16-bit, 单声道
            {
                const int16_t* pdmPcm = (const int16_t*)i2sScratch;
                for (int i = 0; i < samples; i++) {
                    pcmMain[i] = pdmPcm[i];
                }
            }
#else
            i2s_read(I2S_NUM_0, i2sScratch, PCM_CHUNK * sizeof(int32_t), &bytesRead, pdMS_TO_TICKS(300));
            if (bytesRead == 0) continue;   // I2S 停转/超时:跳过本轮,绝不永久阻塞或发空包
            int samples = bytesRead / 4;  // 32-bit, 单声道
            for (int i = 0; i < samples; i++) {
                pcmMain[i] = (int16_t)(i2sScratch[i] >> 14);
            }
#endif
            if (bytesRead > 0) micstickOta.note_audio_health();

            // 逐样本 DSP 链: HP(去DC) → 归一化[-1,1] → [NLMS] → 反归一化 → AGC → int16
            uint64_t sumMain = 0, sumClean = 0;
#if DUAL_MIC_ENABLED
            uint64_t sumRef = 0;
#endif
            for (int i = 0; i < samples; i++) {
                sumMain += (int32_t)pcmMain[i] * pcmMain[i];
                float d_hp = hp_filter_sample((float)pcmMain[i], &hp_main_state);
                float d = d_hp * (1.0f / 32768.0f);

#if DUAL_MIC_ENABLED
                sumRef += (int32_t)pcmRef[i] * pcmRef[i];
                float x_hp = hp_filter_sample((float)pcmRef[i], &hp_ref_state);
                float x = x_hp * (1.0f / 32768.0f);
  #if NLMS_ENABLED
                float clean = nlms_process_sample(d, x);   // 降噪核心
  #else
                (void)x;                                    // ref 不参与, 避免 unused 警告
                float clean = d;                            // 旁路: 主麦 HP 后直通
  #endif
#else
                float clean = d;                            // 单麦: 仅主麦 HP 后直通
#endif

                float out = clean * 32768.0f;
                if (out >  32767.0f) out =  32767.0f;
                if (out < -32768.0f) out = -32768.0f;
                pcmClean[i] = (int16_t)out;

                sumClean += (int32_t)pcmClean[i] * pcmClean[i];
            }
            clipCount += audioAgcProcessChunk(&audioAgc, pcmClean, pcmClean, samples);
            sumClean = 0;
            for (int i = 0; i < samples; i++) {
                sumClean += (int32_t)pcmClean[i] * pcmClean[i];
            }

            totalSamples += samples;

            // 屏幕音量条用 clean 输出
            long sumAbs = 0;
            for (int i = 0; i < samples; i++) sumAbs += abs(pcmClean[i]);
            displayVolume = sumAbs / samples;

            // 录音页电平/波形发布(README_VOICE_UI §5.3/§5.5)
            {
                float rms  = sqrtf((float)sumClean / samples);
                float dbfs = 20.0f * log10f((rms + 1.0f) / 32768.0f);
                if (dbfs < -60.0f) dbfs = -60.0f;
                if (dbfs >   0.0f) dbfs =   0.0f;
                displayLevelDb10 = (int16_t)lroundf(dbfs * 10.0f);

                for (int bin = 0; bin < 21; bin++) {
                    int begin = bin * samples / 21;
                    int end   = (bin + 1) * samples / 21;
                    int peak  = 0;
                    for (int i = begin; i < end; i++) {
                        int v = abs((int)pcmClean[i]);
                        if (v > peak) peak = v;
                    }
                    // 开方响度曲线:线性映射下人声峰值(满幅 10~30%)柱高太矮、抖动不明显
                    // (用户 2026-07-25 反馈);sqrt 后 1%→10%、10%→32%、25%→50%
                    int p = (int)lroundf(sqrtf((float)peak / 32767.0f) * 255.0f);
                    displayWaveform[bin] = (uint8_t)(p > 255 ? 255 : p);
                }
            }

            // [DEBUG] 每 ~640ms 打印 RMS
            if (++rmsPrintCounter % 20 == 0) {
                float rmsMain  = sqrtf((float)sumMain  / samples);
                float rmsClean = sqrtf((float)sumClean / samples);
                float reduceDb = 20.0f * log10f((rmsMain + 1.0f) / (rmsClean + 1.0f));
                float clipPct = totalSamples > 0
                    ? 100.0f * (float)clipCount / (float)totalSamples : 0.0f;
#if DUAL_MIC_ENABLED
                float rmsRef = sqrtf((float)sumRef / samples);
                Serial.printf("[%s] main=%6.0f ref=%6.0f clean=%6.0f gain=%4.2f reduce=%+5.1f dB clip=%.2f%%\n",
                              NLMS_ENABLED ? "ANC-ON " : "ANC-OFF",
                              rmsMain, rmsRef, rmsClean, audioAgc.gain, reduceDb, clipPct);
#else
                Serial.printf("[MONO ] main=%6.0f clean=%6.0f gain=%4.2f reduce=%+5.1f dB clip=%.2f%%\n",
                              rmsMain, rmsClean, audioAgc.gain, reduceDb, clipPct);
#endif
                // 周期重置,避免长时间录音后统计失真
                clipCount = 0;
                totalSamples = 0;
            }

            adpcm_encode(pcmClean, packet.adpcm, samples, &adpcmState);
            packet.seq = packetSeq++;

            if (xQueueSend(audioQueue, &packet, 0) == pdTRUE) {
                if (packet.seq < 3) {
                    Serial.printf("Audio seq=%d vol=%d clean[0..3]=%d,%d,%d,%d adpcm[0..3]=%02X,%02X,%02X,%02X\n",
                        packet.seq, displayVolume,
                        pcmClean[0], pcmClean[1], pcmClean[2], pcmClean[3],
                        packet.adpcm[0], packet.adpcm[1], packet.adpcm[2], packet.adpcm[3]);
                }
            } else {
                Serial.println("Audio queue FULL!");
            }
        } else if (preBufActive && bleConnected && !micSourceIsSystem()) {   // T-033: 系统麦不预滚
            // === 预录模式:I2S → 单麦 DSP → 写 preBuf 环形 (不发包) ===
            // 这段在 BtnA 按下到 hold thresh 之间 (500ms) + 用户按下前持续记录 (空闲时不录)
            // 不走双麦 / NLMS:NLMS 收敛要时间,200ms 内反而劣化
            size_t bytesRead = 0;
#if DUAL_MIC_ENABLED
            i2s_read(I2S_NUM_0, i2sScratch, sizeof(i2sScratch), &bytesRead, pdMS_TO_TICKS(300));
            if (bytesRead == 0) continue;   // I2S 停转/超时:跳过本轮,绝不永久阻塞或发空包
            int samples = (bytesRead / 4) / 2;
            for (int i = 0; i < samples; i++) {
                pcmMain[i] = (int16_t)(i2sScratch[2 * i] >> 14);
            }
#elif defined(MIC_PDM)
            i2s_read(I2S_NUM_0, i2sScratch, PCM_CHUNK * sizeof(int16_t), &bytesRead, pdMS_TO_TICKS(300));
            if (bytesRead == 0) continue;   // I2S 停转/超时:跳过本轮,绝不永久阻塞或发空包
            int samples = bytesRead / 2;
            {
                const int16_t* pdmPcm = (const int16_t*)i2sScratch;
                for (int i = 0; i < samples; i++) {
                    pcmMain[i] = pdmPcm[i];
                }
            }
#else
            i2s_read(I2S_NUM_0, i2sScratch, PCM_CHUNK * sizeof(int32_t), &bytesRead, pdMS_TO_TICKS(300));
            if (bytesRead == 0) continue;   // I2S 停转/超时:跳过本轮,绝不永久阻塞或发空包
            int samples = bytesRead / 4;
            for (int i = 0; i < samples; i++) {
                pcmMain[i] = (int16_t)(i2sScratch[i] >> 14);
            }
#endif
            if (bytesRead > 0) micstickOta.note_audio_health();
            audioDspMonoChunk(pcmMain, pcmClean, samples);

            // 只接受完整 chunk;短读时(I2S 异常/唤醒首帧)pcmClean 尾段是栈脏数据,
            // 写进环形会在下一次 PTT flush 时把噪声混进 200ms 预录,拉低 RMS
            if (samples == PCM_CHUNK) {
                memcpy(preBuf[preBufWriteIdx], pcmClean, PCM_CHUNK * sizeof(int16_t));
                preBufWriteIdx = (preBufWriteIdx + 1) % PREBUF_CHUNKS;
                if (preBufCount < PREBUF_CHUNKS) preBufCount++;
            }
        } else {
            // === Idle ===
            wasPrebuffering = false;
            preBufCount = 0;
            // 空闲时持续抽干 I2S DMA 并丢弃(像 mic_lcd 连续读那样),避免 DMA 环溢出 →
            // PTT 首段采集错位/低电平。blocking 读自然按 I2S 速率节流(~32ms/chunk)。
            size_t dump = 0;
#ifdef MIC_PDM
            i2s_read(I2S_NUM_0, i2sScratch, PCM_CHUNK * sizeof(int16_t), &dump, pdMS_TO_TICKS(300));
#else
            i2s_read(I2S_NUM_0, i2sScratch, PCM_CHUNK * sizeof(int32_t), &dump, pdMS_TO_TICKS(300));
#endif
            if (dump > 0) micstickOta.note_audio_health();
        }
    }
}

// ── BLE TX Task (Core 0) ────────────────────────────────
void bleTxTask(void* param) {
    AudioPacket packet;

    while (true) {
        if (micstickOta.active()) {
            while (xQueueReceive(audioQueue, &packet, 0) == pdTRUE) {}
            vTaskDelay(pdMS_TO_TICKS(1));
            continue;
        }
        if (xQueueReceive(audioQueue, &packet, pdMS_TO_TICKS(100))) {
            if (micstickOta.active() || !bleConnected || !pAudioDataChar) continue;

            uint8_t* data = (uint8_t*)&packet;
            size_t packetSize = sizeof(AudioPacket);
            size_t maxPayload = currentMTU - 3;

            if (packet.seq < 3) Serial.printf("BLE TX seq=%d size=%d mtu=%d\n", packet.seq, packetSize, currentMTU);

            if (packetSize <= maxPayload) {
                pAudioDataChar->setValue(data, packetSize);
                pAudioDataChar->notify();
            } else {
                // Split into chunks
                size_t offset = 0;
                while (offset < packetSize) {
                    size_t chunk = packetSize - offset;
                    if (chunk > maxPayload) chunk = maxPayload;
                    pAudioDataChar->setValue(data + offset, chunk);
                    pAudioDataChar->notify();
                    offset += chunk;
                    vTaskDelay(pdMS_TO_TICKS(1));
                }
            }
        }
    }
}

// ── BLE Callbacks ────────────────────────────────────────
static const char* bleDisconnectReasonName(int reason) {
    switch (reason & 0xFF) {
        case 0x08: return "connection timeout";
        case 0x13: return "remote user terminated";
        case 0x16: return "local host terminated";
        case 0x22: return "LMP response timeout";
        case 0x3E: return "connection failed to establish";
        default:   return "unknown";
    }
}

class ServerCallbacks : public NimBLEServerCallbacks {
    void onConnect(NimBLEServer* pServer, NimBLEConnInfo& connInfo) override {
        bleConnected = true;
        g_taskLifecycleResetPending.store(true, std::memory_order_release);
        s_bleConnHandle = connInfo.getConnHandle();
        // 默认快连接(15-18ms),进 OFF 时由主 loop 切到 100ms
        pServer->updateConnParams(s_bleConnHandle, 12, 15, 0, 400);
        // REQ-003 Phase 2.2: Mac 主动连接当作 user activity,把设备从 light sleep 唤回 ACTIVE
        // 这样 GATT discovery 期间 conn 维持 15ms,不会撞长 conn 兼容问题
        power_note_ble_connection(true);
        Serial.println("BLE connected");
        Serial.printf("[ble] connect handle=%u mtu=%u\n",
                      (unsigned)s_bleConnHandle, (unsigned)currentMTU);
    }

    void onDisconnect(NimBLEServer* pServer, NimBLEConnInfo& connInfo, int reason) override {
        uint16_t oldMTU = currentMTU;
        bleConnected = false;
        g_taskLifecycleResetPending.store(true, std::memory_order_release);
        power_note_ble_connection(false);
        s_bleConnHandle = 0xFFFF;
        currentMTU = 23;
        isRecording = false;
        g_actionModeExitOnDisconnect.store(true, std::memory_order_release);
        if (!g_mockHold) g_v5.valid = false;   // 断开回 splash(mock 验证期间保留)
        if (!g_mockHold) g_listSel.inactiveExpanded = false;   // T-034: 重连回到默认折叠
        g_haveTime = false;   // 重连后未收时间帧前显示 --:--
        // Stage 2: 断开时复位轮询计数,避免重连后立刻进 60s 退避
        statusFailCount  = 0;
        currentPollIvlMs = STATUS_POLL_INTERVAL_MS;
        lastStatusReqMs  = 0;
        NimBLEDevice::startAdvertising();
        NimBLEAdvertising* adv = NimBLEDevice::getAdvertising();
        Serial.println("BLE disconnected, re-advertising");
        Serial.printf("[ble] disconnect reason=%d hci=0x%02X(%s) oldMtu=%u adv=%u cpu=%dMHz heap=%u\n",
                      reason, reason & 0xFF, bleDisconnectReasonName(reason),
                      (unsigned)oldMTU,
                      adv && adv->isAdvertising() ? 1 : 0,
                      getCpuFrequencyMhz(),
                      (unsigned)ESP.getFreeHeap());
    }

    void onMTUChange(uint16_t MTU, NimBLEConnInfo& connInfo) override {
        currentMTU = MTU;
        Serial.printf("MTU changed to %d\n", MTU);
    }
};

class MicStickOTAControlCallbacks : public NimBLECharacteristicCallbacks {
public:
    explicit MicStickOTAControlCallbacks(micstick_ota::MicStickOTASession& session)
        : session_(session) {}

    void onWrite(NimBLECharacteristic* pChar, NimBLEConnInfo& connInfo) override {
        if (!connInfo.isEncrypted()) return;
        std::string value = pChar->getValue();
        session_.on_control(reinterpret_cast<const uint8_t*>(value.data()), value.size());
    }

private:
    micstick_ota::MicStickOTASession& session_;
};

class MicStickOTADataCallbacks : public NimBLECharacteristicCallbacks {
public:
    explicit MicStickOTADataCallbacks(micstick_ota::MicStickOTASession& session)
        : session_(session) {}

    void onWrite(NimBLECharacteristic* pChar, NimBLEConnInfo& connInfo) override {
        if (!connInfo.isEncrypted()) return;
        std::string value = pChar->getValue();
        session_.on_data(reinterpret_cast<const uint8_t*>(value.data()), value.size());
    }

private:
    micstick_ota::MicStickOTASession& session_;
};

class ControlCallbacks : public NimBLECharacteristicCallbacks {
    void onWrite(NimBLECharacteristic* pChar, NimBLEConnInfo& connInfo) override {
        if (micstickOta.active()) return;
        std::string val = pChar->getValue();
        if (val.empty()) return;

        uint8_t cmd = val[0];
        switch (cmd) {
            case CMD_HANDSHAKE: {
                uint8_t reply[2] = { CMD_HANDSHAKE, PROTOCOL_VERSION };
                pAudioControlChar->setValue(reply, 2);
                pAudioControlChar->notify();
                Serial.println("Handshake OK");
                break;
            }
            case CMD_VOICE_RECOGNIZING:
                Serial.println("Mac: recognizing...");
                break;
            case CMD_VOICE_DONE:
                Serial.println("Mac: voice done");
                break;
            case CMD_VOICE_ERROR:
                Serial.println("Mac: voice error");
                break;
            case CMD_BUZZER_VOLUME:   // REQ-022 音效批次:[0x37, pct],其他未知值钳制到最近 20% 档
                if (val.size() >= 2) {
                    buzzer_set_volume((uint8_t)val[1]);
                } else {
                    Serial.println("[bz] 0x37 malformed (no pct byte)");
                }
                break;
            case CMD_BUZZER_PREVIEW:
                if (val.size() >= 2) {
                    buzzer_set_volume((uint8_t)val[1]);
                    buzzer_preview_volume();
                } else {
                    Serial.println("[bz] 0x39 malformed (no pct byte)");
                }
                break;
            case CMD_LED_BRIGHTNESS:
                if (val.size() >= 2) {
                    led_set_brightness_percent((uint8_t)val[1]);
                } else {
                    Serial.println("[LED] 0x38 malformed (no pct byte)");
                }
                break;
            case CMD_DEVICE_PREFS_GET: {
                // Optional fourth/fifth bytes are backward compatible: old
                // Hosts read the first three; new Hosts use PCB revision and
                // the generic dynamic-scene capability bit.
                uint8_t reply[6] = {
                    CMD_DEVICE_PREFS,
                    buzzer_get_volume(),
                    led_get_brightness_percent(),
                    HARDWARE_REVISION,
                    0x3F,  // + bit5: extended Agent cards and metric metadata
                    V5_MAX_AGENTS
                };
                pAudioControlChar->setValue(reply, sizeof(reply));
                pAudioControlChar->notify();
                Serial.printf("[prefs] report buzzer=%u%% led=%u%% hw=v%u caps=0x%02X agents=%u\n",
                              reply[1], reply[2], reply[3], reply[4], reply[5]);
                break;
            }
            case CMD_SHIP_MODE_REQUEST:
#if HARDWARE_REVISION >= 14 && defined(BOARD_MICSTICK_V14)
                g_pendingShipModeRequest.store(true, std::memory_order_release);
                Serial.println("[ship] host requested confirmation page");
#else
                Serial.println("[ship] ignored: unsupported hardware revision");
#endif
                break;
            case VOICE_NOTIFY_SUCCESS:
            case VOICE_NOTIFY_FAILURE: {
                AsrFeedbackState fb;
                if (parseVoiceNotify(cmd, (const uint8_t*)val.data(), val.size(), fb)) {
                    // REQ-003 Phase 1a (2026-05-03): BLE 推送不再刷 activity 计时器。
                    // VOICE_NOTIFY 是用户 PTT 后的回执,用户已经在 PTT 期间刷过 activity,
                    // ASR 反馈本身不该再延 sleep 计时(Mac App 反复推送会让设备永不睡)。
                    fb.expiresAt = millis() + 500;  // 0.5s 显示窗口(对齐 Stick S3)
                    g_asrFeedback = fb;
                    if (fb.isFailure) {
                        Serial.printf("ASR Failure: btn=%d msg=\"%s\"\n",
                                      fb.buttonId, fb.message);
                        // Stage 3b: 切 ASR_FAILURE overlay,2s 自动回 Dashboard
                        strncpy(g_overlayCtx.asrFailMsg, fb.message,
                                sizeof(g_overlayCtx.asrFailMsg) - 1);
                        g_overlayCtx.asrFailMsg[sizeof(g_overlayCtx.asrFailMsg) - 1] = 0;
                        g_overlayCtx.asrFailExpireMs = millis() + ASR_FEEDBACK_HOLD_MS;
                        ui_set_overlay(g_overlayCtx, UI_OV_ASR_FAILURE);
                        led_fire_event(LED_EV_ASR_FAILURE);
                    } else {
                        Serial.printf("ASR Success: btn=%d\n", fb.buttonId);
                        // Stage 3b: 切 ASR_SUCCESS overlay,2s 自动回 Dashboard
                        g_overlayCtx.asrFailExpireMs = millis() + ASR_FEEDBACK_HOLD_MS;
                        ui_set_overlay(g_overlayCtx, UI_OV_ASR_SUCCESS);
                        led_fire_event(LED_EV_ASR_SUCCESS);
                    }
                } else {
                    Serial.printf("ASR notify malformed (cmd=0x%02X len=%u)\n",
                                  cmd, (unsigned)val.size());
                }
                break;
            }
        }
    }
};

// ══════════════════════════════════════════════════════════
// REQ-022: 审批协议接线(0x55/0x56 → static ApprovalQueue;0x36 ← control char)
//   帧编解码与状态机全部由 approval_protocol.h 承担,这里只做 IO/事件映射。
// ══════════════════════════════════════════════════════════
static void sendBleCmdN(const uint8_t *data, size_t len);   // 前置声明(定义在下方)
static void setUiMode(DeviceUiMode m);
static void cancelPendingTaps();
static void enterEditMode();     // MODE 串口命令用(REQ-023 布局验证)
static void exitEditMode();
static void enterPromptMode();
static void exitPromptMode();

// ── onWrite(nimble_host 任务)侧入口:只看首字节判别,不触碰 ApprovalQueue ──
// 返回 true = 0x55/0x56 已消费(投队列或队满丢弃),调用方不得再落 v5/v4/JSON 路径;
// false = 非审批帧,交回原路径。decode 校验一律延后到 loop 侧 handleApprovalFrame。
static bool apvEnqueueRx(const uint8_t *data, size_t len) {
    if (data == nullptr || len < 1) return false;
    if (data[0] != kApprovalMagicRequest && data[0] != kApprovalMagicResolved) return false;
    if (g_apvRxQueue == nullptr) {                 // 创建失败兜底:禁止直调(会引入竞态),只能丢弃
        Serial.println("[apv] rx queue unavailable, frame dropped");
        return true;
    }
    if (len > sizeof(((ApprovalRxMsg *)0)->bytes)) {
        // 超过 0x55 最大帧长(357B):decode 必败,不占队列槽位直接丢
        Serial.printf("[apv] rx frame oversize (len=%u), dropped\n", (unsigned)len);
        return true;
    }
    ApprovalRxMsg msg;
    msg.len = (uint16_t)len;
    memcpy(msg.bytes, data, len);
    if (xQueueSend(g_apvRxQueue, &msg, 0) != pdTRUE) {
        g_apvRxDropCount++;
        Serial.printf("[apv] rx queue full, frame dropped (drops=%lu)\n",
                      (unsigned long)g_apvRxDropCount);
    }
    return true;
}

static bool taskLifecycleEnqueueRx(const uint8_t *data, size_t len) {
    if (!data || len < 1 || data[0] != V5_FRAME_TASK_LIFECYCLE) return false;
    if (!g_taskLifecycleRxQueue || len > TASK_LIFECYCLE_EVENT_FRAME_LEN) {
        Serial.println("[task-life] rx unavailable/oversize, dropped");
        return true;
    }
    TaskLifecycleRxMsg msg{};
    msg.len = (uint8_t)len;
    memcpy(msg.bytes, data, len);
    if (xQueueSend(g_taskLifecycleRxQueue, &msg, 0) != pdTRUE) {
        Serial.println("[task-life] rx queue full, dropped");
    }
    return true;
}

// 0x36 发送(经现有 control characteristic notify)+ 留存 APVTX 调试记录
static void apvSend36(const ApprovalSend &s) {
    if (s.len == 0) return;
    memcpy(g_apvLastTx, s.bytes, s.len);
    g_apvLastTxLen = s.len;
    sendBleCmdN(s.bytes, s.len);
    Serial.printf("[apv] tx 0x36 reqId=%u decision=%u\n",
                  (unsigned)(s.bytes[1] | ((uint16_t)s.bytes[2] << 8)), s.bytes[3]);
}

// 队列事件 → buzzer/LED 映射(REQ-022 音效批次)
// detail:ARRIVED = 0x55 帧 flags(bit1 notifyOnly → INPUT_REQUIRED,去重规则:
//        waitingForInput 的 phase 边沿不响,INPUT_REQUIRED 只由 notifyOnly 审批帧触发);
//        COMPLETED = 0x56 rawOutcome(0=allow→ACCEPTED,1=deny→REJECTED);其余事件忽略。
static void apvFireEvent(ApprovalEvent ev, uint16_t reqId, uint8_t detail = 0) {
    switch (ev) {
        case ApprovalEvent::ARRIVED:
            buzzer_play((detail & kApprovalFlagNotifyOnly) ? BZ_INPUT_REQUIRED
                                                           : BZ_APPROVAL_REQUIRED);
            led_fire_event(LED_EV_PERM_PENDING);   // 紫色心跳(复用现有 LED 事件)
            Serial.printf("[apv] ARRIVED reqId=%u notifyOnly=%u\n",
                          reqId, (detail & kApprovalFlagNotifyOnly) ? 1 : 0);
            break;
        case ApprovalEvent::COMPLETED:
            // outcome=0 判决采纳为 allow,outcome=1 为 deny(COMPLETED 仅这两值)
            buzzer_play(detail == kApprovalOutcomeJudgedAllow ? BZ_APPROVAL_ACCEPTED
                                                              : BZ_APPROVAL_REJECTED);
            Serial.printf("[apv] COMPLETED reqId=%u outcome=%u\n", reqId, detail);
            break;
        case ApprovalEvent::RESOLVED_ELSEWHERE:
            buzzer_play(BZ_APPROVAL_TAKEN);
            Serial.printf("[apv] RESOLVED_ELSEWHERE reqId=%u\n", reqId);
            break;
        case ApprovalEvent::EXPIRED:
            buzzer_play(BZ_APPROVAL_EXPIRED);
            Serial.printf("[apv] EXPIRED reqId=%u\n", reqId);
            break;
        case ApprovalEvent::SEND_FAILED:
            // 用户拍板:复用任务错误音(高低重复 = 需立即注意)
            buzzer_play(BZ_TASK_ERROR);
            Serial.printf("[apv] SEND_FAILED reqId=%u (条目保留,等 0x56/过期兜底)\n", reqId);
            break;
        default:
            break;
    }
}

// B2 进入条件:NORMAL 且无 overlay 且不在录音(EDIT/PROMPT/录音中不打断)
static bool apvCanEnterNow() {
    return g_uiMode == DEV_MODE_NORMAL &&
           g_overlayCtx.state == UI_OV_NONE &&
           !isRecording;
}

// 进出模态必调 cancelPendingTaps():残留的单击迟滞窗不得漏到新模态误触发
static void enterApprovalMode() {
    cancelPendingTaps();
    // 审批是 Mac 端推送，不是设备上的真实用户活动。可以唤屏，但不能让
    // 后台通知或重推无限延长电池供电下的 30 分钟 L3 截止时间。
    power_note_system_activity();
    g_approvalView.pressFeedbackMs = 0;
    setUiMode(DEV_MODE_APPROVAL);
}

static void exitApprovalMode() {
    cancelPendingTaps();
    setUiMode(DEV_MODE_NORMAL);
}

// 0x55/0x56 统一入口(BLE 两条 characteristic + 串口 APV 注入共用)。
// 返回 true = magic 命中审批帧已消费(含 decode error 整帧丢弃);false = 交回原路径。
static bool handleApprovalFrame(const uint8_t *data, size_t len) {
    if (data == nullptr || len < 1) return false;

    if (data[0] == kApprovalMagicRequest) {          // 0x55 APPROVAL_REQUEST
        ApprovalRequestFrame f;
        if (!approvalDecodeRequest(data, len, &f)) {
            Serial.printf("[apv] 0x55 decode FAIL (len=%u), dropped\n", (unsigned)len);
            return true;
        }
        ApprovalPushResult r = g_approvalQueue.push(f, millis());
        if (r.evicted) {
            // §3.1.3:满队列淘汰只记日志,不发帧、不出事件(Mac 幂等层兜迟到判决)
            Serial.printf("[apv] queue full, evicted reqId=%u\n", r.evictedReqId);
        }
        if (r.event == ApprovalEvent::ARRIVED) {
            apvFireEvent(ApprovalEvent::ARRIVED, f.reqId, f.flags);
            if (apvCanEnterNow()) {
                enterApprovalMode();
            } else if (g_uiMode != DEV_MODE_APPROVAL) {
                // EDIT/PROMPT/录音中:入队 + 紫 LED(已在 ARRIVED 事件里触发),退出后 loop 自动进入
                Serial.println("[apv] busy (edit/prompt/recording), queued for later entry");
            }
        } else if (r.event == ApprovalEvent::UPDATED) {
            Serial.printf("[apv] UPDATED reqId=%u\n", f.reqId);
        } else if (r.event == ApprovalEvent::IGNORED) {
            Serial.printf("[apv] update IGNORED (awaiting ack) reqId=%u\n", f.reqId);
        }
        return true;
    }

    if (data[0] == kApprovalMagicResolved) {         // 0x56 APPROVAL_RESOLVED
        uint16_t reqId;
        uint8_t rawOutcome, treatAs;
        if (!approvalDecodeResolved(data, len, &reqId, &rawOutcome, &treatAs)) {
            Serial.printf("[apv] 0x56 decode FAIL (len=%u), dropped\n", (unsigned)len);
            return true;
        }
        ApprovalResolveResult r = g_approvalQueue.onResolved(reqId, rawOutcome);
        if (!r.found) {
            Serial.printf("[apv] 0x56 unknown reqId=%u, ignored (§2.5)\n", reqId);
            return true;
        }
        Serial.printf("[apv] resolved reqId=%u outcome=%u(treat=%u)\n", reqId, rawOutcome, treatAs);
        apvFireEvent(r.event, reqId, rawOutcome);
        if (g_approvalQueue.empty() && g_uiMode == DEV_MODE_APPROVAL) exitApprovalMode();
        return true;
    }

    return false;
}

// loop() 每帧顶部调:把 nimble_host 投进来的原始帧取出,在 loop 任务里消费。
// timeout=0 非阻塞;一帧最多清空整个队列(深度 8),不会长时间占 loop。
static void apvDrainRx() {
    if (g_apvRxQueue == nullptr) return;
    ApprovalRxMsg msg;
    while (xQueueReceive(g_apvRxQueue, &msg, 0) == pdTRUE) {
        handleApprovalFrame(msg.bytes, msg.len);
    }
}

static void taskAudioEnqueue(BuzzerFx fx) {
    if (g_taskAudioCount >= TASK_AUDIO_QUEUE_CAP) {
        Serial.println("[task-life] audio queue full, dropped");
        return;
    }
    uint8_t tail = (uint8_t)((g_taskAudioHead + g_taskAudioCount) % TASK_AUDIO_QUEUE_CAP);
    g_taskAudioQueue[tail] = fx;
    ++g_taskAudioCount;
}

static void taskLifecycleDrainRx() {
    if (g_taskLifecycleResetPending.exchange(false, std::memory_order_acq_rel)) {
        g_explicitTaskAudio = false;
        g_taskLifecycleDeduper.clear();
        g_taskAudioHead = g_taskAudioCount = 0;
        if (!bleConnected && g_taskLifecycleRxQueue) xQueueReset(g_taskLifecycleRxQueue);
    }
    if (!g_taskLifecycleRxQueue) return;
    TaskLifecycleRxMsg msg;
    while (xQueueReceive(g_taskLifecycleRxQueue, &msg, 0) == pdTRUE) {
        TaskLifecycleFrame frame{};
        if (!taskLifecycleDecode(msg.bytes, msg.len, &frame)) {
            Serial.printf("[task-life] decode FAIL len=%u\n", msg.len);
            continue;
        }
        if (frame.kind == TASK_LIFECYCLE_ENABLE) {
            g_explicitTaskAudio = true;
            g_taskLifecycleDeduper.clear();
            Serial.println("[task-life] explicit Prompt lifecycle enabled");
            continue;
        }
        if (!g_explicitTaskAudio) {
            Serial.println("[task-life] event ignored before enable");
            continue;
        }
        if (!g_taskLifecycleDeduper.insertIfNew(frame.eventId)) {
            Serial.println("[task-life] duplicate event ignored");
            continue;
        }
        BuzzerFx fx = frame.kind == TASK_LIFECYCLE_STARTED ? BZ_TASK_STARTED
                    : frame.kind == TASK_LIFECYCLE_FAILED ? BZ_TASK_ERROR
                    : BZ_TASK_COMPLETED;
        taskAudioEnqueue(fx);
        Serial.printf("[task-life] queued kind=%u\n", (unsigned)frame.kind);
    }
}

static void taskLifecycleAudioTick() {
    if (g_taskAudioCount == 0 || buzzer_is_busy()) return;
    BuzzerFx fx = g_taskAudioQueue[g_taskAudioHead];
    g_taskAudioHead = (uint8_t)((g_taskAudioHead + 1) % TASK_AUDIO_QUEUE_CAP);
    --g_taskAudioCount;
    buzzer_play(fx);
}

// 当前条目判决(合法性完全由 ApprovalQueue.decide 判定;UI 只负责灰显)
static void apvDecide(uint8_t decision) {
    const ApprovalEntry *e = g_approvalQueue.current();
    if (e == nullptr) return;
    uint16_t reqId = e->req.reqId;
    ApprovalDecideResult r = g_approvalQueue.decide(reqId, decision, millis());
    if (!r.accepted) {
        Serial.printf("[apv] decide rejected reqId=%u decision=%u (state/notifyOnly/risk/bit2)\n",
                      reqId, decision);
        return;
    }
    if (r.hasSend) apvSend36(r.send);
    Serial.printf("[apv] decide reqId=%u decision=%u removed=%u\n", reqId, decision, r.removed ? 1 : 0);
    if (g_approvalQueue.empty() && g_uiMode == DEV_MODE_APPROVAL) exitApprovalMode();
}

// 同步失败后的“关闭”只移除本机卡片，不再发送第二个 decision：此前的 allow/deny
// 可能已到 Mac 但 0x56 回执丢失，补发 dismiss 会制造相互矛盾的语义。
static void apvDismissOrClose() {
    const ApprovalEntry *e = g_approvalQueue.current();
    if (e == nullptr) return;
    uint16_t reqId = e->req.reqId;
    if (e->state == ApprovalEntryState::SEND_FAILED) {
        if (g_approvalQueue.closeFailedLocally(reqId)) {
            Serial.printf("[apv] local close after send failure reqId=%u\n", reqId);
            if (g_approvalQueue.empty() && g_uiMode == DEV_MODE_APPROVAL) exitApprovalMode();
        }
        return;
    }
    apvDecide(kApprovalDecisionDismiss);
}

// ── Stage 2: ClaudeStatus characteristic callback (Mac → Device write) ──
class ClaudeStatusCallback : public NimBLECharacteristicCallbacks {
    void onWrite(NimBLECharacteristic* pChar, NimBLEConnInfo& connInfo) override {
        if (micstickOta.active()) return;
        NimBLEAttValue val = pChar->getValue();
        const uint8_t* data = val.data();
        size_t len = val.length();

        // ── REQ-022 审批帧路由(0x55/0x56;与 v4 phase≤5/0xFF、v5 0x51..0x54 无碰撞)──
        // 本回调在 nimble_host 任务:只判别+投队列,ApprovalQueue 读写收敛到 loop 任务
        if (apvEnqueueRx(data, len)) return;
        if (taskLifecycleEnqueueRx(data, len)) return;

        // ── v5 帧路由(0x51..0x53;v4 首字节 phase≤5/0xFF 无碰撞)──
        if (v5IsFrame(data, len)) {
            bool ok = false;
            switch (data[0]) {
                case V5_FRAME_SESSIONS:
                    if (!g_mockHold) ok = v5ParseSessions(data, len, g_v5);
                    else             ok = true;   // mock 期间丢弃但不算错
                    if (ok && !g_mockHold) {
                        Serial.printf("[v5] sessions=%u exclusive=%d inactiveStart=%d\n",
                                      g_v5.sessionCount, (int)g_v5.exclusiveIdx,
                                      (int)g_v5.inactiveStart);
                    }
                    break;
                case V5_FRAME_AGENT_INFO:
                    if (!g_mockHold) ok = v5ParseAgentInfo(data, len, g_v5);
                    else             ok = true;
                    if (ok && !g_mockHold) {
                        Serial.printf("[v5] agents=%u", g_v5.agentCount);
                        for (uint8_t i = 0; i < g_v5.agentCount; i++) {
                            Serial.printf(" [%u:5h=%u%% 7d=%u%% R=%u S=%u/%u]",
                                          g_v5.agents[i].agentId,
                                          g_v5.agents[i].usage5hPct, g_v5.agents[i].usage7dPct,
                                          g_v5.agents[i].resetInHours,
                                          g_v5.agents[i].activeCount, g_v5.agents[i].totalCount);
                        }
                        Serial.println();
                    }
                    break;
                case V5_FRAME_CONFIG:
                    ok = v5ParseConfig(data, len, g_v5cfg);
                    if (ok) {
                        if (g_v5cfg.hasLanguage) queueUiLocale(g_v5cfg.language);
                        if ((!promptRecommendationsEnabled() && g_uiMode == DEV_MODE_PROMPT) ||
                            (!inputAssistantEnabled() && g_uiMode == DEV_MODE_INPUT_ASSISTANT)) {
                            g_laboratoryModeExitPending.store(true, std::memory_order_release);
                        }
                        if (g_v5cfg.hasLanguage) {
                            Serial.printf("[v5] config voiceMode=%u prompts=%u micSource=%u language=%u laboratory=0x%02X\n",
                                          g_v5cfg.voiceMode, g_v5cfg.promptCount,
                                          g_v5cfg.micSource, g_v5cfg.language,
                                          g_v5cfg.laboratoryFeatures);
                        } else {
                            Serial.printf("[v5] config voiceMode=%u prompts=%u micSource=%u language=keep laboratory=0x%02X\n",
                                          g_v5cfg.voiceMode, g_v5cfg.promptCount,
                                          g_v5cfg.micSource, g_v5cfg.laboratoryFeatures);
                        }
                    }
                    break;
                case V5_FRAME_TIME: {
                    uint16_t mod;
                    ok = v5ParseTime(data, len, &mod);
                    if (ok) {
                        g_timeBaseMin = mod;
                        g_timeBaseMs  = millis();
                        g_haveTime    = true;
                        Serial.printf("[v5] time sync %02u:%02u\n", mod / 60, mod % 60);
                    }
                    break;
                }
                case V5_FRAME_ACTION_MODE:
                    ok = parseActionModeDefinition(data, len, g_modeCtx.actionMode);
                    if (ok) {
                        cancelPendingTaps();
                        if (g_modeCtx.actionMode.valid) {
                            setUiMode(DEV_MODE_ACTION);
                            Serial.printf("[mode] action id=%u title=%s\n",
                                          g_modeCtx.actionMode.modeId,
                                          g_modeCtx.actionMode.title);
                        } else {
                            setUiMode(DEV_MODE_NORMAL);
                            Serial.println("[mode] action exit from Host");
                        }
                    }
                    break;
                case V5_FRAME_PROMPT_RECOMMENDATIONS:
                    ok = (g_uiMode == DEV_MODE_PROMPT) &&
                         v5ParsePromptRecommendations(data, len, g_modeCtx.promptRequestId, g_modeCtx);
                    if (ok) {
                        g_promptHostAcked = true;
                        g_promptSel = 0;
                        g_modeCtx.promptSel = 0;
                        g_promptTouchMs = millis();
                        Serial.printf("[prompt] response req=%u loading=%u count=%u\n",
                                      g_modeCtx.promptRequestId,
                                      g_modeCtx.promptLoading ? 1 : 0,
                                      g_modeCtx.promptCount);
                    }
                    break;
                case V5_FRAME_INPUT_ASSISTANT:
                    ok = (g_uiMode == DEV_MODE_INPUT_ASSISTANT) &&
                         v5ParseInputAssistant(data, len, g_modeCtx.assistantRequestId, g_modeCtx);
                    if (ok) {
                        g_assistantHostAcked = true;
                        g_assistantTouchMs = millis();
                        g_assistantStatusMs = g_assistantTouchMs;
                        Serial.printf("[assistant] response req=%u state=%u count=%u\n",
                                      g_modeCtx.assistantRequestId, g_modeCtx.assistantState,
                                      g_modeCtx.assistantCount);
                    }
                    break;
                case V5_FRAME_APPLICATION_SWITCHER:
                    ok = parseApplicationSwitcherFrame(data, len, g_modeCtx.applicationSwitcher);
                    if (ok) {
                        const uint8_t operation = len >= 3 ? data[2] : 0xFF;
                        if (operation == APP_SWITCHER_START) {
                            g_appSwitcherActive = false;
                            g_appSwitcherHostAcked = true;
                            g_appSwitcherRequestMs = g_appSwitcherTouchMs = millis();
                            setUiMode(DEV_MODE_APP_SWITCHER);
                        } else if (operation == APP_SWITCHER_COMMIT) {
                            g_appSwitcherTouchMs = millis();
                        } else if (operation == APP_SWITCHER_EXIT) {
                            setUiMode(DEV_MODE_NORMAL);
                        }
                        Serial.printf("[app-switcher] frame req=%u op=%u count=%u selected=%d valid=%u\n",
                                      data[1], operation, g_modeCtx.applicationSwitcher.count,
                                      (int)g_modeCtx.applicationSwitcher.selected,
                                      g_modeCtx.applicationSwitcher.valid ? 1 : 0);
                    }
                    break;
            }
            if (!ok) {
                Serial.printf("[v5] frame 0x%02X parse FAIL (len=%u)\n", data[0], (unsigned)len);
                return;
            }
            // 有效 v5 帧同样重置轮询退避
            statusFailCount  = 0;
            currentPollIvlMs = STATUS_POLL_INTERVAL_MS;
            return;
        }

        ClaudeStatusState parsed;
        if (!parseClaudeStatus(data, len, parsed)) {
            Serial.printf("ClaudeStatus parse FAIL (len=%u)\n", (unsigned)len);
            return;
        }

        // 任何有效 notify 都重置轮询失败计数 + 恢复 30s 间隔
        statusFailCount  = 0;
        currentPollIvlMs = STATUS_POLL_INTERVAL_MS;

        g_claudeStatus = parsed;
        if (!g_mockHold) mapV4ToV5(parsed, g_v5);   // v1.0.0 渲染走 g_v5(REQ-007 前的桥)

        Serial.printf(
            "ClaudeStatus parsed: phase=%u sessions=%u color=%u proj=\"%s\" tool=\"%s\" "
            "usage=%u%% ctx=%u%% tokIn=%u tokOut=%u +%u/-%u dashCount=%u exclusive=%d\n",
            parsed.phase, parsed.sessionCount, parsed.colorIndex,
            parsed.projName, parsed.toolName,
            parsed.usagePct, parsed.ctxPct,
            parsed.tokenInK, parsed.tokenOutK,
            parsed.linesAdded, parsed.linesRemoved,
            parsed.dashCount, (int)parsed.exclusiveIdx);

        for (uint8_t i = 0; i < parsed.dashCount; i++) {
            Serial.printf("  dash[%u]: name=\"%s\" color=%u phase=%u\n",
                          i, parsed.dashes[i].name,
                          parsed.dashes[i].colorIdx, parsed.dashes[i].phase);
        }
    }
};

// ── Stage 2: PermissionRequest characteristic callback (Mac → Device write) ──
class PermRequestCallback : public NimBLECharacteristicCallbacks {
    void onWrite(NimBLECharacteristic* pChar, NimBLEConnInfo& connInfo) override {
        if (micstickOta.active()) return;
        NimBLEAttValue val = pChar->getValue();
        const uint8_t* data = val.data();
        size_t len = val.length();

        // REQ-022:新 Mac 可能在本 characteristic 上发二进制审批帧(0x55/0x56);
        // onWrite 侧只看首字节判别并投队列(竞态修复),命中即消费。
        // 未命中(裸 JSON '{' 开头)走下方既有 toast 路径不动(A4 旧 Mac 兼容)。
        if (apvEnqueueRx(data, len)) return;

        PermissionToastState toast;
        if (!parsePermissionRequest(data, len, toast)) {
            Serial.printf("Permission parse FAIL (len=%u)\n", (unsigned)len);
            return;
        }

        toast.expiresAt = millis() + 3000;
        g_permToast = toast;
        // REQ-003 Phase 1a (2026-05-03): light sleep 中也能远程提醒用户。
        // 不刷 activity 计时器(BLE 推送不算用户行为),不亮屏,
        // 只触发 LED 紫色心跳 → 不打断 light sleep 但让用户看见请求。
        led_fire_event(LED_EV_PERM_PENDING);

        Serial.printf("Permission toast: tool=\"%s\" input=\"%s\"\n",
                      toast.tool, toast.input);
    }
};

// ── plan v4: EC11 正交状态机解码 ─────────────────────────
// 升级原因:实测 ElecFans 4 脚 EC11 模块(板上 R5 让 SW 借 SIGA 输出),
//          按下旋钮时 SIGA 在阈值附近抖动,FALLING 单边沿模式会被误触多次。
// 解决:Gray code 状态机,A 和 B 都 CHANGE 中断,只在走完完整 4 步循环
//      (00→01→11→10→00 或反向)才计 ±1 格。SW 抖动产生不完整循环 → 净零。
//
// 状态编码: bit0=A, bit1=B  (HIGH=1 / LOW=0)
// 查表:索引 = (oldState << 2) | newState,值 = +1 / -1 / 0(无效跳变)
volatile int8_t encDelta = 0;
volatile uint8_t encState = 0;
volatile int8_t  encAccum = 0;

static const int8_t kEncLUT[16] = {
    0, -1, +1,  0,
   +1,  0,  0, -1,
   -1,  0,  0, +1,
    0, +1, -1,  0
};

static void IRAM_ATTR onEncChange() {
    uint8_t s = (digitalRead(PIN_ENC_A) ? 1 : 0) | (digitalRead(PIN_ENC_B) ? 2 : 0);
    encAccum += kEncLUT[(encState << 2) | s];
    encState = s;
    if (encAccum >= 4)  { encDelta++; encAccum = 0; }
    if (encAccum <= -4) { encDelta--; encAccum = 0; }
}

// ── Setup ────────────────────────────────────────────────
// ── 死机黑匣子(RTC_NOINIT:PANIC/WDT/BROWNOUT 复位间保留,仅物理断电丢)──
//   排查"电池上过夜后按键无法唤醒"(2026-07-05):开机取证上一条命的死法,
//   splash 屏显 + 串口打印;配合 loop 里 120s task WDT(挂死自动复位自救)与 30s 记帧。
#define BB_MAGIC 0x51564D45u   // 'QVME'(v4:加 dip 追踪器定位瞬时大分配)
typedef struct {
    uint32_t magic;
    uint32_t bootCount;   // 自 RTC 内容失效(真掉电)以来第几次 boot
    uint32_t upMs;        // 最后一帧:运行时长
    uint32_t batMv;       // 最后一帧:电池 mV
    uint8_t  bleConn;     // 最后一帧:BLE 是否连接
    uint8_t  pwrLabel;    // 最后一帧:电源状态 (UiPowerLabel: 0=ACT 1=IDLE 2=DIM 3=OFF)
    uint8_t  offStep;     // 步骤标记(死在哪两段之间):
                          //   10/11/12=SLPIN块  1=power_tick内 2=power_tick后~LED前
                          //   20/21/22=进OFF转换块  30=led_tick内 31=led后~delay前 32=delay中
                          //   33=loop顶~按键区  0=不在已标记路径
    uint8_t  wdtFired;    // task WDT 曾触发(ISR 钩子里标记)
    // ── 墓碑:最近一次"非正常死亡"的完整现场,正常重启不覆盖 ──
    uint32_t gUpMs;
    uint32_t gBatMv;
    uint32_t gBootCount;  // 死亡发生在第几条命
    uint8_t  gReason;     // esp_reset_reason_t
    uint8_t  gOffStep;
    uint8_t  gWdt;
    uint8_t  gBleConn;
    uint8_t  gPwrLabel;
    uint8_t  gValid;      // 墓碑有效标志
    uint8_t  rsv[2];
    uint32_t minHeap;     // 本条命的历史最小空闲堆(泄漏侦测:趋势下行=泄漏)
    uint32_t gMinHeap;    // 墓碑:死亡时的历史最小堆
    // ── dip 追踪器(0.6.8):定位瞬时大分配 ──
    uint32_t dipMin;      // 分配器终身最小值(每迭代采样)
    uint32_t dipUp;       // 检测到新低的时刻(ms)
    uint32_t dipLarg;     // 新低时的最大可分配块
    uint8_t  dipStep;     // 新低时主循环所在标记段
    uint8_t  rsv2[3];
} BlackBox;
RTC_NOINIT_ATTR static BlackBox g_bb;
static char g_bbDiag1[28];
static char g_bbDiag2[28];
static char g_bbDiag3[44];   // 墓碑行
static bool g_forcedStandbyPending = false;
static uint32_t g_forcedStandbyDeadlineMs = 0;

// ── NVS 启动环(flash 持久,RTC 被清/真掉电也不丢)──
//   每次开机把上一条命的取证写一条进 NVS(12 槽轮转,一次开机一写,损耗可忽略)
static void bbPersistBootRecord() {
    Preferences p;
    if (!p.begin("bb", false)) return;
    uint32_t seq = p.getUInt("seq", 0) + 1;
    p.putUInt("seq", seq);
    // 0.6.7:并入前会话 journal 快照(单槽 journal 会被新会话 60s 后覆盖,
    // 此处固化进 12 槽 ring,freeze 会话的最后轨迹永久保留)
    uint32_t jUp = p.getUInt("aUp", 0), jMinH = p.getUInt("aMinH", 0);
    uint32_t jFree = p.getUInt("aFree", 0), jLarg = p.getUInt("aLarg", 0);
    char key[8];
    snprintf(key, sizeof(key), "r%u", (unsigned)(seq % 12));
    char rec[176];
    snprintf(rec, sizeof(rec), "q%u %s | %s | j:up=%lus minH=%luk free=%luk larg=%luk | dip:%luk@%lus s%u",
             (unsigned)seq, g_bbDiag1, g_bbDiag2,
             (unsigned long)jUp, (unsigned long)(jMinH / 1024),
             (unsigned long)(jFree / 1024), (unsigned long)(jLarg / 1024),
             (unsigned long)(g_bb.dipMin / 1024), (unsigned long)(g_bb.dipUp / 1000), g_bb.dipStep);
    p.putString(key, rec);
    p.end();
}
static void bbDumpNvsRing() {
    Preferences p;
    if (!p.begin("bb", true)) return;
    uint32_t seq = p.getUInt("seq", 0);
    Serial.printf("[bb] nvs ring(新→旧, 最新 q%u):\n", (unsigned)seq);
    for (uint32_t i = 0; i < 12 && i < seq; i++) {
        char key[8];
        snprintf(key, sizeof(key), "r%u", (unsigned)((seq - i) % 12));
        String v = p.getString(key, "");
        if (v.length()) Serial.printf("[bb]   %s\n", v.c_str());
    }
    p.end();
}

static const char* bbResetName(esp_reset_reason_t r) {
    switch (r) {
        case ESP_RST_POWERON:   return "POWERON";
        case ESP_RST_EXT:       return "EXT";
        case ESP_RST_SW:        return "SW";
        case ESP_RST_PANIC:     return "PANIC";
        case ESP_RST_INT_WDT:   return "INT_WDT";
        case ESP_RST_TASK_WDT:  return "TASK_WDT";
        case ESP_RST_WDT:       return "WDT";
        case ESP_RST_DEEPSLEEP: return "DEEPSLEEP";
        case ESP_RST_BROWNOUT:  return "BROWNOUT";
        case ESP_RST_SDIO:      return "SDIO";
        default:                return "UNKNOWN";
    }
}

// task WDT 触发时优先走这里(覆盖 IDF 弱符号):标记后直接 ROM 硬复位,
// 跳过 panic 串口打印——无 USB 主机时 panic 往 CDC 打印可能卡死,复位走不完
// (2026-07-05 夜测:WDT armed 但整夜没复位成功,怀疑就是 panic 打印被 CDC 卡住)
#include "esp32s3/rom/rtc.h"
extern "C" void esp_task_wdt_isr_user_handler(void) {
    g_bb.wdtFired = 1;
    software_reset();
}

// ── I2S 安装(v0.6.3:从 setup 抽出)──
//   息屏省电改为 driver_uninstall/install 完整重建:v0.6.2 用 i2s_stop/start,
//   PDM RX 时钟 start 后起不来,i2s_read 永久阻塞 → 麦克风装死、识别全灭。
static void installI2S() {
#ifdef MIC_PDM
    // v11: MSM261DHP006 PDM 顶进声麦(CLK=GPIO4 / DATA=GPIO6,L/R→GND=左声道)
    // ⚠ 时钟死区坑:MSM261 系列标准模式要求 fCLOCK 1.1–4.0 MHz(低功耗档上限 900kHz)。
    //   legacy 驱动 PDM RX 时钟 = fs×64(DSR_8S)/ fs×128(DSR_16S);16kHz 下 DSR_8S 只有
    //   1.024MHz,落在 900k–1.1M 的模式死区麦可能不出声 → 必须 DSR_16S(2.048MHz)。
    // PDM RX 硬件滤波直接吐 16-bit PCM(非 32-bit slot),读取路径同步走 int16(见 audioTask)。
    i2s_config_t i2s_config = {
        .mode = (i2s_mode_t)(I2S_MODE_MASTER | I2S_MODE_RX | I2S_MODE_PDM),
        .sample_rate = SAMPLE_RATE,
        .bits_per_sample = I2S_BITS_PER_SAMPLE_16BIT,
#ifdef MIC_PDM_CH_RIGHT
        .channel_format = I2S_CHANNEL_FMT_ONLY_RIGHT,  // bringup 备用:ONLY_LEFT 无声时加 -DMIC_PDM_CH_RIGHT 换边
#else
        .channel_format = I2S_CHANNEL_FMT_ONLY_LEFT,   // L/R→GND = 左声道
#endif
        .communication_format = (i2s_comm_format_t)I2S_COMM_FORMAT_STAND_I2S,
        .intr_alloc_flags = ESP_INTR_FLAG_LEVEL1,
        .dma_buf_count = 8,
        .dma_buf_len = 256,
        .use_apll = false,
    };

    i2s_pin_config_t pin_config = {
        .mck_io_num = I2S_PIN_NO_CHANGE,
        .bck_io_num = I2S_PIN_NO_CHANGE,   // PDM 无 BCLK/WS 之分,时钟从 ws 槽位出
        .ws_io_num = PIN_PDM_CLK,
        .data_out_num = I2S_PIN_NO_CHANGE,
        .data_in_num = PIN_PDM_DATA,
    };

    i2s_driver_install(I2S_NUM_0, &i2s_config, 0, NULL);
    i2s_set_pin(I2S_NUM_0, &pin_config);
    i2s_set_pdm_rx_down_sample(I2S_NUM_0, I2S_PDM_DSR_16S);  // 2.048MHz;勿改 8S(时钟死区)
#else
    i2s_config_t i2s_config = {
        .mode = (i2s_mode_t)(I2S_MODE_MASTER | I2S_MODE_RX),
        .sample_rate = SAMPLE_RATE,
        // INMP441 输出 24-bit MSB-aligned 在 32-bit I2S slot 高位; 必须 32-bit 读
        // 否则只拿到 24-bit 数据的高 16 bit, 灵敏度直接打 1/16 折扣
        .bits_per_sample = I2S_BITS_PER_SAMPLE_32BIT,
#if DUAL_MIC_ENABLED
        .channel_format = I2S_CHANNEL_FMT_RIGHT_LEFT,  // 双麦立体声: L=Mic1(主,对嘴), R=Mic2(参考)
#else
        .channel_format = I2S_CHANNEL_FMT_ONLY_LEFT,   // 单麦: 仅 Mic1 (L/R=GND)
#endif
        .communication_format = (i2s_comm_format_t)I2S_COMM_FORMAT_STAND_I2S,
        .intr_alloc_flags = ESP_INTR_FLAG_LEVEL1,
        .dma_buf_count = 8,
        .dma_buf_len = 256,
        .use_apll = false,
    };

    i2s_pin_config_t pin_config = {
        .mck_io_num = I2S_PIN_NO_CHANGE,
        .bck_io_num = I2S_SCK,
        .ws_io_num = I2S_WS,
        .data_out_num = I2S_PIN_NO_CHANGE,
        .data_in_num = I2S_SD,
    };

    i2s_driver_install(I2S_NUM_0, &i2s_config, 0, NULL);
    i2s_set_pin(I2S_NUM_0, &pin_config);
#endif  // MIC_PDM
}

void setup() {
#ifdef PIN_PWR_KILL
    // REQ-029 第一优先级:锁电源。IO9 悬空/读到 HIGH 会关 3.3V 自杀,
    // 必须在任何其它初始化之前 OUTPUT LOW 保持供电。仅 pwr_enter_standby() 末尾才拉 HIGH。
    pinMode(PIN_PWR_KILL, OUTPUT);
    digitalWrite(PIN_PWR_KILL, LOW);
#endif
#ifdef BOARD_MICSTICK_V14
    // V14 safe boot: keep visible/high-current loads off until the charger has
    // been configured. GPIO8/40 are reserved for SGM41511 I2C.
    pinMode(PIN_LCD_BL_LOCAL, OUTPUT);
    digitalWrite(PIN_LCD_BL_LOCAL, LOW);
    pinMode(PIN_LED_DIN, OUTPUT);
    digitalWrite(PIN_LED_DIN, LOW);
#endif
#ifdef PIN_POWER_ON
    pinMode(PIN_POWER_ON, OUTPUT);
    digitalWrite(PIN_POWER_ON, HIGH);
#endif

#if PIN_BUZZER >= 0
    // v10:无源蜂鸣器脚常驻拉低,防悬空拾电源开关噪声"嗡嗡"(面包板 PIN_BUZZER=-1 跳过)
    pinMode(PIN_BUZZER, OUTPUT);
    digitalWrite(PIN_BUZZER, LOW);
#endif

    pinMode(PIN_BUTTON, INPUT_PULLUP);
    pinMode(PIN_BUTTON_B, INPUT_PULLUP);
    pinMode(PIN_ENC_SW, INPUT_PULLUP);
#ifdef PIN_BUTTON_C
    pinMode(PIN_BUTTON_C, INPUT_PULLUP);
#endif
#ifdef PIN_SIDE_BUTTON
    pinMode(PIN_SIDE_BUTTON, INPUT_PULLUP);
#endif

    power_early_init();

    pinMode(PIN_ENC_A, INPUT_PULLUP);
    pinMode(PIN_ENC_B, INPUT_PULLUP);
    // 初始化状态机当前值,避免 boot 后第一次跳变误判
    encState = (digitalRead(PIN_ENC_A) ? 1 : 0) | (digitalRead(PIN_ENC_B) ? 2 : 0);
    attachInterrupt(digitalPinToInterrupt(PIN_ENC_A), onEncChange, CHANGE);
    attachInterrupt(digitalPinToInterrupt(PIN_ENC_B), onEncChange, CHANGE);
    // RX 缓冲 256→2048:APV <hex> 最长 719 字符一次性突发,默认 256B 会丢中段
    // (cmdBuf 早已开到 800,漏配了对应 RX 缓冲;必须在 begin 之前设)
    Serial.setRxBufferSize(2048);
    Serial.begin(115200);
    // 无 USB 主机时 CDC 写不进就丢弃(0=不等待)。根因排查 2026-07-05:
    // HWCDC 拔线后 TX 环形缓冲写满,write() 阻塞(HWCDC.cpp 自己注释承认此坑),
    // OFF 切换路径连串 printf 就把主 loop 卡死 → 电池上"深睡不可唤醒"假象
    Serial.setTxTimeoutMs(0);

    // 生成动态设备名:MicPad-XXXX(MAC 后 2 字节)
    uint8_t mac[6];
    esp_efuse_mac_get_default(mac);
#if defined(BOARD_MICSTICK_V12) || defined(BOARD_MICSTICK_V14)
    snprintf(devName, sizeof(devName), "MicStick-%02X%02X", mac[4], mac[5]);
#else
    snprintf(devName, sizeof(devName), "MicPad-%02X%02X", mac[4], mac[5]);
#endif
    Serial.printf("Device name: %s\n", devName);
    loadPersistedUiLocale();

    // ── 黑匣子取证:上一条命怎么死的(必须在写入任何新帧之前读)──
    esp_reset_reason_t bbReason = esp_reset_reason();
    // v2:只认 magic,不再按 POWERON 清盒——插拔 USB 的电源瞬态会产生假 POWERON
    // 把整夜证据误清(2026-07-06 教训);真掉电时 RTC 内容变垃圾,magic 自然失效
    if (g_bb.magic != BB_MAGIC) {
        memset(&g_bb, 0, sizeof(g_bb));
        g_bb.magic = BB_MAGIC;
    }
    // 非正常死亡 → 现场寄存进墓碑(正常重启/复位不覆盖)。
    // 注意:offStep 单独不算异常——稳态标记(30/31/32/33/1/2)每圈都在写,
    // 正常复位(esptool 等)总会逮到一个非零值,曾把健康快照误存墓碑(0.6.2 教训);
    // 真冻死必伴随 WDT(W)或 crash 类 reason,那时 offStep 才作为死点读取。
    bool bbAbnormal = g_bb.wdtFired ||
                      bbReason == ESP_RST_PANIC || bbReason == ESP_RST_INT_WDT ||
                      bbReason == ESP_RST_TASK_WDT || bbReason == ESP_RST_WDT ||
                      bbReason == ESP_RST_BROWNOUT;
    if (bbAbnormal) {
        g_bb.gReason    = (uint8_t)bbReason;
        g_bb.gOffStep   = g_bb.offStep;
        g_bb.gWdt       = g_bb.wdtFired;
        g_bb.gUpMs      = g_bb.upMs;
        g_bb.gBatMv     = g_bb.batMv;
        g_bb.gBleConn   = g_bb.bleConn;
        g_bb.gPwrLabel  = g_bb.pwrLabel;
        g_bb.gBootCount = g_bb.bootCount;
        g_bb.gMinHeap   = g_bb.minHeap;
        g_bb.gValid     = 1;
    }
    snprintf(g_bbDiag2, sizeof(g_bbDiag2), "last %lum ble%u p%u %umV h%uk",
             (unsigned long)(g_bb.upMs / 60000UL), g_bb.bleConn, g_bb.pwrLabel,
             (unsigned)g_bb.batMv, (unsigned)(g_bb.minHeap / 1024));
    g_bb.bootCount++;
    snprintf(g_bbDiag1, sizeof(g_bbDiag1), "rst:%s #%u s%u%s",
             bbResetName(bbReason), (unsigned)g_bb.bootCount,
             g_bb.offStep, g_bb.wdtFired ? " W" : "");
    // 0.6.6:读回 flash 存活账(上条命最后 60s 记录 + heapGuard 事件)
    {
        Preferences rp;
        if (rp.begin("bb", true)) {
            uint32_t aUp = rp.getUInt("aUp", 0), aMinH = rp.getUInt("aMinH", 0);
            uint32_t aFree = rp.getUInt("aFree", 0), aLarg = rp.getUInt("aLarg", 0);
            uint8_t aSt = rp.getUChar("aSt", 0);
            String guard = rp.getString("guard", "");
            String corrupt = rp.getString("corrupt", "");
            rp.end();
            if (corrupt.length()) Serial.printf("[bb] 前科: %s\n", corrupt.c_str());
            Serial.printf("[bb] flash账: 上条命 up=%lus minH=%luk free=%luk larg=%luk p%u ble%u%s%s\n",
                          (unsigned long)aUp, (unsigned long)(aMinH / 1024),
                          (unsigned long)(aFree / 1024), (unsigned long)(aLarg / 1024),
                          (unsigned)(aSt & 0x7F), (unsigned)(aSt >> 7),
                          guard.length() ? " | GUARD: " : "", guard.c_str());
        }
    }
    if (g_bb.gValid) {
        snprintf(g_bbDiag3, sizeof(g_bbDiag3), "grave:%s s%u%s %lum ble%u p%u %umV b#%u",
                 bbResetName((esp_reset_reason_t)g_bb.gReason), g_bb.gOffStep,
                 g_bb.gWdt ? " W" : "", (unsigned long)(g_bb.gUpMs / 60000UL),
                 g_bb.gBleConn, g_bb.gPwrLabel, (unsigned)g_bb.gBatMv,
                 (unsigned)g_bb.gBootCount);
    } else {
        g_bbDiag3[0] = '\0';
    }
    // (清零移至 bbPersistBootRecord 之后,防止 ring 记录被先清空 — 0.6.9 修复)
    Serial.printf("[bb] %s | %s%s%s\n", g_bbDiag1, g_bbDiag2,
                  g_bbDiag3[0] ? " | " : "", g_bbDiag3);
    // splash 两行:第二行优先展示墓碑(比"上一帧"更值钱)。
    // REQ-023 二期(用户 2026-07-25 拍板):仅本次复位异常时上屏,正常开机 splash
    // 无调试文字(满足设计约束);串口/NVS 取证输出不受影响
    if (bbAbnormal) ui_set_diag(g_bbDiag1, g_bbDiag3[0] ? g_bbDiag3 : g_bbDiag2);
    bbPersistBootRecord();   // flash 持久化(RTC 被清也不丢)
    bbDumpNvsRing();
    g_bb.offStep = 0;
    g_bb.wdtFired = 0;
    g_bb.minHeap = (uint32_t)ESP.getMinFreeHeap();
    g_bb.dipMin = 0; g_bb.dipUp = 0; g_bb.dipStep = 0; g_bb.dipLarg = 0;

    // ── PSRAM 诊断(BLE 之前打,验证 fqbn PSRAM=opi 生效) ──
    Serial.printf("PSRAM size: %u bytes (%u MB)\n",
                  (unsigned)ESP.getPsramSize(),
                  (unsigned)(ESP.getPsramSize() / 1024 / 1024));
    Serial.printf("Free heap:  %u bytes\n", (unsigned)ESP.getFreeHeap());
    Serial.printf("Free PSRAM: %u bytes\n", (unsigned)ESP.getFreePsram());

    // TFT + Dashboard sprite (Stage 3a)
    tft.begin();
    ui_init();   // 内部 setRotation(0) + 整屏 sprite (PSRAM)

    // Stage 4: 接管背光 PWM + USB 检测 + 状态机
    // 必须在 tft.begin()(它会 digitalWrite TFT_BL=38 HIGH)之后,
    // 由 power_init 用 LEDC 重新 attach 引脚做 PWM。
    power_init();

    // REQ-029:上电区分"上次是主动 IO9 待机" vs "崩溃/欠压"。唤醒重连时跳 LED 自检提速。
    bool g_wokeFromStandby = power_was_clean_shutdown();
    if (g_wokeFromStandby)
        Serial.println("[PWR] boot after clean deep-standby (IO9 wake, cold boot)");

    // ── REQ-003 Phase 2.2 (0.5.3): esp_pm_configure 在 Arduino-ESP32 2.0.14 上不可用 ──
    //   实测 esp_pm_configure 返回 262 (ESP_ERR_NOT_SUPPORTED) — 预编译 sdkconfig CONFIG_PM_ENABLE=n
    //   要开 PM 需自定义 sdkconfig 重编 arduino-esp32 静态库,工作量大
    //   退而求其次:setCpuFrequencyMhz 手动降频,进 OFF 切到 80MHz(~30mA 省),出 OFF 切回 240
    //   注意:setCpuFrequencyMhz 内部也会调 esp_pm_configure,但是 light_sleep_enable=false,
    //   所以只动 CPU 频率不进 light sleep,BLE radio 不受影响

    // Stage 1b 后半:SK6812 LED 灯条(GPIO 2 → 74AHCT125 → 470Ω → DIN)
    // 启动时 R/G/B 自检 200ms × 3(唤醒重连时跳过省 ~600ms)
    led_init(g_wokeFromStandby);

    // REQ-022:审批音效驱动(LEDC ch2)+ 渲染视图指针注册 + BLE→loop 审批帧中转队列
    buzzer_init();
    ui_set_approval_view(&g_approvalView);
    g_apvRxQueue = xQueueCreate(8, sizeof(ApprovalRxMsg));
    if (g_apvRxQueue == nullptr) Serial.println("[apv] rx queue create FAILED");
    g_taskLifecycleRxQueue = xQueueCreate(16, sizeof(TaskLifecycleRxMsg));
    if (g_taskLifecycleRxQueue == nullptr) Serial.println("[task-life] rx queue create FAILED");

    tft.fillScreen(TFT_BLACK);
    tft.setTextColor(TFT_WHITE, TFT_BLACK);
    tft.setTextFont(2);
    tft.setCursor(8, 8);
    tft.print(devName);
    tft.setCursor(8, 28);
    tft.print("BLE: booting...");

    installI2S();   // I2S 安装(抽为函数,睡眠唤醒时可完整重装,见 audioTask)

    // BLE
    NimBLEDevice::init(devName);
    NimBLEDevice::setMTU(512);
    NimBLEDevice::setSecurityAuth(false, false, true);

    pServer = NimBLEDevice::createServer();
    pServer->setCallbacks(new ServerCallbacks());

    NimBLEService* pService = pServer->createService(AUDIO_SERVICE_UUID);

    pAudioDataChar = pService->createCharacteristic(
        AUDIO_DATA_CHAR_UUID,
        NIMBLE_PROPERTY::NOTIFY
    );

    pAudioControlChar = pService->createCharacteristic(
        AUDIO_CONTROL_CHAR_UUID,
        NIMBLE_PROPERTY::WRITE | NIMBLE_PROPERTY::NOTIFY
    );
    pAudioControlChar->setCallbacks(new ControlCallbacks());

    // Stage 2: ClaudeStatus characteristic (Mac writes; we parse).
    pClaudeStatusChar = pService->createCharacteristic(
        CLAUDE_STATUS_CHAR_UUID,
        NIMBLE_PROPERTY::WRITE | NIMBLE_PROPERTY::NOTIFY
    );
    pClaudeStatusChar->setCallbacks(new ClaudeStatusCallback());

    // Stage 2: PermissionRequest characteristic (Mac writes JSON; we parse).
    pPermRequestChar = pService->createCharacteristic(
        PERM_REQUEST_CHAR_UUID,
        NIMBLE_PROPERTY::WRITE | NIMBLE_PROPERTY::NOTIFY
    );
    pPermRequestChar->setCallbacks(new PermRequestCallback());

    // Permission response 留给 Stage 4(用户 Allow/Deny 回写),目前只做占位。
    pService->createCharacteristic(
        PERM_RESPONSE_CHAR_UUID,
        NIMBLE_PROPERTY::READ | NIMBLE_PROPERTY::INDICATE
    );

    pService->start();

#if defined(BOARD_MICSTICK_V12) || defined(BOARD_MICSTICK_V14)
    NimBLEService* otaService = pServer->createService(OTA_SERVICE_UUID);
    NimBLECharacteristic* otaControlChar = otaService->createCharacteristic(
        OTA_CONTROL_CHAR_UUID,
        NIMBLE_PROPERTY::WRITE | NIMBLE_PROPERTY::WRITE_ENC
    );
    NimBLECharacteristic* otaDataChar = otaService->createCharacteristic(
        OTA_DATA_CHAR_UUID,
        NIMBLE_PROPERTY::WRITE_NR | NIMBLE_PROPERTY::WRITE_ENC
    );
    NimBLECharacteristic* otaStatusChar = otaService->createCharacteristic(
        OTA_STATUS_CHAR_UUID,
        NIMBLE_PROPERTY::READ | NIMBLE_PROPERTY::NOTIFY
    );
    otaControlChar->setCallbacks(new MicStickOTAControlCallbacks(micstickOta));
    otaDataChar->setCallbacks(new MicStickOTADataCallbacks(micstickOta));
    micstickOta.begin(otaStatusChar);
    otaService->start();
#endif

    NimBLEAdvertising* pAdvertising = NimBLEDevice::getAdvertising();
    // NimBLE 2.x 不自动广播设备名;128-bit Service UUID 已占 18 字节,
    // 名字必须放 Scan Response(同 StickS3 做法),否则 Mac 扫描端拿不到
    // 名字、按前缀分型会把 MicPad 误判成 StickS3(v1.0.4)
    pAdvertising->enableScanResponse(true);
    pAdvertising->setName(devName);
    pAdvertising->addServiceUUID(AUDIO_SERVICE_UUID);
    pAdvertising->setMinInterval(160);   // 100ms: faster discovery/reconnect
    pAdvertising->setMaxInterval(240);   // 150ms
    // REQ-029:广播声明快首选连接间隔(Slave Conn Interval Range,单位 1.25ms)。
    // 目的=IO9 冷启动后 macOS 全量 GATT 发现阶段就用快间隔(不等 onConnect 的 15ms 生效),
    // 压缩空口发现往返时间。12=15ms / 24=30ms(macOS 可能只作参考,不保证采纳)。
    pAdvertising->setPreferredParams(12, 24);
    pAdvertising->start();

    Serial.printf("BLE advertising started: %s\n", devName);
    Serial.printf("[ble] adv config name=%s service=%s scanResp=1 interval=%u..%u units\n",
                  devName, AUDIO_SERVICE_UUID, 160, 240);
    Serial.printf("Protocol version: %d\n", PROTOCOL_VERSION);

    // Audio queue & tasks
    audioQueue = xQueueCreate(20, sizeof(AudioPacket));
#if DUAL_MIC_ENABLED
    xTaskCreatePinnedToCore(audioTask, "audio", 12288, NULL, 3, NULL, 1);  // 双麦立体声缓冲增大, 栈扩容
#else
    xTaskCreatePinnedToCore(audioTask, "audio", 8192,  NULL, 3, NULL, 1);  // 单麦原始栈
#endif
    xTaskCreatePinnedToCore(bleTxTask, "bleTx", 4096, NULL, 2, NULL, 0);

    // ── Task WDT:loop 挂死 120s 自动复位自救(reason=TASK_WDT 留证据)──
    //   只订阅 loopTask;audioTask/bleTxTask 不订阅(i2s_read 阻塞是常态)
    esp_task_wdt_init(120, true);
    esp_task_wdt_add(NULL);
    Serial.println("[bb] task WDT armed: 120s on loopTask");

    // ── RWDT(RTC 看门狗):跑在 RTC 时钟域,复位不依赖 CPU 执行代码 ──
    //   专治"取指挂死"级全冻结(电池瞬态致 flash 打嗝时,task/INT WDT 全部失效,
    //   2026-07-05/06 两夜整机冻死连 WDT 都没火,即此类)。20s 没喂 → RESET_SYSTEM
    //   (复位 CPU+外设但不动 RTC,黑匣子标记原样保留)。喂狗在 loop。
    {
        uint32_t slowHz = rtc_clk_slow_freq_get_hz();   // S3 默认 RC ~136kHz,运行期实测
        wdt_hal_init(&g_rwdt, WDT_RWDT, 0, false);
        wdt_hal_write_protect_disable(&g_rwdt);
        wdt_hal_config_stage(&g_rwdt, WDT_STAGE0, slowHz * 20, WDT_STAGE_ACTION_RESET_SYSTEM);
        wdt_hal_enable(&g_rwdt);
        wdt_hal_write_protect_enable(&g_rwdt);
        Serial.printf("[bb] RWDT armed: 20s @%luHz (survives CPU/cache hang)\n",
                      (unsigned long)slowHz);
    }

}

// ── Main Loop ────────────────────────────────────────────
// 双按键行为（与 Stick S3 V4 协议对齐）：
//   BtnA 短按 → CMD_ENTER (0x10)            Mac 模拟回车
//   BtnA 长按 → 主 AI PTT (buttonId=0x01) 录音 + 推流（唯一 PTT 源）
//   BtnA 长按松开 → CMD_BTN_A_PTT_STOP (0x14)
//   BtnB 短按 → CMD_ESC (0x11)              Mac 模拟 Esc
//   BtnB 长按 → CMD_SHIFT_TAB (0x12)        Mac 注入 Shift+Tab（模式切换，不录音）
//   EC11 SW 短按 → CMD_BACKSPACE (0x13)     Mac 模拟 Backspace（删除）
//   EC11 SW 长按 → 空（预留）
// 代价：PTT 启动延迟 500ms（短按 vs 长按判定阈值）
ButtonState btnA     = {PIN_BUTTON,    false, 0, false};
ButtonState btnB     = {PIN_BUTTON_B,  false, 0, false};
ButtonState btnEncSw = {PIN_ENC_SW,    false, 0, false};
#ifdef PIN_BUTTON_C
ButtonState btnC     = {PIN_BUTTON_C,  false, 0, false};   // v12 第三键(IO47):ESC / App Switcher / 模式动作
#endif
#ifdef PIN_SIDE_BUTTON
ButtonState btnSide  = {PIN_SIDE_BUTTON, false, 0, false};  // V14 SW1:short=activity, hold 2s=transport confirm
#endif
// plan v4: btnUp/btnDn 已被 EC11 编码器中断取代,见 onEncA()

static ButtonEvent updateButton(ButtonState &btn, unsigned long holdThresholdMs = BTN_HOLD_THRESH_MS) {
    bool pressed = (digitalRead(btn.pin) == LOW);
    ButtonEvent event = BTN_NONE;

    if (pressed && !btn.wasPressed) {
        btn.pressStartMs = millis();
        btn.isHolding = false;
        event = BTN_RAW_PRESS;        // Stage 5: 按下瞬间事件,给预录用
    }
    // RAW_PRESS 优先级低于后续(同一帧不会同时触发 RAW_PRESS 和 HOLD_START,因为 hold 至少 500ms)
    if (pressed && !btn.isHolding && (millis() - btn.pressStartMs) >= holdThresholdMs) {
        btn.isHolding = true;
        event = BTN_HOLD_START;
    }
    if (!pressed && btn.wasPressed) {
        event = btn.isHolding ? BTN_HOLD_END : BTN_TAP;
        btn.isHolding = false;
    }
    btn.wasPressed = pressed;
    return event;
}

// ── 串口调试命令(host 侧工具用;行分隔)──
// REQ-022:APV <hex> 把 hex 当收到的 0x55/0x56 帧注入(绕过 BLE 验全链路)/
//         APV? 打印队列状态 / APVTX 打印最近一次待发 0x36。
// REQ-022 音效批次:BZ <1-9> 试听音效 / BZV <pct> 设音量(0..100,20% 步进)。
// 缓冲 24→800:0x55 帧最大 357B = 714 hex 字符 + "APV " 前缀。
static int  apvHexToBytes(const char *hex, uint8_t *out, size_t cap);   // 前置声明(定义在下方)
static void apvDumpStatus();
static void prepareL3RailDischargeLoad() {
    if (!power_is_sleeping()) return;
    // V13 L2 has nearly every 3.3V load disabled. On the first boards that can
    // let V3.3 decay more slowly than Q10's gate hold after GPIO9 goes HIGH;
    // D12 then re-latches EN3V3 and produces an immediate cold reboot. Wake
    // only the ST7789 logic (backlight remains LOW) so the rail collapses
    // decisively. Do not call power_note_activity: this is still an L3 path.
    tft.writecommand(0x11);  // SLPOUT
    delay(120);              // ST7789 mandatory wake interval
    tft.writecommand(0x29);  // DISPON; invisible because BL stays off
    Serial.println("[PWR] L3 rail-discharge load armed (ST7789 awake, BL off)");
}
static void handleSerialCommands() {
    static char     cmdBuf[800];
    static uint16_t cmdLen = 0;
    while (Serial.available() > 0) {
        char c = (char)Serial.read();
        if (c == '\n' || c == '\r') {
            cmdBuf[cmdLen] = 0;
            if (cmdLen > 0 && strcmp(cmdBuf, "SCR") == 0) {
                if (power_is_sleeping()) Serial.print("<<<SCR WARN sleeping, frame stale>>>\n");
                ui_dump_screen();
            } else if (cmdLen > 5 && strncmp(cmdBuf, "MOCK ", 5) == 0) {
                power_note_activity();   // OFF 息屏下渲染停摆,mock 调试必须先唤屏
                applyMock(atoi(cmdBuf + 5));
            } else if (cmdLen > 0 && strcmp(cmdBuf, "STANDBY") == 0) {
                // REQ-029 Phase 1 测试:手动触发 IO9 深待机(不返回,按键冷启动唤醒)
                power_enter_deep_standby("serial STANDBY");
            } else if (cmdLen > 8 && strncmp(cmdBuf, "STANDBY ", 8) == 0) {
                // 可控电池测试：下发后在倒计时内拔 USB，随后由主 loop 进入 L3。
                unsigned sec = (unsigned)atoi(cmdBuf + 8);
                if (sec < 1) sec = 1;
                if (sec > 60) sec = 60;
                g_forcedStandbyPending = true;
                g_forcedStandbyDeadlineMs = millis() + sec * 1000UL;
                Serial.printf("[PWR] scheduled STANDBY in %us; unplug USB now\n", sec);
            } else if (cmdLen > 0 && strcmp(cmdBuf, "SHIPCONF") == 0) {
#if HARDWARE_REVISION >= 14 && defined(BOARD_MICSTICK_V14)
                // 与 BLE 0x3D 共用入口，用于实机 UI 和 B/C 路由回归。
                g_pendingShipModeRequest.store(true, std::memory_order_release);
                Serial.println("[ship] serial requested confirmation page");
#else
                Serial.println("[ship] unavailable on this hardware");
#endif
            } else if (cmdLen > 0 && strcmp(cmdBuf, "WAKE") == 0) {
                power_note_activity();
                Serial.println("[wake] activity noted");
            } else if (cmdLen == 5 && strncmp(cmdBuf, "TAP ", 4) == 0) {
                power_note_activity();
                char k = cmdBuf[4];
                if (k == 'A') g_synthA = BTN_TAP;
                else if (k == 'B') g_synthB = BTN_TAP;
                else if (k == 'C') g_synthC = BTN_TAP;
                else if (k == 'D') g_synthSw = BTN_TAP;
                Serial.printf("[synth] TAP %c\n", k);
            } else if (cmdLen == 6 && strncmp(cmdBuf, "HOLD ", 5) == 0) {
                power_note_activity();
                char k = cmdBuf[5];
                if (k == 'A') g_synthA = BTN_HOLD_START;
                else if (k == 'B') g_synthB = BTN_HOLD_START;
                else if (k == 'C') g_synthC = BTN_HOLD_START;
                else if (k == 'D') g_synthSw = BTN_HOLD_START;
                Serial.printf("[synth] HOLD %c\n", k);
            } else if (cmdLen == 5 && strncmp(cmdBuf, "REL ", 4) == 0) {
                power_note_activity();
                char k = cmdBuf[4];
                if (k == 'A') g_synthA = BTN_HOLD_END;
                else if (k == 'B') g_synthB = BTN_HOLD_END;
                else if (k == 'C') g_synthC = BTN_HOLD_END;
                else if (k == 'D') g_synthSw = BTN_HOLD_END;
                Serial.printf("[synth] REL %c\n", k);
            } else if (cmdLen == 5 && strncmp(cmdBuf, "SPL ", 4) == 0) {
                // REQ-023 二期布局验证:强制 splash(1=Disconnected 2=Connected 0=恢复)
                power_note_activity();
                g_splashDemo = (uint8_t)(cmdBuf[4] - '0');
                if (g_splashDemo > 2) g_splashDemo = 0;
                ui_splash_restart_cycle();   // 演示重入无连接边沿,强制新循环便于定时截图
                Serial.printf("[synth] SPL %u\n", g_splashDemo);
            } else if (cmdLen == 6 && strncmp(cmdBuf, "MODE ", 5) == 0) {
                // 布局验证:0=退出 1=编辑 2=Prompt 4=自定义一 5=ChatGPT App 6=Music。
                power_note_activity();
                int m = cmdBuf[5] - '0';
                if (m == 1)      enterEditMode();
                else if (m == 2) enterPromptMode();
                else if (m >= 4 && m <= 6) {
                    g_modeCtx.actionMode = ActionModeDefinition{};
                    const bool custom = m == 4;
                    const bool chatGPT = m == 5;
                    g_modeCtx.actionMode.modeId = custom ? ACTION_MODE_CUSTOM_ONE
                                                        : (chatGPT ? ACTION_MODE_CHATGPT_APP : ACTION_MODE_MUSIC);
                    const char *title = i18nText(custom ? UI_STR_ACTION_CUSTOM_ONE_TITLE
                                                       : (chatGPT ? UI_STR_ACTION_CODEX_TITLE : UI_STR_ACTION_MUSIC_TITLE));
                    const char *line0 = i18nText(custom ? UI_STR_ACTION_CUSTOM_ONE_B
                                                       : (chatGPT ? UI_STR_ACTION_CODEX_B : UI_STR_ACTION_MUSIC_B));
                    const char *line1 = i18nText(custom ? UI_STR_ACTION_CUSTOM_ONE_C
                                                       : (chatGPT ? UI_STR_ACTION_CODEX_C : UI_STR_ACTION_MUSIC_C));
                    const char *line2 = i18nText(custom ? UI_STR_ACTION_CUSTOM_ONE_D
                                                       : (chatGPT ? UI_STR_ACTION_CODEX_D : UI_STR_ACTION_MUSIC_D));
                    strncpy(g_modeCtx.actionMode.title, title, sizeof(g_modeCtx.actionMode.title) - 1);
                    strncpy(g_modeCtx.actionMode.lines[0], line0, sizeof(g_modeCtx.actionMode.lines[0]) - 1);
                    strncpy(g_modeCtx.actionMode.lines[1], line1, sizeof(g_modeCtx.actionMode.lines[1]) - 1);
                    strncpy(g_modeCtx.actionMode.lines[2], line2, sizeof(g_modeCtx.actionMode.lines[2]) - 1);
                    strncpy(g_modeCtx.actionMode.footer,
                            i18nText(m == 6 ? UI_STR_ACTION_MUSIC_FOOTER : UI_STR_ACTION_GESTURE_ORDER),
                            sizeof(g_modeCtx.actionMode.footer) - 1);
                    g_modeCtx.actionMode.valid = true;
                    setUiMode(DEV_MODE_ACTION);
                }
                else             { exitEditMode(); exitPromptMode(); setUiMode(DEV_MODE_NORMAL); }
                Serial.printf("[synth] MODE %d\n", m);
            } else if (cmdLen == 5 && strncmp(cmdBuf, "OVL ", 4) == 0) {
                // REQ-023 布局验证:直接钉 overlay 状态(0=NONE 1=PTT 2=ASR_PROC 3=SUCCESS 4=FAILURE)
                // ASR 结果页平时 2s 自动回落,这里给 8s 窗口便于截图;OVL 0 恢复
                power_note_activity();
                int o = cmdBuf[4] - '0';
                if (o >= 0 && o <= 4) {
                    ui_set_overlay(g_overlayCtx, (UiOverlayState)o);
                    if (o == 3 || o == 4) g_overlayCtx.asrFailExpireMs = millis() + 8000;
                    Serial.printf("[synth] OVL %d\n", o);
                }
            } else if (cmdLen > 4 && strncmp(cmdBuf, "ENC ", 4) == 0) {
                power_note_activity();
                g_synthEnc += (int8_t)atoi(cmdBuf + 4);
                Serial.printf("[synth] ENC %d\n", atoi(cmdBuf + 4));
            } else if (cmdLen > 4 && strncmp(cmdBuf, "TMO ", 4) == 0) {
                g_voiceTimeoutMs = (unsigned long)atoi(cmdBuf + 4) * 1000UL;
                Serial.printf("[test] voice timeout = %lus\n", g_voiceTimeoutMs / 1000);
            } else if (cmdLen > 7 && strncmp(cmdBuf, "PWRSIM ", 7) == 0) {
                power_sim_battery(atoi(cmdBuf + 7) != 0);
                Serial.printf("[test] sim battery = %d\n", atoi(cmdBuf + 7));
            } else if (cmdLen > 4 && strncmp(cmdBuf, "BZV ", 4) == 0) {
                // REQ-022 音效批次:BZV <pct> 设音量(其他钳制到最近 20% 档;NVS 持久化)
                buzzer_set_volume((uint8_t)atoi(cmdBuf + 4));
            } else if (cmdLen > 3 && strncmp(cmdBuf, "BZ ", 3) == 0) {
                // REQ-022 音效批次:BZ <1-9> 试听(编号 = buzzer_fx.h 枚举序,1=TASK_STARTED..9=TASK_COMPLETED)
                int n = atoi(cmdBuf + 3);
                if (n >= 1 && n <= 9) {
                    Serial.printf("[bz] audition %d (vol=%u%%)\n", n, buzzer_get_volume());
                    buzzer_play((BuzzerFx)n);
                } else {
                    Serial.printf("[bz] BZ <1-9> only (got %d)\n", n);
                }
            } else if (cmdLen > 4 && strncmp(cmdBuf, "APV ", 4) == 0) {
                // REQ-022:hex 帧注入,与 BLE 接收走同一入口 handleApprovalFrame
                power_note_activity();   // 息屏下注入也要能唤屏看到模态
                static uint8_t apvFrame[kApprovalRequestMaxLen];
                int n = apvHexToBytes(cmdBuf + 4, apvFrame, sizeof(apvFrame));
                if (n <= 0) {
                    Serial.printf("[apv] bad hex (err=%d)\n", n);
                } else if (!handleApprovalFrame(apvFrame, (size_t)n)) {
                    Serial.printf("[apv] not an approval frame (magic=0x%02X)\n", apvFrame[0]);
                }
            } else if (cmdLen == 3 && strcmp(cmdBuf, "BB?") == 0) {
                // 黑匣子按需 dump(开机打印在 CDC 无主机时被丢,验尸得有事后入口)
                Serial.printf("[bb] %s | %s%s%s\n", g_bbDiag1, g_bbDiag2,
                              g_bbDiag3[0] ? " | " : "", g_bbDiag3);
                bbDumpNvsRing();
                power_dump_shutdown_history();
            } else if (cmdLen == 4 && strcmp(cmdBuf, "APV?") == 0) {
                apvDumpStatus();
            } else if (cmdLen == 5 && strcmp(cmdBuf, "APVTX") == 0) {
                if (g_apvLastTxLen == 0) {
                    Serial.println("[apv] no 0x36 pending/sent yet");
                } else {
                    Serial.print("[apv] last 0x36 hex=");
                    for (uint8_t i = 0; i < g_apvLastTxLen; i++) Serial.printf("%02x", g_apvLastTx[i]);
                    Serial.println();
                }
            }
            cmdLen = 0;
        } else if (cmdLen < sizeof(cmdBuf) - 1) {
            cmdBuf[cmdLen++] = c;
        } else {
            cmdLen = 0;
        }
    }
}

// notify 直接带值:setValue+notify() 在同一 loop 连发两包时,共享 value 缓冲会被
// 第二次 setValue 覆盖,先前的 notify 发出去的是新值(实测 0x30+0x34 连发变两个 0x34)。
static void sendBleCmd(uint8_t cmd) {
    if (!micstickOta.active() && bleConnected && pAudioControlChar) {
        pAudioControlChar->notify(&cmd, 1);
    }
}

static void sendBleCmdN(const uint8_t *data, size_t len) {
    if (!micstickOta.active() && bleConnected && pAudioControlChar) {
        pAudioControlChar->notify(data, len);
    }
}

// ── v1.0.0 设备 UI 模式切换(REQ-011/012):变更同步通知 Mac(0x34,胶囊 UI 联动)──
static void setUiMode(DeviceUiMode m) {
    if (g_uiMode == m) return;
    g_uiMode = m;
    g_modeCtx.mode = (uint8_t)m;
    uint8_t pkt[2] = { CMD_DEVICE_MODE, (uint8_t)m };
    sendBleCmdN(pkt, 2);
    static const char *kModeNames[] = { "normal", "edit", "prompt", "approval", "action", "assistant", "app-switcher" };
    Serial.printf("[mode] -> %s\n",
                  ((uint8_t)m < 7) ? kModeNames[(uint8_t)m] : "?");
}

static void setEditEcho(const char *s) {
    strncpy(g_modeCtx.editEcho, s, sizeof(g_modeCtx.editEcho) - 1);
    g_modeCtx.editEcho[sizeof(g_modeCtx.editEcho) - 1] = 0;
}

static void cancelPendingTaps() {
    g_tapA.cancel();
    g_tapB.cancel();
    g_tapC.cancel();
    if (g_bDeleting) { g_bDeleting = false; g_modeCtx.deleting = false; }
    g_actionRepeatB.active = false;
    g_actionRepeatC.active = false;
}

static void enterPromptMode() {
    cancelPendingTaps();
    g_promptSel = 0;
    g_modeCtx.promptSel = 0;
    g_modeCtx.promptDynamic = true;
    g_modeCtx.promptLoading = true;
    g_modeCtx.promptCount = 0;
    memset(g_modeCtx.promptTitles, 0, sizeof(g_modeCtx.promptTitles));
    g_modeCtx.promptRequestId = ++g_promptNextRequestId;
    if (g_modeCtx.promptRequestId == 0) g_modeCtx.promptRequestId = ++g_promptNextRequestId;
    g_promptTouchMs = millis();
    g_promptRequestMs = g_promptTouchMs;
    g_promptHostAcked = false;
    setUiMode(DEV_MODE_PROMPT);
    uint8_t request[3] = { CMD_DEVICE_MODE, (uint8_t)DEV_MODE_PROMPT,
                           g_modeCtx.promptRequestId };
    sendBleCmdN(request, sizeof(request));
    Serial.printf("[prompt] request req=%u\n", g_modeCtx.promptRequestId);
}

static void exitPromptMode() {
    setUiMode(DEV_MODE_NORMAL);
}

static void enterInputAssistantMode() {
    cancelPendingTaps();
    memset(g_modeCtx.assistantPreview, 0, sizeof(g_modeCtx.assistantPreview));
    memset(g_modeCtx.assistantTitles, 0, sizeof(g_modeCtx.assistantTitles));
    g_modeCtx.assistantState = 0; g_modeCtx.assistantCount = 0; g_modeCtx.assistantSel = 0;
    g_modeCtx.assistantSelectedScope = false;
    g_modeCtx.assistantRequestId = ++g_assistantNextRequestId;
    if (g_modeCtx.assistantRequestId == 0) g_modeCtx.assistantRequestId = ++g_assistantNextRequestId;
    g_assistantRequestMs = g_assistantTouchMs = millis(); g_assistantHostAcked = false;
    setUiMode(DEV_MODE_INPUT_ASSISTANT);
    uint8_t pkt[3] = {CMD_DEVICE_MODE, (uint8_t)DEV_MODE_INPUT_ASSISTANT,
                      g_modeCtx.assistantRequestId};
    sendBleCmdN(pkt, sizeof(pkt));
}

static void exitInputAssistantMode() {
    cancelPendingTaps();
    setUiMode(DEV_MODE_NORMAL);
}

static void enterEditMode() {
    cancelPendingTaps();
    setEditEcho("");
    setUiMode(DEV_MODE_EDIT);
}

static void exitEditMode() {
    g_editPtt = false;
    cancelPendingTaps();   // 残留的 A/B 单击延迟窗不得漏到一级界面触发 UP/ESC
    setUiMode(DEV_MODE_NORMAL);
}

// REQ-013 + T-034: 框选移动(step>0=向下);索引空间 = 显示行(含非活跃标签行)
static void moveFrame(int8_t step, unsigned long now) {
    if (!g_v5.valid || g_v5.sessionCount == 0) return;
    int total = ui_row_count(g_v5, g_listSel.inactiveExpanded);
    if (total <= 0) return;
    if (!g_listSel.visible) {
        g_listSel.visible = true;
        int r = (g_v5.exclusiveIdx >= 0)
                ? ui_session_to_row(g_v5, g_listSel.inactiveExpanded, g_v5.exclusiveIdx) : -1;
        g_listSel.framedIdx = (int8_t)((r >= 0) ? r : (int)g_listSel.scrollTop);
    } else {
        int idx = g_listSel.framedIdx + step;
        if (idx < 0) idx = 0;
        if (idx > total - 1) idx = total - 1;
        g_listSel.framedIdx = (int8_t)idx;
    }
    int vis = ui_session_vis_rows(g_v5);
    if (g_listSel.framedIdx < (int8_t)g_listSel.scrollTop) {
        g_listSel.scrollTop = (uint8_t)g_listSel.framedIdx;
    } else if (g_listSel.framedIdx >= (int8_t)(g_listSel.scrollTop + vis)) {
        g_listSel.scrollTop = (uint8_t)(g_listSel.framedIdx - vis + 1);
    }
    g_frameTouchMs = now;
}

static void startPTT() {
    adpcmState = {0, 0};
    packetSeq = 0;
    audioAgc = AudioAgc{};
    hp_reset();
#if NLMS_ENABLED
    nlms_reset();
#endif
    isRecording = true;
    if (micSourceIsSystem()) {
        sendBleCmd(CMD_BTN_A_PTT_START);
        Serial.println("[T-033] PTT START -> system mic (0x19 sent, no audio upload)");
    }
}

static void stopPTT() {
    isRecording = false;
}

static void sendActionEvent(uint8_t context, DeviceActionControl control,
                            DeviceActionGesture gesture, int8_t delta = 0) {
    uint8_t pkt[5] = {CMD_ACTION_EVENT, context, (uint8_t)control,
                      (uint8_t)gesture, (uint8_t)delta};
    sendBleCmdN(pkt, sizeof(pkt));
}

static void beginVoiceRecording(bool toggle, unsigned long now) {
    if (!bleConnected || isRecording) return;
    startPTT();
    g_toggleRecording = toggle;
    g_holdRecording = !toggle;
    g_recStartMs = now;
    g_overlayCtx.pttStartMs = now;
    g_overlayCtx.toggleHint = toggle;
    g_overlayCtx.systemMic = micSourceIsSystem();
    ui_set_overlay(g_overlayCtx, UI_OV_PTT_PRESS);
    Serial.printf("[A] recording start kind=%s\n", toggle ? "toggle" : "hold");
}

static void finishVoiceRecording(const char *reason) {
    if (!isRecording) return;
    stopPTT();
    preBufActive = false;
    g_toggleRecording = false;
    g_holdRecording = false;
    sendBleCmd(CMD_BTN_A_PTT_STOP);
    ui_set_overlay(g_overlayCtx, bleConnected ? UI_OV_ASR_PROC : UI_OV_NONE);
    Serial.printf("[A] recording stop reason=%s\n", reason ? reason : "?");
}

// A 是全局键：单击 Enter、双击切换式录音、长按 PTT。所有界面先走这里，
// 审批/Prompt/动作模式不得重新解释 A。
static void handleGlobalA(ButtonEvent a, unsigned long now,
                          bool allowSingleEnter = true, bool allowVoice = true) {
    switch (a) {
        case BTN_RAW_PRESS:
            if (allowVoice && (long)(now - g_aSuppressTapUntilMs) >= 0 && bleConnected && !isRecording) {
                audioAgc = AudioAgc{};
                preBufActive = true;
            }
            break;
        case BTN_TAP:
            if ((long)(now - g_aSuppressTapUntilMs) < 0) {
                preBufActive = false;
                Serial.println("[A] suppressed trailing tap after toggle stop");
                break;
            }
            if (isRecording && g_toggleRecording) {
                finishVoiceRecording("toggle tap");
                g_tapA.cancel();
                g_aSuppressTapUntilMs = now + DBL_CLICK_MS;
                break;
            }
            if (g_tapA.onTap(now, DBL_CLICK_MS) == TAP_GESTURE_DOUBLE) {
                if (allowVoice) beginVoiceRecording(true, now);
            }
            break;
        case BTN_HOLD_START:
            g_tapA.cancel();
            if (allowVoice) beginVoiceRecording(false, now);
            break;
        case BTN_HOLD_END:
            if (isRecording && g_holdRecording) finishVoiceRecording("hold release");
            break;
        case BTN_NONE:
            break;
    }

    if (g_tapA.tick(now, DBL_CLICK_MS) == TAP_GESTURE_SINGLE) {
        preBufActive = false;
        if (allowSingleEnter) {
            sendBleCmd(CMD_ENTER);
            led_fire_event(LED_EV_BTN_A);
            Serial.println("[A] single -> Enter");
        } else {
            Serial.println("[A] single suppressed in input assistant");
        }
    }

    if (isRecording && g_toggleRecording && now - g_recStartMs > g_voiceTimeoutMs) {
        snprintf(g_overlayCtx.infoNote, sizeof(g_overlayCtx.infoNote), "%s",
                 i18nText(UI_STR_RECORDING_TIMEOUT_STOPPED));
        finishVoiceRecording("60min timeout");
    }
}

// ══════════════════════════════════════════════════════════
// v1.0.0 输入分发:一级界面 / Prompt 选择 / 文字编辑(REQ-010~013)
// ══════════════════════════════════════════════════════════

// 一级界面：B=DEL/连删/Prompt，C=ESC/App Switcher，D=框选/激活/自定义模式。
static void fireNormalBSingle() {
    sendBleCmd(CMD_BACKSPACE);
    led_fire_event(LED_EV_BTN_B);
    Serial.println("BtnB single -> DEL");
}

static void fireNormalCSingle() {
    if (g_overlayCtx.state == UI_OV_ASR_PROC) {
        sendBleCmd(CMD_BTN_A_PTT_STOP);
        ui_set_overlay(g_overlayCtx, UI_OV_NONE);
        Serial.println("BtnC ESC from ASR_PROC (resent 0x14)");
    } else {
        sendBleCmd(CMD_ESC);
        Serial.println("BtnC single -> ESC");
    }
}

static void handleNormalInput(ButtonEvent b, ButtonEvent c, ButtonEvent sw,
                              int8_t step, unsigned long now) {
    // B：单击 DEL / 双击 Prompt / 长按连续 DEL。
    switch (b) {
        case BTN_TAP:
            if (g_tapB.onTap(now, DBL_CLICK_MS) == TAP_GESTURE_DOUBLE) {
                if (promptRecommendationsEnabled()) {
                    Serial.println("BtnB double -> prompt mode");
                    enterPromptMode();
                } else {
                    Serial.println("BtnB double -> DEL x2 (Laboratory disabled)");
                    fireNormalBSingle();
                    fireNormalBSingle();
                }
            }
            break;
        case BTN_HOLD_START:
            g_tapB.cancel();
            g_bDeleting       = true;
            g_bDelIntervalMs  = B_DEL_START_MS;
            g_bDelCount       = 0;
            g_bDelNextMs      = now;             // 立即删第一个
            g_modeCtx.deleting = true;
            g_modeCtx.delCount = 0;
            Serial.println("BtnB hold -> repeat delete start");
            break;
        case BTN_HOLD_END:
            if (g_bDeleting) {
                g_bDeleting        = false;
                g_modeCtx.deleting = false;
                Serial.printf("BtnB release -> deleted %u chars\n", g_bDelCount);
            }
            break;
        default: break;
    }
    if (g_tapB.tick(now, DBL_CLICK_MS) == TAP_GESTURE_SINGLE) {
        fireNormalBSingle();
    }
    // 连删节拍(300ms 起,×0.85 加速,50ms 下限)
    if (g_bDeleting && (long)(now - g_bDelNextMs) >= 0) {
        sendBleCmd(CMD_BACKSPACE);
        g_bDelCount++;
        g_modeCtx.delCount = g_bDelCount;
        g_bDelIntervalMs = g_bDelIntervalMs * 85 / 100;
        if (g_bDelIntervalMs < B_DEL_MIN_MS) g_bDelIntervalMs = B_DEL_MIN_MS;
        g_bDelNextMs = now + g_bDelIntervalMs;
    }

    // C：单击一次 ESC / 双击两次 ESC / 长按打开设备端 App 列表。
    // 新 Host 会回传列表并接管 D 旋转/确认；老 Host 仍走按住 Cmd-Tab、松开确认。
    switch (c) {
        case BTN_TAP:
            if (g_tapC.onTap(now, DBL_CLICK_MS) == TAP_GESTURE_DOUBLE) {
                if (inputAssistantEnabled()) {
                    Serial.println("BtnC double -> input assistant");
                    enterInputAssistantMode();
                } else {
                    Serial.println("BtnC double -> ESC x2 (Laboratory disabled)");
                    fireNormalCSingle();
                    fireNormalCSingle();
                }
            }
            break;
        case BTN_HOLD_START:
            g_tapC.cancel();
            g_appSwitcherActive = true;
            g_appSwitcherHostAcked = false;
            resetApplicationSwitcherDefinition(g_modeCtx.applicationSwitcher);
            g_modeCtx.applicationSwitcher.loading = true;
            g_appSwitcherRequestMs = g_appSwitcherTouchMs = now;
            setUiMode(DEV_MODE_APP_SWITCHER);
            sendActionEvent(0, ACTION_CONTROL_C, ACTION_GESTURE_HOLD_START);
            Serial.println("BtnC hold -> App list request / legacy switcher begin");
            break;
        case BTN_HOLD_END:
            if (g_appSwitcherActive) {
                g_appSwitcherActive = false;
                sendActionEvent(0, ACTION_CONTROL_C, ACTION_GESTURE_HOLD_END);
                if (g_uiMode == DEV_MODE_APP_SWITCHER) setUiMode(DEV_MODE_NORMAL);
                Serial.println("BtnC release -> legacy App Switcher commit");
            }
            break;
        default:
            break;
    }
    if (g_tapC.tick(now, DBL_CLICK_MS) == TAP_GESTURE_SINGLE) {
        fireNormalCSingle();
    }

    // ── EC11 SW(REQ-012/013):单击 框选确认/激活 / 长按 请求情景模式 ──
    //   ⚠ 行为变化:v0.x 的 SW 短按 = Backspace 已移除(退格改由 B 长按连删承担)
    switch (sw) {
        case BTN_TAP:
            if (!g_listSel.visible) {
                moveFrame(0, now);   // 第一次点按只唤出线框
            } else if (g_listSel.framedIdx >= 0) {
                int si = ui_row_to_session(g_v5, g_listSel.inactiveExpanded, g_listSel.framedIdx);
                if (si == -1) {
                    // T-034:选中"非活跃"标签行 → 单击切换展开/收起(REQ-028 §3)
                    g_listSel.inactiveExpanded = !g_listSel.inactiveExpanded;
                    int total = ui_row_count(g_v5, g_listSel.inactiveExpanded);
                    if (g_listSel.framedIdx > (int8_t)(total - 1)) g_listSel.framedIdx = (int8_t)(total - 1);
                    g_frameTouchMs = now;
                    Serial.printf("[T-034] inactive group %s\n",
                                  g_listSel.inactiveExpanded ? "expanded" : "collapsed");
                } else if (si >= 0) {
                    uint8_t pkt[2] = { CMD_EXCLUSIVE_TOGGLE, (uint8_t)si };   // 发**会话**下标
                    sendBleCmdN(pkt, 2);
                    g_frameTouchMs = now;
                    Serial.printf("Exclusive toggle -> idx %d\n", si);
                }
            }
            break;
        case BTN_HOLD_START:
            sendActionEvent(0, ACTION_CONTROL_D, ACTION_GESTURE_HOLD_START);
            Serial.println("EncSW hold -> request preferred scene mode");
            break;
        default: break;
    }

    // ── EC11 旋转(REQ-013):框选移动(顺时针=向上)──
    //   ⚠ 行为变化:v0.x 的旋转 = CMD_UP/DOWN 直发已移除,改为本地框选
    if (step != 0 && !isRecording) {
        // 主页列表单独反向；Prompt、编辑和情景模式继续使用归一后的物理方向。
        moveFrame((int8_t)-step, now);
    }

    // 框选超时隐藏(5s),隐藏时滚动回顶(静止显示排序前 N 条,REQ-013 决策)
    if (g_listSel.visible && now - g_frameTouchMs > FRAME_HIDE_MS) {
        g_listSel.visible   = false;
        g_listSel.framedIdx = -1;
        g_listSel.scrollTop = 0;
    }
}

static void handleInputAssistantInput(ButtonEvent b, ButtonEvent c, ButtonEvent sw,
                                      int8_t step, unsigned long now) {
    if (!g_assistantHostAcked && now - g_assistantRequestMs > ASSISTANT_LEGACY_FALLBACK_MS) {
        Serial.println("[assistant] old Host fallback -> ESC x2");
        exitInputAssistantMode(); sendBleCmd(CMD_ESC); sendBleCmd(CMD_ESC); return;
    }
    if (c == BTN_TAP) { exitInputAssistantMode(); return; }
    if (g_modeCtx.assistantState == 0) {
        if (now - g_assistantRequestMs > ASSISTANT_LOADING_TIMEOUT_MS) exitInputAssistantMode();
        return;
    }
    if (g_modeCtx.assistantState == 4) {
        if (now - g_assistantStatusMs > 1800) exitInputAssistantMode();
        return;
    }
    if (g_modeCtx.assistantState == 5) {
        if (now - g_assistantStatusMs > 500) exitInputAssistantMode();
        return;
    }
    if (g_modeCtx.assistantState == 3 && now - g_assistantStatusMs > 1200)
        g_modeCtx.assistantState = 1;
    if (g_modeCtx.assistantState != 1 || g_modeCtx.assistantCount == 0) return;
    if (step != 0) {
        int next = g_modeCtx.assistantSel - step;
        if (next < 0) next = 0;
        if (next >= g_modeCtx.assistantCount) next = g_modeCtx.assistantCount - 1;
        g_modeCtx.assistantSel = (int8_t)next; g_assistantTouchMs = now;
    }
    if (b == BTN_TAP && g_modeCtx.assistantSelectedScope) {
        uint8_t pkt[3] = {CMD_INPUT_ASSISTANT_ACTION, g_modeCtx.assistantRequestId, 0xFE};
        sendBleCmdN(pkt, sizeof(pkt)); g_modeCtx.assistantState = 0; return;
    }
    if (sw == BTN_TAP) {
        uint8_t pkt[3] = {CMD_INPUT_ASSISTANT_ACTION, g_modeCtx.assistantRequestId,
                          (uint8_t)g_modeCtx.assistantSel};
        sendBleCmdN(pkt, sizeof(pkt)); g_modeCtx.assistantState = 2; return;
    }
    if (now - g_assistantTouchMs > ASSISTANT_MODE_TIMEOUT_MS) exitInputAssistantMode();
}

// Prompt 选择模式(REQ-011):旋钮选,C 发送,B 退出,15s 超时
static void handlePromptInput(ButtonEvent a, ButtonEvent b, ButtonEvent sw,
                              int8_t step, unsigned long now) {
    (void)a;
    if (g_modeCtx.promptLoading && !g_promptHostAcked &&
        now - g_promptRequestMs > PROMPT_LEGACY_FALLBACK_MS) {
        g_modeCtx.promptDynamic = false;
        g_modeCtx.promptLoading = false;
        g_promptTouchMs = now;
        Serial.println("[prompt] old Host fallback");
    }
    int total = g_modeCtx.promptDynamic ? g_modeCtx.promptCount
                                         : 1 + (g_v5cfg.valid ? g_v5cfg.promptCount : 0);
    if (g_modeCtx.promptLoading) {
        if (b == BTN_TAP || sw == BTN_HOLD_START ||
            now - g_promptRequestMs > PROMPT_LOADING_TIMEOUT_MS) {
            Serial.println("Prompt loading cancelled/timeout");
            exitPromptMode();
        }
        return;
    }
    if (total <= 0) { exitPromptMode(); return; }
    if (step != 0) {
        // 与主页列表一致：归一后的顺时针 step>0 向上移动。
        g_promptSel = promptSelectionAfterRotate(g_promptSel, step, (uint8_t)total);
        g_modeCtx.promptSel = g_promptSel;
        g_promptTouchMs = now;
    }
    if (sw == BTN_TAP) {
        if (g_modeCtx.promptDynamic) {
            uint8_t pkt[3] = { CMD_PROMPT_SELECT, g_modeCtx.promptRequestId,
                               (uint8_t)g_promptSel };
            sendBleCmdN(pkt, sizeof(pkt));
        } else {
            uint8_t pkt[2] = { CMD_PROMPT_SELECT, (uint8_t)g_promptSel };
            sendBleCmdN(pkt, sizeof(pkt));
        }
        Serial.printf("Prompt select -> idx %d\n", (int)g_promptSel);
        exitPromptMode();
        return;
    }
    if (sw == BTN_HOLD_START) {
        Serial.println("Prompt mode exit (EncSW hold)");
        exitPromptMode();
        return;
    }
    if (b == BTN_TAP) {
        Serial.println("Prompt mode cancelled (BtnB)");
        exitPromptMode();
        return;
    }
    if (now - g_promptTouchMs > PROMPT_MODE_TIMEOUT_MS) {
        Serial.println("Prompt mode timeout");
        exitPromptMode();
    }
}

static void exitApplicationSwitcherMode(bool notifyHost) {
    const uint8_t requestId = g_modeCtx.applicationSwitcher.requestId;
    if (notifyHost) resetApplicationSwitcherDefinition(g_modeCtx.applicationSwitcher);
    g_appSwitcherActive = false;
    setUiMode(DEV_MODE_NORMAL);
    if (notifyHost) {
        sendActionEvent(APP_SWITCHER_CONTEXT_ID, ACTION_CONTROL_C, ACTION_GESTURE_HOLD_END);
    }
    Serial.printf("[app-switcher] exit req=%u notify=%u\n", requestId, notifyHost ? 1 : 0);
}

static void handleApplicationSwitcherInput(ButtonEvent c, ButtonEvent sw,
                                           int8_t step, unsigned long now) {
    ApplicationSwitcherDefinition &apps = g_modeCtx.applicationSwitcher;
    if (apps.loading) {
        if (c == BTN_HOLD_END && !g_appSwitcherHostAcked) {
            g_appSwitcherActive = false;
            sendActionEvent(0, ACTION_CONTROL_C, ACTION_GESTURE_HOLD_END);
            resetApplicationSwitcherDefinition(apps);
            setUiMode(DEV_MODE_NORMAL);
            Serial.println("[app-switcher] released before Host response; legacy commit");
            return;
        }
        if (!g_appSwitcherHostAcked &&
            now - g_appSwitcherRequestMs > APP_SWITCHER_LEGACY_FALLBACK_MS) {
            // No new-Host START frame arrived. Return the screen to normal but
            // keep g_appSwitcherActive until C release so the old Cmd-Tab path
            // still commits correctly.
            resetApplicationSwitcherDefinition(apps);
            setUiMode(DEV_MODE_NORMAL);
            Serial.println("[app-switcher] new Host timeout; legacy fallback");
        } else if (g_appSwitcherHostAcked &&
                   now - g_appSwitcherRequestMs > APP_SWITCHER_LOADING_TIMEOUT_MS) {
            Serial.println("[app-switcher] incomplete Host response timeout");
            exitApplicationSwitcherMode(true);
        }
        return;
    }
    if (!apps.valid) return;
    if (step != 0 && apps.count > 0) {
        int next = ((int)apps.selected - (int)step) % (int)apps.count;
        if (next < 0) next += apps.count;
        apps.selected = (int8_t)next;
        g_appSwitcherTouchMs = now;
        sendActionEvent(APP_SWITCHER_CONTEXT_ID, ACTION_CONTROL_D,
                        ACTION_GESTURE_ROTATE, step);
    }
    if (sw == BTN_TAP) {
        sendActionEvent(APP_SWITCHER_CONTEXT_ID, ACTION_CONTROL_D, ACTION_GESTURE_TAP);
        exitApplicationSwitcherMode(false);
        return;
    }
    if (c == BTN_TAP) {
        sendActionEvent(APP_SWITCHER_CONTEXT_ID, ACTION_CONTROL_C, ACTION_GESTURE_TAP);
        exitApplicationSwitcherMode(false);
        return;
    }
    if (now - g_appSwitcherTouchMs > APP_SWITCHER_MODE_TIMEOUT_MS) {
        exitApplicationSwitcherMode(true);
    }
}

// Host 定义的动作模式。快捷键映射完全留在 Mac；固件只上报 B/C/D 手势。
static void handleActionModeInput(ButtonEvent b, ButtonEvent c, ButtonEvent sw,
                                  int8_t step, unsigned long now) {
    const uint8_t modeId = g_modeCtx.actionMode.modeId;

    if (b == BTN_TAP) {
        TapGesture g = g_tapB.onTap(now, DBL_CLICK_MS);
        if (g == TAP_GESTURE_DOUBLE)
            sendActionEvent(modeId, ACTION_CONTROL_B, ACTION_GESTURE_DOUBLE_TAP);
    } else if (b == BTN_HOLD_START) {
        g_tapB.cancel();
        sendActionEvent(modeId, ACTION_CONTROL_B, ACTION_GESTURE_HOLD_START);
        g_actionRepeatB.start(now, B_DEL_START_MS);
    } else if (b == BTN_HOLD_END) {
        g_actionRepeatB.stop();
        sendActionEvent(modeId, ACTION_CONTROL_B, ACTION_GESTURE_HOLD_END);
    }
    if (g_tapB.tick(now, DBL_CLICK_MS) == TAP_GESTURE_SINGLE)
        sendActionEvent(modeId, ACTION_CONTROL_B, ACTION_GESTURE_TAP);

    if (c == BTN_TAP) {
        TapGesture g = g_tapC.onTap(now, DBL_CLICK_MS);
        if (g == TAP_GESTURE_DOUBLE)
            sendActionEvent(modeId, ACTION_CONTROL_C, ACTION_GESTURE_DOUBLE_TAP);
    } else if (c == BTN_HOLD_START) {
        g_tapC.cancel();
        sendActionEvent(modeId, ACTION_CONTROL_C, ACTION_GESTURE_HOLD_START);
        g_actionRepeatC.start(now, B_DEL_START_MS);
    } else if (c == BTN_HOLD_END) {
        g_actionRepeatC.stop();
        sendActionEvent(modeId, ACTION_CONTROL_C, ACTION_GESTURE_HOLD_END);
    }
    if (g_tapC.tick(now, DBL_CLICK_MS) == TAP_GESTURE_SINGLE)
        sendActionEvent(modeId, ACTION_CONTROL_C, ACTION_GESTURE_TAP);

    ActionRepeatState *states[] = { &g_actionRepeatB, &g_actionRepeatC };
    const DeviceActionControl controls[] = { ACTION_CONTROL_B, ACTION_CONTROL_C };
    for (uint8_t i = 0; i < 2; i++) {
        ActionRepeatState &state = *states[i];
        if (!state.tick(now, B_DEL_MIN_MS)) continue;
        sendActionEvent(modeId, controls[i], ACTION_GESTURE_REPEAT);
    }

    if (sw == BTN_HOLD_END) {
        sendActionEvent(modeId, ACTION_CONTROL_D, ACTION_GESTURE_HOLD_END);
        Serial.println("Action mode D released / armed");
        return;
    }
    if (sw == BTN_HOLD_START) {
        cancelPendingTaps();
        sendActionEvent(modeId, ACTION_CONTROL_D, ACTION_GESTURE_HOLD_START);
        Serial.println("Action mode exit request (EncSW hold)");
        return;
    }
    if (sw == BTN_TAP)
        sendActionEvent(modeId, ACTION_CONTROL_D, ACTION_GESTURE_TAP);
    if (step != 0)
        sendActionEvent(modeId, ACTION_CONTROL_D, ACTION_GESTURE_ROTATE, step);
}

// 文字编辑模式(REQ-012;2026-07-10 用户改版按键布局,同日二改:长按 C 取消动作移除):
//   旋钮转 = 左右移光标
//   A: 单击=上 / 双击=发送回车 / 长按=固定 PTT 插入
//   B: 单击=下 / 双击=删左侧字符 / 长按=加速连删(与一级界面同节拍)
//   按旋钮 C = 退出;长按 C = 无动作
static void handleEditInput(ButtonEvent a, ButtonEvent b, ButtonEvent sw,
                            int8_t step, unsigned long now) {
    if (sw == BTN_TAP) {
        Serial.println("EncSW tap -> exit edit mode");
        exitEditMode();
        return;
    }

    // A 单击(双击窗延迟判定)= 上;双击 = 回车
    if (a == BTN_TAP) {
        if (g_tapA.pending && now - g_tapA.lastTapMs <= DBL_CLICK_MS) {
            g_tapA.pending = false;
            sendBleCmd(CMD_ENTER);
            setEditEcho(i18nText(UI_STR_EDIT_ECHO_ENTER));
            Serial.println("Edit: Enter (BtnA double)");
        } else {
            g_tapA.pending   = true;
            g_tapA.lastTapMs = now;
        }
    }
    if (g_tapA.pending && now - g_tapA.lastTapMs > DBL_CLICK_MS) {
        g_tapA.pending = false;
        sendBleCmd(CMD_UP);
        setEditEcho(i18nText(UI_STR_EDIT_ECHO_UP));
        Serial.println("Edit: Up (BtnA single)");
    }

    // B 单击(双击窗延迟判定)= 下;双击 = 删左侧字符;长按 = 加速连删
    if (b == BTN_TAP) {
        if (g_tapB.pending && now - g_tapB.lastTapMs <= DBL_CLICK_MS) {
            g_tapB.pending = false;
            sendBleCmd(CMD_BACKSPACE);
            setEditEcho(i18nText(UI_STR_EDIT_ECHO_DELETE));
            Serial.println("Edit: Backspace (BtnB double)");
        } else {
            g_tapB.pending   = true;
            g_tapB.lastTapMs = now;
        }
    }
    if (g_tapB.pending && now - g_tapB.lastTapMs > DBL_CLICK_MS) {
        g_tapB.pending = false;
        sendBleCmd(CMD_DOWN);
        setEditEcho(i18nText(UI_STR_EDIT_ECHO_DOWN));
        Serial.println("Edit: Down (BtnB single)");
    }
    if (b == BTN_HOLD_START) {
        g_tapB.pending     = false;
        g_bDeleting        = true;
        g_bDelIntervalMs   = B_DEL_START_MS;
        g_bDelCount        = 0;
        g_bDelNextMs       = now;            // 立即删第一个
        g_modeCtx.deleting = true;
        g_modeCtx.delCount = 0;
        setEditEcho(i18nText(UI_STR_EDIT_ECHO_REPEAT_DELETE));
        Serial.println("Edit: BtnB hold -> repeat delete start");
    }
    if (b == BTN_HOLD_END && g_bDeleting) {
        g_bDeleting        = false;
        g_modeCtx.deleting = false;
        Serial.printf("Edit: BtnB release -> deleted %u chars\n", g_bDelCount);
    }
    // 连删节拍(与一级界面同参数:300ms 起,×0.85 加速,50ms 下限)
    if (g_bDeleting && (long)(now - g_bDelNextMs) >= 0) {
        sendBleCmd(CMD_BACKSPACE);
        g_bDelCount++;
        g_modeCtx.delCount = g_bDelCount;
        g_bDelIntervalMs = g_bDelIntervalMs * 85 / 100;
        if (g_bDelIntervalMs < B_DEL_MIN_MS) g_bDelIntervalMs = B_DEL_MIN_MS;
        g_bDelNextMs = now + g_bDelIntervalMs;
    }

    // A 长按 = 固定 PTT(与全局语音模式无关),识别文字插入光标处
    if (a == BTN_HOLD_START && bleConnected && !isRecording) {
        g_tapA.pending = false;   // 长按吞掉未决单击,防 PTT 前误发"上"
        startPTT();
        g_editPtt = true;
        g_recStartMs = now;
        setEditEcho(i18nText(UI_STR_EDIT_ECHO_VOICE));
        Serial.println("Edit: PTT START (fixed hold-to-talk)");
        g_overlayCtx.pttStartMs = now;
        g_overlayCtx.toggleHint = false;
        g_overlayCtx.systemMic  = micSourceIsSystem();   // T-033
        ui_set_overlay(g_overlayCtx, UI_OV_PTT_PRESS);
    }
    if (a == BTN_HOLD_END && g_editPtt && isRecording) {
        stopPTT();
        g_editPtt = false;
        preBufActive = false;
        sendBleCmd(CMD_BTN_A_PTT_STOP);
        Serial.println("Edit: PTT STOP");
        ui_set_overlay(g_overlayCtx, bleConnected ? UI_OV_ASR_PROC : UI_OV_NONE);
    }
    // 旋钮:顺时针=右移光标,逆时针=左移(编辑模式方向约定)
    if (step != 0 && !isRecording) {
        int reps = step > 0 ? step : -step;
        if (reps > 8) reps = 8;
        uint8_t cmd = (step > 0) ? CMD_RIGHT : CMD_LEFT;
        for (int i = 0; i < reps; i++) sendBleCmd(cmd);
        setEditEcho(i18nText(step > 0 ? UI_STR_EDIT_ECHO_RIGHT : UI_STR_EDIT_ECHO_LEFT));
        Serial.printf("Edit: cursor %s x%d\n", step > 0 ? "right" : "left", reps);
    }
}

// ══════════════════════════════════════════════════════════
// REQ-022: 审批模态输入(§B4)——模态内独立分发,不得漏到 PTT/ESC
//   A 仍走全局语义；B 单击 = allow，B 双击 = always_allow；C 单击 = deny。
//   旋钮转 = 全局队列循环；旋钮单击 = dismiss。
// ══════════════════════════════════════════════════════════
static void handleApprovalInput(ButtonEvent b, ButtonEvent c, ButtonEvent sw,
                                int8_t step, unsigned long now) {
    // B:单击 allow / 双击 always_allow。按下即给反馈，补偿 200ms 消歧等待。
    if (b == BTN_RAW_PRESS) g_approvalView.pressFeedbackMs = now;
    if (b == BTN_TAP) {
        if (g_tapB.onTap(now, APV_DBL_CLICK_MS) == TAP_GESTURE_DOUBLE) {
            Serial.println("[apv] BtnB double -> always_allow");
            apvDecide(kApprovalDecisionAlwaysAllow);
        }
    }
    if (g_tapB.tick(now, APV_DBL_CLICK_MS) == TAP_GESTURE_SINGLE) {
        Serial.println("[apv] BtnB single -> allow");
        apvDecide(kApprovalDecisionAllow);
    }

    if (c == BTN_TAP) {
        // C 没有双击语义；快速连按也只拒绝当前一项，避免误伤队列下一项。
        if (g_tapC.onTap(now, APV_DBL_CLICK_MS) == TAP_GESTURE_DOUBLE) {
            Serial.println("[apv] BtnC double -> one deny");
            apvDecide(kApprovalDecisionDeny);
        }
    }
    if (g_tapC.tick(now, APV_DBL_CLICK_MS) == TAP_GESTURE_SINGLE) {
        Serial.println("[apv] BtnC single -> deny");
        apvDecide(kApprovalDecisionDeny);
    }

    if (sw == BTN_TAP) {
        Serial.println("[apv] EncSW -> dismiss/local close");
        apvDismissOrClose();
    }

    // 旋钮转动:全局队列循环切换(REQ-022 B4 决策:不按会话分组)
    if (step != 0) {
        int reps = step > 0 ? step : -step;
        if (reps > 8) reps = 8;
        for (int i = 0; i < reps; i++) {
            if (step > 0) g_approvalQueue.moveNext();
            else          g_approvalQueue.movePrev();
        }
    }
    // B/C 长按等其余事件在审批模态内无功能，静默吞掉。
}

// 全屏运输模式确认页是严格模态：只接受 B 单击确认、C 单击取消。A、D、旋转及
// B/C 的长按/双击都被吞掉，不得泄漏到录音、情景模式或 Mac 快捷键。
static void handleShipModeConfirmInput(ButtonEvent b, ButtonEvent c) {
    if (g_overlayCtx.shipModeState == UI_SHIP_ENTERING) return;
    if (b == BTN_TAP) {
        if (power_is_usb_powered()) {
            g_overlayCtx.shipModeState = UI_SHIP_USB_BLOCKED;
            lastDashboardRenderMs = 0;
            Serial.println("[ship] blocked: unplug USB first");
            return;
        }
        if (!power_prepare_ship_mode()) {
            g_overlayCtx.shipModeState = UI_SHIP_ERROR;
            lastDashboardRenderMs = 0;
            Serial.println("[ship] REG07 prepare/readback failed");
            return;
        }
        g_overlayCtx.shipModeState = UI_SHIP_ENTERING;
        g_shipModeCommitPending = true;
        g_shipModeCommitAtMs = millis() + SHIP_MODE_FINAL_NOTICE_MS;
        lastDashboardRenderMs = 0;
        Serial.println("[ship] prepared; final BATFET_DIS write scheduled");
    } else if (c == BTN_TAP) {
        cancelPendingTaps();
        g_shipModeCommitPending = false;
        g_overlayCtx.shipModeState = UI_SHIP_READY;
        ui_set_overlay(g_overlayCtx, UI_OV_NONE);
        Serial.println("[ship] cancelled by Button C");
    }
}

// REQ-022 每帧任务:tick 驱动重发/过期 → 消费动作与事件;同步渲染视图;
// B2 延迟进入(EDIT/PROMPT/录音退出后自动进模态)与队列清空退出。
static void approvalTask(unsigned long now) {
    ApprovalTickResult t = g_approvalQueue.tick(now);
    for (uint8_t i = 0; i < t.sendCount; i++)  apvSend36(t.sends[i]);
    for (uint8_t i = 0; i < t.eventCount; i++) apvFireEvent(t.events[i].event, t.events[i].reqId);

    if (g_uiMode == DEV_MODE_APPROVAL && g_approvalQueue.empty()) {
        exitApprovalMode();                      // 队列空 → 退出模态
    } else if (!g_approvalQueue.empty() && apvCanEnterNow()) {
        enterApprovalMode();                     // 忙态解除后自动进入(B2)
    }

    // ── 渲染视图同步(ApprovalQueue → ApprovalUiView;渲染侧只读)──
    const ApprovalEntry *e = g_approvalQueue.current();
    if (e == nullptr) {
        g_approvalView.active = false;
        return;
    }
    g_approvalView.active         = true;
    g_approvalView.reqId          = e->req.reqId;
    g_approvalView.agentId        = e->req.agentId;
    g_approvalView.riskLevel      = e->req.riskLevel;
    g_approvalView.truncated      = e->req.truncated();
    g_approvalView.notifyOnly     = e->req.notifyOnly();
    g_approvalView.alwaysDisabled = e->req.alwaysDisabled();
    g_approvalView.state          = (uint8_t)e->state;
    memcpy(g_approvalView.sessName, e->req.sessName, e->req.sessNameLen);
    g_approvalView.sessName[e->req.sessNameLen] = 0;
    memcpy(g_approvalView.tool, e->req.tool, e->req.toolLen);
    g_approvalView.tool[e->req.toolLen] = 0;
    memcpy(g_approvalView.body, e->req.body, e->req.bodyLen);
    g_approvalView.body[e->req.bodyLen] = 0;
    long remain = (long)(e->expiresAtMs - now);
    g_approvalView.remainMs = (remain > 0) ? (uint32_t)remain : 0;
    g_approvalView.index1   = (uint8_t)(g_approvalQueue.currentIndex() + 1);
    g_approvalView.total    = g_approvalQueue.size();
}

// ── REQ-022 串口测试命令(实机验证:APV <hex> 注入 0x55/0x56 / APV? 队列状态 / APVTX)──
static int apvHexToBytes(const char *hex, uint8_t *out, size_t cap) {
    int n = 0;
    int hi = -1;
    for (const char *p = hex; *p; p++) {
        char c = *p;
        int v;
        if (c >= '0' && c <= '9')      v = c - '0';
        else if (c >= 'a' && c <= 'f') v = c - 'a' + 10;
        else if (c >= 'A' && c <= 'F') v = c - 'A' + 10;
        else if (c == ' ')             continue;   // 容忍空格分隔
        else return -1;                            // 非法字符
        if (hi < 0) {
            hi = v;
        } else {
            if ((size_t)n >= cap) return -2;       // 超缓冲
            out[n++] = (uint8_t)((hi << 4) | v);
            hi = -1;
        }
    }
    if (hi >= 0) return -1;                        // 奇数个 hex 字符
    return n;
}

static void apvDumpStatus() {
    unsigned long now = millis();
    Serial.printf("[apv] queue count=%u cur=%u uiMode=%u\n",
                  g_approvalQueue.size(), g_approvalQueue.currentIndex(), (unsigned)g_uiMode);
    static const char *kSt[] = { "ACTIVE", "AWAIT_ACK", "SEND_FAILED" };
    for (uint8_t i = 0; i < g_approvalQueue.size(); i++) {
        const ApprovalEntry *e = g_approvalQueue.entryAt(i);
        if (e == nullptr) continue;
        char tool[kApprovalToolMax + 1];
        memcpy(tool, e->req.tool, e->req.toolLen);
        tool[e->req.toolLen] = 0;
        long remain = (long)(e->expiresAtMs - now);
        Serial.printf("[apv]  [%u]%c reqId=%u st=%s risk=%u flags=0x%02X resend=%u remain=%lds tool=\"%s\"\n",
                      i, (i == g_approvalQueue.currentIndex()) ? '*' : ' ',
                      e->req.reqId, kSt[(uint8_t)e->state], e->req.riskLevel, e->req.flags,
                      e->resendCount, remain / 1000, tool);
    }
}

// REQ-021: RSSI(dBm)→ 信号格(1..4),阈值附近 ±3dB 死区防边界闪格。
//   阈值 th[]:1/2 格边界 -84,2/3 格边界 -72,3/4 格边界 -60。已连接至少 1 格。
static uint8_t rssiToBarsHysteresis(int8_t rssi, uint8_t cur) {
    static const int8_t th[3] = { -84, -72, -60 };
    const int8_t DZ = 3;
    if (cur < 1) cur = 1;
    if (cur > 4) cur = 4;
    while (cur < 4 && rssi >= th[cur - 1] + DZ) cur++;   // 升格需越过上边界 +DZ
    while (cur > 1 && rssi <  th[cur - 2] - DZ) cur--;   // 降格需跌破下边界 -DZ
    return cur;
}

void loop() {
    g_bb.offStep = 33;   // 标记:loop 顶(SLPIN/唤醒/按键/BLE 命令/渲染区)
    micstickOta.loop();
    if (micstickOta.active()) {
        isRecording = false;
        preBufActive = false;
        static unsigned long otaUiLastMs = 0;
        static uint8_t otaUiLastProgress = 0xFF;
        static bool otaUiLastFinalizing = false;
        const uint8_t otaProgress = micstickOta.progress_percent();
        const bool otaFinalizing = micstickOta.finalizing();
        const unsigned long otaUiNow = millis();
        if (otaProgress != otaUiLastProgress ||
            otaFinalizing != otaUiLastFinalizing ||
            otaUiNow - otaUiLastMs >= 1000) {
            ui_render_firmware_update(otaProgress, otaFinalizing);
            otaUiLastProgress = otaProgress;
            otaUiLastFinalizing = otaFinalizing;
            otaUiLastMs = otaUiNow;
        }
        vTaskDelay(pdMS_TO_TICKS(1));
        esp_task_wdt_reset();
        wdt_hal_write_protect_disable(&g_rwdt);
        wdt_hal_feed(&g_rwdt);
        wdt_hal_write_protect_enable(&g_rwdt);
    } else {

    // REQ-003 Phase 2 (2026-05-03): 进入 OFF 时给 TFT 发 DISPOFF(0x28) + SLPIN(0x10)
    //   - ST7789 IC 进 sleep mode 后从 ~50mA 降到 ~3µA
    //   - GPIO 15 保持 HIGH,IC 持续供电,framebuffer 不丢失
    if (power_check_enter_off()) {
        g_bb.offStep = 10;
        tft.writecommand(0x28);          // DISPOFF
        tft.writecommand(0x10);          // SLPIN
        g_bb.offStep = 11;
        Serial.println("[sleep] TFT DISPOFF + SLPIN sent");
        g_bb.offStep = 12;
    }

    // REQ-003 Phase 2: 唤醒时发 SLPOUT(0x11) + DISPON(0x29),保留 framebuffer 内容
    //   - SLPOUT 后 datasheet 要求 ≥120ms 才能发后续命令
    if (power_check_wake_reinit()) {
        g_bb.offStep = 13;
        tft.writecommand(0x11);          // SLPOUT
        delay(120);                      // datasheet 强制等待
        tft.writecommand(0x29);          // DISPON
        lastDashboardRenderMs = 0;       // 强制下一帧重绘 sprite
        g_bb.offStep = 14;
        Serial.println("[wake] TFT SLPOUT + DISPON sent");
    }

    handleSerialCommands();
    applyPendingUiLocale();

    // 不打断录音、识别结果页或审批决策；请求保持待处理，待现有模态结束后
    // 自动弹出。Prompt/编辑/情景模式可被全屏页暂时覆盖，取消后原样返回。
    if (g_pendingShipModeRequest.load(std::memory_order_acquire) &&
        !isRecording && g_overlayCtx.state == UI_OV_NONE &&
        g_uiMode != DEV_MODE_APPROVAL) {
        g_pendingShipModeRequest.store(false, std::memory_order_release);
        cancelPendingTaps();
        if (g_appSwitcherActive) {
            // 先释放 Host 侧持有的 Command，避免关机确认页出现后组合键卡住。
            g_appSwitcherActive = false;
            sendActionEvent(0, ACTION_CONTROL_C, ACTION_GESTURE_HOLD_END);
        }
        if (g_uiMode == DEV_MODE_APP_SWITCHER) {
            sendActionEvent(APP_SWITCHER_CONTEXT_ID, ACTION_CONTROL_C, ACTION_GESTURE_HOLD_END);
            resetApplicationSwitcherDefinition(g_modeCtx.applicationSwitcher);
            setUiMode(DEV_MODE_NORMAL);
        }
        power_note_activity();
        g_shipModeCommitPending = false;
        g_overlayCtx.shipModeState = UI_SHIP_READY;
        ui_set_overlay(g_overlayCtx, UI_OV_SHIP_CONFIRM);
    }

    // 用户拔掉 USB 后恢复普通确认文案；仍须再次按 B，避免拔线自动进入运输模式。
    if (g_overlayCtx.state == UI_OV_SHIP_CONFIRM &&
        g_overlayCtx.shipModeState == UI_SHIP_USB_BLOCKED &&
        !power_is_usb_powered()) {
        g_overlayCtx.shipModeState = UI_SHIP_READY;
        lastDashboardRenderMs = 0;
        Serial.println("[ship] USB removed; confirmation enabled");
    }

    if (g_actionModeExitOnDisconnect.exchange(false, std::memory_order_acq_rel) &&
        (g_uiMode == DEV_MODE_ACTION || g_uiMode == DEV_MODE_APP_SWITCHER)) {
        cancelPendingTaps();
        g_modeCtx.actionMode = ActionModeDefinition{};
        resetApplicationSwitcherDefinition(g_modeCtx.applicationSwitcher);
        g_appSwitcherActive = false;
        setUiMode(DEV_MODE_NORMAL);
        Serial.println("Action/App-switcher mode cleared after BLE disconnect");
    }

    if (g_laboratoryModeExitPending.exchange(false, std::memory_order_acq_rel)) {
        if (g_uiMode == DEV_MODE_PROMPT && !promptRecommendationsEnabled()) {
            exitPromptMode();
            Serial.println("Prompt mode closed because Laboratory feature was disabled");
        } else if (g_uiMode == DEV_MODE_INPUT_ASSISTANT && !inputAssistantEnabled()) {
            exitInputAssistantMode();
            Serial.println("Input assistant closed because Laboratory feature was disabled");
        }
    }

    // REQ-022:BLE 收到的审批帧在这里(loop 单任务)消费,ApprovalQueue 无跨任务并发
    apvDrainRx();
    taskLifecycleDrainRx();

    // BUG-032:识别等待页 30s 超时自愈 —— 0x06/0x07 回执丢失或 Mac 侧卡死时,
    // 设备不再永久停留"正在识别"(实测卡过 4 分半),超时切失败页 2s 后自动回主页。
    if (g_overlayCtx.state == UI_OV_ASR_PROC &&
        millis() - g_overlayCtx.overlayStartMs > 30000UL) {
        strncpy(g_overlayCtx.asrFailMsg, i18nText(UI_STR_RECOGNITION_TIMEOUT),
                sizeof(g_overlayCtx.asrFailMsg) - 1);
        g_overlayCtx.asrFailMsg[sizeof(g_overlayCtx.asrFailMsg) - 1] = 0;
        g_overlayCtx.asrFailExpireMs = millis() + ASR_FEEDBACK_HOLD_MS;
        ui_set_overlay(g_overlayCtx, UI_OV_ASR_FAILURE);
        led_fire_event(LED_EV_ASR_FAILURE);
        Serial.println("[BUG-032] ASR_PROC timeout (30s) -> local escape");
    }

    ButtonEvent eventA     = updateButton(btnA);
    ButtonEvent eventB     = updateButton(btnB);
    ButtonEvent eventEncSw = updateButton(btnEncSw, ENC_SW_HOLD_THRESH_MS);
    ButtonEvent eventC     = BTN_NONE;
#ifdef PIN_BUTTON_C
    eventC = updateButton(btnC);
#endif
    ButtonEvent eventSide = BTN_NONE;
#ifdef PIN_SIDE_BUTTON
    eventSide = updateButton(btnSide, SIDE_BUTTON_HOLD_THRESH_MS);
#endif

    // plan v4: EC11 旋转累积值,从 ISR 原子拿走再清零
    int8_t encStep = 0;
    noInterrupts();
    if (encDelta != 0) { encStep = encDelta; encDelta = 0; }
    interrupts();

    // 合成输入注入(串口 TAP/HOLD/REL/ENC,与物理按键同一路径)
    if (g_synthA  != BTN_NONE) { eventA = g_synthA;      g_synthA  = BTN_NONE; }
    if (g_synthB  != BTN_NONE) { eventB = g_synthB;      g_synthB  = BTN_NONE; }
    if (g_synthC  != BTN_NONE) { eventC = g_synthC;      g_synthC  = BTN_NONE; }
    if (g_synthSw != BTN_NONE) { eventEncSw = g_synthSw; g_synthSw = BTN_NONE; }
    if (g_synthEnc != 0)       { encStep += g_synthEnc;  g_synthEnc = 0; }

    // ── Stage 4: 屏幕关闭吞键守卫 + activity 触发 ──
    // 任一按键/编码器事件经过 wake guard(PWR_OFF 时吞掉本轮只唤屏)。
    // BtnA/BtnB/旋钮 都视为真实用户操作,刷 activity 计时器。
    // 旧的 floating Up/Dn 误触隐患已随按键模块下马消除(EC11 静止 detent 稳定 HIGH)。
    bool anyEvent = (eventA != BTN_NONE) || (eventB != BTN_NONE) ||
                    (eventC != BTN_NONE) || (eventEncSw != BTN_NONE) ||
                    (eventSide != BTN_NONE) || (encStep != 0);
    if (anyEvent) {
        if (power_consume_wake_event()) {
            eventA = eventB = eventC = eventEncSw = BTN_NONE;
            eventSide = BTN_NONE;
            encStep = 0;
        }
        if (eventA != BTN_NONE || eventB != BTN_NONE || eventC != BTN_NONE ||
            eventEncSw != BTN_NONE || eventSide != BTN_NONE || encStep != 0) {
            power_note_activity();
        }
    }

#ifdef PIN_SIDE_BUTTON
    if (eventSide == BTN_HOLD_START &&
        g_overlayCtx.state != UI_OV_SHIP_CONFIRM && !g_shipModeCommitPending) {
        // Reuse the host-command entry and its busy-state deferral. A physical
        // SW1 hold may request the page, but B is still required for BATFET_DIS.
        g_pendingShipModeRequest.store(true, std::memory_order_release);
        Serial.println("[ship] V14 side SW1 hold -> confirmation requested");
    }
#endif

    // ── v1.0.0 输入分发(REQ-010~013):按设备 UI 模式路由 ──
    //   旋钮方向归一:step>0 = 物理顺时针,ENC_INVERT 抹平板级相位差；各模式自行映射语义
    {
        unsigned long nowIn = millis();
        int8_t step = ENC_INVERT ? (int8_t)-encStep : encStep;
        if (g_overlayCtx.state == UI_OV_SHIP_CONFIRM) {
            handleShipModeConfirmInput(eventB, eventC);
        } else if (g_appSwitcherActive && g_uiMode != DEV_MODE_APP_SWITCHER) {
            // Command 被 Host 持有期间只允许 C 松开，避免 A/B/D 被解释成 Cmd+组合键。
            if (eventC == BTN_HOLD_END) {
                g_appSwitcherActive = false;
                sendActionEvent(0, ACTION_CONTROL_C, ACTION_GESTURE_HOLD_END);
                Serial.println("BtnC release -> App Switcher commit");
            }
        } else {
            bool assistant = g_uiMode == DEV_MODE_INPUT_ASSISTANT;
            bool assistantVoiceReady = assistant && g_modeCtx.assistantState == 1;
            handleGlobalA(eventA, nowIn, !assistant, !assistant || assistantVoiceReady);
            switch (g_uiMode) {
                case DEV_MODE_PROMPT:
                    handlePromptInput(BTN_NONE, eventB, eventEncSw, step, nowIn);
                    break;
                case DEV_MODE_EDIT:
                    handleEditInput(BTN_NONE, eventB, eventEncSw, step, nowIn);
                    break;
                case DEV_MODE_ACTION:
                    handleActionModeInput(eventB, eventC, eventEncSw, step, nowIn);
                    break;
                case DEV_MODE_APPROVAL:
                    handleApprovalInput(eventB, eventC, eventEncSw, step, nowIn);
                    break;
                case DEV_MODE_INPUT_ASSISTANT:
                    handleInputAssistantInput(eventB, eventC, eventEncSw, step, nowIn);
                    break;
                case DEV_MODE_APP_SWITCHER:
                    handleApplicationSwitcherInput(eventC, eventEncSw, step, nowIn);
                    break;
                default:
                    handleNormalInput(eventB, eventC, eventEncSw, step, nowIn);
                    break;
            }
        }

        // REQ-022:审批队列每帧推进(重发/过期/延迟进入/视图同步)
        approvalTask(nowIn);

        // REQ-022 音效批次:会话状态边沿检测(任务级音效;审批类音效优先级更高,
        // 冲突时任务类在 buzzer_play 内被丢弃)
        sessionEdgeScan();
    }

    // ── Stage 2: CMD_REQUEST_STATUS 30s 轮询(连续 3 次未收到回包退避到 60s) ──
    if (bleConnected) {
        unsigned long now = millis();
        if (now - lastStatusReqMs >= currentPollIvlMs) {
            sendBleCmd(CMD_REQUEST_STATUS);
            lastStatusReqMs = now;
            statusFailCount++;  // 收到 ClaudeStatus notify 时清零
            if (statusFailCount >= STATUS_POLL_BACKOFF_THRESHOLD) {
                currentPollIvlMs = STATUS_POLL_BACKOFF_MS;
            }
            Serial.printf("Status req sent (fail=%d, interval=%lums)\n",
                          statusFailCount, currentPollIvlMs);
        }
    }

    // Stage 2: 透明 toast/feedback 过期清理(目前只清 active 标记,屏幕在 Stage 3 渲染)
    {
        unsigned long now = millis();
        if (g_permToast.active && (long)(now - g_permToast.expiresAt) >= 0) {
            g_permToast.active = false;
        }
        if (g_asrFeedback.active && (long)(now - g_asrFeedback.expiresAt) >= 0) {
            g_asrFeedback.active = false;
        }
    }

    // ── Stage 3b: overlay 过期回 Dashboard ──
    //   ASR_SUCCESS / ASR_FAILURE → 2s 后回 NONE
    //   PTT_PRESS / ASR_PROC 永不自动消失(在 BTN_HOLD_END / VOICE_NOTIFY 切换)
    {
        unsigned long now = millis();
        if ((g_overlayCtx.state == UI_OV_ASR_SUCCESS ||
             g_overlayCtx.state == UI_OV_ASR_FAILURE) &&
            (long)(now - g_overlayCtx.asrFailExpireMs) >= 0) {
            ui_set_overlay(g_overlayCtx, UI_OV_NONE);
        }
    }

    // ── REQ-021: BLE RSSI 采样(~1s 一次)→ EMA + 信号格滞回 ──
    static int8_t  s_rssiEma   = 0;
    static uint8_t s_bleBars   = 0;
    static unsigned long s_lastRssiMs = 0;
    if (bleConnected && s_bleConnHandle != 0xFFFF && millis() - s_lastRssiMs > 1000) {
        s_lastRssiMs = millis();
        int8_t r = 0;
        if (ble_gap_conn_rssi(s_bleConnHandle, &r) == 0) {
            s_rssiEma = (s_rssiEma == 0) ? r : (int8_t)(0.3f * r + 0.7f * s_rssiEma);
            s_bleBars = rssiToBarsHysteresis(s_rssiEma, s_bleBars);
        }
    }
    if (!bleConnected) { s_bleBars = 0; s_rssiEma = 0; }

    // ── Stage 3a/3b: 渲染调度(主界面 ≤10Hz;splash 期间 20Hz 跑品牌动效)──
    // REQ-003 Phase 1b: light sleep(PWR_OFF)期间 TFT 已断电,不渲染省时间 + 防潜在写空 IC 寄存器
    if (!power_is_sleeping()) {
        unsigned long now = millis();
        // splash 判据须与 ui_render 实际走 splash 分支一致:除"无有效 v5 数据"外,
        // 还要求无 overlay(刚连接未收首帧时按 PTT 录音 = overlay 活跃 + BLE 音频流,
        // 此时必须维持 10Hz 防中断冲突,code review HIGH)且非审批模态
        bool splashActive = !g_v5.valid && g_overlayCtx.state == UI_OV_NONE &&
                            g_modeCtx.mode != DEV_MODE_APPROVAL;
        unsigned long renderInterval = (splashActive || g_splashDemo)
                                       ? 50 : DASHBOARD_RENDER_INTERVAL_MS;
        if (now - lastDashboardRenderMs >= renderInterval) {
            lastDashboardRenderMs = now;
            // REQ-021: 平滑电量 + 充电三态(充电中冻结不虚跳);REQ-021: BLE 信号格
            BatteryInfo bat = { power_get_battery_pct_smoothed(),
                                power_get_charge_state() == PWR_CHG_CHARGING,
                                power_get_charge_state() == PWR_CHG_FULL,
                                power_has_battery_percentage(),
                                power_charger_reachable(),
                                power_has_fault(),
                                power_get_battery_thermal_state() };
            int topMin = -1;
            if (g_haveTime) {
                uint32_t elapsedMin = (uint32_t)((millis() - g_timeBaseMs) / 60000UL);
                topMin = (int)((g_timeBaseMin + elapsedMin) % 1440);
            }
            // 录音页电平/波形快照(volatile → 局部,同帧内数值稳定)
            VoiceMeterView vm;
            vm.db10 = displayLevelDb10;
            for (int i = 0; i < 21; i++) vm.waveform[i] = displayWaveform[i];
            if (!isRecording || !bleConnected) {   // 非录音期/BLE 断开清零(断开时 audioTask 停更,避免冻结残影)
                vm.db10 = -600;
                memset(vm.waveform, 0, sizeof(vm.waveform));
            }
            // SPL 演示:压掉 v5 数据 + 覆写连接态,强制走 splash 分支(布局验证)
            static const V5Status kEmptySt = {};
            const V5Status &rSt = g_splashDemo ? kEmptySt : g_v5;
            bool rConn = g_splashDemo ? (g_splashDemo == 2) : bleConnected;
            ui_render(rSt, bat, FW_VERSION_STR, s_bleBars,
                      g_overlayCtx, g_permToast, rConn, devName,
                      g_listSel, g_v5cfg, g_modeCtx, topMin, vm);
        }
    }

    // ── dip 追踪器(0.6.8):每迭代采样分配器终身最小值,新低即记录现场 ──
    {
        uint32_t mh = (uint32_t)esp_get_minimum_free_heap_size();
        if (g_bb.dipMin == 0) g_bb.dipMin = mh;
        if (mh < g_bb.dipMin) {
            uint32_t drop = g_bb.dipMin - mh;
            g_bb.dipMin  = mh;
            g_bb.dipUp   = millis();
            g_bb.dipStep = g_bb.offStep;
            g_bb.dipLarg = (uint32_t)heap_caps_get_largest_free_block(MALLOC_CAP_INTERNAL | MALLOC_CAP_8BIT);
            if (drop > 20000) {
                Serial.printf("[dip] min=%luk (-%luk) up=%lus step=%u larg=%luk\n",
                              (unsigned long)(mh / 1024), (unsigned long)(drop / 1024),
                              (unsigned long)(millis() / 1000), g_bb.dipStep,
                              (unsigned long)(g_bb.dipLarg / 1024));
            }
        }
    }

    // ── 0.6.9:堆完整性周期校验(heap corruption 假设验证)──
    {
        static uint32_t s_lastIntegrity = 0;
        if (millis() - s_lastIntegrity >= 10000UL) {
            s_lastIntegrity = millis();
            if (!heap_caps_check_integrity_all(true)) {
                g_bb.offStep = 66;   // 专用标记:完整性校验失败
                Preferences cp;
                if (cp.begin("bb", false)) {
                    char note[48];
                    snprintf(note, sizeof(note), "heapCorrupt up=%lus",
                             (unsigned long)(millis() / 1000));
                    cp.putString("corrupt", note);
                    cp.end();
                }
                Serial.printf("[bb] HEAP INTEGRITY FAIL up=%lus\n",
                              (unsigned long)(millis() / 1000));
            }
        }
    }

    // ── 黑匣子 30s 记帧 + 喂 task WDT + 3s 补发取证行(插 USB 晚开串口也能看到)──
    {
        static unsigned long s_lastBbFrame = 0;
        static bool s_bbReprinted = false;
        if (!s_bbReprinted && millis() > 3000) {
            s_bbReprinted = true;
            Serial.printf("[bb] %s | %s%s%s\n", g_bbDiag1, g_bbDiag2,
                          g_bbDiag3[0] ? " | " : "", g_bbDiag3);
        }
        if (millis() - s_lastBbFrame >= 30000UL) {
            s_lastBbFrame = millis();
            g_bb.upMs     = millis();
            g_bb.batMv    = power_get_voltage_mv();
            g_bb.bleConn  = bleConnected ? 1 : 0;
            g_bb.pwrLabel = (uint8_t)power_get_label();
            uint32_t mh = (uint32_t)ESP.getMinFreeHeap();
            g_bb.minHeap = mh;
            // ── 0.6.6:每 2 帧(60s)落盘 flash(NVS)——RTC 被抹也丢不了 ──
            //   记堆轨迹(泄漏/碎片化取证)+ 存活时刻;1440 写/天,NVS 损耗可忽略
            static uint8_t s_flushCnt = 0;
            if (++s_flushCnt >= 2) {
                s_flushCnt = 0;
                uint32_t lb = (uint32_t)heap_caps_get_largest_free_block(MALLOC_CAP_INTERNAL | MALLOC_CAP_8BIT);
                uint32_t fh = (uint32_t)ESP.getFreeHeap();
                Preferences ap;
                if (ap.begin("bb", false)) {
                    ap.putUInt("aUp", millis() / 1000);
                    ap.putUInt("aMinH", mh);
                    ap.putUInt("aFree", fh);
                    ap.putUInt("aLarg", lb);
                    ap.putUChar("aSt", (uint8_t)(g_bb.pwrLabel | (g_bb.bleConn ? 0x80 : 0)));
                    ap.end();
                }
                // ── 堆地板保护:泄漏/碎片化演变成 panic 之前,主动留证优雅重启 ──
                //   (panic 路径会自关看门狗+打印堵死 → 永冻;这里绕开它)
                if (fh < 20000 || lb < 8192) {
                    Preferences gp;
                    if (gp.begin("bb", false)) {
                        char note[64];
                        snprintf(note, sizeof(note), "heapGuard up=%lus free=%lu larg=%lu",
                                 (unsigned long)(millis() / 1000), (unsigned long)fh, (unsigned long)lb);
                        gp.putString("guard", note);
                        gp.end();
                    }
                    Serial.printf("[bb] HEAP GUARD 触发,优雅重启: free=%lu larg=%lu\n",
                                  (unsigned long)fh, (unsigned long)lb);
                    delay(50);
                    esp_restart();
                }
            }
            // 泄漏浸泡诊断:每 10 帧(5min)报一次堆水位(电池上无主机自动丢弃)
            static uint8_t s_hb = 0;
            if (++s_hb >= 10) {
                s_hb = 0;
                Serial.printf("[bb] heap free=%u min=%u up=%lum\n",
                              (unsigned)ESP.getFreeHeap(), (unsigned)mh,
                              (unsigned long)(millis() / 60000UL));
            }
        }
        esp_task_wdt_reset();
        wdt_hal_write_protect_disable(&g_rwdt);
        wdt_hal_feed(&g_rwdt);
        wdt_hal_write_protect_enable(&g_rwdt);
    }

    // ── Stage 4: REQ-029 电源状态机推进 ──
    g_bb.offStep = 1;
    power_tick();
    g_bb.offStep = 2;

    // 运输模式最终写入前保留 500ms 给屏幕呈现不可逆提示。若期间重新插入
    // USB，则撤销提交并要求拔线后重新按 B，避免 VBUS 供电下进入半关闭状态。
    if (g_shipModeCommitPending) {
        if (power_is_usb_powered()) {
            g_shipModeCommitPending = false;
            power_cancel_ship_mode();
            g_overlayCtx.shipModeState = UI_SHIP_USB_BLOCKED;
            lastDashboardRenderMs = 0;
            Serial.println("[ship] disarmed: USB power returned");
        } else if ((long)(millis() - g_shipModeCommitAtMs) >= 0) {
            g_shipModeCommitPending = false;
            if (!power_enter_ship_mode("user confirmed transport mode")) {
                g_overlayCtx.shipModeState = UI_SHIP_ERROR;
                lastDashboardRenderMs = 0;
            }
        }
    }

    // 真实录音仍可短暂延迟 L3；远程 overlay/审批不是物理用户活动，不得让设备
    // 无限停在 L2。不要在这里 stop/disconnect 业务驱动：audioTask 在 L2 已经
    // uninstall I2S，再次 i2s_stop 会触发 PANIC（V13 实板黑匣子 stage 41）。
    // GPIO9 即将切断整条 3.3V，优先走最短、无竞态的不可逆关断路径。
    const bool l3Busy = isRecording;
    if (g_forcedStandbyPending &&
        (long)(millis() - g_forcedStandbyDeadlineMs) >= 0 && !l3Busy) {
        g_forcedStandbyPending = false;
        prepareL3RailDischargeLoad();
        g_bb.offStep = 40;
        power_enter_deep_standby("scheduled serial STANDBY", &g_bb.offStep);
    }
    if (power_deep_standby_due() && !l3Busy) {
        prepareL3RailDischargeLoad();
        g_bb.offStep = 40;
        power_enter_deep_standby("REQ-029 L3 due", &g_bb.offStep);
    }

    // ── REQ-003 Phase 2.2 (2026-05-03): light sleep 入口/出口管理 ──
    //   进 OFF:BLE conn 切 100ms 长间隔 + LED 静态弱光点 + 准备 light sleep
    //   出 OFF:BLE conn 切回 15ms 快连接 + LED 恢复正常动画
    //   注:OFF 已经 60s 后才进,Mac discovery 早就稳了,conn 切换不会跟 GATT 冲突
    static bool wasSleeping = false;
    static uint16_t appliedCpuMhz = 240;
    bool nowSleeping = power_is_sleeping();
    uint16_t targetCpuMhz = power_get_cpu_target_mhz();

    if (targetCpuMhz != appliedCpuMhz) {
        setCpuFrequencyMhz(targetCpuMhz);
        appliedCpuMhz = targetCpuMhz;
        Serial.printf("[pm] CPU -> %u MHz\n", (unsigned)targetCpuMhz);
    }

    if (nowSleeping && !wasSleeping) {
        // 刚进 OFF — CPU 240→80MHz + BLE conn 拉长
        g_bb.offStep = 20;
        g_bb.offStep = 21;
        if (bleConnected && s_bleConnHandle != 0xFFFF) {
            pServer->updateConnParams(s_bleConnHandle, 80, 100, 0, 600);
            g_bb.offStep = 22;
            Serial.println("[ble] conn -> 100ms (entering sleep)");
        }
        Serial.printf("[pm] entering sleep, CPU now %d MHz\n", getCpuFrequencyMhz());
        g_bb.offStep = 0;   // OFF 切换路径走完
    } else if (!nowSleeping && wasSleeping) {
        // 刚出 OFF — CPU 切回 240MHz + BLE conn 切回快
        if (bleConnected && s_bleConnHandle != 0xFFFF) {
            pServer->updateConnParams(s_bleConnHandle, 12, 15, 0, 400);
            Serial.println("[ble] conn -> 15ms (waking)");
        }
        Serial.printf("[pm] waking, CPU now %d MHz\n", getCpuFrequencyMhz());
    }
    wasSleeping = nowSleeping;

    static unsigned long lastBleAdvDiagMs = 0;
    unsigned long bleDiagNow = millis();
    if (!bleConnected && bleDiagNow - lastBleAdvDiagMs >= 60000UL) {
        lastBleAdvDiagMs = bleDiagNow;
        NimBLEAdvertising* adv = NimBLEDevice::getAdvertising();
        bool advOn = adv && adv->isAdvertising();
        if (!advOn) {
            NimBLEDevice::startAdvertising();
            Serial.println("[ble] advertising watchdog restarted advertising");
        }
        Serial.printf("[ble] adv heartbeat up=%lus adv=%u sleeping=%u cpu=%dMHz heap=%u psram=%u name=%s\n",
                      bleDiagNow / 1000UL,
                      advOn ? 1 : 0,
                      nowSleeping ? 1 : 0,
                      getCpuFrequencyMhz(),
                      (unsigned)ESP.getFreeHeap(),
                      (unsigned)ESP.getFreePsram(),
                      devName);
    }

    // ── LED 状态推断 + 渲染(0.5.2: sleep 状态现在也走静态点 case,统一 led_tick) ──
    //   原 0.5.0 把 sleep 走单独 render_static 路径,事件结束 led_tick 回 renderStatus
    //   画的是上次的 LED_IDLE(4 颗绿)。改成 sleep 也设 status,renderStatus 直接画静态点
    LedStatus ledNext;
    if (nowSleeping) {
        ledNext = bleConnected ? LED_SLEEPING : LED_SLEEPING_DISCONNECTED;
    }
    // REQ-022:审批队列非空 → 紫色慢闪(与旧 permission toast 同色语义)
    else if (g_permToast.active || !g_approvalQueue.empty()) ledNext = LED_PERM_REQUEST;
    else if (g_overlayCtx.state == UI_OV_ASR_PROC)         ledNext = LED_ASR_PROC;
    else if (isRecording)                                  ledNext = LED_PTT;
    else if (!bleConnected)                                ledNext = LED_BLE_DISCONNECTED;
    else                                                   ledNext = LED_IDLE;
    g_bb.offStep = 30;   // 标记:LED 渲染区(SK6812/RMT)
    led_set_status(ledNext);
    led_tick();
    buzzer_tick();       // REQ-022 §B7:审批音效序列非阻塞推进
    taskLifecycleAudioTick();
    g_bb.offStep = 31;   // 标记:LED 后

    // ── REQ-003 Phase 2.2 (0.5.1): 不再手动 esp_light_sleep_start ──
    //   0.5.0 的手动 sleep 跟 BLE controller 没协调,radio 跟着停 → Mac 6s supervision timeout 断连
    //   现在靠 esp_pm_configure 启用 tickless idle:delay() = vTaskDelay,
    //   FreeRTOS 在 idle 时自动进 light sleep,BLE controller 会通过 PM lock 守住 conn event 期间
    //   OFF 状态延迟 100ms 给更长睡眠窗口,IDLE/DIM/ACTIVE 仍然 10ms 保响应
    micstickOta.note_runtime_health();
    g_bb.offStep = 32;   // 标记:delay/tick 等待中
    delay(nowSleeping ? 100 : 10);
    }
}
